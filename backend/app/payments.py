"""Stripe, over its REST API with httpx: PaymentIntents for buyers, Connect Express for sellers.

Nothing here runs unless `settings.payments_enabled` (STRIPE_SECRET_KEY and STRIPE_PUBLISHABLE_KEY).
Tests replace `call` with a fake Stripe.

Never twice: an order (or a supper seat) has at most one PaymentIntent, created with the idempotency
key `letsgo-order-<order id>` (`letsgo-seat-<seat id>`) and stored on it, so a retried "pay" gets the
same one back.
"""

import hashlib
import hmac
import json
import time
import uuid
from typing import Any

import httpx

from app.config import settings

API = "https://api.stripe.com"


class StripeError(Exception):
    def __init__(self, status: int, message: str, code: str = ""):
        super().__init__(message)
        self.status = status
        self.code = code


def _flatten(data: dict[str, Any], prefix: str = "") -> list[tuple[str, str]]:
    """Stripe's form encoding: {"a": {"b": 1}} → a[b]=1, lists → a[0]=…"""
    out: list[tuple[str, str]] = []
    for key, value in data.items():
        name = f"{prefix}[{key}]" if prefix else key
        if isinstance(value, dict):
            out += _flatten(value, name)
        elif isinstance(value, list):
            for i, v in enumerate(value):
                if isinstance(v, dict):
                    out += _flatten(v, f"{name}[{i}]")
                else:
                    out.append((f"{name}[{i}]", str(v)))
        elif isinstance(value, bool):
            out.append((name, "true" if value else "false"))
        elif value is not None:
            out.append((name, str(value)))
    return out


async def call(
    method: str, path: str, data: dict[str, Any] | None = None, idempotency_key: str | None = None
) -> dict[str, Any]:
    headers = {"Authorization": f"Bearer {settings.stripe_secret_key}"}
    if idempotency_key:
        headers["Idempotency-Key"] = idempotency_key
    async with httpx.AsyncClient(base_url=API, timeout=20) as client:
        r = await client.request(method, path, data=_flatten(data or {}) or None, headers=headers)
    body = r.json() if r.content else {}
    if r.status_code >= 400:
        err = body.get("error", {}) if isinstance(body, dict) else {}
        raise StripeError(
            r.status_code, err.get("message", f"Stripe said {r.status_code}"), err.get("code", "")
        )
    return body


# Buyers


async def create_payment_intent(
    *,
    order_id: uuid.UUID | None = None,
    seat_id: uuid.UUID | None = None,
    amount_cents: int,
    fee_cents: int,
    destination: str,
    description: str,
) -> dict[str, Any]:
    """For an order or a supper seat. Card only (Apple Pay is a card wallet), so nothing needs a
    redirect back to the app."""
    kind, ref = ("seat", seat_id) if seat_id is not None else ("order", order_id)
    return await call(
        "POST",
        "/v1/payment_intents",
        {
            "amount": amount_cents,
            "currency": "usd",
            "payment_method_types": ["card"],
            "application_fee_amount": fee_cents,
            "transfer_data": {"destination": destination},
            "description": description[:200],
            "metadata": {f"{kind}_id": str(ref)},
        },
        idempotency_key=f"letsgo-{kind}-{ref}",
    )


async def retrieve_payment_intent(pi_id: str) -> dict[str, Any]:
    return await call("GET", f"/v1/payment_intents/{pi_id}")


async def cancel_payment_intent(pi_id: str) -> dict[str, Any]:
    return await call("POST", f"/v1/payment_intents/{pi_id}/cancel")


async def refund(pi_id: str) -> dict[str, Any]:
    """Money back, and the seller's transfer and our fee with it."""
    return await call(
        "POST",
        "/v1/refunds",
        {"payment_intent": pi_id, "reverse_transfer": True, "refund_application_fee": True},
        idempotency_key=f"letsgo-refund-{pi_id}",
    )


# Sellers


async def create_express_account(kitchen_id: uuid.UUID) -> dict[str, Any]:
    return await call(
        "POST",
        "/v1/accounts",
        {
            "type": "express",
            "country": settings.stripe_country,
            "business_type": "individual",
            "capabilities": {"card_payments": {"requested": True}, "transfers": {"requested": True}},
            "metadata": {"kitchen_id": str(kitchen_id)},
        },
        idempotency_key=f"letsgo-account-{kitchen_id}",
    )


async def onboarding_link(account_id: str) -> str:
    base = settings.public_base_url.rstrip("/")
    link = await call(
        "POST",
        "/v1/account_links",
        {
            "account": account_id,
            "type": "account_onboarding",
            "refresh_url": f"{base}/v1/stripe/return?again=1",
            "return_url": f"{base}/v1/stripe/return",
        },
    )
    return link["url"]


async def retrieve_account(account_id: str) -> dict[str, Any]:
    return await call("GET", f"/v1/accounts/{account_id}")


# Webhooks


def verify_webhook(payload: bytes, header: str, secret: str, tolerance_s: int = 300) -> dict[str, Any]:
    """Checks the Stripe-Signature header (t=…,v1=…) and returns the event. Raises ValueError."""
    parts: dict[str, list[str]] = {}
    for item in header.split(","):
        k, _, v = item.strip().partition("=")
        parts.setdefault(k, []).append(v)
    try:
        ts = int(parts["t"][0])
    except (KeyError, ValueError):
        raise ValueError("no timestamp") from None
    if abs(time.time() - ts) > tolerance_s:
        raise ValueError("too old")
    expected = hmac.new(secret.encode(), f"{ts}.".encode() + payload, hashlib.sha256).hexdigest()
    if not any(hmac.compare_digest(expected, sig) for sig in parts.get("v1", [])):
        raise ValueError("bad signature")
    return json.loads(payload)


def sign_for_tests(payload: bytes, secret: str, ts: int | None = None) -> str:
    ts = ts or int(time.time())
    sig = hmac.new(secret.encode(), f"{ts}.".encode() + payload, hashlib.sha256).hexdigest()
    return f"t={ts},v1={sig}"
