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

Current version: **V78**. All 224 checks pass. `python dev/check_all.py --sync`
before playing, and **restart Scrap Mechanic** — scripts are read at world load.

---

## WHERE THIS LEFT OFF -- read this first

**The mod is finished enough to publish and has never been published.** That is
the single outstanding action and it is one nobody but the owner can do.

`description.json` has no `fileId`, which is how you can tell: it has never been
uploaded. Publishing happens inside the game and writes that id back into the
file. **Tell the next session once it is done** so the id gets committed --
otherwise the next `--sync` overwrites it.

Before uploading: **restart Scrap Mechanic.** `description.json`, `preview.jpg`
and every script are read at startup, so a running game is showing an older
build than the folder holds.

### What changed, V64 to V78

The detail is in [`CHANGELOG.md`](CHANGELOG.md); this is what a person needs to
know to use it.

- **`/developer on`** gates DEV TOOLS, TESTING CHECKLIST, `/crowd`, `/bench`,
  `/bridge` and `/check`. **Off by default**, so a fresh world hides them. Every
  dev tool keeps its OFF switch working whatever the mode -- `/crowd off` never
  refuses -- so the switch can never strand a crowd.
- **A guest may type exactly one command: `/menu`.** Everything else is
  host-only and reached by button. If a guest needs something that turns out not
  to be on the menu, that is the bug, not the refusal.
- **BANS** is its own menu entry. Banning is a list you click, never a name you
  type -- a Scrap Mechanic name can hold characters a host cannot type at all,
  so every button carries a perma id. The allow list works on an empty server,
  which is the only time it is any use.
- **HOW THIS WORKS** is the in-game tutorial: three sections you pick between,
  gated -- players get one, a host gets two, developer mode adds the third. It
  opens by itself three seconds after somebody joins **for the first time**.
- **`citybuild`** opens the roads, the plaza, the decking and the seams for
  building. Off by default. It does not survive a `/lockdown`.
- **The BUILD preset is complete now.** It was missing `destructible` -- the
  damage switch -- which was ON in the live settings, so explosives worked
  through build events.
- **Backups**: `python dev/backup_world.py --watch` copies the game's own save
  file every time you quit. Unconditional, and consistent even while the game is
  running because it goes through sqlite. **This is the backup that matters** --
  `/snapshot` saves buildings and plot ownership and nothing else.

### START HERE: what only the owner can do

**1. Publish it**, then say so. See above.

**2. Take four screenshots.** The Workshop gallery has one image and the four
newest features have none. `python dev/steam_images.py --list`, then `--add <n>`:

    HOW THIS WORKS   the tutorial, open on FOR PLAYERS
    BANS             the picker, with a few names on it
    MY PLOT          with a plot actually claimed
    a lockdown       the world frozen, PROTECTION panel open

The crowd shot is already pinned as 01 and is the one the owner asked to keep.

**3. Read the tutorial in game and look for hollow boxes.** The game builds a
glyph atlas per font from strings it has already drawn, so a character it has
never rendered comes out as an empty square. A check holds the tutorial inside
the characters other panels draw, but that check is a precaution and not a
measurement. Boxes are the thing to look for.

**4. Anything needing a second person.** Thirteen checklist items, and they are
the only ones nothing here can reach: a guest being refused, a guest with no
chat commands, the focus marker seen by somebody else, the per-client network
budget, and the tutorial opening for a genuinely new arrival.

### What the bridge already settled, so nobody re-tests it

Driven live on 2026-09-01, recorded in `Checklist.json` (32 of 97 answered,
**none failing**):

| | |
|---|---|
| **restore** | 676 shapes / 195 bodies before, `195 of 195` restored, identical after. **The last red line in the project, now green** |
| `/lockdown`, `/unlock` | all 195 bodies to `locked` and back |
| `citybuild` | `/unlock` returned `open_destructible 195` where it has always returned `locked 99, open_destructible 96` -- the deck is no longer scenery |
| the developer gate | `/crowd 5` refused with it off, `/crowd off` still worked |
| the allow list | added and removed somebody with nobody else online |
| the event clock | started, took its phase snapshot |
| `Multiplayer = 2` | is **Friends**, read out of the running world |

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
6. ~~**`/purge here <radius>`**~~ **SETTLED 2026-09-01: it stays.** "its needed
   just as a side thing of the delete tool. its fine." It is the typed half of
   the Cleaner -- both ignore every permission flag, which is what makes them
   the only things that can shift stuck litter, and the Cleaner needs something
   to point AT. `/purge` covers what it cannot reach: a whole plot, a radius, or
   whatever you are carrying.
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

## Settled, so nobody spends a day on it again

**"Public multiplayer is limited to about six players."** It is not, and there
is no number to raise. Four independent facts, in
[`../CLAUDE.md`](../CLAUDE.md): the game loads **no `SteamMatchMaking`
interface at all** (it is `SteamNetworkingSockets` peer-to-peer, so there is no
lobby and no member limit), `MaxPlayers`/`maxConnections`/`MemberLimit` are zero
hits, `SteamNetworkServer.cpp` has a complete set of connection-refusal strings
and **none of them is about being full**, and the whole `sm.game` binding list
has nothing about connections.

**What it actually is: the visibility setting.** From this owner's own logs --
one person refused seven times over fifty seconds, alone, and connected on the
first attempt after the host widened `Multiplayer`. Across all 340 logs: 50
connections, 10 refusals, 8 of them that one sequence. And narrowing the setting
mid-session **evicts** people who no longer qualify, one tick later, reported
only as "not authenticated".

Both are silent on both ends, which is why the mod now prints the mode on
`/protection` and on the BANS panel, warns when it changes with people in the
world, and why `dev/session_stats.py` reports the whole connection story for any
log.

What this does **not** settle: no session here has two people genuinely joining
at once, so the concurrency claim in the video is neither confirmed nor refuted.
It just is not the thing the evidence points at.

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
