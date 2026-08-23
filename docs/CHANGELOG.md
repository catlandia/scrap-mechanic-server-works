# Changelog

The version is on the mod thumbnail, so a host can tell which build a machine is
running from the Custom Game list without opening a file. `VERSION` holds it —
**not** `description.json`, whose `version` is the game content version and must
stay `1` for a Custom Game on this build.

Bugs below are marked **MEASURED** where the game log named them outright, which
was most of them.

---

## V25 — the lift, for real this time

### There are two lifts, and this game only had the wrong one

Third attempt, and the first one built on evidence rather than inference.

The game log prints the class every uuid resolves to at the moment a tool is
created. Ours said, in every single session:

    Created Tool 18 of type {8f190ce2-3a59-423e-8483-a7aa67bd5bc0(SurvivalLift)}

Two things follow, and both were believed otherwise.

**A Custom Game's toolset cannot override a uuid the base content declares.** It
can only ADD. First declaration wins and the mod's is loaded last. The proof it
is precedence and not a broken file sits in the same toolset: the nugdupS canary,
a uuid nothing else declares, resolves exactly as written. So V19's lift override
and V22's `GuardedClayRifle` / `GuardedPotatoLauncher` **never ran** — and what
actually stopped the clay gun was the client-side `forceTool` guard that shipped
in the same build and got none of the credit.

**The creative lift is a different item entirely.**

| uuid | class | declared by |
|---|---|---|
| `5cc12f03` | `Lift` | `Data/Tools/ToolSets/tools.json`, named `tool_lift_creative` at `ChallengeData/Scripts/game/challenge_tools.lua:2` |
| `8f190ce2` | `SurvivalLift` | `Survival/Tools/ToolSets/tools.json:44` |

`baseGameContent: "Survival"` loads `Survival/Tools/toolsets.json`, which never
lists the creative index — so this game had only the survival lift, and no amount
of Lua was going to change that. The blueprint menu the **E** key opens is
engine-side: `GarageImportGui` driving `Data/Gui/Layouts/Lift/Lift_Import.layout`.

The fix is one toolset entry adding `5cc12f03`, which is the case that provably
works. **Unconfirmed in game** — it is a strong inference from three independent
pieces of evidence, not a measurement.

### Find my plot

`g_compassHud` already exists in our game: `CreativeGame.client_onCreate` calls
`sm.gui.createCompassHudGui()` and we call that parent. So the compass needed
pointing at something, not building. Claiming a plot, `/home`, or joining an
event you already own ground in now puts a marker on it. It is that client's own
HUD, so nobody else sees it — *"only they can see it so it doesnt interfier"*
comes free.

### /myplot

Claiming was a typed command, run while standing in the right square, answered by
a line of chat that scrolls away. Now one panel: what you own, what you are
standing on, who is on your team, a live map with your plot in green — and
buttons to claim it, find it again, or give it up. The hint line under the
buttons says why CLAIM will not do anything when it will not.

`/players` marks the host, because "who has the buttons" is a fair question and
there was no way to answer it.

### Removed

`dev/check_uuids.py` now reads `baseGameContent` and indexes only the tool
databases that setting actually loads — which is what turns "this uuid exists
somewhere in the install" into the useful question, "does this uuid exist in
*our* game". It immediately found a second dead uuid: the creative sledgehammer
`ed185725`, which our settings had been gating for nothing.

## V24 — the lift, the city, and a test harness that runs the mod

### The lift finally has the right cause, and V19's was wrong

Reported twice: *"I cant use the lift to spawn creations"*. V19 blamed survival
owning uuid `8f190ce2` and pointed the toolset at creative's `Lift` instead.
**That diagnosis was wrong.** `SurvivalLift = class( Lift )` with exactly one
live method — `client_onUpdate`, calling `setBlockSprint` — and the rest of the
file inside a `--[[ ]]` block. It inherits every piece of blueprint handling
there is. V19 swapped a working class for an identical one.

The real cause was ours. Picking a creation out of the blueprint menu does not
hand the lift a picture of a build: **it spawns real bodies into the world,
marked as ghosts.** Vanilla proves it — `Lift.client_onForceTool( self, bodies )`
takes body objects and `Lift.sv_n_removeGhostBody` calls `body:destroyCreation()`
on one. So a ghost turns up in `sm.body.getAllBodies()` like anything else, and
the protection patrol reached it within a fraction of a second and pinned
`convertibleToDynamic = false` on it. **A ghost that cannot convert to dynamic
cannot become a creation** — silently, with nothing in the log.

`body:isGhost()` is a real binding (`python dev/dump_api.py Body`). Ghosts are
now invisible to everything the mod does: not protected, not counted in the
shape census that arms the grief alarm, not captured into a snapshot, not
counted against a plot's part budget, not caught by any of the clear commands.

### The city is built from the middle outwards

*"the city maker is broken since some stuff is overlaid. make sure you start
building from the middle and going out of it."*

The old builder ran a grid from a corner and then skipped the plots that hit the
spawn plaza. Two rules for one shape. Three confirmed defects:

- **every coordinate landed on a half block.** Ten plots of 20 with 1-block
  seams is 209 across, so centring put the origin at −104.5 and every child of
  every blueprint at `x.5`.
- **3 of 9 vertical seams were never built.** A full-height strip that crossed
  the plaza band was discarded whole instead of split, so the city had three
  full-length gaps in it.
- **rebuilding laid a second city on top of the first.** `sv_clearFloor` found
  city bodies by `worldPosition.z <= 1.5 m`, and a plot slab with a build welded
  onto it has its body position dragged above that. The slab survived the clear
  and the rebuild imported another one into the same space. That is what
  "overlaid" looks like.

Now the plaza is not a hole punched in a grid — it is the **first thing on the
axis**, sitting on the origin, with plots laid outwards from its edge in both
directions. A plot can never overlap the plaza because it never starts inside
one, not because something checked. Where the two plaza bands cross is spawn;
where a band crosses plots is a grand avenue running out to the city edge.

Clearing is now by **shape** against the three city uuids at deck height, which
is exact and leaves a player's build alone.

### One geometry, three callers

`Layout.lua` is new and holds all of it. It is pure — no `sm.*` calls at all —
so the Game script, the World script and the client panel all compute the city
from the same code. `PlotsGui` used to carry a hand-copied mirror of the axis
under a comment reading *"the panel has to lay the city out the same way the
builder does or the map is a decoration that lies"*. It drifted, and the map
lied. The copy is gone.

Teaming now follows the seam rather than the grid: two plots may team up only
when the ground between them is a **filler**. A road between them, or the plaza,
means there is nothing to share — and that falls out of the segment list instead
of being a second rule to keep in step.

### Teams chain; links do not

*"the teams shall only be able to team if the plot is either behind, front, left,
right. nothing in between. unless another teammate connects."*

Half of that already held — a link was already refused for anything but an
orthogonal neighbour with a shared filler. The other half did not: teams were
**pairwise**, so A–B and B–C left A and C strangers.

A team is now the connected component over the link graph. A diagonal plot is a
teammate exactly when somebody links you both, and not otherwise. A filler is
shared across the whole team rather than only between two plots that exchanged a
request, so a ring of four teammates no longer has a locked strip through the
middle of its own land. Leaving cuts everyone who was only reachable through you.

Refusals now say which rule you hit — "corner to corner does not count", "too far
apart", "there is a road between you" — because "not a neighbour" is the one
message people argue with, and diagonal *looks* adjacent.

The city map paints your plot bright green and your team dark green, since a team
is a shape you cannot work out by looking at the grid.

### The mod can now be tested without the game

`lupa` embeds a real Lua interpreter, so the mod's own code can be executed
outside Scrap Mechanic.

- **`dev/test_layout.py`** runs `Layout.lua` over twelve configurations and
  rasterises every block of every piece: no block claimed twice, no gap, no
  fractional coordinate. This is the check that would have caught the overlay.
- **`dev/test_logic.py`** runs `Settings`, `Identity`, `Protection` and `Plots`
  against small honest stubs — 22 checks covering who may build where, whether a
  ban survives a restart, whether the profile sentinel still tells all five
  profiles apart (the V15 bug), whether the lift can ever land in the hazard list.

Neither can tell you anything about bodies, tools, GUIs or the network. Those
are still in-game work, and both files say so.

## V23 — one central pillar, roads, 2D map, /menu
- Plots lost their pillars. The deck is static and needs no support; 100 columns
  read as clutter. The city is one raised platform on its centre.
- **Roads** became a first-class thing, distinct from fillers. A filler is the
  one-block seam shared by two teamed neighbours; a road is a public street.
  Forced the grid off a uniform stride onto an explicit segment run with prefix
  sums. Verified 0 overlapping cells.
- The city panel draws a **top-down map** from the same axis function the builder
  uses, so it cannot drift from what gets built.
- `/menu` — the front door. Guests see only what they may open.

## V22 — disable the TOOL, not the item
- **MEASURED:** `took firelauncher from CyberSlime2077` ×12 in one second while
  the player stood holding it. **A creative inventory is infinite**
  (`enableLimitedInventory = false`), so stripping a slot refills instantly and
  reports success forever. That loop was also the chat spam.
- Clay gun and fire launcher now point at **subclasses of their real scripts**
  with the fire buttons swallowed. Subclass, not replace, so the setting still
  means something.
- A locked world forces every hazard tool off regardless of the panel.
- Found: `ClayRifle.client_onEquippedUpdate`'s 4th arg is `forceBuildActive`.
  **F is readable inside a tool script.**

## V21 — banned tools taken from the inventory
Superseded by V22. `forceTool( nil )` only *unequips*; the player picks it
straight back up.

## V20 — the lift is host only
`hostlift`, default on. The lift spawns whole saved creations, which is right for
a host and wrong for a lobby.

## V19 — give back the creative lift
- **Survival content wins a shared uuid.** `8f190ce2` resolved to `SurvivalLift`,
  which has no `sm.player.placeLift` and no blueprint handling — so the lift could
  not spawn creations, silently, with no error.
- Our toolset re-declares the uuid pointing at `$GAME_DATA/Scripts/game/Lift.lua`.
- Second instance of this class of bug; the first was `Sledgehammer` reading
  `clientPublicData.perks`.

## V17 — /purge look and /purge carry
Carryable props (gems, crates, harvestables) get *picked up* by the remove tool
rather than erased. `/purge look` raycasts and destroys what you point at.

## V16 — city layout panel, hazard tools bind the host
- `/plotmenu`, showing what the numbers mean before building anything.
- **The clay gun kept working because the HOST was exempt.** Hazard tools now
  bind everyone.

## V15 — the sentinel that made lockdown and show identical
- **Reported:** buttons still worked in lockdown. `matchesProfile` compared only
  `buildable` and `destructable`, which `locked`, `display` and `sweep` all share
  — so switching between them found every body "already correct" and applied
  nothing. Four flags now, verified unique by enumeration.

## V14 — destructibility is a setting
`destructable` was pinned false in *every* profile including open, so explosives
could never do anything even when enabled. Now follows `destructible`, but only
in open mode: a locked world stays locked.

## V13 — settings take effect, not just display
- **MEASURED:** `setting fire = false` logged, `Settings.json` written, no errors,
  nothing changed in the world. `Settings.Sv_Set` runs apply hooks from the **Game
  script**, and `sm.fire.setFireLimit` is world-dependent and threw — into a
  `pcall` that swallowed it silently.
- The world re-applies on `/settingschanged`. A failing hook now logs.

## V12 — /why, debris vacuum, tighter scenery test
- `/why` reports a body's zone and every permission flag. Three rounds of guessing
  why a lift would not work is two too many.
- Scenery detection required only "metal near the ground", so anyone building in
  metal had their creation classed as city and locked.
- `sm.debris.createBlackHole` vacuums explosion debris.

## V11 — settings panel buttons work
- **MEASURED:** `Unknown member 'open' in userdata`. A json GUI has no `open()`,
  the same way it has no `destroy()`. `render()` **is** the show.
- The onClick signature is `( self, widgetName, data )`, not `( self, data )`.

## V10 — the panel reopens; tool guard moved to the client
- **MEASURED:** `Unknown member 'destroy' in userdata`. One CLOSE press made the
  panel unopenable for the rest of the session.

## V8 — a real settings panel
The first version stretched `BackgroundPromptNarrow`, a 346×346 alert skin, over
660×560. Rebuilt at 1120×690 — `Handbook.gui` scale. The useful discovery:
`Widget + Skin WhiteSkin + Colour` is a tintable rectangle, so a whole panel can
be drawn with no bespoke texture.

## V5–V7 — the city
Built as a blueprint and imported, not block by block: blueprint children carry
`bounds`, so a 20×20 plot is **one shape, not 400**. Each plot imported separately
so `getCreationsFromBodies` does not collapse the city into one creation.

## V2 — the three bugs the first real run found
- **MEASURED:** `Calling world dependent functions in a no world script!` — a
  Game script has no world; `sm.body.*` cannot be called from it. Protection,
  Plots, Rules and Snapshots moved to `World.lua`.
- `/help` is a reserved command name.
- `Sledgehammer.lua:193` — `clientPublicData.perks` nil, the first Survival +
  Creative pairing bug.

## V1 — first build
2,638 lines, compiled, installed, never executed. Everything above is what
happened when it finally was.
