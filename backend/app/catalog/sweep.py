"""The nightly sweep: every feed, through the resolver, into the catalog. Then it marks coverage for
whatever the feeds already answer well, so asks for those never start a scout run.

    python -m app.catalog.sweep                    # SF, the next 7 nights
    python -m app.catalog.sweep --days 3 --feeds 19hz,datasf
"""

import argparse
import asyncio
import json
import logging
from collections import defaultdict
from collections.abc import Awaitable, Callable
from datetime import date, datetime, timedelta

import h3
import httpx
from sqlalchemy import and_, exists, select, update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.catalog import cells
from app.catalog.feeds import Candidate, datasf_trucks, funcheap, nineteenhz
from app.catalog.geocode import CityGeocoder, Geocoder
from app.catalog.resolve import resolve
from app.catalog.tables import Coverage, Event, EventSource, SweepLog

log = logging.getLogger("letsgo.sweep")

Feed = Callable[[httpx.AsyncClient, date, int], Awaitable[list[Candidate]]]
FEEDS: dict[str, Feed] = {
    funcheap.SOURCE: funcheap.fetch,
    nineteenhz.SOURCE: nineteenhz.fetch,
    datasf_trucks.SOURCE: datasf_trucks.fetch,
}
# A kind of thing is "covered" for a night in an area when the feeds have at least this many of it
# within the area and the ones around it.
COVERED_AT = 3
SWEEP_FRESH = timedelta(hours=26)


async def mark_feed_coverage(session: AsyncSession, city: str, days: list[date], now: datetime) -> int:
    """Coverage rows for (area, intent, night) the feeds already answer. Never touches a run in flight."""
    rows = await session.execute(
        select(Event.area, Event.day, Event.tags).where(
            Event.city == city, Event.day.in_(days), Event.status == "on", Event.area.is_not(None)
        )
    )
    counts: dict[tuple[str, date, str], int] = defaultdict(int)
    for area, day, tags in rows:
        for near in h3.grid_disk(area, 1):
            for tag in tags:
                counts[(near, day, tag)] += 1
    covered = [k for k, n in counts.items() if n >= COVERED_AT]
    for area, day, intent in covered:
        stmt = insert(Coverage).values(
            city=city, area=area, intent=intent, day=day, state="covered", by="sweep",
            claimed_at=now, fresh_until=now + SWEEP_FRESH, found=counts[(area, day, intent)],
        )  # fmt: skip
        await session.execute(
            stmt.on_conflict_do_update(
                index_elements=[Coverage.city, Coverage.area, Coverage.intent, Coverage.day],
                set_={
                    "state": "covered",
                    "by": "sweep",
                    "claimed_at": now,
                    "fresh_until": stmt.excluded.fresh_until,
                    "found": stmt.excluded.found,
                },
                where=and_(Coverage.state == "covered", Coverage.fresh_until < stmt.excluded.fresh_until),
            )  # fmt: skip
        )
    return len(covered)


async def mark_gone(
    session: AsyncSession, city: str, ran: list[str], first: date, last: date, since: datetime
):
    """Events every one of whose sources ran tonight and dropped them: the listing is gone."""
    if not ran:
        return 0
    stale = select(EventSource.event_id).where(EventSource.source.in_(ran), EventSource.seen_at < since)
    fresh = exists().where(EventSource.event_id == Event.id, EventSource.seen_at >= since)
    other = exists().where(EventSource.event_id == Event.id, EventSource.source.not_in(ran))
    result = await session.execute(
        update(Event)
        .where(
            Event.city == city,
            Event.status == "on",
            Event.day >= first,
            Event.day <= last,
            Event.id.in_(stale),
            ~fresh,
            ~other,
        )
        .values(status="gone")
    )
    return result.rowcount or 0


async def sweep(
    session: AsyncSession,
    city: str,
    client: httpx.AsyncClient,
    geocoder: Geocoder,
    now: datetime,
    days: int = 7,
    feeds: dict[str, Feed] | None = None,
) -> dict:
    feeds = feeds or FEEDS
    start = cells.night_of(now, city)
    log_row = SweepLog(city=city, started_at=now)
    session.add(log_row)
    await session.commit()
    summary: dict[str, dict] = {}
    ran: list[str] = []
    for name, fetch in feeds.items():
        try:
            found = await fetch(client, start, days)
        except Exception:  # one broken feed must not stop the others
            log.exception("feed %s failed", name)
            summary[name] = {"error": "failed"}
            continue
        if not found:
            summary[name] = {"seen": 0}
            continue
        result = await resolve(session, city, found, geocoder, now)
        await session.commit()
        ran.append(name)
        summary[name] = {"seen": len(found), **result.summary()}
        log.info("feed %s: %s", name, summary[name])
    night_list = [start + timedelta(days=i) for i in range(days)]
    gone = await mark_gone(session, city, ran, start, night_list[-1], now)
    covered = await mark_feed_coverage(session, city, night_list, now)
    summary["_"] = {"gone": gone, "covered": covered}
    log_row.finished_at = datetime.now(now.tzinfo)
    log_row.ok = bool(ran)
    log_row.summary = json.dumps(summary)
    await session.commit()
    return summary


async def main() -> None:
    from app.db import SessionLocal, engine
    from app.views import now

    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--city", default="sf")
    parser.add_argument("--days", type=int, default=7)
    parser.add_argument("--feeds", default=",".join(FEEDS))
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(message)s")
    chosen = {k: v for k, v in FEEDS.items() if k in args.feeds.split(",")}
    async with httpx.AsyncClient(follow_redirects=True) as client, SessionLocal() as session:
        summary = await sweep(session, args.city, client, CityGeocoder(client), now(), args.days, chosen)
    await engine.dispose()
    print(json.dumps(summary, indent=1))


if __name__ == "__main__":
    asyncio.run(main())
