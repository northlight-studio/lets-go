import logging
import secrets
import uuid
from datetime import timedelta

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app import payments
from app.auth import current_user
from app.config import settings
from app.db import get_session
from app.models import Drop, MenuItem, Order, OrderLine, Review, User
from app.pricing import service_fee
from app.schemas import OrderCreate, OrderOut, PaymentOut, ReviewCreate
from app.views import now, order_out, pay_mode

router = APIRouter(prefix="/v1/orders", tags=["orders"])
log = logging.getLogger(__name__)

SLOT = timedelta(minutes=15)
# An order paid in the app holds its stock this long before it's paid; once PaymentSheet has
# started (there's a PaymentIntent) it gets a while longer.
HOLD = timedelta(minutes=15)
HOLD_PAYING = timedelta(minutes=30)


def quantity(o: Order) -> int:
    return sum(line.quantity for line in o.lines)


def mark_paid(o: Order) -> None:
    if o.payment != "paid":
        o.payment = "paid"
        o.paid_at = now()


async def lock_drop(session: AsyncSession, drop_id: uuid.UUID) -> Drop | None:
    """The drop row, locked: stock, slots and holds change only under it. (OF drops: the joined
    menu item is the nullable side of an outer join and can't be locked.)"""
    return await session.scalar(select(Drop).where(Drop.id == drop_id).with_for_update(of=Drop))


async def release_stale_holds(session: AsyncSession, drop: Drop) -> None:
    """Unpaid orders past their hold give their stock back. Call with the drop locked.
    One that turns out to be paid is marked paid; one Stripe can't answer for keeps its hold."""
    t = now()
    stale = (
        await session.scalars(
            select(Order).where(
                Order.drop_id == drop.id,
                Order.payment == "unpaid",
                Order.status == "reserved",
                Order.created_at < t - HOLD,
            )
        )
    ).unique()
    for o in stale:
        if o.payment_intent_id:
            if o.created_at >= t - HOLD_PAYING:
                continue
            try:
                pi = await payments.retrieve_payment_intent(o.payment_intent_id)
                if pi["status"] == "succeeded":
                    mark_paid(o)
                    continue
                if pi["status"] in ("processing", "requires_capture"):
                    continue
                if pi["status"] != "canceled":
                    await payments.cancel_payment_intent(o.payment_intent_id)
            except payments.StripeError as e:
                log.warning("Couldn't settle hold on order %s: %s", o.id, e)
                continue
        o.status = "canceled"
        drop.sold = max(0, drop.sold - quantity(o))


async def new_code(session: AsyncSession, drop_id: uuid.UUID) -> str:
    """Three digits, 100 to 999, not already given out on this drop if it can help it."""
    taken = set(
        await session.scalars(
            select(Order.pickup_code).where(Order.drop_id == drop_id, Order.status != "canceled")
        )
    )
    for _ in range(50):
        code = str(100 + secrets.randbelow(900))
        if code not in taken:
            return code
    return str(100 + secrets.randbelow(900))


@router.post("", response_model=OrderOut, status_code=201)
async def reserve(
    body: OrderCreate, user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> OrderOut:
    """Reserve from a drop. Safe to retry: the same client_id returns the same order.
    Paid in the app when the kitchen takes payments (then it's held until paid), else at pickup."""
    existing = await session.scalar(
        select(Order).where(Order.buyer_id == user.id, Order.client_id == body.client_id)
    )
    if existing is not None:
        return order_out(existing)

    # Lock the drop: stock and slot counts are checked and taken in one go.
    drop = await lock_drop(session, body.drop_id)
    if drop is None:
        raise HTTPException(404, "Drop not found")
    if drop.ends_at <= now():
        raise HTTPException(409, "This drop is over")
    await session.refresh(drop, ["kitchen", "item"])
    if drop.kitchen.owner_id == user.id:
        raise HTTPException(409, "You can't order from your own kitchen")
    await release_stale_holds(session, drop)

    offset = body.pickup_at - drop.starts_at
    if body.pickup_at < drop.starts_at or body.pickup_at >= drop.ends_at or offset % SLOT != timedelta(0):
        raise HTTPException(422, "Pick one of the drop's 15-minute pickup slots")
    if body.pickup_at + SLOT < now():
        raise HTTPException(409, "That pickup slot has passed")

    if drop.menu_item_id is not None:
        # A batch: one thing, a quantity of it.
        item = drop.item
        if any(line.menu_item_id != drop.menu_item_id for line in body.lines):
            raise HTTPException(422, "That isn't in this batch")
        count = body.quantity or sum(line.quantity for line in body.lines)
        lines = [
            OrderLine(
                menu_item_id=item.id,
                name=drop.title or item.name,
                price_cents=item.price_cents,
                quantity=count,
            )
        ]
    else:
        if not body.lines:
            raise HTTPException(422, "Pick something from the menu")
        ids = [line.menu_item_id for line in body.lines]
        items = {m.id: m for m in await session.scalars(select(MenuItem).where(MenuItem.id.in_(ids)))}
        for line in body.lines:
            m = items.get(line.menu_item_id)
            if m is None or m.kitchen_id != drop.kitchen_id or not m.active:
                raise HTTPException(422, "That item isn't on this kitchen's menu")
        count = sum(line.quantity for line in body.lines)
        lines = [
            OrderLine(menu_item_id=m.id, name=m.name, price_cents=m.price_cents, quantity=line.quantity)
            for line in body.lines
            for m in [items[line.menu_item_id]]
        ]

    if count > drop.total - drop.sold:
        left = drop.total - drop.sold
        raise HTTPException(409, f"Only {left} left" if left > 0 else "Sold out")
    in_slot = await session.scalar(
        select(func.count())
        .select_from(Order)
        .where(Order.drop_id == drop.id, Order.pickup_at == body.pickup_at, Order.status != "canceled")
    )
    if in_slot >= drop.per_slot:
        raise HTTPException(409, "That pickup slot is full")
    if body.eat_on_porch and drop.kitchen.porch_tables == 0:
        raise HTTPException(422, "This kitchen has no porch seating")

    in_app = pay_mode(drop.kitchen) == "in_app"
    subtotal = sum(line.price_cents * line.quantity for line in lines)
    order = Order(
        client_id=body.client_id,
        buyer_id=user.id,
        kitchen_id=drop.kitchen_id,
        drop_id=drop.id,
        pickup_at=body.pickup_at,
        eat_on_porch=body.eat_on_porch,
        subtotal_cents=subtotal,
        # The service fee is what the app keeps from a payment in the app. Paying the cook in person,
        # there's nothing to keep it from.
        service_cents=service_fee(subtotal) if in_app else 0,
        payment="unpaid" if in_app else "at_pickup",
        pickup_code=await new_code(session, drop.id),
        lines=lines,
    )
    drop.sold += count
    session.add(order)
    await session.commit()
    order = await session.scalar(select(Order).where(Order.id == order.id))
    return order_out(order)


@router.get("", response_model=list[OrderOut])
async def my_orders(user: User = Depends(current_user), session: AsyncSession = Depends(get_session)):
    orders = await session.scalars(
        select(Order)
        .where(Order.buyer_id == user.id, Order.status != "canceled")
        .order_by(Order.pickup_at.desc())
        .limit(50)
    )
    return [order_out(o) for o in orders.unique()]


async def _my_order(session: AsyncSession, order_id: uuid.UUID, user: User) -> Order:
    o = await session.get(Order, order_id)
    if o is None or o.buyer_id != user.id:
        raise HTTPException(404, "Order not found")
    return o


async def _settle(session: AsyncSession, o: Order) -> None:
    """If PaymentSheet finished before Stripe's webhook got here, ask Stripe."""
    if o.payment != "unpaid" or not o.payment_intent_id or o.status == "canceled":
        return
    try:
        pi = await payments.retrieve_payment_intent(o.payment_intent_id)
    except payments.StripeError as e:
        log.warning("Couldn't check payment for order %s: %s", o.id, e)
        return
    if pi["status"] == "succeeded":
        mark_paid(o)
        await session.commit()


@router.get("/{order_id}", response_model=OrderOut)
async def get_order(
    order_id: uuid.UUID, user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> OrderOut:
    o = await _my_order(session, order_id, user)
    await _settle(session, o)
    return order_out(o)


@router.post("/{order_id}/pay", response_model=PaymentOut)
async def pay(
    order_id: uuid.UUID, user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> PaymentOut:
    """What PaymentSheet needs to take the payment. One PaymentIntent per order, ever: asking again
    returns the same one, so it can't charge twice."""
    o = await _my_order(session, order_id, user)
    if o.payment == "at_pickup":
        raise HTTPException(409, "This one's paid at pickup")
    if not settings.payments_enabled:
        raise HTTPException(409, "Payments aren't set up")
    # Hold the drop so this order's hold can't be released while its PaymentIntent is made.
    await lock_drop(session, o.drop_id)
    await session.refresh(o)
    if o.status == "canceled":
        raise HTTPException(409, "That hold ran out. Reserve again.")

    def out(client_secret: str | None) -> PaymentOut:
        return PaymentOut(
            order_id=o.id,
            payment="paid" if o.payment == "paid" else "unpaid",
            amount_cents=o.subtotal_cents + o.service_cents,
            client_secret=client_secret,
            publishable_key=settings.stripe_publishable_key,
            merchant_id=settings.apple_pay_merchant_id or None,
            country=settings.stripe_country,
        )

    if o.payment == "paid":
        return out(None)
    try:
        if o.payment_intent_id:
            pi = await payments.retrieve_payment_intent(o.payment_intent_id)
        else:
            if not o.kitchen.stripe_account_id:
                raise HTTPException(409, "This kitchen can't take payments in the app")
            pi = await payments.create_payment_intent(
                order_id=o.id,
                amount_cents=o.subtotal_cents + o.service_cents,
                fee_cents=o.service_cents,
                destination=o.kitchen.stripe_account_id,
                description=f"{o.kitchen.name}: {', '.join(f'{li.quantity}× {li.name}' for li in o.lines)}",
            )
            o.payment_intent_id = pi["id"]
    except payments.StripeError as e:
        log.error("Stripe failed for order %s: %s", o.id, e)
        raise HTTPException(502, "The payment service didn't answer. Try again.") from None
    if pi["status"] == "succeeded":
        mark_paid(o)
    await session.commit()
    return out(None if o.payment == "paid" else pi["client_secret"])


@router.post("/{order_id}/picked-up", response_model=OrderOut)
async def picked_up(
    order_id: uuid.UUID, user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> OrderOut:
    o = await _my_order(session, order_id, user)
    if o.status == "reserved" and o.confirmed:
        o.status = "picked_up"
        o.picked_up_at = now()
        await session.commit()
    return order_out(o)


@router.post("/{order_id}/review", response_model=OrderOut)
async def review(
    order_id: uuid.UUID,
    body: ReviewCreate,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> OrderOut:
    """One review per order, after pickup."""
    o = await _my_order(session, order_id, user)
    if o.status in ("reserved", "canceled"):
        raise HTTPException(409, "Pick it up first")
    if o.status == "reviewed":
        raise HTTPException(409, "Already reviewed")
    session.add(
        Review(
            kitchen_id=o.kitchen_id,
            order_id=o.id,
            author_id=user.id,
            stars=body.stars,
            tags=[t.strip()[:40] for t in body.tags if t.strip()],
            text=body.text.strip(),
        )
    )
    o.status = "reviewed"
    await session.commit()
    return order_out(o)
