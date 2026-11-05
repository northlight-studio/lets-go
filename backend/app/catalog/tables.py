"""The city catalog: one row per real event, wherever it was found, shared by everyone.

Feeds fill it every night (`app.catalog.sweep`); the scout fills gaps when someone asks for something
nobody has asked about nearby lately (`app.catalog.scout`). Nothing here names who asked: the only
person-linked tables are `finds` (what your asks put on the map, seen only by you) and `scout_quota`
(a counter, so one person can't run up the bill).
"""

import uuid
from datetime import date, datetime

from sqlalchemy import (
    ARRAY,
    Boolean,
    Date,
    DateTime,
    Float,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
    func,
)
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base


def _uuid() -> Mapped[uuid.UUID]:
    return mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)


def _created() -> Mapped[datetime]:
    return mapped_column(DateTime(timezone=True), server_default=func.now(), nullable=False)


class Venue(Base):
    """A place things happen. Geocoded once, then every event there reuses it."""

    __tablename__ = "venues"
    id: Mapped[uuid.UUID] = _uuid()
    city: Mapped[str] = mapped_column(String(16), nullable=False)
    # city|normalized name (or address when there's no name): what feeds and the scout match on.
    key: Mapped[str] = mapped_column(String(300), nullable=False, unique=True)
    name: Mapped[str] = mapped_column(String(160), nullable=False)
    address: Mapped[str] = mapped_column(String(240), nullable=False, default="")
    lat: Mapped[float | None] = mapped_column(Float)
    lon: Mapped[float | None] = mapped_column(Float)
    # pending → not tried yet; ok → has a point; failed → tried, nothing found (retried after a week).
    geocode: Mapped[str] = mapped_column(String(8), nullable=False, default="pending")
    geocoded_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = _created()


class Event(Base):
    """One occurrence of something real: a show on Friday at 9, a truck at its curb on Saturday."""

    __tablename__ = "events"
    __table_args__ = (Index("ix_events_city_starts_at", "city", "starts_at"),)
    id: Mapped[uuid.UUID] = _uuid()
    city: Mapped[str] = mapped_column(String(16), nullable=False)
    title: Mapped[str] = mapped_column(String(200), nullable=False)
    # Lowercased, punctuation and "(SF)"-style noise removed: what the resolver compares.
    title_key: Mapped[str] = mapped_column(String(200), nullable=False)
    venue_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("venues.id", ondelete="SET NULL"), index=True
    )
    venue_name: Mapped[str] = mapped_column(String(160), nullable=False, default="")
    address: Mapped[str] = mapped_column(String(240), nullable=False, default="")
    lat: Mapped[float | None] = mapped_column(Float)
    lon: Mapped[float | None] = mapped_column(Float)
    # H3 cells: `area` (resolution 7, about 5 km²) is what coverage is kept by.
    area: Mapped[str | None] = mapped_column(String(16), index=True)
    starts_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    ends_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    # The city-local night it belongs to (6 AM to 4 AM the next morning).
    day: Mapped[date] = mapped_column(Date, nullable=False, index=True)
    genre: Mapped[str] = mapped_column(String(16), nullable=False)
    tags: Mapped[list[str]] = mapped_column(ARRAY(String(24)), nullable=False, default=list)
    price_min_cents: Mapped[int | None] = mapped_column(Integer)
    price_text: Mapped[str] = mapped_column(String(120), nullable=False, default="")
    ages: Mapped[str] = mapped_column(String(16), nullable=False, default="")
    description: Mapped[str] = mapped_column(Text, nullable=False, default="")
    url: Mapped[str] = mapped_column(String(500), nullable=False, default="")
    # Wren's one shared line about it. The personal line is written on the phone.
    why: Mapped[str | None] = mapped_column(String(280))
    # on | canceled | sold_out | gone (no longer listed by any source that had it)
    status: Mapped[str] = mapped_column(String(12), nullable=False, default="on")
    # The scout run that first put it in the catalog, if one did.
    found_by_run: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("scout_runs.id", ondelete="SET NULL"))
    first_seen_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    last_seen_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    created_at: Mapped[datetime] = _created()


class EventSource(Base):
    """Where an event was seen. Three sites listing the same show are three rows, one event."""

    __tablename__ = "event_sources"
    __table_args__ = (UniqueConstraint("source", "ref", name="event_sources_source_ref"),)
    id: Mapped[uuid.UUID] = _uuid()
    event_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("events.id", ondelete="CASCADE"), nullable=False, index=True
    )
    # funcheap | 19hz | datasf | scout | manual
    source: Mapped[str] = mapped_column(String(24), nullable=False)
    # Stable within the source: its URL, or day|title|venue when it has none.
    ref: Mapped[str] = mapped_column(String(500), nullable=False)
    url: Mapped[str] = mapped_column(String(500), nullable=False, default="")
    seen_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class ScoutRun(Base):
    """One search for one kind of thing, in one area, for one night. Never says who asked."""

    __tablename__ = "scout_runs"
    id: Mapped[uuid.UUID] = _uuid()
    city: Mapped[str] = mapped_column(String(16), nullable=False)
    area: Mapped[str] = mapped_column(String(16), nullable=False)
    intent: Mapped[str] = mapped_column(String(24), nullable=False)
    day: Mapped[date] = mapped_column(Date, nullable=False)
    # running | done | failed
    status: Mapped[str] = mapped_column(String(8), nullable=False, default="running")
    searches: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    tokens_in: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    tokens_out: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    cache_read: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    # Millionths of a dollar, at list prices.
    cost_micros: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    proposed: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    added: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    merged: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    note: Mapped[str] = mapped_column(String(400), nullable=False, default="")
    started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    finished_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class Coverage(Base):
    """What's been looked for, where, for which night, and until when that's good enough. A row
    that's `running` is also the claim on its run: a second ask joins it instead of starting another."""

    __tablename__ = "coverage"
    city: Mapped[str] = mapped_column(String(16), primary_key=True)
    area: Mapped[str] = mapped_column(String(16), primary_key=True)
    intent: Mapped[str] = mapped_column(String(24), primary_key=True)
    day: Mapped[date] = mapped_column(Date, primary_key=True)
    # running | covered
    state: Mapped[str] = mapped_column(String(8), nullable=False)
    # sweep | scout
    by: Mapped[str] = mapped_column(String(8), nullable=False)
    run_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True))
    claimed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    fresh_until: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    found: Mapped[int] = mapped_column(Integer, nullable=False, default=0)


class Find(Base):
    """Something your ask put on the map first. Only you ever see this."""

    __tablename__ = "finds"
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    event_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("events.id", ondelete="CASCADE"), primary_key=True)
    created_at: Mapped[datetime] = _created()


class ScoutQuota(Base):
    """How many scout runs a person started in an hour. A counter, not a log of what they asked."""

    __tablename__ = "scout_quota"
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    hour: Mapped[datetime] = mapped_column(DateTime(timezone=True), primary_key=True)
    runs: Mapped[int] = mapped_column(Integer, nullable=False, default=0)


class SweepLog(Base):
    """One nightly sweep: when, and what each feed brought. The scheduler reads the last one."""

    __tablename__ = "sweep_log"
    id: Mapped[uuid.UUID] = _uuid()
    city: Mapped[str] = mapped_column(String(16), nullable=False, index=True)
    started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    finished_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    ok: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    # {"funcheap": {"seen": 120, "added": 30, ...}, ...}
    summary: Mapped[str] = mapped_column(Text, nullable=False, default="")
