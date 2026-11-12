"""Stripe's side: sellers' payouts (Connect Express) and the webhook that says a payment went through."""

import logging

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import HTMLResponse
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app import payments
from app.auth import current_user
from app.config import settings
from app.db import get_session
from app.models import Kitchen, Order, User
from app.routes.orders import lock_drop, mark_paid, quantity
from app.routes.suppers import seat_paid
from app.schemas import PayoutsOut
from app.views import now

router = APIRouter(tags=["payments"])
log = logging.getLogger(__name__)


async def _kitchen(session: AsyncSession, user: User) -> Kitchen:
    k = await session.scalar(select(Kitchen).where(Kitchen.owner_id == user.id))
    if k is None:
        raise HTTPException(404, "You haven't opened a kitchen")
    return k


async def _refresh_ready(k: Kitchen) -> None:
    if k.stripe_account_id and not k.payouts_ready:
        try:
            account = await payments.retrieve_account(k.stripe_account_id)
            k.payouts_ready = bool(account.get("charges_enabled"))
        except payments.StripeError as e:
            log.warning("Couldn't check payouts for kitchen %s: %s", k.id, e)


@router.get("/v1/kitchens/me/payouts", response_model=PayoutsOut)
async def payouts(
    user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> PayoutsOut:
    k = await _kitchen(session, user)
    if not settings.payments_enabled:
        return PayoutsOut(enabled=False, ready=False)
    await _refresh_ready(k)
    await session.commit()
    return PayoutsOut(enabled=True, ready=k.payouts_ready)


@router.post("/v1/kitchens/me/payouts", response_model=PayoutsOut)
async def set_up_payouts(
    user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> PayoutsOut:
    """Makes the kitchen's Stripe Express account (once) and returns Stripe's page to finish it."""
    k = await _kitchen(session, user)
    if not settings.payments_enabled:
        raise HTTPException(409, "Payments aren't set up on the server yet")
    try:
        if not k.stripe_account_id:
            account = await payments.create_express_account(k.id)
            k.stripe_account_id = account["id"]
            await session.commit()
        await _refresh_ready(k)
        url = None if k.payouts_ready else await payments.onboarding_link(k.stripe_account_id)
    except payments.StripeError as e:
        log.error("Stripe onboarding failed for kitchen %s: %s", k.id, e)
        raise HTTPException(502, "Stripe didn't answer. Try again.") from None
    await session.commit()
    return PayoutsOut(enabled=True, ready=k.payouts_ready, onboarding_url=url)


@router.get("/v1/stripe/return", response_class=HTMLResponse, include_in_schema=False)
async def stripe_return(again: int = 0) -> str:
    line = (
        "That link ran out. Go back to Let's Go and tap Set up payouts again."
        if again
        else "Done. Go back to Let's Go; your next batch takes payments in the app once Stripe has checked."
    )
    return (
        "<!doctype html><meta name=viewport content='width=device-width,initial-scale=1'>"
        "<title>Let's Go</title><body style='font:17px -apple-system,system-ui;margin:48px 24px;"
        f"background:#F4F2EC;color:#1B1A17'><p>{line}</p></body>"
    )


@router.post("/v1/stripe/webhook", include_in_schema=False)
async def webhook(request: Request, session: AsyncSession = Depends(get_session)) -> dict[str, bool]:
    if not settings.stripe_webhook_secret:
        raise HTTPException(404)
    payload = await request.body()
    try:
        event = payments.verify_webhook(
            payload, request.headers.get("stripe-signature", ""), settings.stripe_webhook_secret
        )
    except ValueError:
        raise HTTPException(400, "Bad signature") from None
    obj = event.get("data", {}).get("object", {})
    kind = event.get("type")
    if kind == "payment_intent.succeeded":
        await _paid(session, obj.get("id", ""))
    elif kind == "account.updated":
        k = await session.scalar(select(Kitchen).where(Kitchen.stripe_account_id == obj.get("id")))
        if k is not None:
            k.payouts_ready = bool(obj.get("charges_enabled"))
            await session.commit()
    return {"ok": True}


async def _paid(session: AsyncSession, pi_id: str) -> None:
    o = await session.scalar(select(Order).where(Order.payment_intent_id == pi_id))
    if o is None:
        # A seat at a supper, paid through the same path.
        await seat_paid(session, pi_id)
        return
    if o.payment in ("paid", "refunded"):
        return
    drop = await lock_drop(session, o.drop_id)
    await session.refresh(o)
    if o.status != "canceled":
        mark_paid(o)
    elif drop is not None and drop.ends_at > now() and drop.total - drop.sold >= quantity(o):
        # Its hold ran out just before the money came, and there's still enough: take it back.
        drop.sold += quantity(o)
        o.status = "reserved"
        mark_paid(o)
    else:
        try:
            await payments.refund(pi_id)
            o.payment = "refunded"
        except payments.StripeError as e:
            log.error("Refund failed for order %s: %s", o.id, e)
            await session.rollback()
            raise HTTPException(502, "Refund failed; Stripe will retry") from None
    await session.commit()
