# Changelog

The version is on the mod thumbnail, so a host can tell which build a machine is
running from the Custom Game list without opening a file. `VERSION` holds it —
**not** `description.json`, whose `version` is the game content version and must
stay `1` for a Custom Game on this build.

Bugs below are marked **MEASURED** where the game log named them outright, which
was most of them.

---

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
