from datetime import UTC, datetime, timedelta

from sqlalchemy import update

from app import poster as P
from app.models import Gathering
from tests.conftest import at, make_user
from tests.test_gatherings import host_game

TZ = "America/Los_Angeles"


async def make_poster(client, headers, gathering_id, tz=TZ):
    r = await client.post(f"/v1/gatherings/{gathering_id}/poster", json={"tz": tz}, headers=headers)
    assert r.status_code == 200, r.text
    return r.json()


async def join_web(client, code, name, ip="203.0.113.7", cookies=None, **extra):
    client.cookies.clear()
    if cookies:
        client.cookies.update(cookies)
    return await client.post(
        f"/p/{code}/in",
        data={"first_name": name, **extra},
        headers={"X-Forwarded-For": ip},
        follow_redirects=False,
    )


def message(r) -> str:
    assert r.status_code == 303, r.text
    return r.headers["location"].split("m=")[1]


# Plain logic


def test_codes_are_short_and_unambiguous():
    for _ in range(200):
        c = P.new_code()
        assert len(c) == 6 and not set(c) & set("01ilo")
    assert P.normalize_code(" K7M-3QX ") == "k7m3qx"


def test_first_names():
    assert P.clean_first_name("  Maya ") == "Maya"
    assert P.clean_first_name("Anne-Marie") == "Anne-Marie"
    assert P.clean_first_name("José") == "José"
    for bad in ["", "x" * 31, "http://spam.example", "Bob123", "<b>"]:
        assert P.clean_first_name(bad) is None


def test_weekly_keeps_local_time_across_daylight_saving():
    assert P.is_weekly("Every Thursday") and P.is_weekly("every thursdays")
    assert not P.is_weekly("") and not P.is_weekly("Every so often")
    # Thursday Oct 29 2026, 6:30 PM in LA (PDT, UTC-7). DST ends Nov 1.
    starts = datetime(2026, 10, 30, 1, 30, tzinfo=UTC)
    ends = starts + timedelta(hours=2)
    s, e = P.next_week(starts, ends, TZ, now=ends + timedelta(minutes=1))
    assert s == datetime(2026, 11, 6, 2, 30, tzinfo=UTC)  # 6:30 PM PST
    assert e - s == timedelta(hours=2)
    # Months later it skips ahead to the next one that hasn't ended.
    later = ends + timedelta(days=60)
    s, e = P.next_week(starts, ends, TZ, now=later)
    assert e > later and e - timedelta(weeks=1) <= later


def test_web_share_and_client_ip():
    assert P.web_limit(6) == 3 and P.web_limit(2) == 1 and P.web_limit(1) == 1
    assert P.web_limit(0) == 25
    # Only the address the proxy appended counts; what the caller wrote in front is ignored.
    assert P.client_ip("6.6.6.6, 198.51.100.4", "10.0.0.1") == "198.51.100.4"
    assert P.client_ip(None, "10.0.0.1") == "10.0.0.1"


# The host's side


async def test_only_the_host_makes_a_poster_and_it_is_stable(client):
    sam, you = await make_user(client, "Sam O."), await make_user(client, "You")
    g = await host_game(client, sam)
    r = await client.post(f"/v1/gatherings/{g['id']}/poster", json={"tz": TZ}, headers=you)
    assert r.status_code == 403
    r = await client.post(f"/v1/gatherings/{g['id']}/poster", json={"tz": "Mars/Base"}, headers=sam)
    assert r.status_code == 422
    first = await make_poster(client, sam, g["id"])
    again = await make_poster(client, sam, g["id"])
    assert first["code"] == again["code"]
    assert first["url"].endswith(f"/p/{first['code']}") and "://" not in first["short_text"]


# The public page and joining from it


async def test_page_shows_counts_never_names(client):
    sam, ana = await make_user(client, "Sam Ortiz"), await make_user(client, "Ana Reyes")
    g = await host_game(client, sam, capacity=6, details="Bring water. All levels.")
    await client.post(f"/v1/gatherings/{g['id']}/join", headers=ana)
    code = (await make_poster(client, sam, g["id"]))["code"]

    assert message(await join_web(client, code, "Maya")) == "in"
    client.cookies.clear()
    page = (await client.get(f"/p/{code}")).text
    assert "Pickup soccer" in page and "Bring water. All levels." in page
    assert "3 in · 3 spots left" in page
    assert "Ana" not in page and "Maya" not in page and "Ortiz" not in page
    assert "run by Sam" in page

    # The host sees the web first name; anyone else only the count.
    mine = (await client.get(f"/v1/gatherings/{g['id']}", headers=sam)).json()
    theirs = (await client.get(f"/v1/gatherings/{g['id']}", headers=ana)).json()
    assert mine["going"] == 3 and mine["web_going"] == 1 and mine["web_names"] == ["Maya"]
    assert theirs["going"] == 3 and theirs["web_names"] == []


async def test_same_browser_is_one_guest_and_can_leave(client):
    sam = await make_user(client, "Sam")
    g = await host_game(client, sam, capacity=10)
    code = (await make_poster(client, sam, g["id"]))["code"]
    r = await join_web(client, code, "Maya")
    cookie = {"lg_b": r.cookies["lg_b"]}
    assert message(await join_web(client, code, "Maya", cookies=cookie)) == "in"
    client.cookies.update(cookie)
    page = (await client.get(f"/p/{code}")).text
    assert "You're in, Maya." in page and "2 in" in page
    r = await client.post(f"/p/{code}/out", follow_redirects=False)
    assert message(r) == "out"
    assert (await client.get(f"/v1/gatherings/{g['id']}", headers=sam)).json()["going"] == 1


async def test_the_web_cannot_fill_every_spot(client):
    sam = await make_user(client, "Sam")
    g = await host_game(client, sam, capacity=4)
    code = (await make_poster(client, sam, g["id"]))["code"]
    assert message(await join_web(client, code, "Ana", ip="198.51.100.1")) == "in"
    assert message(await join_web(client, code, "Ben", ip="198.51.100.2")) == "in"
    # Half of four is two: the rest are for people on the app.
    assert message(await join_web(client, code, "Cy", ip="198.51.100.3")) == "webfull"
    app_user = await make_user(client, "Dee")
    assert (await client.post(f"/v1/gatherings/{g['id']}/join", headers=app_user)).json()["going"] == 4
    # Web guests count against capacity for app joins too.
    late = await make_user(client, "Eli")
    assert (await client.post(f"/v1/gatherings/{g['id']}/join", headers=late)).status_code == 409


async def test_one_network_is_rate_limited(client):
    sam = await make_user(client, "Sam")
    g = await host_game(client, sam, capacity=0)
    code = (await make_poster(client, sam, g["id"]))["code"]
    for name in ["Ana", "Ben", "Cy"]:
        assert message(await join_web(client, code, name)) == "in"
    assert message(await join_web(client, code, "Dee")) == "slow"
    # Leaving doesn't hand the slot back.
    assert message(await join_web(client, code, "Dee", ip="198.51.100.9")) == "in"


async def test_bots_and_bad_names_record_nothing(client):
    sam = await make_user(client, "Sam")
    g = await host_game(client, sam)
    code = (await make_poster(client, sam, g["id"]))["code"]
    assert message(await join_web(client, code, "Maya", website="http://spam")) == "in"
    assert message(await join_web(client, code, "www.spam.example")) == "name"
    assert (await client.get(f"/v1/gatherings/{g['id']}", headers=sam)).json()["going"] == 1


async def test_unknown_code_and_cancelled(client):
    assert (await client.get("/p/zzzzzz")).status_code == 404
    sam = await make_user(client, "Sam")
    g = await host_game(client, sam)
    code = (await make_poster(client, sam, g["id"]))["code"]
    await client.delete(f"/v1/gatherings/{g['id']}", headers=sam)
    assert "called this one off" in (await client.get(f"/p/{code}")).text
    assert message(await join_web(client, code, "Maya")) == "off"


async def test_retired_poster_takes_no_joins(client):
    sam, you = await make_user(client, "Sam"), await make_user(client, "You")
    g = await host_game(client, sam)
    code = (await make_poster(client, sam, g["id"]))["code"]
    assert (await client.delete(f"/v1/posters/{code}", headers=you)).status_code == 403
    assert (await client.delete(f"/v1/posters/{code}", headers=sam)).status_code == 204
    assert "took this poster down" in (await client.get(f"/p/{code}")).text
    assert message(await join_web(client, code, "Maya")) == "off"


async def test_weekly_poster_moves_on_to_next_week(client, engine):
    sam = await make_user(client, "Sam")
    g = await host_game(client, sam, capacity=6, recurring="Every Thursday")
    code = (await make_poster(client, sam, g["id"]))["code"]
    assert message(await join_web(client, code, "Maya")) == "in"

    # Last week's ends.
    async with engine.begin() as conn:
        await conn.execute(
            update(Gathering)
            .where(Gathering.id == g["id"])
            .values(
                starts_at=datetime.now(UTC) - timedelta(hours=3),
                ends_at=datetime.now(UTC) - timedelta(hours=1),
            )
        )

    client.cookies.clear()
    page = (await client.get(f"/p/{code}")).text
    assert "Every " in page and "1 in · 5 spots left" in page
    # The same link now points at a new gathering a week on, with only the host in, on the map.
    r = await client.get(
        "/v1/nearby", params={"lat": g["lat"], "lon": g["lon"], "hours": 24 * 8}, headers=sam
    )
    [nxt] = r.json()["gatherings"]
    assert nxt["id"] != g["id"] and nxt["going"] == 1 and nxt["recurring"] == "Every Thursday"
    assert (await make_poster(client, sam, nxt["id"]))["code"] == code
    assert message(await join_web(client, code, "Maya", ip="198.51.100.20")) == "in"
    # Scanning twice doesn't make two.
    await client.get(f"/p/{code}")
    r = await client.get(
        "/v1/nearby", params={"lat": g["lat"], "lon": g["lon"], "hours": 24 * 8}, headers=sam
    )
    assert len(r.json()["gatherings"]) == 1


async def test_ended_one_off_says_so(client, engine):
    sam = await make_user(client, "Sam")
    g = await host_game(client, sam, starts_at=at(10))
    code = (await make_poster(client, sam, g["id"]))["code"]
    async with engine.begin() as conn:
        await conn.execute(
            update(Gathering)
            .where(Gathering.id == g["id"])
            .values(
                starts_at=datetime.now(UTC) - timedelta(hours=3),
                ends_at=datetime.now(UTC) - timedelta(hours=1),
            )
        )
    assert "This one's over" in (await client.get(f"/p/{code}")).text
    assert message(await join_web(client, code, "Maya")) == "over"


async def test_scheduler_rolls_weekly_posters_nobody_scanned(client, engine):
    from sqlalchemy.ext.asyncio import async_sessionmaker

    from app.poster_roll import roll_due
    from app.views import now

    sam = await make_user(client, "Sam")
    weekly = await host_game(client, sam, recurring="Every Tuesday")
    once = await host_game(client, sam)
    for g in (weekly, once):
        await make_poster(client, sam, g["id"])
    async with engine.begin() as conn:
        await conn.execute(
            update(Gathering).values(
                starts_at=datetime.now(UTC) - timedelta(hours=3),
                ends_at=datetime.now(UTC) - timedelta(hours=1),
            )
        )
    async with async_sessionmaker(engine, expire_on_commit=False)() as session:
        assert await roll_due(session, now()) == 1
        assert await roll_due(session, now()) == 0
    r = await client.get(
        "/v1/nearby", params={"lat": weekly["lat"], "lon": weekly["lon"], "hours": 24 * 8}, headers=sam
    )
    assert [g["recurring"] for g in r.json()["gatherings"]] == ["Every Tuesday"]
