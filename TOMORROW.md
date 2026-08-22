# Tomorrow — start here

Written 2026-08-22 late, at the owner's instruction. **Nothing was changed after this
was written.** V2 is installed and pushed; the code is where the last commit left it.

## What was reported

- **Lifts do not work.**
- "everything I told you doesn't work" — the fixes appear not to have taken effect.
- Owner's read: **Scrap Mechanic's update problem is not just Challenge mode, it hits
  Custom Games too** — i.e. an updated mod does not actually replace the running one.

## The thing to establish first, before touching any code

**Which version actually loaded?** Everything else depends on the answer and it takes
one command:

    python dev/session_stats.py --spam

Then in the newest log, look for:

    [UGC] Installed Server Works, type: Custom Game ... local id: a34bfc8b-...
    [Lua] [ServerWorks] world ready, protection ...

- `world ready` is a **V2-only** line. It does not exist in V1. If it is absent, V2 did
  not run and the stale-mod theory is supported.
- If it IS there, V2 ran and the lift problem is a V2 bug, not a stale file.

The thumbnail in the Custom Game list also shows V1 vs V2. If the menu shows V1 after a
sync and a restart, that is the stale-content problem on its own.

## Two hypotheses, do not pick one before looking

### A. Stale mod content (the owner's theory)

There is real evidence a per-mod cache exists. From the first-run log:

    Failed to load data cache for '$CONTENT_a34bfc8b-.../Players.json'
    CacheName: '$CONTENT_a34bfc8b-.../Cache/Data/players_1C36AD040C62F3B6.dco'

So the game keeps `Cache/Bundle/*.cbo` and `Cache/Data/*.dco` **inside the mod folder**.
First checks:

1. Does `Mods/Server Works/Cache/` exist? If so, delete it and relaunch.
2. Compare installed files against the repo — `python dev/sync_mod.py --status`, and
   diff a script's first line against `mod/Scripts/`.
3. Was the game running while `sync_mod.py` copied? Scripts are read at startup; a sync
   during a live session does nothing until a full restart (not just leaving the world).

### B. V2 locked the world (a real regression risk, and it fits "lifts don't work")

This is worth taking seriously because **V1 could not lock anything** — the protection
patrol disabled itself on the first tick with the no-world error. V2 is the first build
where protection actually runs. If it locks when it should not, the symptom is exactly
"lifts do not work", because `liftable = false` is part of the locked profile, along with
buildable, erasable, paintable and connectable.

Suspects, in order:

1. `Settings.Get( "buildopen" )` — if it reads false, `World.server_onCreate`'s resolver
   returns `false` for **every body in the world** and nothing can be lifted, built on or
   erased. Default is `true`, but check what is actually in
   `Mods/Server Works/Settings.json` — a file written by an older build could be missing
   the key or holding a stale value.
2. `Settings.Get( "protection" )` — new in V2. If a previous run wrote `locked`, the
   world comes back locked by design. `/unlock` should clear it. That is the first thing
   to try in game, and if `/unlock` fixes the lift, this is the answer.
3. `g_swPlots` nil, or `sv_bodyIsOpen` returning false when plots are off. Should return
   `nil` (defer to global mode) when `enabled` is false — verify it does.

**Fastest in-game test:** type `/protection`. It reports the mode, the shape count and
whether the patrol is alive. If it says `locked`, hypothesis B. If the command does not
respond at all, the world script is not running and it is hypothesis A.

## Also still open

- `/sw` replaced `/help` (the engine reserves `/help`). If the old name was being typed,
  nothing would have happened — worth ruling out before assuming a deeper fault.
- No V2 log has been seen yet. Every V2 claim in the last commit message is untested.

## Do not repeat

The V1 log is the model for how this should go: three errors, three fixes, all traced to
file and line in minutes. Guessing at causes before reading the log wasted the owner's
evening. **Read the log first.**
