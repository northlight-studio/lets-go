"""Runs the nightly sweep and the reader from inside the API process, so there's no separate cron
service to keep.

Every 15 minutes it checks whether SF's last good sweep is older than 20 hours and it's past 4 AM there
(or older than 30 hours, whatever the time), and the same for the reader's last night. Feeds first, then
the source list is topped up from the seed and read, then the source finder takes its share of the
grid. In between, once an hour, the sources of everything starting in the next six hours are read again.
A Postgres advisory lock keeps two replicas from doing any of it at once. A fresh deploy with an empty
catalog sweeps and reads within a minute.
"""

import asyncio
import logging
from datetime import timedelta

import httpx
from openai import AsyncOpenAI
from sqlalchemy import select, text

from app.catalog import cells
from app.catalog.geocode import CityGeocoder
from app.catalog.sources.fetch import Fetcher
from app.catalog.sources.finder import OpenAIFinder, find_sources
from app.catalog.sources.model import OpenAIPageModel
from app.catalog.sources.night import read_sources, recheck_soon, record_feeds
from app.catalog.sources.seed import load_seed
from app.catalog.sweep import sweep
from app.catalog.tables import ReaderNight, SweepLog
from app.config import settings
from app.db import SessionLocal, engine
from app.poster_roll import roll_due
from app.views import now

log = logging.getLogger("letsgo.scheduler")

LOCK = 4_242_001
CITIES = ("sf",)
EVERY = timedelta(minutes=15)
RECHECK = timedelta(minutes=55)


def nightly_due(city: str, last, at) -> bool:
    if last is None:
        return True
    age = at - last
    return age > timedelta(hours=30) or (
        age > timedelta(hours=20) and at.astimezone(cells.tz(city)).hour >= 4
    )


async def due(city: str) -> bool:
    async with SessionLocal() as session:
        last = await session.scalar(
            select(SweepLog.started_at)
            .where(SweepLog.city == city, SweepLog.ok.is_(True))
            .order_by(SweepLog.started_at.desc())
            .limit(1)
        )
    return nightly_due(city, last, now())


async def reader_due(city: str, kind: str = "night") -> bool:
    async with SessionLocal() as session:
        q = select(ReaderNight.started_at).where(ReaderNight.city == city)
        if kind == "night":
            q = q.where(ReaderNight.kind == "night")
        last = await session.scalar(q.order_by(ReaderNight.started_at.desc()).limit(1))
    if kind == "night":
        return nightly_due(city, last, now())
    return last is None or now() - last > RECHECK


def budget_micros() -> int:
    return round(settings.scout_daily_budget_usd * 1_000_000)


def page_model() -> OpenAIPageModel | None:
    if not settings.openai_api_key:
        return None
    return OpenAIPageModel(
        AsyncOpenAI(api_key=settings.openai_api_key), settings.ai_model, settings.reader_reasoning_effort
    )


async def read_city(city: str, client: httpx.AsyncClient) -> None:
    async with SessionLocal() as session:
        added = await load_seed(session, city)
        await session.commit()
        if added:
            log.info("source list: %d new from the seed", added)
        await read_sources(
            session, city, Fetcher(client), CityGeocoder(client), now(),
            model=page_model(), budget_micros=budget_micros(), max_model_pages=settings.reader_model_pages,
        )  # fmt: skip
        if settings.finder_enabled and settings.openai_api_key:
            finder = OpenAIFinder(AsyncOpenAI(api_key=settings.openai_api_key), settings.ai_model)
            found = await find_sources(
                session, city, finder, now(), budget_micros=budget_micros(),
                limit=settings.finder_runs_per_night or None,
            )  # fmt: skip
            log.info("source finder %s: %s", city, found)


async def recheck_city(city: str, client: httpx.AsyncClient) -> None:
    async with SessionLocal() as session:
        await recheck_soon(
            session, city, client, Fetcher(client), CityGeocoder(client), now(),
            model=page_model(), budget_micros=budget_micros(),
        )  # fmt: skip


async def tick() -> None:
    async with engine.connect() as lock_conn:
        got = await lock_conn.scalar(text("select pg_try_advisory_lock(:k)"), {"k": LOCK})
        if not got:
            return
        try:
            try:
                async with SessionLocal() as session:
                    await roll_due(session, now())
            except Exception:  # a poster problem mustn't stop the sweep
                log.exception("rolling weekly posters failed")
            for city in CITIES:
                if await due(city):
                    log.info("sweeping %s", city)
                    async with httpx.AsyncClient(follow_redirects=True) as client, SessionLocal() as session:
                        summary = await sweep(session, city, client, CityGeocoder(client), now())
                        await load_seed(session, city)
                        await record_feeds(session, city, summary, now())
                        await session.commit()
                try:
                    async with httpx.AsyncClient(follow_redirects=True) as client:
                        if await reader_due(city):
                            log.info("reading %s's sources", city)
                            await read_city(city, client)
                        elif await reader_due(city, "recheck"):
                            await recheck_city(city, client)
                except Exception:  # the reader mustn't stop the next city's sweep
                    log.exception("reading %s failed", city)
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
