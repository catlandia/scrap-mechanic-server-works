# SERVER WORKS — event server

## What this is

A Scrap Mechanic **Custom Game** built for hosting large multiplayer building events —
the kind a streamer runs with a lobby full of people building at once. Creative first.
A Survival branch comes later and is explicitly out of scope until Creative works.

There is exactly one user — the owner of this repo. Optimise for running real events,
not for generality.

## The three goals, in the owner's order

1. **Many people building at once without the server dying.** Stated as the most important
   and the hardest, and that is correct. See "The performance position" below — it is not
   a tuning problem and there is no knob.
2. **Host tooling against griefing.** Freeze every build once a batch is finished so nothing
   is touchable (the way warehouse parts behave), and restrict placing/breaking to a
   player's own plot.
3. **The event, not just the building.** Scope still open — the owner has said this is not
   only a build-server.

## The hard constraint

**It ships as a Custom Game.**

This is what makes goals 1 and 2 reachable at all. A Custom Game owns `Game.lua`,
`Player.lua`, `World.lua` and the terrain script, and several bindings we need exist *only*
in a Game script — `sm.game.kickPlayer`, `sm.game.banPlayer`, `sm.game.bindChatCommand`,
`sm.game.setEnableRestrictions`, `sm.game.pauseSaving`. A Blocks-and-Parts mod cannot reach
any of them.

What it costs: a Custom Game replaces the world. Existing creative saves do not come along,
and every participant needs the mod installed. For an event server both of those are
correct behaviour, not drawbacks.

## Ground truth for this build

Researched against the installed game, not from memory. Redo it after any game update.

- Install: `D:\SteamLibrary\steamapps\common\Scrap Mechanic`
- Build id `24529696`, `Release/ScrapMechanic.exe` stamped 2026-08-03.
- Local mods: `%APPDATA%\Axolot Games\Scrap Mechanic\User\User_<your-steam-id>\Mods`
- **`"version"` in `description.json` is the game content version, not a mod revision, and
  it differs by mod type.** Cross-tabulated across the whole local Workshop corpus:

      Custom Game        {'0': 22, '1': 3}
      Blocks and Parts   {'1': 48, '2': 14, '0': 27, ...}

  So **Custom Games use `1`; `2` is a Blocks-and-Parts number and never appears on a
  Custom Game.** (An earlier version of this file said `2` outright — that was inherited
  from a Blocks-and-Parts project and is wrong here.) City Building MMO, republished
  2026-08-22, carries `1`. Get it wrong and every world load shows "One or more of the
  selected mods have not been updated to the current game version". After a game update,
  re-derive it the same way — histogram `description.json` `version` by `type` over the
  Workshop corpus, weighted toward recently-republished items.
- `allow_add_mods: true` in `description.json` is what lets Blocks-and-Parts mods be
  enabled alongside a Custom Game. Ours sets it.
- Workshop corpus for prior art: `D:\SteamLibrary\steamapps\workshop\content\387990` (1205 items)
- `dev/dump_api.py` extracts a module's real Lua binding list from the executable. The
  engine keeps each wrapper's binding-name literals contiguous *after* its own
  `wrap_<Module>.cpp` source-path literal. That method is reproducible and beats any wiki,
  which lags the game.

## What the engine actually gives us

Verified — file and line where it was found, so it can be rechecked.

### The shell is nearly free

`Data/Scripts/game/CreativeGame.lua` is a plain Lua class, so a Custom Game inherits all of
vanilla creative in four lines:

    dofile "$GAME_DATA/Scripts/game/CreativeGame.lua"
    Game = class( CreativeGame )

Template `config.json` shape is at `Data/ExampleMods/Templates/Survival Custom Game/`.
`baseGameContent` is `"Survival"` or `"None"`. World subclasses that already exist:
`CreativeFlatWorld`, `CreativeTerrainWorld`, `CreativeCustomWorld`,
`ClassicCreativeTerrainWorld` — all in `Data/Scripts/game/worlds/`.

### Anti-grief is an engine primitive, not something we invent

Bodies carry the whole permission set: `setBuildable`, `setErasable`, `setConnectable`,
`setPaintable`, `setLiftable`, `setUsable`, `setDestructable`, `setConvertibleToDynamic`
(plus `is*` getters, and `isStatic` / `isDynamic`). Confirmed in the `wrap_Body.cpp` slice
and used by vanilla at `ChallengeData/Scripts/challenge/world_util.lua:restrictAllBodies()`
and `ChallengeData/Scripts/challenge/BuilderWorld.lua`.

**These flags are per-body, not per-player.** There is no `setBuildableBy(player)`. A body is
buildable by everyone or by nobody. Every plot design has to be built on top of that fact.

### There is no block-placed callback

The engine's callback set has `server_onInteractableCreated`, `server_onVoxelConstruction`,
`server_onVoxelDestruction`, `server_onCellCreated/Loaded/Unloaded`, `server_onCollision`,
`server_onPlayerJoined/Left` — but a plain block is not an interactable and nothing fires
when one is placed.

This is why vanilla's `BuilderWorld.server_onFixedUpdate` walks `sm.body.getAllBodies()` and
sets eight flags on **every body, every tick, at 40 Hz**. Treat that file as a correctness
reference and never as a performance one; that cadence is exactly what would kill a full
lobby. Plot enforcement here is therefore *amortised reconciliation*, not prevention — an
out-of-bounds block gets reverted shortly after placement, not blocked.

### A body on the lift is REAL, and it is flagged as a ghost

Selecting a creation from the blueprint menu spawns actual bodies into the world
and hands them to the lift tool. `Lift.client_onForceTool( self, bodies )` takes
body objects; `Lift.sv_n_removeGhostBody( self, body )` calls
`body:destroyCreation()` on one (`Data/Scripts/game/Lift.lua:383, :391`). So a
creation being placed appears in `sm.body.getAllBodies()` alongside everything
else.

**`body:isGhost()` exists** — it is in the `wrap_Body.cpp` binding list next to
`isOnLift` and `isOnVirtualLift`. Anything that walks every body must skip
ghosts. Ours did not, and pinned `convertibleToDynamic = false` on the ghost
within a fraction of a second, which made the lift silently refuse to place
anything. There was no error and nothing in the log — which is exactly why it
took three attempts to find.

### The World class carries engine flags too, not just the Game class

`LuaWorldScript.cpp`'s literal list, straight out of the executable's string
table:

    terrainScript renderMode enableSurface enableAssets enableClutter
    enableCreations enableNodes enableHarvestables enableKinematics
    enableVoxelTerrain enableNavMesh enableBuildOnAssets enableBuildOnSurface
    enableBuildOnLift enableBuildOnBodies horizonWater hLod defaultVoxelMaterial
    defaultVoxelDensity worldBorder cellMinX cellMaxX cellMinY cellMaxY
    enableRestrictions enableAmmoConsumption enableFuelConsumption enableUpgrade
    enableAggro enableRecipes defaultInventorySize

`LuaGameScript.cpp` reads only `enableLimitedInventory`. Note that
`enableBuildOnLift` and `enableCreations` live on the **world**, and that
`enableCreations = false` on every vanilla creative world — so it does not mean
player blueprints.

### Lifts are a plot primitive the engine already tracks

`body:getLift()`, `body:isOnLift()`, `body:isOnVirtualLift()`, `sm.player.placeLift()`,
`sm.player.removeLift()`. Ownership comes for free, lift builds are already static, and
freezing one is a single call. Does not cover ground builds, but it is a far better
starting point than geometric regions.

### Area triggers exist for the geometric case

`sm.areaTrigger.createBox / createSphere / createCylinder / createHull` and the `Attached`
variants, with `sm.areaTrigger.filter.dynamicBody + staticBody`. Vanilla's Challenge builder
already ships an `obj_interactive_buildarea` part using exactly this
(`BuilderWorld.server_onInteractableCreated`).

### Chat commands are the admin surface, and they have a real bug

`sm.game.bindChatCommand( "/name", { { type, label, optional, enumValues? } }, callback, help )`.
Types seen: `string`, `number`, `bool`. `CreativeGame.client_onCreate` binds a dozen of them
and routes to the server over `self.network:sendToServer`.

**The parser splits on spaces and has no quoting.** So `/kick June Carya` puts only `"June"`
in `params[2]` and any Steam name containing a space is unkickable by name. Vanilla's
`SurvivalGame.sv_kickPlayer` (line 1876) matches on `player:getName()` and therefore has
this bug too. Workshop mods work around it by switching to player ids —
`workshop/387990/3787876507/Scripts/Game.lua:112` — but that one indexes
`sm.player.getAllPlayers(true)[tonumber(id)]`, which is an **array slot, not `player.id`**,
and silently targets the wrong person once the list shifts. Do not copy it.

The better fix: declare several trailing *optional* string params and rejoin them with
spaces, which reconstructs names containing spaces, and additionally offer a `/players`
listing so the host can target by id when they want to.

### `sm.game.kickPlayer` / `banPlayer` take a Player object

Not an id. Confirmed at `Survival/Scripts/game/SurvivalGame.lua:1876-1893`. Both refuse the
host ("Unable to kick host" / "Unable to ban host" in the exe).

## The performance position

**There is no simulation knob.** `sm.game` has 25 bindings and not one touches tickrate,
timescale, threading or physics quality. A mod cannot make Scrap Mechanic's physics faster,
and looking for a way to is the single easiest way to lose a month on this project.

What a mod *can* do is shrink what has to be simulated:

- **Freezing finished builds is the same feature as anti-grief.** A body that is not
  convertible to dynamic stays static, and static bodies skip rigid-body simulation. Goal 1
  and goal 2 are one implementation. This is the most important structural insight in the
  project. *(Static-is-cheaper is a strong inference from the engine's static/dynamic split
  and is not yet measured in-game — see working agreements.)*
- **Budget joints and interactables, not blocks.** A 500-block static sculpture is nearly
  free; a 50-block machine with 20 bearings is not. `body:getCreationJoints()`,
  `getInteractables()`, `getShapeCount()`, `getCreationBodies()` are the accounting tools.
  Any limit that counts blocks is measuring the wrong quantity.
- **Plot spacing is a performance decision.** Far-apart plots mean unloaded cells mean free.
- **The client side cannot be helped.** Twenty players each rendering twenty plots is draw
  calls, and no binding touches the renderer. Only spatial separation and budgets mitigate it.

**One lead worth chasing: `PhysicsQuality`.** The name is in the executable's string
table and `sm.game.getSettingValue( "PhysicsQuality" )` reads it. There is no setter, so
a mod cannot change it — but the host runs the physics for everyone, so the *host's*
value governs the whole server, and it is not in `settings.json` until it is changed
from the default. `/protection` now prints it. This is the closest thing to a
simulation knob found so far and it has not been measured: get a value, change it in
the host's options, and re-run `dev/session_stats.py` on both sessions before believing
anything about it.

There is no Lua profiler binding — but the game log is one. Every line is stamped
`HH:MM:SS (tick/frame)`: the first counter advances at the simulation rate, the second at
the render rate, so dividing each by wall-clock recovers server tick rate and client FPS
for **any session already played**. `dev/session_stats.py` does it. No test group required.

### What that measurement actually said

Two sessions, run before any of this existed:

| session | players | tick/s | frame/s |
|---|---|---|---|
| 2026-08-22, 100 min | 19 | median 39.9, min 36.7, **0/86 windows below 90% of 40 Hz** | 60 → 31 |
| 2026-08-08 | 1 | **collapsed to 11.6** | — |

Nineteen players never dented the simulation. One player did. The premise that "Scrap
Mechanic hates a lot of players" is not what this owner's own logs show.

- **Player count did not degrade anything measurable.** Tick held at target the whole event.
- **Client frame rate degraded with *time*, not player count** — it kept sliding while the
  count was flat at 19. That is accumulated world content, i.e. a render problem.
- **The single-player collapse was self-inflicted.** That log is 1.79 GB / 1.88 M lines:
  1.45 M lines of a `print()` dumping a player table every tick, plus 58 K
  `attempt to index global 'g_unitManager' (a nil value)` from
  `CreativeBaseWorld.lua:server_onCollision`, each with a full traceback written to disk.
  A Custom Game that overrides `server_onCreate` without calling its parent never creates
  `g_unitManager`, and then every collision throws. **Log spam is a performance bug**, and
  on this evidence the largest one measured so far.

Consequence for the freeze: it buys simulation headroom, and simulation was not the
bottleneck in the measured session. **Freezing does not fix frame rate — a static body
still renders.** Keep it for anti-grief and for headroom at higher counts, but do not
credit it with fixing the thing that actually degraded.

## What exists

    mod/description.json        Custom Game, version 1, allow_add_mods
    mod/config.json             baseGameContent "Survival" (for survival parts in creative)
    mod/Scripts/Game.lua        class(CreativeGame); commands; timers; grief alarm
    mod/Scripts/Player.lua      class(CreativePlayer)
    mod/Scripts/World.lua       class(CreativeFlatWorld); stops explosion cratering
    mod/Scripts/Protection.lua  the anti-grief freeze + shape census
    mod/Scripts/Identity.lua    perma ids, aliases, persistent ban list
    mod/Scripts/Plots.lua       claimable grid, teaming, presence enforcement
    mod/Scripts/Settings.lua    every host toggle, one schema
    mod/Scripts/Snapshots.lua   world and per-plot capture and rollback

    mod/Scripts/Layout.lua      ALL city geometry, pure -- no sm.* calls at all

    dev/check_all.py            all four checks below; --sync installs afterwards
    dev/check_lua.py            compiles every mod script through a real Lua parser
    dev/check_uuids.py          every uuid the mod names, against the install
    dev/test_layout.py          runs Layout.lua and proves the city is a partition
    dev/test_logic.py           runs the mod's rules and panel layouts (26 checks)
    dev/sync_mod.py             repo -> game Mods folder (preserves live BanList.json)
    dev/session_stats.py        tick/FPS reconstruction from any game log
    dev/dump_api.py             per-module Lua bindings out of the executable

Commands, all host-only: `/lockdown` `/unlock` `/protection` `/buildtime` `/autosave`
`/snapshot` `/snapshots` `/restore` `/players` `/ban` `/unban` `/banlist` `/kick`.

Three things run without the host watching, because the grief that started this project
landed two minutes before an event ended and no amount of watching catches that:

- **`/buildtime N`** locks builds when the timer expires and snapshots at that instant.
- **Grief alarm.** The protection patrol already walks every body, so totalling
  `getShapeCount()` costs one extra call per body and yields a whole-world shape count per
  cycle. A drop past `ALARM_SHAPE_DROP` announces itself and arms `/lockdown` on its own.
  This is the only way to notice mass deletion at all — the engine fires no callback when
  a plain block is destroyed.
- **`/autosave N`** rotates through `AUTO_SLOTS` snapshot names.

### How strong each "off switch" actually is

`/settings` and `/set <name> <value>`. Be honest in the help text about the tiers,
because they are not equally strong:

- **Real off** — fire (`sm.fire.setFireLimit(0)`), terrain cratering (our
  `World.server_onExplosion` declines the voxel subtraction), unit aggro.
- **Forced down** — tools. `sm.tool.forceTool(nil)` pulls a banned tool out of the player's
  hands within 10 ticks of equipping it. The item still appears in the creative menu; Lua
  cannot edit that list. Uuids came from `survival_items.lua` and `challenge_tools.lua`.
- **Damage only** — explosive *items* (cornades). They are consumables, not tools, so
  `forceTool` does not reach them. They cannot hurt a build (`destructable` pinned false)
  or the ground, so what remains is noise and knockback. Removing them properly needs our
  own `Objects` database — a content change, not a script change. Not done. Do not let the
  UI imply otherwise.

Snapshot/restore uses vanilla's own round trip: `sm.creation.exportToString(body, true,
onLift)` per creation, `importFromString(world, str, vec3.zero(), quat.identity(), ...)`
back. `BuilderWorld.lua` exports a level that way and re-imports at the origin, so the
blueprint carries world-relative geometry and no positions need recording. `/restore`
clears first via the inherited `CreativeBaseWorld.sv_e_clear`, and is deliberately
two-step — it deletes the world, so a fat-fingered restore mid-event beats the griefer.

**Untested in-game so far.** Everything above compiles under a real Lua parser
(`dev/check_lua.py`) and installs; none of it has been run. Ranked by what is most likely
to be wrong:

1. **`baseGameContent: "Survival"` + a `CreativeGame` subclass.** No Workshop Custom Game
   pairs those (they use Survival+SurvivalGame, or Creative+own class). If it misbehaves,
   flip to `"Creative"` — and survival parts go away with it.

   **It has misbehaved once, and the fix was small.** Survival content wins any uuid
   the two modes share, so you get the *survival* version of a shared tool:
   `Sledgehammer.lua` reads `clientPublicData.perks`, which `SurvivalPlayer` sets and
   `CreativePlayer` does not, and threw once per client frame → fixed by two
   overrides in `Player.lua`.

   The pattern to remember: **when a creative feature silently does nothing, check whether
   survival owns that uuid.** Our own toolset can take it back.

   **And the counter-example, which cost a whole version.** uuid `8f190ce2` is the
   lift, and survival does own it — `Survival/Tools/ToolSets/tools.json:44` maps it
   to `SurvivalLift`. That looked like the same bug and it was not:
   `SurvivalLift = class( Lift )` has exactly one live method (`client_onUpdate`,
   calling `setBlockSprint`) and the whole rest of that file sits inside a
   `--[[ ]]` block. It inherits every piece of blueprint handling there is. V19
   swapped a working class for an identical one and changed nothing.
   **Survival owning a uuid is not the same as survival breaking it — read the
   subclass before blaming it.**
2. **`sm.creation.importFromString`'s last two arguments.** Vanilla passes `true, true`
   in `BuilderWorld` and only five arguments in `MenuWorld`; the meaning is not documented
   anywhere and was not derivable from the binding names.
3. **Whether `sm.json.save` can write into an installed mod's directory at runtime.**
   Workshop mods are replaced wholesale on update, so the master ban list should live
   outside the mod and be synced in regardless.

Every one of those is guarded with `pcall` and logs once rather than per tick.

## Build order

0. ~~Measure before writing mod code.~~ Done, from existing logs — see above. It changed
   the ordering below.
1. ~~The shell~~ — built. Custom Game inheriting `CreativeGame`, host-gated chat commands,
   kick/ban that handles names with spaces.
2. ~~The freeze~~ — built. `/lockdown` full-sweeps immediately, then an amortised patrol
   catches new bodies. Never the vanilla 40 Hz full sweep.
3. **Next: run it.** Load the Custom Game, confirm the world starts, confirm the log is
   *quiet* (that is the pass condition, not "the mod appears to work"), then exercise every
   command.
4. **Then chase frame rate**, since that is what actually degraded — part budgets and plot
   spacing aimed at what is *rendered*, not what is simulated.
5. **Plots** — lift ownership first, area triggers second.
6. **Budgets** — joint/interactable counts per plot with a live HUD so builders self-regulate.
7. Later: whatever goal 3 turns out to be.

## Working agreements

- **Nothing ships that the owner cannot test in one sitting.** One working freeze beats five
  stubbed systems.
- **Measure before optimising, and say so when a claim is unmeasured.** This project's whole
  premise is performance; an unverified perf claim is worse than no claim.
- **`print()` does not reach the game log; `sm.log.info` does.** Every `[Lua]` line in
  `Logs/game-*.log` comes from `sm.log.info`. Absent log output proves nothing on its own.
- **Run `python dev/check_all.py` before playing.** It is four checks and ten
  seconds, and two of them execute the mod's own Lua through `lupa` rather than a
  Python restatement of it. A pass does not mean the mod works — nothing there
  touches a body, a tool or the network — but a failure is always real.
- **Verify against the game, not against memory.** The wiki and the training data both lag
  this build. If a fact matters, find it in the install or the workshop corpus and write down
  where it was found — as this file does.
- **Every API call not yet run in-game is a guess.** Mark them in comments, guard them with
  `pcall`, and never let one take the server down mid-event.
- **Fail back to vanilla.** Anything we lock, we must be able to unlock. If a script errors
  during an event the lobby must not be left frozen or unable to build.
- Comments explain *why* — an engine quirk, a workaround, a thing that looked wrong and
  isn't. Not what a line does.
- Taste calls — plot size, batch length, which commands exist, how strict the budget is —
  are the owner's. Ask, don't guess.

## Open decisions

- Does this project stay in `E:\Projects\Server Works\server-works`? There is no git repo
  here yet.
- Is there a group available for the phase-0 load test? If not, phase 0 needs a different
  design and that should be settled before phase 1.
- How much of vanilla creative survives? `CreativeGame` brings tapebots (`UnitManager`,
  `aggroCreations = true`), weather and water managers by default, and they cost real CPU on
  an event server.
