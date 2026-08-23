# Where things stand

**V4 installed.** nugdupS confirmed visible in the creative menu, so **mod content does
reach the game** — the stale-cache theory is disproved and can be dropped.

That leaves the lift problem as a V2/V3 bug, not a stale mod.

## First thing to check: why lifts do not work

Type `/protection` in chat.

| response | meaning | fix |
|---|---|---|
| `protection: locked` | The world came up locked. `liftable = false` is part of that profile, along with buildable, erasable, paintable and connectable. | `/unlock` — should restore lifts immediately |
| `protection: open` | Not the lock. Check `buildopen` in `Mods/Server Works/Settings.json`; if false, the resolver in `World.server_onCreate` returns false for every body in the world | `/set buildopen on` |
| no response at all | The world script is not running | read the log |

If it was `locked`, the cause is the `protection` value now persisted in `Settings.json`
— new in V2. A run that ended locked comes back locked by design, which is correct
behaviour for an event but surprising on a test world.

## Then confirm the new code is actually live

    python dev/session_stats.py --spam

`[ServerWorks] world ready` is a V2-and-later log line. Absent means the new scripts
never ran, whatever the reason.

## What is new in V4

- **Settings panel.** `/settings` opens a real GUI instead of printing to chat.
  Click a value to change it; numbers cycle through presets. `/settingslist` still
  prints to chat and `/set <name> <value>` still takes exact numbers.
- **`/swhelp`** — the mod's own help, separate from the game's `/help` (which the
  engine reserves and refuses to let a mod bind). `/sw` does the same thing.

## Still unverified

Nothing in V4 has been run. The settings panel is the biggest untested piece: the
json GUI format has no documentation beyond `Data/Gui/JsonGuis/PopUp_YN.gui`, so the
skin names and the widget tree are inference. If `/settings` errors or opens blank,
the panel is at fault, not the settings themselves — use `/settingslist` and `/set`
meanwhile.
