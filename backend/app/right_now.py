"""Wren's three for right now: how well each thing nearby fits one person, this hour.

The phone already ranks what's near by the clock and the walk (`Picks` on iOS): soon, close, filling
up. What it can't tell is that a jazz trio suits someone who keeps going to gigs and a kids' craft
morning doesn't. This is that read: one Decisions call (`app.decisions`) with a question per thing,
each answered on a four-step rubric with a probability, back in well under a second for forty things.

The phone sends the things it's already showing and what it has learned about the person (their taste
notes, the titles of what they've joined). The server keeps none of it. What comes back is a fit from
0 to 1 for each thing; the phone folds that into its own ranking, so a thing that has ended, is full
or is an hour's walk away still never gets picked, whatever its fit.

Nothing here invents anything: it scores things the phone sent, and writes no words.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Any

from app import decisions, llm
from app.config import settings

log = logging.getLogger(__name__)

PROMPT_CACHE_KEY = "letsgo:right_now:v1"
MOST = 40

_BRIEF = (
    "You help a neighborhood guide decide what one person would enjoy doing in the next few hours, "
    "within walking distance. You are given what the app has learned about them (short notes on what "
    "they're into, and things they have gone to before), the local day and time, and a list of things "
    "happening nearby, each with a key. For each question, judge only the thing named by its key. "
    "Judge the fit to this person's tastes and to the hour; ignore how far away it is and how soon it "
    "starts, which are handled separately. When little is known about the person, judge by how "
    "broadly appealing the thing is at this hour for an adult going out on their own or with a friend."
)

_LEVELS = {
    "not for them": "nothing suggests they'd want this, or it's clearly for someone else",
    "maybe": "nothing against it, nothing in particular for it",
    "likely": "it matches something they're into",
    "very likely": "it matches what they keep choosing",
}


@dataclass(frozen=True)
class Thing:
    key: str
    title: str
    genre: str = ""
    place: str = ""
    price: str = ""
    kind: str = ""


def request_input(local_time: str, taste: list[str], went_to: list[str], things: list[Thing]) -> list[dict]:
    """The stable brief first, then this person and what's near as JSON."""
    data = {
        "local_time": local_time,
        "what_they_are_into": taste,
        "things_they_went_to": went_to,
        "nearby": [
            {
                k: v
                for k, v in (
                    ("key", t.key),
                    ("title", t.title),
                    ("kind", t.kind),
                    ("genre", t.genre),
                    ("place", t.place),
                    ("price", t.price),
                )
                if v
            }
            for t in things
        ],
    }
    return [
        {"role": "developer", "content": _BRIEF},
        {"role": "user", "content": [decisions.json_part(data)]},
    ]


def questions(things: list[Thing]) -> list[dict]:
    return [
        decisions.score(
            t.key, f"How much would this person want to go to the thing with key {t.key}?", _LEVELS
        )
        for t in things
    ]


async def fits(
    client: Any, *, local_time: str, taste: list[str], went_to: list[str], things: list[Thing]
) -> dict[str, float] | None:
    """Each thing's fit, 0 to 1, by key. None when it couldn't be read: the phone ranks on its own."""
    things = things[:MOST]
    if not things or not settings.decisions_enabled:
        return None
    try:
        decision = await llm.decide(
            client,
            input=request_input(local_time, taste, went_to, things),
            questions=questions(things),
            prompt_cache_key=PROMPT_CACHE_KEY,
            surface="right_now",
        )
    except decisions.DecisionError as error:
        log.warning("right now: not scored: %s", error)
        return None
    out: dict[str, float] = {}
    for t in things:
        answer = decision.get(t.key)
        if answer is not None:
            out[t.key] = round(answer.fraction, 3)
    return out or None
