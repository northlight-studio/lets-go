import asyncio
import contextlib
import logging
from collections.abc import AsyncIterator

from fastapi import FastAPI

from app.config import settings
from app.routes import discover, gatherings, kitchens, listings, orders, people, users

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")


@contextlib.asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    task = None
    if settings.catalog_scheduler:
        from app.catalog.scheduler import run_forever

        task = asyncio.create_task(run_forever())
    yield
    if task is not None:
        task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await task


app = FastAPI(title="Let's Go", version="0.2.0", lifespan=lifespan)
app.include_router(users.router)
app.include_router(gatherings.router)
app.include_router(kitchens.router)
app.include_router(orders.router)
app.include_router(listings.router)
app.include_router(people.router)
app.include_router(discover.router)


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}
