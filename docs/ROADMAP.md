# Roadmap

Written 2026-08-24 at V53. Companion to [`STATUS.md`](STATUS.md), which says what
is verified, and [`NEXT.md`](NEXT.md), which is the short handover for the very
next session.

**The ordering principle:** this project has ten features written and roughly two
confirmed working. Building an eleventh is worth less than confirming the third.
So Phase 1 is not a feature.

---

## Phase 1 — turn the ledger from red to green

**Goal: move as many lines as possible from [`STATUS.md`](STATUS.md) section C
("never run") into section A ("seen working").** Nothing new gets built until
this is done. It needs one person, one sitting, and no group.

### Before starting

```
python dev/check_all.py --sync
```

Then **restart Scrap Mechanic** — scripts are read at world load, and a running
game will not pick up a sync. Load Play → Custom Game → Server Works.

**The pass condition for the whole session is a quiet log,** not "the mod appears
to work". Keep `Logs/game-*.log` open. A `[Lua]` traceback repeating once a
second is a worse outcome than a feature not working.

### 1.1 The world came up correctly

Read these four lines out of the log before touching anything:

```
[ServerWorks] world ready, protection open (...)
[ServerWorks] build on: lift=true bodies=true surface=true assets=true
[ServerWorks] gui canvas 1720x720 (panels are declared in these units)
[ServerWorks] identity: N known players, M bans
```

- If the canvas height is at or below **690**, `SettingsGui` is overflowing the
  screen and some buttons are physically unreachable. That is the first thing to
  fix and it is a one-number change.
- If `build on:` is missing, `World.lua` did not load.

### 1.2 Turn the plot system on

```
/set plots on
/plotgrid 20 1 10 10
/plotmenu     -> BUILD CITY
```

Then read the line the city prints:

```
[ServerWorks] where the city landed: 196 bodies -- filler 99, plot 96, plaza 1
```

**96 bodies coming out `plot` is the pass condition.** If plots are landing as
`filler` or as nothing, `sv_bodyZone` is wrong and everything downstream of it
is meaningless — stop and fix that first.

### 1.3 The oldest open bug: can you build on your own plot?

```
/plot claim
/event start 0 30
```

Then place a block on your own concrete, and try to place one on a neighbour's.

The line to read on every phase change:

```
event build -> protection open (99 bodies, 99 changed) [locked 2, open 96, sweep 1]
```

**96 `open` is the pass condition.** Any `sweep` in that breakdown where a plot
should be means V46's fix did not take.

Four fixes are stacked behind this — see [`STATUS.md`](STATUS.md) section B for
which one to suspect if it still fails.

### 1.4 The lift

Hold it during **build** phase and place a saved creation.

- If nothing spawns, look for `[ServerWorks] ghost body seen and skipped`. If the
  lift was used and that line is **absent**, `body:isGhost()` is not recognising
  ghosts and the patrol is pinning `convertibleToDynamic = false` on the creation
  before it can be placed. That is where to look, and only there.
- `/tool` while holding it prints which uuid you actually have. There are three
  lifts and they are different items.

### 1.5 The part limit — the current next step

Already written in `Rules.lua`, never run.

```
/set plots on          (again: without this it counts and locks NOTHING)
/set maxjoints 10
```

Build 12 bearings on one plot, then:

```
/budget
```

Five things to check, in order:

1. **Does the count land on the right tile?** That plot alone should stop taking
   new parts.
2. **Can you still remove the bearings?** This is V53 and it is the fix for
   *"I cant break the block if I hit the limit"*. If you cannot, the `trim`
   profile is not being reached.
3. **Is a 4-bearing car counted as 4, not 16?** `body:getCreationId()` is an
   unproven binding. **If a plot locks at roughly a quarter of the limit, that
   call is failing** and the pcall is falling through to counting per body.
4. **Does trimming reopen it within about a second?** Not five — V53 added a
   scoped 1 Hz pass. Five seconds means the scope is coming back empty.
5. **A creation straddling two plots** is attributed by AABB centre. Decide
   whether that is right for teams, or whether teams should pool a budget.

### 1.6 The things nobody has ever run

Each is one command and each is load-bearing for a real event.

| test | how | what would go wrong |
|---|---|---|
| ~~snapshot~~ | already confirmed — the installed `Snapshots/` folder holds a complete, exact 195-entry capture of a real city. See [`STATUS.md`](STATUS.md) section A | — |
| **restore** | `/restore test` — **twice**, it is deliberately two-step | `importFromString`'s last two arguments are a guess. **This is the single most important untested thing in the project.** Capture is proven; a backup nobody has restored from is not yet a backup |
| ban | `/ban <name>` with a second machine, then `/banlist` | `sm.game.banPlayer` has never been called |
| allow list | `/allow <name>` then `/set allowlist on` | stronger than bans and completely untried |
| cleaner | equip it, click a craftbot, hold **F** on a creation | the only thing that can remove a carryable prop |
| the alarm | delete a 16×16 patch (256 shapes) | must stay **quiet**. `alarmdrop` is 400 |
| ~~autosave~~ | already confirmed — `auto1`..`auto6` rotating on schedule on disk | — |
| ~~settings surviving a restart~~ | already confirmed — `sm.json.save` writes into the installed mod fine. But Workshop replaces a mod wholesale on update, so the master ban list should still be synced in from outside | — |

### 1.7 New in V53

- `/citystyle` — read the list, then `/citystyle brutalist`, then **BUILD CITY
  again**. Nothing restyles a city that already stands.
- The **CITY STYLE** page of `/settings` — click a value, it cycles.
- The top-left **ONLINE / RESIDENTS** counter. If it is missing entirely, look
  for `[ServerWorks] roster HUD unavailable`.

### Phase 1 is done when

Every line in [`STATUS.md`](STATUS.md) section C is either moved to A or has a
named reason it failed. Update that file as you go — it is the deliverable.

---

## Phase 2 — the part limit, finished

Assumes 1.5 passed. These are the things the limit needs before an event can
lean on it.

### 2.1 The budget on the panel, not just in chat

The original ask was *"a live HUD so builders self-regulate"*. `/budget` exists
now; nobody types it.

`MY PLOT` should carry a line:

```
bearings 7/10 · bots 0/1 · lights 3/25
```

`Rules.lastPerPlot` already holds the numbers and `MyPlotGui` already re-renders
on every action. This is plumbing, not design. **Half a day.**

Consider a colour change at 80% so somebody notices before they hit the wall
rather than after.

### 2.2 Team budgets — a decision first

Per plot today. If four people team up, four plots is four budgets, and a single
build spanning them is attributed to whichever plot its AABB centre is over.

Two coherent answers, and this is the owner's call:

- **Per plot** (today). Simple, predictable, and a team of four can legitimately
  build a 40-bearing machine by spreading it out.
- **Pooled per team.** `Plots.sv_teamOf` already returns the whole team, so
  summing is a few lines. Harder to explain, harder to display, but it is what
  "ten per tile" probably means to somebody looking at a big team build.

### 2.3 Warn before locking

A plot that hits the limit currently locks and then explains. Warning at 90% and
locking at 100% would turn *"why did my plot stop working"* into *"I was told"*.
The cooldown machinery for this is already in `Rules.sv_shouldReport`.

---

## Phase 3 — frame rate, which is the problem that was actually measured

**This is the highest-value engineering work in the project and it has not
started.** See [`STATUS.md`](STATUS.md) section D: nineteen players never dented
the server tick, and client frame rate slid from 60 to 31 *with time*, not with
player count. That is accumulated world content.

Everything below is a hypothesis. Measure first with `dev/session_stats.py`,
which reconstructs tick rate and FPS from any log already on disk — no test group
required.

### 3.1 Plot spacing is a rendering decision

Cells that are far apart are unloaded, and unloaded is free. The current layout
optimises for a city that looks like a city. There is a real trade between
"twenty people can see each other's builds" and "twenty people are each drawing
twenty builds".

**Cheap experiment:** build the same city at `gap 1` and at `gap 8`, walk the
same route, and diff the two logs' frame counters. One evening, and it settles an
argument that would otherwise run for months.

### 3.2 Budget what is rendered, not what is simulated

`maxjoints` is the right metric for *simulation*. For rendering, the metric is
shape count and draw calls, and `body:getShapeCount()` is already being totalled
every patrol cycle for the grief alarm — the number is free.

A `maxshapes` per plot would be a different rule with a different justification,
and it should be presented as such rather than folded into the joint limit.

### 3.3 `PhysicsQuality` — the one unmeasured lead

The name is in the executable's string table and
`sm.game.getSettingValue( "PhysicsQuality" )` reads it. **There is no setter** —
but the host runs the physics for everyone, so the *host's* value governs the
server. `/protection` prints it.

It is not in `settings.json` until it is changed from the default, which is why
nobody has a baseline. **Get a value, change it in the host's options, re-run
`dev/session_stats.py` on both sessions.** Believe nothing until then.

### 3.4 How much of vanilla creative should survive?

`CreativeGame` brings `UnitManager` (with `aggroCreations = true`), a weather
manager and a water manager, and they cost real CPU on an event server where
nothing needs them. Turning them off is a `server_onCreate` override — but see
the 2026-08-08 collapse: **an override that does not call its parent is how
`g_unitManager` became nil and every collision threw a traceback.** Whatever gets
disabled, disable it deliberately, not by omission.

---

## Phase 4 — goal 3: the event, not just the building

Still the least specified part of the project, and deliberately so —
*"this is not only a build-server"* is as far as it has been taken.

Things the engine makes cheap, listed so a decision has options rather than a
blank page:

- **Judging and voting.** Plots are already numbered and owned. A `/vote 23`
  command and a results panel is a day's work and turns a build session into a
  competition with an ending.
- **Themes per event.** `Event.lua` already has phases; a theme string shown on
  the event HUD and in `/rules` costs almost nothing.
- **Spectator handover.** `polish` mode already exists (look, sit, drive, do not
  build). A `showcase` phase that teleports everyone to one plot at a time is
  `sm.player.setWorldPosition` plus a timer.
- **A tour.** The compass HUD is per-player and already working. Pointing it at
  "the plot currently being judged" is one call.
- **Prizes and records.** `Identity.players.records` is already a persistent list
  of everyone who has been here. Wins per person is one more field.

**None of this should start before Phase 1.** An event feature built on top of
unverified plot ownership inherits every one of its bugs.

---

## Phase 5 — the Survival branch

Explicitly out of scope until Creative works, and that has not changed.

Worth writing down now while the reasons are fresh:

- `baseGameContent` is already `"Survival"`, so the parts and tools are present.
  The switch is `Game = class( SurvivalGame )` and a different world class.
- **Every anti-grief mechanism carries over unchanged.** Body flags, plots,
  presence, snapshots and bans are all mode-agnostic.
- **The part budget does not.** In survival a bearing is a crafted item somebody
  spent resources on, and locking a plot over one is a different social contract.
- The thing that would actually need designing is loot and land: survival has
  containers, and `setUsable(false)` is the only lever over them.

---

## Open decisions waiting on the owner

Nothing here is blocked on code. Each is a taste call, and taste calls are the
owner's.

1. **Plot size.** The reference blueprint is 22×22 with a **20×20** concrete
   interior — the metal ring goes *around* a 20-block pad. Ours puts the ring
   *inside* a 20-block plot, leaving **18×18** to build on. Matching the
   blueprint means street width 1 → 2 and a city about 10% wider.
2. **Wedges.** The original event separated panels with wedges; ours uses flat
   strips. If the wedges were doing something specific — a bevel, a ramp, a
   visual seam — say so and it can be matched.
3. **Is `garden` the right default?** V53 defaults the city to a deep green
   carpet pad, which is what was asked for before the ask became "make a choice".
   `/citystyle brutalist` is one command away and could be the default instead.
4. **Six style presets** — garden, brutalist, boardwalk, arctic, warehouse, neon.
   They are guesses at taste and cost nothing to change or delete.
5. **Team budgets** — per plot or pooled? See 2.2.
6. **`/purge here <radius>`** is the same guess-and-delete shape as the sweep
   that was removed on request. Say the word and it goes too.
7. **How strict should the limits be?** 10 joints, 1 bot, 25 lights are the
   2026-08-22 board, transcribed. They are settings, not decisions.

---

## Parked, by agreement

- Quest markers for plots, and the invite system.
- Anything that tries to make Scrap Mechanic's physics faster. There is no knob;
  see [`STATUS.md`](STATUS.md) section E.

---

## The working agreements, restated

They have each been earned by a specific mistake, so they are worth keeping in
front of whoever picks this up.

- **Nothing ships that cannot be tested in one sitting.** One working freeze
  beats five stubbed systems.
- **Measure before optimising, and say when a claim is unmeasured.** This was
  broken once, on the `enableBuildOn*` flags, and the owner caught it.
- **Verify against the game, not against memory.** The wiki and the training data
  both lag this build. Write down where a fact was found, as `CLAUDE.md` does.
- **Write the check by breaking the code.** Every check added in the last two
  sessions was written by putting the bug back and watching it fail. Several
  were passing for the wrong reason until that was done.
- **Read the log first.** Every hard bug in this project was named by
  `Logs/game-*.log`, several of them weeks before anybody looked.
- **Fail back to vanilla.** If a script errors mid-event the lobby must not be
  left frozen or unable to build.
