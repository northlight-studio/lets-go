"""Small, testable text rules the resolver depends on: title keys, prices, cancellations."""

import html
import re
from difflib import SequenceMatcher

# Promo noise listing sites put around a title: "$5 Off:", "Free Tix:", "(SF)", "w/ 70+ Makers".
_PREFIX = re.compile(r"^\s*(?:\$\d+\s*off|free(?:\s+tix)?|every\s+\w+|tonight|new)\s*:\s*", re.I)
_PAREN = re.compile(r"\((?:[^()]*)\)")
_WITH = re.compile(r"\s+w/\s.*$", re.I)
_NONWORD = re.compile(r"[^a-z0-9]+")
_CANCEL = re.compile(r"\b(cancell?ed|postponed)\b", re.I)
_SOLD_OUT = re.compile(r"\bsold[\s-]?out\b", re.I)


def clean(text: str) -> str:
    """Unescaped, single-spaced."""
    return re.sub(r"\s+", " ", html.unescape(text or "")).strip()


_TRAILING_SF = re.compile(r"\s*\((?:sf|san francisco)\)\s*$", re.I)


def display_title(title: str) -> str:
    """The title people see: "$5 Off: “The Ritual” Comedy Show (SF)" → "“The Ritual” Comedy Show"."""
    t = _PREFIX.sub("", clean(title))
    return _TRAILING_SF.sub("", t).strip() or clean(title)


def title_key(title: str) -> str:
    t = clean(title).lower().replace("’", "'").replace("“", '"').replace("”", '"')
    t = _PREFIX.sub("", t)
    t = _PAREN.sub(" ", t)
    t = _WITH.sub("", t)
    t = re.sub(r"\b(the|a|an|at|in|sf|san francisco)\b", " ", t)
    return _NONWORD.sub(" ", t).strip()[:200]


def same_title(a: str, b: str) -> bool:
    """Close enough to be one event at one place and time: one key contains the other, or they're
    mostly the same letters."""
    if not a or not b:
        return False
    if a == b or a in b or b in a:
        return True
    return SequenceMatcher(None, a, b).ratio() >= 0.72


def canceled(*texts: str) -> bool:
    return any(_CANCEL.search(t or "") for t in texts)


def sold_out(*texts: str) -> bool:
    return any(_SOLD_OUT.search(t or "") for t in texts)


_MONEY = re.compile(r"\$\s*(\d+(?:\.\d{1,2})?)")


def price_min_cents(text: str) -> int | None:
    """The cheapest way in, in cents: "free" → 0, "$20 b4 11 / $26+" → 2000, "" → unknown."""
    t = (text or "").lower()
    if not t.strip():
        return None
    amounts = [round(float(m) * 100) for m in _MONEY.findall(t)]
    if re.search(r"\bfree\b", t) or re.search(r"pay[- ]what[- ]you[- ]can", t):
        return 0
    return min(amounts) if amounts else None


def venue_key(city: str, name: str, address: str = "") -> str:
    """What venues are matched on: the name, or the street address when there's no real name."""
    base = clean(name) or clean(address)
    base = _PAREN.sub(" ", base.lower())
    base = re.sub(r"\b(the|sf|san francisco)\b", " ", base)
    return f"{city}|{_NONWORD.sub(' ', base).strip()}"[:300]
