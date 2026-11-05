"""What /v1/discover does: read the catalog, check the coverage ledger, and on a miss claim one scout
run for that area, kind of thing and night. Anyone else who asks while it runs joins it."""

import logging
import uuid
from collections.abc import AsyncIterator, Callable
from contextlib import AbstractAsyncContextManager, asynccontextmanager
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta

import httpx
from sqlalchemy import and_, func, or_, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.catalog import cells, intents
from app.catalog.geocode import CityGeocoder, Geocoder
from app.catalog.resolve import resolve
from app.catalog.scout import Ask, Scout, to_candidates
from app.catalog.tables import Coverage, Event, EventSource, Find, ScoutQuota, ScoutRun
from app.geo import distance_m

log = logging.getLogger("letsgo.discover")

# A claim older than this belongs to a run that died; the next ask may take it over.
STALE_CLAIM = timedelta(minutes=5)
# After a failed run, wait this long before trying the same search again.
FAILED_BACKOFF = timedelta(minutes=10)
SHOWN = ("on", "canceled", "sold_out")

GeocoderFactory = Callable[[], AbstractAsyncContextManager[Geocoder]]


@asynccontextmanager
async def city_geocoder() -> AsyncIterator[Geocoder]:
    async with httpx.AsyncClient(follow_redirects=True) as client:
        yield CityGeocoder(client)


@dataclass
class Discovery:
    city: str | None
    intent: str
    area: str
    day: date
    # hit: checked lately · searching: a run is going · miss: not checked and no run (no key, budget,
    # quota or account) · off: outside the cities we cover
    coverage: str
    checked_at: datetime | None = None
    run: ScoutRun | None = None
    events: list[tuple[Event, float, list[str]]] = field(default_factory=list)
    mine: set[uuid.UUID] = field(default_factory=set)


async def nearby(
    session: AsyncSession,
    city: str,
    lat: float,
    lon: float,
    day: date,
    intent: str,
    free: bool,
    now: datetime,
) -> list[tuple[Event, float, list[str]]]:
    """Placed events on that night in your area and the ones around it, soonest first, with their
    distance and sources. Tonight's, once over, drop off."""
    q = select(Event).where(
        Event.city == city,
        Event.day == day,
        Event.area.in_(cells.areas_near(lat, lon, 1)),
        Event.status.in_(SHOWN),
        Event.lat.is_not(None),
    )
    if intent != intents.ANY:
        q = q.where(Event.tags.any(intent))
    else:
        # Trucks are there all day, every day: they answer Food, not "what's on".
        q = q.where(~Event.tags.any("trucks"))
    if free:
        q = q.where(Event.price_min_cents == 0)
    events = [
        e
        for e in await session.scalars(q.order_by(Event.starts_at).limit(300))
        if (e.ends_at or e.starts_at + timedelta(hours=3)) > now
    ]
    sources: dict[uuid.UUID, list[str]] = {}
    if events:
        rows = await session.execute(
            select(EventSource.event_id, EventSource.source).where(
                EventSource.event_id.in_([e.id for e in events])
            )
        )
        for event_id, source in rows:
            sources.setdefault(event_id, []).append(source)
    return [(e, distance_m(lat, lon, e.lat, e.lon), sorted(set(sources.get(e.id, [])))) for e in events]


async def claim(
    session: AsyncSession, city: str, area: str, intent: str, day: date, now: datetime
) -> tuple[uuid.UUID | None, bool]:
    """Takes the run for (area, intent, night) unless it's covered and fresh or someone holds it.
    Returns the run that's going and whether it's ours."""
    mine = uuid.uuid4()
    stmt = insert(Coverage).values(
        city=city, area=area, intent=intent, day=day, state="running", by="scout",
        run_id=mine, claimed_at=now, found=0,
    )  # fmt: skip
    stmt = stmt.on_conflict_do_update(
        index_elements=[Coverage.city, Coverage.area, Coverage.intent, Coverage.day],
        set_={"state": "running", "by": "scout", "run_id": mine, "claimed_at": now},
        where=or_(
            and_(
                Coverage.state == "covered", or_(Coverage.fresh_until.is_(None), Coverage.fresh_until <= now)
            ),
            and_(Coverage.state == "running", Coverage.claimed_at < now - STALE_CLAIM),
        ),
    ).returning(Coverage.run_id)
    won = await session.scalar(stmt)
    if won == mine:
        return mine, True
    row = await session.get(Coverage, (city, area, intent, day), populate_existing=True)
    return (row.run_id if row and row.state == "running" else None), False


async def spent_today(session: AsyncSession, city: str, now: datetime) -> int:
    start, _ = cells.night_bounds(cells.night_of(now, city), city)
    total = await session.scalar(
        select(func.coalesce(func.sum(ScoutRun.cost_micros), 0)).where(
            ScoutRun.city == city, ScoutRun.started_at >= start
        )
    )
    return int(total or 0)


async def take_quota(session: AsyncSession, user_id: uuid.UUID, now: datetime, limit: int) -> bool:
    hour = now.replace(minute=0, second=0, microsecond=0)
    stmt = insert(ScoutQuota).values(user_id=user_id, hour=hour, runs=1)
    runs = await session.scalar(
        stmt.on_conflict_do_update(
            index_elements=[ScoutQuota.user_id, ScoutQuota.hour], set_={"runs": ScoutQuota.runs + 1}
        ).returning(ScoutQuota.runs)
    )
    return (runs or 0) <= limit


def known_for(rows: list[tuple[Event, float, list[str]]]) -> list[dict]:
    return [
        {"title": e.title, "venue": e.venue_name, "starts_at": e.starts_at.isoformat(), "url": e.url}
        for e, _, _ in rows
    ]


async def execute(
    factory: async_sessionmaker[AsyncSession],
    scout: Scout,
    geocoders: GeocoderFactory,
    run_id: uuid.UUID,
    ask: Ask,
    known: list[dict],
    asked_by: uuid.UUID | None,
    now: Callable[[], datetime],
) -> None:
    """The run itself, after the response has gone. Every outcome ends the claim."""
    note, status = "", "done"
    try:
        found = await scout.search(ask, known)
    except Exception as e:  # the claim must end however the search does
        log.exception("scout run %s failed", run_id)
        found, note, status = None, f"{type(e).__name__}: {e}"[:400], "failed"
    async with factory() as session:
        run = await session.get(ScoutRun, run_id)
        cov = await session.get(Coverage, (ask.city, ask.area, ask.intent, ask.day))
        at = now()
        added: list[uuid.UUID] = []
        merged = 0
        if found is not None:
            candidates, dropped = to_candidates(ask, found.proposals)
            async with geocoders() as geocoder:
                result = await resolve(session, ask.city, candidates, geocoder, at, run_id=run_id)
            added, merged = result.added, result.merged
            if asked_by is not None and added:
                await session.execute(
                    insert(Find)
                    .values([{"user_id": asked_by, "event_id": e} for e in added])
                    .on_conflict_do_nothing()
                )
            if run is not None:
                u = found.usage
                run.searches, run.tokens_in, run.tokens_out = u.searches, u.tokens_in, u.tokens_out
                run.cache_read, run.cost_micros = u.cache_read, u.cost_micros
                run.proposed, run.added, run.merged = len(found.proposals), len(added), merged
                note = (found.note or "") + (f" · {dropped} dropped by checks" if dropped else "")
        if run is not None:
            run.status, run.note, run.finished_at = status, note[:400], at
        if cov is not None and cov.run_id == run_id:
            cov.state = "covered"
            cov.fresh_until = at + (
                cells.fresh_for(ask.day, ask.city, at) if status == "done" else FAILED_BACKOFF
            )
            cov.found = len(added) + merged
        await session.commit()


async def discover(
    session: AsyncSession,
    *,
    lat: float,
    lon: float,
    query: str | None,
    intent: str | None,
    day: date | None,
    free: bool,
    now: datetime,
    user_id: uuid.UUID | None,
    scout_ready: bool,
    budget_micros: int,
    runs_per_hour: int,
) -> tuple[Discovery, bool]:
    """The catalog's answer, and whether this request just claimed a run (the caller starts it)."""
    kind = intents.parse(query, intent)
    city = "sf" if cells.in_city("sf", lat, lon) else None
    area = cells.area(lat, lon)
    if city is None:
        return Discovery(None, kind, area, day or now.date(), "off"), False
    today = cells.night_of(now, city)
    night = min(max(day or today, today), today + timedelta(days=30))
    out = Discovery(city, kind, area, night, "miss")
    out.events = await nearby(session, city, lat, lon, night, kind, free, now)
    if user_id is not None and out.events:
        rows = await session.scalars(
            select(Find.event_id).where(
                Find.user_id == user_id, Find.event_id.in_([e.id for e, _, _ in out.events])
            )
        )
        out.mine = set(rows)
    if kind == intents.ANY:
        out.coverage = "hit"
        return out, False
    cov = await session.get(Coverage, (city, area, kind, night))
    if cov is not None and cov.state == "covered" and cov.fresh_until and cov.fresh_until > now:
        out.coverage, out.checked_at = "hit", cov.claimed_at
        return out, False
    if cov is not None and cov.state == "running" and cov.claimed_at and cov.claimed_at >= now - STALE_CLAIM:
        out.coverage, out.run = "searching", await session.get(ScoutRun, cov.run_id) if cov.run_id else None
        return out, False
    if not scout_ready or user_id is None or await spent_today(session, city, now) >= budget_micros:
        return out, False
    if not await take_quota(session, user_id, now, runs_per_hour):
        await session.commit()
        return out, False
    run_id, mine = await claim(session, city, area, kind, night, now)
    if mine and run_id is not None:
        run = ScoutRun(
            id=run_id, city=city, area=area, intent=kind, day=night, status="running", started_at=now
        )
        session.add(run)
        await session.commit()
        out.coverage, out.run = "searching", run
        return out, True
    await session.commit()
    if run_id is not None:
        out.coverage, out.run = "searching", await session.get(ScoutRun, run_id)
    return out, False
