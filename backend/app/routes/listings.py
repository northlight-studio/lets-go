from collections import defaultdict
from datetime import date, datetime, time, timedelta
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, Query
from sqlalchemy import and_, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.catalog import cells
from app.catalog.tables import Event, EventSource
from app.db import get_session
from app.listings_import import listing_key
from app.models import Listing
from app.schemas import ListingOut, Listings, Slot
from app.views import now

router = APIRouter(prefix="/v1", tags=["listings"])

CITY_TIME = {"sf": ZoneInfo("America/Los_Angeles")}
# How far ahead catalog events are offered in the listing shape the app already reads.
CATALOG_DAYS = 14
# Trucks are in the catalog for /v1/discover; the map's listing layer isn't built for hundreds of carts.
NOT_AS_LISTINGS = {"datasf"}
# A slot or event with no end is over this long after it starts.
TYPICAL_LENGTH = timedelta(hours=3)


def slot_over(slot: dict, at: datetime, zone: ZoneInfo) -> bool:
    """A one-off slot whose end (or start plus a typical length) has passed. Weekly slots never are."""
    if "weekday" in slot and slot.get("weekday"):
        return False
    try:
        day = date.fromisoformat(str(slot["date"]))
        start = datetime.combine(day, time.fromisoformat(str(slot["start"])), zone)
        end = datetime.combine(day, time.fromisoformat(str(slot["end"])), zone) if slot.get("end") else None
    except (KeyError, ValueError):
        return True
    if end is not None and end <= start:
        end += timedelta(days=1)
    return (end or start + TYPICAL_LENGTH) <= at


async def catalog_listings(session: AsyncSession, city: str, taken: set[str]) -> list[ListingOut]:
    """Catalog events in the shape of `sf_happenings.json`: one listing per title and venue, a dated
    slot per occurrence, so phones that only know /v1/listings get the real city too."""
    zone = CITY_TIME.get(city, ZoneInfo("UTC"))
    at = now()
    today = cells.night_of(at, city)
    rows = (
        await session.scalars(
            select(Event)
            .where(
                Event.city == city,
                Event.status == "on",
                Event.lat.is_not(None),
                Event.day >= today,
                Event.day <= today + timedelta(days=CATALOG_DAYS),
                # Nothing that's over: ended, or (with no end) three hours past its start.
                or_(
                    Event.ends_at > at,
                    and_(Event.ends_at.is_(None), Event.starts_at > at - TYPICAL_LENGTH),
                ),
                ~Event.id.in_(select(EventSource.event_id).where(EventSource.source.in_(NOT_AS_LISTINGS))),
            )
            .order_by(Event.starts_at)
        )
    ).all()
    groups: dict[str, list[Event]] = defaultdict(list)
    for e in rows:
        venue = e.venue_name or e.address or "San Francisco"
        key = listing_key(city, e.title[:160], venue[:160])
        if key not in taken:
            groups[key].append(e)
    out = []
    for events in groups.values():
        first = events[0]
        slots = []
        for e in events:
            start = e.starts_at.astimezone(zone)
            end = e.ends_at.astimezone(zone) if e.ends_at else None
            slots.append(Slot(date=start.date(), start=f"{start:%H:%M}", end=f"{end:%H:%M}" if end else None))
        out.append(
            ListingOut(
                title=first.title[:160],
                genre=first.genre,
                venue=(first.venue_name or first.address or "San Francisco")[:160],
                address=first.address[:200],
                lat=first.lat,
                lon=first.lon,
                schedule=slots,
                price=first.price_text[:80],
                organizer="",
                url=first.url[:500],
                description=(first.why or first.description)[:2000],
                confidence="high",
            )
        )
    return out


@router.get("/listings", response_model=Listings)
async def listings(
    city: str = Query(default="sf", max_length=16), session: AsyncSession = Depends(get_session)
) -> Listings:
    """Everything live in `city` that hasn't happened yet: the hand-made regulars, then the catalog's
    dated events. A one-off slot that's over is left out, and a listing with nothing left goes with it.
    Public: you can see what's on before you have an account."""
    zone = CITY_TIME.get(city, ZoneInfo("UTC"))
    at = now()
    rows = await session.scalars(
        select(Listing).where(Listing.city == city, Listing.status == "live").order_by(Listing.title)
    )
    manual = []
    for row in rows:
        ahead = [s for s in row.schedule if not slot_over(s, at, zone)]
        if ahead:
            item = ListingOut.model_validate(row)
            manual.append(item.model_copy(update={"schedule": [Slot.model_validate(s) for s in ahead]}))
    taken = {listing_key(city, item.title, item.venue) for item in manual}
    return Listings(listings=manual + await catalog_listings(session, city, taken))
