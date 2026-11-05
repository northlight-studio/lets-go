"""Turning a venue into a point on the map, once per venue.

1. The venues table: anything placed before is reused.
2. Known venues: places that list a name and no address (most of 19hz), with the address we know.
3. San Francisco's own address register (DataSF, Enterprise Addressing System): every street address
   in the city with its point. Public, no key, no attribution strings to carry.

An address that misses the exact number takes the nearest number on the same street, within a block.
Anything still unplaced stays in the catalog without a point and never reaches the map.
"""

import logging
import re
from dataclasses import dataclass
from typing import Protocol

import httpx

from app.catalog.text import clean, venue_key

log = logging.getLogger("letsgo.geocode")

EAS_URL = "https://data.sf.gov/resource/ramy-di5m.json"
CENTERLINES_URL = "https://data.sf.gov/resource/3psu-pn9h.json"


@dataclass(frozen=True)
class Point:
    lat: float
    lon: float


class Geocoder(Protocol):
    async def locate(self, city: str, name: str, address: str) -> Point | None: ...


# Name-only venues, by the names listing sites use. Addresses only: points come from the register.
KNOWN_SF: dict[str, str] = {
    "1015 folsom": "1015 Folsom St",
    "aunt charlie s lounge": "133 Turk St",
    "delirium": "3139 16th St",
    "de young museum": "50 Hagiwara Tea Garden Dr",
    "legion of honor": "100 34th Ave",
    "main library": "100 Larkin St",
    "main public library": "100 Larkin St",
    "thrive city": "1 Warriors Way",
    "yerba buena center for arts": "701 Mission St",
    "ybca": "701 Mission St",
    "1190 folsom": "1190 Folsom St",
    "111 minna": "111 Minna St",
    "audio": "316 11th St",
    "august hall": "420 Mason St",
    "beauty bar": "2299 Mission St",
    "bill graham civic auditorium": "99 Grove St",
    "bimbo s 365 club": "1025 Columbus Ave",
    "bottom of hill": "1233 17th St",
    "castro theatre": "429 Castro St",
    "cat club": "1190 Folsom St",
    "chase center": "1 Warriors Way",
    "dna lounge": "375 11th St",
    "f8": "1192 Folsom St",
    "f8 1192 folsom": "1192 Folsom St",
    "fillmore": "1805 Geary Blvd",
    "great american music hall": "859 O'Farrell St",
    "great northern": "119 Utah St",
    "halcyon": "314 11th St",
    "hawthorn": "46 Geary St",
    "independent": "628 Divisadero St",
    "kilowatt bar": "3160 16th St",
    "madrone art bar": "500 Divisadero St",
    "midway": "900 Marin St",
    "monarch": "101 6th St",
    "public works": "161 Erie St",
    "regency ballroom": "1300 Van Ness Ave",
    "rickshaw stop": "155 Fell St",
    "sea star": "2289 3rd St",
    "underground": "424 Haight St",
    "warfield": "982 Market St",
    "white rabbit": "3138 Polk St",
}

# Places the city's address register doesn't carry (piers, plazas, federal land), with their points.
LANDMARKS_SF: dict[str, tuple[float, float]] = {
    "ferry building": (37.7955, -122.3937),
    "shack15": (37.7955, -122.3937),
    "union square": (37.7880, -122.4075),
    "union square park": (37.7880, -122.4075),
    "zoo": (37.7330, -122.5028),
}
_SPELLED = {
    "first": "01ST", "second": "02ND", "third": "03RD", "fourth": "04TH", "fifth": "05TH",
    "sixth": "06TH", "seventh": "07TH", "eighth": "08TH", "ninth": "09TH", "tenth": "10TH",
}  # fmt: skip
_STREET_TYPES = {
    "st": "ST", "street": "ST", "ave": "AVE", "avenue": "AVE", "blvd": "BLVD", "boulevard": "BLVD",
    "way": "WAY", "dr": "DR", "drive": "DR", "pl": "PL", "place": "PL", "rd": "RD", "road": "RD",
    "ter": "TER", "terrace": "TER", "ct": "CT", "court": "CT", "ln": "LN", "lane": "LN", "hwy": "HWY",
    "plz": "PLZ", "plaza": "PLZ", "aly": "ALY", "alley": "ALY",
}  # fmt: skip
_ADDRESS = re.compile(r"^\s*(\d+)[a-z]?\s+([0-9a-z' .-]+?)(?:[,(]|\s+san francisco\b|$)", re.I)
_ORDINAL = re.compile(r"^(\d+)(st|nd|rd|th)$", re.I)


def parse_street(address: str) -> tuple[int, str] | None:
    """'2965 Mission St (btwn 25th and 26th), San Francisco' → (2965, 'MISSION');
    '4608 3rd St.' → (4608, '03RD'), the register's spelling for one-digit numbered streets."""
    m = _ADDRESS.match(clean(address))
    if not m:
        return None
    name = street_name(m.group(2))
    return (int(m.group(1)), name) if name else None


def street_name(text: str) -> str:
    """'O'Farrell St.' → 'OFARRELL'; 'Third Street' → '03RD'; '3rd' → '03RD'."""
    words = text.replace(".", " ").replace("'", "").replace("’", "").split()
    if words and words[-1].lower() in _STREET_TYPES:
        words = words[:-1]
    if not words:
        return ""
    if words[0].lower() in _SPELLED:
        words[0] = _SPELLED[words[0].lower()]
    first = _ORDINAL.match(words[0])
    if first and len(first.group(1)) == 1:
        words[0] = f"0{first.group(1)}{first.group(2)}"
    return " ".join(words).upper()


_CORNER = re.compile(r"^\s*([a-z0-9' .]+?)\s+(?:and|&|at)\s+([a-z0-9' .]+?)\s*(?:,|$)", re.I)


def parse_corner(text: str) -> tuple[str, str] | None:
    """'Polk St. and Sutter St., San Francisco' → ('POLK', 'SUTTER')."""
    m = _CORNER.match(clean(text))
    if not m:
        return None
    a, b = street_name(m.group(1)), street_name(m.group(2))
    # A bare number is a house number, so this is an address, not a corner.
    if not a or not b or any(w.isdigit() for w in f"{a} {b}".split()):
        return None
    return a, b


class SFRegister:
    """DataSF's address register. One request per new address; the venues table remembers it."""

    def __init__(self, client: httpx.AsyncClient):
        self.client = client

    async def street_point(self, number: int, street: str) -> Point | None:
        lo, hi = max(1, number - 100), number + 100
        q = street.replace("'", "''")
        params = {
            "$select": "address_number,latitude,longitude",
            "$where": f"street_name='{q}' AND address_number between {lo} and {hi}",
            "$limit": "200",
        }
        try:
            r = await self.client.get(EAS_URL, params=params, timeout=20)
            r.raise_for_status()
            rows = r.json()
        except (httpx.HTTPError, ValueError) as e:
            log.warning("address register failed for %s %s: %s", number, street, e)
            return None
        best = None
        for row in rows:
            try:
                n, lat, lon = int(row["address_number"]), float(row["latitude"]), float(row["longitude"])
            except (KeyError, TypeError, ValueError):
                continue
            if best is None or abs(n - number) < best[0]:
                best = (abs(n - number), lat, lon)
        return Point(best[1], best[2]) if best else None

    async def corner(self, a: str, b: str) -> Point | None:
        """Where two streets meet, from the city's street centerlines: the end of a block of `a` that
        names `b` as its cross street."""
        qa, qb = a.replace("'", "''"), b.replace("'", "''")
        params = {
            "$select": "f_st,t_st,line",
            "$where": f"streetname like '{qa} %' and (f_st like '{qb} %' or t_st like '{qb} %')",
            "$limit": "4",
        }
        try:
            r = await self.client.get(CENTERLINES_URL, params=params, timeout=20)
            r.raise_for_status()
            rows = r.json()
        except (httpx.HTTPError, ValueError) as e:
            log.warning("centerlines failed for %s & %s: %s", a, b, e)
            return None
        for row in rows:
            coords = (row.get("line") or {}).get("coordinates") or []
            if not coords:
                continue
            lon, lat = coords[0] if str(row.get("f_st", "")).startswith(b + " ") else coords[-1]
            return Point(float(lat), float(lon))
        return None


class CityGeocoder:
    def __init__(self, client: httpx.AsyncClient):
        self.register = SFRegister(client)

    async def locate(self, city: str, name: str, address: str) -> Point | None:
        if city != "sf":
            return None
        key = venue_key(city, name).split("|", 1)[1]
        if key in LANDMARKS_SF:
            return Point(*LANDMARKS_SF[key])
        known = KNOWN_SF.get(key)
        for candidate in (address, known or "", name):
            parsed = parse_street(candidate) if candidate else None
            if parsed:
                point = await self.register.street_point(*parsed)
                if point:
                    return point
        for candidate in (address, name):
            corner = parse_corner(candidate) if candidate else None
            if corner:
                point = await self.register.corner(*corner)
                if point:
                    return point
        return None
