# The mod list is the trust boundary, not the code

Written after auditing **T mod** (Workshop `3438987478`), a Blocks-and-Parts mod
that ships a deliberate host-takeover backdoor. The audit is the worked example;
the conclusions are general, and two of them cost a code change.

---

## The one fact everything follows from

**There is no sandbox between mods.**

A Blocks-and-Parts mod enabled in a world executes server-side Lua on the host's
machine with the same `sm.*` reach the Game script has, minus the handful of
bindings that exist only in a Game script (`kickPlayer`, `banPlayer`,
`bindChatCommand`, `setEnableRestrictions`, `pauseSaving` -- see CLAUDE.md).

It shares the engine's own `sm` table. T mod writes its whole state onto it as
`sm[insertionId]`, and stashes `sm.physics.raycast`, `sm.physics.multicast` and
`sm.localPlayer.getRaycast` in an `oldSmPhysicsRaycast` field so it can replace
them. `Scripts/hook.lua` is one line of comment: *"idk what im gona use this for
but its cool i can override things"*.

So no amount of correctness in `Game.lua` defends against a mod loaded beside it.
**What defends is not loading it.**

---

## What a co-loaded mod can and cannot reach

MEASURED, from `dev/dump_api.py` over this build's executable. The full module
list is Audio, Camera, Game, Garage, Gui, Render, Tool, Widget, Shape, Lift,
Player, Unit, Uuid, VoxelTerrain, World, Joint, Interactable, Color, Physics,
Body, Network, Projectile, Melee, Creation, Cell, Container, Ai, AreaTrigger,
Event, Message, Item, Portal, ScriptableObject, BuilderGuide, JsonGui, Debris,
Fire, PipeGraph, DebugDraw, AiState, Pathfinder, Quat, Noise, Log, Terrain\*.

| | reachable? |
|---|---|
| the internet | **No.** There is no HTTP, socket, URL, request or download module. `Network` is the in-game RPC layer, nothing else |
| your disk, generally | **No.** No `os`, no `io`, no process module. File access is `sm.json` only |
| `$CONTENT_<uuid>/` directories | **Yes, including other mods'.** T mod reads `$CONTENT_1e37f9b9-.../codes.json`, which belongs to a different mod |
| absolute paths, `..`, `$USER_DATA` | **No.** MEASURED by `/bptest` -- every form refused as *"not located in a valid directory"* |
| everything in the world | **Yes.** Bodies, shapes, players, terrain, units, explosions |

So the realistic worst case is confined to the game -- but *within* the game it is
total, and it includes reading this mod's own `Settings.json`, `Plots.json`,
`BanList.json` and `Snapshots/` if both mods are loaded.

---

## The worked example: how T mod's backdoor is built

Four hops, and the author documents it himself at `Scripts/BASE.lua:487`:

> `-- when I get an op forcefully, I do it by sending factorisation of a number`
> `-- in mods files, mod checks whether its correct and if it is gives me op,`
> `-- only I have the factorisation so don't try looking for it here`

1. **`BASE.lua:107`** -- on join, the client checks for
   `$CONTENT_1e37f9b9-.../codes.json`, a *separate* mod only the author has, and
   sends `opCheck{ primeOne, primeTwo, ownId }`.
2. **`BASE.lua:551`** -- the server multiplies the two 1024-bit binary strings and
   compares against a hardcoded ~2048-bit semiprime. Match, and the id is
   appended to `devsIds`.
3. **`powerAlternatived.lua:477`** -- anyone in `devsIds` silently auto-claims
   `operators` on first `/tmod` use.
4. **`operators`** gates ~90 commands: `ban` `kick` `kill` `delete` `clear`
   `tpto` `tptomeall` `setgravity` `op` (line 970 -- **can deop the host**), and
   `enablescriptinginconsole`, which switches on a bundled Lua-in-Lua interpreter
   (`Scripts/lua-in-lua-main/`) -- arbitrary Lua on the host.

The mod ships the alarm for its own backdoor. `powerAlternatived.lua:492`, shown
to a host who has lost operator:

> *"You are not an operator, someone in your world is taking over, if no TMod
> developers have joined, leave the game NOW"*

**The crypto is sound.** Forging it means factoring a 2048-bit semiprime, so this
is not a hole a griefer walks through -- it is a key one person holds. Two weaker
things in the same file are worth more as lessons than the backdoor is:

- `BASE.lua:294` -- a **name-based** whitelist (`getName()=="#d4af37T"`, `"openxe"`,
  and two others). Steam names are user-settable, so that one is spoofable. It
  hands out the tool, not operator.
- `opCheck` ops **`data[3]`** -- a player id the *client* supplies -- rather than
  the engine-supplied sender. Whoever holds the key can op anybody, not just
  themselves. **This is the anti-pattern `dev/test_logic.py` now forbids here.**
- `hostPlayerId = ((sm.player.getAllPlayers())[1]):getId()` -- host by array slot,
  the exact bug CLAUDE.md already warns about from another Workshop mod. The real
  binding is `sm.player.getHostPlayer()`.

---

## It does not have to be malicious to end an event

MEASURED, 2026-08-25, in a **Server Works world** with T mod enabled --
`Logs/game-20260825-143811.log`, two players:

| | with T mod (27 min) | clean Server Works, same day |
|---|---|---|
| log size | **95.6 MB** | 126 KB |
| tick/s min | **4.6** (healthy = 40) | -- |
| frame/s min | **4.4** | -- |
| windows under 90% of target | 2/25 | 0 |

**760x the log volume.** Attribution is exact: 6,341 of the 6,342 `__mul` errors
carry `$CONTENT_e653ddc4`, T mod's content id; one is vanilla's WeatherManager.
Two separate faults --

- **14:49:13** -- `console.layout` opens asking for font `InventoryItemTitle`,
  which does not exist, so MyGUI writes an error **per render**. Tick that
  minute: 4.6 Hz. The same font-tier-3 bug this project documented in its own code.
- **14:59-15:04** -- `power.lua:1856`, `sv_force_field_tick` produces a non-finite
  number: 6,341 tracebacks, ~70,800 lines of a player-state table dumped every
  tick, 912 `!isnan` physics asserts. Frame rate 58 to ~45, and it stayed there.

Set against this project's own ledger: 19 players for 100 minutes gave **0/86**
windows below target, and a 384-plot city build cost **0.2 Hz**. One player plus
one co-loaded mod gave **4.6 Hz**.

*Caveat, stated because this project's rules require it: one session, not a
controlled A/B. The file attribution of the errors is exact; the causal link to
the tick numbers is strong but uncontrolled.*

---

## What CANNOT happen, and the evidence for it

Both were checked before deciding the fix, because they bound the whole problem.

**1. A guest cannot bring their own mods.** MEASURED,
`Logs/game-20260822-181349.log` -- joined someone's City Building MMO world while
subscribed to **101** Blocks-and-Parts mods. Mods the world loaded: **one**, the
host's Custom Game. Zero of the guest's own. The host's world dictates the list,
which is *why* the join-time auto-subscribe exists at all: the client is being
forced to match the host, not the reverse.

**2. Installed is not loaded.** MEASURED, same machine, same day, T mod
subscribed and on disk in both sessions:

| session | T mod enabled | lines referencing `$CONTENT_e653ddc4` |
|---|---|---|
| 14:38 | yes | **12,766** |
| 20:41 | no | **0** |

An unticked mod is inert content. Not one line executes.

**So the only door into a Server Works event is the host ticking the box at world
creation.** That is the entire threat model, and it makes the fix a config change
rather than a system.

---

## The propagation shape, since it is not obvious

Joining a modded world **subscribes you permanently** -- the Steam record in
`appworkshop_387990.acf` carries `"subscribedby"`, not a temporary cache. So:

    join a modded world  ->  permanently subscribed
      ->  months later, "enable all mods" when making your own world
        ->  now you are hosting it
          ->  your guests are permanently subscribed
            ->  repeat

Every hop needs a human clicking *enable all mods*, so this is not self-replicating
-- it propagates by UX default and carelessness. But the author's key works on
every world in the chain, and an event host is the highest-fanout node in it.

---

## What was done

> ## REVERSED, V74: `allow_add_mods` is TRUE again
>
> Asked for plainly: *"you know what. lets allow to install block mods."*
>
> **Nothing below is withdrawn.** Every measurement in this document still
> holds: there is no sandbox between mods, a Blocks-and-Parts mod enabled
> beside this one runs server-side Lua on the host with nearly our own reach,
> and T mod's host-takeover backdoor is a real worked example. The facts did
> not change. The decision did.
>
> **What makes it defensible is the one measurement that decides who is
> exposed: a guest cannot bring their own mods.** MEASURED, on a real join --
> 101 subscribed, 1 loaded. The only person who can enable a mod is the HOST,
> at world creation. So `allow_add_mods` is not a hole a lobby can walk
> through; it is a decision the owner makes about their own machine, and this
> mod was making it for them.
>
> **The cost is real and this owner has already paid it once.** T mod appears
> in this machine's own logs, in a session with **155 mods loaded**, and the
> 95 MB / 4.6 Hz incident recorded below happened in a Server Works world by
> accident with nobody attacking anything.
>
> **What changed to make it survivable:** `dev/session_stats.py` now lists
> every mod a session loaded, with its Workshop id, and says plainly when
> anything besides the custom game was running. "My own risk" is only true if
> you can see what you took.
>
> An event that wants custom building parts needs this box. Turning it off
> protected the host from themselves at the price of the feature, and that
> was the wrong trade to make on somebody else's behalf.

1. **~~`allow_add_mods: false`~~** in `mod/description.json`. This was the whole
   defense: with it off, the tick box is not there to click, and no script of
   ours has to be correct for that to hold. Cost: players get no extra building
   parts beyond base content. **Reverting is one word.**

2. **Two host gates that were missing.** Both the same class -- a modified client
   opening a host UI on its own screen. Neither could *change* anything, because
   every action handler behind them tests the sender; what leaked was reading.
   - `Game.sv_n_openPanel` -- city, event and settings panels
   - `NotLift.sv_n_swOpenImport` -- the blueprint browser

3. **Two checks in `dev/test_logic.py`**, so this cannot regress:
   - *access: every server handler checks the sender* -- walks every `sv_n_*` in
     the mod and demands it tests `getHostPlayer()` or is named in
     `GUEST_REACHABLE` with a reason. **It caught `sv_n_swOpenImport` on its
     first run**, which a hand audit had already missed once.
   - *access: no handler trusts an identity from its payload* -- named directly
     after T mod's `opCheck`.

---

## The rule

**The client half of this mod runs from the player's own disk.** Every
`sendToServer` in it is therefore a message a modified client can send at will,
with any payload, at any time, whether or not the button that normally sends it
was ever drawn.

So a server handler may never treat *"the panel only shows this to the host"* as
a check. The panel is not what sent the message. The engine hands the real sender
in as the third argument, and that is the only trustworthy answer to *who asked*.

The audit found this already true nearly everywhere. `/plot claim` derives both
identity and target from the sender and their **actual world position**, never
from the payload, so a modified client cannot claim plot 47 by sending `47` -- it
has to stand there. That is the pattern. The two gates above were the exceptions,
and the checks now keep them exceptions.
