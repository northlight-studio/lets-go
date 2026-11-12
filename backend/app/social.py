"""Who your friends are, and what of theirs you're allowed to see."""

import uuid
from datetime import datetime, timedelta

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import aliased

from app.models import Friendship, Gathering, GatheringMember, Intro
from app.schemas import OutNow
from app.views import now

# How soon a joined gathering has to start for a friend to count as heading there.
HEADING_WINDOW = timedelta(minutes=90)


async def friend_ids(session: AsyncSession, user_id: uuid.UUID) -> set[uuid.UUID]:
    rows = await session.scalars(select(Friendship.friend_id).where(Friendship.user_id == user_id))
    return set(rows)


async def are_friends(session: AsyncSession, a: uuid.UUID, b: uuid.UUID) -> bool:
    return await session.get(Friendship, (a, b)) is not None


async def out_now(session: AsyncSession, ids: set[uuid.UUID]) -> dict[uuid.UUID, OutNow]:
    """For each friend: the gathering they're checked in to, or else the one they joined that starts
    soonest within the next 90 minutes. Only gatherings they joined count; nobody is tracked."""
    if not ids:
        return {}
    t = now()
    rows = await session.execute(
        select(GatheringMember, Gathering)
        .join(Gathering, Gathering.id == GatheringMember.gathering_id)
        .where(
            GatheringMember.user_id.in_(ids),
            Gathering.cancelled_at.is_(None),
            Gathering.ends_at > t,
            Gathering.starts_at < t + HEADING_WINDOW,
        )
        .order_by(Gathering.starts_at)
    )
    found: dict[uuid.UUID, OutNow] = {}
    for member, g in rows.unique():
        there = member.checked_in_at is not None and g.starts_at - timedelta(minutes=30) <= t
        current = found.get(member.user_id)
        if current is not None and (current.state == "there" or not there):
            continue
        found[member.user_id] = OutNow(
            gathering_id=g.id,
            title=g.title,
            place_name=g.place_name,
            starts_at=g.starts_at,
            ends_at=g.ends_at,
            state="there" if there else "heading",
            lat=g.lat,
            lon=g.lon,
        )
    return found


# Three real check-ins at the same things, and Wren offers an intro.
INTRO_AFTER = 3


async def checked_in_with(
    session: AsyncSession, user_id: uuid.UUID
) -> dict[uuid.UUID, list[tuple[str, datetime]]]:
    """Everyone who checked in to the same gatherings as you, with the (title, start) of each one."""
    mine = aliased(GatheringMember)
    theirs = aliased(GatheringMember)
    rows = await session.execute(
        select(theirs.user_id, Gathering.title, Gathering.starts_at)
        .join(mine, mine.gathering_id == theirs.gathering_id)
        .join(Gathering, Gathering.id == theirs.gathering_id)
        .where(
            mine.user_id == user_id,
            mine.checked_in_at.is_not(None),
            theirs.user_id != user_id,
            theirs.checked_in_at.is_not(None),
        )
        .order_by(Gathering.starts_at)
    )
    out: dict[uuid.UUID, list[tuple[str, datetime]]] = {}
    for other, title, starts_at in rows:
        out.setdefault(other, []).append((title, starts_at))
    return out


async def met_ids(
    session: AsyncSession, me: uuid.UUID, friends: set[uuid.UUID] | None = None
) -> set[uuid.UUID]:
    """People you've met: three real check-ins at the same things, not friends yet, and neither of
    you has said not now. They see what you're up for, and you theirs; nobody else does."""
    if friends is None:
        friends = await friend_ids(session, me)
    met = {
        other
        for other, nights in (await checked_in_with(session, me)).items()
        if len(nights) >= INTRO_AFTER and other not in friends
    }
    if not met:
        return set()
    declined = await session.execute(
        select(Intro.user_id, Intro.other_id).where(
            Intro.declined_at.is_not(None),
            ((Intro.user_id == me) & Intro.other_id.in_(met))
            | ((Intro.other_id == me) & Intro.user_id.in_(met)),
        )
    )
    for a, b in declined:
        met.discard(b if a == me else a)
    return met


async def can_see(session: AsyncSession, viewer: uuid.UUID, other: uuid.UUID) -> bool:
    """Whether viewer may see what other is up for: friends, or people who've met."""
    if viewer == other:
        return False
    if await are_friends(session, viewer, other):
        return True
    return other in await met_ids(session, viewer)
