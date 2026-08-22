# Server Works — review notes

Written for someone who did not write this code and has no reason to trust it.
The owner cannot read Lua, so this exists so a programmer can judge it quickly
and so the owner can ask the right questions.

## Status, stated plainly

**2,638 lines of Lua. Written in one session. Never run once.**

It compiles under a real Lua parser (`python dev/check_lua.py`) and installs into
the game's Mods folder. That is the entire extent of the verification. Anything
below about behaviour is a claim, not a result.

If you are deciding whether to trust this in a live event: don't, yet. Run it in
an empty world first. The pass condition is not "it looks like it works" — it is
**the game log stays quiet**. See "How to check it" below.

## The thing worth checking first

Scrap Mechanic's Lua API is barely documented and the wiki lags the game. Most
bad mods for this game are bad because someone guessed an API and it half-worked.

So the standard applied here was: **every engine fact is cited to a file in the
installed game or to the executable's own string table.** Not to memory, not to a
wiki. The citations are in the code comments, and they are the thing to attack —
if a citation is wrong, the code above it is probably wrong too.

Examples you can verify in ten minutes against your own install:

| Claim | Where it came from |
|---|---|
| Body permissions are `setBuildable/setErasable/setDestructable/...` | `ChallengeData/Scripts/challenge/world_util.lua:restrictAllBodies()` |
| Vanilla sweeps every body every tick at 40 Hz | `ChallengeData/Scripts/challenge/BuilderWorld.lua:server_onFixedUpdate` |
| Creative mode is a subclassable Lua class | `Data/Scripts/game/CreativeGame.lua` |
| Creation export/import round-trips at world origin | `BuilderWorld.lua:189` exports, `:130` re-imports at `vec3.zero()` |
| Clearing a world is `shape:destroyShape()` over all bodies | `Data/Scripts/game/worlds/CreativeBaseWorld.lua:204` |
| 1 block = 0.25 m | `Data/Scripts/game/Lift.lua:299` — `self.liftPos * 0.25` |
| `sm.game` has no tickrate/timescale knob | `python dev/dump_api.py Game` |
| Lua cannot see a Steam ID | `python dev/dump_api.py Player`; also `grep -ri steam` over all vanilla `.lua` returns nothing |
| Custom Games use `"version": 1`, not 2 | histogram of `description.json` across 1205 workshop items |

`dev/dump_api.py` slices the executable's string table between `wrap_<Module>.cpp`
markers to recover each module's real binding list for the installed build. That
is reproducible and beats any external documentation.

## What is measured rather than claimed

One thing here is not a design opinion. `dev/session_stats.py` reconstructs server
tick rate and client frame rate from any Scrap Mechanic log, because every log line
is stamped `HH:MM:SS (tick/frame)`.

Run over the owner's existing logs:

- 19 players, 100 minutes: tick held at 39.9 median, never dropped below 90% of
  target in 86 sampled windows. Client FPS fell 60 → 31, correlated with time
  rather than player count.
- A single-player session collapsed to 11.6 Hz. That log is 1.79 GB — 1.45 M lines
  of a `print()` in a tick loop plus 58 K `g_unitManager` nil errors with full
  tracebacks.

Two consequences the code depends on, both checkable by re-running that script:

1. Player count was not the bottleneck; accumulated content and log spam were.
2. **Log spam is a performance bug.** Hence the rule throughout: log state changes,
   never per-body or per-tick, and fault-latch anything that could log in a loop.

## Assumed, not verified — attack these first

Ranked by how much damage being wrong would do.

1. **`baseGameContent: "Survival"` combined with a `CreativeGame` subclass.**
   No Workshop custom game pairs those; they use Survival+SurvivalGame or
   Creative+their own class. If the world fails to load, this is why. Fallback is
   `"Creative"` in `config.json`, losing survival parts.
2. **`sm.creation.importFromString`'s last two arguments.** Vanilla passes
   `true, true` in `BuilderWorld` and only five arguments in `MenuWorld`. The
   meaning is not documented and was not derivable from binding names. This is the
   restore path — if it is wrong, rollback produces garbage.
3. **`sm.json.save` writing into an installed mod's directory at runtime.** All
   persistence (bans, plots, settings, snapshots) assumes this works. A Workshop
   install is also replaced wholesale on update, so the master ban list should
   live outside the mod regardless.
4. **`sm.tool.forceTool(nil)` called from a Game client script.** Vanilla only
   calls it from tool scripts and the LogBook.
5. **`character:setWorldPosition()` for pushing intruders off plots.** May fight
   the physics or the client's own prediction.

Every one of these is wrapped in `pcall` and logs once rather than per tick. That
is damage control, not correctness.

## Known holes, by design

- **Plot enforcement leaks at the edges.** A plot locks when an unauthorised
  player stands *in* it. Someone on the walkway can still reach a short way over
  the 1-block gap. Widening the check to the walkway would lock plots every time
  anyone walked past, which is worse. The grief alarm and per-plot restore cover
  what gets through.
- **Bans key on display name.** The engine exposes no Steam ID to Lua, so a
  rename defeats a ban until a companion tool (reading Steam IDs out of the game
  log) resolves it. **The allow list is the real answer** and is why it exists.
- **`maxlights` is not airtight.** The uuid list covers vanilla lights; any
  Blocks-and-Parts mod can add more.
- **Explosive consumables (cornades) cannot be removed.** They are not tools, so
  `forceTool` does not reach them. They are damage-neutralised, not absent.
  Removing them needs our own `Objects` database — a content change.
- **No per-plot cap on plain blocks.** Budgets count joints, bots and lights.

## Architecture, in one paragraph each

- **Protection** — holds a permission profile over every body. The engine fires
  no callback when a block is placed, so state can only be held by re-asserting
  it. One immediate full sweep on mode change (so lockdown is instant), then an
  amortised patrol of 128 bodies/tick that skips bodies already correct via two
  getters. Deliberately not vanilla's every-body-every-tick sweep.
- **Plots** — a grid in block coordinates. Permissions belong to bodies, not
  players, so ownership is enforced by presence: a zone is open only while
  everyone standing in it is authorised. Unbuildable ground is `sweep`
  (erasable, not buildable) so junk dumped there never becomes permanent.
- **Identity** — perma ids assigned locally, aliases accumulated, ban and allow
  lists persisted outside the save so they survive between events.
- **Snapshots** — export every creation to JSON, restore by re-importing at world
  origin. Amortised both ways. Records which plot each creation was on so a single
  plot can be repaired without flattening the city.
- **Rules / Settings** — the event's posted rules as enforced numbers. One schema
  table drives `/set` and `/settings`; adding a rule is one row.
- **Game** — wiring, chat commands, timers. 934 lines and the least tidy file
  here; the command dispatch is a long if/elseif chain and would be the first
  thing to refactor.

## How to check it

    python dev/check_lua.py     # compiles every script through a real Lua parser
    python dev/sync_mod.py      # repo -> game Mods folder, preserves live data
    python dev/session_stats.py --spam    # tick/FPS + what is flooding the log

After any test run, the log is the verdict. A mod can look fine while throwing
thousands of errors a second — that is exactly what happened to the 1.79 GB log.

## Honest summary

The engine research is solid and independently checkable; that part is not
guesswork. The code is readable, commented with *why* rather than *what*, and
fails back to vanilla rather than locking a world open or shut.

It has also never executed. Until it has, treat all of it as a proposal.
