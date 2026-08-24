# How the anti-grief works, and why it cannot be prevention

The honest version, because the question "how can griefing happen if there's an
anti-grief system?" has a real answer and it shapes everything else in this mod.

---

## The one fact everything follows from

**The engine fires no callback when a block is placed or destroyed.**

`server_onInteractableCreated`, `server_onVoxelConstruction`,
`server_onVoxelDestruction`, `server_onCellCreated`, `server_onCollision`,
`server_onPlayerJoined` — that is the whole callback set, and a plain block is
not an interactable. Nothing fires when someone puts a block down. Nothing fires
when someone takes one away.

So there is **no moment to intervene in**. A mod cannot see the act, cannot
refuse it, cannot undo it on the spot. Every protection here is *state* set in
advance, plus a patrol that keeps re-asserting that state.

That is not a design choice. It is the only shape available.

---

## What the state can actually express

A body carries permission flags: `setBuildable`, `setErasable`, `setConnectable`,
`setPaintable`, `setLiftable`, `setUsable`, `setDestructable`,
`setConvertibleToDynamic`.

**They are per-BODY, not per-player.** There is no `setBuildableBy( player )`. A
body is erasable by everyone or by nobody.

That single limitation is why "only build on your own plot" cannot be written
down directly. What this mod does instead is **presence**:

- one plot = one body, so a plot can be locked without locking its neighbours
- a zone unlocks only while **every player standing in it** is authorised for it
- an unauthorised person standing on your plot locks it *and* is pushed back out
- a claimed plot with **nobody** on it is locked, so nobody can reach over it
  from the road

It is a good approximation. It is not the same thing as a per-player rule, and
the difference is where griefing lives.

---

## So where can griefing still happen?

Four places, and they are all consequences of the above rather than oversights.

**1. During build time, on ground you are allowed to touch.**
This is the big one and it is unfixable by design. An event needs plots to be
buildable and erasable while the event is running. Anyone authorised for a plot
— its owner, and their teammates — can wreck it during exactly the window the
event exists for. You can restrict *where*, never *whether*.

**2. The patrol is amortised.** 128 bodies per tick. A body that appears between
sweeps is unprotected until the patrol reaches it. On a small city that is a
fraction of a second; on a huge one it is longer. The alternative is vanilla's
`BuilderWorld`, which sets eight flags on every body every tick at 40 Hz, and
that cadence is what would actually kill a twenty-person event.

**3. Teams.** Teaming with somebody grants them your ground. That is the point of
teaming, and it is also a trust decision the mod cannot make for you.

**4. Anything the flags do not cover.** Explosives and fire are handled
separately (`destructable` pinned false, `sm.fire.setFireLimit(0)`, terrain
cratering declined). Consumable items like cornades are not tools, so
`forceTool` cannot reach them — they can make noise and knock people about but
cannot break a build or the ground.

---

## Which is what the grief alarm is for

**It is not prevention. It is detection, containment and reversal**, for the case
the flags cannot cover: legitimate access being used to do damage.

### How it works

The protection patrol already walks every body. Totalling `getShapeCount()` costs
**one extra call per body** and yields a whole-world shape count once per cycle:

```lua
self.cycleShapes = self.cycleShapes + body:getShapeCount()
...
if self.cursor > n then          -- a full cycle finished
    self.census = self.cycleShapes
    self.cycleShapes = 0
end
```

Every tick, `World.sv_checkGriefAlarm` compares the current census against the
**high-water mark of the last 20 seconds** (see the next section for why a window
and not the previous sample). If the count has fallen by `alarmdrop`
(default **400** blocks) it:

1. writes `GRIEF ALARM: N shapes lost` to the log,
2. announces `*** N blocks just disappeared ***` to everyone,
3. and if `alarmlock` is on -- **off by default** -- locks the whole world and
   tells the host how to roll back.

**The automatic lock is off by default, deliberately.** A false alarm that shouts
is a nuisance; a false alarm that freezes twenty people mid-build in front of a
stream is worse than the griefing it was guarding against, and the alarm cannot
tell somebody clearing their own work from somebody wrecking yours. It still
announces, still logs, and `/set alarmlock on` arms it for an unattended
server -- which is the case it was really written for.

Ghosts are excluded from the count — a blueprint preview appearing and vanishing
would otherwise swing the total by the size of a whole creation and trip it.

### Why it exists at all

The founding incident: **a griefer wrecked builds two minutes before the end of a
public stream event.** Nobody catches that by watching, because the person
running the event is running the event. The alarm does not need anyone watching,
and it stops the bleeding by itself.

Recovery is the other half, and it is the half that matters most now the lock is
off by default. Snapshots are taken at **every phase boundary** as well as on the
autosave timer:

| when | named |
|---|---|
| prep begins | `prepstart` -- before anybody has touched anything |
| build begins | `buildstart` -- the starting line |
| build ends | `buildend` -- the builds exactly as the clock stopped them |
| the event ends | `eventend` -- the final state, after the buffer |

Those are the moments you would actually want to roll back *to*, which a timer
alone cannot give you: an autosave lands wherever the clock happens to be. Each
is taken **before** the phase's protection change, so `buildend` records the
builds as they stood rather than the world after it was shut.

`/restore <name>` puts a whole world or a single plot back.

---

## The remove tool deletes at most 16x16 at a time

**The owner's fact, and it sets the threshold.** One action of the remove tool
takes at most **256** shapes. Everything about the alarm follows from that:

- A threshold **at or below 256** fires on a single ordinary delete. The old
  default was 250, so one legitimate sweep locked the world.
- A threshold **above 256, compared cycle to cycle**, never fires at all. The
  patrol does 128 bodies per tick at 40 Hz, so a 200-body city finishes a census
  every four hundredths of a second — somebody deleting 256 at a time, over and
  over, never shows a drop bigger than 256 in any single cycle.

So the alarm measures a **20-second window** against its **high-water mark**,
not the previous sample: a griefer who pauses between deletes does not get a
fresh baseline for free. Default **400** — one big sweep is quiet, two inside the
window are not.

## What the alarm cannot do — say this out loud

- **It fires after the fact.** Up to a full patrol cycle late. Blocks are already
  gone; the point is that they stop going and can be restored.
- **It does not say who.** It says how many. `/players` and the chat log are what
  you have.
- **It cannot tell griefing from housekeeping.** Somebody deleting their own
  large build looks identical. Hence the threshold, and hence the quiet windows
  around our own bulk work — purges, restores, snapshots and city rebuilds all
  suppress it, because an alarm that cries wolf is one nobody believes at the
  moment it matters.
- **It is a whole-world total.** Somebody removing less than the threshold per
  window, waiting it out, and doing it again is invisible. Slow, dull, possible.
- **A low `alarmdrop` costs false alarms**, a high one misses small damage. The
  presets set it: `build` 400, `show` 300, `lockdown` 260, `sandbox` off. None
  of them go at or below 256, because that is one ordinary delete.

---

## The honest summary

| | |
|---|---|
| **Prevented outright** | building or erasing on ground you are not authorised for; anything at all once the event ends or `/lockdown` is on; deleting streets, the plaza or the platform; fire; terrain cratering; banned tools |
| **Not prevented, by design** | damage done on your own plot, or a teammate's, while the event is running |
| **Detected and contained** | mass deletion anywhere — the alarm locks the world and calls it out |
| **Reversible** | everything, via snapshots and `/restore`, per plot or whole world |

## Which is why banning is the real enforcement

Build permission is per-BODY and cannot be aimed at a person, so **the only way
to stop someone specific is to remove them.** That makes `/ban` load-bearing
rather than a convenience. Its honest strength:

- **`sm.game.banPlayer` is the engine's own ban** and is what actually keeps
  somebody out. Every path that decides a person is banned reaches it now,
  including the one that fires when somebody banned while offline comes back.
- **Our own list is keyed on the DISPLAY NAME**, because Lua is handed no stable
  player id at all. The `Player` binding list has `id` — a session slot that
  shifts — and `name`, and nothing else. There is no Steam id to key on. So the
  list records aliases and catches renames it has *seen*; a brand new name is a
  brand new identity.
- **The allow list is therefore the stronger tool.** A ban names who must stay
  out and loses to a rename. An allow list names everyone who may come in, and a
  rename just produces another name that is not on it. For a public stream
  event, `/set allowlist on` is the setting that actually holds.

Griefing is possible because building is possible. The system is not a wall; it
is a fence with a burglar alarm and a rewind button, and each of those three
parts exists because the other two cannot do its job.

**None of the above has been exercised in a real event yet.** It compiles, the
rules are checked outside the game, and the flags are set from bindings verified
against the install — but the alarm has never actually fired in anger.
