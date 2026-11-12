"""Friends, crews, up for something, meet-ups and invites.

You become friends by accepting a one-use code someone gave you, or by both saying hi after three
check-ins together. What you're up for is seen by friends and people you've met; nobody else.
Where you are never leaves the server: others get a walk time, and only the person you matched
with gets even that, until Done.
"""

import secrets
import uuid
from datetime import datetime, timedelta

from fastapi import APIRouter, Depends, HTTPException, Query, Response
from sqlalchemy import delete, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app import upfor
from app.auth import current_user
from app.db import get_session
from app.geo import distance_m
from app.models import (
    Crew,
    CrewMember,
    FriendCode,
    Friendship,
    Gathering,
    GatheringInvite,
    GatheringMember,
    Intro,
    Meetup,
    PorchLight,
    User,
    Wave,
)
from app.schemas import (
    CrewCreate,
    CrewNext,
    CrewOut,
    FriendCodeAccept,
    FriendCodeOut,
    FriendOut,
    GatheringInviteOut,
    ImInIn,
    IntroOut,
    IntroResult,
    MeetupOut,
    MeetupUpdate,
    People,
    PersonOut,
    Point,
    PorchLightIn,
    PorchLightOut,
    SharedNight,
    SpotIn,
    SpotOut,
    UpForIn,
    UpForOut,
)
from app.social import INTRO_AFTER, are_friends, can_see, checked_in_with, friend_ids, met_ids, out_now
from app.social import say_hi as connect
from app.views import gathering_out, now

router = APIRouter(prefix="/v1", tags=["people"])

# No 0/O or 1/I/L, so a code read aloud comes out right.
CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
CODE_LENGTH = 8
CODE_DAYS = 7
WAVE_SHOWS_FOR = timedelta(hours=2)


def _normalize(code: str) -> str:
    return "".join(ch for ch in code.upper() if ch.isalnum())


def _walk(light: PorchLight, lat: float | None, lon: float | None) -> int | None:
    if lat is None or lon is None or light.lat is None or light.lon is None:
        return None
    return upfor.rough_minutes(distance_m(lat, lon, light.lat, light.lon))


def _porch_out(p: PorchLight, lat: float | None, lon: float | None) -> PorchLightOut:
    """For phones from before the rename: the same light, with a rounded distance and no coordinates."""
    d = None
    if lat is not None and lon is not None and p.lat is not None and p.lon is not None:
        d = float(round(distance_m(lat, lon, p.lat, p.lon) / 50) * 50)
    note = p.note or upfor.label(p.activity, "")
    return PorchLightOut(on_until=p.on_until, note=note, distance_m=d)


def _up_out(p: PorchLight, lat: float | None, lon: float | None) -> UpForOut:
    return UpForOut(
        activity=p.activity,
        label=upfor.label(p.activity, p.note),
        words=p.note,
        until=p.on_until,
        bubble=upfor.bubble(p.activity, p.note),
        walk_min=_walk(p, lat, lon),
    )


def _crew_out(c: Crew, viewer_id: uuid.UUID, next_up: CrewNext | None = None) -> CrewOut:
    return CrewOut(
        id=c.id,
        name=c.name,
        is_mine=c.owner_id == viewer_id,
        members=[PersonOut(id=m.user_id, display_name=m.user.display_name) for m in c.members],
        next=next_up,
    )


async def _crew_next(
    session: AsyncSession, crew: Crew, viewer_id: uuid.UUID, friends: set[uuid.UUID]
) -> CrewNext | None:
    """The soonest thing still to come that two or more of the crew joined, counting only the
    members the viewer already knows of (themselves and their friends)."""
    known = [m.user_id for m in crew.members if m.user_id == viewer_id or m.user_id in friends]
    if len(known) < 2:
        return None
    going = func.count(GatheringMember.user_id)
    row = (
        await session.execute(
            select(Gathering.id, Gathering.title, Gathering.starts_at, going)
            .join(GatheringMember, GatheringMember.gathering_id == Gathering.id)
            .where(
                GatheringMember.user_id.in_(known),
                Gathering.cancelled_at.is_(None),
                Gathering.ends_at > now(),
            )
            .group_by(Gathering.id)
            .having(going >= 2)
            .order_by(Gathering.starts_at)
            .limit(1)
        )
    ).first()
    if row is None:
        return None
    return CrewNext(gathering_id=row[0], title=row[1], starts_at=row[2], going=row[3])


# Friends


@router.post("/friends/code", response_model=FriendCodeOut, status_code=201)
async def make_code(user: User = Depends(current_user), session: AsyncSession = Depends(get_session)):
    code = "".join(secrets.choice(CODE_ALPHABET) for _ in range(CODE_LENGTH))
    row = FriendCode(code=code, from_id=user.id, expires_at=now() + timedelta(days=CODE_DAYS))
    session.add(row)
    await session.commit()
    return FriendCodeOut(code=code, expires_at=row.expires_at)


@router.post("/friends/accept", response_model=PersonOut)
async def accept_code(
    body: FriendCodeAccept, user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> PersonOut:
    row = await session.scalar(
        select(FriendCode).where(FriendCode.code == _normalize(body.code)).with_for_update(of=FriendCode)
    )
    if row is None or row.expires_at <= now():
        raise HTTPException(404, "That code didn't work. Codes last a week; ask for a fresh one.")
    if row.from_id == user.id:
        raise HTTPException(409, "That's your own code. Send it to a friend.")
    if row.used_by_id is not None and row.used_by_id != user.id:
        raise HTTPException(404, "That code's been used. Ask for a fresh one.")
    friend = PersonOut(id=row.from_id, display_name=row.sender.display_name)
    if not await are_friends(session, user.id, row.from_id):
        session.add_all(
            [
                Friendship(user_id=user.id, friend_id=row.from_id),
                Friendship(user_id=row.from_id, friend_id=user.id),
            ]
        )
    row.used_by_id = user.id
    row.used_at = row.used_at or now()
    await session.commit()
    return friend


@router.delete("/friends/{friend_id}", status_code=204)
async def unfriend(
    friend_id: uuid.UUID, user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> Response:
    await session.execute(
        delete(Friendship).where(
            ((Friendship.user_id == user.id) & (Friendship.friend_id == friend_id))
            | ((Friendship.user_id == friend_id) & (Friendship.friend_id == user.id))
        )
    )
    await session.commit()
    return Response(status_code=204)


@router.post("/friends/{friend_id}/wave", status_code=204)
async def wave(
    friend_id: uuid.UUID, user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> Response:
    if not await can_see(session, user.id, friend_id):
        raise HTTPException(404, "You can wave at friends and people you've met.")
    session.add(Wave(from_id=user.id, to_id=friend_id))
    await session.commit()
    return Response(status_code=204)


# Everything on the People tab, in one call


@router.get("/people", response_model=People)
async def people(
    lat: float | None = Query(default=None, ge=-90, le=90),
    lon: float | None = Query(default=None, ge=-180, le=180),
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> People:
    t = now()
    friendships = list(
        (await session.scalars(select(Friendship).where(Friendship.user_id == user.id))).unique()
    )
    ids = {f.friend_id for f in friendships}
    met = await met_ids(session, user.id, ids)

    lights = {
        p.user_id: p
        for p in await session.scalars(
            select(PorchLight).where(PorchLight.user_id.in_(ids | met | {user.id}), PorchLight.on_until > t)
        )
    }
    waves: dict[uuid.UUID, datetime] = {}
    if ids or met:
        for w in await session.scalars(
            select(Wave)
            .where(Wave.to_id == user.id, Wave.from_id.in_(ids | met), Wave.created_at > t - WAVE_SHOWS_FOR)
            .order_by(Wave.created_at)
        ):
            waves[w.from_id] = w.created_at
    out = await out_now(session, ids)

    friends = [
        FriendOut(
            id=f.friend_id,
            display_name=f.friend.display_name,
            porch_light=_porch_out(lights[f.friend_id], lat, lon) if f.friend_id in lights else None,
            up_for=_up_out(lights[f.friend_id], lat, lon) if f.friend_id in lights else None,
            out=out.get(f.friend_id),
            waved_at=waves.get(f.friend_id),
        )
        for f in sorted(friendships, key=lambda f: f.friend.display_name.lower())
    ]

    crew_ids = select(CrewMember.crew_id).where(CrewMember.user_id == user.id)
    crew_rows = await session.scalars(select(Crew).where(Crew.id.in_(crew_ids)).order_by(Crew.name))
    crews = [_crew_out(c, user.id, await _crew_next(session, c, user.id, ids)) for c in crew_rows.unique()]

    invites = []
    for inv, g in (
        await session.execute(
            select(GatheringInvite, Gathering)
            .join(Gathering, Gathering.id == GatheringInvite.gathering_id)
            .where(GatheringInvite.to_id == user.id, Gathering.cancelled_at.is_(None), Gathering.ends_at > t)
            .order_by(Gathering.starts_at)
        )
    ).unique():
        if any(m.user_id == user.id for m in g.members):
            continue
        invites.append(
            GatheringInviteOut(
                gathering=gathering_out(g, user.id, friend_ids=ids),
                sender=PersonOut(id=inv.from_id, display_name=inv.sender.display_name),
                created_at=inv.created_at,
            )
        )

    intros = await _intros(session, user.id, ids)
    for i in intros:
        if i.person.id in met:
            light = lights.get(i.person.id)
            i.up_for = _up_out(light, lat, lon) if light else None
            i.waved_at = waves.get(i.person.id)

    mine = lights.get(user.id)
    meetup = await _current_meetup(session, user.id)
    return People(
        porch_light=_porch_out(mine, None, None) if mine else None,
        up_for=_up_out(mine, None, None) if mine else None,
        friends=friends,
        crews=crews,
        invites=invites,
        intros=intros,
        meetup=_meetup_out(meetup, user.id) if meetup else None,
    )


async def _intros(session: AsyncSession, me: uuid.UUID, friends: set[uuid.UUID]) -> list[IntroOut]:
    together = {
        other: nights
        for other, nights in (await checked_in_with(session, me)).items()
        if len(nights) >= INTRO_AFTER and other not in friends
    }
    if not together:
        return []
    mine = {i.other_id: i for i in await session.scalars(select(Intro).where(Intro.user_id == me))}
    names = {u.id: u.display_name for u in await session.scalars(select(User).where(User.id.in_(together)))}
    out = []
    for other, nights in together.items():
        intro = mine.get(other)
        if intro is not None and intro.declined_at is not None:
            continue
        out.append(
            IntroOut(
                person=PersonOut(id=other, display_name=names.get(other, "Someone")),
                together=[SharedNight(title=t, starts_at=at) for t, at in nights[-5:]],
                said_hi=intro is not None and intro.said_hi_at is not None,
            )
        )
    return sorted(out, key=lambda i: -len(i.together))


async def _my_intro(session: AsyncSession, me: uuid.UUID, other: uuid.UUID) -> Intro:
    if len((await checked_in_with(session, me)).get(other, [])) < INTRO_AFTER:
        raise HTTPException(404, "Not yet. Three real check-ins together first.")
    intro = await session.get(Intro, (me, other))
    if intro is None:
        intro = Intro(user_id=me, other_id=other)
        session.add(intro)
    return intro


@router.post("/intros/{other_id}/hi", response_model=IntroResult)
async def say_hi(
    other_id: uuid.UUID, user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> IntroResult:
    """Say hi. If they already did, you're friends now; if not, they hear nothing until they do."""
    if not await are_friends(session, user.id, other_id):
        await _my_intro(session, user.id, other_id)  # three check-ins together first
    return IntroResult(connected=await connect(session, user.id, other_id))


@router.post("/intros/{other_id}/not-now", status_code=204)
async def not_now(
    other_id: uuid.UUID, user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> Response:
    intro = await _my_intro(session, user.id, other_id)
    intro.declined_at = now()
    intro.said_hi_at = None
    await session.commit()
    return Response(status_code=204)


# Up for something (the porch light, renamed; the old routes still work)


async def _set_up_for(session: AsyncSession, user: User, body: UpForIn) -> PorchLight:
    light = await session.get(PorchLight, user.id)
    until = now() + timedelta(hours=body.hours)
    if light is None:
        light = PorchLight(user_id=user.id, on_until=until)
        session.add(light)
    light.on_until = until
    light.activity = body.activity
    light.note = body.words.strip()
    light.lat, light.lon = body.lat, body.lon
    await session.commit()
    return light


@router.put("/me/up-for", response_model=UpForOut)
async def up_for_on(
    body: UpForIn, user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> UpForOut:
    if not body.activity and not body.words.strip():
        raise HTTPException(422, "Say what you're up for: pick one, or put it in your own words.")
    return _up_out(await _set_up_for(session, user, body), None, None)


@router.put("/me/porch-light", response_model=PorchLightOut)
async def porch_light_on(
    body: PorchLightIn, user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> PorchLightOut:
    light = await _set_up_for(
        session, user, UpForIn(words=body.note, hours=body.hours, lat=body.lat, lon=body.lon)
    )
    return _porch_out(light, None, None)


@router.delete("/me/up-for", status_code=204)
@router.delete("/me/porch-light", status_code=204)
async def up_for_off(user: User = Depends(current_user), session: AsyncSession = Depends(get_session)):
    await session.execute(delete(PorchLight).where(PorchLight.user_id == user.id))
    await session.commit()
    return Response(status_code=204)


# Meet-ups: someone's in


def _first(name: str) -> str:
    return name.split(" ")[0] if name.strip() else name


def _active(t: datetime):
    return (Meetup.done_at.is_(None)) & (Meetup.ends_at > t)


async def _current_meetup(session: AsyncSession, me: uuid.UUID) -> Meetup | None:
    return await session.scalar(
        select(Meetup)
        .where(or_(Meetup.host_id == me, Meetup.guest_id == me), _active(now()))
        .order_by(Meetup.created_at.desc())
        .limit(1)
    )


def _sides(m: Meetup, me: uuid.UUID):
    """(mine, theirs) as (lat, lon, on_way_at, says) each."""
    host = (m.host_lat, m.host_lon, m.host_on_way_at, m.host_says)
    guest = (m.guest_lat, m.guest_lon, m.guest_on_way_at, m.guest_says)
    return (host, guest) if m.host_id == me else (guest, host)


def _point(lat: float | None, lon: float | None) -> tuple[float, float] | None:
    return (lat, lon) if lat is not None and lon is not None else None


def _target(m: Meetup) -> tuple[float, float] | None:
    """Where you're walking to: the spot, or halfway until there is one."""
    if m.spot_lat is not None and m.spot_lon is not None:
        return m.spot_lat, m.spot_lon
    a, b = _point(m.host_lat, m.host_lon), _point(m.guest_lat, m.guest_lon)
    return upfor.halfway(a, b) if a and b else None


def _minutes_to(m: Meetup, lat: float | None, lon: float | None) -> int | None:
    target, at = _target(m), _point(lat, lon)
    if target is None or at is None:
        return None
    return upfor.walk_minutes(distance_m(at[0], at[1], target[0], target[1]))


def _meetup_out(m: Meetup, me: uuid.UUID) -> MeetupOut:
    mine, theirs = _sides(m, me)
    other = m.guest if m.host_id == me else m.host
    a, b = _point(m.host_lat, m.host_lon), _point(m.guest_lat, m.guest_lon)
    area = upfor.rough_area(upfor.halfway(a, b)) if a and b else None
    return MeetupOut(
        id=m.id,
        other=PersonOut(id=other.id, display_name=other.display_name),
        is_mine=m.host_id == me,
        activity=m.activity,
        label=upfor.label(m.activity, m.words),
        headline=upfor.headline(m.activity, m.words, _first(other.display_name)),
        spot=SpotOut(name=m.spot_name, lat=m.spot_lat, lon=m.spot_lon)
        if m.spot_name and m.spot_lat is not None and m.spot_lon is not None
        else None,
        area=Point(lat=area[0], lon=area[1]) if area else None,
        meet_at=m.meet_at,
        ends_at=m.ends_at,
        my_walk_min=_minutes_to(m, mine[0], mine[1]),
        their_walk_min=_minutes_to(m, theirs[0], theirs[1]),
        i_am_on_my_way=mine[2] is not None,
        they_are_on_their_way=theirs[2] is not None,
        they_say=theirs[3],
    )


def _retime(m: Meetup) -> None:
    """Meet once the longer walk's done, but never earlier than already said."""
    t = now()
    walks = [_minutes_to(m, m.host_lat, m.host_lon), _minutes_to(m, m.guest_lat, m.guest_lon)]
    m.meet_at = max(m.meet_at, upfor.meet_at(t, [w for w in walks if w is not None]))


@router.post("/up-for/{other_id}/in", response_model=MeetupOut, status_code=201)
async def im_in(
    other_id: uuid.UUID,
    body: ImInIn,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> MeetupOut:
    """I'm in: you and them, meeting about halfway. Their "up for" turns off; they're busy now."""
    t = now()
    if not await can_see(session, user.id, other_id):
        raise HTTPException(404, "They're not up for anything you can see.")
    light = await session.scalar(
        select(PorchLight).where(PorchLight.user_id == other_id, PorchLight.on_until > t).with_for_update()
    )
    if light is None:
        raise HTTPException(409, "They're not up for anything right now.")
    busy = await session.scalar(
        select(Meetup.id).where(
            or_(Meetup.host_id.in_([user.id, other_id]), Meetup.guest_id.in_([user.id, other_id])), _active(t)
        )
    )
    if busy is not None:
        raise HTTPException(409, "One of you is already meeting someone. Finish that one first.")
    m = Meetup(
        host_id=other_id,
        guest_id=user.id,
        activity=light.activity,
        words=light.note,
        host_lat=light.lat,
        host_lon=light.lon,
        guest_lat=body.lat,
        guest_lon=body.lon,
        meet_at=upfor.meet_at(t, []),
        ends_at=t + upfor.MATCH_LASTS,
    )
    walks = [_minutes_to(m, light.lat, light.lon), _minutes_to(m, body.lat, body.lon)]
    m.meet_at = upfor.meet_at(t, [w for w in walks if w is not None])
    session.add(m)
    await session.execute(delete(PorchLight).where(PorchLight.user_id.in_([other_id, user.id])))
    await session.commit()
    m = await session.scalar(
        select(Meetup).where(Meetup.id == m.id).execution_options(populate_existing=True)
    )
    return _meetup_out(m, user.id)


async def _my_meetup(session: AsyncSession, meetup_id: uuid.UUID, me: uuid.UUID) -> Meetup:
    m = await session.scalar(select(Meetup).where(Meetup.id == meetup_id).with_for_update(of=Meetup))
    if m is None or me not in (m.host_id, m.guest_id) or m.done_at is not None or m.ends_at <= now():
        raise HTTPException(404, "That meet-up's over.")
    return m


@router.get("/meetups/current", response_model=MeetupOut | None)
async def current_meetup(
    user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> MeetupOut | None:
    m = await _current_meetup(session, user.id)
    return _meetup_out(m, user.id) if m else None


@router.patch("/meetups/{meetup_id}", response_model=MeetupOut)
async def update_meetup(
    meetup_id: uuid.UUID,
    body: MeetupUpdate,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> MeetupOut:
    """Where you are now (for the walk times), On my way, or a short reply."""
    m = await _my_meetup(session, meetup_id, user.id)
    host = m.host_id == user.id
    if body.lat is not None and body.lon is not None:
        if host:
            m.host_lat, m.host_lon = body.lat, body.lon
        else:
            m.guest_lat, m.guest_lon = body.lat, body.lon
    if body.on_my_way is not None:
        at = now() if body.on_my_way else None
        if host:
            m.host_on_way_at = at
        else:
            m.guest_on_way_at = at
    if body.says is not None:
        if host:
            m.host_says = body.says.strip()
        else:
            m.guest_says = body.says.strip()
    _retime(m)
    await session.commit()
    return _meetup_out(m, user.id)


@router.put("/meetups/{meetup_id}/spot", response_model=MeetupOut)
async def set_spot(
    meetup_id: uuid.UUID,
    body: SpotIn,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> MeetupOut:
    """A real public place about halfway (a park entrance, a café), found on the phone."""
    m = await _my_meetup(session, meetup_id, user.id)
    host, guest = _point(m.host_lat, m.host_lon), _point(m.guest_lat, m.guest_lon)
    if not upfor.spot_ok((body.lat, body.lon), host, guest):
        raise HTTPException(422, "That's not about halfway. Pick somewhere you can both walk to.")
    m.spot_name, m.spot_lat, m.spot_lon = body.name.strip(), body.lat, body.lon
    _retime(m)
    await session.commit()
    return _meetup_out(m, user.id)


@router.post("/meetups/{meetup_id}/done", status_code=204)
async def meetup_done(
    meetup_id: uuid.UUID, user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> Response:
    """Either of you ends it. Where you both were is wiped."""
    m = await session.scalar(select(Meetup).where(Meetup.id == meetup_id).with_for_update(of=Meetup))
    if m is None or user.id not in (m.host_id, m.guest_id):
        raise HTTPException(404, "That meet-up's over.")
    m.done_at = m.done_at or now()
    m.host_lat = m.host_lon = m.guest_lat = m.guest_lon = None
    await session.commit()
    return Response(status_code=204)


# Crews


@router.post("/crews", response_model=CrewOut, status_code=201)
async def make_crew(
    body: CrewCreate, user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> CrewOut:
    wanted = set(body.member_ids) - {user.id}
    if not wanted <= await friend_ids(session, user.id):
        raise HTTPException(422, "Only friends can be in a crew")
    crew = Crew(owner_id=user.id, name=body.name.strip())
    crew.members = [CrewMember(user_id=uid) for uid in [user.id, *sorted(wanted)]]
    session.add(crew)
    await session.commit()
    crew = await session.scalar(
        select(Crew).where(Crew.id == crew.id).execution_options(populate_existing=True)
    )
    return _crew_out(crew, user.id)


@router.delete("/crews/{crew_id}", status_code=204)
async def leave_crew(
    crew_id: uuid.UUID, user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> Response:
    """The owner deletes the crew; anyone else leaves it."""
    crew = await session.get(Crew, crew_id)
    if crew is None or not any(m.user_id == user.id for m in crew.members):
        raise HTTPException(404, "Crew not found")
    if crew.owner_id == user.id:
        await session.delete(crew)
    else:
        await session.execute(
            delete(CrewMember).where(CrewMember.crew_id == crew_id, CrewMember.user_id == user.id)
        )
    await session.commit()
    return Response(status_code=204)
