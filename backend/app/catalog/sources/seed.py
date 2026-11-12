"""The source list: the seed it starts from, and how new sources join it.

The seed is every distinct venue or organizer page in the app's `sf_happenings.json` (real public pages,
each with its real venue), built into `seed_sources.json` here so the API image carries it:

    python -m app.catalog.sources seed-build ../ios/LetsGo/Resources/sf_happenings.json

Every night the seed is loaded again, adding rows it doesn't have yet and leaving the rest alone, so a
source learned since (its reader, its health) keeps what it learned. Pages that a nightly feed already
covers (Funcheap, 19hz) are left out: the feed reads them.
"""

import json
import re
from collections.abc import Iterable
from dataclasses import asdict, dataclass
from pathlib import Path

from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.catalog import cells
from app.catalog.feeds import datasf_trucks, funcheap, nineteenhz
from app.catalog.sources import AGGREGATORS, PLATFORMS, WALLED, host_of, normalize, on, public_page
from app.catalog.tables import Source

SEED_FILE = Path(__file__).with_name("seed_sources.json")
# The nightly feeds, as rows of the list, so one report covers everything the city is read from.
FEEDS = {
    funcheap.SOURCE: ("Funcheap", funcheap.BASE),
    nineteenhz.SOURCE: ("19hz", nineteenhz.URL),
    datasf_trucks.SOURCE: ("DataSF Mobile Food Schedule", datasf_trucks.PAGE),
}
FEED_HOSTS = ("funcheap.com", "19hz.info")

_MUSEUM = re.compile(
    r"museum|moma|academy of sciences|exploratorium|legion of honor|de young|jewish museum", re.I
)
_BOOKS = re.compile(r"book|city lights", re.I)
_BREW = re.compile(r"brew|taproom|tap room|beer|cider", re.I)
_THEATER = re.compile(r"theat|playhouse|opera|ballet|symphony|cinema|roxie|castro theatre|film", re.I)
_CLUB = re.compile(r"\bclub\b|comedy|improv|lounge|boom boom|bimbo", re.I)
_RUN = re.compile(r"\brun(ning|ners)?\b|november project|5k|10k", re.I)


@dataclass
class SeedSource:
    url: str
    kind: str
    name: str
    venue_name: str = ""
    address: str = ""
    lat: float | None = None
    lon: float | None = None
    genre: str = "party"


def kind_of(url: str, title: str, venue: str, organizer: str, genre: str) -> str:
    host = host_of(url)
    words = f"{venue} {organizer} {host}"
    if on(host, PLATFORMS):
        return "platform"
    if on(host, AGGREGATORS):
        return "aggregator"
    if genre == "move" and _RUN.search(f"{title} {organizer}"):
        return "run_club"
    for kind, rule in (("museum", _MUSEUM), ("bookstore", _BOOKS), ("brewery", _BREW), ("theater", _THEATER)):
        if rule.search(words):
            return kind
    if _CLUB.search(words):
        return "club"
    if organizer and organizer.strip().lower() != venue.strip().lower():
        return "organizer"
    return "venue"


def build(listings: list[dict]) -> list[SeedSource]:
    """One source per distinct public page. The page's venue is the first listing's that names it."""
    out: dict[str, SeedSource] = {}
    for item in listings:
        url = normalize(str(item.get("url") or ""))
        host = host_of(url)
        if not public_page(url) or on(host, FEED_HOSTS) or on(host, WALLED) or url in out:
            continue
        venue = str(item.get("venue") or "").strip()
        organizer = str(item.get("organizer") or "").strip()
        kind = kind_of(url, str(item.get("title") or ""), venue, organizer, str(item.get("genre") or ""))
        out[url] = SeedSource(
            url=url,
            kind=kind,
            name=((organizer or venue) if kind in ("organizer", "run_club") else (venue or organizer))[:160],
            venue_name=venue[:160],
            address=str(item.get("address") or "")[:240],
            lat=item.get("lat"),
            lon=item.get("lon"),
            genre=str(item.get("genre") or "party")[:16],
        )
    return sorted(out.values(), key=lambda s: (host_of(s.url), s.url))


def write_seed(listings_path: Path, out: Path = SEED_FILE) -> int:
    seeds = build(json.loads(listings_path.read_text()))
    out.write_text(json.dumps([asdict(s) for s in seeds], indent=1, ensure_ascii=False) + "\n")
    return len(seeds)


def read_seed(path: Path = SEED_FILE) -> list[SeedSource]:
    return [SeedSource(**row) for row in json.loads(path.read_text())] if path.exists() else []


def _row(city: str, s: SeedSource, added_by: str, reader: str = "auto") -> dict:
    placed = s.lat is not None and s.lon is not None and cells.in_city(city, s.lat, s.lon)
    return {
        "city": city,
        "url": s.url[:500],
        "host": host_of(s.url)[:200],
        "kind": s.kind[:16],
        "name": s.name[:160],
        "venue_name": s.venue_name[:160],
        "address": s.address[:240],
        "lat": s.lat if placed else None,
        "lon": s.lon if placed else None,
        "area": cells.area(s.lat, s.lon) if placed else None,
        "genre": s.genre[:16],
        "reader": reader,
        "added_by": added_by,
        "health": "ok" if reader == "feed" else "new",
    }


async def add(session: AsyncSession, city: str, rows: Iterable[dict]) -> int:
    """Inserts the rows the list doesn't have yet (by city and URL); returns how many were new."""
    rows = list(rows)
    if not rows:
        return 0
    result = await session.execute(
        insert(Source).values(rows).on_conflict_do_nothing(constraint="sources_city_url").returning(Source.id)
    )
    return len(result.all())


async def load_seed(session: AsyncSession, city: str = "sf", seeds: list[SeedSource] | None = None) -> int:
    feeds = [
        _row(city, SeedSource(url=normalize(url), kind="feed", name=name), "seed", reader="feed")
        for name, url in FEEDS.values()
    ]
    rows = feeds + [_row(city, s, "seed") for s in (read_seed() if seeds is None else seeds)]
    added = 0
    for i in range(0, len(rows), 500):
        added += await add(session, city, rows[i : i + 500])
    return added


def calendar_source(url: str) -> bool:
    """A page that can be a venue's or organizer's own calendar: public, and not a listings site, a
    ticketing platform or a social network."""
    host = host_of(url)
    return public_page(url) and not on(host, AGGREGATORS + PLATFORMS + WALLED + FEED_HOSTS)


async def add_found(session: AsyncSession, city: str, found: list[SeedSource], added_by: str) -> int:
    """Pages the scout or the source finder came across. Only calendar pages join."""
    rows = [
        _row(city, SeedSource(**{**asdict(s), "url": normalize(s.url)}), added_by)
        for s in found
        if calendar_source(normalize(s.url))
    ]
    return await add(session, city, rows)
