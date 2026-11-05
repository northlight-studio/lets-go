"""DataSF Mobile Food Schedule: every permitted food truck and cart in the city, by weekday, hours and
curb, with its point. Open data, no key. Weekly rows become dated occurrences."""

import logging
import re
from datetime import date, datetime, timedelta

import httpx

from app.catalog.cells import tz
from app.catalog.feeds import USER_AGENT, Candidate
from app.catalog.text import clean

log = logging.getLogger("letsgo.feeds.datasf")

URL = "https://data.sf.gov/resource/jjew-r69b.json"
PAGE = "https://data.sf.gov/d/jjew-r69b"
SOURCE = "datasf"
WEEKDAYS = {"Monday": 0, "Tuesday": 1, "Wednesday": 2, "Thursday": 3, "Friday": 4, "Saturday": 5, "Sunday": 6}


def truck_name(applicant: str) -> str:
    """'Datam SF LLC dba Anzu To You' → 'Anzu To You'; 'BOWL'D ACAI, LLC.' → "Bowl'd Acai"."""
    name = clean(applicant)
    if re.search(r"\bdba\b", name, re.I):
        name = re.split(r"\bdba\b", name, flags=re.I)[-1]
    name = re.sub(r",?\s*\b(llc|inc|corp|co|l\.l\.c)\b\.?", "", name, flags=re.I).strip(" ,.")
    if name.isupper():
        name = " ".join(w.capitalize() if not w[:1].isdigit() else w.lower() for w in name.split())
    return name


def nice_address(text: str) -> str:
    """'201 02ND ST' → '201 2nd St' (the register pads one-digit street numbers)."""
    words = []
    for w in clean(text).split():
        m = re.match(r"^0?(\d+)(ST|ND|RD|TH)$", w, re.I)
        words.append(f"{int(m.group(1))}{m.group(2).lower()}" if m else w.capitalize())
    return " ".join(words)


def _hhmm(text: str) -> tuple[int, int] | None:
    m = re.match(r"^(\d{1,2}):(\d{2})$", (text or "").strip())
    return (int(m.group(1)), int(m.group(2))) if m else None


def parse_rows(rows: list[dict], start: date, days: int, city: str = "sf") -> list[Candidate]:
    zone = tz(city)
    out: list[Candidate] = []
    for row in rows:
        try:
            lat, lon = float(row["latitude"]), float(row["longitude"])
        except (KeyError, TypeError, ValueError):
            continue
        weekday = WEEKDAYS.get(row.get("dayofweekstr", ""))
        open_, close = _hhmm(row.get("start24", "")), _hhmm(row.get("end24", ""))
        if lat == 0 or weekday is None or open_ is None or close is None:
            continue
        name = truck_name(row.get("applicant", ""))
        where = nice_address(row.get("location", ""))
        if not name or not where:
            continue
        for i in range(days):
            d = start + timedelta(days=i)
            if d.weekday() != weekday:
                continue
            starts = datetime(d.year, d.month, d.day, open_[0] % 24, open_[1], tzinfo=zone)
            ends = datetime(d.year, d.month, d.day, 0, 0, tzinfo=zone) + timedelta(
                hours=close[0], minutes=close[1]
            )
            if ends <= starts:
                ends += timedelta(days=1)
            out.append(
                Candidate(
                    source=SOURCE,
                    ref=f"{row.get('locationid', where)}|{d.isoformat()}|{row.get('start24')}",
                    title=name,
                    starts_at=starts,
                    ends_at=ends,
                    venue_name=where,
                    address=f"{where}, San Francisco, CA",
                    lat=lat,
                    lon=lon,
                    url=PAGE,
                    description=clean(row.get("optionaltext", ""))[:500],
                    tags=["trucks", "food"],
                    genre="food",
                )
            )
    return out


async def fetch(client: httpx.AsyncClient, start: date, days: int) -> list[Candidate]:
    try:
        r = await client.get(URL, params={"$limit": "5000"}, headers={"User-Agent": USER_AGENT}, timeout=60)
        r.raise_for_status()
        rows = r.json()
    except (httpx.HTTPError, ValueError) as e:
        log.warning("DataSF trucks failed: %s", e)
        return []
    return parse_rows(rows, start, days)
