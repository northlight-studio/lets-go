"""19hz: the Bay Area's club nights and DJ sets, one table, including door deals like
"free w/rsvp b4 11pm". Venues come as names only; the geocoder knows the common ones."""

import html
import logging
import re
from datetime import date, datetime, timedelta

import httpx

from app.catalog.cells import tz
from app.catalog.feeds import USER_AGENT, Candidate
from app.catalog.text import canceled, clean, title_key

log = logging.getLogger("letsgo.feeds.19hz")

URL = "https://19hz.info/eventlisting_BayArea.php"
SOURCE = "19hz"

_ROW = re.compile(r"<tr[^>]*>(.*?)</tr>", re.S)
_CELL = re.compile(r"<td[^>]*>", re.I)
_HREF = re.compile(r"href=['\"](https?://[^'\"]+)['\"]")
_TIME = re.compile(r"(\d{1,2})(?::(\d{2}))?\s*(am|pm)", re.I)
_AGES = re.compile(r"^(\d{2}\+|all ages)$", re.I)


def _text(cell: str) -> str:
    return clean(re.sub(r"<[^>]+>", " ", html.unescape(cell.replace("</td>", ""))))


def _clock(m: re.Match) -> tuple[int, int]:
    h, mins, ampm = int(m.group(1)) % 12, int(m.group(2) or 0), m.group(3).lower()
    return h + (12 if ampm == "pm" else 0), mins


def parse_listing(page: str, start: date, days: int, city: str = "sf") -> list[Candidate]:
    zone = tz(city)
    last = start + timedelta(days=days)
    out: list[Candidate] = []
    for row in _ROW.findall(page):
        cells = _CELL.split(row)[1:]
        if len(cells) < 7:
            continue
        when, what, genres, price_age, _orgs, links, sort = cells[:7]
        try:
            day = datetime.strptime(_text(sort), "%Y/%m/%d").date()
        except ValueError:
            continue
        if not (start - timedelta(days=1) <= day <= last):
            continue
        title_venue = _text(what)
        if " @ " not in title_venue:
            continue
        title, place = title_venue.rsplit(" @ ", 1)
        m = re.match(r"^(.*?)\s*\(([^()]*)\)\s*$", place)
        venue, where = (m.group(1), m.group(2)) if m else (place, "")
        if where.lower() != "san francisco":
            continue
        when_text = _text(when)
        times = list(_TIME.finditer(when_text.split("(", 1)[-1]))
        multi_day = re.search(
            r"\b(mon|tue|wed|thu|fri|sat|sun):.*-\s*(mon|tue|wed|thu|fri|sat|sun):", when_text, re.I
        )
        hour, minute = _clock(times[0]) if times else (21, 0)
        starts = datetime(day.year, day.month, day.day, hour, minute, tzinfo=zone)
        ends = None
        if len(times) > 1 and not multi_day:
            eh, em = _clock(times[1])
            ends = datetime(day.year, day.month, day.day, eh, em, tzinfo=zone)
            if ends <= starts:
                ends += timedelta(days=1)
        price, ages = "", ""
        for part in (p.strip() for p in _text(price_age).split("|")):
            if _AGES.match(part):
                ages = part
            elif part:
                price = part
        hrefs = _HREF.findall(what) or _HREF.findall(links)
        genre_text = _text(genres)
        tags = ["club"] + (["jazz"] if "jazz" in genre_text.lower() else [])
        out.append(
            Candidate(
                source=SOURCE,
                ref=f"{day.isoformat()}|{title_key(title)}|{title_key(venue)}",
                title=title,
                starts_at=starts,
                ends_at=ends,
                venue_name=venue,
                url=hrefs[0] if hrefs else URL,
                description=genre_text,
                price_text=price,
                ages=ages,
                tags=tags,
                genre="music",
                canceled=canceled(title),
            )
        )
    return out


async def fetch(client: httpx.AsyncClient, start: date, days: int) -> list[Candidate]:
    try:
        r = await client.get(URL, headers={"User-Agent": USER_AGENT}, timeout=30)
        r.raise_for_status()
    except httpx.HTTPError as e:
        log.warning("19hz failed: %s", e)
        return []
    return parse_listing(r.text, start, days)
