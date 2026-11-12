import uuid
from datetime import date as date_
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

Genre = Literal["play", "move", "music", "party", "food"]


class Out(BaseModel):
    model_config = ConfigDict(from_attributes=True)


# Users


class UserCreate(BaseModel):
    display_name: str = Field(min_length=1, max_length=60)


class UserOut(Out):
    id: uuid.UUID
    display_name: str


class UserCreated(BaseModel):
    user: UserOut
    token: str


# Gatherings


class GatheringCreate(BaseModel):
    title: str = Field(min_length=1, max_length=120)
    genre: Genre
    details: str = Field(default="", max_length=2000)
    place_name: str = Field(min_length=1, max_length=120)
    lat: float = Field(ge=-90, le=90)
    lon: float = Field(ge=-180, le=180)
    starts_at: datetime
    ends_at: datetime
    capacity: int = Field(default=0, ge=0, le=500)
    bring: str = Field(default="", max_length=200)
    recurring: str = Field(default="", max_length=60)

    @model_validator(mode="after")
    def _ends_after_start(self):
        if self.ends_at <= self.starts_at:
            raise ValueError("It has to end after it starts.")
        if self.genre == "food":
            raise ValueError("Food is sold through home kitchens, not gatherings.")
        return self


class GatheringOut(Out):
    id: uuid.UUID
    title: str
    genre: Genre
    details: str
    place_name: str
    lat: float
    lon: float
    starts_at: datetime
    ends_at: datetime
    capacity: int
    bring: str
    recurring: str
    host_name: str
    # Everyone in, app and web.
    going: int
    # How many of `going` said they're in from a poster's web page.
    web_going: int = 0
    # Their first names: only on the host's copy, empty for everyone else.
    web_names: list[str] = []
    is_mine: bool
    is_joined: bool
    checked_in_at: datetime | None
    distance_m: float | None = None
    # Which of your friends are in. Never anyone else's names.
    friends_going: list["PersonOut"] = []


class PosterCreate(BaseModel):
    # The host's IANA time zone, e.g. "America/Los_Angeles".
    tz: str = Field(min_length=1, max_length=64)


class PosterOut(BaseModel):
    code: str
    # What the QR code encodes.
    url: str
    # The same link without "https://", for the tear-off tabs.
    short_text: str
    gathering_id: uuid.UUID
    views: int
    web_going: int


class CheckIn(BaseModel):
    lat: float = Field(ge=-90, le=90)
    lon: float = Field(ge=-180, le=180)


# Kitchens


class KitchenCreate(BaseModel):
    name: str = Field(min_length=1, max_length=80)
    cuisine: str = Field(min_length=1, max_length=60)
    story: str = Field(default="", max_length=1000)
    lat: float = Field(ge=-90, le=90)
    lon: float = Field(ge=-180, le=180)
    pickup_note: str = Field(default="", max_length=300)
    porch_tables: int = Field(default=0, ge=0, le=20)
    permit_confirmed: bool = False
    handler_card_confirmed: bool = False


class KitchenUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=80)
    cuisine: str | None = Field(default=None, min_length=1, max_length=60)
    story: str | None = Field(default=None, max_length=1000)
    pickup_note: str | None = Field(default=None, max_length=300)
    porch_tables: int | None = Field(default=None, ge=0, le=20)
    permit_confirmed: bool | None = None
    handler_card_confirmed: bool | None = None


class MenuItemCreate(BaseModel):
    name: str = Field(min_length=1, max_length=80)
    note: str = Field(default="", max_length=160)
    price_cents: int = Field(gt=0, le=100_000)


class MenuItemOut(Out):
    id: uuid.UUID
    name: str
    note: str
    price_cents: int


class DropCreate(BaseModel):
    starts_at: datetime
    ends_at: datetime
    total: int = Field(gt=0, le=1000)
    per_slot: int = Field(default=4, gt=0, le=100)

    @model_validator(mode="after")
    def _ends_after_start(self):
        if self.ends_at <= self.starts_at:
            raise ValueError("It has to end after it starts.")
        return self


class DropOut(Out):
    id: uuid.UUID
    starts_at: datetime
    ends_at: datetime
    total: int
    sold: int
    per_slot: int
    left: int


class ReviewOut(Out):
    stars: int
    tags: list[str]
    text: str
    author_name: str
    created_at: datetime


class KitchenOut(Out):
    id: uuid.UUID
    name: str
    cook_name: str
    cuisine: str
    story: str
    lat: float
    lon: float
    porch_tables: int
    permitted: bool
    rating: float | None
    review_count: int
    next_drop: DropOut | None
    is_mine: bool
    distance_m: float | None = None


class TableFriend(BaseModel):
    id: uuid.UUID
    display_name: str
    pickup_at: datetime


class TableOut(BaseModel):
    """The shared porch table for the next drop: seats, how many have a porch seat, and which of your
    friends are sitting down when. First come; nothing is reserved to a chair."""

    seats: int
    taken: int
    friends: list[TableFriend]


class KitchenDetail(KitchenOut):
    menu: list[MenuItemOut]
    reviews: list[ReviewOut]
    # Present only for the owner and for people with an order here.
    pickup_note: str | None
    table: TableOut | None = None


class Nearby(BaseModel):
    gatherings: list[GatheringOut]
    kitchens: list[KitchenOut]


# Orders


class OrderLineIn(BaseModel):
    menu_item_id: uuid.UUID
    quantity: int = Field(gt=0, le=50)


class OrderCreate(BaseModel):
    client_id: uuid.UUID
    drop_id: uuid.UUID
    pickup_at: datetime
    lines: list[OrderLineIn] = Field(min_length=1, max_length=20)
    eat_on_porch: bool = False


class OrderLineOut(Out):
    name: str
    price_cents: int
    quantity: int


class OrderOut(Out):
    id: uuid.UUID
    client_id: uuid.UUID
    kitchen_id: uuid.UUID
    kitchen_name: str
    drop_id: uuid.UUID
    pickup_at: datetime
    eat_on_porch: bool
    status: Literal["reserved", "picked_up", "reviewed"]
    lines: list[OrderLineOut]
    subtotal_cents: int
    service_cents: int
    total_cents: int
    pickup_note: str


class ReviewCreate(BaseModel):
    stars: int = Field(ge=1, le=5)
    tags: list[str] = Field(default_factory=list, max_length=8)
    text: str = Field(default="", max_length=2000)


# Listings


Weekday = Literal["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
HHMM = r"^([01]\d|2[0-4]):[0-5]\d$"


class Slot(BaseModel):
    """Every `weekday`, or once on `date`. No `end` means a typical length for its kind."""

    weekday: Weekday | None = None
    date: date_ | None = None
    start: str = Field(pattern=HHMM)
    end: str | None = Field(default=None, pattern=HHMM)

    @model_validator(mode="after")
    def _one_kind(self):
        if (self.weekday is None) == (self.date is None):
            raise ValueError("a slot is either weekly (weekday) or one-off (date)")
        return self


class ListingIn(BaseModel):
    """The shape of `sf_happenings.json` in the app, and of what the scout produces."""

    title: str = Field(min_length=1, max_length=160)
    genre: Genre
    venue: str = Field(min_length=1, max_length=160)
    address: str = Field(default="", max_length=200)
    lat: float = Field(ge=-90, le=90)
    lon: float = Field(ge=-180, le=180)
    schedule: list[Slot] = Field(min_length=1)
    price: str = Field(default="", max_length=80)
    organizer: str = Field(default="", max_length=160)
    url: str = Field(default="", max_length=500)
    description: str = Field(default="", max_length=2000)
    confidence: Literal["high", "medium", "low"] = "medium"

    @field_validator("schedule", mode="before")
    @classmethod
    def _one_or_many(cls, v):
        return v if isinstance(v, list) else [v]


class ListingOut(ListingIn):
    model_config = ConfigDict(from_attributes=True)


class Listings(BaseModel):
    listings: list[ListingOut]


# People


class PersonOut(BaseModel):
    id: uuid.UUID
    display_name: str


class FriendCodeOut(BaseModel):
    code: str
    expires_at: datetime


class FriendCodeAccept(BaseModel):
    code: str = Field(min_length=4, max_length=20)


class PorchLightIn(BaseModel):
    hours: float = Field(default=2, gt=0, le=4)
    note: str = Field(default="", max_length=80)
    lat: float | None = Field(default=None, ge=-90, le=90)
    lon: float | None = Field(default=None, ge=-180, le=180)


class PorchLightOut(BaseModel):
    on_until: datetime
    note: str
    lat: float | None = None
    lon: float | None = None
    distance_m: float | None = None


class OutNow(BaseModel):
    """Where a friend is tonight, from what they joined: there (checked in) or heading (starts soon)."""

    gathering_id: uuid.UUID
    title: str
    place_name: str
    starts_at: datetime
    ends_at: datetime
    state: Literal["there", "heading"]
    lat: float
    lon: float


class FriendOut(BaseModel):
    id: uuid.UUID
    display_name: str
    porch_light: PorchLightOut | None = None
    out: OutNow | None = None
    # When they last waved at you, within the last two hours.
    waved_at: datetime | None = None


class CrewCreate(BaseModel):
    name: str = Field(min_length=1, max_length=40)
    member_ids: list[uuid.UUID] = Field(default_factory=list, max_length=30)


class CrewOut(BaseModel):
    id: uuid.UUID
    name: str
    is_mine: bool
    members: list[PersonOut]


class InviteFriends(BaseModel):
    user_ids: list[uuid.UUID] = Field(min_length=1, max_length=30)


class Invited(BaseModel):
    invited: int


class GatheringInviteOut(BaseModel):
    gathering: GatheringOut
    sender: PersonOut
    created_at: datetime


class SharedNight(BaseModel):
    title: str
    starts_at: datetime


class IntroOut(BaseModel):
    """Someone you keep checking in alongside. Seen only by the two of you, each on your own."""

    person: PersonOut
    together: list[SharedNight]
    said_hi: bool


class IntroResult(BaseModel):
    connected: bool


class People(BaseModel):
    porch_light: PorchLightOut | None
    friends: list[FriendOut]
    crews: list[CrewOut]
    invites: list[GatheringInviteOut]
    intros: list[IntroOut] = []


# GatheringOut names PersonOut before it's defined.
GatheringOut.model_rebuild()


# The city catalog


class EventOut(BaseModel):
    id: uuid.UUID
    title: str
    venue: str
    address: str
    lat: float
    lon: float
    starts_at: datetime
    ends_at: datetime | None
    genre: Genre
    tags: list[str]
    price_text: str
    price_min_cents: int | None
    ages: str
    url: str
    why: str | None
    # on | canceled | sold_out
    status: str
    # Where it was seen: funcheap, 19hz, datasf, scout.
    sources: list[str]
    distance_m: float | None = None
    # Your ask put it on the map first. Only ever true for you.
    found_by_you: bool = False


class ScoutRunOut(Out):
    id: uuid.UUID
    intent: str
    day: date_
    # running | done | failed
    status: str
    searches: int
    added: int
    merged: int
    started_at: datetime
    finished_at: datetime | None


class DiscoverOut(BaseModel):
    intent: str
    day: date_
    # hit · searching · miss · off (see app.catalog.discover.Discovery)
    coverage: Literal["hit", "searching", "miss", "off"]
    checked_at: datetime | None
    run: ScoutRunOut | None
    events: list[EventOut]


class FindsOut(BaseModel):
    events: list[EventOut]
