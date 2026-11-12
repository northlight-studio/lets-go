"""The resolver: plain code, not a model. It turns candidates from feeds and the scout into catalog
rows: the same show seen on three sites becomes one event with three sources.

Same event = same venue, same night, starts within 45 minutes, and titles that mostly agree.
"""

import logging
import re
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timedelta

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.catalog import cells, intents
from app.catalog.feeds import Candidate
from app.catalog.geocode import Geocoder
from app.catalog.tables import Event, EventSource, Venue
from app.catalog.text import (
    clean,
    display_title,
    price_min_cents,
    same_title,
    sold_out,
    title_key,
    venue_key,
)

log = logging.getLogger("letsgo.resolve")

SAME_START = timedelta(minutes=45)
RETRY_GEOCODE = timedelta(days=7)
# Venues that are deliberately unplaceable: the listing only says "somewhere in the city".
_STREET = re.compile(r"\d+\s+\w")
_NOWHERE = ("secret location", "tba", "tbd", "all over", "bay area", "various", "online", "virtual")


@dataclass
class Resolved:
    added: list[uuid.UUID] = field(default_factory=list)
    merged: int = 0
    updated: int = 0
    unplaced: int = 0
    skipped: int = 0
    # Candidates that said the event is called off (cancels win, whichever source says so).
    canceled: int = 0

    def summary(self) -> dict[str, int]:
        return {
            "added": len(self.added),
            "merged": self.merged,
            "updated": self.updated,
            "unplaced": self.unplaced,
            "skipped": self.skipped,
            "canceled": self.canceled,
        }


def _nowhere(name: str) -> bool:
    n = name.lower()
    return not n or any(w in n for w in _NOWHERE)


async def _venue(
    session: AsyncSession, city: str, c: Candidate, geocoder: Geocoder, now: datetime, cache: dict[str, Venue]
) -> Venue | None:
    name = clean(c.venue_name)
    # "Secret Location (SF)" at "San Francisco, CA" is somewhere in the city, which isn't a place.
    if _nowhere(name) and not _STREET.search(c.address) and c.lat is None:
        return None
    key = venue_key(city, name, c.address)
    if key.endswith("|"):
        return None
    venue = cache.get(key) or await session.scalar(select(Venue).where(Venue.key == key))
    if venue is None:
        venue = Venue(city=city, key=key, name=name or c.address, address=clean(c.address), geocode="pending")
        session.add(venue)
    cache[key] = venue
    if not venue.address and c.address:
        venue.address = clean(c.address)
    retry = venue.geocode == "failed" and (
        venue.geocoded_at is None or now - venue.geocoded_at > RETRY_GEOCODE
    )
    if venue.geocode == "pending" or retry:
        point = None
        if c.lat is not None and c.lon is not None:
            point = (c.lat, c.lon)
        elif not _nowhere(name) or c.address:
            found = await geocoder.locate(city, name, venue.address)
            point = (found.lat, found.lon) if found else None
        if point and cells.in_city(city, *point):
            venue.lat, venue.lon, venue.geocode = point[0], point[1], "ok"
        else:
            venue.geocode = "failed"
        venue.geocoded_at = now
    return venue


async def _match(
    session: AsyncSession, city: str, venue: Venue | None, c: Candidate, key: str
) -> Event | None:
    if venue is None or venue.id is None:
        return None
    rows = await session.scalars(
        select(Event).where(
            Event.city == city,
            Event.venue_id == venue.id,
            Event.starts_at >= c.starts_at - SAME_START,
            Event.starts_at <= c.starts_at + SAME_START,
        )
    )
    return next((e for e in rows if same_title(e.title_key, key)), None)


def _status(c: Candidate) -> str:
    if c.canceled:
        return "canceled"
    return "sold_out" if sold_out(c.title, c.price_text) else "on"


async def resolve(
    session: AsyncSession,
    city: str,
    candidates: list[Candidate],
    geocoder: Geocoder,
    now: datetime,
    run_id: uuid.UUID | None = None,
) -> Resolved:
    """Writes candidates into the catalog and flushes; the caller commits."""
    out = Resolved()
    seen: set[tuple[str, str]] = set()
    batch = [c for c in candidates if not ((c.source, c.ref) in seen or seen.add((c.source, c.ref)))]
    refs = {(c.source, c.ref) for c in batch}
    existing: dict[tuple[str, str], EventSource] = {}
    for source in {s for s, _ in refs}:
        wanted = [r for s, r in refs if s == source]
        for i in range(0, len(wanted), 500):
            rows = await session.scalars(
                select(EventSource).where(
                    EventSource.source == source, EventSource.ref.in_(wanted[i : i + 500])
                )
            )
            existing |= {(row.source, row.ref): row for row in rows}
    venues: dict[str, Venue] = {}

    for c in batch:
        title = display_title(c.title)[:200]
        if not title or c.starts_at.tzinfo is None:
            out.skipped += 1
            continue
        key = title_key(title)
        out.canceled += int(c.canceled)
        src = existing.get((c.source, c.ref))
        if src is not None:
            event = await session.get(Event, src.event_id)
            if event is not None:
                src.seen_at, src.url = now, c.url or src.url
                event.last_seen_at = now
                event.starts_at, event.ends_at = c.starts_at, c.ends_at or event.ends_at
                event.day = cells.night_of(c.starts_at, city)
                event.price_text = c.price_text or event.price_text
                event.price_min_cents = price_min_cents(event.price_text)
                if c.canceled:
                    event.status = "canceled"
                elif event.status == "gone":
                    event.status = "on"
                out.updated += 1
                continue

        venue = await _venue(session, city, c, geocoder, now, venues)
        await session.flush()
        event = await _match(session, city, venue, c, key)
        if event is not None:
            session.add(EventSource(event_id=event.id, source=c.source, ref=c.ref, url=c.url, seen_at=now))
            event.last_seen_at = now
            event.url = event.url or c.url
            event.price_text = event.price_text or c.price_text
            event.price_min_cents = price_min_cents(event.price_text)
            event.ends_at = event.ends_at or c.ends_at
            event.ages = event.ages or c.ages
            event.tags = sorted(set(event.tags) | set(c.tags))
            event.why = event.why or c.why
            if c.canceled:
                event.status = "canceled"
            elif event.status == "gone":
                event.status = "on"
            out.merged += 1
            await session.flush()
            continue

        placed = venue is not None and venue.geocode == "ok"
        lat, lon = (venue.lat, venue.lon) if placed else (None, None)
        tags = sorted(set(c.tags) | set(intents.tags_for(title, c.description)))
        event = Event(
            city=city,
            title=title,
            title_key=key,
            venue_id=venue.id if venue else None,
            venue_name=clean(c.venue_name)[:160],
            address=clean(c.address or (venue.address if venue else ""))[:240],
            lat=lat,
            lon=lon,
            area=cells.area(lat, lon) if placed else None,
            starts_at=c.starts_at,
            ends_at=c.ends_at,
            day=cells.night_of(c.starts_at, city),
            genre=intents.genre_for(tags, c.genre),
            tags=tags,
            price_min_cents=price_min_cents(c.price_text),
            price_text=clean(c.price_text)[:120],
            ages=clean(c.ages)[:16],
            description=clean(c.description)[:2000],
            url=c.url[:500],
            why=c.why,
            status=_status(c),
            found_by_run=run_id,
            first_seen_at=now,
            last_seen_at=now,
        )
        session.add(event)
        await session.flush()
        session.add(
            EventSource(event_id=event.id, source=c.source, ref=c.ref[:500], url=c.url[:500], seen_at=now)
        )
        out.added.append(event.id)
        if not placed:
            out.unplaced += 1
    await session.flush()
    return out
