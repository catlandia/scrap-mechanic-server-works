# What is actually verified, and what is not

Written 2026-08-24, at V53; revised 2026-08-25 after the co-loaded mod
audit. **This file is the honest ledger.** Everywhere else
in this repo describes what the code is *meant* to do; this one says which of it
has been seen to happen.

Read it before believing any other document in here.

---

## The one thing to understand about the checks

`python dev/check_all.py` runs **222 checks** in ten seconds and they all pass.
That is worth having and it is not evidence the mod works.

| what the checks DO touch | what they CANNOT touch |
|---|---|
| the rules, run as real Lua through `lupa` | a body, or any permission flag on one |
| city geometry, proved a partition | a tool, or whether a tool can be held |
| panel layout at every resolution | the network, client or server |
| fonts: existence *and* glyph coverage | the renderer, and therefore frame rate |
| the command plumbing, both directions | the lift, blueprints, or `importFromString` |
| every setting, preset and migration | anything the engine does with any of it |
| that every `sv_n_*` handler gates on the sender | whether a real guest is actually refused |

Nothing in `dev/` has ever created a body, equipped a tool, or sent a packet.
**A passing suite means "no known logic error". A failing one is always real.**

---

## The V55 summary, before the ledger

Three things are now measured and are not going to change without new evidence:

- **The server does not die.** 128 characters, 2,102 bodies, tick rate never left
  40 Hz. Player count was never the risk.
- **One character costs ~24 shapes of frame time.** Twenty players' characters
  are ~2.7 fps. Content is the thing to budget, not people.
- **The per-client network budget is the real hazard** -- up to 6.8 seconds of a
  client receiving nothing, measured from logs already on disk.

And one thing has not changed at all: **goal 2 has still never been run in a real
event.** The freeze is the core of it. Everything below section C is the list.

## A. Seen working in game

The owner has watched these happen. Each line names how it was confirmed.

| what | how it was confirmed |
|---|---|
| The Custom Game loads and the world starts | many sessions since V1 |
| Chat commands reach the server and reply | `/set`, `/plotgrid`, `/citycensus` all used |
| The hub menu and every panel **open, and their buttons run** | *"YES THE BUTTONS FINALY WORK LETS GOOOO"* (V30) |
| A panel stays open after an action and restates itself | same session |
| The event clock draws in the top right | screenshot, V28 |
| The compass plot marker draws | *"AND THIS! YES!!"*, V28 |
| Our own tools appear in the creative menu, named | the nugdupS canary, V49 |
| The city builds, and it is walkable | screenshots, V26 onward |
| Protection flags are genuinely being applied to bodies | proved backwards by V46: the world went `buildable=false, erasable=true`, which is one profile out of six. Wrong profile, but really applied |
| Fonts render without hollow boxes | V29, after three were found glyph-limited |
| A mod-shipped **effectset** loads and its effects can be created | V56 — the focused player's name is drawn, and only our own effect has a text element |
| **In-world** text honours the same font tiers as GUI text | V56 — `SM_Header` drew `CyberSlime2077` clean |
| An effect and a compass icon can be **hosted on another player's character** | V56 screenshot — marker over the head, compass icon with a distance readout |
| The game log is quiet in a Custom Game session | no `g_unitManager` storm since V1 |

### Four things the snapshot files on disk prove, that nobody had noticed

Found 2026-08-24 by reading the installed mod's `Snapshots/` directory rather
than by running anything. This is evidence that was sitting there the whole time.

**1. `sm.json.save` CAN write into an installed mod's directory at runtime.**
This was one of the three "most likely to be wrong" items in `CLAUDE.md` and the
reason the master ban list was going to have to live outside the mod. It is not
wrong: there are 341 KB files in there, written by the game.

**2. Snapshot CAPTURE works end to end, and the export is real.**
`buildend-2026-08-24_2222.json` holds **195 entries and 676 children**, and every
one of the six distinct shape/colour pairs in it is a city material —
`a6c6ce30/8D8F89` concrete, `1016cafc/68615C` metal 2, and metal 3 in the stand,
road, plaza and pillar colours. A 96-plot city is 96×6 + 99 + 2 = **677**
children. The capture is complete and exact, and `sm.creation.exportToString` is
returning genuine blueprints rather than the empty string a failing call would.

**3. Phase snapshots (V50) fire, in order.** All four, one minute apart, from a
single event:

    prepstart-2026-08-24_2220     195
    buildstart-2026-08-24_2221    195
    buildend-2026-08-24_2222      195
    eventend-2026-08-24_2223      195

**4. Autosave rotation works.** `auto1` through `auto6`, timestamped, on schedule
— 1947, 2047, 2147 an hour apart. The index survives restarts.

**What this does NOT prove: RESTORE.** Capture and restore are different halves
and `sm.creation.importFromString` has still never been called. Its last two
arguments remain a documented guess. **A backup nobody has restored from is not
yet a backup** — it is the single most important untested thing left.

---

### Seen working in game, 2026-08-29 -- the first session driven from outside

The first hour the bridge carried real commands. Everything here was observed
through it, with the game's own replies as the evidence, and it is the largest
single move from C to A this project has had.

| what | the evidence |
|---|---|
| **the bridge itself** | game commands, world commands and the replies that arrive an event later all came back in the transcript |
| **the city builds** | `96 plots, 0 failed`, twice, in two fresh worlds |
| **snapshot capture** | `195 creations`, and the file on disk holds 195 entries |
| `/snapshots` | listed it |
| **RESTORE** | `195 of 195`, and afterwards `locked 99, open_destructible 96` -- 99 deck creations *including the plaza*. **Only after the fix**; see section B |
| **the grief alarm** | fired by itself on `/plotclear`: `*** 678 blocks have disappeared ***` |
| `/lockdown` | `195 bodies, 96 changed [locked 195]` -- every body on the locked profile |
| `/unlock` | `locked 99, open_destructible 96`, which is exactly what the rules specify |
| **an empty claimed plot is LOCKED** | with one plot claimed and the host standing elsewhere: `locked 100, open_destructible 95`. V46's rule, confirmed for the first time |
| `/plot claim`, `/plot info` | claimed plot 66, read it back |
| `/protection` | mode, counts, and **`PhysicsQuality: 9`** -- read for the first time in this project |
| **a quiet log** | zero Lua errors and zero tracebacks across the whole session |

Two of those deserve their own line because they were the two most important
unknowns in the project:

- **A whole-city restore takes about a second.** That is what makes `/restore`
  usable as a panic button mid-event rather than a thing you would only try
  afterwards.
- **The tick rate never moved.** 120 ticks in 3 seconds of wall clock, read off
  the log's own counters, while a city was being built and destroyed.

**What the restore evidence is, precisely.** The import count is NOT the
evidence -- it said `195 creations, 0 failed` on the run that left a hole. The
BODY count afterwards is: 99 deck creations where a missing plaza would leave
98. The plaza has not yet been confirmed by eye.

**RESTORE IS CONFIRMED, 2026-09-01, through the bridge.** Snapshot taken at 676
shapes / 195 bodies; `/restore` reported `195 of 195 creations`; the world
afterwards read **676 shapes and 195 bodies** -- identical. The V58.1 settle fix
holds and the plaza is back by count (99 deck creations, where a hole leaves 98).
The `backup-restore` checklist line is GREEN and the suite has no failures left.

**AND EVERY RESTORE EVER RUN WAS ON A CITY WITH NOTHING BUILT ON IT.** Read out
of the snapshot files themselves, 2026-09-01: the restores used 195 entries --
99 deck creations and 96 plot slabs, and **zero player buildings**. So the one
thing `/restore` exists for, bringing back what people built, has never once
been exercised.

Capture is not the gap: a crowd session captured `3995` creations with `3896` of
them on plots, so builds do get saved. What is untested is putting them back.

Two more things the files settle, one reassuring and one not:

- **Blueprint coordinates are ABSOLUTE** (-104..+84 in the real files), so a
  restored build lands where it was rather than in a heap at the origin. That
  was the obvious way this could have been broken and it is not.
- **The plot state is new and thin.** Every snapshot on disk older than
  2026-09-01 has `plots: null` -- no ownership at all. And what a snapshot saves
  even now is `grid, owners, teams, enabled` and nothing else: **not** the
  server settings, **not** the event clock, **not** the ban list, **not** the
  city style. A snapshot is buildings plus who owns which square, and calling it
  a world backup oversells it.

**The real whole-world backup is `dev/backup_world.py`**, which copies Scrap
Mechanic's own `Save/<world>.db`. That is the world exactly as the game
understands it -- terrain, save state and all -- and it cannot half-succeed the
way an import can. The mod cannot do this itself: the Lua sandbox has no
filesystem outside `$CONTENT_*`.


## B. Seen BROKEN in game — a fix shipped, not re-tested

### Seen BROKEN and fixed, 2026-08-29 — restore lost the plaza

The first restore ever run in this project reported `195 creations, 0 failed`
and left a hole in the middle of the city. It cleared the world and imported on
the very next tick, so the first four creations went into space the old shapes
still occupied — and the plaza is entry one in every snapshot.

Fixed by giving restore the same settle stage the city builder has had since the
same bug bit there. **Re-tested the same session, and the body count says it
worked**: 99 deck creations, where a missing plaza would leave 98. What has NOT
happened is somebody looking at the middle of the city and saying so.

### /lockdown, rebuilt and NOT re-tested

REPORTED: *"I still could use the lift, and the clay gun."* Two faults were found
and fixed — the lift was never in the blocked list, and `/unlock` never restored
the four settings `/lockdown` wrote — but **none of the new behaviour has run in
the game**, because it needs a world reload.

**What to check first:** `/lockdown`, hold the clay gun and the lift, then
`/tool`. It now prints whether the world is shut and what the server blocks for
the host and for a guest, so a disagreement between the server's list and the
client's is visible instead of guessed at.

The clay gun getting through is still unexplained: the setting was already false
and the host guard list already contained it. The guard now re-sends the list
whenever the server catches a blocked tool in a hand, which repairs the one
failure the code allows for — a client whose copy arrived empty, which enforces
nothing while looking perfectly healthy.

### Seen working in game, 2026-08-26 — the focus marker, first try

*"thanks it works!"*, with a screenshot. Three separate things confirmed at once,
and one of them answers a question this file had flagged as the highest risk in
the release.

| what the screenshot shows | what it proves |
|---|---|
| an orange diamond floating over the player's head | `sm.effect.createEffect( name, character, nil, sm.effect.axis.all )` works on a **player's** character, driven from `World.lua`'s client, with `setOffsetPosition` lifting it clear of the head |
| **`CyberSlime2077` in world text under it** | **the mod-shipped effectset LOADED**, and `setParameter( "TextContent", … )` on a parameter *we* declared works |
| the name is legible, mixed case and digits | **the glyph atlas did not mangle it.** `SM_Header` is tier 1 and in-world text really does honour that |
| a compass icon with a `1m` distance readout | `compassSetIconHost( name, character )` binds an icon to a character from a Custom Game |

**The name is the load-bearing detail, and it is worth spelling out why.**
`Focus.bind` only attempts the name tag when the marker resolved to
`MARKER_EFFECTS[1]` — our own `ServerWorks - Focus`. The vanilla fallback,
`QuestMarker_Far`, has no `text` element and never gets one. So a visible name
is not merely *consistent with* our effectset having loaded; it is only
reachable if it did. **A Custom Game can ship an effectset, and this one does.**

That retires the biggest unknown in V56 in a single screenshot, and it retires
it the strong way — by a consequence that could not have happened otherwise,
rather than by "it looked right".

**What this does NOT prove, and it is the same gap as everything else here:**

- **that anybody else sees it.** One machine, no guest. The push is
  `sendToClients` from the world, so every client should get it, but "should" is
  what this section exists to distinguish from "does". This is the first feature
  in the mod whose entire purpose is what *other* people see, so the gap matters
  more here than usual.
- **that it draws through walls.** Nothing occluded the marker in that shot.
  `behindFadeAlpha 0.6` and `InWorldIconBehindDepthOffset` are copied from
  `QuestMarker_Far`, which does it in vanilla.
- **that it holds at range.** The compass read `1m`. `maxRenderDistance` is
  1000000 and `distanceScale` keeps it a constant size on screen; neither has
  been seen past a few metres.
- **which door was used.** The tool, the panel and `/focus` all end at
  `Game.sv_setFocus`, so one of the three worked and the other two are untested.
  The search box, the pager and CLEAR are all still unrun.
- **that clearing works.** Hold F, the CLEAR button and `/unfocus` all go through
  `sv_setFocus( nil )`, which has not been seen.

### Seen working in game, 2026-08-25

The first features in this project confirmed working by the owner rather than by
a check passing:

| feature | evidence |
|---|---|
| **NOTlift imports a creation and it is a normal build** | *"FINALLY IT WORKS LIKE IT SHOULD"* — after six causes, each measured; see the import section in CLAUDE.md |
| **the Cleaner deletes a whole creation across joints** | fixed after *"the cleaner even with F wont delete the whole thing"* on a build with 20 bearings |
| **the city map and the roads** | *"its all good now"* — roads clean on both axes, plaza distinct from claimed plots |
| **a 384-plot city builds and holds 40 Hz** | *"I tested the largest city setup can pull. AND IT DIDNT CRASH"* — `city built: 384 plots, 0 failed`, tick 39.7 during the build minute, 39.9 after. One player, empty city |
| **the custom NOTlift icon** (crossed-out lift) | visible in the creative menu in the owner's screenshot |
| **a new world starts clean** | HUD read `NO EVENT / build freely` on a fresh world instead of inheriting `ended` and `locked` |
| **the engine's blueprint browser opens for us** | `LOAD CREATION` panel, and the pick callback reached a Game script five times |
| **the lift trace** | 25 seconds of per-change logging, which is what finally disproved the `placeLift` theory |

Not yet re-tested after the last fixes: importing several creations back to back
(the release queue), and importing onto a plot inside a built city — every test so
far was on open terrain with no city.

**This is the most important section in the file.** Every line is a real report
from a real session, with a real fix behind it, and **not one of them has been
seen working since.** A fix that has not been re-tested is a hypothesis.

| reported | version | what was found | re-tested? |
|---|---|---|---|
| *"I cant build on my plot even when the time has started"* | V43, V46, V48, V50 | four separate causes, each sufficient on its own — see below | **no** |
| *"the lift is still fuc-SAD"* | V49, V51 | added an Import Lift on our own uuid; took all three lifts out of the tool gate | **no** |
| *"I cant press E on the lift to import creations"* | **V54–V56** | the tool was never the gate. Solved a different way: **NOTlift**, a new tool that borrows the engine's own blueprint browser and imports onto a lift, then takes it off again | **YES — seen working in game 2026-08-25** |
| *"stuck at 100 when loading into the mod"* | **V54** | `"Creative"` registers no scriptable objects, so `CreativeGame.server_onCreate` threw on line 47 and never reached `sm.world.createWorld`. Reverted to `"Survival"`; `check_uuids.py` now fails the build on it | **fix is a revert to the state that was working at 10:46** |
| *"/unlock says Building reopened and nothing reopens"* | **V54** | the world shuts with TWO persisted switches and `/unlock` wrote one; every plot stayed on the `locked` profile, `liftable` false | **no** |
| *"game crashed when I tried to change the number of build time"* | V45 | redrawing a json GUI from inside an EditBox callback is a native crash | **no** |
| *"you need to fix the unremovable craft bots, gems and others"* | V38 | three separate places locked shared ground; carryables need `destroyShape` | **no** |
| *"I still cant remove metal 2 via the tool. even if its not on the platform"* | V44 | a pure height test called terrain-level metal "city floor" | **no** |
| *"please make as I said to the buffer time"* | V41 | `buildopen=false` fired before the mode was consulted, so buffer == prep | **no** |
| *"I cant build while standing on protected blocks which sucks"* | V50 | stepping onto a road locked your own plot behind you | **no** |
| *"I cant break the block if I hit the limit... stuck in a loop"* | **V53** | over-budget returned the LOCKED profile, so the limit forbade its own remedy | **no** |
| *"I dont see my deleting thing appear"* | V49 | a tool with no `inventoryDescriptions` entry has no name in the menu | **no** |
| *"the concrete is still not attached"* / *"the things NEED to be separated"* | V39 | the city is deliberately many bodies now, each plot with its own stand | **no** |

### The four candidate fixes for "I cant build on my plot"

They are listed most-likely-first, and the log line that settles it is in
[`NEXT.md`](NEXT.md):

1. **V46** — every body was located by `body.worldPosition`, which is its
   *origin*, not where it is. Every plot resolved to `sweep`
   (`buildable=false, erasable=true`) — exactly the reported symptom.
2. **V48** — a dead event resurrected itself on every world load and dropped the
   world into a fresh `polish` window.
3. **V50** — stepping onto a road locked your own plot behind you.
4. **V43** — the floor was pinned during build time.

---

## C. Never run at all

Written, compiled, checked, installed. **Never once executed in the game.**

### Whole features

| feature | where | why it matters |
|---|---|---|
| **The per-tile part limit** | `Rules.lua` | this is the current next step. See [`NEXT.md`](NEXT.md) |
| **Restore** (capture is confirmed — see A) | `Snapshots.lua` | `importFromString`'s last two arguments are a guess. The only thing standing between a griefer and a lost event |
| **Ban and kick reaching the engine** | `Identity.lua`, `Game.sv_flushKicks` | *"we need to make sure banning works. cause its the only way"* |
| **The allow list** | `Identity.Sv_IsAllowed` | stronger than bans, and completely untried |
| **The grief alarm firing** | `World.sv_checkAlarm` | has never tripped, false or true |
| **`/purge` in all its forms** | `World.lua` | and the guard that stops it eating the city |
| **The cleaner tool actually deleting** | `CleanerTool.lua` | the only thing that can remove a carryable prop |

### New in V53, none of it run

- **The `trim` profile** — over budget stops placing and nothing else.
- **The two-cadence audit** — 1 Hz scoped, 5 s full.
- **City style** — ten settings, `/citystyle`, six presets.
- **The roster HUD** — ONLINE and RESIDENTS, top left.

### New in V54, none of it run

- **The city style picker** (`StyleGui.lua`) — the five city pieces, all
  twenty-five blocks as a list, all forty paint-tool colours as a grid, and the
  six whole-city styles, on one screen. Replaces ten stepper rows.
- **A Button drawn with `WhiteSkin` + `Colour`** — the swatch. Both halves have
  a vanilla precedent (`EditorSkin.xml:27`, `DigitalSign.gui`) and the
  *combination* does not. **This is the thing to look at first when the panel
  opens**: if the forty swatches are grey or invisible, the Button half is not
  honouring `Colour` and the fix is to drop back to the `fill()` drawn
  underneath each one and put an unskinned Button on top of it. The fill is
  already there — see the note at the top of `StyleGui.lua`.
- **`CITY STYLE` on the city panel** and the settings nav entry that now opens a
  panel instead of selecting a tab.
- **Two host gates that were missing** -- `Game.sv_n_openPanel` and
  `NotLift.sv_n_swOpenImport`. Both let a guest open a host UI on their own
  screen; neither could change anything, because the action handlers behind them
  all test the sender. **This is the one line here that cannot be turned green
  solo:** proving a guest is refused needs a second client, and there is no
  dedicated server to stand in for one.
- **`allow_add_mods: true`** in `description.json` (V74, reversed). The world
  has never been loaded either way since V54. What to check is that the world
  still creates AND that the "add mods" box is now on the world-creation screen
  -- it changes that screen, and nothing in `dev/` can see it. If you tick
  anything, `python dev/session_stats.py` afterwards names every mod that
  loaded.

### New in V55, none of it run

The crowd. `/crowd N` puts N human-model bots on the city. The whole argument
for what it does and does not measure is in [`CROWD.md`](CROWD.md); what follows
is only the list of things that have never executed.

- **A mod-shipped character set.** `mod/Characters/Database/`. The Custom Game
  template has the directory, so the mechanism is the engine's -- but **no mod in
  the 1205-item Workshop corpus ships one**, so there is no prior art whatsoever
  and this is the highest-risk line in the release. **What to look at first:** if
  `/crowd 5` says `5 failed`, the character set did not load, and the log line
  from `Crowd.sv_spawnOne` names the uuid it asked for.
- **`sm.unit.createUnit` with a uuid of our own.** Vanilla only ever passes its
  own. Guarded, and it stops at the first failure rather than spinning.
- **`character:overrideRenderableList` on a unit we made.** The vanilla caller is
  a quest NPC. The failure mode is a bot that looks like the characterset's
  fallback -- an ordinary mechanic -- rather than a random one, and twenty
  identical mechanics is the tell.
- **`character:setNameTag` on a non-player.** One vanilla caller, and it is
  guarded by `sm.exists( player )`. Read as a player feature; argued in
  `BotCharacter.lua` not to be one. If bots are nameless, that reading was wrong.
- **`unit:setMovementDirection` / `setMovementType` / `setFacingDirection`
  without a pathfinder.** Vanilla always feeds these from a path query. Bots
  standing still would mean a direction alone is not enough.
- **Crowd bots inside `Plots.sv_updateOccupancy`.** They are handed in as real
  occupants and are deliberately kept out of the push-out table. **What to check:
  a bot must never lock a plot a real player cannot get back** -- stand on a plot
  a bot is on and confirm you can still build.
- **`/crowd claim on`.** Writes `crowdbot:` permas into `Plots.json`. Swept at
  world create, and released by `/crowd off` and `/crowd claim off`. If a plot is
  ever stuck owned by nobody, this is why, and `/crowd off` is the remedy.
- **`/crowd churn on`.** Each bot places one block and later removes it, through
  the same `sv_importBlueprint` the city uses. Watch for blocks left standing
  after `/crowd off`.

**And `/bench`**, which drives the crowd up in steps and records the numbers.

- **`Game.client_onUpdate`.** The mod has never had one; `CreativeGame` does, and
  ours now calls it. **What to check first:** if the day/night cycle stops
  advancing, the parent call is not happening.
- **The frame-rate probe round trip.** Client -> `sv_n_benchSample` -> world ->
  `Bench`. Armed only for the length of a run. If `/bench start` prints its
  header and then nothing ever happens, no sample is arriving and the run
  self-abandons after fifteen seconds of silence (`Bench.WATCHDOG`).
- **`dt` being wall-clock seconds.** Argued from `CreativeGame.lua:208`, never
  measured here. The tell if it is wrong: a baseline row reporting a frame rate
  nothing like what the game is visibly drawing.
- **`Bench.json` being written at all.** Same `sm.json.save` path as
  `Settings.json`, which is known to work, so this is the lowest-risk line here.
  `dev/bench_report.py` reads it, and has been exercised against a synthetic file
  of the right shape.

The arithmetic underneath is NOT on this list -- seven checks in
`dev/test_logic.py` drive the real `Bench` against fed samples, including the one
that catches a benchmark timing itself with the counter it is measuring. They
already found one bug: absolute ticks differenced across a window reported 36 Hz
on a clean 40.

Nothing in this list is on the event path: `/crowd` and `/bench` are host-only,
do nothing until asked for, and their faults are caught in a `pcall` separate
from the protection patrol's -- deliberately, so a test harness can never switch
off protection, and a protection fault can never leave a crowd nothing can
clear. `/bench` additionally refuses to start while an event clock is running.

### New in V56 — the marker is confirmed, the rest of it is not

The focus feature's *highlight* half was seen working the day it shipped — see
"Seen working in game, 2026-08-26" above, which is where the evidence and its
limits are written out. What is left on this list is everything that screenshot
did not touch.

- **Anybody but the host seeing the marker.** One machine, no guest. This is the
  first feature in the mod whose whole purpose is what *other people* see, so
  this is not a formality: `World.sv_e_swFocusPush` uses `sendToClients`, and a
  message that reaches one client is not proof it reaches two.
- **The marker through a wall, or at range.** The compass read `1m`.
  `behindFadeAlpha` and `maxRenderDistance 1000000` are `QuestMarker_Far`'s own
  numbers, which vanilla uses across a map, but neither has been seen here.
- **The panel.** `FOCUS PLAYER` on `/menu`: the list, the search box, the pager,
  the FOCUS button per row, CLEAR, BACK. None of it has been clicked. It reuses
  the plumbing every other panel proved in V30, and the search deliberately does
  a **server round trip** rather than redrawing from inside the text callback --
  the shape that crashed the game twice on the event clock.
- **Clearing.** Hold F, the CLEAR button and `/unfocus` all end at
  `sv_setFocus( nil )`. Unrun. If a marker ever sticks, that is the function.
- **Two of the three doors.** The tool, the panel and `/focus` all end at
  `Game.sv_setFocus`, so exactly one of them is known to work and it is not
  recorded which.
- **`sm.isHost` inside a TOOL script.** Read by `FocusTool.looksLikeHost` for the
  guest-side crosshair hint only. Vanilla reads it in 81 places and never from a
  tool, and a tool's environment is demonstrably not a Game script's -- a
  character script's callbacks have no `setmetatable` at all. It fails **open**
  on purpose: the server refuses regardless, so being wrong costs a guest one
  wasted click rather than a host a dead tool.
- **A focused player leaving, and a client joining mid-focus.**
  `sv_checkFocusAlive` runs once a second beside the roster push; the join
  re-push is deferred two seconds because the joining client's world script does
  not exist yet. Neither has been observed.
- **The roster HUD's third row.** The `FOCUS` line in the top-left corner grows
  the panel by 30 units. Never seen with a name in it.

**Not on the event path.** The focus tool creates nothing, deletes nothing and
changes no body flag -- it is the only host tool in the mod that cannot damage a
world. Every marker call is inside a `pcall` that faults once and then stops,
never per frame.

### New in V57–V59, and what of it has run

**The checklist** (`/check`) — the panel itself is confirmed: 14 items were
answered through it before the bridge existed, and the file it writes is read
back by `dev/checklist_report.py`. Not run: the note box, RUN IT, NEXT, and the
pager.

**The bridge** (`/bridge on`) — confirmed, and it carried the session above.
Two things about it are still unknown:

- **A batch that runs longer than its listening window.** The window is a
  clock, so a slow command answers into the next batch's transcript or nobody's.
  `--wait` covers it; nothing enforces it.
- **Two sessions of a world in one day.** The sequence number is persisted and
  only ever moves forward, so this should be fine, and has not been watched.

**The lockdown rebuild** — see section B. Written, checked, installed, unrun.

**Save presets and a controlled bot** — asked for, not started.

### New in V64, none of it run

Every line of it is checks-and-reasoning; nothing here has been seen on a screen.

- **`/developer on|off`** — the switch itself, and the two menu entries appearing
  and disappearing with it. Off is the default, so **the first thing to confirm
  is that a fresh world's menu has ten entries and not twelve**.
- **The dev command gate.** `/crowd 5` should refuse with developer off and name
  the switch; `/crowd off` should still work. That escape is the half most worth
  testing, because getting it wrong strands a crowd.
- **The bridge being derived.** `/bridge on`, then `/developer off`, then
  `/bridge status` — it should say *on, but SHUT*, and `/developer on` should
  give the channel back without `/bridge on` being typed again.
- **EVERYONE SEEN, and it is the piece to look at hardest.** `WHO IS HERE ->
  EVERYONE SEEN` should list every player the server has ever recorded, newest
  first, with BAN on each row and UNBAN on anyone already banned. Press BAN on
  somebody offline and check `BANNED` picked them up. **`Identity.Sv_KnownList`
  has never been called in game**, and neither has a ban placed by perma id.
- **The FIND box.** Typed input is the one thing in this mod that has crashed the
  game outright, and nothing typed into a json GUI on this panel has ever run.
  It must only ever narrow the list -- if pressing Enter bans somebody, stop and
  say so.
- **Banning somebody who is online, by perma id.** The new `resolveTarget` branch
  is what makes `sm.game.banPlayer` fire on that path. If they stay in the world
  after a ban from EVERYONE SEEN, that branch is what failed.
- **The WORK IN PROGRESS line on the menu.** It is right-aligned in the header
  band, which no other caption in this mod is — worth one glance to confirm it
  is not sitting on top of the title.

---

### New in V64-V78, and what of it has run

**Driven live through the bridge on 2026-09-01** -- so these have moved out of
this section and into A: restore (676 shapes / 195 bodies, identical after),
`/lockdown` and `/unlock` on a built city, `citybuild` (the deck stopped being
locked scenery), the developer gate and its `/crowd off` escape, the allow list
on an empty server, the event clock and its phase snapshot, and the join-mode
readout.

**Never run**, and every one of them needs hands or eyes:

- **HOW THIS WORKS**, the tutorial. Twelve pages of prose is the most text this
  mod has ever drawn after the checklist. **Look for hollow boxes** -- the game
  builds a glyph atlas per font from what it has already drawn, and the check
  that guards this is a precaution rather than a measurement.
- **The tutorial opening by itself** on a first join. Needs somebody the server
  has never seen.
- **The BANS picker and the allow buttons** -- clicked in anger, on a list with
  more than one name on it.
- **A guest with no chat commands.** If anything they need turns out not to be
  on the menu, that is the finding.
- **The unstuck button** landing in the middle of the city.
- **`backup_world.py --watch`** surviving a real play session.

### New in V65, none of it run

- **A guest with no chat commands.** Needs a second person: have them type
  `/plot claim` and then `/menu`. **If anything they need turns out not to be on
  the menu, that is the finding** -- the refusal is working as intended.
- **`citybuild`.** Place a block on a road with it off (should refuse) and on
  (should work), then `/lockdown` and confirm the city freezes anyway.
- **The unstuck button.** `sm.character.createCharacter` called from our own
  world handler has never run; vanilla's copy of that call is the only evidence
  it works. Walk away from the middle, press unstuck, and see where you land.
- **`sm.physics.spherecast` from a World script of ours.** Same: vanilla does it
  in `CreativeBaseWorld.sv_e_spawnNewCharacter`, we never have. It is guarded and
  falls back to the deck height plus the clearance.
- **A ban surviving a new world.** Proven in the harness against the real
  Identity, never watched in game.

---

### Specific API calls that are still guesses

Each is `pcall`'d and logs once rather than per tick, but none has returned a
value anybody has looked at.

| call | why it is uncertain |
|---|---|
| `body:getCreationId()` | **the highest-risk one.** Not in any vanilla script. If it errors, every multi-body creation counts its joints once per body and blows the part budget at roughly a quarter of the limit |
| `sm.creation.importFromString`'s last two arguments | vanilla passes `true, true` in one place and five arguments in another; the meaning is documented nowhere |
| `body:isGhost()` | in the binding list, never seen return a value |
| `sm.game.banPlayer` on a non-host | vanilla calls it, we never have |

---

## D. Measured, and still true

### The load curve, 2026-08-26 -- the first clean one

`/bench` from 0 to 128 bots in tens, building on their own plots, 96-plot city:

| bots | fps | min | tick/s | shapes | bodies |
|---|---|---|---|---|---|
| 0 | 60.0 | 60.0 | **40.0** | 676 | 195 |
| 40 | 59.8 | 59.3 | **40.1** | 898 | 417 |
| 70 | 57.6 | 56.8 | **40.0** | 1,276 | 796 |
| 80 | 51.9 | 48.7 | **40.0** | 1,446 | 966 |
| 100 | 42.1 | 40.1 | **40.1** | 1,844 | 1,366 |
| 128 | 31.9 | 30.5 | **40.0** | 2,580 | 2,102 |

**The tick rate never moved**, at any size, from 195 bodies to 2,102. The frame
rate is flat to ~70 bots and then falls away; the knee is 70-80.

Three things this does NOT say:

- **128 bots is not 128 players.** No client connections, so the per-client
  network budget stays at zero however far it goes.
- **It confounds crowd size with content**, because build mode grows the world as
  the crowd grows. `/crowd mode churn` plus the same bench separates them, and
  has not been run.
- **The host is rendering AND simulating.** A guest carries only half of it.



Two facts from `dev/session_stats.py` over the owner's own client logs. These
are the only *numbers* this project has, and **neither was measured on a world
running Server Works.**

**The 19-player session was somebody else's event, joined as a guest** -- that
log loads City Building MMO, not this mod. It is evidence about the *engine*
under 19 players and it is not evidence about anything in this repo. There has
never been a multi-player session on a Server Works world, and as of
2026-08-25 there is no lobby available to hold one.

| session | players | server tick | client frames |
|---|---|---|---|
| 2026-08-22, 100 min | 19 | median 39.9 Hz, **0 of 86 windows below 90% of target** | 60 → 31 |
| 2026-08-08 | 1 | **collapsed to 11.6 Hz** | — |

- **Nineteen players never dented the simulation.** The premise that "Scrap
  Mechanic hates a lot of players" is not what these logs show.
- **Frame rate degraded with TIME, not player count** — it kept sliding while
  the count was flat at 19. That is accumulated world content: a render problem,
  and **nothing in this mod addresses it.**
- **The single-player collapse was self-inflicted**: a 1.79 GB log, 1.45 M lines
  of a per-tick `print()` plus 58 K tracebacks. Log spam is the largest
  performance bug this project has measured.

### A third number, 2026-08-25: what one co-loaded mod costs

MEASURED in a **Server Works world** with T mod (Workshop `3438987478`) enabled
beside it -- `Logs/game-20260825-143811.log`, two players:

| | with T mod (27 min) | clean Server Works, same day |
|---|---|---|
| log size | **95.6 MB** | 126 KB |
| tick/s min | **4.6** | -- |
| frame/s min | **4.4** | -- |

760x the log volume, and 6,341 of the 6,342 `__mul` errors carry T mod's content
id. **One player plus one co-loaded mod did more damage to the tick rate than
nineteen players building did**, with nobody attacking anything. Full working in
[`MODS-AND-TRUST.md`](MODS-AND-TRUST.md). Caveat: one session, not a controlled
A/B.

---

**Consequence, stated plainly:** freezing builds buys simulation headroom, and
simulation was not the bottleneck. Do not credit the freeze with fixing frame
rate. Keep it for anti-grief, which is what it is actually for.

---

## E. Known to be impossible, so stop looking

Written down so no future session spends a day rediscovering them.

- **No simulation knob.** `sm.game` has 25 bindings and none touches tickrate,
  timescale, threading or physics quality. `PhysicsQuality` is readable and has
  no setter.
- **No block-placed or block-destroyed callback.** Protection can only ever be
  reconciliation after the fact, never prevention. This is the whole argument in
  [`ANTI-GRIEF.md`](ANTI-GRIEF.md).
- **No per-player body permissions.** There is no `setBuildableBy( player )`. A
  body is buildable by everyone or by nobody, which is why plot ownership is
  approximated by presence.
- **No stable player id in Lua.** `player.id` is a session slot. Bans key on
  display name; the allow list is the stronger tool.
- **A toolset can ADD a tool, never OVERRIDE one.** First declaration wins.
- **The creative menu's item list cannot be edited from Lua.** A banned tool
  still appears; it just cannot be held.
- **The renderer is untouchable.** No binding reaches it. Only spatial
  separation and part budgets can help client frame rate.
- **The remove tool deletes at most 16×16 = 256 shapes** in one action. Any
  grief-alarm threshold below that is a false alarm generator.
- **The Lua sandbox has no network and no general filesystem.** No HTTP, socket,
  URL, download, `os` or `io` module exists in the engine at all -- MEASURED from
  `dev/dump_api.py` over the full module list. File access is `sm.json` over
  `$CONTENT_*` paths only, and absolute paths and `..` are refused.
- **A guest cannot bring their own mods.** MEASURED: joined a world while
  subscribed to 101 Blocks-and-Parts mods, and the world loaded exactly one --
  the host's. The host's world dictates the list, which is why join-time
  auto-subscribe exists at all.
- **An installed mod that is not enabled executes nothing.** MEASURED: same
  machine, same day, 12,766 lines referencing T mod with it ticked and **0**
  without.
- **There is no dedicated server *binary*.** The install ships only
  `Release/ScrapMechanic.exe`, so `sm.player.getHostPlayer()` is never nil --
  vanilla dereferences it unguarded at `SurvivalGame.lua:1846`. Consequence for
  testing: you cannot be a guest on your own machine.

  **One correction, 2026-08-25:** that same executable *does* parse a
  `-dedicated_server` command-line flag, alongside `-use_null_driver`,
  `-console`, `-window` and `-connect_steam_id <id>` (all of them in `Main.cpp`'s
  argument list). This does not move the line -- there is no
  `DedicatedServer.cpp` anywhere in the binary, only `ListenServer.cpp`, so the
  flag is plausibly a dead dev stub -- but it is no longer true that nothing in
  the install suggests one. **Untried, and it is a two-minute test.** See
  [`CROWD.md`](CROWD.md).

- **The per-client network budget cannot be measured alone.** MEASURED across
  all 150 logs here: `NetworkServer.cpp` only ever writes its
  `Skip sending unreliable network data to client <id>` warning about a REMOTE
  client, never about the host's own loopback. No crowd of bots produces one,
  because a bot holds no client connection. The good news in the same fact:
  the budget is per client and independent, so **one guest measures it as well
  as twenty would.**

---

## How to move a line from C to A

One session, in this order. It is written out step by step in
[`ROADMAP.md`](ROADMAP.md) under **Phase 1**.

The short version: `python dev/check_all.py --sync`, restart the game, and then
**read `Logs/game-*.log` first, not last.** Every hard bug in this project was
named by that file, several of them weeks before anybody looked.
