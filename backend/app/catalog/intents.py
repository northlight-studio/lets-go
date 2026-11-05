"""The kinds of thing people ask for, and the words that mean them.

An intent is deliberately coarse ("comedy", not "comedy under $20 near me"), because it's the key the
coverage ledger is kept by: two people asking in different words should hit the same row. Filters such
as price or "free" are applied to catalog results afterwards and never create a new search.

The same keywords tag events, so an event matches an intent when it carries its tag.
"""

import re
from dataclasses import dataclass

ANY = "any"


@dataclass(frozen=True)
class Intent:
    key: str
    # The app's Genre this kind of thing shows as on the map.
    genre: str
    words: tuple[str, ...]


INTENTS: tuple[Intent, ...] = (
    Intent("comedy", "party", ("comedy", "comedian", "stand-up", "standup", "improv", "funny", "laugh")),
    Intent("jazz", "music", ("jazz", "swing band", "big band", "bebop")),
    Intent("club", "music", ("dj", "techno", "house music", "rave", "club night", "dance party", "edm")),
    Intent(
        "live-music",
        "music",
        ("concert", "live music", "band", "gig", "orchestra", "symphony", "singer", "acoustic", "choir"),
    ),
    Intent("dance", "move", ("salsa", "swing dance", "lindy", "bachata", "tango", "dance class", "ballroom")),
    Intent("trucks", "food", ("food truck", "truck", "food cart", "cart")),
    Intent(
        "food",
        "food",
        ("food", "eat", "dinner", "lunch", "brunch", "tacos", "pizza", "pop-up", "supper", "bites"),
    ),
    Intent("drinks", "party", ("cocktail", "beer", "wine", "cider", "brewery", "happy hour", "tasting")),
    Intent("market", "party", ("market", "flea", "makers", "craft fair", "bazaar", "holiday mart")),
    Intent("art", "party", ("art", "gallery", "museum", "exhibit", "art walk", "art crawl")),
    Intent("film", "party", ("film", "movie", "screening", "cinema", "documentary")),
    Intent("talks", "party", ("talk", "lecture", "book", "reading", "author", "panel", "workshop")),
    Intent("games", "play", ("trivia", "board game", "game night", "bingo", "karaoke", "arcade")),
    Intent("sports", "play", ("pickup", "soccer", "basketball", "volleyball", "roller", "skate")),
    Intent("run", "move", ("run club", "running", "5k", "10k", "jog", "track workout")),
    Intent("ride", "move", ("bike", "bicycle", "critical mass", "cycling")),
    Intent(
        "outdoors",
        "move",
        (
            "hike",
            "hiking",
            "walking tour",
            "nature walk",
            "nature",
            "beach",
            "garden",
            "stargazing",
            "picnic",
        ),
    ),
    Intent("festival", "party", ("festival", "fest", "fair", "parade", "celebration", "block party")),
)
BY_KEY = {i.key: i for i in INTENTS}


def _pattern(word: str) -> re.Pattern[str]:
    return re.compile(r"(?<![a-z0-9])" + re.escape(word) + r"(?![a-z0-9])")


_PATTERNS = {i.key: [_pattern(w) for w in i.words] for i in INTENTS}


def tags_for(*texts: str) -> list[str]:
    """Every intent whose words appear in the text, in vocabulary order."""
    hay = " ".join(t.lower() for t in texts if t)
    return [key for key, pats in _PATTERNS.items() if any(p.search(hay) for p in pats)]


def parse(query: str | None, explicit: str | None = None) -> str:
    """The intent of an ask: the one the phone named, else the first whose words appear, else `any`."""
    if explicit:
        return explicit if explicit in BY_KEY or explicit == ANY else ANY
    tags = tags_for(query or "")
    return tags[0] if tags else ANY


def genre_for(tags: list[str], fallback: str) -> str:
    for t in tags:
        if t in BY_KEY:
            return BY_KEY[t].genre
    return fallback
