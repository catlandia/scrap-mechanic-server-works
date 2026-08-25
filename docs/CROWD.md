# Testing for twenty players, with nobody to invite

> "we need to start testing the mod optimitsation for players. the issue is...
> we dont have real players. how can we have many players. without actual
> people? for testing stuff."

The honest answer is that you cannot have many *players*. What you can have is
most of what a player **costs the server**, and this document exists so that
nobody — including a later version of this project — mistakes one for the other.

Everything below was researched against the installed game and the 150 session
logs in `Logs/`, not from memory. Where a claim is measured it says so and says
where; where it is unmeasured it says that instead.

---

## What a player costs, and which parts `/crowd` can fake

| what a player brings | faked? | by what |
|---|---|---|
| a human capsule stepped by the physics every tick | **yes** | `Crowd.lua` — a real character, real mass, real collision hull |
| a character replicated to every client every tick | **yes** | same — a unit is a networked object |
| bodies appearing and disappearing while people build | **yes** | `/crowd churn on` |
| our own per-player Lua: occupancy, resolver, holds, budgets | **yes** | bots are handed to `Plots.sv_updateOccupancy` as real occupants |
| plot ownership, teams, authorisation | **yes** | `/crowd claim on` |
| **a real client connection with its own network budget** | **NO** | needs one guest |
| **a second machine's render load** | **NO** | not fakeable at all |

The last two rows are the whole reason this file is not just a paragraph in
`CLAUDE.md`.

---

## The measurement that matters, and why it needs exactly one guest

The engine gives away one number about multiplayer, and it is already in your
logs:

```
WARNING: NetworkServer.cpp:231 Skip sending unreliable network data
         to client 76561199070209586 Budget is currently: -280930
```

That is **the host giving up on sending a client its state updates for that
tick** because that client's send budget is exhausted. One line is one tick of
movement and state that a player never received.

**MEASURED**, across every `game-*.log` in this install:

- It only ever names a **remote** client. Not once does it name the host's own
  loopback id. A solo session cannot produce one, and **no number of `/crowd`
  bots will either** — a bot holds no client connection.
- The budget is **per client and independent**. So **one guest exercises it
  exactly as well as twenty would.** Twenty multiplies the *host's total upload*,
  which is arithmetic on top of a measured per-client rate — not a separate
  measurement that has to be made.
- A budget of exactly `0` in the first seconds of a session is the counter before
  it is initialised. It appears in almost every log and means nothing. Only
  negative values are data being dropped.

Worst seen here:

| log | clients | skips | worst deficit |
|---|---|---|---|
| `game-20260710-192923` | 3 | 371 | **-856,841** |
| `game-20260803-183557` | 1 remote | 67 | -486,900 |
| `game-20260227-190435` | 1 remote | 1,729 over 81 min | -186,023 |

`dev/session_stats.py` now reports this per client for any log, alongside tick
rate and frame rate.

### And it already points somewhere

`game-20260710-192923.log` is five players. Tick rate held at a median of
**39.8 Hz** against a healthy 40 — the simulation was fine, exactly as the
19-player session in `CLAUDE.md` was fine. And in the same session **three
separate clients were starved of state 371 times, one of them 856 KB over
budget.**

That is the first evidence in this project of something that degrades *before*
the tick rate does. It is consistent with what the 2026-08-22 event showed —
client frame rate sliding while player count stayed flat — and it says the
headroom to chase is bandwidth and rendered content, not simulation.

**Not yet established:** whether those skips were caused by content, by player
count, or by whatever was being built that evening. That needs a controlled
session, which is what `/crowd` plus one guest is for.

---

## Why bots and not fake player records

The per-player work in this mod is not a loop over a player list. It is a loop
over **where people are standing** — `sv_locate`, `sv_zoneKey`, `sv_holdNearby`,
`sv_authorised`, the push-out. Feeding that fabricated records at fabricated
positions would exercise the arithmetic and none of the geometry, and the
geometry is where every plot bug this project has had actually lived.

So `Crowd.sv_occupants` hands `Plots` **real characters at real positions** and
the pass does its true work. The only invented thing is the identity string.

Two deliberate limits on that:

- **Bots are never put in the `occupied` table.** That table drives `sv_pushOut`,
  which needs a `Player` to move. A bot cannot be pushed, so a bot standing on
  somebody else's plot would hold it shut forever with nothing able to clear it.
  Bots contribute presence and hold their own team's ground; they never deny
  anyone else's.
- **Bot claims are prefixed `crowdbot:`** and swept at world create, so a session
  that crashes mid-test cannot leave plots owned by a perma nobody can log in as.

**A bot only ever builds inside its own pad** — the plot rectangle inset by the
metal ring. A bot building on a road, on the ring, or on a neighbour would be the
host griefing the city with the host's own tool, so it is a *checked property*
rather than an intention: `dev/test_logic.py` builds a real grid, runs all four
build styles to their block cap, and asserts every block landed inside the pad.
Verified by mutation — it catches an off-by-one at the pad edge and a pad
computed without the border inset.

---

## What the bots are made of

A Custom Game may ship its own character database — the template does, at
`Data/ExampleMods/Templates/Survival Custom Game/Characters/Database/`. **No
Workshop mod in the 1205-item corpus ships one**, so there is no prior art beyond
the template and every failure mode here is one this project hits first.

- `mod/Characters/Database/charactersets.characterdb` → `serverworks.characterset`
- The bot is a **human**, not a totebot, on purpose: a totebot is a different
  capsule, mass, collision hull and renderable count, so measuring totebots would
  not tell you anything about measuring mechanics.
- Its `movement` block is the **player's** (`moveSpeed` 1.4575, `sprintSpeed` 4.0)
  out of `Data/Character/CharacterSets/default.json`, not vanilla's NPC
  mechanics, who sprint at 8.0 — twice a player.
- It is `class( nil )`, not `class( BaseUnit )`. Every vanilla human NPC unit is
  a `QuestActorUnit`, whose `server_onCreate` calls `QuestManager.Sv_RegisterQuestUnit`
  unconditionally — and **`QuestManager` is not loaded by `CreativeGame` or
  `CreativeBaseWorld`**, so inheriting one would have thrown on the first spawn.

### Names, clothes, skin

> "make the skin colours beards and others randomizable too. since this makes
> the best sense. for maximum customazability."

**Skin needs a correction: there is no skin channel to randomise.** A head
renderable carries its own skin — open `char_male_head02.rend` and the `skin`
submesh points at `char_male_head02_dif.tga`, its own texture and its own tone.
So **picking a head at random is picking a skin at random**, and there are
fifteen (7 male, 8 female) plus two more in the classic set. The only tint
binding on a character is `setColor`, which is what makes a totebot red; on a
human it tints the whole model and is not a skin channel.

Beards were already randomised — ten of them, male, at 55%. They never appeared
because the whole appearance system was failing; see the note below.

The real lever for variety is a second **art set**. `Data/Character/Char_Classic`
is the original mechanic: seven renderables that replace the whole body at once
(head, chest, hands, feet, legs, hair, backpack — no jacket, pants or shoes,
because the chest and legs already are those). It is also what
`Data/Character/CharacterSets/default.json` dresses the **player** in, so a
classic bot wears exactly what a real player's character is built from. About one
bot in four is classic.

That is the half that genuinely tests "handling of extra assets": a different
directory tree and a different texture convention, loaded alongside the modern
set.

### The wardrobe

> "if they have their own player models. please make every bot have like a name
> and a random clothing from all clothes aviable. like tf2 bots and stuff."

**It lives inside `BotCharacter.lua`, and it has to.** It began as its own
`Scripts/Wardrobe.lua`, loaded with `dofile( "$CONTENT_DATA/Scripts/Wardrobe.lua" )`,
and every bot threw `attempt to call field 'Name' (a nil value)` thirty times in
one session — reported as *"BOTS WORK! just without the skins stuff"*, which is
exactly right, because the unit half is server-side and never touched it. The
engine's own log showed the file being found and compiled; the `Wardrobe` global
was a table; the functions in the back half of it simply were not on it.

**Twelve vanilla character scripts call `dofile` and every one of them loads a
`$SURVIVAL_DATA` path — not one loads mod content.** A character script is not a
Game or World script. Anything one needs must be in its own file.

Two things fell out of that, both worth keeping:

- **`dev/sync_mod.py` now prunes.** The orphaned `Wardrobe.lua` stayed in the
  installed mod after being deleted from the repo, and the engine compiles every
  `.lua` it finds there. Same class as the stale `Cache/`. Pruning skips
  `Cache/`, `Snapshots/` and the root json the game writes.
- **A `pcall` around the wrong half proves nothing.** The appearance call *was*
  guarded and logged-once. The line that threw was one line above the guard.

The wardrobe is pure — no `sm.*` calls — so the whole thing is checked outside
the game. 98 renderable paths, enumerated off the install, and
`dev/check_uuids.py` resolves **every one of them against the install on every
build**. That check matters more here than anywhere else in the mod: a
renderable path that does not exist is not a Lua error, it is a character that
draws wrong, and nothing in the log says so.

Two engine facts it is built on:

- **`character:setNameTag( name )`** — one caller in the whole game
  (`MechanicCharacter.lua:138`), guarded by `if sm.exists( player )`. That guard
  reads as "name tags are a player feature". It is not; the guard is there
  because `MechanicCharacter` is the *player's* class and wants the player's own
  name. The call is on the character.
- **`character:overrideRenderableList( list )`** — refused for a *player*
  character, and the engine says so in as many words in its string table
  ("Tried to override the renderable list of a player character. This is not
  allowed."). A bot is a unit, so it is allowed.

**A hat does not carry a head, but it does carry hair.**
`GenericBuilderQuestCharacter` swaps its hat *out* for head+hair+facialhair as a
quest progresses, which reads as "a hat replaces the head". It does not —
`char_male_outfit_farmer_hat.rend` declares exactly two submeshes, `Hat_mat` and
`Hathair_mat`, with no skin, eyes or mouth. The head is always needed; the
**hair** is the thing inside the hat, so hat excludes hair. That is the one
combination rule in the file, and `dev/test_logic.py` enforces both halves of it.

**The seed is the character id, so nothing is sent.** A bot's whole appearance is
a pure function of `character.id`, which is already identical on the server and
every client. Twenty bots cost twenty integers of appearance traffic — which is
to say none. That matters for what this thing is *for*: a costume system that
showed up in the network budget would be measuring itself.

**The generator is a local LCG, never `math.random`.** `Layout` and the plot
shuffler both draw from the global sequence. If dressing a bot advanced it, the
city you got would depend on how many bots had been spawned first — a silent bug,
because both cities would look perfectly plausible. `dev/test_logic.py` asserts
the global sequence is untouched.

---

## Using it

```
/crowd                    what the crowd is doing right now
/crowd 20                 twenty bots, one per plot, spread across the city
/crowd off                take them all away
/crowd mode build         stack blocks on their own plot and LEAVE them
/crowd mode churn         place one, take it away — the world never grows
/crowd mode off           just stand there
/crowd claim on|off       have them claim the plot they stand on
```

### The two work modes answer two different questions

**`build`** was the owner's idea and is the better test:

> "we take the city. and the bots. the bots stand on their plots. and build up
> with various blocks. this will make them build."

Each bot stacks single blocks on its own plot — on top of whatever is already
there, out of all 25 materials and all 40 paint-tool colours — and leaves them
standing.

**Every bot builds a different kind of thing.** Twenty bots all picking a
uniformly random cell build the same shape twenty times: one even lumpy blob the
size of a plot, tested repeatedly. So each bot gets a build style for its
lifetime, and `/crowd` reports the mix:

| style | what it makes | why it differs |
|---|---|---|
| `scatter` | uneven mess over the whole pad | the default; touches every cell |
| `tower` | a column in the middle quarter | tall and thin, few cells, goes up |
| `wall` | one line, on a fixed axis | a flat plane, half the footprint |
| `platform` | fills a floor before starting the next | wide, low, touches everything |

Height, material and colour stay random underneath the style, so no two bots of
the same style build the same thing either. A tower and a platform at the same
block count load cell streaming and frustum culling quite differently, which is
the point. It is better because **accumulated content is what actually
degraded in the one real event on record**: client frame rate slid for a hundred
minutes while the player count sat flat at 19. Churn can never reproduce that, by
construction, because it puts back exactly what it takes away.

**`churn`** is steady state: place one, remove it, repeat. The world never grows,
so every stage of a `/bench` run is measured against the same amount of world.
Use it for a clean "what does one more builder cost".

The cost of build mode is that a `/bench` row confounds two variables — stage 4
has more bots *and* more world than stage 3. That is exactly what an event looks
like, and exactly what you cannot attribute. Run both.

**What a bot builds is not welded, and that matters.** Blocks weld only when the
engine's own build tool places them; Lua cannot reach that (the Body binding list
has no `createPart` and no `createBlock`), and `importFromString` always makes a
fresh creation. So:

| | bodies | shapes | cheap at | expensive at |
|---|---|---|---|---|
| a player's welded tower | 1 | N | the patrol | **rebuilds** — change one block and the whole body is reprocessed |
| a bot's stack | N | N | rebuilds — there are none | **the patrol**, which walks every body every cycle |

Neither is wrong; they are different halves of the same problem, and the bot's
half is the one this mod's own code pays for. Read a build-mode run as "what the
patrol and the renderer do against this much content", not as "what twenty
players building would do".

Build the city first — `/crowd` refuses if there are no plots, because a bot
spawned over open terrain falls, and a crowd of falling bots is a rigid-body
test rather than a building-event one.

Every size change is written to the log as
`[ServerWorks] crowd set to N (...)`, which is what dates a measurement:
`dev/session_stats.py` reports per minute, and the minute the crowd changed is
the one to read against it.

---

## `/bench` — the same thing, run for you

Doing the steps by hand means watching a clock and writing numbers down.
`/bench` does it: it walks the crowd up — 0, 5, 10, 15, … — holds each size still
for a measured window, and records frame rate, tick rate and world size at every
step.

```
/bench start [step] [secs]    default +5 bots every 36s, up to 128
/bench stop                   abandon it and clear the crowd
/bench results                the table from the last run
/bench                        what it is doing right now
```

Results go three places: chat, the game log (`[ServerWorks] bench row: …`), and
`$CONTENT_DATA/Bench.json`. Read the file with `python dev/bench_report.py`,
which also takes `--csv`.

```
  bots     fps     min   tick/s    shapes   bodies   vs empty
     0    62.0    55.0     39.9     12000     200     100%  ####################
    10    46.0    36.0     39.7     12400     220      74%  ##############
    20    30.0    17.0     39.5     12800     240      48%  #########

  tick rate: never fell below 36 Hz
  frame rate: halved at 20 bots
```

**Read `fps` and `tick/s` as a pair.** The finding this project keeps running
into is that they do not fail together. If tick rate is flat all the way down
while frame rate halves, that is the *expected* shape on the evidence so far —
not a broken run.

`/bench` refuses to start while an event clock is running: the phases change
protection mode mid-run, which moves the thing being measured.

### There is no clock in this engine's Lua, so the client is the stopwatch

This is the part of `/bench` most likely to be got wrong by a later change, so
it is written down.

`os` does not exist in the sandbox. `sm.game.getCurrentTick()` is the
*simulation counter* — which is the very thing a benchmark measures, and a
counter cannot be its own reference. Time a stage in ticks, divide ticks by
ticks, and the answer is 40 Hz however badly the server is doing: **a benchmark
that reports perfect health under any load.**

The one real-time quantity Lua can see is the `dt` handed to `client_onUpdate`.
It is wall-clock seconds, proven by what vanilla does with it —
`timeOfDay + dt / DAYCYCLE_TIME` (`CreativeGame.lua:208`), which would drift
against the sun otherwise. So the **host's client is the metronome**: once a
second it reports frames drawn, real seconds elapsed, and ticks elapsed *over
that same interval*.

All three are **deltas**, and that detail cost a bug. An earlier version sent the
absolute tick and differenced the ends of the window: N samples span N seconds
but only N−1 gaps between timestamps, so a clean 40 Hz server reported **36**.
Nothing about 36 looks wrong. `dev/test_logic.py` caught it and now guards it,
along with the settle-window discard and the wild-sample clamp.

The host specifically, because on the host the client and server are one process
and one tick counter. A **guest's** tick counter is its own simulation loop, not
the server's — so guests are sampled for **frame rate only**, which is the number
that actually degraded in the one real event on record. That is also why
`Game.sv_n_benchSample` is guest-reachable: what `/bench` most wants to know is
what the frame rate is on *other people's machines*, and only their machine can
say. Nothing in the payload is authority — the sender comes from the engine's own
argument, so a guest cannot claim to be the host and drive the run.

### A session that would actually settle something

1. Build the largest city you mean to run.
2. `/bench start` — leave it alone, stand still, do not open a menu. You are the
   probe.
3. `python dev/bench_report.py` when it finishes.
4. `/crowd churn on`, `/bench start` again — the same walk, but with bodies being
   created and destroyed throughout.
5. **Then invite one guest** and run it once more with them connected. That run,
   and only that run, produces the network-budget numbers —
   `python dev/session_stats.py`.

---

## Things ruled out along the way

Worth recording so nobody spends a day on them twice.

- **`-dedicated_server` exists as a command-line flag.** The executable's
  `Main.cpp` parses: `-open <path>` `-builtin_mods_only` `-dedicated_server`
  `-console` `-dev` `-window` `-disable_debug_device` `-disable_mem_back_trace`
  `-fps` `--ugc` `-last_save` `-tileeditor` `-no_popcnt` `-no_profiler`
  `-max_threads` `-use_null_driver` `-select_custom_gpu` `-enable_flip_discard`.
  There is also `-connect_steam_id <id>`.
  **Untested.** `-dedicated_server` is a bare flag with no supporting strings
  anywhere in the binary — no `DedicatedServer.cpp`, only `ListenServer.cpp` and
  `NetworkServer.cpp` — so it is plausibly a dead dev stub. `-use_null_driver` is
  the interesting partner: a client with no renderer would be cheap to run
  several of. Both are a two-minute test that has not been run.
- **`setParallelLimit` is not a threading knob.** It sits in `wrap_Interactable.cpp`
  beside `setInteractableCondition` and `getInteractableConditionTicks` — it is
  pipe/logic. Dead end.
- **`wrap_Profiler.cpp` exists but exposes zero bindings.** The string run after
  its marker belongs to `wrap_Storage.cpp`. `CLAUDE.md`'s "there is no Lua
  profiler binding" is correct.
- **`sm.character.createCharacter` exists** and takes a *player* as its first
  argument (`CreativeBaseWorld.lua:58`). Not a route to a free-standing puppet.
- **`unit_mechanic` is the null uuid** `00000000-0000-0000-0000-000000000000`,
  which is `default.json`'s character — the player. Vanilla only ever uses it as
  a *type test* (`character:getCharacterType() == unit_mechanic`), never passes it
  to `createUnit`.

---

## Still not covered, and no plan covers it

**Twenty clients' worth of rendering.** Twenty people each drawing twenty plots
is draw calls on twenty machines, and no binding in the game touches the
renderer. The only mitigations remain the ones already in the design: spatial
separation, part budgets, and freezing what is finished.
