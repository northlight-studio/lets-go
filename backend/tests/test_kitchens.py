import asyncio
import uuid
from datetime import UTC, datetime, timedelta

from tests.conftest import HERE, make_user, offset


async def open_kitchen(client, headers, permitted=True):
    lat, lon = offset(200, 250)
    r = await client.post(
        "/v1/kitchens",
        headers=headers,
        json={
            "name": "Dana's Porch Pizza",
            "cuisine": "Pizza",
            "lat": lat,
            "lon": lon,
            "pickup_note": "Side gate, ring the bell",
            "porch_tables": 2,
            "permit_confirmed": permitted,
            "handler_card_confirmed": permitted,
        },
    )
    assert r.status_code == 201, r.text
    m = await client.post(
        "/v1/kitchens/me/menu", headers=headers, json={"name": "Margherita", "price_cents": 1400}
    )
    return r.json(), m.json()


def slot_start(minutes_from_now: int) -> datetime:
    t = datetime.now(UTC).replace(second=0, microsecond=0) + timedelta(minutes=minutes_from_now)
    return t - timedelta(minutes=t.minute % 15)


async def post_drop(client, headers, total=24, per_slot=4, starts=None):
    s = starts or slot_start(30)
    r = await client.post(
        "/v1/kitchens/me/drops",
        headers=headers,
        json={
            "starts_at": s.isoformat(),
            "ends_at": (s + timedelta(minutes=90)).isoformat(),
            "total": total,
            "per_slot": per_slot,
        },
    )
    assert r.status_code == 201, r.text
    return r.json()


def order_body(drop, item, qty=1, slot=0, client_id=None, porch=False):
    pickup = datetime.fromisoformat(drop["starts_at"]) + timedelta(minutes=15 * slot)
    return {
        "client_id": str(client_id or uuid.uuid4()),
        "drop_id": drop["id"],
        "pickup_at": pickup.isoformat(),
        "lines": [{"menu_item_id": item["id"], "quantity": qty}],
        "eat_on_porch": porch,
    }


async def test_kitchen_shows_nearby_with_next_drop(client):
    dana = await make_user(client, "Dana")
    k, item = await open_kitchen(client, dana)
    await post_drop(client, dana)
    you = await make_user(client, "You")
    r = await client.get("/v1/nearby", params={"lat": HERE[0], "lon": HERE[1]}, headers=you)
    ks = r.json()["kitchens"]
    assert ks[0]["name"] == "Dana's Porch Pizza" and ks[0]["cook_name"] == "Dana"
    assert ks[0]["next_drop"]["left"] == 24 and ks[0]["permitted"]


async def test_one_kitchen_per_person(client):
    dana = await make_user(client, "Dana")
    await open_kitchen(client, dana)
    lat, lon = HERE
    r = await client.post(
        "/v1/kitchens", headers=dana, json={"name": "Two", "cuisine": "x", "lat": lat, "lon": lon}
    )
    assert r.status_code == 409


async def test_no_drop_without_permit(client):
    dana = await make_user(client, "Dana")
    await open_kitchen(client, dana, permitted=False)
    s = slot_start(30)
    r = await client.post(
        "/v1/kitchens/me/drops",
        headers=dana,
        json={
            "starts_at": s.isoformat(),
            "ends_at": (s + timedelta(hours=1)).isoformat(),
            "total": 5,
        },
    )
    assert r.status_code == 409


async def test_pickup_note_is_hidden_until_you_order(client):
    dana = await make_user(client, "Dana")
    k, item = await open_kitchen(client, dana)
    drop = await post_drop(client, dana)
    you = await make_user(client, "You")
    assert (await client.get(f"/v1/kitchens/{k['id']}", headers=you)).json()["pickup_note"] is None
    r = await client.post("/v1/orders", headers=you, json=order_body(drop, item, qty=2))
    assert r.status_code == 201, r.text
    o = r.json()
    assert o["pickup_note"] == "Side gate, ring the bell"
    # Paid to the cook at pickup (payments aren't configured), so no service fee on top.
    assert o["subtotal_cents"] == 2800 and o["service_cents"] == 0 and o["total_cents"] == 2800
    assert o["payment"] == "at_pickup" and len(o["pickup_code"]) == 3
    assert (await client.get(f"/v1/kitchens/{k['id']}", headers=you)).json()[
        "pickup_note"
    ] == "Side gate, ring the bell"


async def test_retrying_an_order_does_not_double_it(client):
    dana = await make_user(client, "Dana")
    _, item = await open_kitchen(client, dana)
    drop = await post_drop(client, dana)
    you = await make_user(client, "You")
    cid = uuid.uuid4()
    a = await client.post("/v1/orders", headers=you, json=order_body(drop, item, client_id=cid))
    b = await client.post("/v1/orders", headers=you, json=order_body(drop, item, client_id=cid))
    assert a.json()["id"] == b.json()["id"]
    me = (await client.get("/v1/kitchens/me", headers=dana)).json()
    assert me["next_drop"]["sold"] == 1


async def test_cannot_oversell_even_at_once(client):
    dana = await make_user(client, "Dana")
    _, item = await open_kitchen(client, dana)
    drop = await post_drop(client, dana, total=3, per_slot=20)
    buyers = [await make_user(client, f"B{i}") for i in range(6)]
    results = await asyncio.gather(
        *[client.post("/v1/orders", headers=h, json=order_body(drop, item)) for h in buyers]
    )
    assert sorted(r.status_code for r in results) == [201, 201, 201, 409, 409, 409]
    assert (await client.get("/v1/kitchens/me", headers=dana)).json()["next_drop"]["left"] == 0


async def test_slot_fills_up(client):
    dana = await make_user(client, "Dana")
    _, item = await open_kitchen(client, dana)
    drop = await post_drop(client, dana, per_slot=1)
    a, b = await make_user(client, "A"), await make_user(client, "B")
    assert (await client.post("/v1/orders", headers=a, json=order_body(drop, item))).status_code == 201
    r = await client.post("/v1/orders", headers=b, json=order_body(drop, item))
    assert r.status_code == 409 and "slot" in r.json()["detail"]
    assert (
        await client.post("/v1/orders", headers=b, json=order_body(drop, item, slot=1))
    ).status_code == 201


async def test_off_grid_pickup_time_rejected(client):
    dana = await make_user(client, "Dana")
    _, item = await open_kitchen(client, dana)
    drop = await post_drop(client, dana)
    you = await make_user(client, "You")
    body = order_body(drop, item)
    body["pickup_at"] = (datetime.fromisoformat(drop["starts_at"]) + timedelta(minutes=7)).isoformat()
    assert (await client.post("/v1/orders", headers=you, json=body)).status_code == 422


async def test_cannot_order_from_yourself_or_other_menus(client):
    dana = await make_user(client, "Dana")
    _, item = await open_kitchen(client, dana)
    drop = await post_drop(client, dana)
    assert (await client.post("/v1/orders", headers=dana, json=order_body(drop, item))).status_code == 409

    june = await make_user(client, "June")
    lat, lon = HERE
    await client.post(
        "/v1/kitchens", headers=june, json={"name": "Ice", "cuisine": "Ice cream", "lat": lat, "lon": lon}
    )
    other = (
        await client.post("/v1/kitchens/me/menu", headers=june, json={"name": "Cone", "price_cents": 600})
    ).json()
    you = await make_user(client, "You")
    assert (await client.post("/v1/orders", headers=you, json=order_body(drop, other))).status_code == 422


async def test_review_after_pickup_moves_the_rating(client):
    dana = await make_user(client, "Dana")
    k, item = await open_kitchen(client, dana)
    drop = await post_drop(client, dana)
    you = await make_user(client, "You")
    o = (await client.post("/v1/orders", headers=you, json=order_body(drop, item))).json()

    early = await client.post(f"/v1/orders/{o['id']}/review", headers=you, json={"stars": 5})
    assert early.status_code == 409
    await client.post(f"/v1/orders/{o['id']}/picked-up", headers=you)
    r = await client.post(
        f"/v1/orders/{o['id']}/review", headers=you, json={"stars": 4, "tags": ["Crust"], "text": "Good"}
    )
    assert r.json()["status"] == "reviewed"
    again = await client.post(f"/v1/orders/{o['id']}/review", headers=you, json={"stars": 1})
    assert again.status_code == 409

    detail = (await client.get(f"/v1/kitchens/{k['id']}", headers=you)).json()
    assert detail["rating"] == 4.0 and detail["review_count"] == 1
    assert detail["reviews"][0]["author_name"] == "You"


async def test_removed_item_leaves_menu_but_not_old_orders(client):
    dana = await make_user(client, "Dana")
    _, item = await open_kitchen(client, dana)
    drop = await post_drop(client, dana)
    you = await make_user(client, "You")
    await client.post("/v1/orders", headers=you, json=order_body(drop, item))
    await client.delete(f"/v1/kitchens/me/menu/{item['id']}", headers=dana)
    me = (await client.get("/v1/kitchens/me", headers=dana)).json()
    assert me["menu"] == []
    orders = (await client.get("/v1/orders", headers=you)).json()
    assert orders[0]["lines"][0]["name"] == "Margherita"


async def test_the_porch_table_names_only_friends(client):
    from tests.test_people import befriend

    dana, maya, stranger, you = (
        await make_user(client, "Dana"),
        await make_user(client, "Maya"),
        await make_user(client, "Stranger"),
        await make_user(client, "You"),
    )
    k, item = await open_kitchen(client, dana)
    drop = await post_drop(client, dana)
    await befriend(client, maya, you)
    for who, slot in ((maya, 1), (stranger, 2)):
        r = await client.post("/v1/orders", json=order_body(drop, item, slot=slot, porch=True), headers=who)
        assert r.status_code == 201, r.text
    table = (await client.get(f"/v1/kitchens/{k['id']}", headers=you)).json()["table"]
    assert table["seats"] == 8 and table["taken"] == 2
    assert [f["display_name"] for f in table["friends"]] == ["Maya"]
