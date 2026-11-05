"""Runs the nightly sweep from inside the API process, so there's no separate cron service to keep.

Every 15 minutes it checks whether SF's last good sweep is older than 20 hours and it's past 4 AM there
(or older than 30 hours, whatever the time). A Postgres advisory lock keeps two replicas from sweeping
at once. A fresh deploy with an empty catalog sweeps within a minute.
"""

import asyncio
import logging
from datetime import timedelta

import httpx
from sqlalchemy import select, text

from app.catalog import cells
from app.catalog.geocode import CityGeocoder
from app.catalog.sweep import sweep
from app.catalog.tables import SweepLog
from app.db import SessionLocal, engine
from app.views import now

log = logging.getLogger("letsgo.scheduler")

LOCK = 4_242_001
CITIES = ("sf",)
EVERY = timedelta(minutes=15)


async def due(city: str) -> bool:
    async with SessionLocal() as session:
        last = await session.scalar(
            select(SweepLog.started_at)
            .where(SweepLog.city == city, SweepLog.ok.is_(True))
            .order_by(SweepLog.started_at.desc())
            .limit(1)
        )
    at = now()
    if last is None:
        return True
    age = at - last
    return age > timedelta(hours=30) or (
        age > timedelta(hours=20) and at.astimezone(cells.tz(city)).hour >= 4
    )


async def tick() -> None:
    async with engine.connect() as lock_conn:
        got = await lock_conn.scalar(text("select pg_try_advisory_lock(:k)"), {"k": LOCK})
        if not got:
            return
        try:
            for city in CITIES:
                if await due(city):
                    log.info("sweeping %s", city)
                    async with httpx.AsyncClient(follow_redirects=True) as client, SessionLocal() as session:
                        await sweep(session, city, client, CityGeocoder(client), now())
        finally:
            await lock_conn.scalar(text("select pg_advisory_unlock(:k)"), {"k": LOCK})


async def run_forever() -> None:
    await asyncio.sleep(30)
    while True:
        try:
            await tick()
        except Exception:  # the loop must outlive one bad night
            log.exception("scheduled sweep failed")
        await asyncio.sleep(EVERY.total_seconds())
