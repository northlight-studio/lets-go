# Let's Go

Pokémon Go for hanging out. A live map of what's happening within walking distance — pickup games, runs, backyard sets, game nights — and neighbors selling what they're good at cooking, out of their own houses. Wren, the AI, learns what you actually show up for and tells you what's worth leaving the house for.

Working name. The mocks this was built from: https://claude.ai/artifact/WxbnSewLmj7KwW69GwS1ys (direction A's map with C's Wren line).

## What's in it

**LIVE. MORE.** A social app boosted by AI: it's about getting out and being with people, not about time on the screen, and Wren does the logistics so you can go. It opens on the map, and the first launch opens on the line it's named for (Dostoevsky, *Demons*), clause by clause. Passport → *Read the quote again* brings it back. Designs: https://claude.ai/artifact/VrtFdCRFcZzKaV6f2vJ4AE.

- **Map (the opening screen)** — *Daylight map*: MapKit's own standard map, edge to edge and kept quiet, light by day and the evening map after dark (it follows the phone's appearance, the way Maps does). Over it, the system's Liquid Glass: a search capsule ("Tonight, nearby"), a filter button, and chips (Now, Tonight, Weekend, Free, Food, Music, Friends). Pins are small circles in their kind's colour (music orange, food green, the rest the compass's blue) with a glyph and a soft halo; they pulse while they fill, faster the fuller they get, with a count on each ("4/6", "16 left"). A dotted yellow ring marks a 10-minute walk, and the route to Wren's pick is drawn in yellow. Wren's pick sits on a glass sheet at the bottom: the title, "4 of 6 in · 6-minute walk · leave by 6:40", who's in, and *I'm in* right there; *Not tonight* moves on to the next. Filters: Now, Tonight, Weekend, kinds of thing, Free. Drag the sheet up (or tap search) for the whole list. Walk view still tilts the map into the street.
- **Quick pick** — from the map's filter button, the *Signal* look (left as it was, dark whatever the phone's appearance): black and lime, the top three numbered on the map with real walking routes, *leave by* times, and a ruler of the next five hours you can drag to look ahead.
- **People** — your friends on a small map; your **porch light** ("up for something", on for two hours, seen only by friends); who's **out now** (from what they joined: checked in, or heading to something that starts soon) with *Join*; porch lights on with *Wave*; things friends asked you along to; and **crews**. You add a friend by trading a one-use code (good for a week). Friends show on the main map too, and *Friends · N* filters to what they're going to. With no friends yet, People says so and offers *Add a friend*.
- **Who's in** — a gathering's page opens on the map fading into the page, under glass back and share buttons: when ("Thursday · 6:45 PM"), the title, where and the walk, then a seat per spot as people say they're in, your friends ringed in green and your seat waiting in yellow ("You?"). If a friend is on the way, a card says so ("Maya's on the way") with *Walk with Maya* and *Just go*: Wren routes you past them so you walk in together (`MeetUp`, words in `GatheringCopy`). *Bring someone* asks friends along.
- **Plans** — what you've said yes to (gatherings, pickups), then what used to be Today: the one pick, what starts in the next hour, what's within a 15-minute walk, the week's real listings day by day (weeks start Monday), places from the city list, and kitchens with a drop coming. Sunset time is worked out on the phone (`Sun`).
- **Passport** — show-ups, kitchens tried, *Know your city: SF 50* (fifty places every San Franciscan should go once, `sf_places.json`, closest first, with progress by kind; each place has a page, and checking in within 200 m stamps it), stamps, and everything Wren believes about you, deletable. Settings live at the bottom.
- **Wren** — the round button at the end of the tab bar. One sentence in ("something with Maya and Theo Saturday") and Wren works it out in front of you, a check at a time: when everyone's free, the day (and sunset), what's worth going to, a kitchen slot and the walks. Then a plan: food first if a kitchen has a batch, somewhere outside for sunset if it falls in between, the thing itself. *Ask Maya and Theo* holds your spot, sends the invites and opens **"Saturday, sorted."**: the stops on a map with the walks drawn, the timeline with when to leave, who's in, *Hold the 4:30 slot* for the kitchen, and Wren's note. Refine with *Add Jun*, *Done by 9*, *Free only*, or *Another*. Plans you send show at the top of Plans. A mood ("something chill tonight under $15") gets real nearby options; "host a slow jog sat 8am" gets a draft to post. The plan and picks always come from plain types (`PlanRequest`, `Planner`, `Wren`); with Apple Intelligence on the phone, the on-device model (FoundationModels) rewrites Wren's sentence around them.
- **Out in the world** — checking in opens **You're here**: a clock of how long you've been out tonight, who's with you, how far you've walked, how little you've had Let's Go open, and *Go dark until 11* (a black screen with a dim clock; that time doesn't count as phone time). **Eyes up** (*Walk* on a gathering you're in, or *Walk there* on a plan's stop) gets Apple Maps walking directions and buzzes at each turn: one for left, two for right, three when you're here. *Pocket it and go* turns on the proximity sensor so the screen goes off in a pocket while the app keeps guiding. The next morning, **the morning after** shows last night as a ribbon of where you were, phone time out of the whole night, hours out, who you were with, the walk and the stamps. Passport keeps a link to the latest one. All of this stays on the phone (`Night`).
- **Third time's a friend** — after three real check-ins at the same things (never likes, follows or scrolling), Wren offers a mutual intro on People (and the morning after). Both say hi and you're friends; if only one does, the other hears nothing. *Met* on People lists them.
- **The shared table** — a kitchen with porch seating shows its garage with the door up and the porch table for the next drop: seats filling, friends ringed with when they sit down, your open seat, and *Sit with Maya · 7:15* (the order opens on that slot with the porch on).
- **Passport with people** — nights out, people, Know your city; *Most nights with*; and every night as a stamp: the date as a seal, where, and who with.
- **Gatherings** — headcount, what to bring, who runs it. Join, and check in when you're physically within 200 m to collect a stamp. Host your own from the + button or by telling Wren.
- **The lamppost poster** — host something (tick *Every week* for a weekly one) and *Make a poster* on its page: "EVERY THURSDAY · 6:30", the big title, a line, a QR code ("Scan to say you're in. No app needed."), and tear-off tabs with the short link, on off-white paper. Preview, Letter or A4, then print (AirPrint) or share the PDF or the link. Only for a real gathering you host that lives on the server. Names from the web show to you alone (*From your poster: Maya, Ben*). *Take the poster down* stops its page taking sign-ups. Laid out in `PosterView`, words and rules in `PosterCopy`.
- **Kitchens** — a page per home kitchen with its drop (a fixed batch at a set time), menu and reviews. Reserve a pickup slot or a porch seat; the pickup spot unlocks after you reserve. Mark it picked up, leave a review; three visits makes you a regular.
- **Your kitchen** — open one, keep a menu, post drops, see what sold. Permit checklist (MEHKO in California).

Everything is on-device (SwiftData), with the server's copy pulled in when there is one. Nothing on the map is made up: in San Francisco it's the city's real listings (`sf_happenings.json`, below) plus what people host; elsewhere there are no listings yet, and the map says *Let's Go only knows San Francisco so far*. Screens with nothing real to show say so (no friends yet, no kitchens nearby yet, nothing on your list yet) and offer the way to start. Older versions placed a made-up sample neighborhood around you; the first launch of this one deletes whatever it left (`SamplePurge`, through `Ledger`).

**Nothing old on the map.** Anything that has ended is off the map, the lists, Wren's pick and Plans' upcoming sections; something on now stays until it ends (`Upcoming`, tested in `UpcomingTests`). Once over, what you joined, checked in to or host stays in the store for your history (Passport, the morning after); everything else is deleted. The app prunes on launch, on coming back, and while it's open: when the next thing on show ends, and at midnight, when weekly listings roll on to a new day.

## The look

*Daylight map* on native Liquid Glass (designs: https://claude.ai/artifact/M7isgVthT1hvgCR8WBgiFj, "Let's Go", "Daylight map"). The app follows the phone's light and dark. Light: paper #EFEDE6, ink #1B231E, secondary #5F6A62, white cards. Dark: trail green #0C1D15, ink #F3F0E4, secondary #A7B5AA, glass over the map. The compass icon's yellow (#F2A516 light, #F5B82E dark, dark ink on it) is the one prominent button a screen, the selected chip, the walk ring and the route. Chrome is the system's own glass: the floating tab bar with Wren in the search circle, glass toolbar buttons, `.glassProminent` / `.glass` buttons, glass sheets. The system face throughout. Colours live in `Design/Theme.swift`.

## Backend

`backend/` is a FastAPI + Postgres API for the shared version: device accounts with bearer tokens, `/v1/nearby` (gatherings and kitchens around a point), hosting, joining and **server-checked check-ins** (within 200 m, from 30 min before start), kitchens with menus and drops, and **orders that can't oversell** (the drop row is locked while stock and the 15-minute slot are checked; a retried request with the same `client_id` returns the same order). Pickup notes only go to the cook and to people with an order. Reviews only after pickup, one per order. **People** (`/v1/people`, `/v1/friends/…`, `/v1/me/porch-light`, `/v1/crews`, `/v1/gatherings/{id}/invites`): friends by one-use code, porch lights and waves seen only by friends, who's out from what they joined (nobody is tracked), crews of friends, invites to gatherings; a gathering lists which of *your* friends are in, never anyone else's names. **Intros** (`/v1/intros/{id}/hi`, `/not-now`): offered after three shared check-ins, mutual, and silent until both say hi. Kitchen detail has the porch **table** for the next drop (seats, porch orders, friends at it).

```bash
docker compose up                                   # api on :8100, Postgres on :5433
docker compose run --rm --no-deps api pytest -q
```

**Posters** (`POST /v1/gatherings/{id}/poster`, `DELETE /v1/posters/{code}`, and the public page at `/p/{code}`): one six-character code per gathering (lowercase, no 0/1/i/l/o, so it can be typed off a tab). Scanning it opens a plain HTML page, no app and no account: what, when (in the host's time zone), where, how many are in and how many spots are left, and *I'm in* with a first name. The page shows counts, never names; the first name goes only to the host (`web_names` on the host's copy of the gathering). Web sign-ups count in `going` and against capacity. Abuse: one per browser (a cookie), at most half of a capped gathering's spots (25 for an open one) so the rest stay for the app, three per network per gathering and six per network per hour (salted IP hashes, counted even after someone backs out), and a honeypot field. A weekly gathering's poster moves on to next week's when the last one ends (a fresh gathering with only the host in, same local time across daylight saving), on the next scan or within 15 minutes from the scheduler, so the paper keeps working. Settings: `PUBLIC_BASE_URL` (what the link and tabs say; point a short domain at the API and set it here to shorten the tabs), `APP_DOWNLOAD_URL` (the page's *Get Let's Go* button; without it, the page says to ask the host for an invite), `WEB_IP_SALT`, `TRUSTED_PROXY_HOPS` (1 behind Railway's edge).

**Listings** (`/v1/listings?city=sf`, no account needed) are the real city: shows, markets, weekly regulars, in the same shape as the app's `sf_happenings.json`. The phone fetches them on launch and when it comes back, keeps the last copy for offline, and falls back to the bundled file before its first fetch. The bundled file is researched by hand from real event pages (each entry has its page in `url` and a `confidence`): weekly regulars, which are spot-checked against their pages and dropped when they end, and dated one-offs a few weeks ahead, which are dropped once their day has passed. Weekly entries are `{"weekday", "start", "end"}`, dated ones `{"date", "start", "end"}`, 24-hour local time, `end` null when the page doesn't say. Load or refresh them with:

```bash
cd backend && python -m app.listings_import ../ios/LetsGo/Resources/sf_happenings.json              # local
DATABASE_URL=<Railway Postgres public URL> python -m app.listings_import ../ios/LetsGo/Resources/sf_happenings.json  # deployed
```

Rows match on city, title and venue; ones the file no longer has are marked gone. Until the import runs, the phone also shows bundled listings the server doesn't have yet (same title and venue counts as the same listing). `/v1/listings` also carries the city catalog's dated events for the next two weeks (below), so phones that only read listings get the real city without an app update.

**The city catalog** (`backend/app/catalog/`): one row per real event, wherever it was found, shared by everyone. Designs: https://claude.ai/artifact/9sqMbPBjTVYTRjuAb2tkCU, and the events engine (learn the city's sources, read them every night): https://claude.ai/artifact/CTFovF4BciY4ePC8TnaZKp (option C).

- **Feeds, every night.** Funcheap (schema.org Event data on its day pages), 19hz (club nights, door deals) and DataSF's Mobile Food Schedule (permitted trucks and carts). The API process sweeps by itself: within a minute of a deploy with an empty catalog, then nightly after 4 AM Pacific (`app/catalog/scheduler.py`, one replica at a time by advisory lock). By hand: `python -m app.catalog.sweep --days 7`.
- **The resolver** is plain code: same venue, same night, starts within 45 minutes, titles that mostly agree → one event with several sources. A cancel from any source marks it. Venues are placed once, from known venues, the city's address register (DataSF EAS) or its street centerlines for corners, and reused.
- **`/v1/discover?lat&lon&q|intent&day&free&near`** answers from the catalog. A coarse intent (`comedy`, `jazz`, `trucks`, … in `app/catalog/intents.py`) plus a ~5 km² H3 cell plus the night is the key the coverage ledger is kept by. Covered and fresh → `hit`. Not covered, signed in, with a key and budget → it claims one **scout run** and answers `searching`; anyone asking meanwhile joins that run. Poll `/v1/discover` again or `/v1/scout/runs/{id}`.
- **The scout** runs on OpenAI's Responses API the way Pulse's AI does: every call goes through `app/llm.py` (`llm.create`, with a `letsgo:<surface>:v<n>` prompt-cache key), on `AI_MODEL` (gpt-6-luna), with the hosted `web_search` tool plus `catalog_search` (what we already have) and `propose_events` (strict schema, the only way anything gets written). Code checks every proposal (public link, nothing private, on the night asked) before the resolver sees it. Budget per city per day and five runs per person per hour. When it found events on a venue's own calendar page (`calendar_url` in its proposals), that page joins the source list.
- **The source list** (`app/catalog/sources/`, table `sources`): where the city actually publishes what's on — venue calendars, clubs, bookstores, breweries, run clubs, museums, organizers — plus the three feeds as rows. Each row has its URL, kind, venue or organizer, how it's read (`ical`, `jsonld`, `rss`, `squarespace`, `tribe` for WordPress's The Events Calendar, `html` for the model, `feed`, or `auto` until it's learned), who added it (`seed`, `scout`, `finder`, `hand`), last fetch, content hash, events found last time, and health (`ok`, `moved`, `broken`, `empty` for three weeks, `blocked` by robots.txt, a 403 or a login). It starts from every distinct venue or organizer page in `ios/LetsGo/Resources/sf_happenings.json` (202 today; Funcheap and 19hz pages are left to their feeds), built into `seed_sources.json` with `python -m app.catalog.sources seed-build ../ios/LetsGo/Resources/sf_happenings.json` and topped up every night. Event pages on one site that lead to the same calendar file collapse into one source.
- **The reader, every night after the feeds.** Plain code fetches every source (user agent `LetsGoReader`, robots.txt obeyed, one request at a time per host with three seconds between, conditional requests, no cookies; a redirect to a login is a closed door). A new source is learned on its first read: a calendar file it links to, a known calendar platform, or schema.org events on the page. Unchanged pages (304, or the same hash of what was read off them) are skipped. Structured formats are parsed by code. Only a changed page with no structure goes to the model: `llm.create` on `AI_MODEL` with `prompt_cache_key` `letsgo:reader:v1`, no tools, a strict JSON schema, the page passed as data between markers, and the scout's code checks on every event. Everything goes through the resolver; a code-read page that drops an upcoming event marks it gone. Its spend counts against the same daily budget as the scout, and a page the budget can't cover waits for the next night. Each night is a `reader_nights` row (sources read, changed, events new, updated, canceled, gone, cost).
- **The hourly re-check.** Once an hour the sources of everything starting in the next six hours are read again (and today's Funcheap and 19hz pages), so a cancellation before doors shows.
- **The source finder** is the scout in another mode: neighborhood × kind of place, the hosted `web_search` tool and one strict `propose_sources` function (`letsgo:finder:v1`). It adds calendar pages, never events. A seventh of the 24 × 9 grid a night for the first week, then weekly for the cells that still have fewer than three sources. Its runs are scout runs (`src:<kind>`), counted in the same budget.
- **Health and numbers.** `GET /v1/admin/sources` with `X-Admin-Token` (or `python -m app.catalog.sources report`): counts by health, reader and origin, every source that's moved, broken, empty or blocked, last night's and the last re-check's numbers, the finder's week, and today's AI spend. `python -m app.catalog.sources dry-run` fetches and parses the seed without writing anything.
- **Nothing old.** Anything that's ended (its end, or three hours after a start with no end) never comes back from `/v1/listings` or `/v1/discover`; a listing keeps only its dates still to come.
- **Private stays private.** The catalog never says who asked. `finds` (what your asks put on the map first, `/v1/me/finds`) and `scout_quota` (a counter) are the only person-linked tables.

Settings (Railway service variables): `OPENAI_API_KEY` turns the scout on (the same key Pulse uses; without it the catalog still answers, it just never searches), `AI_MODEL` (gpt-6-luna), `SCOUT_REASONING_EFFORT` (medium), `SCOUT_DAILY_BUDGET_USD` (40), `SCOUT_RUNS_PER_HOUR` (5), `READER_REASONING_EFFORT` (low), `READER_MODEL_PAGES` (150 a night), `FINDER_ENABLED` (on), `FINDER_RUNS_PER_NIGHT` (0 = a seventh of the grid), `ADMIN_TOKEN` (turns `/v1/admin/*` on), `CATALOG_SCHEDULER` (on; set `0` for one-off scripts).

Schema changes go through Alembic (`alembic revision --autogenerate`, then read it). CI runs lint, `alembic check` and the tests.

The app talks to it when it has a server address: under **Passport → Server** (an ngrok URL to your Mac works), `LETSGO_API` in the Xcode scheme, or `APIConfig.deployed` once there's a real deployment. With no address it runs on the phone's own data, as before. Things from the server are pulled into the on-phone store on launch, on returning to the app and when you move; joining, check-ins, hosting, kitchens, drops, orders and reviews go to the server first when the thing lives there.

iOS integration tests against a running backend:

```bash
TEST_RUNNER_LETSGO_API=http://localhost:8100 xcodebuild test -project ios/LetsGo.xcodeproj -scheme LetsGo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Deployed on Railway: project **lets-go**, services `api` (this Dockerfile; runs `alembic upgrade head` on start) and `Postgres`, at https://api-production-658b9.up.railway.app. Every merge to `main` that passes backend-ci deploys it (`.github/workflows/backend-cd.yml`, needs the `RAILWAY_TOKEN` repo secret); by hand, `railway up --service api` from `backend/`. The app uses it by default (`APIConfig.deployed`); Passport → Server overrides it.

## Not yet

- Payments — you pay the cook at pickup.
- Sign in with Apple, push notifications, Live Activities.

## Layout

```
ios/
  project.yml          XcodeGen spec — the source of truth for the project
  LetsGo.xcodeproj     generated; commit it, but change project.yml, then `xcodegen generate`
  Config.xcconfig      bundle id, team, version, build number
  LetsGo/              app sources (synced folder: new files are picked up automatically)
  LetsGoTests/         Swift Testing
backend/               FastAPI + SQLAlchemy async + Alembic
docker-compose.yml     local api (:8100) + Postgres (:5433)
scripts/
  ship.sh              archive → sign → upload to TestFlight (build number from App Store Connect)
  asc.py               App Store Connect API: app record, testers, build status
  setup-signing.sh     rebuild the prompt-free signing keychain on a new Mac
```

## Run

```bash
cd ios && xcodegen generate   # only after editing project.yml
open ios/LetsGo.xcodeproj
```

Tests:

```bash
xcodebuild test -project ios/LetsGo.xcodeproj -scheme LetsGo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO
```

Ship a TestFlight build from GitHub: **Actions → "iOS CD — TestFlight" → Run workflow** (or `gh workflow run ios-cd.yml -R northlight-studio/lets-go`). It runs the tests, then archives, signs and uploads on the Mac mini's Let's Go runner (`~/actions-runner-letsgo`, label `letsgo`, next to Pulse's), and waits for Apple to finish processing. Internal testers get it automatically.

From this Mac directly:

```bash
scripts/ship.sh
```

Both need, outside the repo: the App Store Connect key at `~/.appstoreconnect/letsgo_asc_api_key.json` (+ `private_keys/AuthKey_*.p8`), and the signing bundle in `~/.appstoreconnect/letsgo-signing/` (Let's Go's own Apple Distribution cert, its keychain password and the App Store profile). On a new Mac run `scripts/setup-signing.sh` once.
