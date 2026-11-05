"""Feeds: sources that already publish what's on. Each turns its own format into `Candidate`s; the
resolver does the rest. A feed never writes to the database."""

from dataclasses import dataclass, field
from datetime import datetime

USER_AGENT = "LetsGo/0.1 (city events app; nightly listing check)"


@dataclass
class Candidate:
    """One occurrence, as a source describes it, before it's matched against the catalog."""

    source: str
    ref: str
    title: str
    starts_at: datetime
    ends_at: datetime | None = None
    venue_name: str = ""
    address: str = ""
    lat: float | None = None
    lon: float | None = None
    url: str = ""
    description: str = ""
    price_text: str = ""
    ages: str = ""
    # Intent tags the source itself implies (a club listing is "club", a truck is "trucks").
    tags: list[str] = field(default_factory=list)
    # The app Genre to fall back on when no tag says otherwise.
    genre: str = "party"
    canceled: bool = False
    why: str | None = None
