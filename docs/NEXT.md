# Server Works — what happens next

**This file is the handover.** Everything the next session needs is here or
linked from here; nothing important lives only in the conversation.

Companions:
[`STATUS.md`](STATUS.md) **what is verified and what is not** — read this one ·
[`CROWD.md`](CROWD.md) the crowd and the benchmark, and what they cannot cover ·
[`HARNESS.md`](HARNESS.md) automating the CITY RULES -- designed, not built ·
[`ROADMAP.md`](ROADMAP.md) the phased plan ·
[`../CLAUDE.md`](../CLAUDE.md) engine facts with citations ·
[`ANTI-GRIEF.md`](ANTI-GRIEF.md) why protection cannot be prevention ·
[`MODS-AND-TRUST.md`](MODS-AND-TRUST.md) what a co-loaded mod can do ·
[`BUTTONS.md`](BUTTONS.md) everything a json GUI needs ·
[`CHANGELOG.md`](CHANGELOG.md) what every version fixed

Current version: **V74**. All 217 checks pass. `python dev/check_all.py --sync`
before playing, and **restart Scrap Mechanic** — scripts are read at world load.

---

## V65, and what it changed about who can do what

- **A guest has one chat command: `/menu`.** Everything else is host-only. They
  still do everything they could before, through buttons -- the menu is now the
  only door rather than one of two. If something a guest needs turns out NOT to
  be on it, that is the bug, not the refusal.
- **Every host panel gates at its opener**, not only on the menu that hides the
  button.
- **`citybuild`** (SERVER SETTINGS, PLOTS) opens the roads, the plaza and the
  decking for building. Off by default. It does not survive a `/lockdown`, and
  it costs the litter escape on shared ground -- see the changelog.
- **The unstuck button lands in the middle of the city**, 20 blocks above
  whatever is standing there, instead of vanilla's fixed 16,16 out in a field.
- **The ban list is proven to survive a new world**, perma ids included.

---

## V64, and what it changed about the shape of a session

Asked for when the owner's time to test got shorter, which is the constraint
this build is written around:

> "look now ive got far less time to test and work on the mod ... you are gonna
> polish the mod in state that it is now."

So nothing new was started. What changed is what the mod OFFERS:

- **The menu is ten entries, not twelve.** `DEV TOOLS` and `TESTING CHECKLIST`
  are behind **`/developer on`**, which is off by default and persists. That is
  a gate rather than a filter -- `/crowd`, `/bench`, `/bridge` and `/check` all
  refuse while it is off, and the four places that open a dev panel each ask the
  mode again, because the menu is drawn on the player's own machine.
- **You can always switch a dev tool OFF.** `/crowd off`, `/crowd 0`,
  `/bench stop` and `/bridge off` work whatever the mode. Turning developer mode
  off with a crowd standing would otherwise strand it -- the same shape as the
  part budget that forbade its own remedy.
- **Banning is a list you click, and never a name you type.** `WHO IS HERE ->
  EVERYONE SEEN` lists every player the server has ever recorded, with BAN on
  each row and UNBAN on anyone already banned. The button carries the `SW-` id,
  because a Scrap Mechanic name can hold characters a host cannot type at all.
  The FIND box only narrows the list.
- **The mod says it is a WORK IN PROGRESS** on the menu, in the join message and
  in its Custom Game description -- to guests as well as the host.

**This changes the first two minutes of every test session from here on.** A
fresh world comes up with developer mode OFF, so the way in is:

    /developer on

and then `/check` and `/bridge on` are reachable again. `docs/CHANGELOG.md` V64
has the reasoning for each piece.

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

### START HERE: three things, in this order

**1. Look at the middle of the city.** The first restore ever run left a hole
where the plaza had been, that is fixed, and the fix has been re-run — 195
bodies back, 99 deck creations where a hole would leave 98. The only thing
missing is somebody's eyes on it. Then `backup-restore` goes green.

**2. Re-test `/lockdown`, which V60 rebuilt again and which has still never
run.** It is now three things rather than one: every tool off a **guest** and
none off **you**, fire and cratering and aggro forced off by the mode, and a
four-metre bubble that follows you so you can still fix things while the world
is shut. `/lockdown`, then `/protection` — it prints the guest list, the host
list and whether the bubble is open, shut or switched off.

The bubble is the part to look at hardest, because it is an approximation and
not a permission: there is no per-player build flag in this engine (39 Body
bindings, none takes a player), so the mod unlocks the ground you are standing
on and relocks it when you leave. Another **player** standing next to you shuts
it; a crowd bot does not. `/check` has three items for all of this —
`prot-lockdown`, `prot-hostbuild`, `prot-lockdown-fire`.

**3. `/developer on`, then `/bridge on`, and the work moves off your hands.**
V64 put the dev tools behind that first switch, so a fresh world refuses the
second one until it is thrown. The bridge carried its
first real session on 2026-08-29 and found two bugs in an hour, in features
that had shipped weeks earlier and never been run. It is off by default and
the switch persists; a world that comes up with it open says so in the log.

    python dev/bridge.py --status
    python dev/bridge.py --file dev/bridge_smoke.txt --wait 3

**What it cannot reach:** a second player, a held tool, a key press, a button,
or the screen. That is roughly half the checklist and it stays yours.

### The list in the game, for the half a bridge cannot do


In the game, once per install, as host:

    /developer on
    /bridge on

That lets a running world be driven from outside it -- I write a file into
the mod folder, the mod runs it as you and writes back everything it said.
The first batch to run is `dev/bridge_smoke.txt`, which proves the channel
works at all:

    python dev/bridge.py --file dev/bridge_smoke.txt --wait 3

It is off by default and it is a door -- `docs/CHANGELOG.md` V58 has the four
rules that keep it narrow. **What it cannot reach:** a second player, a held
tool, a key press, a button, or the screen. Those stay yours, and they are
roughly half the checklist.

### V57 put the list in the game, so the other half is one command

    /developer on   V64: the checklist and the dev tools are behind this
    /check          the panel: 90 items, grouped, in the order to run them
    /check next     the next thing nobody has ever tried

Answer each one with a click. It writes `Checklist.json` in the installed mod on
every press -- so the session leaves a FILE behind rather than a conversation
somebody has to remember to have, and

    python dev/checklist_report.py

reads it back out on this side: the failures with their notes first, then what
is still untried. That is the fastest handover this project has ever had, and
it exists because writing results down by hand was costing more than the
testing.

The catalogue is [`STATUS.md`](STATUS.md) section C and `ROADMAP.md` phase 1,
restated one item at a time. **Start with BOOT.** Nothing below it means
anything if the world came up wrong, and `boot-quiet` -- a log with no repeating
traceback in it -- is the pass condition for the whole sitting.

### The two settings that now have numbers behind them

Both were guesses before this session. Neither is any more.

**1. The per-plot part limit.** The limits are NOT off -- `maxjoints` is 10,
`maxbots` is 1, `maxlights` is 25 by default. What is off is `plots`, and
`Rules.lua` enforces nothing at all until that is on, which is the real reason
none of it has ever run at an event.
The measured cost on this machine is **0.0058 fps per shape**:

| you want to hold | total shapes | per plot, 20 builders |
|---|---|---|
| 45 fps | ~2,100 | **~105** |
| 31 fps (what the 2026-08-22 event actually did) | ~4,500 | ~225 |

**CORRECTED, V57: there is no setting to put that number in.** Earlier versions
of this file said `/set maxparts 105` was "now a defensible number rather than a
taste call". There is no `maxparts`. `Rules.lua` enforces exactly three limits --
`maxjoints`, `maxbots`, `maxlights` -- and a per-plot SHAPE budget is not one of
them, so the whole 0.0058-fps-per-shape cost model has nothing to drive.

It was found by a check written to stop the in-game checklist going stale, which
compares every command the checklist names against the code that would run it.
The checklist said "type /set maxparts 105" because this file did.

So it is an open decision, not a setting: **should a per-plot block budget
exist?** The measurement says ~105 blocks each for 20 builders at 45 fps. It
would be a fourth row in `Rules.lua` beside the three that are there. Say the
word.

What IS real and has still never run: `maxjoints` (rule 10, ten bearings a
plot), `maxbots` and `maxlights`.

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
7. **`allow_add_mods` is `true`** (V74, reversed from V54). The mod list is
   still the trust boundary -- what changed is who decides. A guest cannot bring
   mods, so the only person who can enable one is you, at world creation.
   `dev/session_stats.py` lists every mod a session loaded.
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
  **181 checks.** A pass does not mean it works; a failure is always real.
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
