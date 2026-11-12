"""The source list from the command line.

python -m app.catalog.sources seed-build ../ios/LetsGo/Resources/sf_happenings.json
python -m app.catalog.sources seed                 # add new seed rows to the database
python -m app.catalog.sources read                 # tonight's read, now (CATALOG_SCHEDULER=0)
python -m app.catalog.sources dry-run [--limit 40] # fetch and parse the seed, write nothing
python -m app.catalog.sources report               # health and last night's numbers
"""

import argparse
import asyncio
import json
import logging
from collections import Counter
from datetime import UTC, datetime, timedelta
from pathlib import Path

import httpx

from app.catalog.sources import formats, host_of
from app.catalog.sources.fetch import Fetcher
from app.catalog.sources.night import TYPICAL_LENGTH, upcoming
from app.catalog.sources.seed import SeedSource, read_seed, write_seed


async def dry_run(
    seeds: list[SeedSource], client: httpx.AsyncClient, now: datetime, days: int = 45, delay: float = 3.0
) -> dict:
    """Every seed source fetched politely and read by code, nothing written. Pages with no structure are
    counted as the model's, not sent to it."""
    fetcher = Fetcher(client, delay=delay)
    lines: list[dict] = []

    async def one(s: SeedSource) -> dict:
        page = await fetcher.fetch(s.url)
        row = {"url": s.url, "status": page.status, "outcome": "", "reader": "", "events": 0, "sample": []}
        if not page.ok:
            row["outcome"] = page.refused or f"http {page.status}"
            return row
        url = page.final_url or s.url
        learned = formats.detect(page.text, url, page.content_type)
        text = page.text
        if learned.feed_url:
            feed = await fetcher.fetch(learned.feed_url)
            if feed.ok:
                text = feed.text
            else:
                learned = formats.Learned("jsonld" if formats.ld_events(page.text) else "html")
        row["reader"] = learned.reader
        if learned.reader == "html":
            row["outcome"] = "model"
            row["chars"] = len(formats.page_text(page.text, url))
            return row
        ctx = formats.Context(
            source_id="dry", page_url=url, venue_name=s.venue_name, address=s.address, lat=s.lat, lon=s.lon,
            genre=s.genre, window=(now - TYPICAL_LENGTH, now + timedelta(days=days)),
        )  # fmt: skip
        events = upcoming(formats.parse(learned.reader, text, ctx) or [], now)
        row["outcome"] = "code"
        row["events"] = len(events)
        row["sample"] = [
            f"{c.starts_at.astimezone(ctx.zone):%a %b %d %H:%M} · {c.title} · {c.venue_name or '?'}"
            + (" · CANCELED" if c.canceled else "")
            for c in sorted(events, key=lambda c: c.starts_at)[:3]
        ]
        return row

    by_host: dict[str, list[SeedSource]] = {}
    for s in seeds:
        by_host.setdefault(host_of(s.url), []).append(s)
    gate = asyncio.Semaphore(8)

    async def host(items: list[SeedSource]) -> None:
        async with gate:
            for s in items:
                try:
                    lines.append(await one(s))
                except Exception as e:  # a dry run reports, it doesn't stop
                    lines.append({"url": s.url, "outcome": f"error {type(e).__name__}", "events": 0})

    await asyncio.gather(*(host(items) for items in by_host.values()))
    totals = Counter(r["outcome"] for r in lines)
    return {
        "sources": len(seeds),
        "outcomes": dict(totals),
        "readers": dict(Counter(r.get("reader") or "-" for r in lines)),
        "events_by_code": sum(r["events"] for r in lines),
        "requests": fetcher.requests,
        "lines": sorted(lines, key=lambda r: (-r["events"], r["url"])),
    }


async def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("command", choices=["seed-build", "seed", "read", "dry-run", "report"])
    parser.add_argument("path", nargs="?")
    parser.add_argument("--city", default="sf")
    parser.add_argument("--limit", type=int, default=0)
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(message)s")

    if args.command == "seed-build":
        print(f"{write_seed(Path(args.path))} sources written")
        return
    if args.command == "dry-run":
        seeds = read_seed()[: args.limit or None]
        async with httpx.AsyncClient() as client:
            out = await dry_run(seeds, client, datetime.now(UTC))
        print(json.dumps(out, indent=1))
        return

    from app.catalog.scheduler import read_city
    from app.catalog.sources.report import report
    from app.catalog.sources.seed import load_seed
    from app.db import SessionLocal, engine
    from app.views import now

    if args.command == "seed":
        async with SessionLocal() as session:
            print(f"{await load_seed(session, args.city)} new sources")
            await session.commit()
    elif args.command == "read":
        async with httpx.AsyncClient(follow_redirects=True) as client:
            await read_city(args.city, client)
    async with SessionLocal() as session:
        print(json.dumps(await report(session, args.city, now()), indent=1, default=str))
    await engine.dispose()


if __name__ == "__main__":
    asyncio.run(main())
