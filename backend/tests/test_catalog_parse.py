"""Feeds and the small text rules the resolver leans on. No database."""

import json
from datetime import date, datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

from app.catalog import cells, intents
from app.catalog.feeds import datasf_trucks, funcheap, nineteenhz
from app.catalog.feeds.funcheap import venue_hint
from app.catalog.geocode import parse_corner, parse_street
from app.catalog.scout import Ask, to_candidates
from app.catalog.text import canceled, display_title, price_min_cents, same_title, title_key, venue_key

FIX = Path(__file__).parent / "fixtures"
SF = ZoneInfo("America/Los_Angeles")


def test_funcheap_reads_sf_events_with_categories_and_skips_other_cities():
    found = funcheap.parse_day((FIX / "funcheap_day.html").read_text())
    titles = {c.title: c for c in found}
    assert set(titles) == {
        "“Rush Hour Comedy Night” (The Function)",
        "Fort Mason Night Market 2026 w/ 70+ Makers (SF)",
        "Street Fest (Canceled)",
    }
    comedy = titles["“Rush Hour Comedy Night” (The Function)"]
    assert comedy.tags == ["comedy"]
    assert comedy.price_text == "Free"
    assert comedy.address == "1414 Market Street, San Francisco, CA"
    assert comedy.starts_at == datetime(2026, 11, 6, 19, 0, tzinfo=SF)
    assert titles["Fort Mason Night Market 2026 w/ 70+ Makers (SF)"].tags == ["festival", "market"]
    assert titles["Street Fest (Canceled)"].canceled
    assert titles["Street Fest (Canceled)"].price_text == "$12"


def test_19hz_reads_sf_rows_times_past_midnight_and_door_deals():
    found = nineteenhz.parse_listing((FIX / "19hz.html").read_text(), date(2026, 11, 6), 7)
    by = {c.title: c for c in found}
    assert set(by) == {"Fieldtest: DJ Koolt, Naone", "Hawthorn Feat. Kromatic", "Polar Inertia"}
    ft = by["Fieldtest: DJ Koolt, Naone"]
    assert ft.venue_name == "Public Works"
    assert ft.starts_at == datetime(2026, 11, 6, 21, 0, tzinfo=SF)
    assert ft.ends_at == datetime(2026, 11, 7, 3, 0, tzinfo=SF)
    assert (ft.price_text, ft.ages) == ("$20 b4 11 / $26+", "21+")
    assert ft.tags == ["club"] and ft.genre == "music"
    # No link in the title cell: the row's other link.
    assert by["Hawthorn Feat. Kromatic"].url == "https://example.com/hawthorn"
    # Multi-day: start known, end left open.
    assert by["Polar Inertia"].ends_at is None


def test_trucks_become_dated_occurrences_with_their_point():
    anzu = {"applicant": "Datam SF LLC dba Anzu To You", "location": "2535 TAYLOR ST", "locationid": "9"}
    dots = {"applicant": "Bay Area Dots, LLC", "location": "900 BEACH ST", "locationid": "7"}
    rows = [
        anzu | {"dayofweekstr": "Saturday", "start24": "11:00", "end24": "16:00",
                "latitude": "37.80573", "longitude": "-122.41537", "optionaltext": "Musubi, sliders"},
        dots | {"dayofweekstr": "Friday", "start24": "06:00", "end24": "24:00",
                "latitude": "37.80627", "longitude": "-122.42388"},
        {"dayofweekstr": "Friday", "start24": "06:00", "end24": "24:00", "applicant": "Nowhere Cart",
         "location": "1 NOWHERE", "latitude": "0", "longitude": "0", "locationid": "8"},
    ]  # fmt: skip
    found = datasf_trucks.parse_rows(rows, date(2026, 11, 5), 7)
    assert [(c.title, c.starts_at.date()) for c in found] == [
        ("Anzu To You", date(2026, 11, 7)),
        ("Bay Area Dots", date(2026, 11, 6)),
    ]
    dots = found[1]
    assert dots.ends_at == datetime(2026, 11, 7, 0, 0, tzinfo=SF)
    assert (dots.lat, dots.venue_name, dots.tags) == (37.80627, "900 Beach St", ["trucks", "food"])


def test_title_keys_ignore_promo_noise_and_match_across_sites():
    a = title_key("$5 Off: “The Ritual” Comedy Show in The Mission (SF)")
    b = title_key("The Ritual Comedy Show")
    assert same_title(a, b)
    assert not same_title(title_key("Moby"), title_key("Danny L Harle"))
    assert (
        venue_key("sf", "Bottom Of The Hill")
        == venue_key("sf", "bottom of the hill (SF)")
        == "sf|bottom of hill"
    )


def test_display_titles_and_truck_addresses_read_like_people_write_them():
    assert (
        display_title("$5 Off: “The Ritual” Comedy Show in The Mission (SF)")
        == "“The Ritual” Comedy Show in The Mission"
    )
    assert display_title("Free Tix: Desi Comedy Night") == "Desi Comedy Night"
    assert display_title("Rush Hour Comedy Night (The Function)") == "Rush Hour Comedy Night (The Function)"
    assert datasf_trucks.nice_address("201 02ND ST") == "201 2nd St"
    assert datasf_trucks.nice_address("15 MARINA BLVD") == "15 Marina Blvd"


def test_prices_and_cancellations():
    assert price_min_cents("free w/rsvp b4 11pm / $15") == 0
    assert price_min_cents("$20 b4 11 / $26+") == 2000
    assert price_min_cents("$5.50+") == 550
    assert price_min_cents("") is None
    assert canceled("Oakland First Fridays (Nov. 2026 Canceled)")
    assert canceled("Show — CANCELLED")
    assert not canceled("Cancel culture: a comedy hour")


def test_streets_parse_the_way_the_city_register_spells_them():
    assert parse_street("2965 Mission St (btwn 25th and 26th), San Francisco, CA") == (2965, "MISSION")
    assert parse_street("4608 3rd St., San Francisco, CA") == (4608, "03RD")
    assert parse_street("100 34th Avenue, San Francisco, CA 94121") == (100, "34TH")
    assert parse_street("859 O'Farrell St") == (859, "OFARRELL")
    assert parse_street("2569 Third Street, San Francisco, CA 94107") == (2569, "03RD")
    assert parse_street("Hayes St. and Laguna St., San Francisco") is None
    assert parse_corner("Hayes St. and Laguna St., San Francisco") == ("HAYES", "LAGUNA")
    assert parse_corner("Geary and Powell, San Francisco, CA") == ("GEARY", "POWELL")
    assert parse_corner("2 Marina Blvd, San Francisco") is None


def test_listings_without_location_data_name_their_venue_in_the_title():
    assert venue_hint("Practice French + Meet SF Francophones (Tala Wine)") == "Tala Wine"
    assert venue_hint("Every Thursday: “Inner Circle” Dance Party at White Rabbit (SF)") == "White Rabbit"
    assert venue_hint("Free Research Webinar (Zoom)") == ""
    assert venue_hint("Rooftop Stargazing Nights (Nov. 2026)") == ""


def test_intents_from_words():
    assert intents.parse("anything funny tonight?") == "comedy"
    assert intents.parse("comedy under $20") == "comedy"
    assert intents.parse("late tacos") == "food"
    assert intents.parse("something chill") == intents.ANY
    assert intents.parse(None, "jazz") == "jazz"
    assert intents.parse(None, "not-a-thing") == intents.ANY
    assert "trucks" in intents.tags_for("Philz Coffee truck")


def test_nights_run_six_to_four():
    late = datetime(2026, 11, 7, 1, 30, tzinfo=SF)
    assert cells.night_of(late, "sf") == date(2026, 11, 6)
    start, end = cells.night_bounds(date(2026, 11, 6), "sf")
    assert end - start == timedelta(days=1)
    assert start.astimezone(SF).hour == 6


def proposal(**over) -> dict:
    return {
        "title": "The Infinite Wrench",
        "venue_name": "447 Minna St",
        "address": "447 Minna St, San Francisco, CA",
        "starts_at": "2026-11-06T21:00:00-08:00",
        "ends_at": None,
        "url": "https://example.com/wrench",
        "price_text": "$18",
        "ages": "",
        "description": "30 plays in 60 minutes",
        "why": "Thirty tiny plays in an hour, and the crowd picks the order.",
        "public": True,
    } | over


def test_scout_proposals_are_checked_in_code():
    ask = Ask("sf", "872830828ffffff", "comedy", date(2026, 11, 6), 37.78, -122.41)
    good, dropped = to_candidates(
        ask,
        [
            proposal(),
            proposal(title="Members' night", description="Members only, bring your card"),
            proposal(public=False),
            proposal(url="javascript:alert(1)"),
            proposal(starts_at="2026-11-09T21:00:00-08:00"),
            proposal(starts_at="not a date"),
            proposal(starts_at="2026-11-06T21:00:00"),
        ],
    )
    assert dropped == 6
    assert [c.title for c in good] == ["The Infinite Wrench"]
    assert good[0].source == "scout" and good[0].tags == ["comedy"] and good[0].why


class FakeResponses:
    """Plays back Responses API replies and records each request."""

    def __init__(self, replies):
        self.replies = list(replies)
        self.requests: list[dict] = []

    async def create(self, **kwargs):
        self.requests.append(kwargs)
        return self.replies.pop(0)


def reply(rid: str, *items, text: str = "", cached: int = 0):
    from types import SimpleNamespace as NS

    usage = NS(input_tokens=1000, output_tokens=200, input_tokens_details=NS(cached_tokens=cached))
    return NS(id=rid, status="completed", output=list(items), output_text=text, usage=usage)


def call(cid: str, name: str, arguments: dict):
    from types import SimpleNamespace as NS

    return NS(type="function_call", call_id=cid, name=name, arguments=json.dumps(arguments))


def searched(action: str = "search"):
    from types import SimpleNamespace as NS

    return NS(type="web_search_call", action=NS(type=action))


async def test_openai_scout_reads_the_catalog_proposes_and_stops():
    from types import SimpleNamespace as NS

    from app.catalog.scout import PROMPT_CACHE_KEY, OpenAIScout

    responses = FakeResponses(
        [
            reply("r1", searched(), searched("open_page"), call("c1", "catalog_search", {})),
            reply("r2", searched(), call("c2", "propose_events", {"events": [proposal()]}), cached=800),
            reply("r3", text="Found one new show."),
        ]
    )
    scout = OpenAIScout(NS(responses=responses), "gpt-6-luna", "medium")
    ask = Ask("sf", "872830828ffffff", "comedy", date(2026, 11, 6), 37.78, -122.41, "Mission")
    found = await scout.search(ask, [{"title": "Golden Gate Comedy Night"}])

    assert [p["title"] for p in found.proposals] == ["The Infinite Wrench"]
    assert found.note == "Found one new show."
    # Two searches (opening a page isn't one), three replies' tokens, 800 of them read from cache.
    assert found.usage.searches == 2 and found.usage.tokens_in == 3000 and found.usage.cache_read == 800
    assert found.usage.cost_micros == round(2200 * 0.10 + 800 * 0.01 + 600 * 0.50 + 2 * 10_000)
    first, second = responses.requests[0], responses.requests[1]
    assert first["model"] == "gpt-6-luna" and first["reasoning"] == {"effort": "medium"}
    assert first["prompt_cache_key"] == PROMPT_CACHE_KEY == "letsgo:scout:v1"
    assert "temperature" not in first
    assert [t.get("name", t["type"]) for t in first["tools"]] == [
        "web_search",
        "catalog_search",
        "propose_events",
    ]
    assert (
        "Mission" in first["input"][0]["content"]
        and "Friday, November 6, 2026" in first["input"][0]["content"]
    )
    # Later rounds carry on from the last reply and send back only the function outputs.
    assert second["previous_response_id"] == "r1"
    assert second["input"][0]["call_id"] == "c1" and "Golden Gate" in second["input"][0]["output"]
    assert responses.requests[2]["input"][0]["output"].startswith("Received 1.")


async def test_every_model_call_names_its_cache_key():
    from types import SimpleNamespace as NS

    import pytest

    from app import llm

    with pytest.raises(ValueError):
        await llm.create(NS(responses=FakeResponses([])), model="gpt-6-luna", input="hi")
    with pytest.raises(ValueError):
        await llm.create(
            NS(responses=FakeResponses([])), model="gpt-6-luna", prompt_cache_key="letsgo:x:v1", temperature=0
        )
