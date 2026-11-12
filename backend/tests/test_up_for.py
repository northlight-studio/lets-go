"""Up for something: who sees it, how long it lasts, I'm in, and what nobody gets to see."""

from datetime import UTC, datetime

from sqlalchemy import text

from app import upfor
from tests.conftest import HERE, at, make_user, offset
from tests.test_gatherings import host_game
from tests.test_people import befriend, check_in_together, me_id

HERE_Q = {"lat": HERE[0], "lon": HERE[1]}


async def up_for(client, headers, activity="walk", east=600, north=0, **extra):
    lat, lon = offset(east, north)
    body = {"activity": activity, "hours": 2, "lat": lat, "lon": lon} | extra
    r = await client.put("/v1/me/up-for", json=body, headers=headers)
    assert r.status_code == 200, r.text
    return r.json()


def no_coordinates(obj, path="") -> None:
    """Nothing in what someone else sees about you is a latitude or longitude."""
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k in ("lat", "lon"):
                assert v is None, f"{path}.{k} leaked"
            no_coordinates(v, f"{path}.{k}")
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            no_coordinates(v, f"{path}[{i}]")


# Visibility


async def test_friends_see_what_youre_up_for_and_how_far_never_where(client):
    maya, you, stranger = (
        await make_user(client, "Maya Reyes"),
        await make_user(client, "You"),
        await make_user(client, "Stranger"),
    )
    await befriend(client, maya, you)
    mine = await up_for(client, maya, "walk", east=480)
    assert mine["label"] == "A walk" and mine["bubble"] == "walk?"

    seen = (await client.get("/v1/people", params=HERE_Q, headers=you)).json()
    light = seen["friends"][0]["up_for"]
    assert light["activity"] == "walk" and light["label"] == "A walk"
    assert light["walk_min"] == 7  # 480 m, streets aren't straight
    # The friend list, the old porch light shape included, carries no coordinates for Maya.
    for friend in seen["friends"]:
        no_coordinates({k: v for k, v in friend.items() if k != "out"})
    assert seen["friends"][0]["porch_light"]["note"] == "A walk"

    assert (await client.get("/v1/people", params=HERE_Q, headers=stranger)).json()["friends"] == []
    assert (await client.get("/v1/people", headers=maya)).json()["up_for"]["label"] == "A walk"


async def test_people_youve_met_three_times_see_it_and_nobody_else(client):
    sam, you, ben, two_times = (
        await make_user(client, "Sam"),
        await make_user(client, "You"),
        await make_user(client, "Ben"),
        await make_user(client, "Jun"),
    )
    await check_in_together(client, sam, [you, ben], 3)
    await check_in_together(client, sam, [two_times], 0)
    await up_for(client, ben, "coffee")

    intros = (await client.get("/v1/people", params=HERE_Q, headers=you)).json()["intros"]
    assert [i["person"]["display_name"] for i in intros] == ["Ben"]
    assert intros[0]["up_for"]["label"] == "Coffee"
    no_coordinates(intros)
    # Sam hosted and never checked in alongside; Jun never met Ben.
    for other in (sam, two_times):
        seen = (await client.get("/v1/people", headers=other)).json()
        assert seen["friends"] == [] and all(i["up_for"] is None for i in seen["intros"])
        ben_id = await me_id(client, ben)
        assert (await client.post(f"/v1/up-for/{ben_id}/in", json={}, headers=other)).status_code == 404
        assert (await client.post(f"/v1/friends/{ben_id}/wave", headers=other)).status_code == 404


async def test_not_now_hides_it_both_ways(client):
    sam, you, ben = (
        await make_user(client, "Sam"),
        await make_user(client, "You"),
        await make_user(client, "Ben"),
    )
    await check_in_together(client, sam, [you, ben], 3)
    ben_id = await me_id(client, ben)
    assert (await client.post(f"/v1/intros/{ben_id}/not-now", headers=you)).status_code == 204
    await up_for(client, you, "drink")
    bens = (await client.get("/v1/people", headers=ben)).json()
    assert bens["intros"][0]["up_for"] is None
    you_id = await me_id(client, you)
    assert (await client.post(f"/v1/up-for/{you_id}/in", json={}, headers=ben)).status_code == 404


async def test_waves_reach_people_youve_met(client):
    sam, you, ben = (
        await make_user(client, "Sam"),
        await make_user(client, "You"),
        await make_user(client, "Ben"),
    )
    await check_in_together(client, sam, [you, ben], 3)
    ben_id = await me_id(client, ben)
    assert (await client.post(f"/v1/friends/{ben_id}/wave", headers=you)).status_code == 204
    assert (await client.get("/v1/people", headers=ben)).json()["intros"][0]["waved_at"] is not None


# What you can say, and for how long


async def test_own_words_or_an_activity_and_at_most_four_hours(client):
    you = await make_user(client, "You")
    r = await client.put("/v1/me/up-for", json={"activity": "", "words": "  "}, headers=you)
    assert r.status_code == 422
    assert (
        await client.put("/v1/me/up-for", json={"activity": "walk", "hours": 5}, headers=you)
    ).status_code == 422
    assert (await client.put("/v1/me/up-for", json={"activity": "bowling"}, headers=you)).status_code == 422
    r = await client.put("/v1/me/up-for", json={"words": "Frisbee in the park"}, headers=you)
    assert r.json()["label"] == "Frisbee in the park" and r.json()["bubble"] == "frisbee?"


async def test_it_goes_off_when_its_time_is_up(client, engine):
    maya, you = await make_user(client, "Maya"), await make_user(client, "You")
    await befriend(client, maya, you)
    await up_for(client, maya)
    async with engine.begin() as conn:
        await conn.execute(text("UPDATE porch_lights SET on_until = now() - interval '1 minute'"))
    seen = (await client.get("/v1/people", headers=you)).json()
    assert seen["friends"][0]["up_for"] is None and seen["friends"][0]["porch_light"] is None
    maya_id = await me_id(client, maya)
    assert (await client.post(f"/v1/up-for/{maya_id}/in", json={}, headers=you)).status_code == 409


async def test_off_and_the_old_porch_light_routes_still_work(client):
    maya, you = await make_user(client, "Maya"), await make_user(client, "You")
    await befriend(client, maya, you)
    r = await client.put("/v1/me/porch-light", json={"hours": 1, "note": "up for a walk"}, headers=maya)
    assert r.status_code == 200 and r.json()["note"] == "up for a walk"
    assert (await client.get("/v1/people", headers=you)).json()["friends"][0]["up_for"][
        "label"
    ] == "up for a walk"
    assert (await client.delete("/v1/me/up-for", headers=maya)).status_code == 204
    assert (await client.get("/v1/people", headers=you)).json()["friends"][0]["up_for"] is None
    await up_for(client, maya)
    assert (await client.delete("/v1/me/porch-light", headers=maya)).status_code == 204
    assert (await client.get("/v1/people", headers=maya)).json()["up_for"] is None


# I'm in


async def test_im_in_makes_a_match_both_of_you_see(client):
    maya, you, theo = (
        await make_user(client, "Maya Reyes"),
        await make_user(client, "You"),
        await make_user(client, "Theo"),
    )
    await befriend(client, maya, you)
    await befriend(client, maya, theo)
    await up_for(client, maya, "walk", east=800)
    maya_id = await me_id(client, maya)

    r = await client.post(f"/v1/up-for/{maya_id}/in", json={"lat": HERE[0], "lon": HERE[1]}, headers=you)
    assert r.status_code == 201, r.text
    match = r.json()
    assert match["headline"] == "You and Maya are going for a walk"
    assert match["other"]["display_name"] == "Maya Reyes" and not match["is_mine"]
    assert match["my_walk_min"] == match["their_walk_min"] == 6  # 400 m each way to halfway
    assert datetime.fromisoformat(match["meet_at"]) > datetime.now(UTC)
    no_coordinates({k: v for k, v in match.items() if k not in ("area", "spot")})

    hers = (await client.get("/v1/people", headers=maya)).json()
    assert hers["meetup"]["headline"] == "You and You are going for a walk"
    assert hers["meetup"]["is_mine"] and hers["meetup"]["id"] == match["id"]
    # She's busy now: her "up for" is off, so Theo can't be in too.
    assert hers["up_for"] is None
    assert (await client.post(f"/v1/up-for/{maya_id}/in", json={}, headers=theo)).status_code == 409
    assert (await client.get("/v1/people", headers=theo)).json()["meetup"] is None


async def test_only_the_two_of_you_can_touch_it(client):
    maya, you, theo = (
        await make_user(client, "Maya"),
        await make_user(client, "You"),
        await make_user(client, "Theo"),
    )
    await befriend(client, maya, you)
    await up_for(client, maya)
    maya_id = await me_id(client, maya)
    match = (await client.post(f"/v1/up-for/{maya_id}/in", json={}, headers=you)).json()
    for call in (
        client.patch(f"/v1/meetups/{match['id']}", json={"on_my_way": True}, headers=theo),
        client.put(f"/v1/meetups/{match['id']}/spot", json={"name": "X", "lat": 1, "lon": 1}, headers=theo),
        client.post(f"/v1/meetups/{match['id']}/done", headers=theo),
    ):
        assert (await call).status_code == 404


async def test_you_cant_be_in_on_your_own(client):
    you = await make_user(client, "You")
    await up_for(client, you)
    you_id = await me_id(client, you)
    assert (await client.post(f"/v1/up-for/{you_id}/in", json={}, headers=you)).status_code == 404


async def test_spot_on_my_way_and_a_short_reply(client):
    maya, you = await make_user(client, "Maya"), await make_user(client, "You")
    await befriend(client, maya, you)
    await up_for(client, maya, "coffee", east=800)
    maya_id = await me_id(client, maya)
    match = (await client.post(f"/v1/up-for/{maya_id}/in", json=HERE_Q, headers=you)).json()
    # The rough halfway square is near the real halfway point, never on either of you.
    mid = offset(400, 0)
    assert abs(match["area"]["lat"] - mid[0]) < 0.003 and abs(match["area"]["lon"] - mid[1]) < 0.003

    far = offset(5000, 0)
    r = await client.put(
        f"/v1/meetups/{match['id']}/spot", json={"name": "Far", "lat": far[0], "lon": far[1]}, headers=you
    )
    assert r.status_code == 422
    near = offset(450, 60)
    r = await client.put(
        f"/v1/meetups/{match['id']}/spot",
        json={"name": "Ritual Coffee", "lat": near[0], "lon": near[1]},
        headers=you,
    )
    assert r.status_code == 200 and r.json()["spot"]["name"] == "Ritual Coffee"

    await client.patch(
        f"/v1/meetups/{match['id']}", json={"on_my_way": True, "says": "Running 5 late"}, headers=you
    )
    hers = (await client.get("/v1/meetups/current", headers=maya)).json()
    assert hers["they_are_on_their_way"] and hers["they_say"] == "Running 5 late"
    assert hers["spot"]["name"] == "Ritual Coffee" and not hers["i_am_on_my_way"]


async def test_done_ends_it_for_both_and_wipes_where_you_were(client, engine):
    maya, you = await make_user(client, "Maya"), await make_user(client, "You")
    await befriend(client, maya, you)
    await up_for(client, maya)
    maya_id = await me_id(client, maya)
    match = (await client.post(f"/v1/up-for/{maya_id}/in", json=HERE_Q, headers=you)).json()
    assert (await client.post(f"/v1/meetups/{match['id']}/done", headers=maya)).status_code == 204
    assert (await client.get("/v1/people", headers=you)).json()["meetup"] is None
    assert (await client.get("/v1/meetups/current", headers=maya)).json() is None
    async with engine.begin() as conn:
        row = (await conn.execute(text("SELECT host_lat, host_lon, guest_lat, guest_lon FROM meetups"))).one()
    assert tuple(row) == (None, None, None, None)
    r = await client.patch(f"/v1/meetups/{match['id']}", json={"lat": HERE[0], "lon": HERE[1]}, headers=you)
    assert r.status_code == 404
    # Free again: a new one can start.
    await up_for(client, maya)
    assert (await client.post(f"/v1/up-for/{maya_id}/in", json={}, headers=you)).status_code == 201


async def test_a_match_runs_out_by_itself(client, engine):
    maya, you = await make_user(client, "Maya"), await make_user(client, "You")
    await befriend(client, maya, you)
    await up_for(client, maya)
    maya_id = await me_id(client, maya)
    await client.post(f"/v1/up-for/{maya_id}/in", json={}, headers=you)
    async with engine.begin() as conn:
        await conn.execute(text("UPDATE meetups SET ends_at = now() - interval '1 minute'"))
    assert (await client.get("/v1/people", headers=you)).json()["meetup"] is None


# Crews


async def test_a_crew_shows_its_next_plan(client):
    sam, maya, theo, you = (
        await make_user(client, "Sam"),
        await make_user(client, "Maya"),
        await make_user(client, "Theo"),
        await make_user(client, "You"),
    )
    maya_id = (await befriend(client, maya, you))["id"]
    theo_id = (await befriend(client, theo, you))["id"]
    await client.post("/v1/crews", json={"name": "Runners", "member_ids": [maya_id, theo_id]}, headers=you)
    assert (await client.get("/v1/people", headers=you)).json()["crews"][0]["next"] is None
    run = await host_game(
        client, sam, title="Thursday run", starts_at=at(60 * 20), ends_at=at(60 * 21), capacity=0
    )
    solo = await host_game(client, sam, title="Just Maya", starts_at=at(60), ends_at=at(120), capacity=0)
    await client.post(f"/v1/gatherings/{solo['id']}/join", headers=maya)
    for p in (maya, theo):
        await client.post(f"/v1/gatherings/{run['id']}/join", headers=p)
    nxt = (await client.get("/v1/people", headers=you)).json()["crews"][0]["next"]
    assert nxt["title"] == "Thursday run" and nxt["going"] == 2


# The plain parts


def test_rough_area_is_a_square_not_a_point():
    a = upfor.rough_area((37.75961, -122.42691))
    b = upfor.rough_area((37.75989, -122.42679))
    assert a == b
    assert abs(a[0] - 37.75961) < upfor.AREA_STEP and abs(a[1] + 122.42691) < upfor.AREA_STEP


def test_meet_at_is_on_a_five_after_the_longer_walk():
    t = datetime(2026, 11, 12, 18, 2, tzinfo=UTC)
    assert upfor.meet_at(t, [6, 9]) == datetime(2026, 11, 12, 18, 15, tzinfo=UTC)
    assert upfor.meet_at(t, []) == datetime(2026, 11, 12, 18, 15, tzinfo=UTC)


def test_rough_minutes_round_past_ten():
    assert upfor.rough_minutes(80) == 1
    assert upfor.rough_minutes(600) == 9
    assert upfor.rough_minutes(1100) == 15
