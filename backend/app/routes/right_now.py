"""POST /v1/me/right-now: how well each thing the phone is showing fits this person, for Wren's three
for right now (`app/right_now.py`). Nothing is stored."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends
from openai import AsyncOpenAI
from pydantic import BaseModel, Field, StringConstraints

from app import right_now
from app.auth import current_user
from app.config import settings
from app.models import User

router = APIRouter(prefix="/v1", tags=["right now"])

Short = Annotated[str, StringConstraints(max_length=160)]

_client: AsyncOpenAI | None = None


def get_decider() -> AsyncOpenAI | None:
    """The model client, when there's an OpenAI key. Without one the phone ranks on its own."""
    global _client
    if _client is None and settings.openai_api_key:
        _client = AsyncOpenAI(api_key=settings.openai_api_key, max_retries=0)
    return _client


class ThingIn(BaseModel):
    # The phone's own id for it; it comes back unchanged.
    key: str = Field(min_length=1, max_length=64)
    title: str = Field(min_length=1, max_length=160)
    # gathering · drop (a kitchen's food) · supper
    kind: str = Field(default="", max_length=16)
    genre: str = Field(default="", max_length=16)
    place: str = Field(default="", max_length=120)
    price: str = Field(default="", max_length=60)


class RightNowIn(BaseModel):
    # The phone's own day and time, in words: "Saturday 7:40 PM".
    local_time: str = Field(min_length=1, max_length=40)
    # What the phone has learned they're into: "Into music", "Likes Thai".
    taste: list[Short] = Field(default_factory=list, max_length=30)
    # Titles of things they joined or showed up to, newest first.
    went_to: list[Short] = Field(default_factory=list, max_length=20)
    things: list[ThingIn] = Field(max_length=right_now.MOST)


class FitOut(BaseModel):
    key: str
    # 0 (not for them) to 1 (what they keep choosing).
    fit: float


class RightNowOut(BaseModel):
    # False when nothing was scored (no key, switched off, the read failed): rank without it.
    scored: bool
    fits: list[FitOut]


@router.post("/me/right-now", response_model=RightNowOut)
async def score_right_now(
    body: RightNowIn,
    user: User = Depends(current_user),
    client: AsyncOpenAI | None = Depends(get_decider),
) -> RightNowOut:
    if client is None or not body.things:
        return RightNowOut(scored=False, fits=[])
    scores = await right_now.fits(
        client,
        local_time=body.local_time,
        taste=body.taste,
        went_to=body.went_to,
        things=[right_now.Thing(**t.model_dump()) for t in body.things],
    )
    if scores is None:
        return RightNowOut(scored=False, fits=[])
    return RightNowOut(scored=True, fits=[FitOut(key=k, fit=v) for k, v in scores.items()])
