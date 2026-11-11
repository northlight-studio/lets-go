"""The lamppost poster: the host makes a short link for a gathering they run, and anyone who scans it
gets a page where they can say they're in with only a first name. No app, no account."""

import secrets
import uuid
from datetime import timedelta
from urllib.parse import parse_qs

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from fastapi.responses import HTMLResponse, RedirectResponse
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app import poster as P
from app.auth import current_user
from app.config import settings
from app.db import get_session
from app.models import Gathering, Poster, User, WebGuest
from app.poster_page import PageState, not_found, render
from app.poster_roll import needs_roll, roll_forward
from app.schemas import PosterCreate, PosterOut
from app.views import now

router = APIRouter(tags=["posters"])

COOKIE = "lg_b"


def poster_out(p: Poster) -> PosterOut:
    url, short = P.short_link(p.code)
    return PosterOut(
        code=p.code,
        url=url,
        short_text=short,
        gathering_id=p.gathering_id,
        views=p.views,
        web_going=len(p.gathering.web_guests),
    )


# The host's side, from the app.


@router.post("/v1/gatherings/{gathering_id}/poster", response_model=PosterOut)
async def make_poster(
    gathering_id: uuid.UUID,
    body: PosterCreate,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> PosterOut:
    """One poster per gathering you host; asking again returns the same link."""
    if not P.valid_tz(body.tz):
        raise HTTPException(422, "Unknown time zone")
    g = await session.get(Gathering, gathering_id)
    if g is None or g.cancelled_at is not None:
        raise HTTPException(404, "Gathering not found")
    if g.host_id != user.id:
        raise HTTPException(403, "Only the host can make its poster")
    if g.ends_at <= now():
        raise HTTPException(409, "It's over")
    p = await session.scalar(select(Poster).where(Poster.gathering_id == g.id))
    if p is None:
        for _ in range(5):
            p = Poster(code=P.new_code(), host_id=user.id, gathering_id=g.id, tz=body.tz)
            session.add(p)
            try:
                await session.commit()
                break
            except IntegrityError:
                # A code collision, or the same request twice at once.
                await session.rollback()
                p = await session.scalar(select(Poster).where(Poster.gathering_id == g.id))
                if p is not None:
                    break
        else:
            raise HTTPException(503, "Couldn't make a code; try again")
    else:
        p.tz = body.tz
        p.retired_at = None
        await session.commit()
    p = await session.scalar(select(Poster).where(Poster.id == p.id))
    await session.refresh(p.gathering, ["web_guests"])
    return poster_out(p)


@router.delete("/v1/posters/{code}", status_code=204)
async def retire_poster(
    code: str, user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> Response:
    """Take the poster down: its page says so and takes no more joins."""
    p = await session.scalar(select(Poster).where(Poster.code == P.normalize_code(code)))
    if p is None:
        raise HTTPException(404, "Poster not found")
    if p.host_id != user.id:
        raise HTTPException(403, "Only the host can take it down")
    if p.retired_at is None:
        p.retired_at = now()
        await session.commit()
    return Response(status_code=204)


# The public side: the page the QR code opens.


async def _resolve(session: AsyncSession, code: str) -> Poster | None:
    """The poster and its current gathering. A weekly one whose last time has ended moves on to next
    week's, a fresh gathering with only the host in, so the same paper keeps working."""
    p = await session.scalar(select(Poster).where(Poster.code == P.normalize_code(code)))
    if p is None:
        return None
    if needs_roll(p, now()):
        await roll_forward(session, p.id, now())
        p = await session.scalar(
            select(Poster).where(Poster.id == p.id).execution_options(populate_existing=True)
        )
    await session.refresh(p.gathering, ["members", "web_guests"])
    return p


def _browser(request: Request) -> str | None:
    token = request.cookies.get(COOKIE)
    return token if token and 16 <= len(token) <= 64 else None


async def _mine(session: AsyncSession, gathering_id: uuid.UUID, token: str | None) -> WebGuest | None:
    if token is None:
        return None
    return await session.scalar(
        select(WebGuest).where(
            WebGuest.gathering_id == gathering_id,
            WebGuest.browser_hash == P.browser_hash(token),
            WebGuest.left_at.is_(None),
        )
    )


def _back(code: str, message: str, token: str | None = None) -> RedirectResponse:
    r = RedirectResponse(f"/p/{code}?m={message}", status_code=303)
    if token:
        r.set_cookie(
            COOKIE,
            token,
            max_age=60 * 60 * 24 * 365,
            path="/p",
            httponly=True,
            secure=settings.public_base_url.startswith("https://"),
            samesite="lax",
        )
    return r


@router.get("/p/{code}", response_class=HTMLResponse, include_in_schema=False)
async def poster_page(
    code: str, request: Request, m: str | None = None, session: AsyncSession = Depends(get_session)
) -> HTMLResponse:
    p = await _resolve(session, code)
    headers = {"Cache-Control": "no-store"}
    if p is None:
        return HTMLResponse(not_found(), status_code=404, headers=headers)
    g = p.gathering
    me = await _mine(session, g.id, _browser(request))
    p.views += 1
    await session.commit()
    t = now()
    page = render(
        PageState(
            code=p.code,
            gathering=g,
            tz=p.tz,
            weekly=P.is_weekly(g.recurring),
            retired=p.retired_at is not None,
            ended=g.ends_at <= t,
            my_name=me.first_name if me else None,
            message=m,
            now=t,
        )
    )
    return HTMLResponse(page, headers=headers)


async def _form(request: Request) -> dict[str, str]:
    body = (await request.body())[:4096].decode("utf-8", errors="replace")
    return {k: v[0] for k, v in parse_qs(body).items()}


@router.post("/p/{code}/in", include_in_schema=False)
async def poster_join(
    code: str, request: Request, session: AsyncSession = Depends(get_session)
) -> RedirectResponse:
    """Say you're in from the web. One per browser; a share of the spots at most; a few per network."""
    p = await _resolve(session, code)
    if p is None:
        return _back(P.normalize_code(code), "off")
    code = p.code
    form = await _form(request)
    # Bots fill every field; people never see this one.
    if form.get("website"):
        return _back(code, "in")
    name = P.clean_first_name(form.get("first_name", ""))
    if name is None:
        return _back(code, "name")

    # Lock the gathering so the last spot can't go twice, then count again under the lock.
    g = await session.scalar(
        select(Gathering)
        .where(Gathering.id == p.gathering_id)
        .with_for_update(of=Gathering)
        .execution_options(populate_existing=True)
    )
    await session.refresh(g, ["members", "web_guests"])
    t = now()
    if p.retired_at is not None or g.cancelled_at is not None:
        return _back(code, "off")
    if g.ends_at <= t:
        return _back(code, "over")

    token = _browser(request)
    if await _mine(session, g.id, token) is not None:
        return _back(code, "in")

    ip = P.ip_hash(
        P.client_ip(request.headers.get("x-forwarded-for"), request.client and request.client.host)
    )
    this_hour = await session.scalar(
        select(func.count())
        .select_from(WebGuest)
        .where(WebGuest.ip_hash == ip, WebGuest.created_at > t - timedelta(hours=1))
    )
    here_before = await session.scalar(
        select(func.count())
        .select_from(WebGuest)
        .where(WebGuest.ip_hash == ip, WebGuest.gathering_id == g.id)
    )
    if this_hour >= settings.web_per_ip_per_hour or here_before >= settings.web_per_ip_per_gathering:
        return _back(code, "slow")
    if g.capacity and g.going >= g.capacity:
        return _back(code, "full")
    if len(g.web_guests) >= P.web_limit(g.capacity):
        return _back(code, "webfull")

    token = token or secrets.token_urlsafe(24)
    session.add(WebGuest(gathering_id=g.id, first_name=name, browser_hash=P.browser_hash(token), ip_hash=ip))
    await session.commit()
    return _back(code, "in", token)


@router.post("/p/{code}/out", include_in_schema=False)
async def poster_leave(
    code: str, request: Request, session: AsyncSession = Depends(get_session)
) -> RedirectResponse:
    p = await _resolve(session, code)
    if p is None:
        return _back(P.normalize_code(code), "off")
    me = await _mine(session, p.gathering_id, _browser(request))
    if me is not None:
        me.left_at = now()
        await session.commit()
    return _back(p.code, "out")
