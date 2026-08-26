# Server Works — what happens next

**This file is the handover.** Everything the next session needs is here or
linked from here; nothing important lives only in the conversation.

Companions:
[`STATUS.md`](STATUS.md) **what is verified and what is not** — read this one ·
[`CROWD.md`](CROWD.md) the crowd and the benchmark, and what they cannot cover ·
[`ROADMAP.md`](ROADMAP.md) the phased plan ·
[`../CLAUDE.md`](../CLAUDE.md) engine facts with citations ·
[`ANTI-GRIEF.md`](ANTI-GRIEF.md) why protection cannot be prevention ·
[`MODS-AND-TRUST.md`](MODS-AND-TRUST.md) why `allow_add_mods` is false ·
[`BUTTONS.md`](BUTTONS.md) everything a json GUI needs ·
[`CHANGELOG.md`](CHANGELOG.md) what every version fixed

Current version: **V56**. All 148 checks pass. `python dev/check_all.py --sync`
before playing, and **restart Scrap Mechanic** — scripts are read at world load.

---

## THE NEXT STEP: run an event

Not build anything. **Run one.**

V55 spent itself on measurement — `/crowd`, `/bench`, a benchmark reporter, a
character-set generator, sixty new checks. That work is done and it answered the
question it was built for. What it did not do is touch goal 2 or goal 3, and the
core of goal 2 — *freeze every build once a batch is finished* — **has still
never been run in a real event.** Neither has the event clock, nor restore, nor
the plot rules in anger.

The project's own working agreement is *one working freeze beats five stubbed
systems*. There are now rather more than five measured systems and no run event.

So: open [`STATUS.md`](STATUS.md), start at section C, and turn red lines green.
One sitting, `Logs/game-*.log` open afterwards.

### The two settings that now have numbers behind them

Both were guesses before this session. Neither is any more.

**1. The per-plot part limit.** All the limits are currently `0`, which is off.
The measured cost on this machine is **0.0058 fps per shape**:

| you want to hold | total shapes | per plot, 20 builders |
|---|---|---|
| 45 fps | ~2,100 | **~105** |
| 31 fps (what the 2026-08-22 event actually did) | ~4,500 | ~225 |

`/set maxparts 105` is now a defensible number rather than a taste call. It is
also the first time `Rules.lua` rule 10 will have run at all.

**2. Freeze each batch when it is finished.** Not for the simulation — the
simulation never struggles — but for the **per-client network budget**, which is
the only failure mode measured on this machine that produces something a player
would call broken. A static body has nothing to replicate per tick. This is an
inference, clearly flagged as one in `CLAUDE.md`, and running an event is what
would test it.

---

## What V55 measured, in three lines

Full detail in [`CROWD.md`](CROWD.md) and `CLAUDE.md`.

- **The server does not die.** `/bench` walked a crowd to 128 characters and
  2,102 bodies and the tick rate never left 40 Hz. Not once, at any size. Player
  count was never the risk — the premise this project started from was wrong,
  and the owner's own 19-player log said so before any of this was built.
- **One character costs about 24 shapes of frame time.** Twenty players'
  characters are ~2.7 fps, i.e. free. Content accumulates without limit over an
  evening; people do not. **Budget content.**
- **The network budget is the real hazard, and it needed no guest.** Thirteen
  sessions in `Logs/` show genuine starvation, the worst being **6.8 seconds**
  during which a client received no state at all. 93% of it happens mid-play,
  not at join.

### What is still not measurable here

A second machine's rendering, and the aggregate host upload of twenty real
clients. The per-client budget is per client and independent, so the existing
logs characterise it; the total is arithmetic on top. There is no longer an
outstanding "invite a guest" task — that recommendation was made repeatedly and
was never necessary.

---

## The focus marker, and the one thing it now needs

V56 added it and it was **confirmed working the same day** — marker, name and
compass icon, all three, in one screenshot. See
[`STATUS.md`](STATUS.md) for exactly what that does and does not prove.

What it needs is the thing nothing else in this project needs quite so badly:
**one other person in the world.** Every other feature can be judged from the
host's own screen. This one exists entirely so that *other people* can see who
to look at, and `sendToClients` reaching one client is not evidence it reaches
two. It is a thirty-second test the moment anybody joins — focus them, ask if
they see a marker over their own head, ask if they see one over yours.

That is the same guest this project already needs for the per-client network
budget (see [`CROWD.md`](CROWD.md)). One visit settles both.

---

## Everything else that is untested

[`STATUS.md`](STATUS.md) is the ledger and it is the file to trust. In brief,
never run in a real event: the freeze, the event clock end-to-end, `/restore`,
the plot rules under contention, the grief alarm now that its false positive is
fixed, the focus panel and its search, and every host panel except the ones the
button saga forced through.

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
4. **Is `garden` the right default?** The choice is built; the default is easy to
   change.
5. **Six style presets exist** — garden, brutalist, boardwalk, arctic, warehouse,
   neon. Guesses at taste, free to change.
6. **`/purge here <radius>`** is the same guess-and-delete shape as the sweep
   that was removed on request. Say the word and it goes too.
7. **`allow_add_mods` is `false`** (V54). The mod list is the trust boundary, so
   decide it per event rather than leaving it open.
8. **Crowd looks: eleven.** The bots wear vanilla's ten in-game NPC mechanic
   outfits plus the classic mechanic. More variety is possible and it is not
   free — a bespoke outfit per bot is what took 20 bots to 8 fps. If a crowd of
   128 needs to look less repetitive, add characterset entries with
   `dev/gen_characterset.py`; do not go back to dressing them at runtime.

---

## Parked, by agreement

- Quest markers for plots, and the invite system.
- `PhysicsQuality` — the one lead on a simulation knob, still unmeasured, and now
  clearly pointless: the simulation was never the bottleneck.
- Goal 3, whatever it turns out to be. Still not scoped.

---

## How to work on this

- `python dev/check_all.py --sync` — four suites, ten seconds, then installs.
  **139 checks.** A pass does not mean it works; a failure is always real.
- **Read the log first.** Every hard bug in this project was named by
  `Logs/game-*.log`, several of them weeks before anybody looked.
- **Write the check by breaking the code.** Every check added this session was
  written by putting the bug back and watching it fail. Two were passing for the
  wrong reason until that was done, and one of the mutations turned out to be
  harmless — which is itself how a latent bug in the wall style was found.
- **Say when a claim is unmeasured.**

### The one that cost the most, this session

**A plausible explanation that fits the evidence is not the one that survives a
second measurement.** It went wrong four times in a day, always the same way — a
tidy story, stated, not checked:

| the story | what was actually true |
|---|---|
| a character script cannot `dofile` mod content | it can; the global was being blanked by another instance on another thread |
| 95 bots at 30 fps means the crowd is cheap | the appearance code was throwing, so all 95 shared one renderable set |
| the network budget blows up at join | 7% of skips are near a join; 93% are mid-play |
| freezing buys nothing, simulation was never the bottleneck | true of simulation, wrong about the network budget |

Three of the four were caught by the owner, not by the checks. In every case the
answer was already in vanilla's own files or in `Logs/`, and the cost of looking
was under a minute. **Look first.** Vanilla's own practice is the strongest
signal available and it was right every single time: `overrideRenderableList` has
one caller in the whole game, zero character scripts call `setmetatable`, and ten
different-looking mechanics are ten characterset entries.
