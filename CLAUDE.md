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
the blueprint menu that E opens is engine-side (`GarageImportGui` driving
`Data/Gui/Layouts/Lift/Lift_Import.layout`), so no Lua could bring it back. Our
toolset now adds `5cc12f03`, which is the case that works.

The general rule: **before blaming a script, check the uuid is even loaded.**

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

### GUI skins that draw no text

`UpgradeButton` is a progress bar. Given a Button and a Caption it renders the
bar and **silently drops the caption**, which reads as a broken widget rather
than as a styling mistake. `StyledButtonLarge` and `SecondaryButton` both draw
their text.

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

### The city floor must be PINNED in every profile

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

A check asserts every return path in `profileFor` goes through the pin.

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

### NEVER close a json GUI from inside its own callback

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

Corollary: **an `onClose` handler must only drop the handle**, never call
`close()` again — that is the same bug from the other direction.

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
    mod/Scripts/Event.lua       the clock: prep -> build -> buffer -> ended
    mod/Scripts/EventGui.lua    the host panel for it, so nothing needs typing
    mod/Scripts/ConfirmGui.lua  two doors in front of anything destructive
    mod/Scripts/EventHud.lua    top-right timer + handover to the warehouse timer
    mod/Scripts/MyPlotGui.lua   the panel players use: claim, find, team, leave
    mod/Scripts/PlotMarker.lua  "find my plot", on the game's own compass HUD
                                driven from Player.lua -- compassSetIconWorldPosition
                                is world-dependent and Game.lua has no world

    mod/Scripts/GuiProbe.lua    /guitest -- the button experiment, client only
    mod/Scripts/CleanerTool.lua the only thing that can delete a carryable prop

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

   The pattern to remember: **when a creative feature silently does nothing, check
   whether survival owns that uuid** — and then fix it in Lua, by overriding the
   method that broke, the way `Player.lua` does. **Not by re-declaring the uuid in
   our toolset: that does not work.** See "A Custom Game's toolset can ADD a tool"
   above.

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
