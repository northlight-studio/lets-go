"""Source health and last night's numbers, for `/v1/admin/sources` and the command line. Nothing in it
says who asked for anything: it's about pages and counts."""

import json
from datetime import datetime, timedelta

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.catalog.sources.night import spent_today
from app.catalog.tables import ReaderNight, ScoutRun, Source, SweepLog

TROUBLE = ("moved", "broken", "empty", "blocked")


def _night(row: ReaderNight | None) -> dict | None:
    if row is None:
        return None
    return {
        "kind": row.kind,
        "started_at": row.started_at.isoformat(),
        "finished_at": row.finished_at.isoformat() if row.finished_at else None,
        "sources": row.sources,
        "read": row.read,
        "changed": row.changed,
        "unchanged": row.unchanged,
        "failed": row.failed,
        "blocked": row.blocked,
        "by_model": row.by_model,
        "deferred": row.deferred,
        "events_seen": row.events_seen,
        "events_new": row.added,
        "events_updated": row.updated,
        "events_canceled": row.canceled,
        "events_gone": row.gone,
        "cost_usd": round(row.cost_micros / 1_000_000, 4),
        "note": row.note,
    }


async def report(session: AsyncSession, city: str, now: datetime) -> dict:
    def counts(column):
        return (
            select(column, func.count())
            .where(Source.city == city, Source.active.is_(True))
            .group_by(column)
            .order_by(column)
        )

    by_health = dict((await session.execute(counts(Source.health))).all())
    by_reader = dict((await session.execute(counts(Source.reader))).all())
    by_added = dict((await session.execute(counts(Source.added_by))).all())
    by_kind = dict((await session.execute(counts(Source.kind))).all())
    trouble = await session.scalars(
        select(Source)
        .where(Source.city == city, Source.active.is_(True), Source.health.in_(TROUBLE))
        .order_by(Source.health, Source.host)
    )
    last_night = await session.scalar(
        select(ReaderNight)
        .where(ReaderNight.city == city, ReaderNight.kind == "night")
        .order_by(ReaderNight.started_at.desc())
        .limit(1)
    )
    last_recheck = await session.scalar(
        select(ReaderNight)
        .where(ReaderNight.city == city, ReaderNight.kind == "recheck")
        .order_by(ReaderNight.started_at.desc())
        .limit(1)
    )
    sweep = await session.scalar(
        select(SweepLog).where(SweepLog.city == city).order_by(SweepLog.started_at.desc()).limit(1)
    )
    week = now - timedelta(days=7)
    finder = (
        await session.execute(
            select(
                func.count(),
                func.coalesce(func.sum(ScoutRun.added), 0),
                func.coalesce(func.sum(ScoutRun.cost_micros), 0),
            ).where(ScoutRun.city == city, ScoutRun.intent.like("src:%"), ScoutRun.started_at >= week)
        )
    ).one()
    return {
        "city": city,
        "sources": sum(by_health.values()),
        "health": by_health,
        "reader": by_reader,
        "added_by": by_added,
        "kind": by_kind,
        "trouble": [
            {
                "url": s.url,
                "name": s.name,
                "health": s.health,
                "note": s.health_note,
                "moved_to": s.moved_to,
                "last_fetched_at": s.last_fetched_at.isoformat() if s.last_fetched_at else None,
                "last_status": s.last_status,
            }
            for s in trouble
        ],
        "last_night": _night(last_night),
        "last_recheck": _night(last_recheck),
        "last_sweep": json.loads(sweep.summary) if sweep and sweep.summary else None,
        "finder_last_7_days": {
            "searches": finder[0],
            "sources_added": int(finder[1]),
            "cost_usd": round(int(finder[2]) / 1_000_000, 4),
        },
        "ai_spend_today_usd": round(await spent_today(session, city, now) / 1_000_000, 4),
    }
