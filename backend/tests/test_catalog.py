"""The shared catalog end to end: resolver, sweep, listings, discover, and a scout run with a fake Claude."""

from contextlib import asynccontextmanager
from datetime import UTC, datetime, timedelta

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import async_sessionmaker

from app.catalog import cells
from app.catalog.feeds import Candidate
from app.catalog.geocode import Point
from app.catalog.resolve import resolve
from app.catalog.scout import Ask, Found, Usage
from app.catalog.sweep import mark_feed_coverage, sweep
from app.catalog.tables import Coverage, Event, EventSource, Find, ScoutRun, Venue
from app.main import app
from app.routes.discover import get_geocoders, get_scout
from tests.conftest import HERE, make_user, offset

SF_NOW = datetime.now(UTC)
TONIGHT = cells.night_of(SF_NOW, "sf")


def soon(hours: float) -> datetime:
    """A time later tonight that's still on tonight's night."""
    start, end = cells.night_bounds(TONIGHT, "sf")
    t = max(SF_NOW, start) + timedelta(hours=hours)
    return min(t, end - timedelta(minutes=30))


class FakeGeocoder:
    """Everything is a few hundred meters from HERE, by name."""

    def __init__(self):
        self.calls = 0

    async def locate(self, city, name, address):
        self.calls += 1
        if "nowhere" in (name + address).lower():
            return None
        return Point(*offset(150 * (len(name) % 5), 120))


def cand(source: str, ref: str, title: str, venue: str = "The Function", **over) -> Candidate:
    body = {
        "source": source,
        "ref": ref,
        "title": title,
        "starts_at": soon(2),
        "venue_name": venue,
        "address": "1414 Market Street, San Francisco, CA",
        "url": f"https://example.com/{ref}",
        "tags": ["comedy"],
        "price_text": "Free",
    } | over
    return Candidate(**body)


async def run_resolve(engine, items, geocoder=None, run_id=None):
    async with async_sessionmaker(engine, expire_on_commit=False)() as s:
        out = await resolve(s, "sf", items, geocoder or FakeGeocoder(), datetime.now(UTC), run_id=run_id)
        await s.commit()
        return out


async def count(engine, model) -> int:
    async with async_sessionmaker(engine)() as s:
        return await s.scalar(select(func.count()).select_from(model))


async def test_the_same_show_from_two_sites_is_one_event_with_two_sources(engine):
    geo = FakeGeocoder()
    first = await run_resolve(engine, [cand("funcheap", "a", "“Rush Hour Comedy Night” (The Function)")], geo)
    second = await run_resolve(
        engine,
        [
            cand(
                "19hz",
                "b",
                "Rush Hour Comedy Night",
                starts_at=soon(2) + timedelta(minutes=20),
                price_text="",
            )
        ],
        geo,
    )
    assert len(first.added) == 1 and second.merged == 1 and not second.added
    assert await count(engine, Event) == 1
    assert await count(engine, EventSource) == 2
    # One geocode for the venue, reused.
    assert geo.calls == 1
    # Seeing the same source again updates instead of adding.
    again = await run_resolve(
        engine, [cand("funcheap", "a", "Rush Hour Comedy Night", price_text="$10")], geo
    )
    assert again.updated == 1 and await count(engine, Event) == 1


async def test_different_shows_at_one_venue_stay_apart_and_nowhere_stays_off_the_map(engine):
    out = await run_resolve(
        engine,
        [
            cand("funcheap", "a", "Golden Gate Comedy Night"),
            cand("funcheap", "b", "Crazy Karaoke", starts_at=soon(2) + timedelta(minutes=10)),
            cand(
                "funcheap",
                "c",
                "Crazy Funny Asians",
                venue="Secret Location (SF)",
                address="San Francisco, CA",
            ),
        ],
    )
    assert len(out.added) == 3 and out.unplaced == 1
    async with async_sessionmaker(engine)() as s:
        placed = await s.scalar(select(func.count()).select_from(Event).where(Event.lat.is_not(None)))
    assert placed == 2


async def test_a_cancel_from_any_source_marks_the_event(engine):
    await run_resolve(engine, [cand("funcheap", "a", "Street Fest", tags=["festival"])])
    await run_resolve(engine, [cand("19hz", "b", "Street Fest (Canceled)", tags=["festival"], canceled=True)])
    async with async_sessionmaker(engine)() as s:
        assert (await s.scalar(select(Event.status))) == "canceled"


async def test_sweep_marks_coverage_for_what_feeds_answer_and_drops_vanished_listings(engine):
    maker = async_sessionmaker(engine, expire_on_commit=False)
    shows = [cand("funcheap", f"s{i}", f"Comedy Show Number {i}", venue=f"Club {i}") for i in range(3)]

    async def feed_full(client, start, days):
        return shows

    async def feed_less(client, start, days):
        return shows[:2]

    async with maker() as s:
        summary = await sweep(s, "sf", None, FakeGeocoder(), SF_NOW, 2, {"funcheap": feed_full})
    assert summary["funcheap"]["added"] == 3
    area = cells.area(*HERE)
    async with maker() as s:
        cov = await s.get(Coverage, ("sf", area, "comedy", TONIGHT))
    assert cov is not None and cov.state == "covered" and cov.by == "sweep"

    async with maker() as s:
        summary = await sweep(
            s, "sf", None, FakeGeocoder(), SF_NOW + timedelta(minutes=5), 2, {"funcheap": feed_less}
        )
    assert summary["_"]["gone"] == 1
    async with maker() as s:
        statuses = sorted((await s.scalars(select(Event.status))).all())
    assert statuses == ["gone", "on", "on"]


async def test_feed_coverage_never_overwrites_a_run_in_flight(engine):
    maker = async_sessionmaker(engine, expire_on_commit=False)
    await run_resolve(engine, [cand("funcheap", f"s{i}", f"Show {i}", venue=f"Club {i}") for i in range(3)])
    area = cells.area(*HERE)
    async with maker() as s:
        s.add(Coverage(city="sf", area=area, intent="comedy", day=TONIGHT, state="running", by="scout",
                       claimed_at=SF_NOW))  # fmt: skip
        await s.commit()
        await mark_feed_coverage(s, "sf", [TONIGHT], SF_NOW)
        await s.commit()
        cov = await s.get(Coverage, ("sf", area, "comedy", TONIGHT), populate_existing=True)
    assert cov.state == "running"


async def test_listings_include_catalog_events_except_trucks(client, engine):
    await run_resolve(
        engine,
        [
            cand("funcheap", "a", "Golden Gate Comedy Night"),
            cand(
                "datasf",
                "t",
                "Anzu To You",
                venue="2535 Taylor St",
                tags=["trucks", "food"],
                lat=37.8057,
                lon=-122.4153,
            ),
        ],
    )
    r = await client.get("/v1/listings", params={"city": "sf"})
    assert r.status_code == 200
    titles = [item["title"] for item in r.json()["listings"]]
    assert "Golden Gate Comedy Night" in titles and "Anzu To You" not in titles
    item = next(i for i in r.json()["listings"] if i["title"] == "Golden Gate Comedy Night")
    assert item["schedule"][0]["date"] and item["price"] == "Free"


# Discover and the scout


class FakeScout:
    def __init__(self, proposals=None, fail=False):
        self.proposals = proposals or []
        self.fail = fail
        self.asks: list[tuple[Ask, list[dict]]] = []

    async def search(self, ask, known):
        self.asks.append((ask, known))
        if self.fail:
            raise RuntimeError("search broke")
        return Found(self.proposals, Usage(tokens_in=40_000, tokens_out=3_000, searches=4), "found two")


def proposal(title: str, hours: float = 3) -> dict:
    return {
        "title": title,
        "venue_name": "Endgames Improv",
        "address": "2965 Mission St, San Francisco, CA",
        "starts_at": soon(hours).isoformat(),
        "ends_at": None,
        "url": f"https://example.com/{title.replace(' ', '-')}",
        "price_text": "$12",
        "ages": "",
        "description": "",
        "why": "Improv in a back room on Mission.",
        "public": True,
    }


def use(scout):
    @asynccontextmanager
    async def geocoders():
        yield FakeGeocoder()

    app.dependency_overrides[get_scout] = lambda: scout
    app.dependency_overrides[get_geocoders] = lambda: geocoders


async def test_first_ask_runs_the_scout_once_and_the_next_ask_is_a_hit(client, engine):
    await run_resolve(engine, [cand("funcheap", "a", "Golden Gate Comedy Night")])
    scout = FakeScout([proposal("The Ritual"), proposal("Your Weird Relationship", 4)])
    use(scout)
    me = await make_user(client, "Ana")
    params = {"lat": HERE[0], "lon": HERE[1], "q": "comedy under $20"}

    r = await client.get("/v1/discover", params=params, headers=me)
    body = r.json()
    assert r.status_code == 200, body
    assert body["intent"] == "comedy" and body["coverage"] == "searching"
    # What the catalog already had came back right away.
    assert [e["title"] for e in body["events"]] == ["Golden Gate Comedy Night"]
    # The scout was told what's known, so it doesn't find it again.
    assert scout.asks[0][1][0]["title"] == "Golden Gate Comedy Night"
    run = (await client.get(f"/v1/scout/runs/{body['run']['id']}")).json()
    assert run["status"] == "done" and run["added"] == 2 and run["searches"] == 4

    other = await make_user(client, "Ben")
    r2 = await client.get("/v1/discover", params={**params, "q": "anything funny tonight?"}, headers=other)
    b2 = r2.json()
    assert b2["coverage"] == "hit" and b2["checked_at"]
    assert {e["title"] for e in b2["events"]} == {
        "Golden Gate Comedy Night",
        "The Ritual",
        "Your Weird Relationship",
    }
    assert len(scout.asks) == 1
    # Found it: only the asker sees the credit.
    assert not any(e["found_by_you"] for e in b2["events"])
    mine = (await client.get("/v1/me/finds", headers=me)).json()["events"]
    assert {e["title"] for e in mine} == {"The Ritual", "Your Weird Relationship"}
    assert all(e["sources"] == ["scout"] for e in mine)
    assert (await client.get("/v1/me/finds", headers=other)).json()["events"] == []


async def test_without_an_account_or_a_key_the_catalog_answers_and_nothing_runs(client, engine):
    await run_resolve(engine, [cand("funcheap", "a", "Golden Gate Comedy Night")])
    scout = FakeScout([proposal("The Ritual")])
    use(scout)
    params = {"lat": HERE[0], "lon": HERE[1], "intent": "comedy"}
    anon = (await client.get("/v1/discover", params=params)).json()
    assert anon["coverage"] == "miss" and len(anon["events"]) == 1 and not scout.asks

    app.dependency_overrides[get_scout] = lambda: None
    me = await make_user(client, "Ana")
    keyless = (await client.get("/v1/discover", params=params, headers=me)).json()
    assert keyless["coverage"] == "miss" and await count(engine, ScoutRun) == 0


async def test_a_second_ask_during_a_run_joins_it(client, engine):
    use(FakeScout())
    area = cells.area(*HERE)
    maker = async_sessionmaker(engine, expire_on_commit=False)
    async with maker() as s:
        run = ScoutRun(city="sf", area=area, intent="jazz", day=TONIGHT, status="running", started_at=SF_NOW)
        s.add(run)
        await s.flush()
        s.add(Coverage(city="sf", area=area, intent="jazz", day=TONIGHT, state="running", by="scout",
                       run_id=run.id, claimed_at=SF_NOW))  # fmt: skip
        await s.commit()
    me = await make_user(client, "Cy")
    body = (
        await client.get("/v1/discover", params={"lat": HERE[0], "lon": HERE[1], "q": "jazz"}, headers=me)
    ).json()
    assert body["coverage"] == "searching" and body["run"]["id"] == str(run.id)
    assert await count(engine, ScoutRun) == 1


async def test_a_failed_run_ends_its_claim_and_backs_off(client, engine):
    use(FakeScout(fail=True))
    me = await make_user(client, "Di")
    params = {"lat": HERE[0], "lon": HERE[1], "intent": "games"}
    body = (await client.get("/v1/discover", params=params, headers=me)).json()
    run = (await client.get(f"/v1/scout/runs/{body['run']['id']}")).json()
    assert run["status"] == "failed"
    again = (await client.get("/v1/discover", params=params, headers=me)).json()
    assert again["coverage"] == "hit" and await count(engine, ScoutRun) == 1


async def test_quota_and_budget_stop_new_runs(client, engine, monkeypatch):
    from app.config import settings

    use(FakeScout())
    me = await make_user(client, "Ed")
    monkeypatch.setattr(settings, "scout_runs_per_hour", 2)
    kinds = ["games", "film", "art"]
    results = [
        (
            await client.get("/v1/discover", params={"lat": HERE[0], "lon": HERE[1], "intent": k}, headers=me)
        ).json()
        for k in kinds
    ]
    assert [r["coverage"] for r in results] == ["searching", "searching", "miss"]

    monkeypatch.setattr(settings, "scout_runs_per_hour", 50)
    monkeypatch.setattr(settings, "scout_daily_budget_usd", 0)
    over = (
        await client.get(
            "/v1/discover", params={"lat": HERE[0], "lon": HERE[1], "intent": "talks"}, headers=me
        )
    ).json()
    assert over["coverage"] == "miss"


async def test_outside_the_city_is_off(client):
    body = (await client.get("/v1/discover", params={"lat": 40.7, "lon": -74.0, "q": "comedy"})).json()
    assert body["coverage"] == "off" and body["events"] == []


async def test_free_filter_and_venues_are_reused_across_asks(client, engine):
    await run_resolve(
        engine,
        [
            cand("funcheap", "a", "Golden Gate Comedy Night"),
            cand("funcheap", "b", "The Ritual", venue="Endgames", price_text="$12"),
        ],
    )
    body = (
        await client.get(
            "/v1/discover", params={"lat": HERE[0], "lon": HERE[1], "intent": "comedy", "free": True}
        )
    ).json()
    assert [e["title"] for e in body["events"]] == ["Golden Gate Comedy Night"]
    assert await count(engine, Venue) == 2
    assert await count(engine, Find) == 0
