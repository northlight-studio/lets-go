import uuid
from datetime import timedelta

from fastapi import APIRouter, Depends, HTTPException, Query, Response
from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import current_user
from app.config import settings
from app.db import get_session
from app.geo import bbox, distance_m
from app.models import Gathering, GatheringInvite, GatheringMember, Kitchen, User
from app.schemas import CheckIn, GatheringCreate, GatheringOut, Invited, InviteFriends, Nearby
from app.social import friend_ids
from app.views import gathering_out, kitchen_out, now, ratings

router = APIRouter(prefix="/v1", tags=["gatherings"])


async def _get(session: AsyncSession, gathering_id: uuid.UUID) -> Gathering:
    g = await session.get(Gathering, gathering_id)
    if g is None or g.cancelled_at is not None:
        raise HTTPException(404, "Gathering not found")
    return g


@router.get("/nearby", response_model=Nearby)
async def nearby(
    lat: float = Query(ge=-90, le=90),
    lon: float = Query(ge=-180, le=180),
    radius_m: float = Query(default=settings.nearby_radius_m, gt=0, le=20_000),
    hours: float = Query(default=36, gt=0, le=24 * 14),
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> Nearby:
    """Everything within `radius_m` that hasn't ended and starts within `hours`."""
    t = now()
    min_lat, max_lat, min_lon, max_lon = bbox(lat, lon, radius_m)
    gs = await session.scalars(
        select(Gathering)
        .where(
            Gathering.lat.between(min_lat, max_lat),
            Gathering.lon.between(min_lon, max_lon),
            Gathering.cancelled_at.is_(None),
            Gathering.ends_at > t,
            Gathering.starts_at < t + timedelta(hours=hours),
        )
        .order_by(Gathering.starts_at)
    )
    friends = await friend_ids(session, user.id)
    gatherings = []
    for g in gs.unique():
        d = distance_m(lat, lon, g.lat, g.lon)
        if d <= radius_m:
            gatherings.append(gathering_out(g, user.id, d, friends))

    ks = list(
        (
            await session.scalars(
                select(Kitchen).where(
                    Kitchen.lat.between(min_lat, max_lat), Kitchen.lon.between(min_lon, max_lon)
                )
            )
        ).unique()
    )
    rated = await ratings(session, [k.id for k in ks])
    kitchens = []
    for k in ks:
        d = distance_m(lat, lon, k.lat, k.lon)
        if d <= radius_m:
            kitchens.append(kitchen_out(k, user.id, rated.get(k.id), d))
    return Nearby(gatherings=gatherings, kitchens=kitchens)


@router.post("/gatherings", response_model=GatheringOut, status_code=201)
async def create_gathering(
    body: GatheringCreate, user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> GatheringOut:
    if body.ends_at <= now():
        raise HTTPException(422, "That gathering has already ended")
    g = Gathering(host_id=user.id, **body.model_dump())
    g.members = [GatheringMember(user_id=user.id)]
    session.add(g)
    await session.commit()
    g = await _get(session, g.id)
    await session.refresh(g, ["web_guests"])
    return gathering_out(g, user.id, friend_ids=await friend_ids(session, user.id))


@router.get("/gatherings/{gathering_id}", response_model=GatheringOut)
async def get_gathering(
    gathering_id: uuid.UUID, user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> GatheringOut:
    g = await _get(session, gathering_id)
    return gathering_out(g, user.id, friend_ids=await friend_ids(session, user.id))


@router.delete("/gatherings/{gathering_id}", status_code=204)
async def cancel_gathering(
    gathering_id: uuid.UUID, user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> Response:
    g = await _get(session, gathering_id)
    if g.host_id != user.id:
        raise HTTPException(403, "Only the host can cancel")
    g.cancelled_at = now()
    await session.commit()
    return Response(status_code=204)


@router.post("/gatherings/{gathering_id}/join", response_model=GatheringOut)
async def join(
    gathering_id: uuid.UUID, user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> GatheringOut:
    # Lock the row so two people can't take the last spot at once.
    g = await session.scalar(
        select(Gathering)
        .where(Gathering.id == gathering_id, Gathering.cancelled_at.is_(None))
        .with_for_update(of=Gathering)
    )
    if g is None:
        raise HTTPException(404, "Gathering not found")
    await session.refresh(g, ["members", "web_guests"])
    if any(m.user_id == user.id for m in g.members):
        return gathering_out(g, user.id, friend_ids=await friend_ids(session, user.id))
    if g.ends_at <= now():
        raise HTTPException(409, "It's over")
    if g.capacity and g.going >= g.capacity:
        raise HTTPException(409, "It's full")
    session.add(GatheringMember(gathering_id=g.id, user_id=user.id))
    await session.commit()
    await session.refresh(g, ["members"])
    return gathering_out(g, user.id, friend_ids=await friend_ids(session, user.id))


@router.delete("/gatherings/{gathering_id}/join", response_model=GatheringOut)
async def leave(
    gathering_id: uuid.UUID, user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> GatheringOut:
    g = await _get(session, gathering_id)
    if g.host_id == user.id:
        raise HTTPException(409, "Hosts cancel instead of leaving")
    member = await session.get(GatheringMember, (g.id, user.id))
    if member is not None:
        await session.delete(member)
        await session.commit()
        await session.refresh(g, ["members"])
    return gathering_out(g, user.id, friend_ids=await friend_ids(session, user.id))


@router.post("/gatherings/{gathering_id}/check-in", response_model=GatheringOut)
async def check_in(
    gathering_id: uuid.UUID,
    body: CheckIn,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> GatheringOut:
    """Only counts in person: within the check-in radius, from 30 min before the start until the end."""
    g = await _get(session, gathering_id)
    t = now()
    if not (g.starts_at - timedelta(minutes=settings.check_in_early_min) <= t < g.ends_at):
        raise HTTPException(409, "Check-in isn't open right now")
    away = distance_m(body.lat, body.lon, g.lat, g.lon)
    if away > settings.check_in_radius_m:
        raise HTTPException(
            409, f"You're {round(away)} m away; get within {round(settings.check_in_radius_m)} m"
        )
    member = await session.get(GatheringMember, (g.id, user.id))
    if member is None:
        if g.capacity and g.going >= g.capacity:
            raise HTTPException(409, "It's full")
        member = GatheringMember(gathering_id=g.id, user_id=user.id)
        session.add(member)
    if member.checked_in_at is None:
        member.checked_in_at = t
    await session.commit()
    await session.refresh(g, ["members"])
    return gathering_out(g, user.id, friend_ids=await friend_ids(session, user.id))


@router.post("/gatherings/{gathering_id}/invites", response_model=Invited)
async def invite(
    gathering_id: uuid.UUID,
    body: InviteFriends,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> Invited:
    """Ask friends along. Only friends; asking twice is a no-op."""
    g = await _get(session, gathering_id)
    if g.ends_at <= now():
        raise HTTPException(409, "It's over")
    friends = await friend_ids(session, user.id)
    wanted = set(body.user_ids) - {user.id}
    if not wanted <= friends:
        raise HTTPException(422, "You can only invite friends")
    already = {m.user_id for m in g.members}
    rows = [{"gathering_id": g.id, "to_id": uid, "from_id": user.id} for uid in wanted - already]
    if not rows:
        return Invited(invited=0)
    added = await session.scalars(
        insert(GatheringInvite).values(rows).on_conflict_do_nothing().returning(GatheringInvite.to_id)
    )
    count = len(list(added))
    await session.commit()
    return Invited(invited=count)
