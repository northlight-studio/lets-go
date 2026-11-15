"""Typed answers from OpenAI's Decisions API: a probability, a choice from a fixed list, or a score
on a rubric. Reached as `llm.decide(client, ...)`. The same module as Pulse's.

Decisions never writes text. It reads the input (text, images, JSON) and answers the questions it's
handed, each with a probability, at about a tenth of a Responses call's latency and with no output
tokens to pay for. So it ranks and sorts; the writing stays with `llm.create`, or on the phone.

- It is OpenAI-only. A caller catches `DecisionError` and falls back to what it did before.
- A probability is not a verdict: each caller owns its own lines and says where they came from.
- The stable context goes first, in `input`: the cached prefix ends where `input` does, and the
  questions sit outside it. It has to reach 1,024 tokens before anything is cached.

The SDK this app pins has no `client.decisions`, so the request goes out through the client's own
`post`, which keeps its key, timeout and retries.
"""

from __future__ import annotations

import logging
import time
from dataclasses import dataclass, field
from typing import Any

import httpx

from app.config import settings

logger = logging.getLogger(__name__)

PATH = "/decisions"
#: Decisions is meant to be quick; one that isn't has stopped being worth
#: waiting for, and every caller has a slower path to fall back to.
DEFAULT_TIMEOUT_SECONDS = 8.0
MAX_QUESTIONS = 400


class DecisionError(RuntimeError):
    """The call failed, or came back in a shape nothing here can read."""


# ---------------------------------------------------------------------------
# Questions
# ---------------------------------------------------------------------------


def predicate(name: str, instructions: str) -> dict:
    """How likely a statement is true. Write `instructions` as the statement."""
    return {"type": "predicate", "name": name, "instructions": instructions}


def choice(name: str, instructions: str, choices: dict[Any, str] | list[Any]) -> dict:
    """One value from a fixed set. `choices` maps each value to what it means
    (or is a bare list of values). Give it an "other" when the set isn't
    exhaustive, or the nearest wrong answer gets the probability."""
    if isinstance(choices, dict):
        options = [
            {"value": value, "description": description} if description else {"value": value}
            for value, description in choices.items()
        ]
    else:
        options = [{"value": value} for value in choices]
    return {"type": "choice", "name": name, "instructions": instructions, "choices": options}


def score(name: str, instructions: str, levels: dict[str, str] | list[str]) -> dict:
    """A place on a rubric. `levels` run lowest to highest, each a label and,
    in the dict form, what earns it."""
    if isinstance(levels, dict):
        rungs = [
            {"label": label, "description": description} if description else {"label": label}
            for label, description in levels.items()
        ]
    else:
        rungs = [{"label": label} for label in levels]
    return {"type": "score", "name": name, "instructions": instructions, "levels": rungs}


# ---------------------------------------------------------------------------
# Answers
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Answer:
    """One question's answer.

    `probability` is what a threshold is compared against: for a predicate,
    how likely the statement is true; for a choice, the chosen value's own
    probability; for a score, the top level's. `value` is the chosen value, or
    for a score its level index averaged by probability (so 1.1 sits just
    above the second of three levels); `fraction` puts that on 0...1.
    """

    name: str
    type: str
    probability: float = 0.0
    value: Any = None
    label: str | None = None
    confidence: float | None = None
    probabilities: dict[Any, float] = field(default_factory=dict)
    levels: int = 0

    @property
    def refused(self) -> bool:
        return self.type == "refusal"

    @property
    def fraction(self) -> float:
        """A score as a share of the way up its rubric: 0 lowest, 1 highest."""
        if self.type != "score" or self.levels < 2 or self.value is None:
            return 0.0
        return max(0.0, min(1.0, float(self.value) / (self.levels - 1)))


@dataclass(frozen=True)
class Decision:
    answers: dict[str, Answer]
    model: str = ""
    input_tokens: int = 0
    cached_tokens: int = 0
    seconds: float = 0.0

    def get(self, name: str) -> Answer | None:
        answer = self.answers.get(name)
        return None if answer is None or answer.refused else answer

    def probability(self, name: str, default: float = 0.0) -> float:
        answer = self.get(name)
        return default if answer is None else answer.probability

    def value(self, name: str, default: Any = None) -> Any:
        answer = self.get(name)
        return default if answer is None or answer.value is None else answer.value


def _number(raw: Any) -> float:
    try:
        return float(raw)
    except (TypeError, ValueError):
        return 0.0


def parse_answer(raw: dict, index: int, question: dict | None = None) -> Answer:
    """One item of the reply's `answers`, in this module's shape."""
    kind = str(raw.get("type") or "")
    name = raw.get("name") or (question or {}).get("name") or f"q{index}"
    if kind == "predicate":
        return Answer(name=name, type=kind, probability=_number(raw.get("probability")))
    spread = raw.get("probabilities") or []
    confidence = raw.get("confidence")
    confidence = None if confidence is None else _number(confidence)
    if kind == "choice":
        chosen = raw.get("choice")
        probabilities = {row.get("value"): _number(row.get("probability")) for row in spread}
        return Answer(
            name=name,
            type=kind,
            probability=probabilities.get(chosen, 0.0),
            value=chosen,
            confidence=confidence,
            probabilities=probabilities,
        )
    if kind == "score":
        probabilities = {row.get("value"): _number(row.get("probability")) for row in spread}
        labels = {row.get("value"): row.get("label") for row in spread}
        top = max(probabilities, key=probabilities.get) if probabilities else None
        return Answer(
            name=name,
            type=kind,
            probability=probabilities.get(top, 0.0),
            value=_number(raw.get("score")),
            label=labels.get(top),
            confidence=confidence,
            probabilities=probabilities,
            levels=len(spread) or len((question or {}).get("levels") or []),
        )
    return Answer(name=name, type="refusal")


def parse(raw: Any, questions: list[dict], seconds: float = 0.0) -> Decision:
    if not isinstance(raw, dict) or not isinstance(raw.get("answers"), list):
        raise DecisionError("decisions reply had no answers")
    answers: dict[str, Answer] = {}
    for index, item in enumerate(raw["answers"]):
        if not isinstance(item, dict):
            continue
        question = questions[index] if index < len(questions) else None
        answer = parse_answer(item, index, question)
        answers[answer.name] = answer
    usage = raw.get("usage") or {}
    details = usage.get("input_tokens_details") or {}
    return Decision(
        answers=answers,
        model=str(raw.get("model") or ""),
        input_tokens=int(usage.get("input_tokens") or 0),
        cached_tokens=int(details.get("cached_tokens") or 0),
        seconds=seconds,
    )


# ---------------------------------------------------------------------------
# The call
# ---------------------------------------------------------------------------


def json_part(data: dict | list) -> dict:
    """A JSON content part for a user message in `input`."""
    return {"type": "input_json", "data": data}


async def decide(
    client: Any,
    *,
    input: Any,
    questions: list[dict],
    prompt_cache_key: str,
    surface: str = "app",
    timeout: float = DEFAULT_TIMEOUT_SECONDS,  # noqa: ASYNC109 (passed to the SDK, which owns the wait)
) -> Decision:
    """Ask `questions` of `input`. Raises `DecisionError` on any failure.

    `surface` names the caller in the log line, the way `metadata.service`
    does for a Responses call (Decisions takes no metadata of its own).
    """
    if not questions or len(questions) > MAX_QUESTIONS:
        raise DecisionError(f"decisions takes 1 to {MAX_QUESTIONS} questions, got {len(questions)}")
    body = {
        "model": settings.ai_model,
        "input": input,
        "questions": questions,
        "prompt_cache_key": prompt_cache_key,
    }
    started = time.perf_counter()
    try:
        # `cast_to=httpx.Response` is the SDK's "hand me the reply as it came".
        reply = await client.post(PATH, body=body, cast_to=httpx.Response, options={"timeout": timeout})
        raw = reply.json()
    except Exception as error:
        raise DecisionError(f"decisions call failed: {type(error).__name__}: {error}") from error
    seconds = time.perf_counter() - started
    decision = parse(raw, questions, seconds)
    logger.info(
        "[DECIDE] %s: %d questions, %d tokens (%d cached), %.2fs",
        surface,
        len(questions),
        decision.input_tokens,
        decision.cached_tokens,
        seconds,
    )
    return decision
