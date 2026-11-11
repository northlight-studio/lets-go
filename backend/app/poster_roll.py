"""Weekly posters move on: once a weekly gathering with a poster has ended, the poster points at next
week's, a fresh gathering with only the host in. Done when someone scans it, and every quarter hour
from the scheduler so next week's shows up on the map even if nobody has."""

import logging
import uuid
from datetime import datetime

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app import poster as P
from app.models import Gathering, GatheringMember, Poster

log = logging.getLogger("letsgo.posters")


def needs_roll(p: Poster, t: datetime) -> bool:
    g = p.gathering
    return p.retired_at is None and g.ends_at <= t and P.is_weekly(g.recurring)


async def roll_forward(session: AsyncSession, poster_id: uuid.UUID, t: datetime) -> None:
    # Lock the poster so two scans at once don't both make next week's; then look again.
    p = await session.scalar(
        select(Poster)
        .where(Poster.id == poster_id)
        .with_for_update(of=Poster)
        .execution_options(populate_existing=True)
    )
    g = await session.get(Gathering, p.gathering_id, populate_existing=True)
    if p.retired_at is None and g.ends_at <= t and P.is_weekly(g.recurring):
        starts, ends = P.next_week(g.starts_at, g.ends_at, p.tz, t)
        nxt = Gathering(
            host_id=g.host_id,
            title=g.title,
            genre=g.genre,
            details=g.details,
            place_name=g.place_name,
            lat=g.lat,
            lon=g.lon,
            starts_at=starts,
            ends_at=ends,
            capacity=g.capacity,
            bring=g.bring,
            recurring=g.recurring,
        )
        nxt.members = [GatheringMember(user_id=g.host_id)]
        session.add(nxt)
        await session.flush()
        p.gathering_id = nxt.id
    await session.commit()


async def roll_due(session: AsyncSession, t: datetime) -> int:
    """Every weekly poster whose gathering has ended. Returns how many moved on."""
    ids = list(
        await session.scalars(
            select(Poster.id)
            .join(Gathering, Gathering.id == Poster.gathering_id)
            .where(Poster.retired_at.is_(None), Gathering.ends_at <= t, Gathering.recurring.ilike("every %"))
        )
    )
    moved = 0
    for pid in ids:
        p = await session.get(Poster, pid)
        if p is not None and needs_roll(p, t):
            await roll_forward(session, pid, t)
            moved += 1
    if moved:
        log.info("moved %d weekly posters on to next week", moved)
    return moved
