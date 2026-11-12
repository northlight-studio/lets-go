"""Your block: a short list of what's going on within a few blocks, best first, and then it ends.

Plain functions, so the ranking is tested on its own. The route (app/routes/block.py) gathers the
candidates; this decides which few are worth showing and in what order: what's new, what's near,
what's soon, friends first, and never two rows about the same thing.

Nothing here decides who may be named. The route only puts a name on a candidate when the viewer
may see it (a friend, someone they've met, a kitchen's public name); everyone else is a count.
"""

from dataclasses import dataclass, field
from datetime import datetime, timedelta

# "A few blocks": about a ten-minute walk.
RADIUS_M = 800
# How far ahead the block looks for things to go to.
AHEAD = timedelta(hours=36)
# A followed kitchen's next batch counts this far ahead, wherever it is.
FOLLOW_AHEAD = timedelta(days=7)
# The whole list, and the most of any one kind, so one busy kitchen street can't fill it.
MOST = 8
MOST_OF_A_KIND = 3
# Someone else's gathering shows as a count once at least this many people you don't know are in.
MIN_COUNT = 2

# Right now beats a batch, which beats something later in the week.
KIND_WEIGHT = {
    "up_for": 3.0,
    "batch": 2.0,
    "supper": 2.0,
    "back": 1.5,
    "going": 1.0,
    "neighbor": 1.0,
}


@dataclass
class Candidate:
    """One possible row. `key` is stable across pulls, so the phone can tell what you've seen.
    `subject` is what it's about ("kitchen:<id>"): at most one row per subject."""

    key: str
    kind: str
    subject: str
    posted_at: datetime | None = None
    at: datetime | None = None
    ends_at: datetime | None = None
    walk_min: int | None = None
    friend: bool = False
    payload: dict = field(default_factory=dict)


def score(c: Candidate, now: datetime) -> float:
    s = KIND_WEIGHT.get(c.kind, 0.0)
    if c.posted_at is not None:
        age = now - c.posted_at
        if age <= timedelta(hours=6):
            s += 3
        elif age <= timedelta(hours=24):
            s += 2
        elif age <= timedelta(days=3):
            s += 0.5
    if c.walk_min is not None:
        if c.walk_min <= 5:
            s += 2
        elif c.walk_min <= 10:
            s += 1
    if c.at is not None:
        until = c.at - now
        if until <= timedelta(hours=3):
            s += 2
        elif until <= timedelta(hours=24):
            s += 1
    if c.friend:
        s += 2
    return s


def over(c: Candidate, now: datetime) -> bool:
    return c.ends_at is not None and c.ends_at <= now


def rank(candidates: list[Candidate], now: datetime) -> list[Candidate]:
    """Best first; nothing that has ended; one row per subject and per key; a few of each kind; then
    it stops."""
    ordered = sorted(
        (c for c in candidates if not over(c, now)),
        key=lambda c: (-score(c, now), c.at or now + AHEAD * 10, c.key),
    )
    out: list[Candidate] = []
    keys: set[str] = set()
    subjects: set[str] = set()
    kinds: dict[str, int] = {}
    for c in ordered:
        if c.key in keys or c.subject in subjects or kinds.get(c.kind, 0) >= MOST_OF_A_KIND:
            continue
        out.append(c)
        keys.add(c.key)
        subjects.add(c.subject)
        kinds[c.kind] = kinds.get(c.kind, 0) + 1
        if len(out) == MOST:
            break
    return out
