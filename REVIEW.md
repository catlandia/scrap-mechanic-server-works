# Server Works — review notes

Written for someone who did not write this code and has no reason to trust it.
The owner cannot read Lua, so this exists so a programmer can judge it quickly
and so the owner can ask the right questions.

## Status, stated plainly

**~5,000 lines of Lua across 14 scripts. V24. Tested in game across 24 builds.**

Proven working in a real session: `/lockdown`, the clay gun cannot fire, the city
builds, `sm.json` persistence, explosives and fire genuinely off, mod content
updates reaching the game.

Proven outside the game, by executing the mod's own Lua through `lupa`: the city
geometry is a partition over twelve configurations, and 22 checks over settings,
identity, protection profiles and plot rules. See "How to check it" below.

Still unconfirmed in game: the V24 lift fix, the rebuilt city geometry, and every
panel added after V16.

The full account is in [`docs/PLAN.md`](docs/PLAN.md); every version and the bug
it fixed is in [`docs/CHANGELOG.md`](docs/CHANGELOG.md). Most of those bugs were
named outright by the game log rather than reasoned out, which is the single most
useful thing to know about working on this codebase.

The pass condition for any run is not "it looks like it works" — it is **the game
log stays quiet**.

## The one bug worth reading about before anything else

It is the shape of every hard bug in this codebase, and it is instructive.

*"I can't use the lift to spawn creations."* Reported twice. V19 diagnosed it as
survival content owning the lift's uuid — `baseGameContent: "Survival"` means
uuid `8f190ce2` resolves to `SurvivalLift` rather than creative's `Lift` — and
re-declared the uuid in the mod's own toolset. The reasoning was sound, the
citation was real, and **the diagnosis was wrong**: `SurvivalLift = class( Lift )`
has exactly one live method and the rest of the file is commented out. It
inherits all the blueprint handling. V19 swapped a working class for an identical
one.

The real cause was ours. Selecting a creation from the blueprint menu spawns
**real bodies into the world, flagged as ghosts** (`Lift.client_onForceTool`
takes body objects; `sv_n_removeGhostBody` calls `destroyCreation` on one). They
appear in `sm.body.getAllBodies()` like anything else, and the protection patrol
reached them within a fraction of a second and pinned
`convertibleToDynamic = false`. A ghost that cannot convert to dynamic cannot
become a creation.

Two things to take from it. **The engine will hand you real objects where you
expect a preview** — anything that walks every body must skip `body:isGhost()`.
And **"survival owns this uuid" is not the same as "survival broke this"**; read
the subclass before blaming it.

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
| A creation on the lift is a real body flagged as a ghost | `Lift.lua:383` takes bodies, `:391` calls `destroyCreation` on one |
| World classes carry engine flags, not just Game classes | `LuaWorldScript.cpp`'s literal list in the exe string table |
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

    python dev/check_all.py     # all four of the below, about ten seconds
    python dev/check_lua.py     # compiles every script through a real Lua parser
    python dev/check_uuids.py   # every uuid the mod names, against the install
    python dev/test_layout.py   # runs Layout.lua; proves the city is a partition
    python dev/test_logic.py    # runs the mod's rules and panel layouts; 26 checks
    python dev/sync_mod.py      # repo -> game Mods folder, preserves live data
    python dev/session_stats.py --spam    # tick/FPS + what is flooding the log

The two test files are worth a look before judging anything else here, because
they are the answer to "how would you know?". `lupa` embeds a real Lua
interpreter, and the mod's geometry file is deliberately free of every `sm.*`
call, so `test_layout.py` executes **the code the game runs** and rasterises
every block of every piece it emits: no block claimed twice, no gap, no
fractional coordinate, over twelve configurations. `test_logic.py` does the same
for the rules, against stubs small enough to read in one screen.

Neither pretends to cover bodies, tools, GUIs or the network. A stub for those
would be a test that lies, and both files say so at the top.

After any test run, the log is the verdict. A mod can look fine while throwing
thousands of errors a second — that is exactly what happened to the 1.79 GB log.

## What replaced guesswork, and what did not

Three defects in the old city builder were confirmed by rasterising what it
emitted, not by looking at it: every coordinate landed on a half block (the
origin was −104.5), three of nine vertical seams were never built at all, and
rebuilding laid a second city on top of the first because the clear identified
city bodies by height and a slab welded to a build floats above the test.

The replacement does not check for overlap; it cannot produce one. The plaza is
the first thing on the axis rather than a hole punched in a grid, so a plot never
starts inside it. Geometry lives in exactly one file, which the server builder,
the locator and the client's map all call — the map used to be a hand-copied
mirror under a comment warning that it must not drift, and it drifted.

## Honest summary

The engine research is solid and independently checkable; that part is not
guesswork. The code is readable, commented with *why* rather than *what*, and
fails back to vanilla rather than locking a world open or shut.

The rules can now be executed and checked without the game, which is new and is
the thing to lean on when judging the rest: `dev/test_logic.py` and
`dev/test_layout.py` run the mod's own Lua. Everything they do not cover —
bodies, tools, GUIs, the network — is still only as good as the citations.
