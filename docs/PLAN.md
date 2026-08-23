# Server Works — the plan of record

Written 2026-08-23, after the first day of real testing. This is the durable
account of what the project is, why each decision was made, what is built, what
is proven, and what is next. Where this disagrees with memory, this wins.

Companions: [`../CLAUDE.md`](../CLAUDE.md) for engine facts with citations,
[`../REVIEW.md`](../REVIEW.md) for verified-versus-assumed,
[`CHANGELOG.md`](CHANGELOG.md) for what each version fixed.

---

## 1. What this is

A Scrap Mechanic **Custom Game** for hosting large multiplayer building events —
the kind a streamer runs with a lobby of people building at once.

It exists because a griefer wrecked builds **two minutes before the end** of a
public stream event on 2026-08-22. That timing is the whole design brief: no
amount of host vigilance catches the last two minutes, so protection has to work
without anyone watching, and damage has to be reversible.

Creative first. A Survival branch is explicitly out of scope.

### The owner's goals, in the owner's order

1. **Many people building at once without the server dying.**
2. **Host tooling against griefing** — freeze finished builds, restrict building
   to a player's own plot.
3. **The event, not just the building.** Scope still open.

---

## 2. The measurement that reordered everything

Goal 1 was assumed to be about player count. It is not, and the owner's own logs
said so before a line of mod code existed. `dev/session_stats.py` reconstructs
server tick rate and client frame rate from any Scrap Mechanic log, because every
log line is stamped `HH:MM:SS (tick/frame)`.

| session | players | tick/s | frame/s |
|---|---|---|---|
| 2026-08-22, 100 min | 19 | median 39.9, min 36.7, **0/86 windows below 90% of 40 Hz** | 60 → 31 |
| 2026-08-08 | 1 | **collapsed to 11.6** | — |

**Nineteen players never dented the simulation. One player did.**

- Player count degraded nothing measurable.
- Client frame rate degraded with **time, not player count** — a render problem
  from accumulated content.
- The single-player collapse was self-inflicted: a 1.79 GB log, 1.45 M lines of a
  `print()` in a tick loop plus 58 K `g_unitManager` nil errors with full
  tracebacks. **Log spam is a performance bug**, and the largest one measured.

### What follows from that

- Freezing builds buys *simulation* headroom, and simulation was not the
  bottleneck. **Freezing does not fix frame rate — a static body still renders.**
  Keep it for anti-grief, do not credit it with the wrong win.
- The next performance work is about what is **rendered**: part budgets, plot
  spacing, fewer visible shapes.
- `PhysicsQuality` is a real engine setting readable via
  `sm.game.getSettingValue`. No setter exists, but the **host runs the physics for
  everyone**, so the host's value governs the server. `/protection` prints it.
  **Unmeasured** — the way to settle it is a value, a change, and
  `session_stats.py` over both sessions.

---

## 3. The three engine constraints that shaped the design

Everything non-obvious in this codebase comes from one of these.

1. **Build permissions belong to the BODY, not the player.** There is no
   `setBuildableBy( player )`. "Only build on your own plot" cannot be expressed
   directly — hence presence-based enforcement.
2. **Nothing fires when a block is placed or destroyed.** State can only be held
   by re-asserting it; destruction can only be noticed by counting shapes.
3. **A Game script has no world.** `sm.body.*`, `sm.fire.*` and friends are
   world-dependent and throw from `Game.lua`. This caused three separate bugs
   before it was understood.

### Two more learned the hard way

4. **Survival content wins any uuid it shares with creative.** With
   `baseGameContent: "Survival"`, uuid `8f190ce2` is `SurvivalLift`, which has no
   blueprint handling at all — the lift silently could not spawn creations. Our
   own toolset can take a uuid back. Same class of bug as `Sledgehammer` reading
   `clientPublicData.perks`.
5. **A creative inventory is infinite.** `enableLimitedInventory = false`, so
   removing an item from it is meaningless — it refills instantly and reports
   success forever. Banned tools must be disabled as *tools*, not confiscated as
   items.

---

## 4. Architecture

    Game.lua        chat, identity, settings, players, all GUIs.
                    NEVER touches a body.
    World.lua       everything that touches a body: protection, plots, rules,
                    snapshots, the city builder. Reached by sm.event.sendToWorld.
    Protection.lua  the permission engine
    Plots.lua       grid geometry, ownership, presence enforcement
    Identity.lua    perma ids, aliases, ban list, allow list
    Snapshots.lua   world and per-plot capture and rollback
    Rules.lua       per-plot budgets and banned parts
    Settings.lua    one schema table; adding a setting is one row
    GuardedTools.lua subclasses of real tool scripts with the trigger held shut
    SettingsGui / PlotsGui / MenuGui

Game and World share one Lua global environment (this is how vanilla's
`g_unitManager` crosses the same boundary). Client and server do **not** — that
needs the network.

### Protection, in detail

Five profiles: `open`, `open_destructible`, `locked`, `display`, `sweep`.

One immediate full sweep when the mode changes — that is what makes `/lockdown` a
real panic button — then an amortised patrol of 128 bodies/tick. A **sentinel** of
four getters skips bodies already correct. It must be four: `buildable` and
`destructable` alone cannot tell `locked`, `display` and `sweep` apart, and when
it was two, switching between them silently did nothing.

`sweep` is the subtle one: **anywhere you cannot build, anyone can clean.**
Walkways and open ground are unbuildable, so anything there is litter and must
stay erasable — otherwise protecting the world protects the griefer's mess too.

### Plots, in detail

The grid is an explicit run of segments with positions from a prefix sum, not
`col * stride`, because roads and fillers have different widths.

- **plot** — claimable, one per player
- **filler** — the one-block seam between neighbours, shared once they team up
- **road** — a real street, wider, never claimable, belongs to everyone
- **plaza** — the centre, spawn point, the only pillar

Enforcement is by **presence**: a zone's bodies unlock only while everyone
standing in it is authorised. Intruders are pushed back out — without that,
standing on someone's plot would keep it locked and become a griefing tool.

Plot slabs are deliberately **not** hard-protected: a build welds to its slab, so
the plot and everything on it is one creation that can be exported whole. The
cost is that an owner can erase their own floor; `/plotbuild` puts it back.

---

## 5. Built

**35 settings**, all host-only, all in one schema:
`fire terraindamage aggro sledgehammer spudguns glowsticks claygun firelauncher
extinguisher cornades painttool connecttool weldtool lift hostlift plots
pushintruders allowlist maxjoints maxbots maxlights minbuildheight buildopen
beacons fireworks plasmadrills radios horns destructible cleanupdebris autoremove
protection alarmdrop alarmlock autosave`

**34 commands.** `/menu` is the front door.

**Four presets**: `build`, `show`, `lockdown`, `sandbox`.

**The twelve rules from the stream board**, as enforced numbers. Rule 10 — max
combined bearings/pistons/suspensions per plot — independently arrived at the
right performance metric: joints, not blocks.

### Proven in game

- `/lockdown` works. The anti-grief core is real.
- The clay gun cannot fire.
- The city builds, and looks right.
- `sm.json` persistence works.
- Explosives and fire genuinely off.
- Content updates reach the game (the nugdupS test settled the stale-mod theory).

---

## 6. Not done, in priority order

1. **The lift may still not spawn creations.** V19 gave the uuid back to creative's
   `Lift`; unconfirmed since.
2. **UI for the rest** — `/players`, `/rules`, `/banlist`, `/known` still print to
   chat. Each wants a panel.
3. **Steam-ID ban resolution.** Lua cannot see a Steam ID; the game log records
   `Loaded player <id> (for user <steamid>)`. A companion tool reading that would
   make bans rename-proof. The allow list is the current answer.
4. **Frame-rate work** — the thing the measurement actually pointed at. Part
   budgets and spacing aimed at what is rendered.
5. **Hold-F-to-delete.** `ClayRifle.client_onEquippedUpdate`'s fourth argument is
   `forceBuildActive` — **F is readable inside a tool script**, nowhere else. A
   custom tool could do it.
6. **Sound spam and player collision.** Player-vs-player collision is not
   disableable: confirmed three ways (the full `wrap_Character` binding list, every
   collision identifier in the executable, the 14 dev console commands).
7. **Removing items from the creative menu** needs our own `Objects` database — a
   content change, not a script change.
8. **Host exemptions**, parked at the owner's request while bans are being tested.

---

## 7. Working agreements that earned their place

- **Read the log first.** Every hard bug this project has had was named outright
  by `Logs/game-*.log`. Guessing before reading cost whole test cycles.
- **A `pcall` that swallows an error silently is a bug.** Settings appeared to do
  nothing for two rounds because a world-dependent apply hook threw inside one.
  Guard, but always log once.
- **Verify geometry in Python before the game sees it.** Every city layout has
  been checked for overlapping cells and full coverage first; it has caught real
  collisions twice.
- **Check layout arithmetic before rendering a panel.** It has caught widgets
  running past the footer three times.
- **Never log per body or per tick.** The 1.79 GB log is the reason.
- `server_on*` overrides always call their parent.
- Comments explain *why* — an engine quirk, a workaround, a thing that looks
  wrong and isn't.
