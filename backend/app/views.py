"""Model → response shapes that depend on who's asking."""

import uuid
from datetime import UTC, datetime

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

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


def drop_out(d: Drop) -> DropOut:
    return DropOut(
        id=d.id,
        starts_at=d.starts_at,
        ends_at=d.ends_at,
        total=d.total,
        sold=d.sold,
        per_slot=d.per_slot,
        left=max(0, d.total - d.sold),
    )


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
    k: Kitchen, viewer_id: uuid.UUID, rating: tuple[float, int] | None, distance: float | None = None
) -> KitchenOut:
    d = next_drop(k, now())
    return KitchenOut(
        id=k.id,
        name=k.name,
        cook_name=k.owner.display_name,
        cuisine=k.cuisine,
        story=k.story,
        lat=k.lat,
        lon=k.lon,
        porch_tables=k.porch_tables,
        permitted=k.permit_confirmed and k.handler_card_confirmed,
        rating=rating[0] if rating else None,
        review_count=rating[1] if rating else 0,
        next_drop=drop_out(d) if d else None,
        is_mine=k.owner_id == viewer_id,
        distance_m=distance,
    )


def order_out(o: Order) -> OrderOut:
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
        pickup_note=o.kitchen.pickup_note,
    )
