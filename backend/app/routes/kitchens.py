import uuid

from fastapi import APIRouter, Depends, HTTPException, Response
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth import current_user
from app.db import get_session
from app.models import Drop, Follow, Kitchen, MenuItem, Order, Review, User
from app.schemas import (
    DropCreate,
    DropOut,
    KitchenCreate,
    KitchenDetail,
    KitchenOut,
    KitchenUpdate,
    MenuItemCreate,
    MenuItemOut,
    OrderOut,
    PickupIn,
    ReviewOut,
    TableFriend,
    TableOut,
)
from app.social import friend_ids
from app.views import drop_out, kitchen_out, next_drop, now, order_out, ratings

router = APIRouter(prefix="/v1/kitchens", tags=["kitchens"])


async def _mine(session: AsyncSession, user: User) -> Kitchen:
    k = await session.scalar(select(Kitchen).where(Kitchen.owner_id == user.id))
    if k is None:
        raise HTTPException(404, "You haven't opened a kitchen")
    return k


async def has_confirmed_order(session: AsyncSession, k: Kitchen, user: User) -> bool:
    """Reserved and paid (or paying at pickup): the address, the exact spot and the note are yours."""
    orders = await session.scalars(
        select(Order).where(
            Order.kitchen_id == k.id,
            Order.buyer_id == user.id,
            Order.status != "canceled",
            Order.payment.in_(("at_pickup", "paid")),
        )
    )
    return orders.unique().first() is not None


async def kitchen_for(session: AsyncSession, k: Kitchen, user: User) -> KitchenOut:
    """A kitchen as one person sees it on its page: with regulars, followers and whether they follow."""
    rated = await ratings(session, [k.id])
    exact = k.owner_id == user.id or await has_confirmed_order(session, k, user)
    base = kitchen_out(k, user.id, rated.get(k.id), exact=exact)
    visits = (
        select(Order.buyer_id)
        .where(Order.kitchen_id == k.id, Order.status.in_(("picked_up", "reviewed")))
        .group_by(Order.buyer_id)
        .having(func.count() >= 3)
        .subquery()
    )
    base.regulars = await session.scalar(select(func.count()).select_from(visits)) or 0
    base.followers = await session.scalar(select(func.count()).where(Follow.kitchen_id == k.id)) or 0
    base.is_following = (
        await session.scalar(
            select(Follow.user_id).where(Follow.kitchen_id == k.id, Follow.user_id == user.id)
        )
    ) is not None
    return base


async def _detail(session: AsyncSession, k: Kitchen, user: User) -> KitchenDetail:
    base = await kitchen_for(session, k, user)
    reviews = (
        await session.scalars(
            select(Review).where(Review.kitchen_id == k.id).order_by(Review.created_at.desc()).limit(20)
        )
    ).unique()
    shown = k.owner_id == user.id or await has_confirmed_order(session, k, user)
    return KitchenDetail(
        table=await _table(session, k, user),
        **base.model_dump(),
        menu=[MenuItemOut.model_validate(m) for m in k.menu if m.active],
        reviews=[
            ReviewOut(
                stars=r.stars,
                tags=r.tags,
                text=r.text,
                author_name=r.author.display_name,
                created_at=r.created_at,
            )
            for r in reviews
        ],
        pickup_note=k.pickup_note if shown else None,
        address=k.address if shown else None,
    )


async def _table(session: AsyncSession, k: Kitchen, user: User) -> TableOut | None:
    """The porch table at the next drop: four seats a table, first come. Names only your friends."""
    drop = next_drop(k, now())
    if k.porch_tables == 0 or drop is None:
        return None
    porch = list(
        (
            await session.scalars(
                select(Order)
                .where(Order.drop_id == drop.id, Order.eat_on_porch.is_(True))
                .order_by(Order.pickup_at)
            )
        ).unique()
    )
    friends = await friend_ids(session, user.id)
    names = {}
    if friends:
        buyers = {o.buyer_id for o in porch if o.buyer_id in friends}
        names = {u.id: u.display_name for u in await session.scalars(select(User).where(User.id.in_(buyers)))}
    return TableOut(
        seats=k.porch_tables * 4,
        taken=len(porch),
        friends=[
            TableFriend(id=o.buyer_id, display_name=names[o.buyer_id], pickup_at=o.pickup_at)
            for o in porch
            if o.buyer_id in names
        ],
    )


@router.post("", response_model=KitchenDetail, status_code=201)
async def open_kitchen(
    body: KitchenCreate, user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> KitchenDetail:
    k = Kitchen(owner_id=user.id, **body.model_dump())
    k.menu, k.drops = [], []
    session.add(k)
    try:
        await session.commit()
    except IntegrityError:
        await session.rollback()
        raise HTTPException(409, "You already have a kitchen") from None
    k = await _mine(session, user)
    return await _detail(session, k, user)


@router.get("/me", response_model=KitchenDetail)
async def my_kitchen(user: User = Depends(current_user), session: AsyncSession = Depends(get_session)):
    return await _detail(session, await _mine(session, user), user)


@router.patch("/me", response_model=KitchenDetail)
async def update_kitchen(
    body: KitchenUpdate, user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> KitchenDetail:
    k = await _mine(session, user)
    for field, value in body.model_dump(exclude_unset=True).items():
        setattr(k, field, value)
    await session.commit()
    return await _detail(session, k, user)


@router.post("/me/menu", response_model=MenuItemOut, status_code=201)
async def add_menu_item(
    body: MenuItemCreate, user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> MenuItem:
    k = await _mine(session, user)
    item = MenuItem(kitchen_id=k.id, sort_index=len(k.menu), **body.model_dump())
    session.add(item)
    await session.commit()
    return item


@router.delete("/me/menu/{item_id}", status_code=204)
async def remove_menu_item(
    item_id: uuid.UUID, user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> Response:
    k = await _mine(session, user)
    item = await session.get(MenuItem, item_id)
    if item is not None and item.kitchen_id == k.id:
        item.active = False
        await session.commit()
    return Response(status_code=204)


@router.post("/me/drops", response_model=DropOut, status_code=201)
async def post_drop(
    body: DropCreate, user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> DropOut:
    k = await _mine(session, user)
    if not any(m.active for m in k.menu):
        raise HTTPException(409, "Add something to the menu first")
    if not (k.permit_confirmed and k.handler_card_confirmed):
        raise HTTPException(409, "Confirm your permit and food handler card first")
    if body.ends_at <= now():
        raise HTTPException(422, "That drop has already ended")
    d = Drop(kitchen_id=k.id, **body.model_dump())
    session.add(d)
    await session.commit()
    return drop_out(d)


@router.get("/me/orders", response_model=list[OrderOut])
async def kitchen_orders(user: User = Depends(current_user), session: AsyncSession = Depends(get_session)):
    """Every order that's confirmed (paid, or paying at pickup), with the buyer's name and code."""
    k = await _mine(session, user)
    orders = await session.scalars(
        select(Order)
        .where(Order.kitchen_id == k.id, Order.status != "canceled", Order.payment.in_(("at_pickup", "paid")))
        .order_by(Order.pickup_at)
    )
    return [order_out(o, for_seller=True) for o in orders.unique()]


@router.post("/me/orders/{order_id}/picked-up", response_model=OrderOut)
async def handed_over(
    order_id: uuid.UUID,
    body: PickupIn | None = None,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(get_session),
) -> OrderOut:
    """The cook marks it picked up. If they typed the code, it has to match."""
    k = await _mine(session, user)
    o = await session.get(Order, order_id)
    if o is None or o.kitchen_id != k.id or o.status == "canceled":
        raise HTTPException(404, "Order not found")
    if o.payment == "unpaid":
        raise HTTPException(409, "That order isn't paid yet")
    if body and body.code and body.code.strip() != o.pickup_code:
        raise HTTPException(409, "That code doesn't match")
    if o.status == "reserved":
        o.status = "picked_up"
        o.picked_up_at = now()
        await session.commit()
    return order_out(o, for_seller=True)


@router.get("/{kitchen_id}", response_model=KitchenDetail)
async def get_kitchen(
    kitchen_id: uuid.UUID, user: User = Depends(current_user), session: AsyncSession = Depends(get_session)
) -> KitchenDetail:
    k = await session.get(Kitchen, kitchen_id)
    if k is None:
        raise HTTPException(404, "Kitchen not found")
    return await _detail(session, k, user)
