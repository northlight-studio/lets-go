from tests.conftest import HERE, at, make_user, offset


async def host_game(client, headers, **over):
    lat, lon = offset(-300, 150)
    body = {
        "title": "Pickup soccer",
        "genre": "play",
        "place_name": "The big field",
        "lat": lat,
        "lon": lon,
        "starts_at": at(30),
        "ends_at": at(130),
        "capacity": 3,
    } | over
    r = await client.post("/v1/gatherings", json=body, headers=headers)
    assert r.status_code == 201, r.text
    return r.json()


async def test_unauthenticated_is_rejected(client):
    r = await client.get("/v1/me")
    assert r.status_code == 401


async def test_rename_shows_on_hosted_things(client):
    sam = await make_user(client, "Neighbor")
    await client.patch("/v1/me", json={"display_name": "Sam O."}, headers=sam)
    g = await host_game(client, sam)
    assert g["host_name"] == "Sam O."


async def test_host_is_going_and_shows_up_nearby(client):
    sam = await make_user(client, "Sam O.")
    g = await host_game(client, sam)
    assert g["going"] == 1 and g["is_mine"] and g["is_joined"]

    you = await make_user(client, "You")
    r = await client.get("/v1/nearby", params={"lat": HERE[0], "lon": HERE[1]}, headers=you)
    found = r.json()["gatherings"]
    assert [x["title"] for x in found] == ["Pickup soccer"]
    assert found[0]["host_name"] == "Sam O."
    assert not found[0]["is_joined"]
    assert 250 < found[0]["distance_m"] < 450


async def test_far_away_and_ended_are_not_nearby(client):
    sam = await make_user(client, "Sam")
    lat, lon = offset(9000, 0)
    await host_game(client, sam, lat=lat, lon=lon)
    r = await client.get("/v1/nearby", params={"lat": HERE[0], "lon": HERE[1]}, headers=sam)
    assert r.json()["gatherings"] == []


async def test_capacity_is_enforced(client):
    sam = await make_user(client, "Sam")
    g = await host_game(client, sam, capacity=2)
    a, b = await make_user(client, "A"), await make_user(client, "B")
    assert (await client.post(f"/v1/gatherings/{g['id']}/join", headers=a)).json()["going"] == 2
    r = await client.post(f"/v1/gatherings/{g['id']}/join", headers=b)
    assert r.status_code == 409
    # Joining twice is a no-op, not an error.
    assert (await client.post(f"/v1/gatherings/{g['id']}/join", headers=a)).status_code == 200


async def test_leave_frees_the_spot(client):
    sam = await make_user(client, "Sam")
    g = await host_game(client, sam, capacity=2)
    a = await make_user(client, "A")
    await client.post(f"/v1/gatherings/{g['id']}/join", headers=a)
    r = await client.delete(f"/v1/gatherings/{g['id']}/join", headers=a)
    assert r.json()["going"] == 1 and not r.json()["is_joined"]


async def test_check_in_needs_you_there(client):
    sam = await make_user(client, "Sam")
    g = await host_game(client, sam, starts_at=at(10))
    you = await make_user(client, "You")
    r = await client.post(
        f"/v1/gatherings/{g['id']}/check-in", json={"lat": HERE[0], "lon": HERE[1]}, headers=you
    )
    assert r.status_code == 409 and "m away" in r.json()["detail"]

    r = await client.post(
        f"/v1/gatherings/{g['id']}/check-in", json={"lat": g["lat"], "lon": g["lon"]}, headers=you
    )
    assert r.status_code == 200
    assert r.json()["checked_in_at"] is not None and r.json()["is_joined"]


async def test_check_in_not_open_hours_early(client):
    sam = await make_user(client, "Sam")
    g = await host_game(client, sam, starts_at=at(120), ends_at=at(200))
    r = await client.post(
        f"/v1/gatherings/{g['id']}/check-in", json={"lat": g["lat"], "lon": g["lon"]}, headers=sam
    )
    assert r.status_code == 409


async def test_only_host_cancels(client):
    sam = await make_user(client, "Sam")
    g = await host_game(client, sam)
    you = await make_user(client, "You")
    assert (await client.delete(f"/v1/gatherings/{g['id']}", headers=you)).status_code == 403
    assert (await client.delete(f"/v1/gatherings/{g['id']}", headers=sam)).status_code == 204
    assert (await client.get(f"/v1/gatherings/{g['id']}", headers=sam)).status_code == 404


async def test_food_is_not_a_gathering(client):
    sam = await make_user(client, "Sam")
    lat, lon = HERE
    r = await client.post(
        "/v1/gatherings",
        headers=sam,
        json={
            "title": "Pizza",
            "genre": "food",
            "place_name": "Porch",
            "lat": lat,
            "lon": lon,
            "starts_at": at(10),
            "ends_at": at(60),
        },
    )
    assert r.status_code == 422


def test_railway_database_url_gets_the_async_driver():
    from app.config import Settings

    assert (
        Settings(database_url="postgresql://u:p@h:5432/d").database_url == "postgresql+asyncpg://u:p@h:5432/d"
    )
    assert Settings(database_url="postgres://u:p@h/d").database_url == "postgresql+asyncpg://u:p@h/d"


async def test_validation_messages_read_plainly(client):
    alice = await make_user(client, "Alice")
    lat, lon = HERE
    body = {
        "title": "Backwards",
        "genre": "play",
        "place_name": "The park",
        "lat": lat,
        "lon": lon,
        "starts_at": at(120),
        "ends_at": at(60),
    }
    r = await client.post("/v1/gatherings", json=body, headers=alice)
    assert r.status_code == 422
    assert "It has to end after it starts." in r.text
    r = await client.post("/v1/gatherings", json=body | {"genre": "food", "ends_at": at(180)}, headers=alice)
    assert r.status_code == 422
    assert "Food is sold through home kitchens" in r.text
