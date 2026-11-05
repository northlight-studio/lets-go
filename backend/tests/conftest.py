import inspect
import os
from datetime import UTC, datetime, timedelta

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from app import models  # noqa: F401
from app.db import Base, get_session, get_session_factory
from app.main import app

TEST_URL = os.environ.get(
    "TEST_DATABASE_URL", "postgresql+asyncpg://letsgo:letsgo_dev@localhost:5433/letsgo_test"
)

# Somewhere in a city; everything in the tests is placed relative to it.
HERE = (37.7596, -122.4269)


@pytest.fixture(scope="session")
async def engine():
    eng = create_async_engine(TEST_URL)
    async with eng.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
        await conn.run_sync(Base.metadata.create_all)
    yield eng
    await eng.dispose()


@pytest.fixture(autouse=True)
async def clean(engine):
    yield
    tables = ", ".join(t.name for t in reversed(Base.metadata.sorted_tables))
    async with engine.begin() as conn:
        await conn.execute(text(f"TRUNCATE {tables} CASCADE"))


@pytest.fixture
async def client(engine):
    maker = async_sessionmaker(engine, expire_on_commit=False)

    async def session_override():
        async with maker() as s:
            yield s

    app.dependency_overrides[get_session] = session_override
    app.dependency_overrides[get_session_factory] = lambda: maker
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c
    app.dependency_overrides.clear()


async def make_user(client: AsyncClient, name: str) -> dict[str, str]:
    r = await client.post("/v1/users", json={"display_name": name})
    assert r.status_code == 201, r.text
    return {"Authorization": f"Bearer {r.json()['token']}"}


def at(minutes: float) -> str:
    return (datetime.now(UTC) + timedelta(minutes=minutes)).isoformat()


def offset(east_m: float, north_m: float) -> tuple[float, float]:
    import math

    lat, lon = HERE
    return lat + north_m / 111_320, lon + east_m / (111_320 * math.cos(math.radians(lat)))


def pytest_collection_modifyitems(items):
    # One event loop for the whole run, shared with the session-scoped engine. Plain functions stay plain.
    marker = pytest.mark.asyncio(loop_scope="session")
    for item in items:
        if inspect.iscoroutinefunction(getattr(item, "function", None)):
            item.add_marker(marker, append=False)
