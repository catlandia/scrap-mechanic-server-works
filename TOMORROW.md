# The stale-cache test — read before launching

State: **V3 installed. nugdupS added. Cache deliberately NOT cleared**, so the test
below is still valid. Do not run `sync_mod.py --clean-cache` until after step 1.

## The evidence that started this

The game keeps a `Cache/` directory **inside the mod folder**:

    Mods/Server Works/Cache/Raw/game_5ED431A4C9D4E4CE.rco
                            /world_A5584BCA34E02E16.rco
                            /protection_72D8B5C91EF3D6FE.rco   ... one per script
                      /Data/players_1C36AD040C62F3B6.dco

Measured 2026-08-23:

| file | script written | its cache entry |
|---|---|---|
| Game.lua | 23:26:35 | **22:47:36** |
| World.lua | 23:26:54 | **22:47:36** |
| Player.lua | 23:26:54 | **22:47:36** |
| Settings.lua | 23:26:54 | **22:47:36** |

Every cache entry is stamped 22:47:36. Every script is newer. The cache was never
rebuilt across repeated script rewrites — including the whole V2 refactor. If the game
loads from that cache, no edit since 22:47 has ever run, which is exactly the reported
symptom and matches the owner's theory.

Not yet proof: the `.rco` files might be a build artefact the game ignores at runtime.
The test below settles it.

## The test

**nugdupS** is a copy of the Spud Gun with a new uuid
(`748b6656-84b2-440f-8f4c-8cc7deeba63c`), added as new mod content in
`mod/Tools/Database/`. It behaves exactly like a Spud Gun. It exists only to be
*visible*: a brand new item in the creative menu is unambiguous in a way a script
change never is.

### Step 1 — launch as-is, do not clear anything

Search the creative inventory for **nugdupS**.

- **Missing** → mod content is not reaching the game. Theory confirmed. Go to step 2.
- **Present** → content updates fine, and the "lifts don't work" problem is a bug in
  V2, not a stale mod. Skip to "If it was not the cache".

Also check the thumbnail in the Custom Game list — it should read **V3**. If it reads
V1 or V2, that is the same failure showing in a second place.

### Step 2 — clear the cache and relaunch

    python dev/sync_mod.py --clean-cache

Launch again and look for nugdupS.

- **Now present** → the mod cache was the whole problem. `--clean-cache` becomes part
  of every sync from then on, and the V2 fixes have never actually been tested.
- **Still missing** → the cache is innocent and something else is stopping content
  reaching the game. Next suspects: whether a Custom Game auto-discovers
  `$CONTENT_DATA/Tools/Database/toolsets.tooldb` at all, and whether the item needs a
  shapeset entry as well as a toolset entry.

`sync_mod.py` now also warns on its own whenever `Cache/` is older than the files it
just copied.

## If it was not the cache

Then V2 ran and lifts are broken by V2. In game, type `/protection`.

- Reports `locked` → the world came up locked; `liftable = false` is part of that
  profile. `/unlock` should immediately restore lifts. Cause is a stale `protection`
  value in `Mods/Server Works/Settings.json`, which is new in V2.
- No response at all → the world script is not running; read the log.
- Reports `open` → look at `buildopen` in Settings.json. If false, the resolver in
  `World.server_onCreate` returns false for every body in the world.

## Either way

    python dev/session_stats.py --spam

`[ServerWorks] world ready` is a V2/V3-only log line. If it is absent, the new code
never ran, whatever the reason.
