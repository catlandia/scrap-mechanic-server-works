# What is actually verified, and what is not

Written 2026-08-24, at V53. **This file is the honest ledger.** Everywhere else
in this repo describes what the code is *meant* to do; this one says which of it
has been seen to happen.

Read it before believing any other document in here.

---

## The one thing to understand about the checks

`python dev/check_all.py` runs **91 checks** in ten seconds and they all pass.
That is worth having and it is not evidence the mod works.

| what the checks DO touch | what they CANNOT touch |
|---|---|
| the rules, run as real Lua through `lupa` | a body, or any permission flag on one |
| city geometry, proved a partition | a tool, or whether a tool can be held |
| panel layout at every resolution | the network, client or server |
| fonts: existence *and* glyph coverage | the renderer, and therefore frame rate |
| the command plumbing, both directions | the lift, blueprints, or `importFromString` |
| every setting, preset and migration | anything the engine does with any of it |

Nothing in `dev/` has ever created a body, equipped a tool, or sent a packet.
**A passing suite means "no known logic error". A failing one is always real.**

---

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

## B. Seen BROKEN in game — a fix shipped, not re-tested

**This is the most important section in the file.** Every line is a real report
from a real session, with a real fix behind it, and **not one of them has been
seen working since.** A fix that has not been re-tested is a hypothesis.

| reported | version | what was found | re-tested? |
|---|---|---|---|
| *"I cant build on my plot even when the time has started"* | V43, V46, V48, V50 | four separate causes, each sufficient on its own — see below | **no** |
| *"the lift is still fuc-SAD"* | V49, V51 | added an Import Lift on our own uuid; took all three lifts out of the tool gate | **no** |
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

Two facts from `dev/session_stats.py` over the owner's own logs. These are the
only *numbers* this project has.

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

---

## How to move a line from C to A

One session, in this order. It is written out step by step in
[`ROADMAP.md`](ROADMAP.md) under **Phase 1**.

The short version: `python dev/check_all.py --sync`, restart the game, and then
**read `Logs/game-*.log` first, not last.** Every hard bug in this project was
named by that file, several of them weeks before anybody looked.
