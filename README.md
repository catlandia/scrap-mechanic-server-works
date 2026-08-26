# Server Works

A Scrap Mechanic **Custom Game** for hosting large building events — anti-grief that
does not need a host watching, plot ownership, per-plot rollback, and bans that
survive between events.

Built after a griefer wrecked builds two minutes before the end of a public stream
event on 2026-08-22.

---

## Status

**V56.** Seen working in game: lockdown, plot claiming and enforcement, the city
builder (up to 384 plots without denting a 40 Hz tick), snapshots, bans and the
allow list, the settings and city-layout panels, tool bans that hold, NOTlift
importing a creation, the Cleaner, the crowd-bot load harness, and the focus
marker.

Never run in a real event with real people. That is the honest headline, and
[`docs/STATUS.md`](docs/STATUS.md) is the ledger that keeps it honest — it
separates what has been *seen working*, what was seen broken and has a fix
nobody has re-tested, and what has never executed at all. `check_all.py` passing
is not evidence and that file says so.

- [`docs/NEXT.md`](docs/NEXT.md) — the handover: what to do next and why
- [`docs/STATUS.md`](docs/STATUS.md) — **the honest ledger.** Start here if you
  want to know what actually works
- [`docs/PLAN.md`](docs/PLAN.md) — the plan of record: goals, the measurement that
  reordered them, engine constraints, architecture, what is left
- [`docs/CHANGELOG.md`](docs/CHANGELOG.md) — every version and the bug it fixed
- [`docs/CROWD.md`](docs/CROWD.md) — testing with a lobby you do not have
- [`REVIEW.md`](REVIEW.md) — verified versus assumed, for a sceptical reader

---

## Why you can check this without trusting the author

Scrap Mechanic's Lua API is barely documented and the community wiki lags the game.
Most broken mods for this game are broken because someone guessed an API.

**Every engine fact used here is cited to a file in the installed game, or extracted
from the game executable's own string table.** The citations live in the code
comments next to the code that depends on them. If a citation is wrong, assume the
code above it is wrong too — that is the fastest way to audit this.

A sample you can verify in ten minutes against your own install:

| Claim the code depends on | Verify here |
|---|---|
| Body permissions are `setBuildable` / `setErasable` / `setDestructable` / … | `ChallengeData/Scripts/challenge/world_util.lua` → `restrictAllBodies()` |
| Vanilla re-asserts them across every body every tick at 40 Hz | `ChallengeData/Scripts/challenge/BuilderWorld.lua` → `server_onFixedUpdate` |
| Creative mode is a plain, subclassable Lua class | `Data/Scripts/game/CreativeGame.lua` |
| Creation export/import round-trips at world origin | `BuilderWorld.lua:189` exports, `:130` re-imports at `vec3.zero()` |
| Clearing a world is `shape:destroyShape()` over all bodies | `Data/Scripts/game/worlds/CreativeBaseWorld.lua:204` |
| 1 block = 0.25 m | `Data/Scripts/game/Lift.lua:299` → `self.liftPos * 0.25` |
| `sm.game` exposes no tickrate or timescale | `python dev/dump_api.py Game` |
| Lua cannot see a Steam ID | `python dev/dump_api.py Player`, and `grep -ri steam` over vanilla `.lua` returns nothing |

`dev/dump_api.py` recovers each module's real binding list for *your installed build*
by slicing the executable's string table between `wrap_<Module>.cpp` markers. Prefer
it over any documentation, including this file.

---

## What it does

| | |
|---|---|
| **Protection** | `/lockdown` freezes every build instantly. A grief alarm watches the world's total shape count and locks up on its own if blocks start vanishing — the engine fires no callback when a plain block is destroyed, so counting is the only way to notice. |
| **Plots** | A claimable grid (default 10×10 plots of 20×20 blocks, 1-block walkways). Neighbours can team up, which makes the walkway between them shared ground. |
| **Snapshots** | `/snapshot`, `/autosave N`, and `/restore <name> [plot]` — rebuild one plot without flattening the city. |
| **Identity** | Permanent ids, alias tracking, ban list and allow list, all persisted outside the save so they survive between events. |
| **Rules** | The event's posted rules as enforced numbers — joint budgets, bot and light caps, banned parts. Every number is a setting. |
| **Focus** | Point at somebody with the Focus tool, or pick them off a searchable list, and **everybody** gets a marker over them — drawn through walls at any distance, with their name under it and an icon on the compass. For a host saying "now look at this build" to a lobby of twenty. Host only, with no setting that opens it up. |
| **Events** | A clock with prep, build and buffer phases, each one snapshotting on the boundary and setting what may be built. |
| **Load testing** | `/crowd N` stands N dressed, wandering, plot-claiming bots on the city and `/bench` walks the count up while recording frame rate and tick rate. 128 of them never moved the tick rate off 40 Hz. |

Full command list: `/sw` in game. Server rules: `/rules`.

---

## Releasing a version

The mod revision lives in `VERSION`, **not** in `description.json` — the `version`
field there is the game *content* version and must stay `1`, or every world load
warns that the mod is out of date.

    python dev/make_preview.py --bump    # V2, V3... stamped onto mod/preview.jpg
    python dev/check_lua.py
    python dev/sync_mod.py

The version is on the thumbnail so a host can see which build a machine is running
from the Custom Game list, without opening a file.

## Install

    python dev/check_lua.py     # compile every script through a real Lua parser
    python dev/sync_mod.py      # copy mod/ into the game's Mods folder

Restart Scrap Mechanic → Play → Custom Game → **Server Works**.

`sync_mod.py` never overwrites `BanList.json`, `Players.json` or `Settings.json` —
those are written by the running game and are live data.

---

## Testing

The pass condition is **not** "it looks like it works". A Scrap Mechanic mod can
appear fine while throwing thousands of Lua errors a second — one session in this
project's own history produced a **1.79 GB log** and dragged the server from 40 Hz
to 11 Hz doing exactly that.

After any run:

    python dev/session_stats.py --spam

This reconstructs server tick rate and client frame rate from the log (every line is
stamped `HH:MM:SS (tick/frame)`) and ranks whatever is flooding it. A healthy run is
~40 tick/s and a log measured in kilobytes.

---

## Layout

    mod/
      description.json     Custom Game, version 1
      config.json          baseGameContent, game + player scripts
      Scripts/
        Game.lua           wiring, chat commands, timers        (largest, least tidy)
        World.lua          subclasses CreativeFlatWorld; stops explosion cratering
        Player.lua         subclasses CreativePlayer
        Protection.lua     the permission engine
        Plots.lua          grid, ownership, presence enforcement
        Identity.lua       perma ids, bans, allow list
        Snapshots.lua      capture and rollback
        Rules.lua          per-plot budgets and banned parts
        Settings.lua       one schema table drives /set and /settings

    dev/
      check_lua.py         syntax check via lupa
      sync_mod.py          repo -> Mods folder
      session_stats.py     tick/FPS + log spam analysis
      dump_api.py          per-module Lua bindings out of the executable

    CLAUDE.md              engine research and design decisions, with citations
    REVIEW.md              what is verified vs assumed; read before trusting anything

---

## Modifying it

**Adding a setting or a rule** is one row in `Settings.SCHEMA`. `/set` and
`/settings` pick it up automatically.

**Three constraints the engine imposes.** Most of the non-obvious design here comes
from these, and any change that ignores them will not work:

1. **Build permissions belong to the body, not the player.** There is no
   `setBuildableBy(player)`. "Only build on your own plot" therefore cannot be
   expressed directly — hence presence-based enforcement in `Plots.lua`.
2. **Nothing fires when a block is placed or destroyed.** State can only be held by
   re-asserting it, and destruction can only be noticed by counting.
3. **Log output is a performance cost.** Log state changes, never per body or per
   tick, and fault-latch anything inside a loop so a bug logs once and stops.

**Coding conventions** follow the game's own scripts: `sv_` / `cl_` prefixes, tabs,
`server_on*` overrides always call their parent. That last one is not style — a
Custom Game that overrides `server_onCreate` without calling up leaves
`g_unitManager` nil, and then every collision throws with a full traceback. That is
the 1.79 GB log.

Comments explain *why*, not *what* — an engine quirk, a workaround, a thing that
looks wrong and isn't.

---

## Licence

MIT. See [LICENSE](LICENSE).
