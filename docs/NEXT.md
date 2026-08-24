# Server Works — what happens next

Written 2026-08-24 at the end of a long session, immediately before compacting
the chat. **This file is the handover.** Everything the next session needs is
here or linked from here; nothing important lives only in the conversation.

Companions:
[`../CLAUDE.md`](../CLAUDE.md) engine facts with citations ·
[`ANTI-GRIEF.md`](ANTI-GRIEF.md) why protection cannot be prevention ·
[`BUTTONS.md`](BUTTONS.md) everything a json GUI needs ·
[`CHANGELOG.md`](CHANGELOG.md) what every version fixed ·
[`PLAN.md`](PLAN.md) the original plan of record

Current version: **V51**. All 76 checks pass. `python dev/check_all.py --sync`
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

### What to check, in order

1. **Does the count land on the right tile?** Build something with 12 bearings on
   one plot. The owner should be told, and that plot alone should lock.
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
4. **Does trimming unlock it again?** The audit runs every 5 s, so a plot should
   reopen within about five seconds of the offending part being removed.
5. **The numbers themselves are yours.** 10 joints, 1 bot, 25 lights are the
   2026-08-22 board. `/menu → SERVER SETTINGS`, or `/set maxjoints 15`.

### Likely work once it is tested

- **A live budget readout.** The owner asked for this originally — "a live HUD so
  builders self-regulate". Right now you find out by being locked. `MY PLOT`
  should show `bearings 7/10 · bots 0/1 · lights 3/25`.
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

### 3. The rest, in one list

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
4. **`/purge here <radius>`** is the same guess-and-delete shape as the sweep
   that was removed on request. Say the word and it goes too.

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
  **76 checks.** A pass does not mean it works; a failure is always real.
- **Read the log first.** Every hard bug in this project was named by
  `Logs/game-*.log`, several of them weeks before anybody looked.
- **Write the check by breaking the code.** Every check added in this session was
  written by putting the bug back and watching it fail. Several were passing for
  the wrong reason until that was done.
- **Say when a claim is unmeasured.** This was broken once this session, on the
  `enableBuildOn*` flags, and the owner caught it.
