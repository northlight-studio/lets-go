"""Model → response shapes that depend on who's asking."""

import hashlib
import math
import uuid
from datetime import UTC, datetime

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.models import Drop, Gathering, Kitchen, Order, Review
from app.schemas import DropOut, GatheringOut, KitchenOut, OrderLineOut, OrderOut, PersonOut


def now() -> datetime:
    return datetime.now(UTC)


def gathering_out(
    g: Gathering,
    viewer_id: uuid.UUID,
    distance: float | None = None,
    friend_ids: set[uuid.UUID] | frozenset[uuid.UUID] = frozenset(),
) -> GatheringOut:
    mine = next((m for m in g.members if m.user_id == viewer_id), None)
    return GatheringOut(
        id=g.id,
        title=g.title,
        genre=g.genre,
        details=g.details,
        place_name=g.place_name,
        lat=g.lat,
        lon=g.lon,
        starts_at=g.starts_at,
        ends_at=g.ends_at,
        capacity=g.capacity,
        bring=g.bring,
        recurring=g.recurring,
        host_name=g.host.display_name,
        going=g.going,
        web_going=len(g.web_guests),
        # First names from the poster's page are for the host alone.
        web_names=[w.first_name for w in g.web_guests] if g.host_id == viewer_id else [],
        is_mine=g.host_id == viewer_id,
        is_joined=mine is not None,
        checked_in_at=mine.checked_in_at if mine else None,
        distance_m=distance,
        friends_going=friends_going(g, friend_ids),
    )


def friends_going(g: Gathering, friend_ids: set[uuid.UUID] | frozenset[uuid.UUID]) -> list[PersonOut]:
    # Filter before touching anything else on a member: a row added this request has nothing loaded.
    friends = [m for m in g.members if m.user_id in friend_ids]
    return [
        PersonOut(id=m.user_id, display_name=m.user.display_name)
        for m in sorted(friends, key=lambda m: m.joined_at)
    ]


def photo_url(photo_id: uuid.UUID | None) -> str | None:
    """Relative to the API's own address, so it works from any server the phone points at."""
    return f"/v1/photos/{photo_id}" if photo_id else None


def drop_fields(d: Drop) -> dict:
    return dict(
        id=d.id,
        starts_at=d.starts_at,
        ends_at=d.ends_at,
        total=d.total,
        sold=d.sold,
        per_slot=d.per_slot,
        left=max(0, d.total - d.sold),
        title=d.title,
        unit=d.unit,
        price_cents=d.item.price_cents if d.menu_item_id and d.item else None,
        tags=list(d.tags or []),
        pickup_spot=d.pickup_spot,
        photo_url=photo_url(d.photo_id),
    )


def drop_out(d: Drop) -> DropOut:
    return DropOut(**drop_fields(d))


def public_point(k: Kitchen) -> tuple[float, float]:
    """Where a kitchen shows to people who haven't ordered: 60 to 150 m off the house, in a direction
    fixed by its id, so it doesn't wander between looks and can't be averaged back to the door."""
    h = hashlib.sha256(k.id.bytes).digest()
    angle = int.from_bytes(h[:4]) / 2**32 * 2 * math.pi
    meters = 60 + int.from_bytes(h[4:8]) / 2**32 * 90
    north, east = meters * math.cos(angle), meters * math.sin(angle)
    return (
        k.lat + north / 111_320,
        k.lon + east / (111_320 * max(0.01, math.cos(math.radians(k.lat)))),
    )


def pay_mode(k: Kitchen) -> str:
    return "in_app" if settings.payments_enabled and k.payouts_ready and k.stripe_account_id else "at_pickup"


def next_drop(k: Kitchen, at: datetime) -> Drop | None:
    upcoming = [d for d in k.drops if d.ends_at > at]
    return min(upcoming, key=lambda d: d.starts_at) if upcoming else None


async def ratings(session: AsyncSession, kitchen_ids: list[uuid.UUID]) -> dict[uuid.UUID, tuple[float, int]]:
    if not kitchen_ids:
        return {}
    rows = await session.execute(
        select(Review.kitchen_id, func.avg(Review.stars), func.count())
        .where(Review.kitchen_id.in_(kitchen_ids))
        .group_by(Review.kitchen_id)
    )
    return {kid: (float(avg), int(n)) for kid, avg, n in rows}


def kitchen_out(
    k: Kitchen,
    viewer_id: uuid.UUID,
    rating: tuple[float, int] | None,
    distance: float | None = None,
    exact: bool = False,
) -> KitchenOut:
    """`exact`: the viewer may see where the house really is (its owner, or a confirmed buyer)."""
    d = next_drop(k, now())
    lat, lon = (k.lat, k.lon) if exact or k.owner_id == viewer_id else public_point(k)
    return KitchenOut(
        id=k.id,
        name=k.name,
        cook_name=k.owner.display_name,
        cuisine=k.cuisine,
        story=k.story,
        lat=lat,
        lon=lon,
        porch_tables=k.porch_tables,
        permitted=k.permit_confirmed and k.handler_card_confirmed,
        rating=rating[0] if rating else None,
        review_count=rating[1] if rating else 0,
        next_drop=drop_out(d) if d else None,
        is_mine=k.owner_id == viewer_id,
        distance_m=distance,
        photo_url=photo_url(d.photo_id) if d else None,
        pay=pay_mode(k),
    )


def order_out(o: Order, for_seller: bool = False) -> OrderOut:
    """The address, the exact spot and the pickup note only once it's confirmed."""
    shown = o.confirmed or for_seller
    d = o.drop
    return OrderOut(
        id=o.id,
        client_id=o.client_id,
        kitchen_id=o.kitchen_id,
        kitchen_name=o.kitchen.name,
        drop_id=o.drop_id,
        pickup_at=o.pickup_at,
        eat_on_porch=o.eat_on_porch,
        status=o.status,
        lines=[OrderLineOut.model_validate(line) for line in o.lines],
        subtotal_cents=o.subtotal_cents,
        service_cents=o.service_cents,
        total_cents=o.subtotal_cents + o.service_cents,
        pickup_note=o.kitchen.pickup_note if shown else "",
        payment=o.payment,
        pickup_code=o.pickup_code if shown else "",
        picked_up_at=o.picked_up_at,
        title=d.title,
        unit=d.unit,
        photo_url=photo_url(d.photo_id),
        pickup_spot=d.pickup_spot,
        address=o.kitchen.address if shown else None,
        lat=o.kitchen.lat if shown else None,
        lon=o.kitchen.lon if shown else None,
        buyer_name=o.buyer.display_name if for_seller else None,
    )
