"""Structured formats, read by code: iCal, schema.org Event JSON-LD, RSS with event dates, Squarespace's
events JSON and The Events Calendar's REST API (WordPress). Plus `detect`, which learns how a new source
publishes, and `page_text`, which turns a page with no structure into plain text for the model.

A start with no time of day is left out (we never guess when something starts). A time with no UTC
offset is the city's local time, which is what the page means by it.
"""

import html
import json
import re
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from urllib.parse import urljoin, urlsplit
from xml.etree import ElementTree
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from app.catalog import cells
from app.catalog.feeds import Candidate
from app.catalog.text import canceled, clean, sold_out

SOURCE = "reader"
MAX_EVENTS = 300


@dataclass
class Context:
    """Who published the page, so an event with no place of its own lands at the source's venue."""

    source_id: str
    page_url: str
    city: str = "sf"
    venue_name: str = ""
    address: str = ""
    lat: float | None = None
    lon: float | None = None
    genre: str = "party"
    tags: list[str] = field(default_factory=list)
    # Only occurrences that start inside this window are kept (recurring ones are expanded into it).
    window: tuple[datetime, datetime] | None = None

    @property
    def zone(self) -> ZoneInfo:
        return cells.tz(self.city)

    def bounds(self) -> tuple[datetime, datetime]:
        if self.window:
            return self.window
        start = datetime.now(UTC) - timedelta(hours=6)
        return start, start + timedelta(days=60)

    def candidate(
        self,
        *,
        key: str,
        title: str,
        starts: datetime,
        ends: datetime | None = None,
        url: str = "",
        venue: str = "",
        address: str = "",
        lat: float | None = None,
        lon: float | None = None,
        description: str = "",
        price_text: str = "",
        called_off: bool = False,
    ) -> Candidate | None:
        title = clean(title)[:200]
        if not title or starts.tzinfo is None:
            return None
        low, high = self.bounds()
        if not (low <= starts < high):
            return None
        if ends is not None and ends <= starts:
            ends = None
        own_place = bool(venue or address)
        url = urljoin(self.page_url, url) if url else self.page_url
        if not url.startswith(("https://", "http://")):
            url = self.page_url
        return Candidate(
            source=SOURCE,
            ref=f"{self.source_id}|{key or url}|{starts.astimezone(UTC).isoformat()[:16]}"[:500],
            title=title,
            starts_at=starts,
            ends_at=ends,
            venue_name=clean(venue)[:160] if own_place else self.venue_name,
            address=clean(address)[:240] if own_place else self.address,
            lat=lat if lat is not None else (None if own_place else self.lat),
            lon=lon if lon is not None else (None if own_place else self.lon),
            url=url[:500],
            description=clean(strip_tags(description))[:1000],
            price_text=clean(price_text)[:120],
            tags=list(self.tags),
            genre=self.genre,
            canceled=called_off or canceled(title),
        )


def strip_tags(text: str) -> str:
    return re.sub(r"<[^>]+>", " ", text or "")


def _local(when: datetime, zone: ZoneInfo) -> datetime:
    return when if when.tzinfo is not None else when.replace(tzinfo=zone)


def parse_when(value, zone: ZoneInfo) -> datetime | None:
    """An ISO 8601 date-time; a bare date (no time of day) is None."""
    if not isinstance(value, str):
        return None
    text = value.strip()
    if not re.match(r"^\d{4}-\d{2}-\d{2}[T ]\d{1,2}:\d{2}", text):
        return None
    try:
        return _local(datetime.fromisoformat(text.replace("Z", "+00:00")), zone)
    except ValueError:
        return None


# iCal


def _unfold(text: str) -> list[str]:
    lines: list[str] = []
    for raw in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if raw[:1] in (" ", "\t") and lines:
            lines[-1] += raw[1:]
        elif raw:
            lines.append(raw)
    return lines


def _prop(line: str) -> tuple[str, dict[str, str], str]:
    """'DTSTART;TZID="America/Los_Angeles":20261115T200000' → name, params, value."""
    head, value, quoted = "", "", False
    for i, ch in enumerate(line):
        if ch == '"':
            quoted = not quoted
        elif ch == ":" and not quoted:
            head, value = line[:i], line[i + 1 :]
            break
    else:
        return line.upper(), {}, ""
    parts = head.split(";")
    params = {}
    for p in parts[1:]:
        if "=" in p:
            k, v = p.split("=", 1)
            params[k.upper()] = v.strip('"')
    return parts[0].upper(), params, value


def _ical_text(value: str) -> str:
    return re.sub(r"\\([nN,;\\])", lambda m: "\n" if m.group(1) in "nN" else m.group(1), value)


def _ical_time(value: str, params: dict[str, str], zone: ZoneInfo) -> datetime | None:
    value = value.strip()
    if params.get("VALUE") == "DATE" or re.fullmatch(r"\d{8}", value):
        return None
    m = re.fullmatch(r"(\d{8})T(\d{4})(\d{2})?(Z)?", value)
    if not m:
        return None
    naive = datetime.strptime(m.group(1) + m.group(2) + (m.group(3) or "00"), "%Y%m%d%H%M%S")
    if m.group(4):
        return naive.replace(tzinfo=UTC)
    tz = zone
    if params.get("TZID"):
        try:
            tz = ZoneInfo(params["TZID"])
        except (ZoneInfoNotFoundError, ValueError):
            tz = zone  # "Pacific Standard Time" and friends: the city's zone is what they mean here
    return naive.replace(tzinfo=tz)


_DAYS = {"MO": 0, "TU": 1, "WE": 2, "TH": 3, "FR": 4, "SA": 5, "SU": 6}


def _occurrences(start: datetime, rule: str, low: datetime, high: datetime, zone: ZoneInfo) -> list[datetime]:
    """DAILY and WEEKLY rules (INTERVAL, COUNT, UNTIL, BYDAY), expanded into the window, kept on the
    same wall-clock time across daylight saving. Anything fancier keeps only its first occurrence."""
    parts = dict(p.split("=", 1) for p in rule.upper().split(";") if "=" in p)
    freq = parts.get("FREQ")
    if freq not in ("DAILY", "WEEKLY"):
        return [start]
    interval = max(1, int(parts.get("INTERVAL", "1") or 1))
    count = int(parts["COUNT"]) if parts.get("COUNT", "").isdigit() else None
    until = _ical_time(parts["UNTIL"], {}, zone) if "UNTIL" in parts else None
    if until is None and "UNTIL" in parts and re.fullmatch(r"\d{8}", parts["UNTIL"]):
        d = datetime.strptime(parts["UNTIL"], "%Y%m%d")
        until = datetime(d.year, d.month, d.day, 23, 59, tzinfo=zone)
    days = sorted({_DAYS[d[-2:]] for d in parts.get("BYDAY", "").split(",") if d[-2:] in _DAYS})
    # Wall-clock time in the city when the start was given in UTC, so 7 PM stays 7 PM after DST ends.
    tz = zone if start.utcoffset() == timedelta(0) and start.tzinfo is UTC else start.tzinfo
    local = start.astimezone(tz)
    out: list[datetime] = []
    n = 0
    step = timedelta(days=interval if freq == "DAILY" else 7 * interval)
    base = local.date()
    week0 = base - timedelta(days=base.weekday())
    for i in range(0, 800):
        if freq == "DAILY":
            dates = [base + step * i]
        else:
            week = week0 + step * i
            dates = [week + timedelta(days=d) for d in (days or [base.weekday()])]
        for d in dates:
            if d < base:
                continue
            when = datetime(d.year, d.month, d.day, local.hour, local.minute, tzinfo=tz)
            if (until and when > until) or when >= high:
                return out
            n += 1
            if count is not None and n > count:
                return out
            if when >= low:
                out.append(when)
    return out


def parse_ical(text: str, ctx: Context) -> list[Candidate]:
    zone = ctx.zone
    low, high = ctx.bounds()
    events: list[dict] = []
    current: dict | None = None
    depth = 0
    for line in _unfold(text):
        name, params, value = _prop(line)
        if name == "BEGIN" and value.upper() == "VEVENT":
            current, depth = {"EXDATE": []}, 0
        elif current is not None and name == "BEGIN":
            depth += 1  # a VALARM inside the event
        elif current is not None and name == "END" and value.upper() == "VALARM":
            depth -= 1
        elif current is not None and name == "END" and value.upper() == "VEVENT":
            events.append(current)
            current = None
        elif current is not None and depth == 0:
            if name == "EXDATE":
                current["EXDATE"] += [(v, params) for v in value.split(",")]
            else:
                current[name] = (value, params)
    overridden = {
        (e.get("UID", ("", {}))[0], _ical_time(*e["RECURRENCE-ID"], zone))
        for e in events
        if "RECURRENCE-ID" in e
    }
    out: list[Candidate] = []
    for e in events:
        if "DTSTART" not in e:
            continue
        if e.get("CLASS", ("", {}))[0].upper() in ("PRIVATE", "CONFIDENTIAL"):
            continue
        start = _ical_time(*e["DTSTART"], zone)
        if start is None:
            continue
        end = _ical_time(*e["DTEND"], zone) if "DTEND" in e else None
        length = (end - start) if end and end > start else None
        uid = e.get("UID", ("", {}))[0]
        title = _ical_text(e.get("SUMMARY", ("", {}))[0])
        location = clean(_ical_text(e.get("LOCATION", ("", {}))[0]))
        venue, address = split_location(location)
        called_off = e.get("STATUS", ("", {}))[0].upper() == "CANCELLED"
        excluded = {_ical_time(v, p, zone) for v, p in e["EXDATE"]}
        starts = (
            _occurrences(start, e["RRULE"][0], low, high, zone)
            if "RRULE" in e and "RECURRENCE-ID" not in e
            else [start]
        )
        for when in starts:
            if when in excluded or ("RECURRENCE-ID" not in e and "RRULE" in e and (uid, when) in overridden):
                continue
            c = ctx.candidate(
                key=uid or title,
                title=title,
                starts=when,
                ends=when + length if length else None,
                url=e.get("URL", ("", {}))[0].strip(),
                venue=venue,
                address=address,
                description=_ical_text(e.get("DESCRIPTION", ("", {}))[0]),
                called_off=called_off,
            )
            if c:
                out.append(c)
            if len(out) >= MAX_EVENTS:
                return out
    return out


def split_location(location: str) -> tuple[str, str]:
    """'Bottom of the Hill, 1233 17th St, San Francisco' → venue, address. A bare address stays an
    address; a bare name stays a name."""
    if not location:
        return "", ""
    first, _, rest = location.partition(",")
    if re.match(r"^\s*\d+\s+\w", first):
        return "", location
    if rest and re.search(r"\d+\s+\w", rest):
        return first.strip(), rest.strip()
    return location, ""


# schema.org JSON-LD

_LD = re.compile(r"<script[^>]*type=[\"']application/ld\+json[\"'][^>]*>(.*?)</script>", re.S | re.I)


def ld_blocks(page: str) -> list:
    out = []
    for blob in _LD.findall(page or ""):
        blob = blob.strip().removeprefix("<!--").removesuffix("-->").strip()
        try:
            out.append(json.loads(blob))
        except json.JSONDecodeError:
            try:
                out.append(json.loads(html.unescape(blob)))
            except json.JSONDecodeError:
                continue
    return out


def _types(node: dict) -> list[str]:
    t = node.get("@type", [])
    return [str(x) for x in (t if isinstance(t, list) else [t])]


def _is_event(node: dict) -> bool:
    return any(t.endswith("Event") and t != "EventSeries" for t in _types(node))


def _walk(node, out: list[dict], depth: int = 0) -> None:
    if depth > 8 or len(out) >= MAX_EVENTS:
        return
    if isinstance(node, list):
        for item in node:
            _walk(item, out, depth + 1)
    elif isinstance(node, dict):
        if _is_event(node):
            out.append(node)
        for key in ("@graph", "subEvent", "subEvents", "event", "events", "itemListElement", "item"):
            if key in node:
                _walk(node[key], out, depth + 1)


def ld_events(page: str) -> list[dict]:
    found: list[dict] = []
    for block in ld_blocks(page):
        _walk(block, found)
    return found


def _first(value):
    return value[0] if isinstance(value, list) and value else value


def _place(location) -> tuple[str, str, float | None, float | None, bool]:
    """name, address, lat, lon, and whether it's online only."""
    location = _first(location)
    if isinstance(location, str):
        venue, address = split_location(clean(location))
        return venue, address, None, None, False
    if not isinstance(location, dict):
        return "", "", None, None, False
    if "VirtualLocation" in _types(location):
        return "", "", None, None, True
    name = clean(str(location.get("name") or ""))
    a = location.get("address") or ""
    if isinstance(a, dict):
        parts = [
            a.get("streetAddress"),
            a.get("addressLocality"),
            a.get("addressRegion"),
            a.get("postalCode"),
        ]
        address = ", ".join(clean(str(p)) for p in parts if p)
    else:
        address = clean(str(a))
    lat = lon = None
    geo = location.get("geo")
    if isinstance(geo, dict):
        try:
            lat, lon = float(geo.get("latitude")), float(geo.get("longitude"))
        except (TypeError, ValueError):
            lat = lon = None
    return name, address, lat, lon, False


def _price(offers) -> tuple[str, bool]:
    """Price text and whether it's sold out."""
    items = offers if isinstance(offers, list) else [offers]
    prices: list[float] = []
    gone = bool(items) and all(
        isinstance(o, dict) and str(o.get("availability", "")).endswith("SoldOut") for o in items
    )
    for o in items:
        if not isinstance(o, dict):
            continue
        for k in ("price", "lowPrice"):
            try:
                prices.append(float(str(o.get(k)).replace("$", "").replace(",", "")))
            except (TypeError, ValueError):
                pass
    if not prices:
        return "", gone
    low = min(prices)
    return ("Free" if low == 0 else f"${low:g}"), gone


def parse_jsonld(page: str, ctx: Context) -> list[Candidate]:
    out: list[Candidate] = []
    for e in ld_events(page):
        starts = parse_when(e.get("startDate"), ctx.zone)
        if starts is None:
            continue
        venue, address, lat, lon, online = _place(e.get("location"))
        mode = str(e.get("eventAttendanceMode", ""))
        if online or mode.endswith("OnlineEventAttendanceMode"):
            continue
        price_text, gone = _price(e.get("offers"))
        if not price_text and e.get("isAccessibleForFree") in (True, "true", "True"):
            price_text = "Free"
        if gone or sold_out(str(e.get("name", ""))):
            price_text = (price_text + " · sold out").strip(" ·")
        status = str(e.get("eventStatus", ""))
        url = _first(e.get("url")) or ""
        c = ctx.candidate(
            key=str(e.get("@id") or url or e.get("name") or ""),
            title=html.unescape(str(e.get("name") or "")),
            starts=starts,
            ends=parse_when(e.get("endDate"), ctx.zone),
            url=str(url),
            venue=venue,
            address=address,
            lat=lat,
            lon=lon,
            description=html.unescape(str(e.get("description") or "")),
            price_text=price_text,
            called_off=status.endswith(("EventCancelled", "EventPostponed")),
        )
        if c:
            out.append(c)
    return out


# RSS with event dates (the RSS 1.0 event module, used by many calendar plugins)

_EV = "{http://purl.org/rss/1.0/modules/event/}"


def parse_rss(text: str, ctx: Context) -> list[Candidate] | None:
    """Events from a feed whose items carry their own start (ev:startdate). None when the feed's items
    have no event dates (a blog feed's pubDate is when it was posted, not when anything happens)."""
    try:
        root = ElementTree.fromstring(text.encode() if isinstance(text, str) else text)
    except ElementTree.ParseError:
        return None
    items = root.findall(".//item") + root.findall(".//{http://purl.org/rss/1.0/}item")
    dated = [i for i in items if i.find(f"{_EV}startdate") is not None]
    if not dated:
        return None
    out: list[Candidate] = []
    for i in dated:
        starts = parse_when(i.findtext(f"{_EV}startdate", ""), ctx.zone)
        if starts is None:
            continue
        venue, address = split_location(clean(i.findtext(f"{_EV}location", "")))
        link = clean(i.findtext("link", "") or i.findtext("{http://purl.org/rss/1.0/}link", ""))
        title = clean(i.findtext("title", "") or i.findtext("{http://purl.org/rss/1.0/}title", ""))
        c = ctx.candidate(
            key=clean(i.findtext("guid", "")) or link or title,
            title=title,
            starts=starts,
            ends=parse_when(i.findtext(f"{_EV}enddate", ""), ctx.zone),
            url=link,
            venue=venue,
            address=address,
            description=i.findtext("description", ""),
        )
        if c:
            out.append(c)
    return out


# Squarespace events collections (`?format=json`)


def parse_squarespace(text: str, ctx: Context) -> list[Candidate] | None:
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        return None
    if not isinstance(data, dict):
        return None
    items = [i for i in (data.get("upcoming") or []) + (data.get("items") or []) if isinstance(i, dict)]
    if not any("startDate" in i for i in items):
        return None if not ("upcoming" in data or "items" in data) else []
    seen: set[str] = set()
    out: list[Candidate] = []
    for i in items:
        key = str(i.get("id") or i.get("fullUrl") or "")
        if key in seen or not isinstance(i.get("startDate"), int | float):
            continue
        seen.add(key)
        starts = datetime.fromtimestamp(i["startDate"] / 1000, UTC)
        ends = (
            datetime.fromtimestamp(i["endDate"] / 1000, UTC)
            if isinstance(i.get("endDate"), int | float)
            else None
        )
        loc = i.get("location") if isinstance(i.get("location"), dict) else {}
        address = ", ".join(clean(str(loc.get(k))) for k in ("addressLine1", "addressLine2") if loc.get(k))
        lat = loc.get("markerLat") or loc.get("mapLat")
        lon = loc.get("markerLng") or loc.get("mapLng")
        try:
            lat, lon = (float(lat), float(lon)) if lat and lon else (None, None)
        except (TypeError, ValueError):
            lat = lon = None
        c = ctx.candidate(
            key=key,
            title=html.unescape(str(i.get("title") or "")),
            starts=starts,
            ends=ends,
            url=str(i.get("fullUrl") or ""),
            venue=clean(str(loc.get("addressTitle") or "")),
            address=address,
            lat=lat,
            lon=lon,
            description=str(i.get("excerpt") or ""),
        )
        if c:
            out.append(c)
    return out


# The Events Calendar (WordPress): /wp-json/tribe/events/v1/events


def tribe_api(page_url: str) -> str:
    parts = urlsplit(page_url)
    return f"{parts.scheme}://{parts.netloc}/wp-json/tribe/events/v1/events?per_page=50"


def parse_tribe(text: str, ctx: Context) -> list[Candidate] | None:
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        return None
    if not isinstance(data, dict) or not isinstance(data.get("events"), list):
        return None
    out: list[Candidate] = []
    for e in data["events"]:
        if not isinstance(e, dict) or e.get("all_day"):
            continue
        try:
            starts = datetime.fromisoformat(str(e["utc_start_date"])).replace(tzinfo=UTC)
            ends = (
                datetime.fromisoformat(str(e["utc_end_date"])).replace(tzinfo=UTC)
                if e.get("utc_end_date")
                else None
            )
        except (KeyError, ValueError):
            continue
        v = e.get("venue") if isinstance(e.get("venue"), dict) else {}
        address = ", ".join(clean(str(v.get(k))) for k in ("address", "city") if v.get(k))
        cost = clean(str(e.get("cost") or ""))
        c = ctx.candidate(
            key=str(e.get("id") or e.get("url") or ""),
            title=html.unescape(str(e.get("title") or "")),
            starts=starts,
            ends=ends,
            url=str(e.get("url") or ""),
            venue=html.unescape(str(v.get("venue") or "")),
            address=address,
            description=str(e.get("excerpt") or e.get("description") or ""),
            price_text=cost,
        )
        if c:
            out.append(c)
    return out


# Learning how a source publishes

_HREF = re.compile(r"""href=["']([^"']+)["']""", re.I)
_ICS = re.compile(r"(\.ics(\?|$)|^webcal://|[?&]ical=1|/ical/|outlook-ical=1)", re.I)
_GCAL = re.compile(r"^https://calendar\.google\.com/calendar/ical/[^/]+/public/basic\.ics$")


@dataclass
class Learned:
    # ical | jsonld | rss | squarespace | tribe | html
    reader: str
    feed_url: str | None = None


def looks_like_ical(text: str, content_type: str = "") -> bool:
    return "text/calendar" in content_type or (text or "").lstrip().startswith("BEGIN:VCALENDAR")


def looks_like_feed(text: str, content_type: str = "") -> bool:
    head = (text or "").lstrip()[:400].lower()
    return (
        "xml" in content_type and ("<rss" in head or "<rdf:rdf" in head) or head.startswith(("<?xml", "<rss"))
    )


def detect(page: str, page_url: str, content_type: str = "") -> Learned:
    """The best way to read a source, from its page: a calendar file it links to, a known calendar
    platform, schema.org events on the page, or (failing all that) the model."""
    if looks_like_ical(page, content_type):
        return Learned("ical")
    if looks_like_feed(page, content_type):
        return Learned("rss")
    host = (urlsplit(page_url).hostname or "").lower().removeprefix("www.")
    for raw in _HREF.findall(page or ""):
        link = html.unescape(raw).strip()
        if not _ICS.search(link):
            continue
        link = (
            "https://" + link[len("webcal://") :]
            if link.lower().startswith("webcal://")
            else urljoin(page_url, link)
        )
        link_host = (urlsplit(link).hostname or "").lower().removeprefix("www.")
        if link_host == host or _GCAL.match(link):
            return Learned("ical", link)
    if "/wp-content/plugins/the-events-calendar/" in (page or "") or "tribe-events-calendar" in (page or ""):
        return Learned("tribe", tribe_api(page_url))
    if ld_events(page):
        return Learned("jsonld")
    if "static1.squarespace.com" in (page or "") or "<!-- This is Squarespace. -->" in (page or ""):
        joiner = "&" if urlsplit(page_url).query else "?"
        return Learned("squarespace", f"{page_url}{joiner}format=json")
    return Learned("html")


def parse(reader: str, text: str, ctx: Context) -> list[Candidate] | None:
    """Events by code, or None when this text isn't in that format after all."""
    if reader == "ical":
        return parse_ical(text, ctx) if looks_like_ical(text) else None
    if reader == "jsonld":
        return parse_jsonld(text, ctx) if ld_blocks(text) else None
    if reader == "rss":
        return parse_rss(text, ctx)
    if reader == "squarespace":
        return parse_squarespace(text, ctx)
    if reader == "tribe":
        return parse_tribe(text, ctx)
    return None


# Pages with no structure

_DROP = re.compile(r"<(script|style|noscript|svg|template|iframe|head)\b.*?</\1\s*>", re.S | re.I)
_ANCHOR = re.compile(r"<a\b[^>]*href=[\"']([^\"']+)[\"'][^>]*>(.*?)</a>", re.S | re.I)
_BLOCK = re.compile(
    r"</?(p|div|li|ul|ol|tr|td|th|h[1-6]|br|section|article|header|footer|time|dd|dt)\b[^>]*>", re.I
)
_TITLE = re.compile(r"<title[^>]*>(.*?)</title>", re.S | re.I)
_COMMENT = re.compile(r"<!--.*?-->", re.S)


def page_text(page: str, page_url: str, limit: int = 30_000) -> str:
    """What a person would read on the page, links kept as (url), for the model and for hashing."""
    title = clean(html.unescape(strip_tags(m.group(1)))) if (m := _TITLE.search(page or "")) else ""
    body = _COMMENT.sub(" ", page or "")
    body = _DROP.sub(" ", body)

    def link(m: re.Match) -> str:
        href = html.unescape(m.group(1)).strip()
        label = clean(html.unescape(strip_tags(m.group(2))))
        if not label or href.startswith(("#", "javascript:", "mailto:", "tel:")):
            return f" {label} "
        return f" {label} ({urljoin(page_url, href)}) "

    body = _ANCHOR.sub(link, body)
    body = _BLOCK.sub("\n", body)
    body = html.unescape(strip_tags(body))
    lines = [re.sub(r"[ \t\xa0]+", " ", ln).strip() for ln in body.split("\n")]
    text = "\n".join(ln for ln in lines if ln)
    return (f"{title}\n\n{text}" if title else text)[:limit]
