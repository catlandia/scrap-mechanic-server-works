# ARCHIVED — SCRAPSOLUTE CINEMA (scrapped 2026-08-22)

> Superseded. The project is now the Custom Game event server; see CLAUDE.md.
> Kept only because there is no git here and some engine facts below are still true.

# SCRAPSOLUTE CINEMA

## What this is

A **Scrap Mechanic mod** that fixes camera management for filming. The graphics are good;
the camera is the bottleneck. This mod is the camera department: detach it, re-angle it,
zoom it properly, mount it on a creation, and (where the engine allows) slow the world down.

There is exactly one user — the owner of this repo. Optimise for their filming workflow,
not for generality.

## The hard constraint

**It ships as a "Blocks and Parts" mod, never a Custom Game.**

This is non-negotiable and it drives every architectural decision. A Custom Game replaces
the world you play in; a Blocks and Parts mod is a checkbox on a Creative world, alongside
every other mod. Filming happens in the owner's real worlds and real builds, so the camera
has to travel to them.

Worth knowing the limit: only `CreativeModeMenu.layout` has a mod picker.
`SurvivalModeMenu.layout` has none, so a Blocks and Parts mod cannot be enabled on a
Survival save at all. Creative and Custom Games are the whole audience.

Everything in `docs/RESEARCH.md` exists because that constraint removes the easy routes:
we cannot ship a Game script, cannot replace `Player.lua`, cannot own the world. What we
*can* do is documented there, with evidence.

## Ground truth for this build

Researched against the installed game, not from memory. Redo it after any game update.

- Install: `D:\SteamLibrary\steamapps\common\Scrap Mechanic`
- Build id `24529696`, content stamped 2026-08-03. This is the post-update build.
- Local mods: `%APPDATA%\Axolot Games\Scrap Mechanic\User\User_<your-steam-id>\Mods`
- **`"version"` in `description.json` is the game content version, not a mod revision.**
  This build wants `2`. Get it wrong and the game shows "One or more of the selected mods
  have not been updated to the current game version" on every world load. After an update,
  establish the right number from what freshly re-published Workshop mods carry:
  `python dev/mod_version.py`. Bump ours to match.
- Workshop corpus for prior art: `D:\SteamLibrary\steamapps\workshop\content\387990` (1204 items)

The API surface was extracted from `Release/ScrapMechanic.exe` by slicing the string table
between `wrap_*.cpp` markers — each slice is that module's real Lua binding list for *this*
build. That method is reproducible; the script lives in `dev/dump_api.py`. Prefer it over
any wiki, which lags the game.

## What the engine actually gives us

Full detail in `docs/RESEARCH.md`. The load-bearing facts:

- **`sm.camera`** has `setPosition`, `setDirection`, `setRotation`, `setFov`,
  `setCameraPullback`, `setShake`, `setCameraState`, `getCameraState` and the
  `cutsceneFP / cutsceneTP / scriptedTP / forcedTP / gyroSeatFP / gyroSeatTP / default`
  states. Writing to these every frame from a client script works — Axolot's own
  **Spline Camera** mod is a Blocks-and-Parts mod that does exactly this.
- **Tools are the delivery vehicle.** A Blocks and Parts mod *can* ship tools: 29 of the
  100 B&P mods installed locally do. A tool with `showInInventory` appears in the Creative
  inventory; a tool with `autoTool: true` runs for every player with nothing equipped and
  nothing in the hotbar, which is how a B&P mod gets a script that is always running.
- **Tools get only four keys**: LMB and RMB via `client_onEquippedUpdate`, **Q** via
  `client_onToggle`, **R** via `client_onReload`. Plus `sm.localPlayer.getMouseDelta()`.
  There is no `client_onAction` for tools — verified against the engine's own callback
  registration list.
- **Seats get every key.** `client_onAction` on an interactable delivers
  `forward/backward/left/right/jump/sprint/use/attack/zoomIn/zoomOut/item0..9`, and returning
  `true` consumes the key. This is why the free camera lives on a seat part: it is the only
  input surface wide enough to fly a camera, and a seat can be welded to a creation, which
  turns it into a dolly/crane for free.
- **No time-scale binding exists**, but a real time scale is still reachable. `sm.game` has
  `setTimeOfDay` and nothing else time-related, and the executable has no tickrate, timescale
  or simulation-speed symbol at all. What it does expose is `sm.body.getAllBodies()`,
  `body.velocity`, `body.mass`, `sm.physics.applyImpulse` and `sm.physics.setGravity` - and
  velocities at `v*f` with gravity at `g*f^2` reproduce a trajectory exactly, at rate `f`.
  Slow motion is therefore genuine simulation speed for anything airborne. Scaling gravity
  alone is **not** slow motion, it is moon gravity, and it was the wrong first answer here.
- **No depth of field.** `sm.render` exposes LUT, fog, volumetric fog, GI, horizon light,
  camera light, clouds, reflections and `setCinematic` — no post-process focus control.
  Lens focus is not deferred because it is hard; it is deferred because the binding does
  not exist. Long-lens compression (low FOV, far pullback) is the real substitute.

## Build order

1. **Attached rig** — `tool:updateCamera(pullback, fov, offset, weight)`. Re-angle and zoom
   the camera while it stays on the character. Lowest risk, uses the engine's own blending.
2. **Zoom range** — FOV and pullback far past the vanilla clamps, on a smooth ramp so it
   reads like a lens rather than a setting.
3. **Detached camera** — lock off in place, or fly it. Tool version steers with the mouse;
   the Dolly seat version gets full WASD.
4. **Dolly part** — the seat, weldable to a creation, wired to logic.
5. **Slow motion** — velocity + gravity time scale, honest about what stays driven.
6. **Look and grading** — `sm.render`: LUT, fog, volumetric fog, GI, camera light, cinematic
   mode. Signatures are in `RenderSettingsManager.lua`, not guesswork.
7. Later: shot recording and playback (mirror the engine's own `cameraTrack` keyframe schema:
   position, rotation, FOV, duration, easing, jumpCut), and handheld shake via
   `sm.camera.setShake`.

## Naming

Anything in this mod with real, professional mechanics is **Cinema**-graded: the part or tool
is named `Cinema <thing>`, and its inventory description opens with `CINEMA GRADE`. That mark
is a promise about depth, not decoration - it means the thing has proper controls behind it,
not a single toggle. Simple helpers do not get it.

## Working agreements

- **Nothing ships that the owner cannot test in one sitting.** One working camera beats five
  stubbed modes.
- **`print()` does not reach the game log; `sm.log.info` does.** Every `[Lua]` line in
  `Logs/game-*.log` comes from `sm.log.info`. Absent log output proves nothing on its own -
  treating it as proof that scripts never ran cost a full session. `dev/diagnose.py` reads
  both the log and the mod's own `dev/beacon.json`, which is there precisely so there is a
  second channel that cannot be silently swallowed.
- **Verify against the game, not against memory.** The wiki and the training data are both
  behind this build. If a fact matters, find it in the install or in the workshop corpus and
  write down where you found it.
- **Every API call I could not test in-game is a guess until the owner runs it.** Mark those
  in comments, guard them with `pcall`, and never let one take the whole mod down. The
  `SSC.probe` helper logs what actually exists at runtime — extend it rather than assuming.
- **Fail back to vanilla.** Any camera state we set, we must be able to unset. If a script
  errors mid-shot the player must not be stuck in a locked camera.
- Comments explain *why* — an engine quirk, a workaround, a thing that looked wrong and
  isn't. Not what a line does.
- Taste calls — which key does what, how fast the zoom ramps, how the rig sits behind the
  shoulder — are the owner's. Ask, don't guess.
