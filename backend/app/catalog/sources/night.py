"""The nightly read: every source, fetched by plain code, after the feeds.

1. Fetch. Hosts in parallel, one request at a time within a host (`Fetcher`). A source that hasn't
   been learned yet is looked at first: if it links a calendar file or sits on a known calendar
   platform, that's what gets read from then on.
2. Skip what hasn't changed: a 304, or the same content hash as last time.
3. Read. Structured formats by code. A changed page with no structure goes to the model, while the
   city's daily budget lasts; what's left over is read tomorrow (its hash isn't stored).
4. Resolve. Every event, from code or model, goes through the resolver like the feeds' do. A code-read
   page that drops an upcoming event marks it gone, unless someone else still lists it.
5. Health. 404/410 → broken at once; other failures → broken after three nights in a row; a new address
   → moved; robots.txt says no or it wants a login → blocked; nothing upcoming for three weeks → empty.

The hourly re-check (`recheck_soon`) runs the same read for the sources of everything starting in the
next six hours, plus today's Funcheap and 19hz pages, so a cancellation an hour before doors shows.
"""

import asyncio
import hashlib
import json
import logging
import uuid
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timedelta

import httpx
from sqlalchemy import and_, exists, func, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.catalog import cells
from app.catalog.feeds import Candidate, funcheap, nineteenhz
from app.catalog.geocode import Geocoder
from app.catalog.resolve import resolve
from app.catalog.scout import check_proposals
from app.catalog.sources import formats, normalize
from app.catalog.sources.fetch import Fetcher, Page
from app.catalog.sources.model import PageModel, PageRead
from app.catalog.sources.seed import FEEDS
from app.catalog.tables import Event, EventSource, ReaderNight, ScoutRun, Source

log = logging.getLogger("letsgo.sources.night")

# How far ahead the reader keeps events.
DAYS_AHEAD = 45
HOSTS_AT_ONCE = 8
MODEL_AT_ONCE = 4
BROKEN_AFTER = 3
EMPTY_AFTER = timedelta(weeks=3)
SOON = timedelta(hours=6)
# A rough model-page cost, held against the budget while a call is in flight.
MODEL_PAGE_HOLD = 5_000
# An event that's over is never kept: it's over when it ends, or three hours after it starts.
TYPICAL_LENGTH = timedelta(hours=3)


@dataclass
class Snapshot:
    """What a fetch needs from a source row, copied out so fetching never touches the session."""

    id: uuid.UUID
    url: str
    host: str
    reader: str
    feed_url: str | None
    etag: str | None
    last_modified: str | None


@dataclass
class Fetched:
    source: Snapshot
    page: Page
    # The structured feed the page led to (or the source's known one), when there is one.
    feed: Page | None = None
    learned: formats.Learned | None = None


@dataclass
class Tally:
    sources: int = 0
    read: int = 0
    unchanged: int = 0
    changed: int = 0
    failed: int = 0
    blocked: int = 0
    by_model: int = 0
    deferred: int = 0
    events_seen: int = 0
    added: int = 0
    updated: int = 0
    canceled: int = 0
    gone: int = 0
    tokens_in: int = 0
    tokens_out: int = 0
    cost_micros: int = 0
    notes: list[str] = field(default_factory=list)

    def write(self, row: ReaderNight) -> None:
        for name in (
            "sources", "read", "unchanged", "changed", "failed", "blocked", "by_model", "deferred",
            "events_seen", "added", "updated", "canceled", "gone", "tokens_in", "tokens_out", "cost_micros",
        ):  # fmt: skip
            setattr(row, name, getattr(self, name))
        row.note = "\n".join(self.notes[-50:])

    def as_dict(self) -> dict:
        return {k: v for k, v in self.__dict__.items() if k != "notes"}


def fingerprint(reader: str, events: list[Candidate] | None, text: str) -> str:
    """What "changed" means: the events code read off it, or the page's readable text. Never the raw
    bytes, which change with every ad and session token."""
    if events is not None:
        body = json.dumps(
            sorted(
                [
                    c.ref,
                    c.title,
                    c.starts_at.isoformat(),
                    str(c.ends_at),
                    c.venue_name,
                    c.price_text,
                    c.canceled,
                ]
                for c in events
            )
        )
    else:
        body = text
    return hashlib.sha256(f"{reader}\n{body}".encode()).hexdigest()


def upcoming(events: list[Candidate], now: datetime) -> list[Candidate]:
    return [c for c in events if (c.ends_at or c.starts_at + TYPICAL_LENGTH) > now]


async def _fetch_one(fetcher: Fetcher, s: Snapshot) -> Fetched:
    if s.reader not in ("auto", "html") and s.feed_url:
        feed = await fetcher.fetch(s.feed_url, s.etag, s.last_modified)
        return Fetched(s, feed, feed=feed)
    page = await fetcher.fetch(s.url, s.etag if s.reader != "auto" else None, s.last_modified)
    out = Fetched(s, page)
    if s.reader == "auto" and page.ok:
        out.learned = formats.detect(page.text, page.final_url or s.url, page.content_type)
        if out.learned.feed_url:
            out.feed = await fetcher.fetch(out.learned.feed_url)
            if not out.feed.ok:
                # The calendar link or API didn't answer: read the page itself instead.
                out.learned = formats.Learned("jsonld" if formats.ld_events(page.text) else "html")
                out.feed = None
    return out


async def fetch_all(fetcher: Fetcher, sources: list[Snapshot], queue: asyncio.Queue) -> None:
    by_host: dict[str, list[Snapshot]] = defaultdict(list)
    for s in sources:
        by_host[s.host].append(s)
    gate = asyncio.Semaphore(HOSTS_AT_ONCE)

    async def host_worker(items: list[Snapshot]) -> None:
        async with gate:
            for s in items:
                try:
                    await queue.put(await _fetch_one(fetcher, s))
                except Exception as e:  # one bad page mustn't stop its host's other sources
                    log.exception("fetching %s failed", s.url)
                    await queue.put(Fetched(s, Page(url=s.url, refused="error", error=type(e).__name__)))

    await asyncio.gather(*(host_worker(items) for items in by_host.values()))
    await queue.put(None)


def _health(src: Source, health: str, note: str = "") -> None:
    src.health, src.health_note = health, note[:300]


def _record_failure(src: Source, page: Page, tally: Tally) -> None:
    if page.refused in ("robots", "login"):
        tally.blocked += 1
        _health(src, "blocked", page.error or page.refused or "")
        return
    tally.failed += 1
    src.fails += 1
    if page.status in (404, 410):
        _health(src, "broken", f"{page.status} at {page.final_url or page.url}")
    elif src.fails >= BROKEN_AFTER:
        _health(src, "broken", page.error or f"HTTP {page.status}, {src.fails} nights running")


def _settle(src: Source, moved: bool, now: datetime) -> None:
    """After a good read: moved if it answered from a new address; empty if it's had nothing upcoming
    for three weeks; otherwise fine, including a source that had been failing."""
    quiet_since = src.last_nonempty_at or src.created_at or now
    if moved:
        _health(src, "moved", f"now at {src.moved_to}")
        return
    src.moved_to = None
    if (src.events_last == 0 or src.last_nonempty_at is None) and now - quiet_since >= EMPTY_AFTER:
        _health(src, "empty", f"nothing upcoming for {(now - quiet_since).days // 7} weeks")
    elif src.health != "ok" or src.health_note:
        _health(src, "ok")


async def mark_dropped(session: AsyncSession, source_id: uuid.UUID, now: datetime, until: datetime) -> int:
    """Upcoming events (up to `until`, as far as this read looked) only this page had, that it no longer
    lists: gone."""
    stale = select(EventSource.event_id).where(
        EventSource.source == formats.SOURCE,
        EventSource.ref.like(f"{source_id}|%"),
        EventSource.seen_at < now,
    )
    elsewhere = exists().where(
        EventSource.event_id == Event.id,
        ~and_(EventSource.source == formats.SOURCE, EventSource.ref.like(f"{source_id}|%")),
    )
    result = await session.execute(
        update(Event)
        .where(
            Event.id.in_(stale),
            Event.status == "on",
            Event.starts_at > now,
            Event.starts_at < until,
            ~elsewhere,
        )
        .values(status="gone")
        .execution_options(synchronize_session=False)
    )
    return result.rowcount or 0


def context_for(src: Source, url: str, now: datetime, days: int) -> formats.Context:
    return formats.Context(
        source_id=str(src.id),
        page_url=url,
        city=src.city,
        venue_name=src.venue_name
        or (src.name if src.kind not in ("organizer", "platform", "aggregator") else ""),
        address=src.address,
        lat=src.lat,
        lon=src.lon,
        genre=src.genre,
        window=(now - TYPICAL_LENGTH, now + timedelta(days=days)),
    )


async def _take_events(
    session: AsyncSession,
    src: Source,
    events: list[Candidate],
    geocoder: Geocoder,
    now: datetime,
    tally: Tally,
    *,
    drop_missing: bool,
    until: datetime,
) -> None:
    events = upcoming(events, now)
    tally.events_seen += len(events)
    if events:
        result = await resolve(session, src.city, events, geocoder, now)
        tally.added += len(result.added)
        tally.updated += result.updated + result.merged
        tally.canceled += result.canceled
    if drop_missing:
        tally.gone += await mark_dropped(session, src.id, now, until)
    src.events_last = len(events)
    if events:
        src.last_nonempty_at = now
    _health(src, "ok")


async def spent_today(session: AsyncSession, city: str, now: datetime) -> int:
    """The city's AI spend since this night began: scout runs, the source finder and the reader."""
    start, _ = cells.night_bounds(cells.night_of(now, city), city)
    scouts = await session.scalar(
        select(func.coalesce(func.sum(ScoutRun.cost_micros), 0)).where(
            ScoutRun.city == city, ScoutRun.started_at >= start
        )
    )
    reader = await session.scalar(
        select(func.coalesce(func.sum(ReaderNight.cost_micros), 0)).where(
            ReaderNight.city == city, ReaderNight.started_at >= start
        )
    )
    return int(scouts or 0) + int(reader or 0)


@dataclass
class ForModel:
    source_id: uuid.UUID
    url: str
    text: str
    venue: str
    fingerprint: str


async def read_sources(
    session: AsyncSession,
    city: str,
    fetcher: Fetcher,
    geocoder: Geocoder,
    now: datetime,
    *,
    model: PageModel | None,
    budget_micros: int,
    max_model_pages: int = 150,
    days: int = DAYS_AHEAD,
    only: set[uuid.UUID] | None = None,
    kind: str = "night",
) -> ReaderNight:
    night = ReaderNight(city=city, kind=kind, started_at=now)
    session.add(night)
    q = select(Source).where(Source.city == city, Source.active.is_(True), Source.reader != "feed")
    if only is not None:
        q = q.where(Source.id.in_(list(only)))
    rows = list(await session.scalars(q.order_by(Source.host, Source.url)))
    # Conditional requests only once a page has been read through: a page left for tomorrow is fetched
    # whole again, not answered with a 304.
    snaps = [
        Snapshot(
            r.id, r.url, r.host, r.reader, r.feed_url,
            r.etag if r.content_hash else None, r.last_modified if r.content_hash else None,
        )
        for r in rows
    ]  # fmt: skip
    await session.commit()
    tally = Tally(sources=len(snaps))
    queue: asyncio.Queue = asyncio.Queue(maxsize=32)
    producer = asyncio.create_task(fetch_all(fetcher, snaps, queue))
    for_model: list[ForModel] = []
    try:
        while (item := await queue.get()) is not None:
            try:
                await _process(session, item, geocoder, now, days, tally, for_model)
                await session.commit()
            except Exception:  # one source's trouble mustn't end the night
                await session.rollback()
                log.exception("reading %s failed", item.source.url)
                tally.failed += 1
    finally:
        await producer
    await _read_with_model(
        session, city, for_model, geocoder, now, days, tally, model, budget_micros, max_model_pages, night
    )
    tally.write(night)
    night.finished_at = datetime.now(now.tzinfo)
    await session.commit()
    log.info("reader %s %s: %s", kind, city, tally.as_dict())
    return night


async def _process(
    session: AsyncSession,
    item: Fetched,
    geocoder: Geocoder,
    now: datetime,
    days: int,
    tally: Tally,
    for_model: list[ForModel],
) -> None:
    src = await session.get(Source, item.source.id)
    if src is None:
        return
    page = item.feed or item.page
    src.last_fetched_at = now
    src.last_status = item.page.status or None
    if not item.page.ok and not item.page.not_modified:
        _record_failure(src, item.page, tally)
        return
    if item.feed is not None and not item.feed.ok and not item.feed.not_modified:
        _record_failure(src, item.feed, tally)
        return
    tally.read += 1
    src.fails = 0
    moved = item.page.moved and (item.page.permanent_redirect or item.page.host_changed) and not item.feed
    if moved:
        src.moved_to = item.page.final_url[:500]
    if item.learned is not None:
        src.reader = item.learned.reader
        src.feed_url = item.learned.feed_url
        if src.feed_url:
            twin = await session.scalar(
                select(Source.url).where(
                    Source.city == src.city,
                    Source.feed_url == src.feed_url,
                    Source.active.is_(True),
                    Source.id != src.id,
                )
            )
            if twin is not None:
                # Event pages on one site that all lead to the site's calendar: read it once.
                src.active = False
                _health(src, "ok", f"same calendar as {twin}")
                return
    if page.not_modified:
        tally.unchanged += 1
        _settle(src, moved, now)
        return
    src.etag, src.last_modified = (page.etag or "")[:200] or None, (page.last_modified or "")[:64] or None
    url = page.final_url or page.url
    ctx = context_for(src, url, now, days)
    events = formats.parse(src.reader, page.text, ctx) if src.reader != "html" else None
    if events is None and src.reader != "html":
        # It isn't in its learned format anymore: learn again next time, read it as a page tonight.
        src.reader, src.feed_url, src.etag = "auto", None, None
        if item.feed is not None:
            return
    text = formats.page_text(page.text, url) if events is None else ""
    digest = fingerprint(src.reader, events, text)
    if digest == src.content_hash:
        tally.unchanged += 1
        _settle(src, moved, now)
        return
    tally.changed += 1
    if events is None:
        for_model.append(ForModel(src.id, url, text, ctx.venue_name, digest))
        return
    await _take_events(session, src, events, geocoder, now, tally, drop_missing=True, until=ctx.window[1])
    src.content_hash, src.last_changed_at = digest, now
    _settle(src, moved, now)


async def _read_with_model(
    session: AsyncSession,
    city: str,
    pages: list[ForModel],
    geocoder: Geocoder,
    now: datetime,
    days: int,
    tally: Tally,
    model: PageModel | None,
    budget_micros: int,
    max_pages: int,
    night: ReaderNight,
) -> None:
    if not pages:
        return
    if model is None:
        tally.deferred += len(pages)
        tally.notes.append(f"{len(pages)} changed pages need the model, and there's no key")
        return
    spent = await spent_today(session, city, now)
    gate = asyncio.Semaphore(MODEL_AT_ONCE)
    held = 0
    today = cells.night_of(now, city)

    async def one(p: ForModel) -> tuple[ForModel, PageRead | None]:
        nonlocal held
        try:
            async with gate:
                return p, await model.read(
                    url=p.url, text=p.text, venue=p.venue, today=f"{today:%A, %B} {today.day}, {today.year}"
                )
        except Exception as e:  # a failed call costs us that page tonight, nothing more
            log.warning("model read of %s failed: %s", p.url, e)
            tally.notes.append(f"model failed on {p.url}: {type(e).__name__}")
            return p, None
        finally:
            held -= MODEL_PAGE_HOLD

    tasks = []
    for p in pages:
        if len(tasks) >= max_pages or spent + tally.cost_micros + held + MODEL_PAGE_HOLD > budget_micros:
            tally.deferred += 1
            continue
        held += MODEL_PAGE_HOLD
        tasks.append(asyncio.create_task(one(p)))
        await asyncio.sleep(0)
    if tally.deferred:
        tally.notes.append(f"{tally.deferred} changed pages left for tomorrow (budget or page cap)")
    for task in asyncio.as_completed(tasks):
        p, read = await task
        if read is None:
            continue
        tally.by_model += 1
        tally.tokens_in += read.usage.tokens_in
        tally.tokens_out += read.usage.tokens_out
        tally.cost_micros += read.usage.cost_micros
        src = await session.get(Source, p.source_id)
        if src is None:
            continue
        ctx = context_for(src, p.url, now, days)
        events, dropped = check_proposals(
            read.proposals,
            ctx.window,
            source=formats.SOURCE,
            tags=[],
            genre=src.genre,
            ref_prefix=f"{src.id}|",
            fallback_url=p.url,
            fallback_venue=ctx.venue_name,
            fallback_address=ctx.address,
            limit=60,
        )
        for c in events:
            if not c.venue_name and not c.address:
                c.lat, c.lon = src.lat, src.lon
        if dropped:
            tally.notes.append(f"{p.url}: {dropped} dropped by checks")
        try:
            # The model can miss an event a page still lists, so its reads never mark anything gone.
            was_moved = src.health == "moved"
            await _take_events(
                session, src, events, geocoder, now, tally, drop_missing=False, until=ctx.window[1]
            )
            src.content_hash, src.last_changed_at = p.fingerprint, now
            _settle(src, was_moved, now)
            tally.write(night)
            await session.commit()
        except Exception:
            await session.rollback()
            log.exception("resolving %s failed", p.url)


async def record_feeds(session: AsyncSession, city: str, summary: dict, now: datetime) -> None:
    """The sweep's feeds, on their rows of the list."""
    for name, (_, url) in FEEDS.items():
        result = summary.get(name)
        if result is None:
            continue
        src = await session.scalar(select(Source).where(Source.city == city, Source.url == normalize(url)))
        if src is None:
            continue
        src.last_fetched_at = now
        if "error" in result:
            src.fails += 1
            if src.fails >= BROKEN_AFTER:
                _health(src, "broken", f"failed {src.fails} nights running")
            continue
        src.fails = 0
        seen = int(result.get("seen", 0))
        src.events_last = seen
        if seen:
            src.last_nonempty_at = now
            _health(src, "ok")
        elif now - (src.last_nonempty_at or src.created_at or now) >= EMPTY_AFTER:
            _health(src, "empty", "the feed has been empty for weeks")


async def recheck_soon(
    session: AsyncSession,
    city: str,
    client: httpx.AsyncClient,
    fetcher: Fetcher,
    geocoder: Geocoder,
    now: datetime,
    *,
    model: PageModel | None,
    budget_micros: int,
) -> ReaderNight:
    """Re-read the sources of everything that starts in the next six hours."""
    rows = await session.execute(
        select(EventSource.source, EventSource.ref)
        .join(Event, Event.id == EventSource.event_id)
        .where(
            Event.city == city,
            Event.status.in_(("on", "sold_out")),
            Event.starts_at >= now,
            Event.starts_at <= now + SOON,
        )
    )
    source_ids: set[uuid.UUID] = set()
    feeds: set[str] = set()
    for source, ref in rows:
        if source == formats.SOURCE:
            try:
                source_ids.add(uuid.UUID(ref.split("|", 1)[0]))
            except ValueError:
                continue
        elif source in (funcheap.SOURCE, nineteenhz.SOURCE):
            feeds.add(source)
    night = await read_sources(
        session, city, fetcher, geocoder, now, model=model, budget_micros=budget_micros, days=1,
        only=source_ids, kind="recheck",
    )  # fmt: skip
    today = cells.night_of(now, city)
    fetchers = {funcheap.SOURCE: funcheap.fetch, nineteenhz.SOURCE: nineteenhz.fetch}
    for name in sorted(feeds):
        try:
            found = await fetchers[name](client, today, 1)
        except Exception:
            log.exception("re-checking feed %s failed", name)
            continue
        soon = [c for c in found if now <= c.starts_at <= now + SOON]
        if soon:
            # Updates and cancellations only: a short re-read never marks anything gone.
            result = await resolve(session, city, soon, geocoder, now)
            night.events_seen += len(soon)
            night.added += len(result.added)
            night.updated += result.updated + result.merged
            night.canceled += result.canceled
            await session.commit()
    return night
