# Let's Go

Pokémon Go for hanging out. A live night map of what's happening within walking distance — pickup games, runs, backyard sets, game nights — and neighbors selling what they're good at cooking, out of their own houses. Wren, the AI, learns what you actually show up for and tells you what's worth leaving the house for.

Working name. The mocks this was built from: https://claude.ai/artifact/WxbnSewLmj7KwW69GwS1ys (direction A's map with C's Wren line).

## What's in it

**LIVE. MORE.** A social app boosted by AI: it's about getting out and being with people, not about time on the screen, and Wren does the logistics so you can go. It opens on the map, and the first launch opens on the line it's named for (Dostoevsky, *Demons*), clause by clause. Passport → *Read the quote again* brings it back. Designs: https://claude.ai/artifact/VrtFdCRFcZzKaV6f2vJ4AE.

- **Map (the opening screen)** — *Afterglow*: a night-tinted map with glowing pins for everything on in the next three hours. Pins pulse while they fill, faster the fuller they get, with a count on each ("4/6", "16 left"); a dashed ring marks a 10-minute walk. Wren's line sits on a glass sheet at the bottom: the one thing worth going to, why, when to leave, and *I'm in* right there; *Not tonight* moves on to the next. Filters: Now, Tonight, Weekend, kinds of thing, Free. Drag the sheet up (or tap search) for the whole list. Walk view still tilts the map into the street.
- **Quick pick** — the *Signal* look as a filter mode: black and lime, the top three numbered on the map with real walking routes, *leave by* times, and a ruler of the next five hours you can drag to look ahead.
- **People** — your friends on a small night map; your **porch light** ("up for something", on for two hours, seen only by friends); who's **out now** (from what they joined: checked in, or heading to something that starts soon) with *Join*; porch lights on with *Wave*; things friends asked you along to; and **crews**. You add a friend by trading a one-use code (good for a week). Friends show on the main map too, and *Friends · N* filters to what they're going to. Until you have real friends, sample ones (all marked Sample) are placed on the best things near you.
- **Who's in** — a gathering's page shows a seat per spot as people say they're in, your friends ringed in green, your seat waiting ("You?"), and Wren's walk: if a friend is on the way, it routes you past them so you walk in together (`MeetUp`). *Bring someone* asks friends along.
- **Plans** — what you've said yes to (gatherings, pickups), then what used to be Today: the one pick, what starts in the next hour, what's within a 15-minute walk, the week's real listings day by day (weeks start Monday), places from the city list, and kitchens with a drop coming. Sunset time is worked out on the phone (`Sun`).
- **Passport** — show-ups, kitchens tried, *Know your city: SF 50* (fifty places every San Franciscan should go once, `sf_places.json`, closest first, with progress by kind; each place has a page, and checking in within 200 m stamps it), stamps, and everything Wren believes about you, deletable. Settings live at the bottom.
- **Wren** — the round button at the end of the tab bar. One sentence in ("something with Maya and Theo Saturday") and Wren works it out in front of you, a check at a time: when everyone's free, the day (and sunset), what's worth going to, a kitchen slot and the walks. Then a plan: food first if a kitchen has a batch, somewhere outside for sunset if it falls in between, the thing itself. *Ask Maya and Theo* holds your spot, sends the invites and opens **"Saturday, sorted."**: the stops on a map with the walks drawn, the timeline with when to leave, who's in, *Hold the 4:30 slot* for the kitchen, and Wren's note. Refine with *Add Jun*, *Done by 9*, *Free only*, or *Another*. Plans you send show at the top of Plans. A mood ("something chill tonight under $15") gets real nearby options; "host a slow jog sat 8am" gets a draft to post. The plan and picks always come from plain types (`PlanRequest`, `Planner`, `Wren`); with Apple Intelligence on the phone, the on-device model (FoundationModels) rewrites Wren's sentence around them.
- **Out in the world** — checking in opens **You're here**: a clock of how long you've been out tonight, who's with you, how far you've walked, how little you've had Let's Go open, and *Go dark until 11* (a black screen with a dim clock; that time doesn't count as phone time). **Eyes up** (*Walk* on a gathering you're in, or *Walk there* on a plan's stop) gets Apple Maps walking directions and buzzes at each turn: one for left, two for right, three when you're here. *Pocket it and go* turns on the proximity sensor so the screen goes off in a pocket while the app keeps guiding. The next morning, **the morning after** shows last night as a ribbon of where you were, phone time out of the whole night, hours out, who you were with, the walk and the stamps. Passport keeps a link to the latest one. All of this stays on the phone (`Night`).
- **Third time's a friend** — after three real check-ins at the same things (never likes, follows or scrolling), Wren offers a mutual intro on People (and the morning after). Both say hi and you're friends; if only one does, the other hears nothing. *Met* on People lists them.
- **The shared table** — a kitchen with porch seating shows its garage with the door up and the porch table for the next drop: seats filling, friends ringed with when they sit down, your open seat, and *Sit with Maya · 7:15* (the order opens on that slot with the porch on).
- **Passport with people** — nights out, people, Know your city; *Most nights with*; and every night as a stamp: the date as a seal, where, and who with.
- **Gatherings** — headcount, what to bring, who runs it. Join, and check in when you're physically within 200 m to collect a stamp. Host your own from the + button or by telling Wren.
- **Kitchens** — a page per home kitchen with its drop (a fixed batch at a set time), menu and reviews. Reserve a pickup slot or a porch seat; the pickup spot unlocks after you reserve. Mark it picked up, leave a review; three visits makes you a regular.
- **Your kitchen** — open one, keep a menu, post drops, see what sold. Permit checklist (MEHKO in California).

Everything is on-device (SwiftData) for now. Until real neighbors post, a **sample neighborhood** is placed around you, every item tagged *Sample*; turn it off at the bottom of Passport.

## Backend

`backend/` is a FastAPI + Postgres API for the shared version: device accounts with bearer tokens, `/v1/nearby` (gatherings and kitchens around a point), hosting, joining and **server-checked check-ins** (within 200 m, from 30 min before start), kitchens with menus and drops, and **orders that can't oversell** (the drop row is locked while stock and the 15-minute slot are checked; a retried request with the same `client_id` returns the same order). Pickup notes only go to the cook and to people with an order. Reviews only after pickup, one per order. **People** (`/v1/people`, `/v1/friends/…`, `/v1/me/porch-light`, `/v1/crews`, `/v1/gatherings/{id}/invites`): friends by one-use code, porch lights and waves seen only by friends, who's out from what they joined (nobody is tracked), crews of friends, invites to gatherings; a gathering lists which of *your* friends are in, never anyone else's names. **Intros** (`/v1/intros/{id}/hi`, `/not-now`): offered after three shared check-ins, mutual, and silent until both say hi. Kitchen detail has the porch **table** for the next drop (seats, porch orders, friends at it).

```bash
docker compose up                                   # api on :8100, Postgres on :5433
docker compose run --rm --no-deps api pytest -q
```

**Listings** (`/v1/listings?city=sf`, no account needed) are the real city: shows, markets, weekly regulars, in the same shape as the app's `sf_happenings.json`. The phone fetches them on launch and when it comes back, keeps the last copy for offline, and falls back to the bundled file before its first fetch. Load or refresh them with:

```bash
cd backend && python -m app.listings_import ../ios/LetsGo/Resources/sf_happenings.json              # local
DATABASE_URL=<Railway Postgres public URL> python -m app.listings_import ../ios/LetsGo/Resources/sf_happenings.json  # deployed
```

Rows match on city, title and venue; ones the file no longer has are marked gone. Until the import runs, the phone also shows bundled listings the server doesn't have yet (same title and venue counts as the same listing). `/v1/listings` also carries the city catalog's dated events for the next two weeks (below), so phones that only read listings get the real city without an app update.

**The city catalog** (`backend/app/catalog/`): one row per real event, wherever it was found, shared by everyone. Designs: https://claude.ai/artifact/9sqMbPBjTVYTRjuAb2tkCU.

- **Feeds, every night.** Funcheap (schema.org Event data on its day pages), 19hz (club nights, door deals) and DataSF's Mobile Food Schedule (permitted trucks and carts). The API process sweeps by itself: within a minute of a deploy with an empty catalog, then nightly after 4 AM Pacific (`app/catalog/scheduler.py`, one replica at a time by advisory lock). By hand: `python -m app.catalog.sweep --days 7`.
- **The resolver** is plain code: same venue, same night, starts within 45 minutes, titles that mostly agree → one event with several sources. A cancel from any source marks it. Venues are placed once, from known venues, the city's address register (DataSF EAS) or its street centerlines for corners, and reused.
- **`/v1/discover?lat&lon&q|intent&day&free&near`** answers from the catalog. A coarse intent (`comedy`, `jazz`, `trucks`, … in `app/catalog/intents.py`) plus a ~5 km² H3 cell plus the night is the key the coverage ledger is kept by. Covered and fresh → `hit`. Not covered, signed in, with a key and budget → it claims one **scout run** and answers `searching`; anyone asking meanwhile joins that run. Poll `/v1/discover` again or `/v1/scout/runs/{id}`.
- **The scout** is Claude Opus 5.5 with web search, web fetch, `catalog_search` (what we already have) and `propose_events` (strict schema, the only way anything gets written). Code checks every proposal (public link, nothing private, on the night asked) before the resolver sees it. Server-side refusal fallbacks are on. Budget per city per day and five runs per person per hour.
- **Private stays private.** The catalog never says who asked. `finds` (what your asks put on the map first, `/v1/me/finds`) and `scout_quota` (a counter) are the only person-linked tables.

Settings (Railway service variables): `ANTHROPIC_API_KEY` turns the scout on (without it the catalog still answers, it just never searches), `SCOUT_DAILY_BUDGET_USD` (40), `SCOUT_RUNS_PER_HOUR` (5), `CATALOG_SCHEDULER` (on; set `0` for one-off scripts).

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

Ship a TestFlight build from GitHub: **Actions → "iOS CD — TestFlight" → Run workflow** (or `gh workflow run ios-cd.yml -R yasser100ali/lets-go`). It runs the tests, then archives, signs and uploads on the Mac mini's Let's Go runner (`~/actions-runner-letsgo`, label `letsgo`, next to Pulse's), and waits for Apple to finish processing. Internal testers get it automatically.

From this Mac directly:

```bash
scripts/ship.sh
```

Both need, outside the repo: the App Store Connect key at `~/.appstoreconnect/letsgo_asc_api_key.json` (+ `private_keys/AuthKey_*.p8`), and the signing bundle in `~/.appstoreconnect/letsgo-signing/` (Let's Go's own Apple Distribution cert, its keychain password and the App Store profile). On a new Mac run `scripts/setup-signing.sh` once.
