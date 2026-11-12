"""Post a batch, sell to your neighbors: the post, the photo, the address only after reserving,
codes, follows, and payments (against a fake Stripe)."""

import asyncio
import json
import uuid
from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import text

from app import payments
from app.config import settings
from app.geo import distance_m
from tests.conftest import HERE, make_user, offset

JPEG = b"\xff\xd8\xff\xe0" + b"\x00" * 64 + b"\xff\xd9"


def window(minutes_from_now: int = 30, hours: float = 2) -> tuple[datetime, datetime]:
    t = datetime.now(UTC).replace(second=0, microsecond=0) + timedelta(minutes=minutes_from_now)
    start = t - timedelta(minutes=t.minute % 15)
    return start, start + timedelta(hours=hours)


def batch_body(**over) -> dict:
    start, end = window()
    lat, lon = offset(200, 250)
    body = {
        "title": "Mango sticky rice ice cream",
        "price_cents": 600,
        "total": 8,
        "unit": "pint",
        "starts_at": start.isoformat(),
        "ends_at": end.isoformat(),
        "pickup_spot": "porch",
        "tags": ["Contains dairy", "Coconut", "Gluten-free"],
        "permit_confirmed": True,
        "address": "3100 24th St",
        "pickup_note": "The blue door with the lemon tree",
        "lat": lat,
        "lon": lon,
    }
    body.update(over)
    return body


async def post_batch(client, headers, **over) -> dict:
    r = await client.post("/v1/batches", headers=headers, json=batch_body(**over))
    assert r.status_code == 201, r.text
    return r.json()


def reserve_body(batch, qty=1, slot=0, client_id=None) -> dict:
    pickup = datetime.fromisoformat(batch["starts_at"]) + timedelta(minutes=15 * slot)
    return {
        "client_id": str(client_id or uuid.uuid4()),
        "drop_id": batch["id"],
        "pickup_at": pickup.isoformat(),
        "quantity": qty,
    }


# Posting


async def test_posting_opens_a_kitchen_in_your_name(client):
    dana = await make_user(client, "Dana")
    b = await post_batch(client, dana)
    assert b["title"] == "Mango sticky rice ice cream" and b["price_cents"] == 600 and b["unit"] == "pint"
    assert b["left"] == 8 and b["tags"] == ["Contains dairy", "Coconut", "Gluten-free"]
    assert b["kitchen"]["name"] == "Dana's kitchen" and b["kitchen"]["permitted"]
    # The owner sees their own address.
    assert b["address"] == "3100 24th St"
    # A second batch reuses the kitchen, its permit and its address.
    again = await post_batch(client, dana, permit_confirmed=False, address=None, title="Ube pints")
    assert again["kitchen"]["id"] == b["kitchen"]["id"] and again["address"] == "3100 24th St"
    # The batch's item stays off the standing menu.
    k = (await client.get("/v1/kitchens/me", headers=dana)).json()
    assert k["menu"] == []


async def test_permit_is_asked_once(client):
    dana = await make_user(client, "Dana")
    r = await client.post("/v1/batches", headers=dana, json=batch_body(permit_confirmed=False))
    assert r.status_code == 409 and "permit" in r.json()["detail"]


async def test_first_batch_needs_an_address(client):
    dana = await make_user(client, "Dana")
    r = await client.post("/v1/batches", headers=dana, json=batch_body(address=""))
    assert r.status_code == 422 and "address" in r.json()["detail"]


async def test_cannot_post_a_window_that_has_passed(client):
    dana = await make_user(client, "Dana")
    past = datetime.now(UTC) - timedelta(hours=1)
    r = await client.post(
        "/v1/batches",
        headers=dana,
        json=batch_body(starts_at=(past - timedelta(hours=1)).isoformat(), ends_at=past.isoformat()),
    )
    assert r.status_code == 422


# The address only after reserving


async def test_address_and_exact_spot_only_after_reserving(client):
    dana = await make_user(client, "Dana")
    b = await post_batch(client, dana)
    exact = offset(200, 250)
    you = await make_user(client, "You")

    seen = (await client.get(f"/v1/drops/{b['id']}", headers=you)).json()
    assert seen["address"] is None and seen["pickup_note"] is None
    k = seen["kitchen"]
    off = distance_m(k["lat"], k["lon"], *exact)
    assert 55 <= off <= 160, off
    # The same blurred spot every time, and the same on the map.
    near = (await client.get("/v1/nearby", params={"lat": HERE[0], "lon": HERE[1]}, headers=you)).json()
    assert (near["kitchens"][0]["lat"], near["kitchens"][0]["lon"]) == (k["lat"], k["lon"])
    detail = (await client.get(f"/v1/kitchens/{k['id']}", headers=you)).json()
    assert detail["address"] is None and detail["pickup_note"] is None

    r = await client.post("/v1/orders", headers=you, json=reserve_body(b, qty=2))
    assert r.status_code == 201, r.text
    o = r.json()
    assert o["payment"] == "at_pickup" and o["address"] == "3100 24th St"
    assert (o["lat"], o["lon"]) == pytest.approx(exact)
    assert o["pickup_note"] == "The blue door with the lemon tree"
    assert o["title"] == "Mango sticky rice ice cream" and o["unit"] == "pint"
    assert o["subtotal_cents"] == 1200 and o["total_cents"] == 1200
    assert o["pickup_code"].isdigit() and 100 <= int(o["pickup_code"]) <= 999
    after = (await client.get(f"/v1/drops/{b['id']}", headers=you)).json()
    assert after["address"] == "3100 24th St" and after["left"] == 6


# Stock


async def test_a_batch_cannot_oversell_even_at_once(client):
    dana = await make_user(client, "Dana")
    b = await post_batch(client, dana, total=3, per_slot=10)
    buyers = [await make_user(client, f"B{i}") for i in range(4)]
    results = await asyncio.gather(
        *(client.post("/v1/orders", headers=h, json=reserve_body(b, qty=2)) for h in buyers)
    )
    assert sorted(r.status_code for r in results) == [201, 409, 409, 409]
    left = (await client.get(f"/v1/drops/{b['id']}", headers=dana)).json()["left"]
    assert left == 1
    r = await client.post("/v1/orders", headers=buyers[0], json=reserve_body(b, qty=2))
    assert r.status_code == 409 and r.json()["detail"] == "Only 1 left"


async def test_retrying_a_reservation_returns_the_same_order(client):
    dana = await make_user(client, "Dana")
    b = await post_batch(client, dana)
    you = await make_user(client, "You")
    body = reserve_body(b, qty=3)
    first = (await client.post("/v1/orders", headers=you, json=body)).json()
    again = (await client.post("/v1/orders", headers=you, json=body)).json()
    assert first["id"] == again["id"] and first["pickup_code"] == again["pickup_code"]
    assert (await client.get(f"/v1/drops/{b['id']}", headers=you)).json()["left"] == 5


async def test_full_slots_are_listed(client):
    dana = await make_user(client, "Dana")
    b = await post_batch(client, dana, per_slot=1)
    you = await make_user(client, "You")
    await client.post("/v1/orders", headers=you, json=reserve_body(b))
    page = (await client.get(f"/v1/drops/{b['id']}", headers=you)).json()
    assert [datetime.fromisoformat(s) for s in page["full_slots"]] == [datetime.fromisoformat(b["starts_at"])]


# Photos


async def test_photo_upload_and_serving(client):
    dana = await make_user(client, "Dana")
    b = await post_batch(client, dana)
    you = await make_user(client, "You")
    url = f"/v1/drops/{b['id']}/photo"
    jpeg = {"Content-Type": "image/jpeg"}
    assert (await client.post(url, headers={**you, **jpeg}, content=JPEG)).status_code == 404
    assert (await client.post(url, headers={**dana, **jpeg}, content=b"GIF89a")).status_code == 415
    r = await client.post(url, headers={**dana, **jpeg}, content=JPEG)
    assert r.status_code == 201, r.text
    photo = r.json()["photo_url"]
    assert photo.startswith("/v1/photos/")

    got = await client.get(photo)  # no token needed
    assert got.status_code == 200 and got.content == JPEG
    assert got.headers["content-type"] == "image/jpeg"
    assert "immutable" in got.headers["cache-control"]
    cached = await client.get(photo, headers={"If-None-Match": got.headers["etag"]})
    assert cached.status_code == 304

    near = (await client.get("/v1/nearby", params={"lat": HERE[0], "lon": HERE[1]}, headers=you)).json()
    k = near["kitchens"][0]
    assert k["photo_url"] == photo and k["next_drop"]["photo_url"] == photo
    assert (await client.get(f"/v1/drops/{b['id']}", headers=you)).json()["photo_url"] == photo

    # A new photo replaces the old one.
    newer = (await client.post(url, headers={**dana, **jpeg}, content=JPEG + b"x")).json()["photo_url"]
    assert newer != photo and (await client.get(photo)).status_code == 404


# Pickup


async def test_seller_sees_codes_and_marks_picked_up(client):
    dana = await make_user(client, "Dana")
    b = await post_batch(client, dana)
    you = await make_user(client, "You")
    o = (await client.post("/v1/orders", headers=you, json=reserve_body(b, qty=2))).json()

    orders = (await client.get("/v1/kitchens/me/orders", headers=dana)).json()
    assert [(x["buyer_name"], x["pickup_code"], x["lines"][0]["quantity"]) for x in orders] == [
        ("You", o["pickup_code"], 2)
    ]
    wrong = str((int(o["pickup_code"]) - 100 + 1) % 900 + 100)
    url = f"/v1/kitchens/me/orders/{o['id']}/picked-up"
    r = await client.post(url, headers=dana, json={"code": wrong})
    assert r.status_code == 409
    assert (await client.post(url, headers=you, json={})).status_code == 404  # not your kitchen
    r = await client.post(url, headers=dana, json={"code": o["pickup_code"]})
    assert r.status_code == 200 and r.json()["status"] == "picked_up" and r.json()["picked_up_at"]
    # Then the buyer can review it.
    r = await client.post(f"/v1/orders/{o['id']}/review", headers=you, json={"stars": 5, "text": "So good"})
    assert r.status_code == 200
    page = (await client.get(f"/v1/drops/{b['id']}", headers=you)).json()
    assert page["review"]["text"] == "So good" and page["kitchen"]["review_count"] == 1


async def test_three_pickups_make_a_regular(client):
    dana = await make_user(client, "Dana")
    you = await make_user(client, "You")
    for i in range(3):
        b = await post_batch(client, dana, title=f"Batch {i}")
        o = (await client.post("/v1/orders", headers=you, json=reserve_body(b))).json()
        await client.post(f"/v1/kitchens/me/orders/{o['id']}/picked-up", headers=dana)
        page = (await client.get(f"/v1/drops/{b['id']}", headers=you)).json()
        assert page["kitchen"]["regulars"] == (1 if i == 2 else 0)


# Follows


async def test_followers_hear_about_a_new_batch(client):
    dana = await make_user(client, "Dana")
    first = await post_batch(client, dana)
    kid = first["kitchen"]["id"]
    you = await make_user(client, "You")
    other = await make_user(client, "Other")

    r = await client.put(f"/v1/kitchens/{kid}/follow", headers=you)
    assert r.json() == {"following": True, "followers": 1}
    assert (await client.put(f"/v1/kitchens/{kid}/follow", headers=you)).json()["followers"] == 1
    assert (await client.put(f"/v1/kitchens/{kid}/follow", headers=dana)).status_code == 409
    page = (await client.get(f"/v1/drops/{first['id']}", headers=you)).json()
    assert page["kitchen"]["is_following"] and page["kitchen"]["followers"] == 1

    second = await post_batch(client, dana, title="Ube pints")
    notes = (await client.get("/v1/me/notes", headers=you)).json()
    assert [(n["title"], n["kitchen_name"], n["drop_id"], n["read"]) for n in notes] == [
        ("Ube pints", "Dana's kitchen", second["id"], False)
    ]
    assert (await client.get("/v1/me/notes", headers=other)).json() == []
    assert (await client.get("/v1/me/notes", headers=dana)).json() == []
    assert (await client.post("/v1/me/notes/read", headers=you)).status_code == 204
    assert (await client.get("/v1/me/notes", headers=you)).json()[0]["read"]

    r = await client.delete(f"/v1/kitchens/{kid}/follow", headers=you)
    assert r.json() == {"following": False, "followers": 0}
    await post_batch(client, dana, title="Third")
    assert len((await client.get("/v1/me/notes", headers=you)).json()) == 1


# Payments, against a fake Stripe


class FakeStripe:
    def __init__(self):
        self.intents: dict[str, dict] = {}
        self.by_key: dict[str, dict] = {}
        self.accounts: dict[str, dict] = {}
        self.refunds: list[str] = []
        self.canceled: list[str] = []

    async def call(self, method, path, data=None, idempotency_key=None):
        data = data or {}
        if idempotency_key and idempotency_key in self.by_key:
            return self.by_key[idempotency_key]
        out = await self._handle(method, path, data)
        if idempotency_key:
            self.by_key[idempotency_key] = out
        return out

    async def _handle(self, method, path, data):
        parts = path.strip("/").split("/")[1:]
        if parts == ["accounts"]:
            a = {"id": f"acct_{len(self.accounts) + 1}", "charges_enabled": False}
            self.accounts[a["id"]] = a
            return a
        if parts[0] == "accounts":
            return self.accounts[parts[1]]
        if parts == ["account_links"]:
            return {"url": f"https://connect.stripe.test/setup/{data['account']}"}
        if parts == ["payment_intents"]:
            pi = {
                "id": f"pi_{len(self.intents) + 1}",
                "client_secret": f"pi_{len(self.intents) + 1}_secret",
                "status": "requires_payment_method",
                "amount": data["amount"],
                "application_fee_amount": data["application_fee_amount"],
                "destination": data["transfer_data"]["destination"],
            }
            self.intents[pi["id"]] = pi
            return pi
        if parts[0] == "payment_intents" and len(parts) == 2:
            return self.intents[parts[1]]
        if parts[0] == "payment_intents" and parts[2] == "cancel":
            pi = self.intents[parts[1]]
            if pi["status"] == "succeeded":
                raise payments.StripeError(400, "already succeeded")
            pi["status"] = "canceled"
            self.canceled.append(pi["id"])
            return pi
        if parts == ["refunds"]:
            self.refunds.append(data["payment_intent"])
            return {"id": "re_1"}
        raise AssertionError(f"unexpected Stripe call {method} {path}")


@pytest.fixture
def stripe(monkeypatch):
    fake = FakeStripe()
    monkeypatch.setattr(settings, "stripe_secret_key", "sk_test_x")
    monkeypatch.setattr(settings, "stripe_publishable_key", "pk_test_x")
    monkeypatch.setattr(settings, "stripe_webhook_secret", "whsec_x")
    monkeypatch.setattr(settings, "apple_pay_merchant_id", "merchant.com.example")
    monkeypatch.setattr(payments, "call", fake.call)
    return fake


async def paying_kitchen(client, stripe, **over):
    dana = await make_user(client, "Dana")
    b = await post_batch(client, dana, **over)
    r = await client.post("/v1/kitchens/me/payouts", headers=dana)
    assert r.status_code == 200, r.text
    assert r.json()["onboarding_url"].startswith("https://connect.stripe.test/")
    assert not r.json()["ready"]
    stripe.accounts["acct_1"]["charges_enabled"] = True
    assert (await client.get("/v1/kitchens/me/payouts", headers=dana)).json()["ready"]
    return dana, b


async def webhook(client, event: dict, secret="whsec_x"):
    payload = json.dumps(event).encode()
    return await client.post(
        "/v1/stripe/webhook",
        content=payload,
        headers={"Stripe-Signature": payments.sign_for_tests(payload, secret)},
    )


def succeeded(pi_id: str) -> dict:
    return {"type": "payment_intent.succeeded", "data": {"object": {"id": pi_id}}}


async def test_without_stripe_everything_is_pay_at_pickup(client):
    dana = await make_user(client, "Dana")
    b = await post_batch(client, dana)
    assert b["kitchen"]["pay"] == "at_pickup"
    assert (await client.get("/v1/kitchens/me/payouts", headers=dana)).json() == {
        "enabled": False,
        "ready": False,
        "onboarding_url": None,
    }
    you = await make_user(client, "You")
    o = (await client.post("/v1/orders", headers=you, json=reserve_body(b))).json()
    r = await client.post(f"/v1/orders/{o['id']}/pay", headers=you)
    assert r.status_code == 409


async def test_paying_in_the_app(client, stripe):
    dana, b = await paying_kitchen(client, stripe)
    you = await make_user(client, "You")
    page = (await client.get(f"/v1/drops/{b['id']}", headers=you)).json()
    assert page["kitchen"]["pay"] == "in_app"

    o = (await client.post("/v1/orders", headers=you, json=reserve_body(b, qty=2))).json()
    assert o["payment"] == "unpaid" and o["subtotal_cents"] == 1200 and o["service_cents"] == 60
    # Not paid yet: nothing about where, no code, and the cook doesn't see it.
    assert o["address"] is None and o["lat"] is None and o["pickup_code"] == "" and o["pickup_note"] == ""
    assert (await client.get("/v1/kitchens/me/orders", headers=dana)).json() == []

    first = (await client.post(f"/v1/orders/{o['id']}/pay", headers=you)).json()
    again = (await client.post(f"/v1/orders/{o['id']}/pay", headers=you)).json()
    assert first == again and first["client_secret"] == "pi_1_secret" and len(stripe.intents) == 1
    assert first["amount_cents"] == 1260 and first["publishable_key"] == "pk_test_x"
    assert first["merchant_id"] == "merchant.com.example"
    pi = stripe.intents["pi_1"]
    assert (pi["amount"], pi["application_fee_amount"], pi["destination"]) == (1260, 60, "acct_1")

    assert (await webhook(client, succeeded("pi_1"), secret="wrong")).status_code == 400
    stripe.intents["pi_1"]["status"] = "succeeded"
    assert (await webhook(client, succeeded("pi_1"))).status_code == 200
    paid = (await client.get(f"/v1/orders/{o['id']}", headers=you)).json()
    assert paid["payment"] == "paid" and paid["address"] == "3100 24th St" and len(paid["pickup_code"]) == 3
    # Paying again after it went through: nothing to pay, no second intent.
    done = (await client.post(f"/v1/orders/{o['id']}/pay", headers=you)).json()
    assert done["payment"] == "paid" and done["client_secret"] is None and len(stripe.intents) == 1
    # The webhook arriving twice changes nothing.
    assert (await webhook(client, succeeded("pi_1"))).status_code == 200
    assert [x["id"] for x in (await client.get("/v1/kitchens/me/orders", headers=dana)).json()] == [o["id"]]


async def test_finished_payment_shows_before_the_webhook(client, stripe):
    _, b = await paying_kitchen(client, stripe)
    you = await make_user(client, "You")
    o = (await client.post("/v1/orders", headers=you, json=reserve_body(b))).json()
    await client.post(f"/v1/orders/{o['id']}/pay", headers=you)
    stripe.intents["pi_1"]["status"] = "succeeded"
    assert (await client.get(f"/v1/orders/{o['id']}", headers=you)).json()["payment"] == "paid"


async def age(engine, order_id: str, minutes: int):
    async with engine.begin() as conn:
        await conn.execute(
            text("UPDATE orders SET created_at = now() - make_interval(mins => :m) WHERE id = :id"),
            {"m": minutes, "id": order_id},
        )


async def test_an_unpaid_hold_runs_out(client, engine, stripe):
    _, b = await paying_kitchen(client, stripe, total=2, per_slot=10)
    you = await make_user(client, "You")
    other = await make_user(client, "Other")
    held = (await client.post("/v1/orders", headers=you, json=reserve_body(b, qty=2))).json()
    r = await client.post("/v1/orders", headers=other, json=reserve_body(b))
    assert r.status_code == 409 and r.json()["detail"] == "Sold out"

    await age(engine, held["id"], 16)
    r = await client.post("/v1/orders", headers=other, json=reserve_body(b))
    assert r.status_code == 201, r.text
    assert (await client.get(f"/v1/drops/{b['id']}", headers=you)).json()["left"] == 1
    r = await client.post(f"/v1/orders/{held['id']}/pay", headers=you)
    assert r.status_code == 409 and "ran out" in r.json()["detail"]


async def test_a_hold_being_paid_is_kept_and_a_paid_one_is_never_released(client, engine, stripe):
    _, b = await paying_kitchen(client, stripe, total=2, per_slot=10)
    you = await make_user(client, "You")
    other = await make_user(client, "Other")
    held = (await client.post("/v1/orders", headers=you, json=reserve_body(b, qty=2))).json()
    await client.post(f"/v1/orders/{held['id']}/pay", headers=you)
    # Twenty minutes in, still in PaymentSheet: kept.
    await age(engine, held["id"], 20)
    assert (await client.post("/v1/orders", headers=other, json=reserve_body(b))).status_code == 409
    # Paid at minute 40 but the webhook hasn't come: found paid, kept.
    stripe.intents["pi_1"]["status"] = "succeeded"
    await age(engine, held["id"], 40)
    assert (await client.post("/v1/orders", headers=other, json=reserve_body(b))).status_code == 409
    assert (await client.get(f"/v1/orders/{held['id']}", headers=you)).json()["payment"] == "paid"
    assert stripe.canceled == []


async def test_money_after_the_hold_ran_out(client, engine, stripe):
    _, b = await paying_kitchen(client, stripe, total=2, per_slot=10)
    you = await make_user(client, "You")
    other = await make_user(client, "Other")

    # Still stock left when the late payment lands: the order comes back, paid.
    held = (await client.post("/v1/orders", headers=you, json=reserve_body(b, qty=1))).json()
    await client.post(f"/v1/orders/{held['id']}/pay", headers=you)
    await age(engine, held["id"], 31)
    assert (await client.post("/v1/orders", headers=other, json=reserve_body(b))).status_code == 201
    assert stripe.canceled == ["pi_1"]
    stripe.intents["pi_1"]["status"] = "succeeded"  # paid in the same instant it was canceled
    await webhook(client, succeeded("pi_1"))
    back = (await client.get(f"/v1/orders/{held['id']}", headers=you)).json()
    assert back["status"] == "reserved" and back["payment"] == "paid"
    assert (await client.get(f"/v1/drops/{b['id']}", headers=you)).json()["left"] == 0
    assert stripe.refunds == []


async def test_late_money_on_a_sold_out_batch_is_refunded(client, engine, stripe):
    _, b = await paying_kitchen(client, stripe, total=1, per_slot=10)
    you = await make_user(client, "You")
    other = await make_user(client, "Other")
    held = (await client.post("/v1/orders", headers=you, json=reserve_body(b))).json()
    await client.post(f"/v1/orders/{held['id']}/pay", headers=you)
    await age(engine, held["id"], 31)
    taken = (await client.post("/v1/orders", headers=other, json=reserve_body(b))).json()
    assert taken["payment"] == "unpaid"
    stripe.intents["pi_1"]["status"] = "succeeded"
    assert (await webhook(client, succeeded("pi_1"))).status_code == 200
    assert stripe.refunds == ["pi_1"]
    assert (await client.get(f"/v1/orders/{held['id']}", headers=you)).json()["payment"] == "refunded"


async def test_payouts_turn_on_from_the_webhook(client, stripe):
    dana = await make_user(client, "Dana")
    await post_batch(client, dana)
    await client.post("/v1/kitchens/me/payouts", headers=dana)
    r = await webhook(
        client, {"type": "account.updated", "data": {"object": {"id": "acct_1", "charges_enabled": True}}}
    )
    assert r.status_code == 200
    assert (await client.get("/v1/kitchens/me", headers=dana)).json()["pay"] == "in_app"
