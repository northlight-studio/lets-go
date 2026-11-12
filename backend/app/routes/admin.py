"""Admin-only reads: how the city's sources are doing. Behind `X-Admin-Token` (the `ADMIN_TOKEN`
setting); with no token set, these routes don't exist."""

import secrets

from fastapi import APIRouter, Depends, Header, HTTPException, Query, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.catalog.sources.report import report
from app.config import settings
from app.db import get_session
from app.views import now

router = APIRouter(prefix="/v1/admin", tags=["admin"], include_in_schema=False)


def admin(x_admin_token: str | None = Header(default=None)) -> None:
    if not settings.admin_token:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Not Found")
    if not x_admin_token or not secrets.compare_digest(x_admin_token, settings.admin_token):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Admin only")


@router.get("/sources", dependencies=[Depends(admin)])
async def sources(
    city: str = Query(default="sf", max_length=16), session: AsyncSession = Depends(get_session)
) -> dict:
    """Source health (counts, and every source that's moved, broken, empty or blocked) and the last
    night's numbers: sources read and changed, events new, updated and canceled, and what it cost."""
    return await report(session, city, now())
