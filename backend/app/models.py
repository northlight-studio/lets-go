"""Tables. Schema changes go through Alembic (backend/alembic), never create_all in the app."""

import uuid
from datetime import datetime

from sqlalchemy import (
    ARRAY,
    Boolean,
    CheckConstraint,
    DateTime,
    Float,
    ForeignKey,
    Integer,
    String,
    Text,
    UniqueConstraint,
    func,
)
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db import Base

GENRES = ("play", "move", "music", "party", "food")


def _uuid() -> Mapped[uuid.UUID]:
    return mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)


def _created() -> Mapped[datetime]:
    return mapped_column(DateTime(timezone=True), server_default=func.now(), nullable=False)


class User(Base):
    __tablename__ = "users"
    id: Mapped[uuid.UUID] = _uuid()
    display_name: Mapped[str] = mapped_column(String(60), nullable=False)
    token_hash: Mapped[str] = mapped_column(String(64), nullable=False, unique=True)
    created_at: Mapped[datetime] = _created()


class Gathering(Base):
    __tablename__ = "gatherings"
    __table_args__ = (
        CheckConstraint("ends_at > starts_at", name="gathering_ends_after_start"),
        CheckConstraint("capacity >= 0", name="gathering_capacity_nonnegative"),
    )
    id: Mapped[uuid.UUID] = _uuid()
    host_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    title: Mapped[str] = mapped_column(String(120), nullable=False)
    genre: Mapped[str] = mapped_column(String(16), nullable=False)
    details: Mapped[str] = mapped_column(Text, nullable=False, default="")
    place_name: Mapped[str] = mapped_column(String(120), nullable=False)
    lat: Mapped[float] = mapped_column(Float, nullable=False, index=True)
    lon: Mapped[float] = mapped_column(Float, nullable=False, index=True)
    starts_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, index=True)
    ends_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, index=True)
    # 0 means open, no cap.
    capacity: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    bring: Mapped[str] = mapped_column(String(200), nullable=False, default="")
    recurring: Mapped[str] = mapped_column(String(60), nullable=False, default="")
    cancelled_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = _created()

    host: Mapped[User] = relationship(lazy="joined", innerjoin=True)
    members: Mapped[list["GatheringMember"]] = relationship(
        back_populates="gathering", cascade="all, delete-orphan", lazy="selectin"
    )
    # People who said they're in from a poster's web page, without the app. Only the ones still in.
    web_guests: Mapped[list["WebGuest"]] = relationship(
        primaryjoin="and_(Gathering.id == WebGuest.gathering_id, WebGuest.left_at.is_(None))",
        viewonly=True,
        lazy="selectin",
        order_by="WebGuest.created_at",
    )

    @property
    def going(self) -> int:
        """Everyone in: app members plus web guests. What capacity is checked against."""
        return len(self.members) + len(self.web_guests)


class GatheringMember(Base):
    __tablename__ = "gathering_members"
    gathering_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("gatherings.id", ondelete="CASCADE"), primary_key=True
    )
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    joined_at: Mapped[datetime] = _created()
    checked_in_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    gathering: Mapped[Gathering] = relationship(back_populates="members")
    user: Mapped[User] = relationship(lazy="joined", innerjoin=True)


class Kitchen(Base):
    __tablename__ = "kitchens"
    id: Mapped[uuid.UUID] = _uuid()
    owner_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, unique=True
    )
    name: Mapped[str] = mapped_column(String(80), nullable=False)
    cuisine: Mapped[str] = mapped_column(String(60), nullable=False)
    story: Mapped[str] = mapped_column(Text, nullable=False, default="")
    lat: Mapped[float] = mapped_column(Float, nullable=False, index=True)
    lon: Mapped[float] = mapped_column(Float, nullable=False, index=True)
    # Only shown to the owner and to people with an order.
    pickup_note: Mapped[str] = mapped_column(String(300), nullable=False, default="")
    porch_tables: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    permit_confirmed: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    handler_card_confirmed: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    created_at: Mapped[datetime] = _created()

    owner: Mapped[User] = relationship(lazy="joined", innerjoin=True)
    menu: Mapped[list["MenuItem"]] = relationship(
        back_populates="kitchen",
        cascade="all, delete-orphan",
        lazy="selectin",
        order_by="MenuItem.sort_index",
    )
    drops: Mapped[list["Drop"]] = relationship(
        back_populates="kitchen", cascade="all, delete-orphan", lazy="selectin", order_by="Drop.starts_at"
    )


class MenuItem(Base):
    __tablename__ = "menu_items"
    __table_args__ = (CheckConstraint("price_cents > 0", name="menu_price_positive"),)
    id: Mapped[uuid.UUID] = _uuid()
    kitchen_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("kitchens.id", ondelete="CASCADE"), nullable=False
    )
    name: Mapped[str] = mapped_column(String(80), nullable=False)
    note: Mapped[str] = mapped_column(String(160), nullable=False, default="")
    price_cents: Mapped[int] = mapped_column(Integer, nullable=False)
    sort_index: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    # Removed items stay for old orders but leave the menu.
    active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)

    kitchen: Mapped[Kitchen] = relationship(back_populates="menu")


class Drop(Base):
    """A fixed batch at a set time."""

    __tablename__ = "drops"
    __table_args__ = (
        CheckConstraint("ends_at > starts_at", name="drop_ends_after_start"),
        CheckConstraint("sold >= 0 AND sold <= total", name="drop_sold_within_total"),
        CheckConstraint("per_slot > 0", name="drop_per_slot_positive"),
    )
    id: Mapped[uuid.UUID] = _uuid()
    kitchen_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("kitchens.id", ondelete="CASCADE"), nullable=False
    )
    starts_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    ends_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, index=True)
    total: Mapped[int] = mapped_column(Integer, nullable=False)
    sold: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    per_slot: Mapped[int] = mapped_column(Integer, nullable=False, default=4)

    kitchen: Mapped[Kitchen] = relationship(back_populates="drops")


class Order(Base):
    __tablename__ = "orders"
    __table_args__ = (UniqueConstraint("buyer_id", "client_id", name="orders_buyer_client_unique"),)
    id: Mapped[uuid.UUID] = _uuid()
    # Generated on the phone, so a retried request can't create a second order.
    client_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)
    buyer_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    kitchen_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("kitchens.id", ondelete="CASCADE"), nullable=False
    )
    drop_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("drops.id", ondelete="CASCADE"), nullable=False)
    pickup_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    eat_on_porch: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    # reserved → picked_up → reviewed
    status: Mapped[str] = mapped_column(String(16), nullable=False, default="reserved")
    subtotal_cents: Mapped[int] = mapped_column(Integer, nullable=False)
    service_cents: Mapped[int] = mapped_column(Integer, nullable=False)
    created_at: Mapped[datetime] = _created()

    kitchen: Mapped[Kitchen] = relationship(lazy="joined", innerjoin=True)
    lines: Mapped[list["OrderLine"]] = relationship(cascade="all, delete-orphan", lazy="selectin")


class OrderLine(Base):
    __tablename__ = "order_lines"
    __table_args__ = (CheckConstraint("quantity > 0", name="order_line_quantity_positive"),)
    id: Mapped[uuid.UUID] = _uuid()
    order_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("orders.id", ondelete="CASCADE"), nullable=False)
    menu_item_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("menu_items.id"), nullable=False)
    # Copied at order time so a later price change doesn't rewrite history.
    name: Mapped[str] = mapped_column(String(80), nullable=False)
    price_cents: Mapped[int] = mapped_column(Integer, nullable=False)
    quantity: Mapped[int] = mapped_column(Integer, nullable=False)


class Review(Base):
    __tablename__ = "reviews"
    __table_args__ = (CheckConstraint("stars BETWEEN 1 AND 5", name="review_stars_range"),)
    id: Mapped[uuid.UUID] = _uuid()
    kitchen_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("kitchens.id", ondelete="CASCADE"), nullable=False, index=True
    )
    order_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("orders.id", ondelete="CASCADE"), unique=True)
    author_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    stars: Mapped[int] = mapped_column(Integer, nullable=False)
    tags: Mapped[list[str]] = mapped_column(ARRAY(String(40)), nullable=False, default=list)
    text: Mapped[str] = mapped_column(Text, nullable=False, default="")
    created_at: Mapped[datetime] = _created()

    author: Mapped[User] = relationship(lazy="joined", innerjoin=True)


class Listing(Base):
    """Something real on in a city: a venue's show, a market, a weekly jam. Researched by hand for now;
    the nightly scout will keep these up to date. The phone turns `schedule` into actual dates."""

    __tablename__ = "listings"
    id: Mapped[uuid.UUID] = _uuid()
    # What the scout matches on to update instead of duplicate: city, title and venue, lowercased.
    key: Mapped[str] = mapped_column(String(400), nullable=False, unique=True)
    city: Mapped[str] = mapped_column(String(16), nullable=False, index=True)
    title: Mapped[str] = mapped_column(String(160), nullable=False)
    genre: Mapped[str] = mapped_column(String(16), nullable=False)
    venue: Mapped[str] = mapped_column(String(160), nullable=False)
    address: Mapped[str] = mapped_column(String(200), nullable=False, default="")
    lat: Mapped[float] = mapped_column(Float, nullable=False)
    lon: Mapped[float] = mapped_column(Float, nullable=False)
    # [{"weekday": "Saturday" | "date": "2026-10-24", "start": "20:00", "end": "23:00" | null}]
    schedule: Mapped[list[dict]] = mapped_column(JSONB, nullable=False)
    price: Mapped[str] = mapped_column(String(80), nullable=False, default="")
    organizer: Mapped[str] = mapped_column(String(160), nullable=False, default="")
    url: Mapped[str] = mapped_column(String(500), nullable=False, default="")
    description: Mapped[str] = mapped_column(Text, nullable=False, default="")
    confidence: Mapped[str] = mapped_column(String(8), nullable=False, default="medium")
    # Where it came from: "manual" for hand research, later a scout source like "ticketmaster".
    source: Mapped[str] = mapped_column(String(32), nullable=False, default="manual")
    # live → shown; review → waiting for a person; gone → no longer listed by its source.
    status: Mapped[str] = mapped_column(String(8), nullable=False, default="live")
    last_seen_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    created_at: Mapped[datetime] = _created()


# People: friends, crews, porch lights, and who's invited to what.


class Friendship(Base):
    """One row each way, so "my friends" is a single lookup. Made by accepting a friend code."""

    __tablename__ = "friendships"
    __table_args__ = (CheckConstraint("user_id <> friend_id", name="friendship_not_self"),)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    friend_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    created_at: Mapped[datetime] = _created()

    friend: Mapped[User] = relationship(foreign_keys=[friend_id], lazy="joined", innerjoin=True)


class FriendCode(Base):
    """A one-use code you hand a friend in person or in a message. Accepting it makes you friends."""

    __tablename__ = "friend_codes"
    id: Mapped[uuid.UUID] = _uuid()
    code: Mapped[str] = mapped_column(String(12), nullable=False, unique=True)
    from_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    used_by_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("users.id", ondelete="SET NULL"))
    used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = _created()

    sender: Mapped[User] = relationship(foreign_keys=[from_id], lazy="joined", innerjoin=True)


class PorchLight(Base):
    """ "Up for something" for a couple of hours, seen only by friends. Where is optional."""

    __tablename__ = "porch_lights"
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    on_until: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    note: Mapped[str] = mapped_column(String(80), nullable=False, default="")
    lat: Mapped[float | None] = mapped_column(Float)
    lon: Mapped[float | None] = mapped_column(Float)
    created_at: Mapped[datetime] = _created()


class Wave(Base):
    """A wave at a friend whose porch light is on. They see it for two hours."""

    __tablename__ = "waves"
    id: Mapped[uuid.UUID] = _uuid()
    from_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    to_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    created_at: Mapped[datetime] = _created()


class Crew(Base):
    """A named group of friends you go out with: "Tuesday trivia", "the run lot"."""

    __tablename__ = "crews"
    id: Mapped[uuid.UUID] = _uuid()
    owner_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    name: Mapped[str] = mapped_column(String(40), nullable=False)
    created_at: Mapped[datetime] = _created()

    members: Mapped[list["CrewMember"]] = relationship(cascade="all, delete-orphan", lazy="selectin")


class CrewMember(Base):
    __tablename__ = "crew_members"
    crew_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("crews.id", ondelete="CASCADE"), primary_key=True)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    added_at: Mapped[datetime] = _created()

    user: Mapped[User] = relationship(lazy="joined", innerjoin=True)


class GatheringInvite(Base):
    """A friend asking you along. One per person per gathering."""

    __tablename__ = "gathering_invites"
    gathering_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("gatherings.id", ondelete="CASCADE"), primary_key=True
    )
    to_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    from_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    created_at: Mapped[datetime] = _created()

    sender: Mapped[User] = relationship(foreign_keys=[from_id], lazy="joined", innerjoin=True)


class Intro(Base):
    """Third time's a friend: after three real check-ins at the same things, each of you can say hi.
    Both saying hi makes you friends. One saying hi tells the other nothing."""

    __tablename__ = "intros"
    __table_args__ = (CheckConstraint("user_id <> other_id", name="intro_not_self"),)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    other_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    said_hi_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    declined_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = _created()


# The lamppost poster: a short link per hosted gathering, and the people who say they're in from it.


class Poster(Base):
    """A printed poster's short link. It points at one gathering; for a weekly one it moves on to the
    next week's when the last has ended, so the paper on the lamppost keeps working."""

    __tablename__ = "posters"
    id: Mapped[uuid.UUID] = _uuid()
    # Lowercase, no look-alike characters: typed by hand from a tear-off tab.
    code: Mapped[str] = mapped_column(String(12), nullable=False, unique=True)
    host_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    gathering_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("gatherings.id", ondelete="CASCADE"), nullable=False, unique=True
    )
    # The host's time zone (IANA), so the page shows local time and "every Thursday 6:30" stays 6:30.
    tz: Mapped[str] = mapped_column(String(64), nullable=False)
    views: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    # The host took it down: the page says so and takes no more joins.
    retired_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = _created()

    gathering: Mapped[Gathering] = relationship(lazy="joined", innerjoin=True)


class WebGuest(Base):
    """Someone who said they're in from a poster's page, with no app and no account. Only a first name,
    which only the host sees. Leaving keeps the row (left_at) so rate limits can't be reset by it."""

    __tablename__ = "web_guests"
    id: Mapped[uuid.UUID] = _uuid()
    gathering_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("gatherings.id", ondelete="CASCADE"), nullable=False, index=True
    )
    first_name: Mapped[str] = mapped_column(String(30), nullable=False)
    # A random token in the browser's cookie, hashed: the same browser is one guest, and can leave.
    browser_hash: Mapped[str] = mapped_column(String(64), nullable=False, index=True)
    # Salted hash of the caller's IP, for rate limits. Never the IP itself.
    ip_hash: Mapped[str] = mapped_column(String(64), nullable=False, index=True)
    left_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = _created()


# The city catalog lives in its own module; importing it here registers its tables on Base.metadata.
from app.catalog import tables as _catalog_tables  # noqa: E402, F401
