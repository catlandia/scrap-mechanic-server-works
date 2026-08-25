# Server Works — what happens next

Written 2026-08-24 at the end of a long session, immediately before compacting
the chat. **This file is the handover.** Everything the next session needs is
here or linked from here; nothing important lives only in the conversation.

Companions:
[`STATUS.md`](STATUS.md) **what is verified and what is not** — read this one ·
[`ROADMAP.md`](ROADMAP.md) the phased plan, in detail ·
[`../CLAUDE.md`](../CLAUDE.md) engine facts with citations ·
[`ANTI-GRIEF.md`](ANTI-GRIEF.md) why protection cannot be prevention ·
[`BUTTONS.md`](BUTTONS.md) everything a json GUI needs ·
[`CHANGELOG.md`](CHANGELOG.md) what every version fixed ·
[`PLAN.md`](PLAN.md) the original plan of record

Current version: **V53**. All 90 checks pass. `python dev/check_all.py --sync`
before playing, and **restart Scrap Mechanic** — scripts are read at world load.

---

## THE NEXT STEP: make the per-tile part limit actually work

**Asked for as:** *"about the part limit. make sure it works as per tile as we
selected too. one tile cant have more than X of X combined."*

### It is already written. It has never been run.

`mod/Scripts/Rules.lua` implements the rules board from the 2026-08-22 event, and
the per-tile budget is rule 10 on that board:

| rule | setting | default | what it counts, per plot |
|---|---|---|---|
| 10 | `maxjoints` | **10** | bearings **+** pistons **+** suspensions, **combined** |
| 6 | `maxbots` | 1 | craft / cook / dress bots |
| 4 | `maxlights` | 25 | lights |
| 1 | `minbuildheight` | 0 | blocks below this z — no basements |

`0` means unlimited on any of them.

**"X of X combined" is exactly what `maxjoints` already does** — it does not
count bearings and pistons separately, it counts the joints of the whole
creation, which is the same number. That is also the right performance metric:
a 500-block static sculpture is nearly free, twenty bearings are not.

### How it behaves

- Audited every **5 seconds** (`Rules.AUDIT_SECONDS`), not per tick.
- A plot over budget goes into `g_swPlots.overBudget`, and `sv_bodyIsOpen`
  returns `false` for it — **the plot locks until the owner trims it.**
- **Nothing is ever taken away.** Over-budget is a brake, not a punishment. The
  one exception is contraband explosives, which are removed regardless, because
  announcing that a live cornade exists and leaving it there helps nobody.
- The owner is told what to trim, and told again on a cooldown, not every pass.

### V53 fixed the deadlock this had

REPORTED, from the first test: *"I cant break the block if I hit the limit. so
like I am stuck in a loop I cant remove the bearing that prevents from
building."*

Going over budget handed the plot the **locked** profile, which is
`erasable = false` — so the one action that could satisfy the limit was the one
the limit forbade. There is a `trim` profile now: everything the open profile
allows, minus placing. The check also moved to run *after* the ownership logic
and can only ever downgrade an open verdict, so an over-budget plot that was
locked to a passer-by stays locked to them.

### Two things before you test it

**1. `plots` defaults to OFF.** With plots off, `sv_bodyIsOpen` returns nil
immediately and the `overBudget` check is never reached — so the audit still
counts, still warns the owner, and **locks nothing**. That alone would make the
whole feature look broken.

    /set plots on

**2. `/budget` shows the numbers.** Stand on a plot, or `/budget 23`:

    plot 23, as of the last audit:
       bearings/pistons/suspensions   14 / 10   OVER
       craft/cook/dress bots           0 / 1
       lights                          3 / 25
       -> this plot is LOCKED until it is trimmed

Not host-gated — a builder needs it more than the host does. At most five
seconds stale, because that is the audit interval.

### What to check, in order

1. **Does the count land on the right tile?** Build something with 12 bearings on
   one plot. The owner should be told, and that plot alone should stop taking
   new parts — while still letting you *remove* the bearings. That second half is
   V53 and has not been run either.
2. **Does a creation get counted once?** `getCreationJoints()` returns the joints
   of the *whole creation*, and every body in it returns the same list — so a
   4-bearing car must not count as 4 × 4. `countedCreations` keys on
   `body:getCreationId()`, which is **an unproven binding**: if it errors the
   pcall falls through to counting per body and every multi-body creation
   instantly blows its budget. Watch for a plot locking at a quarter of the
   limit.
3. **A creation straddling two plots.** Attribution is by AABB centre
   (`Plots.sv_bodyZone`), so a build spanning a team's plots lands on whichever
   plot the middle of it is over. Decide whether that is right for teams, or
   whether a team should share one pooled budget.
4. **Does trimming unlock it again?** About **one second** now, not five: V53
   added a scoped pass at 1 Hz over the plots people are standing on, on top of
   the 5 s full pass. If it still takes five, the scope is coming back empty —
   `Plots.sv_updateOccupancy` fills it, so plots being off would do it.
5. **The numbers themselves are yours.** 10 joints, 1 bot, 25 lights are the
   2026-08-22 board. `/menu → SERVER SETTINGS`, or `/set maxjoints 15`.

### Likely work once it is tested

- **The readout on the panel, not just in chat.** `/budget` exists now; the
  original ask was "a live HUD so builders self-regulate", which means `MY PLOT`
  showing `bearings 7/10 · bots 0/1 · lights 3/25` without anybody typing.
- **A team budget.** If four people team up, is the limit per plot or per team?
  Per plot is what happens today.

---

## Everything else that is untested

Nothing below has been confirmed in a real event. Ordered by how much it matters.

### 1. Building on your own plot during build time

The longest-running open bug in the project. Chased through V28–V51 and there is
now a chain of real fixes that each *could* have been it:

- V46 — every body was located by `body.worldPosition`, its **origin**, not
  where it is. Every plot in the city resolved to `sweep`
  (`buildable = false, erasable = true`), which is exactly "can't place, can
  delete". **Most likely the answer.**
- V48 — a dead event resurrected itself on every load and dropped the world into
  a fresh `polish` (no build, no erase) window. Also produces the symptom.
- V50 — stepping onto a road locked your own plot behind you.
- V43 — the floor is unpinned during build time.

**The line that settles it**, printed once per city build and once per phase
change:

    [ServerWorks] where the city landed: 196 bodies -- filler 99, plot 96, plaza 1
    event build -> protection open (99 bodies, 99 changed) [locked 2, open 96, sweep 1]

96 plots resolving to `plot`, and 96 bodies coming out `open`, is the pass
condition.

### 2. The lift

Still not confirmed working. What is now true:

- **Import Lift** (V49) — our own uuid, creative `Lift` class, named in the menu.
- **Nothing in this mod can take a lift away** (V51) — all three lifts are out of
  the tool gate, and the `lift`/`hostlift` settings are gone.
- A locked or display world **does** refuse new creations, and now says so.
- `World.enableBuildOnLift` and friends are set explicitly — **not** known to
  have been the bug; see the note in `World.lua`, which is honest about it.

Next: `/tool` while holding it, during **build** phase, and read
`[ServerWorks] ghost body seen and skipped` — if a lift was used and that line is
absent, the ghost guard is not recognising ghosts and that is where to look.

### 3. New in V53, none of it run

- **The trim profile** — over budget stops placing and nothing else. Watch for
  the message: it now says *"You CAN still remove parts, paint and rewire."*
- **The two-cadence audit** — 1 Hz over occupied plots, 5 s over everything.
  Contraband is only collected on the full pass.
- **City style** — `/citystyle` for the list, `/citystyle brutalist` for the old
  concrete-and-grey, or one of the ten settings on the **CITY STYLE** page of
  `/settings`. **The default changed to `garden`: a deep green carpet pad.**
  Nothing restyles a city that already stands — BUILD CITY again.
- **The top-left counter** — ONLINE and RESIDENTS. If it is missing entirely,
  look for `[ServerWorks] roster HUD unavailable` in the log; if it is in the
  wrong corner, `RosterHud.TopLeft` has the arithmetic and the check for it.

### 4. The rest, in one list

- **The city as separate bodies with stands** (V39). Rebuild and look at it.
- **Buffer time polishing** (V41) — paint, wire, drive; no placing or breaking.
- **Typed event times** (V45) — the handler touches the GUI *not at all* now,
  after two crashes. If it still crashes on the second box, the EditBoxes come
  out and the steppers stay.
- **Phase snapshots** (V50) — `prepstart`, `buildstart`, `buildend`, `eventend`.
- **The cleaner** — named in the menu at last (V49), looks like a sledgehammer,
  crosshair prompt when held.
- **Banning** — every path now reaches `sm.game.banPlayer`. Our list is keyed on
  the **display name** because Lua is given no stable player id, so **the allow
  list is the stronger tool** for a public event: `/set allowlist on`.
- **The grief alarm** — 20-second window, threshold 400, and it **no longer locks
  by itself** (V50). One 16×16 delete is 256 shapes and must stay quiet.
- **`allow_add_mods: false`** (V54) — the world has never been created with it
  off. Check only that it still creates and still lists; it changes the
  world-creation screen, which nothing in `dev/` can see.
- **Two host gates** (V54) — `Game.sv_n_openPanel` and
  `NotLift.sv_n_swOpenImport`. **Cannot be tested solo.** Proving a guest is
  refused needs a second client, and the install has no dedicated server to
  stand in for one. Low priority: the server is invite-only and the surface
  audits clean. See [`MODS-AND-TRUST.md`](MODS-AND-TRUST.md).

---

## Open decisions, waiting on the owner

1. **Plot size.** The reference blueprint is 22×22 with a **20×20** concrete
   interior — the metal ring goes *around* a 20-block pad. Ours puts the ring
   *inside* a 20-block plot, leaving **18×18** to build on. Matching the
   blueprint means street width 1 → 2 and a city about 10% wider.
2. **Wedges.** The original event separated panels with wedges. Ours uses flat
   strips. If the wedges were doing something specific — a bevel, a ramp — say
   so and it can be matched.
3. **Team budgets** — per plot or pooled? Per plot today.
4. **Is `garden` the right default?** The green carpet was asked for, then the
   ask became "make a choice". The choice is built and the green carpet is what
   it defaults to; say the word and the default goes back to `brutalist`.
5. **Six style presets exist** — garden, brutalist, boardwalk, arctic,
   warehouse, neon. They are guesses at taste and cost nothing to change.
6. **`/purge here <radius>`** is the same guess-and-delete shape as the sweep
   that was removed on request. Say the word and it goes too.
7. **`allow_add_mods` is now `false`** (V54), which is what shuts the only door a
   mod like T mod has into an event. The cost is that players get no building
   parts beyond base content. If an event wants a specific parts mod, this is the
   word to change — but the mod list is the trust boundary, so decide it per
   event rather than leaving it open.

---

## Parked, by agreement

- Quest markers for plots, and the invite system.
- **Frame rate**, which is what the very first measurement actually pointed at:
  nineteen players never dented the tick rate, but client FPS slid with *time*,
  i.e. accumulated world content. That is a render problem and none of this
  addresses it.
- `PhysicsQuality` — the one lead on a simulation knob, still unmeasured.

---

## How to work on this

- `python dev/check_all.py --sync` — four suites, ten seconds, then installs.
  **90 checks.** A pass does not mean it works; a failure is always real.
- **Read the log first.** Every hard bug in this project was named by
  `Logs/game-*.log`, several of them weeks before anybody looked.
- **Write the check by breaking the code.** Every check added in this session was
  written by putting the bug back and watching it fail. Several were passing for
  the wrong reason until that was done.
- **Say when a claim is unmeasured.** This was broken once this session, on the
  `enableBuildOn*` flags, and the owner caught it.
