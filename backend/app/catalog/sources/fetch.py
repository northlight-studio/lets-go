"""Polite fetching, in plain code. One user agent that says who we are, robots.txt read and obeyed per
host, one request at a time per host with a pause between them, conditional requests so an unchanged
page costs the site almost nothing, and a size cap. Never sends cookies or credentials, and treats a
redirect to a login page as a closed door.
"""

import asyncio
import logging
import time
from dataclasses import dataclass
from urllib.parse import urlsplit
from urllib.robotparser import RobotFileParser

import httpx

from app.catalog.sources import host_of, looks_like_login, normalize

log = logging.getLogger("letsgo.sources.fetch")

USER_AGENT = "LetsGoReader/0.2 (city events app; reads public event calendars once a night)"
ROBOTS_AGENT = "LetsGoReader"
# Between two requests to the same host, at least this long (more if robots.txt asks, up to MAX_DELAY).
HOST_DELAY = 3.0
MAX_DELAY = 30.0
MAX_BYTES = 8_000_000
TIMEOUT = 30.0


@dataclass
class Page:
    url: str
    # The URL the page was finally served from, after redirects.
    final_url: str = ""
    status: int = 0
    text: str = ""
    content_type: str = ""
    etag: str | None = None
    last_modified: str | None = None
    # robots | login | error | too_big | None
    refused: str | None = None
    error: str = ""
    # A 301/308 somewhere along the way: the page has a new address.
    permanent_redirect: bool = False

    @property
    def ok(self) -> bool:
        return self.refused is None and self.status == 200

    @property
    def not_modified(self) -> bool:
        return self.status == 304

    @property
    def host_changed(self) -> bool:
        a, b = (
            host_of(self.url).removeprefix("www."),
            host_of(self.final_url or self.url).removeprefix("www."),
        )
        return a != b

    @property
    def moved(self) -> bool:
        """Served from somewhere other than where we asked, beyond http→https or a trailing slash."""
        if not self.final_url:
            return False
        a, b = urlsplit(normalize(self.url)), urlsplit(normalize(self.final_url))
        return (a.netloc.removeprefix("www."), a.path, a.query) != (
            b.netloc.removeprefix("www."),
            b.path,
            b.query,
        )


class Fetcher:
    """Shared by every fetch in a night, so the per-host pause and robots.txt hold across sources."""

    def __init__(
        self, client: httpx.AsyncClient, delay: float = HOST_DELAY, clock=time.monotonic, sleep=None
    ):
        self.client = client
        self.delay = delay
        self.clock = clock
        self.sleep = sleep or asyncio.sleep
        self._robots: dict[str, RobotFileParser | None] = {}
        self._locks: dict[str, asyncio.Lock] = {}
        self._last: dict[str, float] = {}
        self.requests = 0

    def _lock(self, host: str) -> asyncio.Lock:
        return self._locks.setdefault(host, asyncio.Lock())

    async def _wait_turn(self, host: str) -> None:
        robots = self._robots.get(host)
        asked = robots.crawl_delay(ROBOTS_AGENT) if robots else None
        gap = min(MAX_DELAY, max(self.delay, float(asked or 0)))
        last = self._last.get(host)
        if last is not None:
            wait = last + gap - self.clock()
            if wait > 0:
                await self.sleep(wait)
        self._last[host] = self.clock()

    async def _get(self, url: str, headers: dict[str, str]) -> httpx.Response:
        self.requests += 1
        return await self.client.get(
            url, headers={"User-Agent": USER_AGENT, **headers}, timeout=TIMEOUT, follow_redirects=True
        )

    async def _robots_for(self, url: str) -> RobotFileParser | None:
        """robots.txt for the URL's host, read once a night. None means we couldn't tell: nothing is
        fetched from that host tonight."""
        parts = urlsplit(url)
        host = (parts.hostname or "").lower()
        if host in self._robots:
            return self._robots[host]
        parser: RobotFileParser | None = RobotFileParser()
        try:
            r = await self._get(f"{parts.scheme}://{parts.netloc}/robots.txt", {})
            if r.status_code == 200:
                parser.parse(r.text.splitlines())
            elif r.status_code in (401, 403):
                parser.disallow_all = True
            elif 400 <= r.status_code < 500:
                parser.allow_all = True
            else:
                parser = None
        except httpx.HTTPError as e:
            log.info("robots.txt for %s unreachable: %s", host, e)
            parser = None
        self._robots[host] = parser
        self._last[host] = self.clock()
        return parser

    async def fetch(self, url: str, etag: str | None = None, last_modified: str | None = None) -> Page:
        page = Page(url=url)
        host = host_of(url)
        if not host or not url.startswith(("https://", "http://")):
            page.refused, page.error = "error", "not a web address"
            return page
        async with self._lock(host):
            robots = await self._robots_for(url)
            if robots is None:
                page.refused, page.error = "error", "robots.txt unreachable"
                return page
            if not robots.can_fetch(ROBOTS_AGENT, url):
                page.refused, page.error = "robots", "robots.txt disallows it"
                return page
            await self._wait_turn(host)
            headers = {
                "Accept": "text/html,application/xhtml+xml,text/calendar,application/json;q=0.9,*/*;q=0.5"
            }
            if etag:
                headers["If-None-Match"] = etag
            if last_modified:
                headers["If-Modified-Since"] = last_modified
            try:
                r = await self._get(url, headers)
            except httpx.HTTPError as e:
                page.refused, page.error = "error", f"{type(e).__name__}: {e}"[:300]
                return page
        page.status = r.status_code
        page.final_url = str(r.url)
        page.permanent_redirect = any(h.status_code in (301, 308) for h in r.history)
        page.content_type = r.headers.get("content-type", "").lower()
        page.etag = r.headers.get("etag")
        page.last_modified = r.headers.get("last-modified")
        if r.history and looks_like_login(page.final_url):
            page.refused, page.error = "login", f"redirects to a login at {page.final_url}"[:300]
            return page
        if page.final_url and host_of(page.final_url) != host:
            other = await self._robots_for(page.final_url)
            if other is None or not other.can_fetch(ROBOTS_AGENT, page.final_url):
                page.refused, page.error = (
                    "robots",
                    f"moved to {page.final_url}, where robots.txt says no"[:300],
                )
                return page
        if r.status_code in (401, 407):
            page.refused, page.error = "login", "asks for a login"
            return page
        if r.status_code == 403:
            # Forbidden to us: the site doesn't want to be read by a program, and we don't argue.
            page.refused, page.error = "robots", "403: the site turns automated readers away"
            return page
        if len(r.content) > MAX_BYTES:
            page.refused, page.error = "too_big", f"{len(r.content)} bytes"
            return page
        if r.status_code == 200:
            page.text = r.text
        return page
