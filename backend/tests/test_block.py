"""Your block: what shows, in what order, that it ends, and that strangers stay counts."""

from datetime import UTC, datetime, timedelta

from sqlalchemy import text

from app import block
from app.block import Candidate
from tests.conftest import HERE, make_user, offset
from tests.test_batches import post_batch
from tests.test_gatherings import host_game
from tests.test_people import befriend, check_in_together, me_id
from tests.test_up_for import up_for

HERE_Q = {"lat": HERE[0], "lon": HERE[1]}
T = datetime(2026, 11, 12, 17, 0, tzinfo=UTC)


async def get_block(client, headers, **q):
    r = await client.get("/v1/me/block", params=q or HERE_Q, headers=headers)
    assert r.status_code == 200, r.text
    return r.json()["items"]


def kinds(items):
    return [i["kind"] for i in items]


# The ranking, on its own


def c(key, kind="batch", subject=None, **kw):
    return Candidate(key=key, kind=kind, subject=subject or key, **kw)


def test_new_near_and_soon_come_first():
    old_far = c("a", posted_at=T - timedelta(days=2), walk_min=10, at=T + timedelta(hours=20))
    new_near = c("b", posted_at=T - timedelta(hours=1), walk_min=3, at=T + timedelta(hours=1))
    middle = c("c", posted_at=T - timedelta(hours=12), walk_min=8, at=T + timedelta(hours=5))
    assert [x.key for x in block.rank([old_far, middle, new_near], T)] == ["b", "c", "a"]


def test_friends_lift_a_row():
    stranger = c("count", kind="going", at=T + timedelta(hours=2))
    friend = c("friend", kind="going", at=T + timedelta(hours=2), friend=True)
    assert block.rank([stranger, friend], T)[0].key == "friend"


def test_one_row_per_subject_and_per_key():
    a = c("batch:1", subject="kitchen:k", posted_at=T)
    b = c("batch:2", subject="kitchen:k", posted_at=T - timedelta(days=2))
    again = c("batch:1", subject="kitchen:other")
    assert [x.key for x in block.rank([a, b, again], T)] == ["batch:1"]


def test_it_ends_a_few_of_a_kind_and_never_whats_over():
    many = [c(f"b{i}", posted_at=T) for i in range(10)]
    going = [c(f"g{i}", kind="going") for i in range(10)]
    over = c("over", kind="up_for", ends_at=T - timedelta(minutes=1), friend=True)
    ranked = block.rank([*many, *going, over], T)
    assert len(ranked) <= block.MOST
    assert kinds_of(ranked).count("batch") == block.MOST_OF_A_KIND
    assert "over" not in [x.key for x in ranked]
    assert len(block.rank([*many, *going, *[c(f"n{i}", kind="neighbor") for i in range(9)]], T)) == block.MOST


def kinds_of(cs):
    return [x.kind for x in cs]


def test_up_for_now_beats_a_batch_for_later():
    later = c("batch", at=T + timedelta(hours=20), posted_at=T - timedelta(days=2))
    now = c("up", kind="up_for", at=T, friend=True, walk_min=6)
    assert block.rank([later, now], T)[0].key == "up"


# The route


async def test_a_neighbors_batch_a_few_blocks_away(client):
    dana, you = await make_user(client, "Dana Whitfield"), await make_user(client, "You")
    b = await post_batch(client, dana)
    far = await make_user(client, "Far")
    lat, lon = offset(3000, 0)
    await post_batch(client, far, lat=lat, lon=lon, title="Far pie")

    items = await get_block(client, you)
    assert kinds(items) == ["batch"]
    row = items[0]
    assert row["id"] == b["id"] and row["name"] == "Dana Whitfield's kitchen" and row["left"] == 8
    assert row["unit"] == "pint" and row["walk_min"] is not None and row["posted_at"]
    # Never the address or the house: nothing in the row says where it is.
    assert "address" not in row and "lat" not in row
    # Your own batch isn't news to you.
    assert await get_block(client, dana) == []


async def test_a_kitchen_you_follow_is_back_wherever_it_is(client):
    wei, you = await make_user(client, "Wei"), await make_user(client, "You")
    lat, lon = offset(4000, 0)
    start = datetime.now(UTC).replace(second=0, microsecond=0) + timedelta(days=2)
    start -= timedelta(minutes=start.minute % 15)
    b = await post_batch(
        client,
        wei,
        lat=lat,
        lon=lon,
        title="Pork dumplings",
        starts_at=start.isoformat(),
        ends_at=(start + timedelta(hours=2)).isoformat(),
    )
    assert await get_block(client, you) == []
    r = await client.put(f"/v1/kitchens/{b['kitchen']['id']}/follow", headers=you)
    assert r.status_code == 200, r.text
    items = await get_block(client, you)
    assert kinds(items) == ["back"] and items[0]["title"] == "Pork dumplings"
    assert items[0]["kitchen_id"] == b["kitchen"]["id"]
    # Even with no location.
    assert kinds(await get_block(client, you, x="1")) == ["back"]


async def test_strangers_going_are_a_count_and_friends_are_named(client):
    host, you, maya = (
        await make_user(client, "Host Person"),
        await make_user(client, "You"),
        await make_user(client, "Maya Reyes"),
    )
    a, b = await make_user(client, "Stranger A"), await make_user(client, "Stranger B")
    g = await host_game(client, host, title="Jazz in the park", capacity=0)
    # Only the host so far: one person is never a count.
    assert await get_block(client, you) == []
    for p in (a, b):
        assert (await client.post(f"/v1/gatherings/{g['id']}/join", headers=p)).status_code == 200
    items = await get_block(client, you)
    assert kinds(items) == ["going"]
    assert items[0]["count"] == 3 and items[0]["friends"] == [] and items[0]["name"] is None
    body = str(items)
    for stranger in ("Host Person", "Stranger A", "Stranger B"):
        assert stranger.split()[0] not in body

    await befriend(client, maya, you)
    assert (await client.post(f"/v1/gatherings/{g['id']}/join", headers=maya)).status_code == 200
    items = await get_block(client, you)
    assert items[0]["friends"] == ["Maya"] and items[0]["count"] == 3
    # Once you're in, it's not news.
    assert (await client.post(f"/v1/gatherings/{g['id']}/join", headers=you)).status_code == 200
    assert await get_block(client, you) == []


async def test_people_youve_met_to_say_hi_to_and_nobody_else(client):
    sam, you, ben, jun = (
        await make_user(client, "Sam"),
        await make_user(client, "You"),
        await make_user(client, "Ben"),
        await make_user(client, "Jun"),
    )
    await check_in_together(client, sam, [you, ben], 3)
    await check_in_together(client, sam, [you, jun], 2)
    items = [i for i in await get_block(client, you) if i["kind"] == "neighbor"]
    assert [(i["name"], i["together"]) for i in items] == [("Ben", 3)]
    ben_id = await me_id(client, ben)
    assert (await client.post(f"/v1/intros/{ben_id}/hi", headers=you)).status_code == 200
    assert [i for i in await get_block(client, you) if i["kind"] == "neighbor"] == []


async def test_said_not_now_never_shows(client):
    sam, you, ben = (
        await make_user(client, "Sam"),
        await make_user(client, "You"),
        await make_user(client, "Ben"),
    )
    await check_in_together(client, sam, [you, ben], 3)
    you_id = await me_id(client, you)
    assert (await client.post(f"/v1/intros/{you_id}/not-now", headers=ben)).status_code == 204
    assert [i for i in await get_block(client, you) if i["kind"] == "neighbor"] == []


async def test_friends_up_for_something_now_with_a_walk_never_where(client, engine):
    maya, you, stranger = (
        await make_user(client, "Maya Reyes"),
        await make_user(client, "You"),
        await make_user(client, "Stranger"),
    )
    await befriend(client, maya, you)
    await up_for(client, maya, "walk", east=320)
    await up_for(client, stranger, "coffee", east=100)
    items = await get_block(client, you)
    assert kinds(items) == ["up_for"]
    row = items[0]
    assert row["name"] == "Maya Reyes" and row["title"] == "A walk" and row["walk_min"] == 5
    assert "lat" not in row and "lon" not in row
    # It goes when their time is up.
    async with engine.begin() as conn:
        await conn.execute(text("UPDATE porch_lights SET on_until = now() - interval '1 minute'"))
    assert await get_block(client, you) == []


async def test_whats_over_is_gone(client, engine):
    dana, you = await make_user(client, "Dana"), await make_user(client, "You")
    await post_batch(client, dana)
    async with engine.begin() as conn:
        await conn.execute(
            text(
                "UPDATE drops SET starts_at = now() - interval '2 hours',"
                " ends_at = now() - interval '1 minute'"
            )
        )
    assert await get_block(client, you) == []
    host, a, b = await make_user(client, "H"), await make_user(client, "A"), await make_user(client, "B")
    g = await host_game(client, host, capacity=0)
    for p in (a, b):
        await client.post(f"/v1/gatherings/{g['id']}/join", headers=p)
    assert kinds(await get_block(client, you)) == ["going"]
    async with engine.begin() as conn:
        await conn.execute(
            text(
                "UPDATE gatherings SET starts_at = now() - interval '2 hours',"
                " ends_at = now() - interval '1 minute'"
            )
        )
    assert await get_block(client, you) == []
