"""The source list end to end, against a fake web (httpx.MockTransport) and a fake model: the nightly
read, health, budget, the hourly re-check, the scout and the finder feeding the list, the admin report,
and nothing that's over coming back from /v1/listings or /v1/discover."""

from datetime import UTC, datetime, timedelta

import httpx
from sqlalchemy import delete, func, select
from sqlalchemy.ext.asyncio import async_sessionmaker

from app.catalog import cells
from app.catalog.scout import Usage
from app.catalog.sources.fetch import Fetcher
from app.catalog.sources.finder import FinderFound, find_sources, grid, per_night
from app.catalog.sources.model import PageRead
from app.catalog.sources.night import read_sources, recheck_soon, record_feeds
from app.catalog.sources.seed import SeedSource, load_seed
from app.catalog.tables import Event, EventSource, ReaderNight, ScoutRun, Source
from tests.conftest import HERE, make_user
from tests.test_catalog import FakeGeocoder, FakeScout, cand, proposal, run_resolve, soon, use
from tests.test_sources_parse import dated, fixture

ZONE = cells.tz("sf")
BIG = 10**9


def source(url: str, name: str, **over) -> SeedSource:
    body = {"url": url, "kind": "venue", "name": name, "venue_name": name, "address": "", "lat": None,
            "lon": None, "genre": "music"} | over  # fmt: skip
    return SeedSource(**body)


SOURCES = [
    source("https://birds.example/events", "Bird & Beckett Books", kind="bookstore",
           address="653 Chenery St, San Francisco, CA"),
    source("https://chapel.example/calendar", "The Chapel", address="777 Valencia St, San Francisco, CA"),
    source("https://hotel.example/shows", "Hotel Utah Saloon", address="500 4th St, San Francisco, CA",
           lat=37.7795, lon=-122.3980),
    source("https://blocked.example/events", "Members Club"),
    source("https://gone.example/calendar", "Closed Venue"),
    source("https://moved.example/calendar", "Moved Venue"),
]  # fmt: skip


class Web:
    """A handful of venue sites. `pages` can be changed between nights."""

    def __init__(self):
        self.hits: list[str] = []
        self.pages = {
            "https://birds.example/events": (
                "text/html",
                '<a href="/events.ics">Subscribe to our calendar</a>',
            ),
            "https://birds.example/events.ics": ("text/calendar", fixture("venue.ics")),
            "https://chapel.example/calendar": ("text/html", fixture("venue_jsonld.html")),
            "https://hotel.example/shows": ("text/html", fixture("plain_calendar.html")),
            "https://blocked.example/events": ("text/html", "<p>secret</p>"),
            "https://moved.example/new-calendar": ("text/html", fixture("venue_jsonld.html")),
        }

    def __call__(self, request: httpx.Request) -> httpx.Response:
        url = str(request.url)
        self.hits.append(url)
        if request.url.path == "/robots.txt":
            if request.url.host == "blocked.example":
                return httpx.Response(200, text="User-agent: LetsGoReader\nDisallow: /\n")
            return httpx.Response(404)
        if url == "https://moved.example/calendar":
            return httpx.Response(301, headers={"location": "https://moved.example/new-calendar"})
        if url in self.pages:
            kind, body = self.pages[url]
            return httpx.Response(200, text=body, headers={"content-type": kind})
        return httpx.Response(404, text="not here")


def at_local(days: int, hour: int, minute: int = 0) -> datetime:
    d = datetime.now(UTC).astimezone(ZONE).date() + timedelta(days=days)
    return datetime(d.year, d.month, d.day, hour, minute, tzinfo=ZONE)


class FakePageModel:
    def __init__(self):
        self.calls: list[dict] = []

    async def read(self, *, url, text, venue, today):
        self.calls.append({"url": url, "text": text, "venue": venue})

        def p(title, starts, **over):
            return {"title": title, "venue_name": "", "address": "", "starts_at": starts, "ends_at": None,
                    "url": "", "price_text": "$5", "ages": "", "description": "", "public": True,
                    "canceled": False} | over  # fmt: skip

        return PageRead(
            [
                p("Open Mic Night", at_local(2, 19).isoformat(), url="https://hotel.example/shows/open-mic"),
                p("The Bellbirds", at_local(4, 20, 30).isoformat(), url="https://tickets.example/e/123"),
                p("Private buyout", at_local(3, 20).isoformat(), public=False),
                p("No offset", at_local(3, 20).replace(tzinfo=None).isoformat()),
                p("Last week", at_local(-7, 20).isoformat()),
            ],
            Usage(tokens_in=7000, tokens_out=800, cache_read=0),
        )


async def night(engine, web, model=None, budget=BIG, now=None, **kw):
    maker = async_sessionmaker(engine, expire_on_commit=False)
    async with maker() as s, httpx.AsyncClient(transport=httpx.MockTransport(web)) as client:
        row = await read_sources(
            s, "sf", Fetcher(client, delay=0), FakeGeocoder(), now or datetime.now(UTC),
            model=model, budget_micros=budget, **kw,
        )  # fmt: skip
        return row


async def seed(engine, sources=None):
    async with async_sessionmaker(engine, expire_on_commit=False)() as s:
        n = await load_seed(s, "sf", SOURCES if sources is None else sources)
        await s.commit()
        return n


async def by_url(engine) -> dict[str, Source]:
    async with async_sessionmaker(engine, expire_on_commit=False)() as s:
        return {r.url: r for r in await s.scalars(select(Source))}


async def titles(engine, **where) -> dict[str, str]:
    async with async_sessionmaker(engine)() as s:
        q = select(Event.title, Event.status)
        for k, v in where.items():
            q = q.where(getattr(Event, k) == v)
        return dict((await s.execute(q)).all())


async def test_the_nightly_read_learns_each_source_reads_by_code_or_model_and_flags_health(engine):
    # Three feeds plus six venues; loading the seed twice adds nothing.
    assert await seed(engine) == 9 and await seed(engine) == 0
    web, model = Web(), FakePageModel()
    first = await night(engine, web, model)

    assert (first.sources, first.read, first.changed, first.by_model) == (6, 4, 4, 1)
    assert first.blocked == 1 and first.failed == 1
    # Poetry Night, and the Chapel's cancelled show from both its addresses.
    assert first.canceled == 3
    assert first.cost_micros == round(7000 * 0.10 + 800 * 0.50)
    assert not any("blocked.example/events" in h for h in web.hits)
    rows = await by_url(engine)
    birds = rows["https://birds.example/events"]
    assert (birds.reader, birds.feed_url, birds.health) == ("ical", "https://birds.example/events.ics", "ok")
    assert birds.events_last == 8 and birds.content_hash
    assert rows["https://chapel.example/calendar"].reader == "jsonld"
    assert rows["https://hotel.example/shows"].reader == "html"
    assert rows["https://blocked.example/events"].health == "blocked"
    assert rows["https://gone.example/calendar"].health == "broken"
    moved = rows["https://moved.example/calendar"]
    assert moved.health == "moved" and moved.moved_to == "https://moved.example/new-calendar"
    assert rows["https://funcheap.com".replace("funcheap", "sf.funcheap")].reader == "feed"

    got = await titles(engine)
    assert got["George Rogers Quartet"] == "on" and got["Poetry Night"] == "canceled"
    assert got["Late Show Comedy"] == "canceled" and got["Big Name Tour"] == "sold_out"
    # The model's events passed the same checks as the scout's: private, offset-less and past ones didn't.
    assert {"Open Mic Night", "The Bellbirds"} <= set(got)
    assert not {"Private buyout", "No offset", "Last week", "Used Book Fair", "Staff party"} & set(got)
    assert model.calls[0]["venue"] == "Hotel Utah Saloon" and "Open Mic Night" in model.calls[0]["text"]
    # The Chapel and its moved twin list the same shows: one event each, two sources.
    async with async_sessionmaker(engine)() as s:
        clams = await s.scalar(select(Event.id).where(Event.title == "Shannon & the Clams"))
        assert await s.scalar(select(func.count()).where(EventSource.event_id == clams)) == 2

    # Nothing changed: nothing is read again, and the model isn't asked.
    second = await night(engine, web, model)
    assert (second.unchanged, second.changed, second.by_model, second.added) == (4, 0, 0, 0)
    assert len(model.calls) == 1

    # The bookstore drops one show and calls off another.
    ics = fixture("venue.ics")
    ics = ics.replace("SUMMARY:George Rogers Quartet", "SUMMARY:George Rogers Quartet\nSTATUS:CANCELLED", 0)
    ics = ics.replace("UID:reading@birds.example", "UID:reading@birds.example\nSTATUS:CANCELLED")
    start = ics.index("BEGIN:VEVENT\nUID:jazz-1")
    ics = ics[:start] + ics[ics.index("END:VEVENT", start) + len("END:VEVENT\n") :]
    web.pages["https://birds.example/events.ics"] = ("text/calendar", ics)
    third = await night(engine, web, model)
    assert third.changed == 1 and third.gone == 1 and third.canceled >= 2
    got = await titles(engine)
    assert got["George Rogers Quartet"] == "gone"
    assert got["A reading with a title long enough that the calendar folds it across two lines"] == "canceled"


async def test_event_pages_that_share_a_site_calendar_are_read_once(engine):
    await seed(
        engine,
        [
            source("https://birds.example/event/one", "Bird & Beckett Books"),
            source("https://birds.example/event/two", "Bird & Beckett Books"),
        ],
    )
    web = Web()
    for path in ("one", "two"):
        web.pages[f"https://birds.example/event/{path}"] = ("text/html", '<a href="/events.ics">iCal</a>')
    await night(engine, web)
    rows = await by_url(engine)
    one, two = rows["https://birds.example/event/one"], rows["https://birds.example/event/two"]
    assert (
        one.active
        and not two.active
        and two.health_note == "same calendar as https://birds.example/event/one"
    )
    assert sum(1 for h in web.hits if h.endswith("events.ics")) == 2  # each learned it once; read once after
    await night(engine, web)
    assert sum(1 for h in web.hits if h.endswith("events.ics")) == 3


async def test_the_budget_holds_back_the_model_and_the_page_waits_for_tomorrow(engine):
    await seed(engine, [SOURCES[2]])
    model = FakePageModel()
    row = await night(engine, Web(), model, budget=0)
    assert row.deferred == 1 and row.by_model == 0 and not model.calls
    hotel = (await by_url(engine))["https://hotel.example/shows"]
    assert hotel.content_hash is None
    # No key at all: the same.
    row = await night(engine, Web(), None)
    assert row.deferred == 1
    # With budget, tomorrow, it's read; the spend counts.
    row = await night(engine, Web(), model)
    assert row.by_model == 1 and row.cost_micros > 0


async def test_a_quiet_source_is_flagged_empty_after_three_weeks(engine):
    await seed(engine, [SOURCES[1]])
    web = Web()
    quiet = '{"@type": "Event", "name": "Gone by", "startDate": "{{ISO-30}}T20:00"}'
    web.pages["https://chapel.example/calendar"] = (
        "text/html",
        dated(f'<script type="application/ld+json">{quiet}</script>'),
    )
    await night(engine, web)
    assert (await by_url(engine))["https://chapel.example/calendar"].health == "ok"
    later = datetime.now(UTC) + timedelta(weeks=3, days=1)
    web.pages["https://chapel.example/calendar"] = (
        "text/html",
        web.pages["https://chapel.example/calendar"][1] + " ",
    )
    web.pages["https://chapel.example/calendar"] = (
        "text/html",
        web.pages["https://chapel.example/calendar"][1].replace("Gone by", "Gone by, again"),
    )
    await night(engine, web, now=later)
    chapel = (await by_url(engine))["https://chapel.example/calendar"]
    assert chapel.health == "empty" and "3 weeks" in chapel.health_note


async def test_the_hourly_recheck_reads_again_what_starts_soon(engine):
    await seed(engine, [SOURCES[1]])
    web = Web()
    start = (
        (datetime.now(UTC) + timedelta(hours=2))
        .astimezone(ZONE)
        .replace(second=0, microsecond=0, tzinfo=None)
    )

    def page(status: str) -> tuple[str, str]:
        return "text/html", (
            '<script type="application/ld+json">{"@type": "Event", "name": "Early Show", '
            f'"startDate": "{start.isoformat()}", "eventStatus": "https://schema.org/{status}"}}</script>'
        )

    web.pages["https://chapel.example/calendar"] = page("EventScheduled")
    await night(engine, web)
    assert (await titles(engine))["Early Show"] == "on"
    web.pages["https://chapel.example/calendar"] = page("EventCancelled")
    maker = async_sessionmaker(engine, expire_on_commit=False)
    async with maker() as s, httpx.AsyncClient(transport=httpx.MockTransport(web)) as client:
        row = await recheck_soon(
            s,
            "sf",
            client,
            Fetcher(client, delay=0),
            FakeGeocoder(),
            datetime.now(UTC),
            model=None,
            budget_micros=0,
        )
    assert row.kind == "recheck" and row.sources == 1 and row.canceled == 1
    assert (await titles(engine))["Early Show"] == "canceled"


async def test_feeds_are_rows_of_the_list_too(engine):
    await seed(engine, [])
    async with async_sessionmaker(engine, expire_on_commit=False)() as s:
        await record_feeds(
            s, "sf", {"funcheap": {"seen": 120}, "19hz": {"error": "failed"}}, datetime.now(UTC)
        )
        await s.commit()
    rows = await by_url(engine)
    assert (
        rows["https://sf.funcheap.com"].events_last == 120 and rows["https://sf.funcheap.com"].health == "ok"
    )
    assert rows["https://19hz.info/eventlisting_BayArea.php"].fails == 1


async def test_a_venue_calendar_the_scout_read_joins_the_list(client, engine):
    with_page = proposal("The Ritual") | {"calendar_url": "https://www.endgamesimprov.com/shows/"}
    aggregator = proposal("Your Weird Relationship", 4) | {
        "calendar_url": "https://www.eventbrite.com/d/sf/comedy/"
    }
    rejected = proposal("Members night") | {"public": False, "calendar_url": "https://private.example/cal"}
    use(FakeScout([with_page, aggregator, rejected]))
    me = await make_user(client, "Ana")
    r = await client.get("/v1/discover", params={"lat": HERE[0], "lon": HERE[1], "q": "comedy"}, headers=me)
    assert r.json()["coverage"] == "searching"
    rows = await by_url(engine)
    assert list(rows) == ["https://www.endgamesimprov.com/shows"]
    page = rows["https://www.endgamesimprov.com/shows"]
    assert (page.added_by, page.reader, page.health, page.venue_name) == (
        "scout",
        "auto",
        "new",
        "Endgames Improv",
    )


class FakeFinder:
    def __init__(self):
        self.searches = []

    async def search(self, s, known):
        self.searches.append((s, known))
        return FinderFound(
            [
                {
                    "url": f"https://{s.kind}-{len(self.searches)}.example/events",
                    "name": "Somewhere",
                    "address": "",
                    "lists_upcoming_events": True,
                    "public": True,
                },
                {
                    "url": "https://www.yelp.com/biz/x",
                    "name": "Yelp",
                    "address": "",
                    "lists_upcoming_events": True,
                    "public": True,
                },
            ],  # fmt: skip
            Usage(tokens_in=30_000, tokens_out=2_000, searches=3),
            "found one",
        )


async def test_the_source_finder_walks_the_city_in_a_week_then_fills_gaps(engine):
    now = datetime.now(UTC)
    finder = FakeFinder()
    maker = async_sessionmaker(engine, expire_on_commit=False)
    async with maker() as s:
        first = await find_sources(s, "sf", finder, now, budget_micros=BIG)
    assert (
        first["searches"] == per_night() and first["added"] == per_night() and first["dropped"] == per_night()
    )
    async with maker() as s:
        runs = list(await s.scalars(select(ScoutRun).where(ScoutRun.intent.like("src:%"))))
        assert len(runs) == per_night() and all(r.status == "done" and r.cost_micros > 0 for r in runs)
        found = list(await s.scalars(select(Source).where(Source.added_by == "finder")))
        assert len(found) == per_night() and all(f.area for f in found)
        # Night two picks up where night one stopped.
        await find_sources(s, "sf", finder, now, budget_micros=BIG)
    assert finder.searches[per_night()][0] == grid()[per_night()]
    async with maker() as s:
        for _ in range(5):
            await find_sources(s, "sf", finder, now, budget_micros=BIG)
        # The whole grid is done; nothing is due again until a week has passed, and then only gaps.
        assert (await find_sources(s, "sf", finder, now, budget_micros=BIG))["searches"] == 0
        assert (await find_sources(s, "sf", finder, now + timedelta(days=8), budget_micros=BIG))[
            "searches"
        ] == 0
        await s.execute(delete(Source).where(Source.kind == "bookstore"))
        await s.commit()
        before = len(finder.searches)
        later = await find_sources(s, "sf", finder, now + timedelta(days=9), budget_micros=BIG)
        assert later["searches"] == 24 and {x.kind for x, _ in finder.searches[before:]} == {"books"}
        # And no money, no searching.
        await s.execute(delete(Source).where(Source.kind == "bookstore"))
        await s.commit()
        assert (await find_sources(s, "sf", finder, now + timedelta(days=30), budget_micros=0)).get("stopped")


async def test_admin_report_is_admin_only_and_has_last_nights_numbers(client, engine, monkeypatch):
    from app.config import settings

    assert (await client.get("/v1/admin/sources")).status_code == 404
    monkeypatch.setattr(settings, "admin_token", "s3cret")
    assert (await client.get("/v1/admin/sources")).status_code == 403
    assert (await client.get("/v1/admin/sources", headers={"X-Admin-Token": "nope"})).status_code == 403
    await seed(engine)
    await night(engine, Web(), FakePageModel())
    r = await client.get("/v1/admin/sources", headers={"X-Admin-Token": "s3cret"})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["sources"] == 9 and body["health"]["ok"] >= 3
    assert {t["health"] for t in body["trouble"]} == {"blocked", "broken", "moved"}
    last = body["last_night"]
    assert last["read"] == 4 and last["changed"] == 4 and last["events_new"] > 0
    assert last["events_canceled"] == 3 and last["cost_usd"] > 0
    assert body["ai_spend_today_usd"] == last["cost_usd"]


async def test_the_reader_counts_against_the_scouts_budget(client, engine, monkeypatch):
    from app.config import settings

    async with async_sessionmaker(engine)() as s:
        s.add(ReaderNight(city="sf", started_at=datetime.now(UTC), cost_micros=2_000_000))
        await s.commit()
    monkeypatch.setattr(settings, "scout_daily_budget_usd", 1.5)
    use(FakeScout())
    me = await make_user(client, "Bo")
    body = (
        await client.get("/v1/discover", params={"lat": HERE[0], "lon": HERE[1], "q": "jazz"}, headers=me)
    ).json()
    assert body["coverage"] == "miss"


# Nothing old


async def test_nothing_that_has_ended_comes_back_from_listings_or_discover(client, engine):
    from app.listings_import import upsert
    from app.schemas import ListingIn

    now = datetime.now(UTC)
    tonight = cells.night_bounds(cells.night_of(now, "sf"), "sf")
    # An event that ended an hour ago, one with no end that started four hours ago, one from last week,
    # and one later tonight.
    ended_at = max(now - timedelta(hours=1), tonight[0] + timedelta(minutes=30))
    await run_resolve(
        engine,
        [
            cand(
                "funcheap",
                "a",
                "Ended Comedy Hour",
                starts_at=ended_at - timedelta(hours=1),
                ends_at=ended_at,
            ),
            cand("funcheap", "b", "Matinee Laughs", venue="Matinee Hall", starts_at=now - timedelta(hours=4)),
            cand("funcheap", "c", "Last Week Laughs", venue="Old Hall", starts_at=now - timedelta(days=7)),
            cand("funcheap", "d", "Later Tonight Laughs", venue="Late Hall", starts_at=soon(2)),
        ],
    )
    local = now.astimezone(ZONE)
    earlier = (local - timedelta(hours=2)).replace(tzinfo=None)
    later = local + timedelta(days=2)
    async with async_sessionmaker(engine, expire_on_commit=False)() as s:
        await upsert(
            s,
            [
                ListingIn.model_validate(
                    {
                        "title": "Over Already",
                        "genre": "music",
                        "venue": "The Independent",
                        "lat": 37.7755,
                        "lon": -122.4377,
                        "schedule": [
                            {
                                "date": earlier.date().isoformat(),
                                "start": f"{earlier:%H:%M}",
                                "end": f"{(earlier + timedelta(minutes=60)):%H:%M}",
                            }
                        ],
                    }
                ),
                ListingIn.model_validate(
                    {
                        "title": "Two Nights",
                        "genre": "music",
                        "venue": "The Independent",
                        "lat": 37.7755,
                        "lon": -122.4377,
                        "schedule": [
                            {"date": (local - timedelta(days=1)).date().isoformat(), "start": "20:00"},
                            {"date": later.date().isoformat(), "start": "20:00"},
                        ],
                    }
                ),
            ],  # fmt: skip
            "sf",
            "manual",
            now,
        )
        await s.commit()

    listings = {i["title"]: i for i in (await client.get("/v1/listings")).json()["listings"]}
    old = {"Ended Comedy Hour", "Matinee Laughs", "Last Week Laughs", "Over Already"}
    assert not old & set(listings)
    # A listing keeps only the dates still to come.
    assert [s["date"] for s in listings["Two Nights"]["schedule"]] == [later.date().isoformat()]
    if soon(2) > now:
        assert "Later Tonight Laughs" in listings

    me = await make_user(client, "Cy")
    use(FakeScout())
    found = (await client.get("/v1/discover", params={"lat": HERE[0], "lon": HERE[1]}, headers=me)).json()
    assert not old & {e["title"] for e in found["events"]}
    for day in (cells.night_of(now, "sf") - timedelta(days=7)).isoformat(), None:
        params = {"lat": HERE[0], "lon": HERE[1], "intent": "comedy"} | ({"day": day} if day else {})
        found = (await client.get("/v1/discover", params=params, headers=me)).json()
        assert not old & {e["title"] for e in found["events"]}
