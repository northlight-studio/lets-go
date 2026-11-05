"""Where and when, as keys: H3 cells for place, the city-local night for time.

A night runs from 6 AM to 4 AM the next morning, so a set that starts at 1 AM Saturday belongs to
Friday night, which is how people talk about it.
"""

from datetime import UTC, date, datetime, time, timedelta
from zoneinfo import ZoneInfo

import h3

# Coverage is kept per resolution-7 cell: about 5 km², roughly a 15-minute walk across.
AREA_RES = 7
NIGHT_STARTS = time(6, 0)

CITIES: dict[str, ZoneInfo] = {"sf": ZoneInfo("America/Los_Angeles")}
# Roughly the city, from Ocean Beach to the Embarcadero, Daly City line to the Marina.
CITY_BOUNDS: dict[str, tuple[float, float, float, float]] = {"sf": (37.70, 37.84, -122.53, -122.35)}


def tz(city: str) -> ZoneInfo:
    return CITIES.get(city, ZoneInfo("UTC"))


def in_city(city: str, lat: float | None, lon: float | None) -> bool:
    if lat is None or lon is None or city not in CITY_BOUNDS:
        return False
    s, n, w, e = CITY_BOUNDS[city]
    return s <= lat <= n and w <= lon <= e


def area(lat: float, lon: float) -> str:
    return h3.latlng_to_cell(lat, lon, AREA_RES)


def areas_near(lat: float, lon: float, rings: int = 1) -> list[str]:
    """The cell you're in and the ones around it: about a 25-minute walk in any direction."""
    return sorted(h3.grid_disk(area(lat, lon), rings))


def night_of(when: datetime, city: str) -> date:
    local = when.astimezone(tz(city))
    return (local - timedelta(hours=NIGHT_STARTS.hour)).date()


def night_bounds(day: date, city: str) -> tuple[datetime, datetime]:
    """The UTC instants a night starts and ends."""
    start = datetime.combine(day, NIGHT_STARTS, tz(city))
    return start.astimezone(UTC), (start + timedelta(days=1)).astimezone(UTC)


def fresh_for(day: date, city: str, now: datetime) -> timedelta:
    """How long a search for `day` stays good: tonight changes fast, next month doesn't."""
    ahead = (day - night_of(now, city)).days
    if ahead <= 0:
        return timedelta(hours=3)
    if ahead <= 7:
        return timedelta(hours=24)
    return timedelta(days=7)
