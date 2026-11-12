import uuid
from datetime import date as date_
from datetime import datetime, timedelta
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
    address: str = Field(default="", max_length=200)


class KitchenUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=80)
    cuisine: str | None = Field(default=None, min_length=1, max_length=60)
    story: str | None = Field(default=None, max_length=1000)
    pickup_note: str | None = Field(default=None, max_length=300)
    porch_tables: int | None = Field(default=None, ge=0, le=20)
    permit_confirmed: bool | None = None
    handler_card_confirmed: bool | None = None
    address: str | None = Field(default=None, max_length=200)


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
    # A batch's own fields; empty (and price_cents null) for a drop off the menu.
    title: str = ""
    unit: str = ""
    price_cents: int | None = None
    tags: list[str] = []
    pickup_spot: str = ""
    # Relative to the API's address: "/v1/photos/<id>". The map draws it as the food pin.
    photo_url: str | None = None


PickupSpot = Literal["porch", "door"]
Pay = Literal["in_app", "at_pickup"]


class BatchCreate(BaseModel):
    """Post a batch in one go. Opens a kitchen in your name if you don't have one yet."""

    title: str = Field(min_length=1, max_length=80)
    price_cents: int = Field(gt=0, le=100_000)
    total: int = Field(gt=0, le=500)
    unit: str = Field(default="", max_length=20)
    starts_at: datetime
    ends_at: datetime
    pickup_spot: PickupSpot = "porch"
    tags: list[str] = Field(default_factory=list, max_length=8)
    per_slot: int = Field(default=4, gt=0, le=100)
    # Asked once, kept on the kitchen.
    permit_confirmed: bool = False
    # The kitchen's address and pickup note; needed the first time, kept after.
    address: str | None = Field(default=None, max_length=200)
    pickup_note: str | None = Field(default=None, max_length=300)
    # Where the kitchen goes on the map, the first time.
    lat: float | None = Field(default=None, ge=-90, le=90)
    lon: float | None = Field(default=None, ge=-180, le=180)

    @model_validator(mode="after")
    def _ends_after_start(self):
        if self.ends_at <= self.starts_at:
            raise ValueError("The pickup window has to end after it starts")
        self.tags = [t.strip()[:30] for t in self.tags if t.strip()]
        return self


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
    # The next drop's photo, for the map's food pin.
    photo_url: str | None = None
    # In the app (Stripe) or to the cook at pickup.
    pay: Pay = "at_pickup"
    # On a kitchen's page and a batch's, not in /v1/nearby.
    regulars: int | None = None
    followers: int | None = None
    is_following: bool | None = None


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
    address: str | None = None


class BatchOut(DropOut):
    """A batch's listing page: the photo, what it is, the kitchen, how many are left."""

    kitchen: KitchenOut
    review: ReviewOut | None
    # 15-minute pickup slots already full.
    full_slots: list[datetime]
    # The owner's and confirmed buyers' only.
    address: str | None
    pickup_note: str | None


class PhotoOut(BaseModel):
    photo_url: str


class FollowOut(BaseModel):
    following: bool
    followers: int


class NoteOut(BaseModel):
    id: uuid.UUID
    kind: Literal["batch"]
    kitchen_id: uuid.UUID
    kitchen_name: str
    drop_id: uuid.UUID | None
    title: str
    photo_url: str | None
    starts_at: datetime | None
    created_at: datetime
    read: bool


class PayoutsOut(BaseModel):
    # Stripe is set up on the server at all.
    enabled: bool
    # This kitchen's account can take charges: buyers pay in the app.
    ready: bool
    # Where to finish setting up (Stripe's own page), when not ready.
    onboarding_url: str | None = None


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
    # Menu drops take lines; a batch takes a quantity.
    lines: list[OrderLineIn] = Field(default_factory=list, max_length=20)
    quantity: int | None = Field(default=None, gt=0, le=50)
    eat_on_porch: bool = False

    @model_validator(mode="after")
    def _something(self):
        if not self.lines and self.quantity is None:
            raise ValueError("Pick something to reserve")
        return self


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
    status: Literal["reserved", "picked_up", "reviewed", "canceled"]
    lines: list[OrderLineOut]
    subtotal_cents: int
    service_cents: int
    total_cents: int
    # Empty until the order's confirmed (paid, or paying at pickup).
    pickup_note: str
    # refunded: the money came after its hold ran out and the batch had sold out meanwhile.
    payment: Literal["at_pickup", "unpaid", "paid", "refunded"] = "at_pickup"
    pickup_code: str = ""
    picked_up_at: datetime | None = None
    title: str = ""
    unit: str = ""
    photo_url: str | None = None
    pickup_spot: str = ""
    # The exact spot, once confirmed.
    address: str | None = None
    lat: float | None = None
    lon: float | None = None
    # On the seller's list only.
    buyer_name: str | None = None


class PaymentOut(BaseModel):
    """What PaymentSheet needs. `client_secret` is null once it's paid."""

    order_id: uuid.UUID
    payment: Literal["unpaid", "paid"]
    amount_cents: int
    client_secret: str | None
    publishable_key: str
    merchant_id: str | None
    merchant_name: str = "Let's Go"
    country: str = "US"


class PickupIn(BaseModel):
    # The three digits the buyer said, if the cook typed them in.
    code: str | None = Field(default=None, max_length=3)


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
    """The old shape of "up for something", for phones from before it was renamed. Never coordinates."""

    on_until: datetime
    note: str
    lat: float | None = None
    lon: float | None = None
    distance_m: float | None = None


ActivityKey = Literal["walk", "coffee", "drink", "pickup", "cooking", ""]


class UpForIn(BaseModel):
    activity: ActivityKey = ""
    words: str = Field(default="", max_length=80)
    hours: float = Field(default=2, gt=0, le=4)
    # Where you are, so friends see how far a walk it is. Kept on the server; nobody gets it.
    lat: float | None = Field(default=None, ge=-90, le=90)
    lon: float | None = Field(default=None, ge=-180, le=180)


class UpForOut(BaseModel):
    """What someone's up for: "A walk" for the next hour, 6 minutes away. Never where they are."""

    activity: str
    label: str
    words: str
    until: datetime
    # The little speech bubble on their pin: "walk?".
    bubble: str
    # How far a walk, rounded; None when either of you has no location.
    walk_min: int | None = None


class Point(BaseModel):
    lat: float
    lon: float


class SpotIn(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    lat: float = Field(ge=-90, le=90)
    lon: float = Field(ge=-180, le=180)


class SpotOut(BaseModel):
    name: str
    lat: float
    lon: float


class ImInIn(BaseModel):
    lat: float | None = Field(default=None, ge=-90, le=90)
    lon: float | None = Field(default=None, ge=-180, le=180)


class MeetupUpdate(BaseModel):
    lat: float | None = Field(default=None, ge=-90, le=90)
    lon: float | None = Field(default=None, ge=-180, le=180)
    on_my_way: bool | None = None
    says: str | None = Field(default=None, max_length=40)


class MeetupOut(BaseModel):
    """You and one other person, meeting. Seen only by the two of you, until Done."""

    id: uuid.UUID
    other: PersonOut
    is_mine: bool  # it was your "up for" they said I'm in to
    activity: str
    label: str
    headline: str
    spot: SpotOut | None
    # Roughly halfway, rounded to a few hundred metres: where a phone looks for a spot.
    area: Point | None
    meet_at: datetime
    ends_at: datetime
    my_walk_min: int | None
    their_walk_min: int | None
    i_am_on_my_way: bool
    they_are_on_their_way: bool
    they_say: str


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
    up_for: UpForOut | None = None
    out: OutNow | None = None
    # When they last waved at you, within the last two hours.
    waved_at: datetime | None = None


class CrewCreate(BaseModel):
    name: str = Field(min_length=1, max_length=40)
    member_ids: list[uuid.UUID] = Field(default_factory=list, max_length=30)


class CrewNext(BaseModel):
    """The next thing at least two of the crew said they're in for."""

    gathering_id: uuid.UUID
    title: str
    starts_at: datetime
    going: int


class CrewOut(BaseModel):
    id: uuid.UUID
    name: str
    is_mine: bool
    members: list[PersonOut]
    next: CrewNext | None = None


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
    # People you've met see what you're up for, and you theirs.
    up_for: UpForOut | None = None
    waved_at: datetime | None = None


class IntroResult(BaseModel):
    connected: bool


class People(BaseModel):
    porch_light: PorchLightOut | None
    up_for: UpForOut | None = None
    friends: list[FriendOut]
    crews: list[CrewOut]
    invites: list[GatheringInviteOut]
    intros: list[IntroOut] = []
    meetup: MeetupOut | None = None


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


# Supper club


class Course(BaseModel):
    name: str = Field(min_length=1, max_length=60)
    note: str = Field(default="", max_length=120)


class SupperCreate(BaseModel):
    """Set up a supper. Like a batch, it opens a kitchen in your name the first time (the address
    goes only to guests you say yes to) and asks for the home kitchen permit once."""

    title: str = Field(min_length=1, max_length=80)
    starts_at: datetime
    ends_at: datetime
    seats: int = Field(ge=1, le=20)
    price_cents: int = Field(gt=0, le=50_000)
    menu: list[Course] = Field(default_factory=list, max_length=8)
    tags: list[str] = Field(default_factory=list, max_length=8)
    house_notes: str = Field(default="", max_length=500)
    permit_confirmed: bool = False
    address: str | None = Field(default=None, max_length=200)
    lat: float | None = Field(default=None, ge=-90, le=90)
    lon: float | None = Field(default=None, ge=-180, le=180)

    @model_validator(mode="after")
    def _ends_after_start(self):
        if self.ends_at <= self.starts_at:
            raise ValueError("It has to end after it starts")
        if self.ends_at - self.starts_at > timedelta(hours=8):
            raise ValueError("A supper runs at most eight hours")
        return self

    @field_validator("tags")
    @classmethod
    def _tags(cls, v: list[str]) -> list[str]:
        return [t.strip()[:30] for t in v if t.strip()]


class SeatAsk(BaseModel):
    note: str = Field(default="", max_length=200)


class SeatOut(BaseModel):
    """Your seat at a supper, as you see it."""

    id: uuid.UUID
    status: Literal["asked", "accepted", "declined", "withdrawn", "canceled", "lapsed"]
    payment: Literal["none", "at_door", "unpaid", "paid", "refunded"]
    note: str
    price_cents: int
    service_cents: int
    total_cents: int
    # Accepted but not paid yet: pay by then or the seat goes back.
    pay_by: datetime | None = None


class TableMate(BaseModel):
    """Someone at the table (the host or an accepted guest), for the people at it."""

    id: uuid.UUID
    display_name: str
    is_host: bool
    is_friend: bool
    # You said hi (add as a friend); you're friends once they do too.
    said_hi: bool
    # You've reviewed them for this supper.
    reviewed: bool


class SupperOut(BaseModel):
    id: uuid.UUID
    title: str
    starts_at: datetime
    ends_at: datetime
    seats: int
    taken: int
    seats_left: int
    price_cents: int
    # The app's fee on a seat paid in the app (none at the door), and what a seat comes to.
    service_cents: int
    seat_total_cents: int
    pay: Literal["in_app", "at_door"]
    menu: list[Course]
    tags: list[str]
    house_notes: str
    photo_url: str | None
    host: PersonOut
    kitchen_id: uuid.UUID
    suppers_hosted: int
    host_rating: float | None
    host_review_count: int
    # The real spot only for the host and confirmed guests; everyone else gets the kitchen's
    # public point, 60 to 150 m off the house.
    lat: float
    lon: float
    exact: bool
    address: str | None
    distance_m: float | None = None
    friends_going: list[PersonOut]
    is_mine: bool
    canceled: bool
    my_seat: SeatOut | None
    # Guests may cancel for a full refund until then.
    refund_until: datetime
    # The host's count of requests waiting for an answer.
    waiting: int = 0
    # Everyone at the table, for the host and accepted guests.
    table: list[TableMate] = Field(default_factory=list)


class GuestOut(BaseModel):
    """Someone asking for a seat, as the host sees them: what others hosts said, and how many suppers
    they've been to."""

    seat_id: uuid.UUID
    guest: PersonOut
    note: str
    status: str
    payment: str
    asked_at: datetime
    suppers_attended: int
    rating: float | None
    review_count: int
    reviews: list[str]
    is_friend: bool


class MySuppers(BaseModel):
    hosting: list[SupperOut]
    going: list[SupperOut]


class SupperReviewIn(BaseModel):
    subject_id: uuid.UUID
    stars: int = Field(ge=1, le=5)
    text: str = Field(default="", max_length=1000)


# Your block


class BlockItemOut(BaseModel):
    """One row on Your block. The phone writes the words (in its own time zone); this is what it
    writes them from. `name` is only ever a friend's, someone you've met, or a kitchen's public name;
    people you don't know are in `count`."""

    key: str
    # batch (a neighbor's batch) · back (a kitchen you follow) · supper · going · neighbor · up_for
    kind: Literal["batch", "back", "supper", "going", "neighbor", "up_for"]
    # The drop, gathering or person it's about.
    id: uuid.UUID
    kitchen_id: uuid.UUID | None = None
    title: str = ""
    name: str | None = None
    # Friends going, by name; everyone else in, as a number.
    friends: list[str] = []
    count: int = 0
    left: int | None = None
    unit: str = ""
    seats_left: int | None = None
    price_cents: int | None = None
    place_name: str = ""
    starts_at: datetime | None = None
    ends_at: datetime | None = None
    posted_at: datetime | None = None
    walk_min: int | None = None
    photo_url: str | None = None
    # For a neighbor to say hi to: how many things you've both been to.
    together: int = 0


class BlockOut(BaseModel):
    items: list[BlockItemOut]
    radius_m: float
