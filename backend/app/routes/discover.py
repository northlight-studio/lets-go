import uuid
from datetime import date

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Query, status
from openai import AsyncOpenAI
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.auth import current_user, optional_user
from app.catalog.discover import GeocoderFactory, city_geocoder, discover, execute, known_for
from app.catalog.scout import Ask, OpenAIScout, Scout
from app.catalog.tables import Event, EventSource, Find, ScoutRun
from app.config import settings
from app.db import get_session, get_session_factory
from app.geo import distance_m
from app.models import User
from app.schemas import DiscoverOut, EventOut, FindsOut, ScoutRunOut
from app.views import now

router = APIRouter(prefix="/v1", tags=["discover"])

_scout: Scout | None = None


def get_scout() -> Scout | None:
    """The model, when there's an OpenAI key. Without one the catalog still answers; it never searches."""
    global _scout
    if _scout is None and settings.openai_api_key:
        _scout = OpenAIScout(
            AsyncOpenAI(api_key=settings.openai_api_key), settings.ai_model, settings.scout_reasoning_effort
        )
    return _scout


def get_geocoders() -> GeocoderFactory:
    return city_geocoder


def event_out(e: Event, sources: list[str], distance: float | None = None, mine: bool = False) -> EventOut:
    return EventOut(
        id=e.id,
        title=e.title,
        venue=e.venue_name,
        address=e.address,
        lat=e.lat,
        lon=e.lon,
        starts_at=e.starts_at,
        ends_at=e.ends_at,
        genre=e.genre,
        tags=e.tags,
        price_text=e.price_text,
        price_min_cents=e.price_min_cents,
        ages=e.ages,
        url=e.url,
        why=e.why,
        status=e.status,
        sources=sources,
        distance_m=round(distance) if distance is not None else None,
        found_by_you=mine,
    )


@router.get("/discover", response_model=DiscoverOut)
async def discover_route(
    background: BackgroundTasks,
    lat: float = Query(ge=-90, le=90),
    lon: float = Query(ge=-180, le=180),
    q: str | None = Query(default=None, max_length=120),
    intent: str | None = Query(default=None, max_length=24),
    day: date | None = None,
    free: bool = False,
    # A neighborhood name for the scout's search ("Mission"). Used for that search only, never stored.
    near: str | None = Query(default=None, max_length=60),
    session: AsyncSession = Depends(get_session),
    user: User | None = Depends(optional_user),
    scout: Scout | None = Depends(get_scout),
    factory: async_sessionmaker[AsyncSession] = Depends(get_session_factory),
    geocoders: GeocoderFactory = Depends(get_geocoders),
) -> DiscoverOut:
    """What's on near a point, for a kind of thing and a night. Answers from the shared catalog; if
    nobody has looked for this kind of thing in this area for that night lately, starts one scout run
    (signed-in callers only) and says so. Poll again, or poll the run, to see what it finds."""
    at = now()
    found, started = await discover(
        session,
        lat=lat,
        lon=lon,
        query=q,
        intent=intent,
        day=day,
        free=free,
        now=at,
        user_id=user.id if user else None,
        scout_ready=scout is not None,
        budget_micros=round(settings.scout_daily_budget_usd * 1_000_000),
        runs_per_hour=settings.scout_runs_per_hour,
    )
    if started and found.run is not None and scout is not None and found.city is not None:
        ask = Ask(found.city, found.area, found.intent, found.day, lat, lon, near or "")
        background.add_task(
            execute, factory, scout, geocoders, found.run.id, ask, known_for(found.events),
            user.id if user else None, now,
        )  # fmt: skip
    return DiscoverOut(
        intent=found.intent,
        day=found.day,
        coverage=found.coverage,
        checked_at=found.checked_at,
        run=ScoutRunOut.model_validate(found.run) if found.run else None,
        events=[event_out(e, src, d, e.id in found.mine) for e, d, src in found.events],
    )


@router.get("/scout/runs/{run_id}", response_model=ScoutRunOut)
async def scout_run(run_id: uuid.UUID, session: AsyncSession = Depends(get_session)) -> ScoutRunOut:
    """How a run is going. A run never says who started it."""
    run = await session.get(ScoutRun, run_id)
    if run is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "No such run")
    return ScoutRunOut.model_validate(run)


@router.get("/me/finds", response_model=FindsOut)
async def my_finds(
    lat: float | None = Query(default=None, ge=-90, le=90),
    lon: float | None = Query(default=None, ge=-180, le=180),
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> FindsOut:
    """What your asks put on the map first, newest first. Nobody else can see this."""
    rows = (
        (
            await session.execute(
                select(Event)
                .join(Find, Find.event_id == Event.id)
                .where(Find.user_id == user.id, Event.lat.is_not(None))
                .order_by(Find.created_at.desc())
                .limit(100)
            )
        )
        .scalars()
        .all()
    )
    sources: dict[uuid.UUID, list[str]] = {}
    if rows:
        for event_id, source in await session.execute(
            select(EventSource.event_id, EventSource.source).where(
                EventSource.event_id.in_([e.id for e in rows])
            )
        ):
            sources.setdefault(event_id, []).append(source)
    return FindsOut(
        events=[
            event_out(
                e,
                sorted(set(sources.get(e.id, []))),
                distance_m(lat, lon, e.lat, e.lon) if lat is not None and lon is not None else None,
                True,
            )
            for e in rows
        ]
    )
