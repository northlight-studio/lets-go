"""Funcheap: free and cheap things to do. Every day page carries schema.org Event data (name, times,
venue, price, status), and each post's CSS classes carry its categories and region.

Allowed by their robots.txt (only search is disallowed). One request a second, a few dozen a night.
"""

import asyncio
import json
import logging
import re
from datetime import date, datetime, timedelta

import httpx

from app.catalog.feeds import USER_AGENT, Candidate
from app.catalog.text import canceled, clean

log = logging.getLogger("letsgo.feeds.funcheap")

BASE = "https://sf.funcheap.com"
SOURCE = "funcheap"

# Their category slugs → our intent tags.
CATEGORY_TAGS = {
    "comedy": "comedy",
    "live-music-event": "live-music",
    "club-dj": "club",
    "eating-drinking": "food",
    "free-food": "food",
    "art-museums": "art",
    "film": "film",
    "fairs-festivals": "festival",
    "block-party": "festival",
    "shopping-fashion": "market",
    "holiday-shopping": "market",
    "outdoors": "outdoors",
    "lectures-workshops": "talks",
    "literature": "talks",
    "geek-event": "talks",
    "dance": "dance",
    "games": "games",
    "sports-fitness": "sports",
}
_LD = re.compile(r'<script type="application/ld\+json">(.*?)</script>', re.S)
_POST = re.compile(r'<div id="post-\d+" class="([^"]*)"[^>]*>(.*?)(?=<div id="post-\d+"|\Z)', re.S)
_HREF = re.compile(r'href="(https://sf\.funcheap\.com/[^"]+)"')
_OTHER_CITY = re.compile(
    r"\b(oakland|berkeley|san jose|alameda|daly city|sausalito|san rafael|redwood city|san mateo|"
    r"santa clara|santa cruz|mountain view|palo alto|richmond|walnut creek|san ramon|lafayette)\b",
    re.I,
)


def _post_classes(page: str) -> dict[str, set[str]]:
    """Each post's URL → its CSS classes (categories, region)."""
    out: dict[str, set[str]] = {}
    for classes, body in _POST.findall(page):
        m = _HREF.search(body)
        if m:
            out.setdefault(m.group(1), set()).update(classes.split())
    return out


def _address(location: dict) -> str:
    a = location.get("address") or ""
    if isinstance(a, dict):
        parts = [a.get("streetAddress"), a.get("addressLocality")]
        return ", ".join(clean(p) for p in parts if p)
    return clean(str(a))


_AT = re.compile(r"\bat (?:SF['’]s |the )?([A-Z][^()|:]+?)\s*(?:\(|$)")
_PARENS = re.compile(r"\(([^()]+)\)\s*$")
_NOT_A_PLACE = re.compile(r"^(sf|zoom|online|virtual|nov.*|dec.*|oct.*|\d.*|every .*|.* only)$", re.I)


def venue_hint(title: str) -> str:
    """Where a listing with no location data says it is: "… (Tala Wine)", "… at Blondie's Bar"."""
    m = _PARENS.search(title)
    if m and not _NOT_A_PLACE.match(m.group(1).strip()):
        return m.group(1).strip()
    m = _AT.search(title)
    return m.group(1).strip() if m else ""


def _in_sf(classes: set[str], name: str, venue: str, address: str) -> bool:
    if "region-san-francisco" in classes or "category-san-francisco" in classes:
        return True
    text = f"{name} {venue} {address}"
    if "san francisco" in text.lower() or "(sf)" in text.lower() or " sf " in f" {text.lower()} ":
        return not _OTHER_CITY.search(address)
    return False


def parse_day(page: str) -> list[Candidate]:
    classes_by_url = _post_classes(page)
    out: list[Candidate] = []
    for blob in _LD.findall(page):
        try:
            data = json.loads(blob)
        except json.JSONDecodeError:
            log.warning("a JSON-LD block didn't parse")
            continue
        for e in data if isinstance(data, list) else [data]:
            if not isinstance(e, dict) or e.get("@type") != "Event":
                continue
            try:
                starts = datetime.fromisoformat(e["startDate"])
            except (KeyError, ValueError):
                continue
            ends = None
            try:
                ends = datetime.fromisoformat(e["endDate"]) if e.get("endDate") else None
            except ValueError:
                ends = None
            if ends is not None and ends <= starts:
                ends = None
            name = clean(e.get("name", ""))
            url = e.get("url") or ""
            location = e.get("location") if isinstance(e.get("location"), dict) else {}
            venue = clean(location.get("name", "")) or venue_hint(name)
            address = _address(location)
            classes = classes_by_url.get(url, set())
            if not name or not _in_sf(classes, name, venue, address):
                continue
            offers = e.get("offers") if isinstance(e.get("offers"), dict) else {}
            price = offers.get("price")
            price_text = ""
            if isinstance(price, int | float) or (
                isinstance(price, str) and price.replace(".", "").isdigit()
            ):
                p = float(price)
                price_text = "Free" if p == 0 else f"${p:g}"
            tags = sorted(
                {
                    CATEGORY_TAGS[c[9:]]
                    for c in classes
                    if c.startswith("category-") and c[9:] in CATEGORY_TAGS
                }
            )
            status = str(e.get("eventStatus", ""))
            out.append(
                Candidate(
                    source=SOURCE,
                    ref=f"{url}|{starts.isoformat()[:16]}",
                    title=name,
                    starts_at=starts,
                    ends_at=ends,
                    venue_name=venue,
                    address=address,
                    url=url,
                    description=clean(e.get("description", ""))[:1000],
                    price_text=price_text,
                    tags=tags,
                    genre="party",
                    canceled=status.endswith("EventCancelled") or canceled(name),
                )
            )
    return out


async def fetch(client: httpx.AsyncClient, start: date, days: int) -> list[Candidate]:
    out: list[Candidate] = []
    for i in range(days):
        d = start + timedelta(days=i)
        for page in range(1, 5):
            url = f"{BASE}/{d:%Y/%m/%d}/" + (f"page/{page}/" if page > 1 else "")
            try:
                r = await client.get(url, headers={"User-Agent": USER_AGENT}, timeout=30)
            except httpx.HTTPError as e:
                log.warning("funcheap %s failed: %s", url, e)
                break
            if r.status_code == 404:
                break
            if r.status_code != 200:
                log.warning("funcheap %s returned %s", url, r.status_code)
                break
            out += parse_day(r.text)
            await asyncio.sleep(1)
            if f"/{d:%Y/%m/%d}/page/{page + 1}/" not in r.text:
                break
    return out
