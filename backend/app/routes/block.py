"""Your block: what's going on within a few blocks, as one short list that ends.

Built from what's already there: batches neighbors posted, kitchens you follow, what people nearby
are going to, people you've met to say hi to, and friends up for something now. `app.block` ranks.
Privacy: a name only for a friend, someone you've met, or a kitchen's own public name; anyone else
is a count. Kitchens are measured to where they show on the map, never to the house.
"""

import uuid
from datetime import datetime

from fastapi import APIRouter, Depends, Query
from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app import block, upfor
from app.auth import current_user
from app.db import get_session
from app.geo import bbox, distance_m
from app.models import Drop, Follow, Gathering, Intro, Kitchen, PorchLight, User
from app.schemas import BlockItemOut, BlockOut
from app.social import checked_in_with, friend_ids, met_ids
from app.views import now, photo_url, public_point

router = APIRouter(prefix="/v1", tags=["block"])

Here = tuple[float, float] | None


def _first(name: str) -> str:
    return name.split(" ")[0] if name.strip() else name


def _walk(here: Here, lat: float | None, lon: float | None) -> int | None:
    if here is None or lat is None or lon is None:
        return None
    return upfor.rough_minutes(distance_m(here[0], here[1], lat, lon))


def _near(here: Here, lat: float, lon: float) -> bool:
    return here is not None and distance_m(here[0], here[1], lat, lon) <= block.RADIUS_M


async def _batches(session: AsyncSession, me: uuid.UUID, here: Here, t: datetime) -> list[block.Candidate]:
    """Open batches a few blocks away, and the next batch of every kitchen you follow, wherever."""
    followed = set(await session.scalars(select(Follow.kitchen_id).where(Follow.user_id == me)))
    where = [Kitchen.id.in_(followed)] if followed else []
    if here is not None:
        # A little wider than the radius: kitchens show up to 150 m off the house.
        min_lat, max_lat, min_lon, max_lon = bbox(here[0], here[1], block.RADIUS_M + 200)
        where.append(Kitchen.lat.between(min_lat, max_lat) & Kitchen.lon.between(min_lon, max_lon))
    if not where:
        return []
    rows = await session.execute(
        select(Drop, Kitchen)
        .join(Kitchen, Kitchen.id == Drop.kitchen_id)
        .where(
            or_(*where),
            Kitchen.owner_id != me,
            Drop.ends_at > t,
            Drop.starts_at < t + block.FOLLOW_AHEAD,
            Drop.sold < Drop.total,
        )
    )
    out = []
    for d, k in rows.unique():
        lat, lon = public_point(k)
        follows = k.id in followed
        if not follows and not (_near(here, lat, lon) and d.starts_at < t + block.AHEAD):
            continue
        out.append(
            block.Candidate(
                key=f"batch:{d.id}",
                kind="back" if follows else "batch",
                subject=f"kitchen:{k.id}",
                posted_at=d.created_at,
                at=d.starts_at,
                ends_at=d.ends_at,
                walk_min=_walk(here, lat, lon),
                payload=dict(
                    id=d.id,
                    kitchen_id=k.id,
                    title=d.title or (d.item.name if d.item else ""),
                    name=k.name,
                    left=max(0, d.total - d.sold),
                    unit=d.unit,
                    price_cents=d.item.price_cents if d.item else None,
                    starts_at=d.starts_at,
                    ends_at=d.ends_at,
                    posted_at=d.created_at,
                    photo_url=photo_url(d.photo_id),
                ),
            )
        )
    return out


async def _suppers(session: AsyncSession, me: uuid.UUID, here: Here, t: datetime) -> list[block.Candidate]:
    """A supper nearby with seats left. Suppers are being built separately; once their table and
    route land, this returns them as kind "supper" (title, name = the host kitchen's public name,
    seats_left, price_cents, starts_at, walk_min) and the phone already knows how to show them."""
    return []


async def _going(
    session: AsyncSession, me: uuid.UUID, friends: set[uuid.UUID], here: Here, t: datetime
) -> list[block.Candidate]:
    """What people a few blocks away are going to. Friends by first name; anyone else as a count,
    and only once there are a few, so a count never points at one person."""
    if here is None:
        return []
    min_lat, max_lat, min_lon, max_lon = bbox(here[0], here[1], block.RADIUS_M)
    gs = await session.scalars(
        select(Gathering).where(
            Gathering.lat.between(min_lat, max_lat),
            Gathering.lon.between(min_lon, max_lon),
            Gathering.cancelled_at.is_(None),
            Gathering.ends_at > t,
            Gathering.starts_at < t + block.AHEAD,
            Gathering.host_id != me,
        )
    )
    out = []
    for g in gs.unique():
        if not _near(here, g.lat, g.lon) or any(m.user_id == me for m in g.members):
            continue
        mates = sorted((m for m in g.members if m.user_id in friends), key=lambda m: m.joined_at)
        others = len(g.members) - len(mates) + len(g.web_guests)
        if not mates and others < block.MIN_COUNT:
            continue
        out.append(
            block.Candidate(
                key=f"going:{g.id}",
                kind="going",
                subject=f"gathering:{g.id}",
                posted_at=max([g.created_at, *(m.joined_at for m in mates)]),
                at=g.starts_at,
                ends_at=g.ends_at,
                walk_min=_walk(here, g.lat, g.lon),
                friend=bool(mates),
                payload=dict(
                    id=g.id,
                    title=g.title,
                    friends=[_first(m.user.display_name) for m in mates],
                    count=others,
                    place_name=g.place_name,
                    starts_at=g.starts_at,
                    ends_at=g.ends_at,
                ),
            )
        )
    return out


async def _neighbors(
    session: AsyncSession, me: uuid.UUID, met: set[uuid.UUID], t: datetime
) -> list[block.Candidate]:
    """People you've met (three real check-ins together, neither said not now) you haven't said hi
    to yet. Nobody else: a stranger never shows here."""
    if not met:
        return []
    said = set(
        await session.scalars(
            select(Intro.other_id).where(
                Intro.user_id == me, Intro.other_id.in_(met), Intro.said_hi_at.is_not(None)
            )
        )
    )
    todo = met - said
    if not todo:
        return []
    nights = await checked_in_with(session, me)
    names = {u.id: u.display_name for u in await session.scalars(select(User).where(User.id.in_(todo)))}
    return [
        block.Candidate(
            key=f"neighbor:{uid}",
            kind="neighbor",
            subject=f"person:{uid}",
            posted_at=max(at for _, at in nights[uid]) if nights.get(uid) else None,
            payload=dict(id=uid, name=names.get(uid, "Someone"), together=len(nights.get(uid, []))),
        )
        for uid in todo
    ]


async def _up_for(
    session: AsyncSession, friends: set[uuid.UUID], met: set[uuid.UUID], here: Here, t: datetime
) -> list[block.Candidate]:
    """Friends (and people you've met) up for something right now, with a walk time, never where."""
    ids = friends | met
    if not ids:
        return []
    lights = await session.scalars(
        select(PorchLight).where(PorchLight.user_id.in_(ids), PorchLight.on_until > t)
    )
    lights = list(lights)
    names = {
        u.id: u.display_name
        for u in await session.scalars(select(User).where(User.id.in_([p.user_id for p in lights])))
    }
    return [
        block.Candidate(
            key=f"up_for:{p.user_id}:{int(p.created_at.timestamp())}",
            kind="up_for",
            subject=f"person:{p.user_id}",
            posted_at=p.created_at,
            at=t,
            ends_at=p.on_until,
            walk_min=_walk(here, p.lat, p.lon),
            friend=p.user_id in friends,
            payload=dict(
                id=p.user_id,
                name=names.get(p.user_id, "Someone"),
                title=upfor.label(p.activity, p.note),
                ends_at=p.on_until,
                posted_at=p.created_at,
            ),
        )
        for p in lights
    ]


@router.get("/me/block", response_model=BlockOut)
async def your_block(
    lat: float | None = Query(default=None, ge=-90, le=90),
    lon: float | None = Query(default=None, ge=-180, le=180),
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> BlockOut:
    """The short list for around (lat, lon), best first. Without a location, only what doesn't need
    one: kitchens you follow, people you've met, friends up for something."""
    t = now()
    here = (lat, lon) if lat is not None and lon is not None else None
    friends = await friend_ids(session, user.id)
    met = await met_ids(session, user.id, friends)
    candidates = [
        *await _batches(session, user.id, here, t),
        *await _suppers(session, user.id, here, t),
        *await _going(session, user.id, friends, here, t),
        *await _neighbors(session, user.id, met, t),
        *await _up_for(session, friends, met, here, t),
    ]
    items = [
        BlockItemOut(key=c.key, kind=c.kind, walk_min=c.walk_min, **c.payload)
        for c in block.rank(candidates, t)
    ]
    return BlockOut(items=items, radius_m=block.RADIUS_M)
