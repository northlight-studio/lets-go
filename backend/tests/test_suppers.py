"""Supper club: hosting, asking for a seat, the host choosing, the address only after acceptance,
paying through the batch payments path (against the fake Stripe), refunds, reviews both ways and
adding the table as friends."""

import uuid
from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import text

from app import payments
from app.config import settings
from app.geo import distance_m
from tests.conftest import HERE, make_user, offset
from tests.test_batches import JPEG, FakeStripe, succeeded, webhook
from tests.test_people import befriend

ADDRESS = "3100 24th St"


def supper_body(days: float = 4, **over) -> dict:
    start = (datetime.now(UTC) + timedelta(days=days)).replace(second=0, microsecond=0)
    lat, lon = offset(300, 200)
    body = {
        "title": "Sunday supper: Oaxacan night",
        "starts_at": start.isoformat(),
        "ends_at": (start + timedelta(hours=3)).isoformat(),
        "seats": 6,
        "price_cents": 1800,
        "menu": [
            {"name": "Tlayudas", "note": "black beans, quesillo"},
            {"name": "Mole negro", "note": "chicken or squash"},
            {"name": "Café de olla", "note": "flan"},
        ],
        "tags": ["Vegetarian option", "Contains nuts"],
        "house_notes": "Shoes off. We have a cat.",
        "permit_confirmed": True,
        "address": ADDRESS,
        "lat": lat,
        "lon": lon,
    }
    body.update(over)
    return body


async def host(client, headers, **over) -> dict:
    r = await client.post("/v1/suppers", headers=headers, json=supper_body(**over))
    assert r.status_code == 201, r.text
    return r.json()


async def ask(client, headers, supper, note="Hi! Two doors down.") -> dict:
    r = await client.post(f"/v1/suppers/{supper['id']}/seats", headers=headers, json={"note": note})
    assert r.status_code == 201, r.text
    return r.json()


async def accept(client, host_headers, seat_id) -> list[dict]:
    r = await client.post(f"/v1/supper-seats/{seat_id}/accept", headers=host_headers)
    assert r.status_code == 200, r.text
    return r.json()


async def get(client, headers, supper) -> dict:
    r = await client.get(f"/v1/suppers/{supper['id']}", headers=headers)
    assert r.status_code == 200, r.text
    return r.json()


async def shift(engine, supper_id, hours: float) -> None:
    """Moves a supper (start and end) by `hours`; negative is into the past."""
    async with engine.begin() as conn:
        await conn.execute(
            text(
                "UPDATE suppers SET starts_at = starts_at + make_interval(secs => :s), "
                "ends_at = ends_at + make_interval(secs => :s) WHERE id = :id"
            ),
            {"s": hours * 3600, "id": supper_id},
        )


@pytest.fixture
def stripe(monkeypatch):
    fake = FakeStripe()
    monkeypatch.setattr(settings, "stripe_secret_key", "sk_test_x")
    monkeypatch.setattr(settings, "stripe_publishable_key", "pk_test_x")
    monkeypatch.setattr(settings, "stripe_webhook_secret", "whsec_x")
    monkeypatch.setattr(payments, "call", fake.call)
    return fake


async def paying_host(client, stripe, **over):
    ana = await make_user(client, "Ana")
    s = await host(client, ana, **over)
    assert (await client.post("/v1/kitchens/me/payouts", headers=ana)).status_code == 200
    stripe.accounts["acct_1"]["charges_enabled"] = True
    assert (await client.get("/v1/kitchens/me/payouts", headers=ana)).json()["ready"]
    return ana, await get(client, ana, s)


# Hosting


async def test_hosting_opens_a_kitchen_and_the_host_sees_everything(client):
    ana = await make_user(client, "Ana")
    s = await host(client, ana)
    assert s["is_mine"] and s["exact"] and s["address"] == ADDRESS
    assert s["seats"] == 6 and s["taken"] == 0 and s["seats_left"] == 6
    assert s["price_cents"] == 1800 and s["pay"] == "at_door" and s["seat_total_cents"] == 1800
    assert [c["name"] for c in s["menu"]] == ["Tlayudas", "Mole negro", "Café de olla"]
    assert s["menu"][0]["note"] == "black beans, quesillo"
    assert s["tags"] == ["Vegetarian option", "Contains nuts"] and s["house_notes"].startswith("Shoes off")
    assert s["host"]["display_name"] == "Ana" and s["suppers_hosted"] == 0 and s["host_rating"] is None
    k = (await client.get("/v1/kitchens/me", headers=ana)).json()
    assert k["id"] == s["kitchen_id"]
    # A batch after reuses the same kitchen and address.
    from tests.test_batches import post_batch

    b = await post_batch(client, ana, address=None, permit_confirmed=False)
    assert b["kitchen"]["id"] == s["kitchen_id"]


async def test_hosting_needs_an_address_a_permit_and_a_future_time(client):
    ana = await make_user(client, "Ana")
    r = await client.post("/v1/suppers", headers=ana, json=supper_body(address=None))
    assert r.status_code == 422 and "address" in r.json()["detail"]
    r = await client.post("/v1/suppers", headers=ana, json=supper_body(permit_confirmed=False))
    assert r.status_code == 409 and "permit" in r.json()["detail"]
    r = await client.post("/v1/suppers", headers=ana, json=supper_body(days=-1))
    assert r.status_code == 422
    r = await client.post("/v1/suppers", headers=ana, json=supper_body(seats=0))
    assert r.status_code == 422


async def test_the_photo(client):
    ana = await make_user(client, "Ana")
    you = await make_user(client, "You")
    s = await host(client, ana)
    r = await client.post(
        f"/v1/suppers/{s['id']}/photo", headers={**you, "Content-Type": "image/jpeg"}, content=JPEG
    )
    assert r.status_code == 404
    r = await client.post(
        f"/v1/suppers/{s['id']}/photo", headers={**ana, "Content-Type": "image/jpeg"}, content=JPEG
    )
    assert r.status_code == 201, r.text
    url = r.json()["photo_url"]
    assert (await get(client, you, s))["photo_url"] == url
    assert (await client.get(url)).content == JPEG


# The page a neighbor sees, and the address


async def test_the_address_only_after_the_host_accepts(client):
    ana = await make_user(client, "Ana")
    you = await make_user(client, "You")
    s = await host(client, ana)
    seen = await get(client, you, s)
    assert seen["address"] is None and not seen["exact"] and seen["my_seat"] is None
    real = offset(300, 200)
    away = distance_m(seen["lat"], seen["lon"], *real)
    assert 55 <= away <= 155
    # Its house notes and menu are there before asking.
    assert seen["house_notes"] and len(seen["menu"]) == 3

    asked = await ask(client, you, s)
    assert asked["my_seat"]["status"] == "asked" and asked["address"] is None
    assert asked["seats_left"] == 6

    guests = await accept(client, ana, asked["my_seat"]["id"])
    assert [g["status"] for g in guests] == ["accepted"]
    mine = await get(client, you, s)
    assert mine["my_seat"]["status"] == "accepted" and mine["my_seat"]["payment"] == "at_door"
    assert mine["address"] == ADDRESS and mine["exact"]
    assert (mine["lat"], mine["lon"]) == pytest.approx(real)
    assert mine["taken"] == 1 and mine["seats_left"] == 5
    # Someone else still doesn't see it.
    other = await make_user(client, "Other")
    assert (await get(client, other, s))["address"] is None


async def test_declined_never_sees_the_address_and_cant_ask_again(client):
    ana = await make_user(client, "Ana")
    you = await make_user(client, "You")
    s = await host(client, ana)
    asked = await ask(client, you, s)
    r = await client.post(f"/v1/supper-seats/{asked['my_seat']['id']}/decline", headers=ana)
    assert r.status_code == 200 and r.json() == []
    seen = await get(client, you, s)
    assert seen["my_seat"]["status"] == "declined" and seen["address"] is None
    r = await client.post(f"/v1/suppers/{s['id']}/seats", headers=you, json={})
    assert r.status_code == 409 and "Ana" in r.json()["detail"]


async def test_only_the_host_chooses(client):
    ana = await make_user(client, "Ana")
    you = await make_user(client, "You")
    other = await make_user(client, "Other")
    s = await host(client, ana)
    asked = await ask(client, you, s)
    seat = asked["my_seat"]["id"]
    for who in (you, other):
        assert (await client.post(f"/v1/supper-seats/{seat}/accept", headers=who)).status_code == 404
        assert (await client.get(f"/v1/suppers/{s['id']}/requests", headers=who)).status_code == 404
    r = await client.post(f"/v1/suppers/{s['id']}/seats", headers=ana, json={})
    assert r.status_code == 409


# Seats


async def test_seats_never_go_past_the_total(client):
    ana = await make_user(client, "Ana")
    s = await host(client, ana, seats=2)
    guests = [await make_user(client, f"Guest {i}") for i in range(3)]
    seats = [(await ask(client, g, s))["my_seat"]["id"] for g in guests]
    # Asking again while waiting changes nothing.
    again = await ask(client, guests[0], s)
    assert again["my_seat"]["id"] == seats[0]
    await accept(client, ana, seats[0])
    await accept(client, ana, seats[1])
    r = await client.post(f"/v1/supper-seats/{seats[2]}/accept", headers=ana)
    assert r.status_code == 409 and r.json()["detail"] == "Every seat is given"
    # Accepting twice is the same yes.
    assert len(await accept(client, ana, seats[0])) == 3
    full = await get(client, guests[2], s)
    assert full["seats_left"] == 0 and full["taken"] == 2
    late = await make_user(client, "Late")
    r = await client.post(f"/v1/suppers/{s['id']}/seats", headers=late, json={})
    assert r.status_code == 409 and r.json()["detail"] == "Every seat is taken"


async def test_the_host_sees_each_guests_reviews_and_suppers(client, engine):
    ana = await make_user(client, "Ana")
    ben = await make_user(client, "Ben")
    you = await make_user(client, "You")
    # You went to Ben's supper and Ben reviewed you.
    first = await host(client, ben)
    seat = (await ask(client, you, first))["my_seat"]["id"]
    await accept(client, ben, seat)
    await shift(engine, first["id"], -4 * 24 - 5)
    r = await client.post(
        f"/v1/suppers/{first['id']}/reviews",
        headers=ben,
        json={"subject_id": (await me(client, you)), "stars": 5, "text": "Brought dessert, lovely."},
    )
    assert r.status_code == 201, r.text

    s = await host(client, ana)
    await ask(client, you, s, note="Ben said I'd love it")
    await befriend(client, ana, you)
    [g] = (await client.get(f"/v1/suppers/{s['id']}/requests", headers=ana)).json()
    assert g["guest"]["display_name"] == "You" and g["note"] == "Ben said I'd love it"
    assert g["suppers_attended"] == 1 and g["rating"] == 5 and g["review_count"] == 1
    assert g["reviews"] == ["Brought dessert, lovely."] and g["is_friend"]
    assert (await get(client, ana, s))["waiting"] == 1


async def me(client, headers) -> str:
    return (await client.get("/v1/me", headers=headers)).json()["id"]


async def test_the_list_for_the_map_and_your_block(client, engine):
    ana = await make_user(client, "Ana")
    you = await make_user(client, "You")
    soon = await host(client, ana, days=1)
    q = {"lat": HERE[0], "lon": HERE[1]}
    listed = (await client.get("/v1/suppers", params=q, headers=you)).json()
    assert [x["id"] for x in listed] == [soon["id"]]
    assert listed[0]["address"] is None and listed[0]["distance_m"] > 0
    # Far away isn't listed.
    far = (await client.get("/v1/suppers", params={"lat": HERE[0] + 1, "lon": HERE[1]}, headers=you)).json()
    assert far == []
    # Full ones drop off "with seats"; canceled and ended ones drop off everything.
    other = await make_user(client, "Other")
    small = await host(client, other, seats=1, days=2)
    seat = (await ask(client, you, small))["my_seat"]["id"]
    await accept(client, other, seat)
    with_seats = (await client.get("/v1/suppers", params={**q, "with_seats": True}, headers=ana)).json()
    assert [x["id"] for x in with_seats] == [soon["id"]]
    await client.delete(f"/v1/suppers/{small['id']}", headers=other)
    await shift(engine, soon["id"], -30 * 24)
    assert (await client.get("/v1/suppers", params=q, headers=you)).json() == []


async def test_friends_going_and_my_suppers(client):
    ana = await make_user(client, "Ana")
    maya = await make_user(client, "Maya")
    you = await make_user(client, "You")
    await befriend(client, maya, you)
    s = await host(client, ana)
    seat = (await ask(client, maya, s))["my_seat"]["id"]
    assert (await get(client, you, s))["friends_going"] == []  # asked isn't going
    await accept(client, ana, seat)
    going = (await get(client, you, s))["friends_going"]
    assert [p["display_name"] for p in going] == ["Maya"]
    mine = (await client.get("/v1/me/suppers", headers=maya)).json()
    assert [x["id"] for x in mine["going"]] == [s["id"]] and mine["hosting"] == []
    theirs = (await client.get("/v1/me/suppers", headers=ana)).json()
    assert [x["id"] for x in theirs["hosting"]] == [s["id"]]


# Paying


async def test_without_stripe_a_seat_is_paid_at_the_door(client):
    ana = await make_user(client, "Ana")
    you = await make_user(client, "You")
    s = await host(client, ana)
    seat = (await ask(client, you, s))["my_seat"]["id"]
    await accept(client, ana, seat)
    mine = (await get(client, you, s))["my_seat"]
    assert mine["payment"] == "at_door" and mine["service_cents"] == 0 and mine["total_cents"] == 1800
    assert (await client.post(f"/v1/supper-seats/{seat}/pay", headers=you)).status_code == 409


async def test_a_seat_is_paid_in_the_app_once_accepted(client, stripe):
    ana, s = await paying_host(client, stripe)
    assert s["pay"] == "in_app" and s["service_cents"] == 90 and s["seat_total_cents"] == 1890
    you = await make_user(client, "You")
    seat = (await ask(client, you, s))["my_seat"]["id"]
    # Nothing to pay before the host says yes.
    assert (await client.post(f"/v1/supper-seats/{seat}/pay", headers=you)).status_code == 409
    await accept(client, ana, seat)
    mine = await get(client, you, s)
    assert mine["my_seat"]["payment"] == "unpaid" and mine["my_seat"]["pay_by"] is not None
    # Accepted but not paid: the address waits for the money.
    assert mine["address"] is None
    assert mine["taken"] == 1

    first = (await client.post(f"/v1/supper-seats/{seat}/pay", headers=you)).json()
    again = (await client.post(f"/v1/supper-seats/{seat}/pay", headers=you)).json()
    assert first == again and first["order_id"] == seat and first["amount_cents"] == 1890
    assert len(stripe.intents) == 1
    pi = stripe.intents["pi_1"]
    assert pi["application_fee_amount"] == 90 and pi["destination"] == "acct_1"
    assert "letsgo-seat-" + seat in stripe.by_key
    # Someone else can't pay for it.
    other = await make_user(client, "Other")
    assert (await client.post(f"/v1/supper-seats/{seat}/pay", headers=other)).status_code == 404

    assert (await webhook(client, succeeded("pi_1"))).status_code == 200
    paid = await get(client, you, s)
    assert paid["my_seat"]["payment"] == "paid" and paid["address"] == ADDRESS


async def test_paid_shows_before_the_webhook(client, stripe):
    ana, s = await paying_host(client, stripe)
    you = await make_user(client, "You")
    seat = (await ask(client, you, s))["my_seat"]["id"]
    await accept(client, ana, seat)
    await client.post(f"/v1/supper-seats/{seat}/pay", headers=you)
    stripe.intents["pi_1"]["status"] = "succeeded"
    assert (await get(client, you, s))["my_seat"]["payment"] == "paid"


async def test_an_unpaid_seat_goes_back_after_a_day(client, engine, stripe):
    ana, s = await paying_host(client, stripe, seats=1)
    you = await make_user(client, "You")
    other = await make_user(client, "Other")
    seat = (await ask(client, you, s))["my_seat"]["id"]
    await accept(client, ana, seat)
    r = await client.post(f"/v1/suppers/{s['id']}/seats", headers=other, json={})
    assert r.status_code == 409
    async with engine.begin() as conn:
        await conn.execute(
            text("UPDATE supper_seats SET decided_at = now() - interval '25 hours' WHERE id = :id"),
            {"id": seat},
        )
    late = await ask(client, other, s)
    assert late["my_seat"]["status"] == "asked"
    assert (await get(client, you, s))["my_seat"]["status"] == "lapsed"
    r = await client.post(f"/v1/supper-seats/{seat}/pay", headers=you)
    assert r.status_code == 409 and "ran out" in r.json()["detail"]
    # Asking again starts fresh.
    fresh = await ask(client, you, s)
    assert fresh["my_seat"]["status"] == "asked" and fresh["my_seat"]["id"] != seat


# Refunds and backing out


async def test_the_host_canceling_refunds_everyone_who_paid(client, stripe):
    ana, s = await paying_host(client, stripe)
    you = await make_user(client, "You")
    waiting = await make_user(client, "Waiting")
    seat = (await ask(client, you, s))["my_seat"]["id"]
    await ask(client, waiting, s)
    await accept(client, ana, seat)
    await client.post(f"/v1/supper-seats/{seat}/pay", headers=you)
    await webhook(client, succeeded("pi_1"))
    r = await client.delete(f"/v1/suppers/{s['id']}", headers=ana)
    assert r.status_code == 200 and r.json()["canceled"]
    assert stripe.refunds == ["pi_1"]
    mine = (await get(client, you, s))["my_seat"]
    assert mine["status"] == "canceled" and mine["payment"] == "refunded"
    assert (await get(client, waiting, s))["my_seat"]["status"] == "canceled"
    # Gone from the list, and nobody can ask.
    assert (
        await client.get("/v1/suppers", params={"lat": HERE[0], "lon": HERE[1]}, headers=you)
    ).json() == []
    other = await make_user(client, "Other")
    assert (await client.post(f"/v1/suppers/{s['id']}/seats", headers=other, json={})).status_code == 409


async def test_backing_out_early_is_refunded_late_is_not(client, engine, stripe):
    ana, s = await paying_host(client, stripe)
    early, late = await make_user(client, "Early"), await make_user(client, "Late")
    for i, who in enumerate((early, late), start=1):
        seat = (await ask(client, who, s))["my_seat"]["id"]
        await accept(client, ana, seat)
        await client.post(f"/v1/supper-seats/{seat}/pay", headers=who)
        await webhook(client, succeeded(f"pi_{i}"))
    r = await client.delete(f"/v1/suppers/{s['id']}/seat", headers=early)
    assert r.status_code == 200
    assert r.json()["my_seat"]["status"] == "withdrawn" and r.json()["my_seat"]["payment"] == "refunded"
    assert stripe.refunds == ["pi_1"]
    # Within 48 hours of the start: the seat goes back, the money doesn't.
    await shift(engine, s["id"], -4 * 24 + 24)
    r = await client.delete(f"/v1/suppers/{s['id']}/seat", headers=late)
    assert r.json()["my_seat"]["payment"] == "paid" and r.json()["my_seat"]["status"] == "withdrawn"
    assert stripe.refunds == ["pi_1"]
    assert (await get(client, ana, s))["taken"] == 0


async def test_backing_out_while_asking_and_asking_again(client):
    ana = await make_user(client, "Ana")
    you = await make_user(client, "You")
    s = await host(client, ana)
    first = (await ask(client, you, s))["my_seat"]["id"]
    r = await client.delete(f"/v1/suppers/{s['id']}/seat", headers=you)
    assert r.json()["my_seat"]["status"] == "withdrawn"
    assert (await client.get(f"/v1/suppers/{s['id']}/requests", headers=ana)).json() == []
    again = await ask(client, you, s)
    assert again["my_seat"]["status"] == "asked" and again["my_seat"]["id"] != first


async def test_money_after_the_seat_went_back_is_refunded(client, engine, stripe):
    ana, s = await paying_host(client, stripe, seats=1)
    you, other = await make_user(client, "You"), await make_user(client, "Other")
    seat = (await ask(client, you, s))["my_seat"]["id"]
    await accept(client, ana, seat)
    await client.post(f"/v1/supper-seats/{seat}/pay", headers=you)
    async with engine.begin() as conn:
        await conn.execute(
            text("UPDATE supper_seats SET decided_at = now() - interval '26 hours' WHERE id = :id"),
            {"id": seat},
        )
    other_seat = (await ask(client, other, s))["my_seat"]["id"]
    await accept(client, ana, other_seat)
    assert stripe.canceled == ["pi_1"]
    stripe.intents["pi_1"]["status"] = "succeeded"  # paid in the same instant
    assert (await webhook(client, succeeded("pi_1"))).status_code == 200
    assert stripe.refunds == ["pi_1"]
    assert (await get(client, you, s))["my_seat"]["payment"] == "refunded"


# Afterwards


async def test_reviews_both_ways_after_the_supper(client, engine):
    ana = await make_user(client, "Ana")
    you = await make_user(client, "You")
    stranger = await make_user(client, "Stranger")
    s = await host(client, ana)
    seat = (await ask(client, you, s))["my_seat"]["id"]
    await accept(client, ana, seat)
    ana_id, you_id = await me(client, ana), await me(client, you)
    body = {"subject_id": ana_id, "stars": 5, "text": "The mole!"}
    r = await client.post(f"/v1/suppers/{s['id']}/reviews", headers=you, json=body)
    assert r.status_code == 409 and r.json()["detail"] == "After the supper"
    await shift(engine, s["id"], -4 * 24 - 4)
    r = await client.post(f"/v1/suppers/{s['id']}/reviews", headers=you, json=body)
    assert r.status_code == 201, r.text
    assert [t["reviewed"] for t in r.json()["table"]] == [True]
    r = await client.post(f"/v1/suppers/{s['id']}/reviews", headers=you, json=body)
    assert r.status_code == 409
    r = await client.post(
        f"/v1/suppers/{s['id']}/reviews", headers=ana, json={"subject_id": you_id, "stars": 4}
    )
    assert r.status_code == 201
    r = await client.post(f"/v1/suppers/{s['id']}/reviews", headers=stranger, json=body)
    assert r.status_code == 404
    page = await get(client, stranger, s)
    assert page["host_rating"] == 5 and page["host_review_count"] == 1 and page["suppers_hosted"] == 1
    assert page["table"] == []


async def test_the_table_adds_each_other_as_friends(client, engine):
    ana = await make_user(client, "Ana")
    you = await make_user(client, "You")
    maya = await make_user(client, "Maya")
    s = await host(client, ana)
    for who in (you, maya):
        await accept(client, ana, (await ask(client, who, s))["my_seat"]["id"])
    maya_id = await me(client, maya)
    r = await client.post(f"/v1/suppers/{s['id']}/table/{maya_id}/hi", headers=you)
    assert r.status_code == 409
    await shift(engine, s["id"], -4 * 24 - 1)
    table = (await get(client, you, s))["table"]
    assert sorted((t["display_name"], t["is_host"]) for t in table) == [("Ana", True), ("Maya", False)]
    r = await client.post(f"/v1/suppers/{s['id']}/table/{maya_id}/hi", headers=you)
    assert r.json() == {"connected": False}
    assert [t["said_hi"] for t in (await get(client, you, s))["table"] if t["id"] == maya_id] == [True]
    you_id = await me(client, you)
    r = await client.post(f"/v1/suppers/{s['id']}/table/{you_id}/hi", headers=maya)
    assert r.json() == {"connected": True}
    friends = (await client.get("/v1/people", headers=you)).json()["friends"]
    assert [f["display_name"] for f in friends] == ["Maya"]
    # Not someone who wasn't there.
    outsider = await make_user(client, "Outsider")
    r = await client.post(f"/v1/suppers/{s['id']}/table/{await me(client, outsider)}/hi", headers=you)
    assert r.status_code == 404


async def test_unknown_supper(client):
    you = await make_user(client, "You")
    assert (await client.get(f"/v1/suppers/{uuid.uuid4()}", headers=you)).status_code == 404


async def test_your_block_lists_a_supper_with_seats(client):
    ana = await make_user(client, "Ana")
    you = await make_user(client, "You")
    s = await host(client, ana, seats=1)
    q = {"lat": HERE[0], "lon": HERE[1]}
    [row] = [
        i
        for i in (await client.get("/v1/me/block", params=q, headers=you)).json()["items"]
        if i["kind"] == "supper"
    ]
    assert row["id"] == s["id"] and row["seats_left"] == 1 and row["price_cents"] == 1800
    assert row["name"] == "Ana's kitchen" and row["title"] == s["title"] and row["walk_min"] is not None
    # Not for the host, and gone once the seat is given.
    host_rows = (await client.get("/v1/me/block", params=q, headers=ana)).json()["items"]
    assert "supper" not in [i["kind"] for i in host_rows]
    other = await make_user(client, "Other")
    await accept(client, ana, (await ask(client, other, s))["my_seat"]["id"])
    rows = (await client.get("/v1/me/block", params=q, headers=you)).json()["items"]
    assert "supper" not in [i["kind"] for i in rows]
