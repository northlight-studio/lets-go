"""Wren's three for right now: the request Decisions gets, the fits that come back, and the route."""

from types import SimpleNamespace as NS
from unittest.mock import AsyncMock

import pytest

from app import decisions, llm, right_now
from app.config import settings
from app.main import app
from app.right_now import Thing
from app.routes.right_now import get_decider
from tests.conftest import make_user

THINGS = [
    Thing("jazz", "Jazz trio", "music", "Club Deluxe", "$10", "gathering"),
    Thing("craft", "Kids craft morning", "play", "Mission Library", "Free", "gathering"),
]


def score_answer(name: str, score: float) -> dict:
    spread = [{"value": i, "label": label, "probability": 0.25} for i, label in enumerate(right_now._LEVELS)]
    return {"type": "score", "name": name, "score": score, "probabilities": spread, "confidence": 0.5}


class FakeDecisions:
    def __init__(self, scores: dict[str, float] | None = None, error: Exception | None = None):
        self.scores = scores or {}
        self.bodies: list[dict] = []
        self.post = AsyncMock(side_effect=error or self._post)

    async def _post(self, path, *, body, **_):
        self.bodies.append(body)
        answers = [score_answer(q["name"], self.scores.get(q["name"], 1.0)) for q in body["questions"]]
        return NS(json=lambda: {"model": "gpt-6-luna", "answers": answers, "usage": {"input_tokens": 900}})


async def test_each_thing_gets_one_question_and_a_fit_between_0_and_1():
    ai = FakeDecisions({"jazz": 3.0, "craft": 0.0})
    fits = await right_now.fits(
        ai, local_time="Saturday 7:40 PM", taste=["Into music"], went_to=["Sofar Sounds"], things=THINGS
    )
    assert fits == {"jazz": 1.0, "craft": 0.0}
    (body,) = ai.bodies
    assert body["model"] == settings.ai_model
    assert body["prompt_cache_key"] == "letsgo:right_now:v1"
    assert [q["name"] for q in body["questions"]] == ["jazz", "craft"]
    assert [level["label"] for level in body["questions"][0]["levels"]] == list(right_now._LEVELS)


async def test_the_brief_comes_first_and_the_person_and_the_things_follow_as_json():
    ai = FakeDecisions()
    await right_now.fits(ai, local_time="Saturday 7:40 PM", taste=["Into music"], went_to=[], things=THINGS)
    brief, person = ai.bodies[0]["input"]
    assert brief == {"role": "developer", "content": right_now._BRIEF}
    data = person["content"][0]["data"]
    assert data["local_time"] == "Saturday 7:40 PM"
    assert data["what_they_are_into"] == ["Into music"]
    assert data["nearby"][0] == {
        "key": "jazz",
        "title": "Jazz trio",
        "kind": "gathering",
        "genre": "music",
        "place": "Club Deluxe",
        "price": "$10",
    }


async def test_a_failed_read_is_none_so_the_phone_ranks_on_its_own():
    down = FakeDecisions(error=RuntimeError("down"))
    assert await right_now.fits(down, local_time="now", taste=[], went_to=[], things=THINGS) is None


async def test_switched_off_makes_no_call(monkeypatch):
    monkeypatch.setattr(settings, "decisions_enabled", False)
    ai = FakeDecisions()
    assert await right_now.fits(ai, local_time="now", taste=[], went_to=[], things=THINGS) is None
    assert ai.bodies == []


async def test_at_most_forty_things_are_asked_about():
    ai = FakeDecisions()
    many = [Thing(f"k{i}", f"Thing {i}") for i in range(55)]
    fits = await right_now.fits(ai, local_time="now", taste=[], went_to=[], things=many)
    assert len(ai.bodies[0]["questions"]) == right_now.MOST
    assert len(fits) == right_now.MOST


async def test_a_decisions_call_names_its_cache_key():
    with pytest.raises(ValueError):
        await llm.decide(
            FakeDecisions(), input="x", questions=[decisions.predicate("p", "x")], prompt_cache_key="oops"
        )


def body(things: int = 2) -> dict:
    return {
        "local_time": "Saturday 7:40 PM",
        "taste": ["Into music"],
        "went_to": ["Sofar Sounds"],
        "things": [
            {
                "key": t.key,
                "title": t.title,
                "kind": t.kind,
                "genre": t.genre,
                "place": t.place,
                "price": t.price,
            }
            for t in THINGS[:things]
        ],
    }


async def test_the_route_scores_what_the_phone_sent(client):
    headers = await make_user(client, "Maya")
    ai = FakeDecisions({"jazz": 3.0, "craft": 0.0})
    app.dependency_overrides[get_decider] = lambda: ai
    r = await client.post("/v1/me/right-now", json=body(), headers=headers)
    assert r.status_code == 200
    assert r.json() == {"scored": True, "fits": [{"key": "jazz", "fit": 1.0}, {"key": "craft", "fit": 0.0}]}


async def test_without_a_key_or_with_nothing_to_score_the_phone_is_told_to_rank_alone(client):
    headers = await make_user(client, "Maya")
    app.dependency_overrides[get_decider] = lambda: None
    r = await client.post("/v1/me/right-now", json=body(), headers=headers)
    assert r.json() == {"scored": False, "fits": []}

    ai = FakeDecisions()
    app.dependency_overrides[get_decider] = lambda: ai
    r = await client.post("/v1/me/right-now", json=body(things=0), headers=headers)
    assert r.json() == {"scored": False, "fits": []}
    assert ai.bodies == []


async def test_a_failed_read_still_answers(client):
    headers = await make_user(client, "Maya")
    app.dependency_overrides[get_decider] = lambda: FakeDecisions(error=RuntimeError("down"))
    r = await client.post("/v1/me/right-now", json=body(), headers=headers)
    assert r.status_code == 200
    assert r.json() == {"scored": False, "fits": []}


async def test_it_needs_a_signed_in_phone(client):
    r = await client.post("/v1/me/right-now", json=body())
    assert r.status_code == 401
