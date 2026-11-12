"""Supper club: dinner for a few neighbors at the host's place, at a set price a seat that covers the
food. Neighbors ask for a seat, the host says yes or no, and the address goes only to guests the host
said yes to (once paid, or paying at the door). Paid in the app through the same Stripe path as
batches (`app/payments.py`, the host's kitchen's Connect account and the same service fee), at the
door when the host can't take payments. Reviews both ways after, and adding each other as friends.

`GET /v1/suppers?lat&lon` is the public list (what the map and Your block read)."""

import logging
import uuid
from datetime import datetime, timedelta

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app import payments
from app.auth import current_user
from app.config import settings
from app.db import get_session
from app.geo import bbox, distance_m
from app.models import Intro, Kitchen, Supper, SupperReview, SupperSeat, User
from app.pricing import service_fee
from app.routes.batches import home_kitchen, store_photo
from app.schemas import (
    Course,
    GuestOut,
    IntroResult,
    MySuppers,
    PaymentOut,
    PersonOut,
    PhotoOut,
    SeatAsk,
    SeatOut,
    SupperCreate,
    SupperOut,
    SupperReviewIn,
    TableMate,
)
from app.social import friend_ids, say_hi
from app.views import now, pay_mode, photo_url, public_point

router = APIRouter(prefix="/v1", tags=["suppers"])
log = logging.getLogger(__name__)

# An accepted seat paid in the app is held this long (or until the supper starts) for the guest to pay.
PAY_WITHIN = timedelta(hours=24)
# Once PaymentSheet has started (there's a PaymentIntent), a little longer.
PAY_GRACE = timedelta(minutes=30)
# Guests who back out at least this long before the start get their money back; after that, they don't.
REFUND_BEFORE = timedelta(hours=48)
# What "suppers you're going to / hosting" keeps showing after they end, for reviews and adding friends.
AFTER = timedelta(days=14)


# Reading


async def lock_supper(session: AsyncSession, supper_id: uuid.UUID) -> Supper | None:
    """The supper row, locked: seats are counted and given only under it."""
    return await session.scalar(
        select(Supper)
        .where(Supper.id == supper_id)
        .with_for_update(of=Supper)
        .execution_options(populate_existing=True)
    )


def _pay_by(seat: SupperSeat, s: Supper) -> datetime | None:
    if seat.status != "accepted" or seat.payment != "unpaid" or seat.decided_at is None:
        return None
    return min(seat.decided_at + PAY_WITHIN, s.starts_at)


def seat_out(seat: SupperSeat, s: Supper) -> SeatOut:
    return SeatOut(
        id=seat.id,
        status=seat.status,
        payment=seat.payment,
        note=seat.note,
        price_cents=seat.price_cents,
        service_cents=seat.service_cents,
        total_cents=seat.price_cents + seat.service_cents,
        pay_by=_pay_by(seat, s),
    )


def at_table(s: Supper) -> set[uuid.UUID]:
    """The host and the guests whose seats are confirmed."""
    return {s.host_id} | {seat.guest_id for seat in s.requests if seat.confirmed}


async def host_stats(session: AsyncSession, host_id: uuid.UUID) -> tuple[int, float | None, int]:
    """Suppers hosted (ended, not canceled), and the stars guests gave the host."""
    hosted = await session.scalar(
        select(func.count())
        .select_from(Supper)
        .where(Supper.host_id == host_id, Supper.canceled_at.is_(None), Supper.ends_at <= now())
    )
    avg, n = (
        await session.execute(
            select(func.avg(SupperReview.stars), func.count()).where(SupperReview.subject_id == host_id)
        )
    ).one()
    return int(hosted or 0), (float(avg) if avg is not None else None), int(n)


async def supper_out(
    session: AsyncSession,
    s: Supper,
    viewer: User,
    friends: set[uuid.UUID] | None = None,
    here: tuple[float, float] | None = None,
) -> SupperOut:
    if friends is None:
        friends = await friend_ids(session, viewer.id)
    mine = s.host_id == viewer.id
    seat = next((r for r in s.requests if r.guest_id == viewer.id), None)
    exact = mine or (seat is not None and seat.confirmed)
    lat, lon = (s.kitchen.lat, s.kitchen.lon) if exact else public_point(s.kitchen)
    in_app = pay_mode(s.kitchen) == "in_app"
    fee = service_fee(s.price_cents) if in_app else 0
    hosted, rating, reviews = await host_stats(session, s.host_id)
    table: list[TableMate] = []
    seated = at_table(s)
    if viewer.id in seated:
        hi = set(
            await session.scalars(
                select(Intro.other_id).where(
                    Intro.user_id == viewer.id, Intro.other_id.in_(seated), Intro.said_hi_at.is_not(None)
                )
            )
        )
        reviewed = set(
            await session.scalars(
                select(SupperReview.subject_id).where(
                    SupperReview.supper_id == s.id, SupperReview.author_id == viewer.id
                )
            )
        )
        people = [(s.host_id, s.host.display_name, True)] + [
            (r.guest_id, r.guest.display_name, False) for r in s.requests if r.confirmed
        ]
        table = [
            TableMate(
                id=uid,
                display_name=name,
                is_host=is_host,
                is_friend=uid in friends,
                said_hi=uid in hi,
                reviewed=uid in reviewed,
            )
            for uid, name, is_host in people
            if uid != viewer.id
        ]
    return SupperOut(
        id=s.id,
        title=s.title,
        starts_at=s.starts_at,
        ends_at=s.ends_at,
        seats=s.seats,
        taken=s.taken,
        seats_left=max(0, s.seats - s.taken),
        price_cents=s.price_cents,
        service_cents=fee,
        seat_total_cents=s.price_cents + fee,
        pay="in_app" if in_app else "at_door",
        menu=[Course(**c) for c in s.menu or []],
        tags=list(s.tags or []),
        house_notes=s.house_notes,
        photo_url=photo_url(s.photo_id),
        host=PersonOut(id=s.host_id, display_name=s.host.display_name),
        kitchen_id=s.kitchen_id,
        suppers_hosted=hosted,
        host_rating=rating,
        host_review_count=reviews,
        lat=lat,
        lon=lon,
        exact=exact,
        address=s.kitchen.address if exact else None,
        distance_m=distance_m(here[0], here[1], lat, lon) if here else None,
        friends_going=[
            PersonOut(id=r.guest_id, display_name=r.guest.display_name)
            for r in s.requests
            if r.confirmed and r.guest_id in friends
        ],
        is_mine=mine,
        canceled=s.canceled_at is not None,
        my_seat=seat_out(seat, s) if seat else None,
        refund_until=s.starts_at - REFUND_BEFORE,
        waiting=sum(1 for r in s.requests if r.status == "asked") if mine else 0,
        table=table,
    )


async def _supper(session: AsyncSession, supper_id: uuid.UUID) -> Supper:
    s = await session.get(Supper, supper_id)
    if s is None:
        raise HTTPException(404, "That supper isn't here anymore")
    return s


async def _reload(session: AsyncSession, supper_id: uuid.UUID) -> Supper:
    """After a commit: the supper with its requests as they are now."""
    return await session.scalar(
        select(Supper).where(Supper.id == supper_id).execution_options(populate_existing=True)
    )


# Money


def mark_paid(seat: SupperSeat) -> None:
    if seat.payment != "paid":
        seat.payment = "paid"
        seat.paid_at = now()


async def settle_lapsed(session: AsyncSession, s: Supper) -> None:
    """Accepted seats not paid in time go back. Call with the supper locked. One that turns out to be
    paid is marked paid; one Stripe can't answer for keeps its seat."""
    t = now()
    for seat in s.requests:
        due = _pay_by(seat, s)
        if due is None or t < due:
            continue
        if seat.payment_intent_id:
            if t < due + PAY_GRACE:
                continue
            try:
                pi = await payments.retrieve_payment_intent(seat.payment_intent_id)
                if pi["status"] == "succeeded":
                    mark_paid(seat)
                    continue
                if pi["status"] in ("processing", "requires_capture"):
                    continue
                if pi["status"] != "canceled":
                    await payments.cancel_payment_intent(seat.payment_intent_id)
            except payments.StripeError as e:
                log.warning("Couldn't settle seat %s: %s", seat.id, e)
                continue
        seat.status = "lapsed"
        seat.ended_at = t


async def _settle(session: AsyncSession, seat: SupperSeat) -> None:
    """If PaymentSheet finished before Stripe's webhook got here, ask Stripe."""
    if seat.status != "accepted" or seat.payment != "unpaid" or not seat.payment_intent_id:
        return
    try:
        pi = await payments.retrieve_payment_intent(seat.payment_intent_id)
    except payments.StripeError as e:
        log.warning("Couldn't check payment for seat %s: %s", seat.id, e)
        return
    if pi["status"] == "succeeded":
        mark_paid(seat)
        await session.commit()


async def _give_back(seat: SupperSeat, refund: bool) -> None:
    """A seat ending: stop a payment under way, and refund a paid one if `refund`. Raises 502 when
    Stripe won't, so nothing changes."""
    try:
        if seat.payment == "unpaid" and seat.payment_intent_id:
            pi = await payments.retrieve_payment_intent(seat.payment_intent_id)
            if pi["status"] == "succeeded":
                mark_paid(seat)
            elif pi["status"] != "canceled":
                await payments.cancel_payment_intent(seat.payment_intent_id)
        if seat.payment == "paid" and refund:
            await payments.refund(seat.payment_intent_id)
            seat.payment = "refunded"
    except payments.StripeError as e:
        log.error("Couldn't give back seat %s: %s", seat.id, e)
        raise HTTPException(502, "The payment service didn't answer. Try again.") from None


async def seat_paid(session: AsyncSession, pi_id: str) -> bool:
    """Stripe's webhook said this PaymentIntent went through. False when it isn't a seat's."""
    seat = await session.scalar(select(SupperSeat).where(SupperSeat.payment_intent_id == pi_id))
    if seat is None:
        return False
    if seat.payment in ("paid", "refunded"):
        return True
    s = await lock_supper(session, seat.supper_id)
    await session.refresh(seat)
    if seat.status == "accepted":
        mark_paid(seat)
    elif seat.status == "lapsed" and s.canceled_at is None and s.starts_at > now() and s.taken < s.seats:
        # The time ran out just before the money came, and the seat is still free: it's theirs.
        seat.status = "accepted"
        seat.ended_at = None
        mark_paid(seat)
    else:
        try:
            await payments.refund(pi_id)
            seat.payment = "refunded"
        except payments.StripeError as e:
            log.error("Refund failed for seat %s: %s", seat.id, e)
            await session.rollback()
            raise HTTPException(502, "Refund failed; Stripe will retry") from None
    await session.commit()
    return True


# Hosting


@router.post("/suppers", response_model=SupperOut, status_code=201)
async def host_supper(
    body: SupperCreate, user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> SupperOut:
    if body.starts_at <= now():
        raise HTTPException(422, "Pick a time that hasn't passed")
    k = await home_kitchen(
        session,
        user,
        address=body.address,
        pickup_note=None,
        lat=body.lat,
        lon=body.lon,
        permit_confirmed=body.permit_confirmed,
    )
    s = Supper(
        host_id=user.id,
        kitchen_id=k.id,
        title=body.title.strip(),
        starts_at=body.starts_at,
        ends_at=body.ends_at,
        seats=body.seats,
        price_cents=body.price_cents,
        menu=[c.model_dump() for c in body.menu],
        tags=body.tags,
        house_notes=body.house_notes.strip(),
    )
    session.add(s)
    await session.commit()
    return await supper_out(session, await _reload(session, s.id), user)


@router.post("/suppers/{supper_id}/photo", response_model=PhotoOut, status_code=201)
async def supper_photo(
    supper_id: uuid.UUID,
    request: Request,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> PhotoOut:
    """The supper's photo, the header of its page and its pin: a JPEG body. A new one replaces the old."""
    s = await session.get(Supper, supper_id)
    if s is None or s.host_id != user.id:
        raise HTTPException(404, "That supper isn't yours")
    photo = await store_photo(session, request, user, s.photo_id)
    s.photo_id = photo.id
    await session.commit()
    return PhotoOut(photo_url=photo_url(photo.id))


@router.delete("/suppers/{supper_id}", response_model=SupperOut)
async def cancel_supper(
    supper_id: uuid.UUID, user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> SupperOut:
    """The host calls it off: everyone who paid gets it all back."""
    s = await lock_supper(session, supper_id)
    if s is None or s.host_id != user.id:
        raise HTTPException(404, "That supper isn't yours")
    if s.canceled_at is None:
        if s.ends_at <= now():
            raise HTTPException(409, "This supper is over")
        for seat in s.requests:
            if seat.status not in ("asked", "accepted"):
                continue
            await _give_back(seat, refund=True)
            seat.status = "canceled"
            seat.ended_at = now()
        s.canceled_at = now()
        await session.commit()
    return await supper_out(session, await _reload(session, s.id), user)


async def guest_out(session: AsyncSession, seat: SupperSeat, friends: set[uuid.UUID]) -> GuestOut:
    attended = await session.scalar(
        select(func.count())
        .select_from(SupperSeat)
        .join(Supper, Supper.id == SupperSeat.supper_id)
        .where(
            SupperSeat.guest_id == seat.guest_id,
            SupperSeat.status == "accepted",
            SupperSeat.payment.in_(("at_door", "paid")),
            Supper.canceled_at.is_(None),
            Supper.ends_at <= now(),
        )
    )
    avg, n = (
        await session.execute(
            select(func.avg(SupperReview.stars), func.count()).where(SupperReview.subject_id == seat.guest_id)
        )
    ).one()
    words = await session.scalars(
        select(SupperReview.text)
        .where(SupperReview.subject_id == seat.guest_id, SupperReview.text != "")
        .order_by(SupperReview.created_at.desc())
        .limit(3)
    )
    return GuestOut(
        seat_id=seat.id,
        guest=PersonOut(id=seat.guest_id, display_name=seat.guest.display_name),
        note=seat.note,
        status=seat.status,
        payment=seat.payment,
        asked_at=seat.created_at,
        suppers_attended=int(attended or 0),
        rating=float(avg) if avg is not None else None,
        review_count=int(n),
        reviews=list(words),
        is_friend=seat.guest_id in friends,
    )


@router.get("/suppers/{supper_id}/requests", response_model=list[GuestOut])
async def requests(
    supper_id: uuid.UUID, user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> list[GuestOut]:
    """For the host: who's asking (oldest first) and who's coming, each with their reviews from other
    hosts and how many suppers they've been to."""
    s = await _supper(session, supper_id)
    if s.host_id != user.id:
        raise HTTPException(404, "That supper isn't yours")
    friends = await friend_ids(session, user.id)
    return [
        await guest_out(session, seat, friends) for seat in s.requests if seat.status in ("asked", "accepted")
    ]


async def _hosts_seat(session: AsyncSession, seat_id: uuid.UUID, user: User) -> tuple[SupperSeat, Supper]:
    seat = await session.get(SupperSeat, seat_id)
    if seat is None:
        raise HTTPException(404, "That request isn't here anymore")
    s = await lock_supper(session, seat.supper_id)
    if s is None or s.host_id != user.id:
        raise HTTPException(404, "That request isn't here anymore")
    await session.refresh(seat)
    if s.canceled_at is not None:
        raise HTTPException(409, "This supper is canceled")
    return seat, s


@router.post("/supper-seats/{seat_id}/accept", response_model=list[GuestOut])
async def accept(
    seat_id: uuid.UUID, user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> list[GuestOut]:
    """Yes: the seat is theirs. Paid in the app (within a day, or by the start) when the host takes
    payments, otherwise at the door. The address goes to them once it's settled."""
    seat, s = await _hosts_seat(session, seat_id, user)
    if seat.status != "accepted":
        if seat.status != "asked":
            raise HTTPException(409, f"{seat.guest.display_name} isn't asking anymore")
        if s.starts_at <= now():
            raise HTTPException(409, "This supper has started")
        await settle_lapsed(session, s)
        if s.taken >= s.seats:
            raise HTTPException(409, "Every seat is given")
        in_app = pay_mode(s.kitchen) == "in_app"
        seat.status = "accepted"
        seat.decided_at = now()
        seat.price_cents = s.price_cents
        seat.service_cents = service_fee(s.price_cents) if in_app else 0
        seat.payment = "unpaid" if in_app else "at_door"
        await session.commit()
    return await requests(s.id, user, session)


@router.post("/supper-seats/{seat_id}/decline", response_model=list[GuestOut])
async def decline(
    seat_id: uuid.UUID, user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> list[GuestOut]:
    """Not this time. They see that the host couldn't fit them in; nothing was paid."""
    seat, s = await _hosts_seat(session, seat_id, user)
    if seat.status == "accepted":
        raise HTTPException(409, "You already said yes")
    if seat.status == "asked":
        seat.status = "declined"
        seat.decided_at = now()
        await session.commit()
    return await requests(s.id, user, session)


# Guests


@router.get("/suppers", response_model=list[SupperOut])
async def suppers_near(
    lat: float = Query(ge=-90, le=90),
    lon: float = Query(ge=-180, le=180),
    radius_m: float = Query(default=settings.nearby_radius_m, gt=0, le=20_000),
    with_seats: bool = False,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> list[SupperOut]:
    """Suppers around a point that haven't ended or been canceled, soonest first. `with_seats`: only
    ones with a seat left that haven't started (for a feed of what you could still go to). Each sits
    at its kitchen's public point unless you're its host or a confirmed guest."""
    min_lat, max_lat, min_lon, max_lon = bbox(lat, lon, radius_m + 200)
    rows = await session.scalars(
        select(Supper)
        .join(Kitchen, Kitchen.id == Supper.kitchen_id)
        .where(
            Supper.canceled_at.is_(None),
            Supper.ends_at > now(),
            Kitchen.lat.between(min_lat, max_lat),
            Kitchen.lon.between(min_lon, max_lon),
        )
        .order_by(Supper.starts_at)
        .limit(100)
    )
    friends = await friend_ids(session, user.id)
    out: list[SupperOut] = []
    for s in rows.unique():
        if with_seats and (s.taken >= s.seats or s.starts_at <= now()):
            continue
        o = await supper_out(session, s, user, friends, here=(lat, lon))
        if o.distance_m is not None and o.distance_m <= radius_m:
            out.append(o)
    return out


@router.get("/me/suppers", response_model=MySuppers)
async def my_suppers(
    user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> MySuppers:
    """Suppers you host and ones you've asked for or have a seat at, until two weeks after they end
    (for reviews and adding the table as friends)."""
    since = now() - AFTER
    hosting = await session.scalars(
        select(Supper).where(Supper.host_id == user.id, Supper.ends_at > since).order_by(Supper.starts_at)
    )
    going = await session.scalars(
        select(Supper)
        .join(SupperSeat, SupperSeat.supper_id == Supper.id)
        .where(
            SupperSeat.guest_id == user.id,
            SupperSeat.status.in_(("asked", "accepted")),
            Supper.ends_at > since,
        )
        .order_by(Supper.starts_at)
    )
    friends = await friend_ids(session, user.id)
    return MySuppers(
        hosting=[await supper_out(session, s, user, friends) for s in hosting.unique()],
        going=[await supper_out(session, s, user, friends) for s in going.unique()],
    )


@router.get("/suppers/{supper_id}", response_model=SupperOut)
async def get_supper(
    supper_id: uuid.UUID,
    lat: float | None = Query(default=None, ge=-90, le=90),
    lon: float | None = Query(default=None, ge=-180, le=180),
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> SupperOut:
    s = await _supper(session, supper_id)
    seat = next((r for r in s.requests if r.guest_id == user.id), None)
    if seat is not None:
        await _settle(session, seat)
    here = (lat, lon) if lat is not None and lon is not None else None
    return await supper_out(session, s, user, here=here)


@router.post("/suppers/{supper_id}/seats", response_model=SupperOut, status_code=201)
async def ask(
    supper_id: uuid.UUID,
    body: SeatAsk,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> SupperOut:
    """Ask for a seat. The host chooses who comes; asking again while you're waiting changes nothing."""
    s = await lock_supper(session, supper_id)
    if s is None:
        raise HTTPException(404, "That supper isn't here anymore")
    if s.host_id == user.id:
        raise HTTPException(409, "It's your supper")
    if s.canceled_at is not None:
        raise HTTPException(409, "This supper was canceled")
    if s.starts_at <= now():
        raise HTTPException(409, "This supper has started")
    seat = next((r for r in s.requests if r.guest_id == user.id), None)
    if seat is not None and seat.status in ("asked", "accepted"):
        return await supper_out(session, s, user)
    if seat is not None and seat.status == "declined":
        raise HTTPException(409, f"{s.host.display_name} can't fit you in this time")
    await settle_lapsed(session, s)
    if s.taken >= s.seats:
        raise HTTPException(409, "Every seat is taken")
    if seat is not None:
        # Backed out (or ran out of time to pay) and asking again: a fresh request, with a fresh
        # payment if it comes to that.
        await session.delete(seat)
        await session.flush()
    session.add(SupperSeat(supper_id=s.id, guest_id=user.id, note=body.note.strip()))
    await session.commit()
    return await supper_out(session, await _reload(session, s.id), user)


@router.delete("/suppers/{supper_id}/seat", response_model=SupperOut)
async def back_out(
    supper_id: uuid.UUID, user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> SupperOut:
    """Stop asking, or give back a seat you were given. Paid and backing out at least 48 hours before
    the start: all of it back. Later than that: the seat goes back to the host, the money doesn't."""
    s = await lock_supper(session, supper_id)
    seat = next((r for r in s.requests if r.guest_id == user.id), None) if s else None
    if s is None or seat is None:
        raise HTTPException(404, "You haven't asked for a seat")
    if seat.status == "asked":
        seat.status = "withdrawn"
        seat.ended_at = now()
    elif seat.status == "accepted":
        if s.starts_at <= now():
            raise HTTPException(409, "This supper has started")
        await _give_back(seat, refund=now() <= s.starts_at - REFUND_BEFORE)
        seat.status = "withdrawn"
        seat.ended_at = now()
    await session.commit()
    return await supper_out(session, await _reload(session, s.id), user)


@router.post("/supper-seats/{seat_id}/pay", response_model=PaymentOut)
async def pay_for_seat(
    seat_id: uuid.UUID, user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> PaymentOut:
    """What PaymentSheet needs to pay for a seat you were given (`order_id` is the seat's id). One
    PaymentIntent per seat, ever: asking again returns the same one, so it can't charge twice."""
    seat = await session.get(SupperSeat, seat_id)
    if seat is None or seat.guest_id != user.id:
        raise HTTPException(404, "That seat isn't yours")
    if seat.payment == "at_door":
        raise HTTPException(409, "This one's paid at the door")
    if not settings.payments_enabled:
        raise HTTPException(409, "Payments aren't set up")
    s = await lock_supper(session, seat.supper_id)
    await session.refresh(seat)
    await settle_lapsed(session, s)
    if seat.status != "accepted":
        await session.commit()
        raise HTTPException(
            409,
            "The time to pay ran out. Ask again."
            if seat.status == "lapsed"
            else "That seat isn't yours anymore",
        )

    def out(client_secret: str | None) -> PaymentOut:
        return PaymentOut(
            order_id=seat.id,
            payment="paid" if seat.payment == "paid" else "unpaid",
            amount_cents=seat.price_cents + seat.service_cents,
            client_secret=client_secret,
            publishable_key=settings.stripe_publishable_key,
            merchant_id=settings.apple_pay_merchant_id or None,
            country=settings.stripe_country,
        )

    if seat.payment == "paid":
        await session.commit()
        return out(None)
    try:
        if seat.payment_intent_id:
            pi = await payments.retrieve_payment_intent(seat.payment_intent_id)
        else:
            if not s.kitchen.stripe_account_id:
                raise HTTPException(409, "This host can't take payments in the app")
            pi = await payments.create_payment_intent(
                seat_id=seat.id,
                amount_cents=seat.price_cents + seat.service_cents,
                fee_cents=seat.service_cents,
                destination=s.kitchen.stripe_account_id,
                description=f"A seat at {s.host.display_name}'s: {s.title}",
            )
            seat.payment_intent_id = pi["id"]
    except payments.StripeError as e:
        log.error("Stripe failed for seat %s: %s", seat.id, e)
        raise HTTPException(502, "The payment service didn't answer. Try again.") from None
    if pi["status"] == "succeeded":
        mark_paid(seat)
    await session.commit()
    return out(None if seat.payment == "paid" else pi["client_secret"])


# Afterwards


def _at_table_after(s: Supper, user: User, other: uuid.UUID) -> None:
    seated = at_table(s)
    if s.starts_at > now():
        raise HTTPException(409, "After the supper")
    if user.id not in seated or other not in seated or other == user.id:
        raise HTTPException(404, "They weren't at your table")


@router.post("/suppers/{supper_id}/reviews", response_model=SupperOut, status_code=201)
async def review(
    supper_id: uuid.UUID,
    body: SupperReviewIn,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> SupperOut:
    """Both ways: a guest reviews the host, the host reviews a guest. Once each, after it's started."""
    s = await _supper(session, supper_id)
    if s.canceled_at is not None:
        raise HTTPException(409, "This supper was canceled")
    _at_table_after(s, user, body.subject_id)
    if s.host_id not in (user.id, body.subject_id):
        raise HTTPException(409, "Guests review the host, and the host reviews guests")
    done = await session.scalar(
        select(SupperReview.id).where(
            SupperReview.supper_id == s.id,
            SupperReview.author_id == user.id,
            SupperReview.subject_id == body.subject_id,
        )
    )
    if done is not None:
        raise HTTPException(409, "Already reviewed")
    session.add(
        SupperReview(
            supper_id=s.id,
            author_id=user.id,
            subject_id=body.subject_id,
            stars=body.stars,
            text=body.text.strip(),
        )
    )
    await session.commit()
    return await supper_out(session, s, user)


@router.post("/suppers/{supper_id}/table/{other_id}/hi", response_model=IntroResult)
async def add_from_table(
    supper_id: uuid.UUID,
    other_id: uuid.UUID,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> IntroResult:
    """Add someone you ate with as a friend: one tap each, and you're friends once both have."""
    s = await _supper(session, supper_id)
    if s.canceled_at is not None:
        raise HTTPException(409, "This supper was canceled")
    _at_table_after(s, user, other_id)
    return IntroResult(connected=await say_hi(session, user.id, other_id))
