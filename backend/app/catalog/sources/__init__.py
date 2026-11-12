"""The city's sources: where San Francisco actually publishes what's on, learned once and read every
night.

    seed.py     the starting list, built from the app's real listings
    fetch.py    polite fetching: robots.txt, one request at a time per host, a clear user agent
    formats.py  structured formats read by code: iCal, schema.org Event JSON-LD, RSS, Squarespace,
                The Events Calendar (WordPress)
    model.py    what's left (a changed page with no structure) read by the model, then checked by code
    night.py    the nightly read and the hourly re-check of what starts soon
    finder.py   the source finder: a scout mode that looks for places that publish a calendar
    report.py   health and last night's numbers, for the admin endpoint and the command line

Every page is data. Nothing on a page can make the reader do anything but return events, and every
event goes through the same code checks and the resolver as the feeds and the scout.
"""

import re
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

# Sites that list other people's events. Their pages are fine to read, but a page there is never a
# venue's own calendar, so the scout doesn't add them as sources.
AGGREGATORS = (
    "funcheap.com",
    "19hz.info",
    "sfstation.com",
    "eventbrite.com",
    "ticketmaster.com",
    "livenation.com",
    "seetickets.us",
    "axs.com",
    "dice.fm",
    "tixr.com",
    "atgtickets.com",
    "jambase.com",
    "songkick.com",
    "bandsintown.com",
    "meetup.com",
    "allevents.in",
    "happeningnext.com",
    "humanitix.com",
    "runsignup.com",
    "runguides.com",
    "do415.com",
    "yelp.com",
    "timeout.com",
    "sf.gov",
    "missionlocal.org",
)
# Ticketing and RSVP platforms: an event page there is the event's own page (it usually carries
# schema.org data), not a listings site.
PLATFORMS = (
    "eventbrite.com",
    "ticketmaster.com",
    "livenation.com",
    "seetickets.us",
    "axs.com",
    "dice.fm",
    "tixr.com",
    "atgtickets.com",
    "humanitix.com",
    "runsignup.com",
    "meetup.com",
    "lu.ma",
    "partiful.com",
)
# Sites that want a login before they show anything, or forbid reading. Never sources.
WALLED = (
    "facebook.com",
    "instagram.com",
    "x.com",
    "twitter.com",
    "tiktok.com",
    "linkedin.com",
    "nextdoor.com",
)
_LOGIN = re.compile(r"/(log-?in|sign-?in|signin|auth|account|accounts|session)(/|$|\?)", re.I)


def host_of(url: str) -> str:
    return (urlsplit(url).hostname or "").lower()


def on(host: str, domains: tuple[str, ...]) -> bool:
    return any(host == d or host.endswith("." + d) for d in domains)


def normalize(url: str) -> str:
    """One spelling per page: lowercase host, https kept as given, no fragment, no tracking query, no
    trailing slash on a path."""
    parts = urlsplit(url.strip())
    query = urlencode(
        [
            (k, v)
            for k, v in parse_qsl(parts.query, keep_blank_values=True)
            if not k.lower().startswith("utm_")
        ]
    )
    path = parts.path.rstrip("/") if parts.path not in ("", "/") else ""
    return urlunsplit((parts.scheme.lower(), (parts.netloc or "").lower(), path, query, ""))


def looks_like_login(url: str) -> bool:
    return bool(_LOGIN.search(urlsplit(url).path)) or on(host_of(url), WALLED)


def public_page(url: str) -> bool:
    """A page anyone can open: http(s), not a social network or a login."""
    return url.startswith(("https://", "http://")) and bool(host_of(url)) and not looks_like_login(url)
