"""Post a batch, sell to your neighbors: the 30-second post, its photo, the listing page a neighbor
sees, following a kitchen, and the notes followers get when it posts."""

import uuid
from datetime import timedelta

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from sqlalchemy import func, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import current_user
from app.db import get_session
from app.models import Drop, Follow, Kitchen, MenuItem, Note, Order, Photo, Review, User
from app.routes.kitchens import has_confirmed_order, kitchen_for
from app.schemas import BatchCreate, BatchOut, FollowOut, NoteOut, PhotoOut, ReviewOut
from app.views import drop_fields, now, photo_url

router = APIRouter(tags=["batches"])

# About 1200 px on the long side at JPEG quality ~0.8 is well under this.
MAX_PHOTO_BYTES = 3 * 1024 * 1024


async def home_kitchen(
    session: AsyncSession,
    user: User,
    *,
    address: str | None,
    pickup_note: str | None,
    lat: float | None,
    lon: float | None,
    permit_confirmed: bool,
) -> Kitchen:
    """Your kitchen, opened in your name the first time (a batch or a supper). The address and the
    permit are asked once and kept on it. Raises when either is still missing."""
    k = await session.scalar(select(Kitchen).where(Kitchen.owner_id == user.id))
    address = (address or "").strip()
    if k is None:
        if lat is None or lon is None:
            raise HTTPException(422, "Where's your kitchen? Turn on location and try again.")
        if not address:
            raise HTTPException(422, "Add your address. Only your buyers and guests see it.")
        k = Kitchen(
            owner_id=user.id,
            name=f"{user.display_name}'s kitchen",
            cuisine="Home cooking",
            lat=lat,
            lon=lon,
            address=address,
            pickup_note=(pickup_note or "").strip(),
        )
        k.menu, k.drops = [], []
        session.add(k)
        await session.flush()
    else:
        if address:
            k.address = address
        if pickup_note is not None:
            k.pickup_note = pickup_note.strip()
        if not k.address:
            raise HTTPException(422, "Add your address. Only your buyers and guests see it.")
    if not (k.permit_confirmed and k.handler_card_confirmed):
        if not permit_confirmed:
            raise HTTPException(409, "Confirm your home kitchen permit first")
        k.permit_confirmed = k.handler_card_confirmed = True
    return k


async def store_photo(
    session: AsyncSession, request: Request, user: User, replacing: uuid.UUID | None
) -> Photo:
    """A JPEG body (Content-Type: image/jpeg), resized on the phone first. Deletes the one it replaces."""
    data = await request.body()
    if len(data) > MAX_PHOTO_BYTES:
        raise HTTPException(413, "That photo is too big. Try again; the app shrinks it first.")
    if not data.startswith(b"\xff\xd8\xff"):
        raise HTTPException(415, "Send the photo as a JPEG")
    photo = Photo(owner_id=user.id, content_type="image/jpeg", data=data)
    session.add(photo)
    await session.flush()
    if replacing is not None:
        await session.execute(Photo.__table__.delete().where(Photo.id == replacing))
    return photo


async def batch_out(session: AsyncSession, d: Drop, user: User) -> BatchOut:
    k = await session.get(Kitchen, d.kitchen_id)
    review = (
        await session.scalars(
            select(Review)
            .where(Review.kitchen_id == k.id, Review.text != "")
            .order_by(Review.stars.desc(), Review.created_at.desc())
            .limit(1)
        )
    ).first()
    full = await session.scalars(
        select(Order.pickup_at)
        .where(Order.drop_id == d.id, Order.status != "canceled")
        .group_by(Order.pickup_at)
        .having(func.count() >= d.per_slot)
        .order_by(Order.pickup_at)
    )
    shown = k.owner_id == user.id or await has_confirmed_order(session, k, user)
    return BatchOut(
        **drop_fields(d),
        kitchen=await kitchen_for(session, k, user),
        review=ReviewOut(
            stars=review.stars,
            tags=review.tags,
            text=review.text,
            author_name=review.author.display_name,
            created_at=review.created_at,
        )
        if review
        else None,
        full_slots=list(full),
        address=k.address if shown else None,
        pickup_note=k.pickup_note if shown else None,
    )


@router.post("/v1/batches", response_model=BatchOut, status_code=201)
async def post_batch(
    body: BatchCreate, user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> BatchOut:
    """A batch is a drop of one thing. No kitchen yet: this opens one in your name. The permit is
    asked once and kept on the kitchen. Followers get a note."""
    if body.ends_at <= now():
        raise HTTPException(422, "That pickup window has already passed")
    k = await home_kitchen(
        session,
        user,
        address=body.address,
        pickup_note=body.pickup_note,
        lat=body.lat,
        lon=body.lon,
        permit_confirmed=body.permit_confirmed,
    )

    # The batch's own item, off the standing menu (inactive), so old orders keep their line.
    item = MenuItem(kitchen_id=k.id, name=body.title.strip(), price_cents=body.price_cents, active=False)
    session.add(item)
    await session.flush()
    d = Drop(
        kitchen_id=k.id,
        starts_at=body.starts_at,
        ends_at=body.ends_at,
        total=body.total,
        per_slot=body.per_slot,
        menu_item_id=item.id,
        title=body.title.strip(),
        unit=body.unit.strip(),
        tags=body.tags,
        pickup_spot=body.pickup_spot,
    )
    session.add(d)
    await session.flush()
    followers = await session.scalars(
        select(Follow.user_id).where(Follow.kitchen_id == k.id, Follow.user_id != user.id)
    )
    session.add_all(Note(user_id=uid, kind="batch", kitchen_id=k.id, drop_id=d.id) for uid in followers)
    await session.commit()
    d = await session.scalar(select(Drop).where(Drop.id == d.id).execution_options(populate_existing=True))
    return await batch_out(session, d, user)


@router.get("/v1/drops/{drop_id}", response_model=BatchOut)
async def get_drop(
    drop_id: uuid.UUID, user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> BatchOut:
    d = await session.get(Drop, drop_id)
    if d is None:
        raise HTTPException(404, "That batch isn't here anymore")
    return await batch_out(session, d, user)


@router.post("/v1/drops/{drop_id}/photo", response_model=PhotoOut, status_code=201)
async def put_photo(
    drop_id: uuid.UUID,
    request: Request,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> PhotoOut:
    """The batch's photo: a JPEG body (Content-Type: image/jpeg), resized on the phone first.
    A new one replaces the old."""
    d = await session.get(Drop, drop_id)
    k = await session.get(Kitchen, d.kitchen_id) if d else None
    if d is None or k is None or k.owner_id != user.id:
        raise HTTPException(404, "That batch isn't yours")
    photo = await store_photo(session, request, user, d.photo_id)
    d.photo_id = photo.id
    await session.commit()
    return PhotoOut(photo_url=photo_url(photo.id))


@router.get("/v1/photos/{photo_id}")
async def get_photo(photo_id: uuid.UUID, request: Request, session: AsyncSession = Depends(get_session)):
    """Public, so the map and image loaders can fetch it without a token. Ids are random and a photo
    never changes (a new one gets a new id), so it caches forever."""
    etag = f'"{photo_id}"'
    headers = {"Cache-Control": "public, max-age=31536000, immutable", "ETag": etag}
    if request.headers.get("if-none-match") == etag:
        exists = await session.scalar(select(Photo.id).where(Photo.id == photo_id))
        if exists:
            return Response(status_code=304, headers=headers)
    row = (await session.execute(select(Photo.content_type, Photo.data).where(Photo.id == photo_id))).first()
    if row is None:
        raise HTTPException(404, "No such photo")
    return Response(content=row.data, media_type=row.content_type, headers=headers)


# Following


async def _follow_out(session: AsyncSession, kitchen_id: uuid.UUID, user: User) -> FollowOut:
    followers = await session.scalar(select(func.count()).where(Follow.kitchen_id == kitchen_id)) or 0
    mine = await session.scalar(
        select(Follow.user_id).where(Follow.kitchen_id == kitchen_id, Follow.user_id == user.id)
    )
    return FollowOut(following=mine is not None, followers=followers)


@router.put("/v1/kitchens/{kitchen_id}/follow", response_model=FollowOut)
async def follow(
    kitchen_id: uuid.UUID, user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> FollowOut:
    k = await session.get(Kitchen, kitchen_id)
    if k is None:
        raise HTTPException(404, "Kitchen not found")
    if k.owner_id == user.id:
        raise HTTPException(409, "That's your own kitchen")
    exists = await session.scalar(
        select(Follow.user_id).where(Follow.kitchen_id == kitchen_id, Follow.user_id == user.id)
    )
    if exists is None:
        session.add(Follow(user_id=user.id, kitchen_id=kitchen_id))
        await session.commit()
    return await _follow_out(session, kitchen_id, user)


@router.delete("/v1/kitchens/{kitchen_id}/follow", response_model=FollowOut)
async def unfollow(
    kitchen_id: uuid.UUID, user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> FollowOut:
    await session.execute(
        Follow.__table__.delete().where(Follow.kitchen_id == kitchen_id, Follow.user_id == user.id)
    )
    await session.commit()
    return await _follow_out(session, kitchen_id, user)


@router.get("/v1/me/notes", response_model=list[NoteOut])
async def my_notes(user: User = Depends(current_user), session: AsyncSession = Depends(get_session)):
    """New batches from kitchens you follow, newest first; the last two weeks."""
    notes = await session.scalars(
        select(Note)
        .where(Note.user_id == user.id, Note.created_at > now() - timedelta(days=14))
        .order_by(Note.created_at.desc())
        .limit(30)
    )
    return [
        NoteOut(
            id=n.id,
            kind="batch",
            kitchen_id=n.kitchen_id,
            kitchen_name=n.kitchen.name,
            drop_id=n.drop_id,
            title=n.drop.title if n.drop else "",
            photo_url=photo_url(n.drop.photo_id) if n.drop else None,
            starts_at=n.drop.starts_at if n.drop else None,
            created_at=n.created_at,
            read=n.read_at is not None,
        )
        for n in notes.unique()
    ]


@router.post("/v1/me/notes/read", status_code=204)
async def read_notes(
    user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> Response:
    await session.execute(
        update(Note).where(Note.user_id == user.id, Note.read_at.is_(None)).values(read_at=now())
    )
    await session.commit()
    return Response(status_code=204)
