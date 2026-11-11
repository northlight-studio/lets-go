"""The lamppost poster's plain logic: short codes, weekly repeats, who's calling, how many may join from
the web. No database access here, so it's all testable on its own."""

import hashlib
import math
import re
import secrets
from datetime import UTC, datetime, timedelta
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from app.config import settings

# Lowercase letters and digits minus the ones that read alike on paper (0/o, 1/l/i).
CODE_ALPHABET = "23456789abcdefghjkmnpqrstuvwxyz"
CODE_LENGTH = 6

WEEKDAYS = ("monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday")
_WEEKLY = re.compile(r"^\s*every\s+(" + "|".join(WEEKDAYS) + r")s?\s*$", re.IGNORECASE)
# Letters (any script) in one to three words joined by a space, hyphen or apostrophe, maybe a final
# dot ("Mary J."). No digits, no links: a first name only the host reads.
_NAME = re.compile(r"^[^\W\d_]+(?:[ '’\-][^\W\d_]+){0,2}\.?$")


def new_code() -> str:
    return "".join(secrets.choice(CODE_ALPHABET) for _ in range(CODE_LENGTH))


def normalize_code(raw: str) -> str:
    """Typed from a tab: forgive case, spaces and hyphens."""
    return re.sub(r"[\s\-]", "", raw.lower())


def valid_tz(name: str) -> bool:
    try:
        ZoneInfo(name)
    except (ZoneInfoNotFoundError, ValueError):
        return False
    return True


def is_weekly(recurring: str) -> bool:
    return bool(_WEEKLY.match(recurring or ""))


def next_week(starts: datetime, ends: datetime, tz: str, now: datetime) -> tuple[datetime, datetime]:
    """The first weekly repeat that hasn't ended by `now`, on the same local wall-clock time
    (so 6:30 PM stays 6:30 PM across a daylight-saving change)."""
    z = ZoneInfo(tz)
    local_start = starts.astimezone(z).replace(tzinfo=None)
    local_end = ends.astimezone(z).replace(tzinfo=None)
    weeks = max(1, math.ceil((now - ends) / timedelta(weeks=1)))
    while True:
        s = (local_start + timedelta(weeks=weeks)).replace(tzinfo=z).astimezone(UTC)
        e = (local_end + timedelta(weeks=weeks)).replace(tzinfo=z).astimezone(UTC)
        if e > now:
            return s, e
        weeks += 1


def clean_first_name(raw: str) -> str | None:
    name = " ".join(raw.split())
    if not 1 <= len(name) <= 30 or not _NAME.match(name):
        return None
    return name


def web_limit(capacity: int) -> int:
    """How many may say they're in from the web: a share of a capped gathering's spots (at least one),
    or a fixed number for an open one. The rest stay for people with the app, so nobody can fill a
    gathering from a browser."""
    if capacity <= 0:
        return settings.web_open_max
    return max(1, math.floor(capacity * settings.web_share_of_spots))


def client_ip(forwarded_for: str | None, peer: str | None) -> str:
    """The caller's address. Behind a proxy, the entry the trusted proxy appended (the rightmost
    `trusted_proxy_hops`-th), never one the caller could have written themselves."""
    hops = settings.trusted_proxy_hops
    if forwarded_for and hops > 0:
        parts = [p.strip() for p in forwarded_for.split(",") if p.strip()]
        if len(parts) >= hops:
            return parts[-hops]
    return peer or "unknown"


def ip_hash(ip: str) -> str:
    return hashlib.sha256(f"{settings.web_ip_salt}|{ip}".encode()).hexdigest()


def browser_hash(token: str) -> str:
    return hashlib.sha256(f"browser|{token}".encode()).hexdigest()


def short_link(code: str) -> tuple[str, str]:
    """The link the QR code holds, and the same without the scheme for the tear-off tabs."""
    base = settings.public_base_url.rstrip("/")
    url = f"{base}/p/{code}"
    return url, re.sub(r"^https?://", "", url)
