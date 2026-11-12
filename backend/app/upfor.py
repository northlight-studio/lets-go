"""Up for something: what you can say you're up for, how it reads, and how a match meets.

Plain functions, so they're tested on their own. Nothing here ever hands anyone else your
coordinates: what leaves the server is a walk time, a rough halfway square, and a public spot.
"""

import math
from dataclasses import dataclass
from datetime import datetime, timedelta

from app.geo import distance_m


@dataclass(frozen=True)
class Activity:
    key: str
    label: str  # "A walk", on the chip and the row
    bubble: str  # "walk?", on a friend's pin
    doing: str  # "going for a walk", in "You and Maya are going for a walk"


ACTIVITIES: dict[str, Activity] = {
    a.key: a
    for a in (
        Activity("walk", "A walk", "walk?", "going for a walk"),
        Activity("coffee", "Coffee", "coffee?", "getting coffee"),
        Activity("drink", "A drink", "drink?", "getting a drink"),
        Activity("pickup", "Pickup game", "game?", "playing a pickup game"),
        Activity("cooking", "Cooking", "cook?", "cooking"),
    )
}

# How long you can be up for something, and how long a match lasts if nobody taps Done.
MAX_HOURS = 4
MATCH_LASTS = timedelta(hours=3)
# About 80 m a minute, the same as the phone's Walk, with streets not being straight lines.
WALK_M_PER_MIN = 80
STREET_FACTOR = 1.2
# The halfway point is only ever shared rounded to a square this many degrees on a side
# (about 330 m north-south), and a spot has to be this close to the real halfway point.
AREA_STEP = 0.003
SPOT_WITHIN_M = 1500


def label(activity: str, words: str) -> str:
    a = ACTIVITIES.get(activity)
    if a:
        return a.label
    return words.strip() or "Something"


def bubble(activity: str, words: str) -> str:
    a = ACTIVITIES.get(activity)
    if a:
        return a.bubble
    w = words.strip().split()
    if not w:
        return "hi?"
    first = w[0].lower().strip("?!.,")
    return f"{first[:10]}?" if first else "hi?"


def headline(activity: str, words: str, other_first: str) -> str:
    a = ACTIVITIES.get(activity)
    if a:
        return f"You and {other_first} are {a.doing}"
    return f"You and {other_first} are meeting up"


def walk_minutes(meters: float) -> int:
    return max(1, round(meters * STREET_FACTOR / WALK_M_PER_MIN))


def rough_minutes(meters: float) -> int:
    """For people who aren't matched with you: exact up to ten minutes, then to the nearest five."""
    m = walk_minutes(meters)
    return m if m <= 10 else int(5 * round(m / 5))


def halfway(a: tuple[float, float], b: tuple[float, float]) -> tuple[float, float]:
    return (a[0] + b[0]) / 2, (a[1] + b[1]) / 2


def rough_area(point: tuple[float, float]) -> tuple[float, float]:
    """The middle of the square a point falls in. What a matched phone gets to search for a spot."""

    def snap(v: float) -> float:
        return round((math.floor(v / AREA_STEP) + 0.5) * AREA_STEP, 6)

    return snap(point[0]), snap(point[1])


def spot_ok(spot: tuple[float, float], a: tuple[float, float] | None, b: tuple[float, float] | None) -> bool:
    """A spot has to be somewhere both of you can reasonably walk to: near the real halfway point."""
    if a is None or b is None:
        return False
    mid = halfway(a, b)
    return distance_m(spot[0], spot[1], mid[0], mid[1]) <= SPOT_WITHIN_M


def meet_at(now: datetime, minutes_away: list[int]) -> datetime:
    """When to meet: once the longer walk is done, plus a few minutes, on the next five."""
    longest = max([m for m in minutes_away if m is not None] or [10])
    t = now + timedelta(minutes=longest + 3)
    step = 5 * 60
    secs = math.ceil(t.timestamp() / step) * step
    return datetime.fromtimestamp(secs, tz=t.tzinfo)
