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

### Anti-grief: the whole argument is in docs/ANTI-GRIEF.md

Why it cannot be prevention, where griefing is still possible and why each of
those places is a consequence rather than an oversight, what the alarm actually
measures, and what it cannot do. Read it before changing anything about
protection, plots or the alarm.

The short version: the engine fires no callback when a block is placed or
destroyed, so there is no moment to intervene in — everything is state plus a
patrol. Body flags are per-body, so "only your own plot" is approximated by
presence. And an event needs plots buildable *while the event runs*, so damage by
somebody with legitimate access is not preventable at all. That is the gap the
alarm exists to detect, contain and reverse.

### Co-loaded mods: the whole argument is in docs/MODS-AND-TRUST.md

There is no sandbox between mods, so a Blocks-and-Parts mod enabled beside this
one runs server-side Lua on the host with nearly our own reach. `allow_add_mods`
is therefore a security setting, and it is now **false**.

The short version, all of it measured: a guest CANNOT bring their own mods (101
subscribed, 1 loaded, on a real join), an installed-but-unticked mod executes
nothing at all (12,766 lines vs 0), and the Lua sandbox has no network and no
filesystem outside `$CONTENT_*`. So the only door is the host ticking the box at
world creation -- which is the one that is now shut. The doc traces T mod's
host-takeover backdoor as the worked example, and records the 95 MB / 4.6 Hz
session it caused in a Server Works world by accident, with nobody attacking
anything.

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

### A Custom Game's toolset can ADD a tool. It cannot OVERRIDE one.

First declaration wins, and a mod's toolset is loaded after the base content's.
**MEASURED**, from the line the game logs whenever a tool is created:

    Created Tool 18 of type {8f190ce2-3a59-423e-8483-a7aa67bd5bc0(SurvivalLift)}

while `serverworks.toolset` was asking for class `Lift` on that uuid. Same for
`6993e5df(ClayRifle)` and `a2a2bb33(PotatoLauncher)` — always the base class,
never ours, in every session. The proof it is precedence rather than a broken
file is in the same toolset: the nugdupS canary is a uuid nothing else declares
and it resolves exactly as written.

Two builds were spent on overrides that never executed. `grep "Created Tool"` in
`Logs/game-*.log` settles it in one command, and `dev/check_uuids.py` now flags
a dead entry before the game ever sees it.

### A tool we ADD gets its menu name from our own inventoryDescriptions

The toolset has **no name field**. A tool entry is uuid, preview renderable,
preview rotation and script, and nothing else. The name and the description in
the creative menu come from

    mod/Gui/Language/English/inventoryDescriptions.json

keyed by uuid. Without an entry the tool is still in the menu and still works, it
just has nothing to call itself -- which is exactly how "I dont see my deleting
thing appear" got reported about a tool the logs proved was in the game.

The nugdupS canary is the standing proof this works: a uuid nothing else
declares, a name nothing else could produce, visible in the menu.

`dev/check_uuids.py` now prints the menu name of every tool the toolset adds and
says **NO NAME IN THE MENU** for any that lack an entry.

### `baseGameContent` decides which tool databases exist at all

`"Survival"` loads `Survival/Tools/toolsets.json`; `"Creative"` and `"None"` load
`Data/Tools/toolsets.json`. They share `core.json` and the survival spudgun/carry
sets, and nothing else.

So there are **two lifts and they are different items**:

| uuid | class | declared by |
|---|---|---|
| `5cc12f03` | `Lift` | `Data/Tools/ToolSets/tools.json` — `tool_lift_creative` at `ChallengeData/Scripts/game/challenge_tools.lua:2` |
| `8f190ce2` | `SurvivalLift` | `Survival/Tools/ToolSets/tools.json:44` |

With `baseGameContent: "Survival"` the creative lift is **not in the game**, and
the blueprint menu that E opens is engine-side (`ImportGui.cpp` / `LiftGui.cpp`,
title `#{LIFT_IMPORT_BLUEPRINTS}`, drawing
`Data/Gui/Layouts/Lift/Lift_Import.layout`), so no Lua could bring it back.

**Adding `5cc12f03` did NOT bring the import menu back, and the tool was never
the gate.** REPORTED: *"in survival you cant press E on the lift to import stuff.
this is a feature. the same feature is turned on in custom game."*

Both lift classes end at the same call — `Lift.server_placeLift` and
`SurvivalLift`'s inherited copy both do `sm.player.placeLift( ... )`
(`Data/Scripts/game/Lift.lua:388`) — so the *placed* lift is identical whichever
tool placed it. Our toolset's `5cc12f03` was created with class `Lift`, confirmed
in the log, and E still did nothing. A gate the tool cannot influence has to be
keyed on the loaded **content**.

### Do NOT set `baseGameContent: "Creative"`. It cannot create a world.

Tried, 2026-08-25, to reach the import menu. **It bricked the game**, and the
failure is worth the whole section because nothing in `dev/` caught it.

    ERROR: ScriptableObjectManager.cpp:252
           ScriptableObject type {46e23051-...(<Unnamed>)} not found!
    [Lua] ERROR: $GAME_DATA/Scripts/game/CreativeGame.lua:47:
           createScriptableObject failed due to invalid uuid

`46e23051` is the **WeatherManager**, and `CreativeGame.server_onCreate` builds it
on line 47 — which is **before** line 57, `self.sv.saved.world =
sm.world.createWorld( ... )`. `createScriptableObject` raises, `server_onCreate`
stops there, and **no world is ever created**. The loading screen still finishes
(`Load finished : 2237.98ms`, `Start state: Game`) and then sits at 100% with
nothing to enter. Reported as *"stuck at 100 when loading into the mod"*. Every
later tick throws `CreativeGame.lua:95: attempt to index field 'time'`, and every
join throws `:114: attempt to index field 'saved'` — the same shape as the 1.79 GB
log, from the same cause: a `server_onCreate` that died half way.

**And the reason is not the one you would guess.** `46e23051` *is* listed in
`Data/ScriptableObjects/scriptableObjectSets.sobdb`, the index you would expect
`"Creative"` to load. It was still not found. So **`"Creative"` loads no
scriptable object index at all — only `"Survival"` does.** That is measured, not
inferred; `RenderSettingsManager` (`54563daa`, `CreativeGame.lua:131`) failed the
same way in the same session.

Shipping our own `.sobdb` is the engine's supported way to add types — both
`Data/ExampleMods/Templates/*/ScriptableObjects/scriptableObjectSets.sobdb` do
exactly that — so `"Creative"` plus a `.sobdb` registering `sob_managers.sobset`
is probably reachable. **Untried.** Do not attempt it without one.

`dev/check_uuids.py` now fails the build on this. It had said *"89 uuids resolve,
0 do not"* about the build that could not create a world, because it only ever
looked at **tools**; it now also resolves every `createScriptableObject` uuid on
the game script's inheritance path (following one level of `dofile` out of the mod
and into the install, which is exactly far enough to reach `CreativeGame`) against
the scriptable object index the configured `baseGameContent` actually loads. Flip
`config.json` to `"Creative"` today and it names `CreativeGame.lua:47` and `:131`
and exits 1.

**What is still true, and cost nothing to learn:** `config.json` said `"Survival"`
*"for survival parts in creative"*, and that premise is wrong.
`Data/Objects/Database/shapesets.json` — the database `"Creative"` loads — already
lists **51 `$SURVIVAL_DATA` shapesets**. The survival building parts were never
behind `baseGameContent`. That is not a reason to switch, given the above; it just
means the stated reason for the current setting is not the real one. The real one
is that `"Survival"` is the only value that registers the scriptable objects
`CreativeGame` needs.

The general rule: **before blaming a script, check the uuid is even loaded.**
And the corollary this cost a version to learn: **a uuid being loaded is not the
same as the feature being on.**

### Importing a creation: six facts, each of which cost a build to learn

REPORTED across a dozen exchanges as *"welded to air"*, *"still is statick"*,
*"the lift isnt even connected and still holds"*, *"it spawns two and only one is
not frozen"*. Every one of those was a different cause. `NOTlift` is the tool;
`NotLift.lua` and `World.sv_e_swImportCreation` are the code.

**1. The engine's blueprint browser can be borrowed, and it is the only door.**
`sm.gui.openGarageImportGui()` plus `sm.gui.setGarageButtonCallback( name )` is
how the survival garage picks a creation (`GarageConsole.lua:468`). MEASURED: it
opens **with no storage set**, from a **Game script**, and the callback
`( self, path, name )` really arrives there — which no vanilla code does, every
caller being an interactable. `/bptest2` is the probe that settled it.

**2. A blueprint is its own content id.** The path handed back is
`$CONTENT_<uuid>/blueprint.json`. MEASURED, `/bptest`, every other form refused
with *"is not located in a valid directory"* — absolute paths, `$BLUEPRINT_DATA`,
`$USER_DATA`, `..` traversal — against a control that came back READABLE. And
there is **no directory-listing binding at all**: `listFiles` `getFiles`
`readDirectory` `directoryExists` are 0 hits in the executable. So Lua can open a
blueprint only when the engine has already handed over the path. A custom
creations list is not possible; borrowing the browser is not a shortcut.

**3. `sm.creation.importFromFile` ALWAYS makes a static body.** MEASURED, six
call shapes, two sessions, `dynamic=false` every time: 4 args, `+true`,
`+true,true`, `+false`, `+false,false`, and `world = nil`. The two undocumented
booleans do not touch it. A blueprint file carries no static flag either — 400 of
the owner's own have only `bodies`/`joints`/`version`/`dependencies`. **Do not go
looking for an import that returns a dynamic creation. There isn't one.**

**4. `sm.player.placeLift` does nothing to a real body.** MEASURED by a 25-second
trace in which `onLift` was false at t+0.00 and still false at t+25.00, without
one change. Vanilla only ever calls it with **ghost** bodies handed over by the
engine's own import (`Lift.client_onForceTool`). It is not deferral — an earlier
version of this file claimed that, and the trace disproved it.

`sm.lift.createNonPlayerLift( world, liftPos, body, level, rotation )` is the one
that takes a **real** body; vanilla passes an existing shape's body straight in
(`BuilderGuideLiftPlatform.sv_spawnLift:160`). Lift coordinates are quarter
blocks (`liftPos = worldPos * 4`), and since `Plots.BLOCK` is 0.25 a lift
coordinate and a city block coordinate are the same number.

**5. PUTTING A BODY ON A LIFT REPLACES IT.** MEASURED: the trace said `BODY GONE
(deleted)` one tick after `createNonPlayerLift`, every single time. The engine
destroys the original body object and makes a new one. So **every handle taken
before the lift is dead afterwards** — which is why a release that was working
logged nothing at all, and why the trace now starts *after* the release and finds
the body by position instead.

Keep the **lift** handle, not the body handle. `Lift:destroy()` is what releases
the creation (`BuilderGuidePlatform.lua:64`) and the only thing that removes a
non-player lift — no player owns one, so no lift tool will pick it up. Two
unremovable lifts were left standing in a test world by not keeping it.

**6. Anything that can be lifted must be convertible to dynamic.** `sweep` was
`liftable = true` with `convertibleToDynamic = false` — "you may put this on a
lift, and it may never come off". Every creation imported outside a plot got that
profile from the patrol within a second of landing and was pinned static forever,
which defeated three separate fixes to the lift before anyone looked at it.
`dev/test_logic.py` now asserts the pairing over every profile.

The shape of the whole episode: **four fixes were shipped on reasoning and none
landed.** What worked was a real-time trace — one line per change, a heartbeat, a
hard stop — because every single-instant measurement had been taken at an instant
chosen before anyone knew which transition was failing. See `World.sv_traceStep`.

### The map draws what the builder builds, so a map bug is usually a CITY bug

REPORTED: *"the road is crosed by frame that it shoudlnt be"*, then *"still line
on one of the axis"*. Both were one fault, and it was not in the drawing.

`Layout.deckPieces` emitted every non-plot **column** as a single full-height
strip, while horizontal seams were only emitted across plot **columns**. So a
one-block seam between two plots ran the entire height of the city, straight
through the middle of every horizontal road, carrying its own `filler` kind --
a line of the wrong material across each road, on **one axis only**, because the
reverse case never happens.

**The partition was intact the whole time, which is exactly why nothing caught
it.** `dev/test_layout.py` checked for overlap, gaps and fractional blocks and
all of them passed: the ground *was* covered exactly once, just by the wrong
piece. A suite that verifies coverage does not verify *kind*. It now asserts no
`filler` piece sits inside a road band, on either axis, across all 13
configurations.

Two smaller things in the same panel, both genuinely cosmetic:

- **The plaza wore the "taken" colour.** It is drawn in ACCENT orange, which the
  key underneath calls *taken*, and a plaza is deliberately larger than a plot --
  with `plazacells 2` it is 41 blocks across against a plot's 20, because it
  swallows the seam between the cells it covers. So it read as a claimed tile of
  the wrong size sitting off the grid. Reported as *"see? they are offset."* It
  is blue now and named in the key.
- **Rounding position and size independently un-tiles a partition.** A piece
  ending at 149.7 was drawn to 149 while its neighbour starting at 149.7 was
  drawn *from* 149. Round both EDGES instead and adjacent pieces land on the same
  boundary pixel by construction. MEASURED: 10 seam breaks across a row before,
  0 after. `dev/test_logic.py` walks a scanline and demands contiguity.

### Mod state is GLOBAL to the mod, not per world

`Settings.json`, `Plots.json`, `Event.json`, `Players.json` and `Snapshots/` all
live in `$CONTENT_DATA` — **one folder shared by every world ever created from
this mod** — and nothing here uses per-world storage at all.

So a brand new world inherited the previous world's protection mode, `buildopen`
flag, plot claims and event phase: it came up **locked**, with claims on plots
that did not exist, and an event that had already ended. Every time. REPORTED as
*"every time I create a new world. and fix something you havent updated yet in a
long time."* It is also what was first misread as "one test event left it locked".

`self.storage` **is** per world (it is where `CreativeGame` keeps `self.sv.saved`),
so a stamp written there and mirrored into `Settings.json` says whether the files
on disk belong to this world. `Game.sv_newWorldReset` clears protection,
`buildopen`, plot claims and the clock, and keeps tool settings, bans and
snapshots — a host's preferences and a persistent ban list are not world state.

**It must run AFTER `CreativeGame.server_onCreate`.** Writing to `self.storage`
first makes that function's own `if self.sv.saved == nil` test see a non-empty
table and skip creating the world entirely — the same no-world-at-all failure the
`baseGameContent` experiment produced. A check enforces the ordering.

### Custom item icons

`"custom_icons": true` in `description.json`, plus `Gui/IconMap.xml` and
`Gui/IconMap.png`. Format taken from the corpus: 31 Workshop items ship icons and
every one uses this exact pair; `2809564171` "Portal Gun" is a Custom Game
precedent. Vanilla's own is `Data/Gui/IconMap.xml`, a 2048x1024 atlas on a 96x96
grid — the creative lift's icon is at `1056,768`.

Two traps. **An XML comment may not contain two consecutive hyphens**, which the
Lua files use as dashes everywhere; a header written that way is rejected outright
and the game says nothing. And every corpus mod points its `Empty` index at tile
`0 0` *and* puts a real icon there — ours leaves `0 0` transparent instead,
because what the engine asks `Empty` for is a guess and the cost of being wrong is
a crossed-out lift appearing wherever it asks.

`dev/check_uuids.py` checks all of it: the flag, that each index uuid is a tool we
actually add, and that each frame lands inside the png.

### Litter must never become permanent, and it takes three rules to guarantee it

REPORTED: *"you need to fix the unremovable craft bots, gems and others."* Three
separate places all locked shared ground, and each one alone was enough.

1. **The plaza returned `"locked"`.** It was meant to stop a guest deleting
   spawn — but the plaza is where everyone arrives, so it is exactly where
   dropped craftbots land, and locking the ground locked them with it. The
   decking is defended by `sv_isScenery` one step earlier, which is the better
   test anyway: our plaza is metal at deck height, a craftbot standing on it is
   not. The plaza is `"sweep"` now, like every other street.
2. **`buildopen == false` locked everything, before the zone was consulted.**
   Prep, buffer and the end of an event all close building, and the world stays
   locked *between* events — so anything dropped during any of those was
   permanent. The zone verdict is asked for first now, and a `"sweep"` verdict
   wins.
3. **A locked mode short-circuited before the resolver ran at all.** `/lockdown`
   froze the rubbish along with the builds. A `"sweep"` verdict now escapes even
   a locked world; nothing else does.

**Carryable props are a separate problem with no script fix.** Gems, crates and
harvestables are *picked up* by the remove tool rather than erased, so making
them erasable does not make them removable. Script-side `destroyShape()` ignores
every permission flag — vanilla's own `sv_e_clear` relies on that — so `/purge`
and the SWEEP LITTER button on the city panel are the only way to be rid of one.

**Any bulk purge must skip bodies holding a city shape.** `/purge walkways`
deleted every body not standing on a plot, which is the deck, the streets, the
plaza and the pillar. It never bit anyone only because it was a chat command
nobody ran. The guard is per SHAPE, not per body, because a build welded to a
plot slab is one body with our concrete in it.

### A profile that exists is not a profile any body receives

**V34 shipped the polish profile with a check that passed and a feature that did
nothing**, and the shape of that mistake is worth more than the fix.

The check read the PROFILES table and asserted `polish` was paintable, usable and
not buildable. All true. But `sv_applyEventPhase` sets `buildopen = false` for
every phase that is not `build`, and the resolver's blanket

    if Settings.Get( "buildopen" ) == false then return false end

fired first and returned `locked`. **Buffer time was identical to prep.** The
profile was correct and unreachable.

Two rules out of it:

- **`buildopen` is a HOST toggle and must not override a MODE that already
  denies building.** `Protection.sv_modeClosesBuilding` says whether the current
  mode's own profile is already `buildable = false`; if it is, the blanket has
  nothing to add and does real harm.
- **Check the resolver, not the table.** `dev/test_logic.py` now builds a real
  `Protection`, a real `Plots`, the actual resolver, and a body standing on a
  real plot, then asks what that body would be given. Reading a data table can
  only ever prove the data.

The fixture stands on `Layout.plotCentre( grid, 1 )` and asserts the zone is a
buildable plot first — the origin is the **plaza**, which resolves to `sweep`,
and a check written there would have passed for entirely the wrong reason.

### Protection modes short-circuit, so anything that closes building must set one

`Protection.profileFor` begins:

    if isLockedMode( self.mode ) then return PROFILES[self.mode] end

A locked mode never reaches the resolver, so `buildopen`, plot ownership and
everything else stop being consulted. Setting `buildopen = false` is **not** how
you close building if the mode might already be locked — and it will be, because
`/lockdown` and the end of an event both set it and both persist it.

`Event.PROTECTION` maps every phase to a mode explicitly for this reason. `prep`
uses `display` (buildable false, usable true), which is the profile that means
"you cannot build and nothing else changes".

### The paint tool's palette is in the EXECUTABLE, as BGRA

There is nothing to read in `Data/` or `Survival/`.
`Data/Gui/Layouts/Tool/Tool_PaintTool.layout` is twenty lines long and declares
one empty widget called `ColorGrid`; the swatches are filled in engine-side.

They are not stored as text either, and the near-miss is worth knowing about:
the string table is full of interned six-hex strings, sorted alphabetically, and
they are the **shapeset** colours -- `8d8f89` in there is `blk_concrete1`, not a
swatch. A different list entirely.

**MEASURED.** Forty `uint32` BGRA values in a zero-terminated run at file offset
`0x13e9b90` of `Release/ScrapMechanic.exe`:

    eeeeee f5f071 cbf66f 68ff88 7eeded 4c6fe3 ae79f0 ee7bf0 f06767 eeaf5c
    7f7f7f e2db13 a0ea00 19e753 2ce6e6 0a3ee2 7514ed cf11d2 d02525 df7f00
    4a4a4a 817c00 577d07 0e8031 118787 0f2e91 500aa6 720a74 7c0000 673b00
    222222 323000 375000 064023 0a4444 0a1d5a 35086c 520653 560202 472800

Four rows of ten, exactly as the tool draws them: a greyscale column, then nine
hues in four shades. `df7f00` is the default orange every new block is painted
and `4a4a4a` is what this mod already used for metal 3 -- two independent
anchors, which is what makes this the palette rather than a plausible run of
bytes. `mod/Scripts/Palette.lua` holds them, named `green` / `palegreen` /
`deepgreen` / `darkgreen` and `white` / `grey` / `darkgrey` / `black`.

Re-derive after a game update: the offset moves, the terminator and the anchors
do not.

### A rule must never forbid its own remedy

REPORTED: *"I cant break the block if I hit the limit. so like I am stuck in a
loop I cant remove the bearing that prevents from building."*

Going over the per-plot part budget returned `false` from the top of
`Plots.sv_bodyIsOpen`, and `false` is the **locked** profile, which is
`erasable = false`. The one action that could satisfy the limit was the one the
limit forbade.

The fix is two rules, and the second matters more than the first:

- **`PROFILES.trim`** is the open profile with placing taken out and nothing
  else. It exists so that a brake stays a brake.
- **The over-budget check runs LAST and can only DOWNGRADE.** It used to run
  before the ownership logic, which meant it also overrode "this is somebody
  else's plot". Body flags are per-body -- `erasable` means erasable by
  *everyone* -- so a version that handed out erasing would have made the part
  limit a griefing tool: go one bearing over and the neighbours can clear your
  plot.

`trim` maps to `polish` during the buffer. Buffer time is the one window with
neither verb, and being over budget blocks nothing there that was not already
blocked, so handing out erasing would be a pure regression.

### Anything that needs to know where players are already has the answer

REPORTED: *"item detection is a bit too slow. you can run it faster if you only
check ocupied places with players curently on the server ocupied."*

Correct, and the reason it is cheap is the part worth writing down.
`Plots.sv_updateOccupancy` runs **every tick** and is the only thing in the mod
that looks at where anybody is standing. So `Rules` does not walk the player list
-- it reads `plots:sv_activePlots()`, which that pass filled in as it went. A
check forbids `sm.player.getAllPlayers` from appearing in `Rules.lua` at all.

The audit has two cadences: a scoped pass every second over the plots people are
on, and the full pass every five seconds over everything. A plot can only go over
budget if somebody is building on it, and somebody building on it is standing on
it -- so the scoped pass covers the case that matters, and the full pass still
catches the owner who logged off mid-build and the contraband dropped on a road.

**The trap, and it has a check.** A scoped pass only writes buckets for bodies it
*finds*, so deleting the last offending part would leave the violation standing
until the next full pass. Every plot in scope is seeded with an empty bucket
first; that is what makes "trim it and it reopens" mean one second.

### The game does not ship whole fonts

Scrap Mechanic builds a **limited glyph atlas per font** from the strings it
renders itself, cached at `Cache/Fonts/<language>/LimitedFontData.xml`. Anything
outside a font's atlas draws as a hollow box. A mod writes strings the game has
never seen, so this hits mods and nothing else.

**MEASURED.** `SM_LabelMini`'s atlas is exactly `0123456789ACDEILORSTVW`, and it
drew `HOST` as `⊠OST`, `YOU OWN` as `⊠O⊠ OW⊠`, `TOP DOWN` as `TO⊠ DOW⊠`. Five
strings, five exact matches.

**A font name that does not exist is NOT safe, and an earlier version of this
file said it was.** MyGUI does fall back to a complete font, so the text draws —
but the engine writes an error *and a full Lua traceback* every time it renders
that widget. **MEASURED**, 2026-08-24 log, once a second for the whole session:

    [Gui] ERROR: MyGUI_FontManager.cpp:101 | Font 'SM_HeaderSmall_Medium' not
                 found. Replaced with default font.
    [Lua] ----- Lua Error Traceback -----
          Game.lua:620: in function 'cl_updateEventHud'

The event HUD redraws once a second, so that is 3,600 tracebacks an hour written
to disk. Log spam is the largest performance bug this project has measured (see
the 1.79 GB single-player log above), so "it renders" was never the bar.

**Two files together are the font registry**, and neither is complete alone:
`Data/Gui/Fonts/ManualFontDataInput.xml` declares most of them, and
`Cache/Fonts/English/LimitedFontData.xml` names eleven more that are real and
glyph-limited — `SM_Label` `SM_NumberSmall` `SM_LabelSmall` `SM_Tab`
`SM_TextDesc` `SM_NumberHuge` `SM_HeaderLarge_Narrow` and four `X_*`. A font in
neither is the kind that spams. `SM_HeaderSmall_Medium` is in neither and never
existed.

So there are three tiers, not two:

| tier | example | what happens |
|---|---|---|
| known, no `<Codes>` | `SM_Text` `SM_TextTiny` `SM_LabelTiny` `SM_ButtonLarge` `SM_ButtonSmall` `SM_Header` `SM_HeaderSmall` `SM_TextSmall` `SM_TextLarge` `SM_ListItem` | **use these.** Full character set, silent |
| known, glyph-limited | `SM_Label` = `0123456789:EIMQTestu`, `SM_LabelMini` = `0123456789ACDEILORSTVW`, `SM_Button`, `SM_SubHeader`, `SM_TabSmall`, `SM_HeaderTiny`, `SM_NumberSmall`, `SM_HeaderLarge_Medium` | letters outside the set draw as hollow boxes |
| not a font at all | `SM_HeaderSmall_Medium` | draws via fallback, logs an error + traceback **per render** |

The mod now uses seven fonts and every one is tier 1. `dev/test_logic.py`
enforces both rules — existence first, then glyphs — over every caption of every
panel in every state.

### The canvas is NOT the window, and a panel is positioned from its CENTRE

Two different questions with two different answers, and confusing them is what
put the event clock off the edge of the screen where it could not be seen at all.

| | what it is |
|---|---|
| `sm.gui.getScreenSize()` | the **window**. Reported 3440x1440 on this owner's monitor |
| `sm.jsonGui.getViewSize()` | the **canvas widget units are in**. What every coordinate here means |

**MEASURED**, 2026-08-24 on a 3440x1440 monitor: `getScreenSize` said 3440x1440
and **`getViewSize` said 1720x720** — exactly half. So a panel is measured in a
space about half the window's width, and `SettingsGui` at 1120x690 is within 30
units of the canvas height. Anything taller would be off screen.

They are different numbers. The game ships GUI skins for exactly four reference
resolutions — `1280x720`, `1920x1080`, `2560x1440`, `3840x2160`
(`Data/Gui/Resolutions/`) — and picks one, so a 3440x1440 monitor is not a
3440x1440 canvas. **A root declared 3440 wide in a narrower canvas hangs off the
edge and everything in its top-right corner is off screen.** That was V29-V32's
event clock: correct arithmetic, wrong units.

`sm.jsonGui.getViewSize()` is the binding vanilla uses in all three places it
positions a HUD (`SurvivalPlayer.lua:424`, `ChallengePlayer.lua:180`,
`MechanicCharacter.lua:194`). Use it, and keep a root the size of the *panel*,
not the size of the screen.

And the arithmetic next to it says what a root widget's `x`/`y` mean, which is
not obvious and is not documented anywhere:

    StatusPanelGui.root.x = math.floor( -screenWidth / 2 + root.width * 0.5 )
    StatusPanelGui.root.y = math.floor( screenHeight / 2 - root.height * 0.5 )

That puts the panel bottom-left. Solve it and the meaning falls out: **x,y is the
widget's CENTRE, measured from the centre of the screen, with +y downwards.** So
top-right with a margin is

    x =  screenW / 2 - width  / 2 - margin
    y = -screenH / 2 + height / 2 + margin

`Anchor = "TopRight"` is not a value the engine accepts; `"Center"` is.

### Typed input in a json GUI: `EditBox` + `Static = false` + `onTextEnter`

The base game has exactly **one** editable box in a json GUI —
`Data/Gui/JsonGuis/DigitalSign.gui`'s `EnterTextBox` — so it is the only proof of
what one needs:

```lua
{ Type = "EditBox", Skin = "EditBoxEmpty",
  Static = false,          -- THE flag. Every other TextBox is Static = true
  NeedKey = true,          -- or it never takes the keyboard
  MultiLine = false, WordWrap = false, HeightFromText = false,
  MaxTextLength = 40,
  CaptionDisableReplacing = true,   -- stop #{...} being read as a localisation key
  onTextEdit = "cl_...",   -- every keystroke
  onTextEnter = "cl_..." } -- Enter
```

The handler is `( self, widgetName, text )` — `DigitalSign.lua:157`. **A text
event carries no `onClickData`**, so the widget *name* is the only thing that
says which field was typed into; map it back yourself (`EventGui.FieldForBox`).

Used by the event clock — **and it crashed the game twice.** One box is fine;
moving focus to a SECOND EditBox in the same tree is what kills it. Deferring our
redraw by a tick was not enough, so the handler now touches the GUI not at all:
it takes the value and says so in chat, and the panel catches up whenever
something else redraws it.

If you add a typed field anywhere, assume **one per panel**, and assume its
callback may not touch the GUI.

### GUI skins that draw no text

`UpgradeButton` is a progress bar. Given a Button and a Caption it renders the
bar and **silently drops the caption**, which reads as a broken widget rather
than as a styling mistake. `StyledButtonLarge` and `SecondaryButton` both draw
their text.

### A clickable colour swatch is two vanilla facts put together

Needed for the city style picker -- *"use the color pallete selection of paint
tool for the city part color selection"* -- and neither half is invented:

| what | where |
|---|---|
| a **Button** may use skin `WhiteSkin` | `Data/Gui/EditorSkin.xml:27` -- `<Widget type="Button" skin="WhiteSkin">` |
| a **Button** may carry `Colour` | `Data/Gui/JsonGuis/DigitalSign.gui` -- all eight colour-option buttons set `Colour` **and** `onClick` |

`WhiteSkin` is a 2x2 **white** patch with only a `normal` state
(`MyGUI_BlackOrangeSkins.xml:778`), so it has no hover art -- and because the
source texel is white, `Colour` multiplies straight through and the widget is
exactly the colour asked for. That is already how every panel background in this
mod is drawn; the only new part is putting it on a `Button` instead of a
`Widget`.

`StyleGui` draws each swatch **twice** -- a `fill()` first, then the Button on
top -- so that if the Button half ever draws nothing the grid still shows the
right colours and still takes clicks. Forty extra widgets on a panel built once
per click is not a cost worth caring about.

Hex to widget colour is `Palette.GuiColour`, which is pure and therefore checked
outside the game: `dev/test_logic.py` reads the colour back off every swatch,
converts it to hex again and compares it against the run out of the executable.

### The city style is picked, not stepped

The ten style settings used to be ten rows on the settings panel, each one
button that advanced to the next value. REPORTED: *"make it not a slider like.
but like a list so its easier to select."* Twenty-five blocks and forty colours
behind one button each is not a selection -- reaching `wood2` from `concrete` was
sixteen clicks, each one a server round trip, and at no point could you see what
you were choosing between.

`StyleGui` is one screen: the five pieces of the city down the left, all
twenty-five blocks as a list, all forty colours as the paint tool's own 4x10
grid, and the six whole-city styles that used to be reachable only through
`/citystyle`. Reached from the settings nav, from the city panel, and from
`/citystyle` with no argument; `back` is carried through every hop so BACK
returns to whichever of the two opened it.

**The trap when a tab stops being a tab.** `SettingsGui.RowsFor("other")` sweeps
up every schema row no group claims, so deleting the `style` group would put all
ten straight back as steppers under OTHER. The group entry stays and still lists
its keys -- it just carries `panel = "style"`, which makes its nav button open
the picker instead of selecting a tab. A check asserts no key ending in `block`
or `colour` is a stepper row under **any** group, OTHER included.

### The compass is available and is per-player

`CreativeGame.client_onCreate` calls `sm.gui.createCompassHudGui()` and stores it
in the global `g_compassHud` (`Data/Scripts/game/CreativeGame.lua:181`), so any
Custom Game that calls its parent inherits a working compass. Vanilla's own calls
give the shapes:

    g_compassHud:compassAddIcon( name, icon, stacking, w, h )   RaidManager.lua:1174
    g_compassHud:compassAddIcon( name, icon )                   LostItems.lua:91
    g_compassHud:compassSetIconWorldPosition( name, position )  RaidManager.lua:1175
    g_compassHud:compassSetIconStacking( name, false )          RaidManager.lua:1176
    g_compassHud:compassPingMarker( name, effect )              RaidManager.lua:1228
    g_compassHud:setVisible( name, bool )                       BaseEnemyCharacter.lua:26
    g_compassHud:compassRemoveIcon( name )                      BaseEnemyCharacter.lua:43

Icons live in `Data/Gui/Resolutions/*/Compass/`. It is that client's own HUD, so
a marker is private to one player with no work — which is the property a
per-player plot marker needs.

**Pass no width or height for a square icon.** Almost every compass icon the game
ships is 33x33; the one vanilla call that passes a width — `RaidManager.lua:1174`,
`( name, icon, true, 32 )` — is for `icon_compass_dropcargo.png`, which is 48x30.
Copying that call for a square icon stretches it. `LostItems.lua:91` is the
precedent to follow: `compassAddIcon( name, icon )`, name and file and nothing
else, and the engine draws it at its own size.

### A CHARACTER SCRIPT'S GLOBALS ARE SHARED, AND ITS INSTANCES ARE NOT ON ONE THREAD

**This cost two versions and the first diagnosis was wrong**, which is the part
worth keeping.

The crowd bot's wardrobe was a global table. Every bot threw:

    ERROR: ...BotCharacter.lua:525: attempt to call field 'Name' (a nil value)
         [Logic Task:25332]   [Logic Task:4764]   [Logic Task:22328]

REPORTED as *"BOTS WORK! just without the skins stuff"* -- exactly right, because
the unit half is server-side and never touched the wardrobe, so the bots spawned,
walked and collided perfectly while wearing the characterset's fallback.

**Round one blamed `dofile`.** The wardrobe was its own `Scripts/Wardrobe.lua`,
and twelve vanilla character scripts all `dofile` `$SURVIVAL_DATA` paths and
never mod content -- a tidy story, and wrong. Moving the whole table INTO
`BotCharacter.lua`, four hundred lines above its only caller, produced the
identical error.

**That second measurement is what settles it.** The chunk plainly ran past the
definitions: `BotCharacter` itself is declared a hundred lines BELOW them and the
engine found it. And `Wardrobe` was still a *table* when it was indexed, or Lua
would have said "index a nil value" rather than "call field". So the table
existed and was EMPTY.

The thread ids are the tell -- they differ between bursts, and the bursts share a
timestamp. **The engine instantiates a character script per character, on its own
logic task, and `Wardrobe = {}` at the top of one instance's chunk blanks the
shared global that another instance's callback is halfway through reading.**
Twenty bots spawning at once is twenty chunks racing one assignment.

**The rule: in a character or unit script, anything shared between the chunk and
its callbacks must be an upvalue, never a global.** Assigning a global is fine --
the engine finds the class that way, and `dev/test_logic.py` reaches the wardrobe
that way -- but *reading one back* is the bug. A field on the class table is the
same mistake wearing a hat: one table, every instance.

`dev/test_logic.py` now enforces it over every script a characterset names, and
reverting the `local` fails it.

Two smaller things from the same session:

- **A `pcall` around the wrong half proves nothing.** The appearance call *was*
  guarded and logged-once. The line that threw was one line above the guard.
- **`dev/sync_mod.py` now PRUNES.** A script deleted from the repo used to stay
  in the Mods folder forever and the engine compiles every `.lua` it finds there,
  so the orphaned `Wardrobe.lua` was still being loaded after it was removed from
  the project. Same class as the stale `Cache/`. Pruning skips `Cache/`,
  `Snapshots/` and the root-level json the game writes.

### The dofile question, answered and set aside

Worth recording only so nobody re-runs the experiment. Round one of the bug above
blamed `dofile`: `BotCharacter.lua` loaded its wardrobe with
`dofile( "$CONTENT_DATA/Scripts/Wardrobe.lua" )`, and it is true that **twelve
vanilla character scripts call `dofile` and every one of them loads a
`$SURVIVAL_DATA` path -- not one loads mod content**.

But the engine's own log shows our file being found and compiled:

    Raw cache miss! Path: '$CONTENT_<uuid>/Scripts/BotCharacter.lua'
    Raw cache miss! Path: '$CONTENT_<uuid>/Scripts/Wardrobe.lua'

and inlining the whole table into the calling file reproduced the error exactly.
So **`dofile` of mod content from a character script works**, and the tidy story
about vanilla never doing it was a correlation, not the cause. The cause is the
shared global, above.

The lesson is the method, not the fact: a plausible explanation that matches the
evidence is not the same as the one that survives being tested against a second
measurement.

### A 50/50 SPLIT IS NOT THE SAME THING AS RANDOM

REPORTED: *"make sure gender is random too"* -- about a generator that was
already producing exactly 50% male over 200 bots and passing a ratio check.

The sequence over consecutive character ids was:

    M f M f M f M f M f M f M f M f M f f M

Perfect alternation. Two bots standing next to each other could never be the same
sex, which is what you notice in a crowd of five, and the ratio test could not
see it because the ratio was right.

**The cause is structural.** An LCG is affine over 2^32, so for adjacent seeds
the state moves in lockstep -- and asking for `n = 2` uses exactly one bit. More
LCG rounds do not help: a composition of affine maps is affine. Breaking it needs
one step that is not affine over the integers, and Lua 5.1 has no bitwise
operators, so the cheapest is **exchanging the 16-bit halves** -- a bit
permutation, linear over GF(2) but not over Z, so composed with the LCG neither
structure survives.

MEASURED over the same 24 seeds: 11 runs instead of 23, where a fair coin
averages 12. Within one generator, 22 runs in 40. Buckets stay flat for n = 2, 3,
5 and 10 and the percentage gates land within 0.2 points.

The general rule, which is the part worth keeping: **a distribution check cannot
see a pattern.** Test the SEQUENCE -- count runs -- whenever a small-n choice is
derived from consecutive seeds. `dev/test_logic.py` does, and reverting the
half-swap fails it.

### There is no skin-colour channel -- the HEAD is the skin

Asked for as *"make the skin colours beards and others randomizable too"*. Beards
already were (ten, male, rolled at 55%); skin needs the correction.

There is nothing to tint. A head renderable carries its own skin: open
`char_male_head02.rend` and the `skin` submesh points at
`char_male_head02_dif.tga` -- its own texture, its own tone. **So picking a head
at random IS picking a skin at random**, and there are fifteen (7 male, 8 female)
plus two more in the classic set. The only tint binding on a character is
`setColor`, which is what makes a totebot red; on a human it would tint the whole
model, and it is not a skin channel.

The real lever for variety is a second ART SET, not a colour. `Data/Character/Char_Classic`
is the original mechanic -- seven renderables that replace the whole body at once
(head, chest, hands, feet, legs, hair, backpack; no jacket/pants/shoes, because
the chest and legs already are those). It is also what
`Data/Character/CharacterSets/default.json` dresses the **player** in, so a
classic bot wears exactly what a real player's character is built from. Roughly
one bot in four is classic, and `dev/check_uuids.py` resolves all 98 renderable
paths against the install on every build.

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

### The city floor is pinned in every profile EXCEPT while people are building

`PROFILES.open` — the profile the whole city runs under during **build time** —
sets `liftable = true` and `convertibleToDynamic = true`. A plot slab is not
scenery (`sv_isScenery` needs every shape to be metal; a plot has concrete in
it), so during an event **every plot floor in the city was liftable and
convertible**: anyone with a lift could carry off somebody's plot, and a slab
that converts to dynamic is a floating object with nothing holding it.

`World.sv_pinCity` does set both false at import. The patrol reapplies the full
profile over the top of it seconds later, so that pinning never survived. **It
has to be in the profile or it does not exist.**

Every profile now has a twin with those two flags forced false, and
`Protection.sv_setGroundTest` decides which bodies get the twin —
`Plots.sv_isGround`, one AABB call, because the heights are unambiguous: the deck
is at z 0.75, a plot slab at 1.00, and anything merely *standing* on the floor
starts at 1.25. A build welded to a slab shares the slab's body and is pinned
with it, which is correct: it is part of the ground now.

**But NOT during build time.** *"the stand the plot is on. and the plot it self
shall be destructuble and placable. aka not protected when build time."* While
the clock is running, a plot and the stand under it belong to whoever is
building on them; presence enforcement is what keeps that to their own plot, not
a flag on the body. `GROUND_FREE` names the modes that skip the pin, and it is
`open` and `open_destructible` only.

Every other mode still pins, which is when pinning earns its keep — nobody should
be able to lift a plot away during prep, during the buffer, after the event has
ended, or under a `/lockdown`.

Note that `locked` and `display` are already `liftable = false` in their own
right, so the pin only *changes* anything for `polish` and `open`. The check
tests `polish` for exactly that reason; testing `locked` would pass whatever the
code did.

A check asserts every return path in `profileFor` goes through the pin, and it
runs the real resolver rather than reading the table.

### NEVER locate a body by `body.worldPosition`

It is the body's own **origin**, not where the body is. Every piece of this city
is imported at `sm.vec3.zero()` because the blueprint carries absolute block
coordinates, so an origin can report a point nowhere near the thing on screen.

**MEASURED by its symptoms**: *"I cant place blocks on the concrete but I can
delete it. I can delete others plots."* buildable false with erasable true is
exactly one profile out of six — `sweep` — which is what `sv_bodyIsOpen` returns
for a body it cannot place in the city at all. Every plot was being located
somewhere it was not and treated as litter.

Use `Plots.sv_bodyZone`, which takes the **centre of the AABB**. A check fails if
any file goes back to `sv_locate( body.worldPosition )`, and the city logs where
every one of its bodies actually landed after each build.

### Body flags are global, so "only build on your own tile" needs presence AND absence

If a plot body is buildable, it is buildable **by everybody, from anywhere within
reach**. There is no per-player flag. Presence enforcement was only half of what
that requires:

- **occupied** → open only if every player standing there is authorised
  (unauthorised ones are pushed out)
- **empty and claimed** → **LOCKED.** It used to stay open — "so owners are not
  locked out of empty plots" — which meant standing on the road beside somebody
  else's work and reaching over it, with the owner not even online.
- **empty and unclaimed** → open. Nothing to protect, and the host needs it.

`zoneHeld` stops the new rule locking somebody out of their own plot: an
authorised player standing anywhere on their team's land holds that whole team's
ground open, so stepping onto the one-block seam at the edge of your plot while
building does not lock the plot behind you.

### Our own materials are ordinary blocks — only HEIGHT AND PLACE tell them apart

Metal 2, metal 3 and concrete are what the city is made of *and* what people
build with. The only thing separating them is where they sit.

    our top layer   block z = DECK_Z    world z 1.00 .. 1.25
    their first     block z = DECK_Z+1  world z 1.25 .. 1.50

**And `shape.worldPosition` might be the minimum corner or the centre** — no
vanilla call settles it. With a threshold of 1.30 the min-corner reading put a
player's first block at exactly 1.25 and classed it as city floor: the cleaner
refused to delete it, and CLEAR CITY would have taken it. REPORTED as *"whatever
the block is metal 2 or concrete it counts as part of the city whatever of it
actualy being so."*

`Plots.CITY_CEILING` is `( DECK_Z + 0.75 ) * BLOCK` = **1.1875** — three quarters
of the way up our own layer, which gives the same answer under both readings with
room on either side. The check tests both.

**And height alone is not enough either.** A metal 2 block dropped on the terrain
*outside* the city is LOWER than our deck, so a pure height test called it city
floor and the cleaner refused to delete it — reported as *"I still cant remove
metal 2 via the tool. even if its not on the platform."* `sv_isCityShape` now
requires the shape to be inside the city footprint (`Layout.locate`), and below
the deck it must be inside an actual **stand** — so somebody building underneath
the platform still owns what they built.

`sv_isCityShape` is deliberately **not** on the patrol path; it runs on a
cleaner click, a `/purge`, a census and a rebuild, which is why it can afford a
`Layout.locate`. `CleanerTool` keeps a cruder copy for when it cannot see
`g_swPlots`: a narrow band at exactly our deck layer, since nothing of a
player's can be in it anyway.

### One body's `childs` array IS the weld group

**MEASURED**, from a reference creation the owner built in game and saved so the
structure could be read directly — *"concrete panel with metal all around it"*,
`Blueprints/038852d7`. Nine children, **one body**, concrete (`a6c6ce30`) and
metal 2 (`1016cafc`) side by side in the same array:

    bodies[0].childs = [ {metal2 21x1}, {metal2 1x22}, {metal2 1x21},
                         {concrete 16x12}, {metal2 20x1}, {concrete 8x8}, ... ]

That is the whole answer to "how are blocks connected in Scrap Mechanic".
**Same `childs` array = welded. Separate blueprints = separate bodies that merely
touch**, however perfectly they line up. Materials are irrelevant to it.

So each plot is now one body: a concrete pad with a metal ring welded round it,
which is exactly the reference creation. `Plots.BORDER` is the ring width; it
costs the outer ring of buildable area, so a 20-block plot gives an 18-block pad.

### SEPARATION IS THE DESIGN — a body is the unit the engine rebuilds

**This corrects V32, which had it exactly backwards, and it is the most important
structural fact about the city.**

Three reports read as "the city is not joined up" — *"the plot is not attached to
the rest of the build"*, *"I dont think the concrete sticks to the borders
still"* — so V32 welded a single slab under the whole footprint to tie it
together. The owner caught it:

> "the things NEED to be separated from the main city! in the original event they
> were separated with wedges so updating one block wont update whole city. but
> just the block! the block between the panels NEEDS to be detached. and each
> panel shall have its own stand!"

That is operational experience from an event they actually ran, and the mechanism
is the same one their blueprint showed: **a body is the unit the engine
rebuilds.** Change one block and the entire body it belongs to is reprocessed.
Weld a hundred plots into one city and every block anyone places, anywhere, costs
a rebuild of all of it — at an event with twenty people building at once, which
is goal 1 of this project.

So the city is deliberately **many** bodies, and nothing spans the footprint:

| piece | body |
|---|---|
| a plot | its metal ring, its concrete pad and **its own stand**, welded together |
| a street | its own body, welded to neither plot beside it |
| the plaza | one body, with the pillar under it |

Two checks hold the line: one asserts no piece spans the bounding box (the base
slab, asserted away) and one rasterises a plot in 3D to prove the ring, the pad
and the stand are one body with no block claimed twice.

There is a second, independent reason the plots cannot be welded to anything:
**body permission flags are per-BODY** — there is no `setBuildableBy( player )` —
so one plot per body is the only reason plot ownership can exist at all. Weld the
city and it is buildable by everyone or by nobody. Both reasons point the same
way.

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

### Everything a GUI button needs is in docs/BUTTONS.md

Three versions have gone on "the buttons dont work" and each fix was a real bug
that turned out not to be the whole story. `docs/BUTTONS.md` is the checklist,
with the vanilla file and line behind every rule, and it separates what is
**confirmed** from what is **not yet known**. Read it before touching a panel.

**SETTLED, 2026-08-24, in game — the buttons work.** A Game script *does*
receive jsonGui clicks, and a widget tree built in Lua is fine. Both of the
things that looked suspicious about our arrangement were innocent.

Four separate bugs were stacked on top of each other, each one alone enough to
make every button look dead, each one hiding the next:

1. `UpgradeButton` is a progress bar and drew no caption *(V26)*
2. three fonts were glyph-limited or did not exist *(V29)*
3. the hub closed its GUI **inside the click callback**, killing the rest of it
   *(V30)*
4. each panel made **its own** interactive GUI, and a json GUI has no
   `destroy()` *(V32)*

The tell that cracked it was a screenshot: the entries that failed were exactly
the ones that opened a **second panel**; the ones that worked answered in
**chat**. `/guitest` stays in the mod — five tests, client-only — as the fastest
way to re-establish ground truth after a game update.

### NEVER close OR REDRAW a json GUI from inside its own callback

**This one bug accounted for every "the buttons dont work" report in the
project**, across three versions, and it is a single line of ordering:

    function Game.cl_onMenuClick( self, widgetName, data )
        self:cl_closeMenu()                                 -- destroys the widget
        self.network:sendToServer( "sv_n_menuOpen", ... )   -- never runs

`close()` destroys the widget whose `onClick` is **currently on the Lua stack**,
and the engine tears the callback down with it. Everything after the close is
dead code. There is no Lua error — the only trace it leaves is an engine assert:

    ERROR: ASSERT: 'itrStackWalk != m_vecLastMethodStack.rend()' : LuaVM.cpp:716

**Vanilla never does it.** `CreativePlayer.cl_e_unstuckYes` sends first and
closes last (`Data/Scripts/game/CreativePlayer.lua:48`), and so does every other
jsonGui in the base game.

The correlation across our own six handlers is what proves this rather than
merely suggests it. The three that sent before closing all worked — BUILD CITY
built a city, the event panel started events, the settings panel applied presets,
each visible in the logs. The three that closed first did nothing at all, every
time. **The hub menu was one of them, and every host feature is reached through
the hub** — which is why "I am the host why cant I access features" and "I click
on city layout and it does nothing" were the same bug, eight versions apart.

Ordering alone fixes it, but ordering is a rule somebody has to remember every
time. So closes are **queued and drained on the next tick** (`cl_closeLater` /
`cl_drainCloses`), which makes it structurally impossible: a widget cannot be
destroyed while its own callback is running, because that callback has returned.
A check asserts no `cl_on*` handler calls a closer directly.

**A REDRAW is the same hazard, and it is worse.** Building a new tree destroys
every widget the old one had, including the one whose callback is running. For a
click that silently killed the handler. For an **EditBox** — which also holds the
keyboard focus — it **crashed the game outright**: *"game crashed when I tried to
change the number of build time"*, and the log ends mid-line with no Lua error
and no shutdown sequence.

Vanilla does render from inside a text callback (`DigitalSign.lua:149`) — but it
re-renders the **same table**, mutated in place. Building a fresh tree is not the
same thing, and the difference is a native crash.

So redraws are queued too: `cl_renderLater` / `cl_drainRenders`, drained beside
the closes at the top of `client_onFixedUpdate`. One tick of latency on a
stepper press is imperceptible; the bug class is gone.

Corollary: **an `onClose` handler must only drop the handle**, never call
`close()` again — that is the same bug from the other direction.

The check forbids any `cl_on*` handler from calling `cl_showPanel` or a closer
directly.

### A panel that closes on every click cannot be told from a broken one

REPORTED: *"you should fix the buttons. since they sadly dont work. like I mean I
press them and menu closes."* There was exactly **one** dead button in that build
— CLEAR CITY sent `/citycensus` to the world and `World.sv_e_swCommand` had no
branch for it — and from the outside it was indistinguishable from the nine live
ones, because every button closed its own panel whether it worked or not.

The convention now, and every panel follows it:

- **only CLOSE and BACK close a panel.** An action runs, the server re-sends the
  panel's whole state, and it re-renders in place.
- **every panel carries a status line** under its header saying what the last
  press did. It is the only feedback a click gets.
- **a confirmation is modal**: it closes whatever asked it and names, in `back`,
  what to reopen afterwards.
- **replies are collected, not just chatted.** A world command sent by a panel
  carries `panel = "..."`; `sv_e_swCommand` gathers every `reply()` into a status
  line for it. Chat is behind the panel; the person who just pressed a button is
  looking at the button.

Two checks in `dev/test_logic.py` walk that plumbing from both ends — every
`sv_toWorld("...")` string in `Game.lua` must have a `cmd == "..."` branch in
`World.lua`, and every `action = "..."` a panel can emit must be named in
`Game.lua`. Both are string matching, but a name that appears on one side of the
bridge and nowhere on the other is always a bug, and it was this one.

### F is `ForceBuild`, and a TOOL is the only script that can see a key

**MEASURED**, from the owner's own `User_<id>/keybinds.json`:
`"ForceBuild": [ { "K": 70 } ]`, and 70 is F.

That action reaches Lua in exactly one place — the **third argument of a tool's
equipped update**:

    client_onEquippedUpdate( self, primaryState, secondaryState, forceBuild )

(`Survival/Scripts/game/tools/Bucket.lua:429`, `ClayRifle.lua:570`.) A Game
script, a World script and a player script are handed **no key state at all**;
`client_onAction` exists only on interactables that lock the player — seats,
beds, kinematics. So if a feature needs a key press, it has to live in a tool.

Combined with "a toolset can ADD but not OVERRIDE", that gives exactly one shape
for a key-driven feature: **a new tool with a new uuid.** That is `CleanerTool` —
point at anything, click to delete the block, hold **F** to delete the whole
creation. It is the only thing in the mod that can remove a carryable prop,
because those are *picked up* by the remove tool rather than erased and no
permission flag reaches them; script-side `destroyShape()` ignores every flag.

A tool script may not share the Game/World Lua environment, so anything it needs
from `Settings` or `g_swPlots` is guarded and has a local fallback that fails
safe — host-only if the settings are unreachable, "this is city floor" if the
shape cannot be classified.

Note also that a tool's network has `sendToServer` and `sendToClients`; no
vanilla tool ever calls `sendToClient( player, ... )`. Replies go through
`Game.sv_e_swReply`, the same bridge the World script uses.

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
(`wrap_Profiler.cpp` *is* in the binary, and exposes **zero** bindings — the string
run after its marker belongs to `wrap_Storage.cpp`. The claim above is confirmed,
not assumed.)

### The engine hands over ONE multiplayer number, and it needs exactly one guest

    WARNING: NetworkServer.cpp:231 Skip sending unreliable network data
             to client 76561199070209586 Budget is currently: -280930

The host giving up on sending a client its state for that tick, because that
client's send budget is exhausted. One line is one tick a player never received.
It is the only "the server cannot keep up with this player" signal that exists,
and unlike tick rate it is **per client**.

**MEASURED** over all 150 `game-*.log` in this install:

- It only ever names a **remote** client — never the host's own loopback id, not
  once. So a solo session cannot produce one, and neither can a crowd of bots.
- The budget is per client and **independent**, so **one guest measures it as
  well as twenty would.** Twenty multiplies the *host's* upload, which is
  arithmetic on a measured per-client rate, not a second measurement.
- A budget of exactly `0` in the first seconds is the uninitialised counter, not
  a drop. Only negative values are data being lost.

**And it already points somewhere.** `game-20260710-192923.log` is five players,
tick rate a median **39.8** against a healthy 40 — the simulation was fine, just
as it was in the 19-player session below. In that same session **three clients
were starved 371 times, one of them 856 KB over budget.** That is the first
thing this project has measured that degrades *before* the tick rate does, and it
agrees with the one real event on record, where client frame rate slid while the
player count stayed flat. What caused it — content, count, or what was being
built — is **not** established. `dev/session_stats.py` now reports it per client.

### Emulating players: `/crowd`, and what it can and cannot stand in for

**The whole argument is in [`docs/CROWD.md`](docs/CROWD.md).** Read it before
trusting any number that came out of a bot session.

The short version. `/crowd N` puts N human-model bots on the city — named,
randomly dressed, wandering, optionally claiming plots and placing and removing
blocks. They are real characters at real positions, handed to
`Plots.sv_updateOccupancy` as real occupants, so the per-player Lua does its true
work against true geometry rather than against a fabricated player list.

What that covers: physics per capsule, character replication, body churn, and
every per-player code path in this mod. What it **cannot** cover, ever: a real
client connection with its own network budget, and a second machine's rendering.
Those two are why one guest joining once is still required, and why `/crowd` is
not a substitute for it.

**`/bench start` runs the whole experiment for you** -- it walks the crowd up in
steps, holds each size still, and records frame rate, tick rate, shape and body
count per step to chat, to the log and to `$CONTENT_DATA/Bench.json`
(`dev/bench_report.py` reads it). One thing about it is worth knowing before
touching it, because getting it wrong produces a benchmark that reports perfect
health under any load:

**There is no clock in this engine's Lua.** `os` does not exist, and
`sm.game.getCurrentTick()` is the simulation counter -- the very thing being
measured, so it cannot also be the reference. The only real-time quantity Lua can
see is the `dt` passed to `client_onUpdate`, which is wall-clock seconds (proven
by `timeOfDay + dt / DAYCYCLE_TIME`, `CreativeGame.lua:208`). So the **host's
client is the stopwatch**, reporting frames, seconds and ticks once a second, all
three as **deltas over the same interval**. Sending the absolute tick and
differencing the window's ends instead loses one interval in N: a clean 40 Hz
server reported **36**, and nothing about 36 looks wrong. `dev/test_logic.py`
found it and now guards it.

Three leads were ruled out getting there, recorded so nobody spends a day on them
twice: **`setParallelLimit` is not a threading knob** (it is in
`wrap_Interactable.cpp`, next to `setInteractableCondition` — pipe logic);
**`sm.character.createCharacter` takes a *player*** and is not a route to a
free-standing puppet; and **`unit_mechanic` is the null uuid**, used by vanilla
only as a type test and never passed to `createUnit`.

**The executable has a command-line parser, and one flag in it is worth a test.**
`Main.cpp` parses `-open <path>` `-builtin_mods_only` `-dedicated_server`
`-console` `-dev` `-window` `-fps` `--ugc` `-last_save` `-tileeditor`
`-no_popcnt` `-no_profiler` `-max_threads` `-use_null_driver`
`-select_custom_gpu` `-enable_flip_discard`, plus `-connect_steam_id <id>`.
**Untested.** `-dedicated_server` is a bare flag with no supporting strings
anywhere in the binary — no `DedicatedServer.cpp`, only `ListenServer.cpp` — so
it is plausibly a dead dev stub. `-use_null_driver` is the interesting partner: a
renderer-less client would be cheap to run several of. Two minutes to find out;
nobody has spent them.

### The biggest city this mod can lay out does not dent the tick rate

**MEASURED, 2026-08-25**, from `dev/session_stats.py` over
`Logs/game-20260825-204149.log`, after the owner deliberately tried the largest
city setting available:

    [ServerWorks] city built: 384 plots, 0 failed        20:50:56

    tick/s   median 39.9   (healthy = 40)
    frame/s  median 58.9

    20:50  tick 39.7  frame 58.3     <- the minute the 384-plot city was built
    20:52  tick 39.9  frame 58.9

The one window below target in that whole session is `20:42, tick 8.3` -- which
is the WORLD LOAD, forty seconds before the game state even starts, not the city
build. Building 384 plots cost 0.2 Hz of a 40 Hz tick and nothing measurable in
frame rate, and nothing failed.

That is the first direct evidence for goal 1 that comes from this mod's own city
rather than from a vanilla event, and it points the same way the 2026-08-22
session did: **the simulation is not where this project's headroom goes.** Note
what it does NOT say -- this was one player on an empty city. Twenty people
building on 384 plots is still unmeasured, and client frame rate degrading with
accumulated content remains the thing that actually got worse in the only real
event on record.

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
    mod/config.json             baseGameContent "Survival" -- the ONLY value that
                                works; "Creative" registers no scriptable objects
                                and CreativeGame then never creates a world
    mod/Scripts/Game.lua        class(CreativeGame); commands; timers; grief alarm
    mod/Scripts/Player.lua      class(CreativePlayer)
    mod/Scripts/World.lua       class(CreativeFlatWorld); stops explosion cratering
    mod/Scripts/Protection.lua  the anti-grief freeze + shape census
    mod/Scripts/Identity.lua    perma ids, aliases, persistent ban list
    mod/Scripts/Plots.lua       claimable grid, teaming, presence enforcement
    mod/Scripts/Settings.lua    every host toggle, one schema
    mod/Scripts/Snapshots.lua   world and per-plot capture and rollback

    mod/Scripts/Layout.lua      ALL city geometry, pure -- no sm.* calls at all
    mod/Scripts/Palette.lua     the paint tool's 40 colours + the city's blocks
    mod/Scripts/Event.lua       the clock: prep -> build -> buffer -> ended
    mod/Scripts/EventGui.lua    the host panel for it, so nothing needs typing
    mod/Scripts/ConfirmGui.lua  two doors in front of anything destructive
    mod/Scripts/EventHud.lua    top-right timer + handover to the warehouse timer
    mod/Scripts/RosterHud.lua   top-left: who is online, and how many residents
    mod/Scripts/StyleGui.lua    what the city is made of: block list + paint palette
    mod/Scripts/MyPlotGui.lua   the panel players use: claim, find, team, leave
    mod/Scripts/PlotMarker.lua  "find my plot", on the game's own compass HUD
                                driven from Player.lua -- compassSetIconWorldPosition
                                is world-dependent and Game.lua has no world

    mod/Scripts/Crowd.lua       /crowd -- a lobby of bots, when there is no lobby
    mod/Scripts/Bench.lua       /bench -- walk the crowd up, record fps and tick
    mod/Scripts/BotUnit.lua     one bot's server half: where it walks
    mod/Scripts/BotCharacter.lua its client half: name tag, clothes, wardrobe
                                98 renderables and 960 names, all in ONE file --
                                see "a character script cannot dofile mod content"
    mod/Characters/Database/    the crowd bot's character set. No Workshop mod
                                ships one of these; the template is the only prior art

    mod/Scripts/GuiProbe.lua    /guitest -- the button experiment, client only
    mod/Scripts/CleanerTool.lua the only thing that can delete a carryable prop
    mod/Scripts/NotLift.lua     NOTlift -- imports a saved creation. Host only
    mod/Gui/IconMap.xml/.png    custom menu icons (NOTlift, Cleaner)

    dev/check_all.py            all four checks below; --sync installs afterwards
    dev/check_lua.py            compiles every mod script through a real Lua parser
    dev/check_uuids.py          every uuid the mod names, against the install
    dev/test_layout.py          runs Layout.lua and proves the city is a partition
    dev/test_logic.py           runs the mod's rules and panel layouts (110 checks)
    dev/sync_mod.py             repo -> game Mods folder (preserves live BanList.json)
    dev/session_stats.py        tick/FPS reconstruction from any game log,
                                plus the per-client network budget skips
    dev/bench_report.py         the table /bench wrote, out of Bench.json
    dev/dump_api.py             per-module Lua bindings out of the executable

### Three tools, and why there are not more

`nugdupS` (the stale-mod canary), `NOTlift` (imports a creation) and the
`Cleaner` (deletes anything, including lifts and carryable props). Both real
tools carry a custom icon, because both would otherwise be indistinguishable
from something else in the menu -- NOTlift draws the lift's preview renderable
and the Cleaner IS a sledgehammer subclass. The Cleaner is also tinted red in the
hand (`setTpColor`/`setFpColor`), since a held model cannot be crossed out
without new 3D content.

**Two lifts were added and both have been removed.** `5cc12f03`, the creative
lift, was added because `baseGameContent: "Survival"` never loads the creative
tool index -- and it worked, but survival's own `8f190ce2` is the same tool for
every purpose that survives here (`SurvivalLift` is `class( Lift )` with one live
method), so it only ever put a second identical lift in the menu. `4c893da9`,
the Import Lift, was a workaround for a creations menu that no lift in this game
opens. NOTlift does the importing now.

What is left is survival's lift, which is base content and cannot be removed. It
is host-gated by `hostlift`.

Commands, all host-only: `/lockdown` `/unlock` `/protection` `/buildtime` `/autosave`
`/snapshot` `/snapshots` `/restore` `/players` `/ban` `/unban` `/banlist` `/kick`
`/citystyle` `/nolift` `/crowd` `/bench`. `/budget` and `/players` are open to
everyone.

Diagnostics, kept because they settle questions in one command rather than
an argument: `/guitest` (json GUI buttons), `/bptest` and `/bptest2` (can we read a
blueprint, will the browser open), `/tool` (what is in your hand and what gates it).

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

1. **`baseGameContent: "Survival"` + a `CreativeGame` subclass.** No Workshop
   Custom Game pairs those (they use Survival+SurvivalGame, or Creative+own
   class). **Do not "fix" that by flipping to `"Creative"` — it cannot create a
   world.** See the `baseGameContent` section above; `dev/check_uuids.py` now
   fails the build if anyone tries.

   **It has misbehaved once, and the fix was small.** Survival content wins any
   uuid the two modes share, so you get the *survival* version of a shared tool:
   `Sledgehammer.lua` reads `clientPublicData.perks`, which `SurvivalPlayer` sets
   and `CreativePlayer` does not, and threw once per client frame → fixed by two
   overrides in `Player.lua`.

2. **`sm.creation.importFromString`'s last two arguments.** Vanilla passes `true, true`
   in `BuilderWorld` and only five arguments in `MenuWorld`; the meaning is not documented
   anywhere and was not derivable from the binding names.
3. ~~**Whether `sm.json.save` can write into an installed mod's directory at
   runtime.**~~ **ANSWERED, and it can.** The installed mod's `Snapshots/`
   directory holds 341 KB files the game wrote itself, alongside a live
   `Settings.json`, `Players.json`, `Plots.json` and `Event.json`. Found by
   reading the folder, not by running a test.

   The advice that follows from it still stands for a different reason: Workshop
   mods are replaced wholesale on update, so the master ban list should live
   outside the mod and be synced in regardless. Not because the write fails —
   because the file gets overwritten.

   The same folder settles two more: **snapshot capture works and the export is
   real** (195 entries, 676 children, exactly the six shape/colour pairs a
   96-plot city is made of), and **V50's phase snapshots fire in order** —
   prepstart, buildstart, buildend, eventend, one minute apart. `RESTORE` is
   still untested; capture and restore are different halves. See
   [`docs/STATUS.md`](docs/STATUS.md).

Every one of those is guarded with `pcall` and logs once rather than per tick.

## Where to start reading

**[`docs/NEXT.md`](docs/NEXT.md) is the handover** — what is done, what has never
been run in a real event, what the next step is, and which decisions are waiting
on the owner. Start there.

Two companions to it, and the first one matters most:

- **[`docs/STATUS.md`](docs/STATUS.md) — the honest ledger.** Which features have
  been *seen working in game*, which were seen broken and have a fix that has
  never been re-tested, and which have never been executed at all. Every other
  document here describes what the code is meant to do; that one says what has
  actually been observed. `check_all.py` passing is not evidence, and it says so.
- **[`docs/ROADMAP.md`](docs/ROADMAP.md)** — the phased plan. Phase 1 is not a
  feature: it is a step-by-step session that turns red ledger lines green, with
  the log line that settles each one.

The next step is the **per-tile part limit**: `Rules.lua` already enforces the
2026-08-22 rules board, including rule 10 -- ten bearings, pistons and
suspensions **combined** per plot -- and none of it has been exercised in game.

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
- ~~Is there a group available for the phase-0 load test?~~ **ANSWERED 2026-08-25: no.**
  The owner has no lobby of their own. The 19-player session that this file cites was
  **somebody else's server, joined as a guest** -- the log loads City Building MMO, not
  this mod. So phase 0 as written cannot run, and no multi-player number can come from a
  real lobby. What is still reachable solo: content/simulation load (which is where this
  mod's own overhead lives), and the per-client network budget warnings the engine
  already logs. ~~Emulating players is being researched separately.~~
  **ANSWERED: `/crowd`, and it goes only so far.** See
  [`docs/CROWD.md`](docs/CROWD.md). The important correction to the sentence
  above is that **the per-client network budget is NOT reachable solo** -- the
  engine only computes one for a remote client, measured over every log here. It
  needs one guest, and one guest is enough, because the budget is per client.
- How much of vanilla creative survives? `CreativeGame` brings tapebots (`UnitManager`,
  `aggroCreations = true`), weather and water managers by default, and they cost real CPU on
  an event server.
