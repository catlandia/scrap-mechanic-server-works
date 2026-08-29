# The automated half — testing the CITY RULES without a lobby

**Status: designed, not built.** Nothing in this file exists yet. It is written
so the decision to build it can be made on what it would actually cover.

Asked for as:

> in minecraft dev mode there is a check list. it spawns test panels. and makes
> them run. and it awaits a certain result. if something doesnt give the result
> it says that it failed. if it completes in the good state it says its good.
> that way the minecraft devs dont have to check thousends of features and
> combinations manualy for changing something small.

and then narrowed, which is the version this file is written to:

> **phase two needs to be adapted to be usefull to test the rules of the city if
> they work.**

That is the right target and it is a different one from the first draft. The
rules of the city are the thing that has to survive every change, they are what
goal 2 *is*, and they are the one part of this mod where **a check that passes
proves almost nothing** — because `dev/test_logic.py` has never touched a body,
and the rules are ultimately eight boolean flags on a body.

The companion is [`../mod/Scripts/Checklist.lua`](../mod/Scripts/Checklist.lua),
V57's manual list. The split is the design: the manual list covers what needs
eyes, hands or a second person; the harness covers what a script can do to a
body and read back off it.

---

## THE ONE RULE THIS HARNESS EXISTS TO ENFORCE

**Assert on the BODY, not on the profile.**

`dev/test_logic.py` already builds a real `Protection`, a real `Plots`, and the
actual resolver, and asks what a body standing on a real plot *would* be given.
That was V34's lesson — *check the resolver, not the table* — and it is as far as
Python can go.

One level further out is the part that has swallowed two shipped bugs:

    profileFor( zone )  ->  sv_applyProfile( body )  ->  body:setBuildable( ... )
    \___ proven in Python ___/ \______ nothing has ever tested this ______/

- **the ghost pinning.** The patrol set `convertibleToDynamic = false` on a
  creation the lift was still holding. The resolver was right; what it was
  applied to was wrong. No error, nothing in the log, three attempts to find.
- **the city floor liftable during an event.** `sv_pinCity` set the flags at
  import and the patrol reapplied the full profile over the top seconds later.
  The profile table was right the whole time.

Both are invisible to a resolver check and obvious to a harness that reads
`body:isBuildable()` back. **Every assertion in this design ends at a getter on
a real body**, and any test that ends at a table belongs in `test_logic.py`
instead, where it is free.

---

## Why this is reachable, and what the actor is

Three things had to be true, and all three already are — verified in the code,
not assumed.

| what it needs | what the mod already has |
|---|---|
| **make a body on demand** | `World.sv_importBlueprint( bp )` — `World.lua:2231`. Blueprint as a plain Lua table, returns the bodies |
| **make a body with a real JOINT** | `Crowd.sv_machineBlueprint` — `Crowd.lua:697`. Two bodies, one bearing, one interactable. Every `/crowd` run already does it |
| **put a person somewhere** | `/crowd`. Bots are handed to `Plots.sv_updateOccupancy` as real characters at real positions — `Plots.lua:293` |
| **run across ticks** | `Snapshots` and `Bench` are both tick-stepped job machines. A test waiting on a 5-second patrol is the same shape |

One block is `Plots.Blueprint{ Plots.Child( uuid, colour, x, y, z, 1, 1, 1 ) }`,
which is what the entire city is built from.

So no new engine capability is needed. It needs a runner, a place to run, and a
cleanup that never leaves rubbish behind.

---

## The four layers of a city rule, and how far a harness gets up them

This is the honest map. It was drawn by reading `Plots.sv_updateOccupancy`
rather than by reasoning about what bots probably do, and layer 4 is not what
the first draft of this file assumed.

### Layer 1 — where is this body? FULLY TESTABLE

`sv_bodyZone` takes the **centre of the AABB**, because `body.worldPosition` is
the body's origin and every piece of the city is imported at `vec3.zero()`.
Getting this wrong produced *"I cant place blocks on the concrete but I can
delete it. I can delete others plots"* — every plot located somewhere it was not
and treated as litter.

**Tests.** Import a block at a known plot centre; assert `kind == "plot"` and the
right index. At a road centre; assert `filler`. On the plaza; assert `plaza`.
One block inside the metal ring; assert it is still that plot. Then a body whose
*origin* is far from where it stands — the exact case the bug was — and assert
it still lands on the right plot.

### Layer 2 — who may build there? FULLY TESTABLE

`sv_authorised( zone )` returns the set of permas allowed on a zone, out of real
claims and real teams. Bots hold `crowdbot:` permas through the real
`Plots.sv_claim` and team up through two real `sv_request` calls, so a whole
neighbourhood of ownership can be built with nobody online.

**Tests.** Claim, assert the owner is in the set and a stranger is not. Team two
orthogonal neighbours; assert both are in both sets. Team across a road, and
across the plaza; assert refused. Leave; assert the team is cut for anyone who
was only reachable through the leaver. Unclaimed plot; assert the set is empty
and the plot is open.

### Layer 3 — what flags does the body actually get? FULLY TESTABLE, AND UNTESTED TODAY

This is the layer worth building the harness for.

**Tests**, each one: import a body, wait one full patrol (5 s), then read
`isBuildable`, `isErasable`, `isLiftable`, `isConvertibleToDynamic`,
`isPaintable`, `isUsable`, `isDestructable` back off it.

| situation | what the flags must say |
|---|---|
| unclaimed plot, build time | open: buildable, erasable |
| claimed plot, nobody there | **locked** — V46's change, and the one most likely to be wrong |
| road / filler | `sweep`: not buildable, erasable, so litter never becomes permanent |
| plaza | `sweep` as well, since that is where dropped craftbots land |
| deck at z 0.75 | scenery, pinned |
| a plot slab during **prep** | not liftable, not convertible — the ground pin |
| a plot slab during **build** | liftable and convertible: `GROUND_FREE` |
| under `/lockdown` | nothing buildable, nothing erasable... |
| ...except litter | a body on the road stays `sweep` even locked, and even with `buildopen = false`. Three separate rules each broke this on their own |
| buffer phase | `polish`: paintable and usable, not buildable, not erasable |

Every row is a rule that has been reported broken at least once, and not one of
them has ever been read back off a body.

### Layer 4 — does standing there change it? HALF TESTABLE, AND THE HALF MATTERS

**Bots can hold a plot OPEN. Bots can never lock one.** That is deliberate and
it is written into `Plots.lua:293-306`: bots are fed into the pass for presence
and for `sv_holdNearby`, but they are **not** put in `occupied`, because the
loop over `occupied` pushes unauthorised people out and `sv_pushOut` needs a
`Player` to move. A bot that could deny a zone would hold it shut forever with
nothing able to clear it.

So:

- **testable with `/crowd`:** an authorised occupant holds their team's ground
  open; `zoneHeld` stops an owner being locked out by standing on the seam at
  the edge of their own plot; standing on a plot marks it active and that is
  what makes the 1 Hz scoped audit look at it.
- **NOT testable without a second real player:** an *unauthorised* person
  standing on somebody else's plot closing it, and being pushed off. The host
  cannot stand in for them either — the host is authorised on every square of
  the map, on purpose.

That single rule — *you cannot build on somebody else's plot while they are
standing on it* — is therefore permanently a `needs = "guest"` item, and it is
already one in the V57 checklist (`plots-refuse-other`, `guest-plot`). **A
harness that quietly reported it green would be worse than not having one**,
which is the whole reason this section is written before any code.

---

## The other thing worth automating: the part limit

Rule 10 has never been enforced once, and every manual item for it needs
somebody to build twelve bearings by hand. It is the most tedious thing in the
checklist and the most mechanical, which is exactly the profile for automation.

**One test, four red lines.** Claim a plot for a bot perma, stand a bot on it so
the scoped audit has it in scope, import N machines onto it, then:

1. wait 1.5 s → assert the plot's bodies come back **not buildable**
2. assert they are still **erasable** — *"I cant remove the bearing that
   prevents from building"*, the `trim` profile, V53, unrun
3. assert a **neighbouring** plot is untouched — the over-budget check runs last
   and may only downgrade, or the limit becomes a griefing tool
4. destroy one machine, wait 1.5 s → assert it reopened. **1.5 s, not 6** —
   five seconds would mean the scoped pass came back empty and only the full
   pass caught it

And the one that cannot be done by hand at all: import **one** creation of two
bodies and assert `getCreationId()` returns the same value for both. If that
call fails, every multi-body creation counts its joints once per body and a plot
locks at roughly a quarter of the limit, silently. STATUS.md calls it the
highest-risk guess in the mod.

---

## Cheap extras, once the runner exists

Each is one call and one assertion, and each closes a documented guess:

- `body:isGhost()` returns `false` on an ordinary body — proves the binding
  exists at all. It is what stops the patrol pinning a creation on the lift.
- `shape:destroyShape()` removes a shape whose body has `destructable = false` —
  the entire basis of the cleaner and of `/purge`.
- **restore.** Import known blocks, count shapes, capture, destroy, restore,
  count again, compare. Capture is proven; restore is not, and
  `importFromString`'s last two arguments are a documented guess. It is the test
  a person is least likely to re-run, because it deletes the world.
- **the census does not lie while the world changes** — the grief alarm reads a
  shape total per patrol, and a miscount is a false lockdown mid-event.

---

## What it can NEVER do

A harness that quietly cannot test something is worse than none, because the
checklist beside it reads as green.

| out of reach | why |
|---|---|
| **an unauthorised person on your plot** | bots are excluded from `occupied` by design; the host is authorised everywhere. Layer 4, above |
| **a key press** | `F` reaches Lua only as a tool's `forceBuild` argument. No script can synthesise one |
| **a GUI click** | a widget callback is the engine's to fire |
| **a second client** | no dedicated server, no headless client. The eleven `needs = "guest"` items stay manual, permanently |
| **frame rate** | `/bench` measures it with the host's own client as the stopwatch; a server-side harness has no frame |
| **anything a person judges** | "the swatches are the right colours", "the marker is over their head" |

---

## The runner

### Shape of a test

```lua
{ id = "plots-empty-locked",          -- the SAME id as the manual checklist item
  needs = { city = true, plot = 1 },
  stages = {
    { do_ = function( t )
        t:claimFor( 1, "harness:owner" )
        t.body = t:spawnBlockOnPlot( 1 )
      end },
    { wait = 5.0 },                    -- one full patrol, not one tick
    { expect = function( t )
        if t.body:isBuildable() then
          return false, "an empty claimed plot is buildable -- V46's rule is not "
                     .. "reaching the body"
        end
        return true
      end },
  } }
```

`do_` acts, `wait` is seconds, `expect` returns `ok, why`. One test at a time.
Anything that throws is a FAIL with the error as its reason, never a crash.

**`wait` is in seconds and it is usually 5.** The patrol is amortised — 1 Hz
scoped, 5 s full — so a test that reads a flag one tick after placing a body is
testing nothing and will pass whatever the code does. That is the single easiest
way to build a harness that reports perfect health under any bug, and it is the
same mistake `/bench` made when it timed itself with the counter it was
measuring.

### Where it runs

A **test yard** clear of the city, derived from `Layout` so it can never overlap
a plot however the grid is configured — plus, for the ownership tests, real
plots claimed under `harness:` permas, the same trick `/crowd` uses for
`crowdbot:`. Swept on world create and when the run ends.

### Cleanup is the part that has to be right

Every body a test makes is tracked and destroyed in teardown **whether it passed
or failed**, then the yard is swept once at the end, then every `harness:` claim
is released. The precedent is a warning, not a theory: `/crowd` had to learn to
release its claims and destroy its blocks, and two unremovable lifts were left
standing in a test world by losing a handle.

### Safety

- **host only**, and it refuses to start while an event clock is running — the
  rule `/bench` already follows.
- **its own `pcall`**, separate from the protection patrol's. A harness must
  never be able to switch protection off, and a protection fault must never
  leave a half-built test standing. That separation is how `/crowd` and `/bench`
  are already wired.
- **it puts every setting back**, on failure too. A test that sets `maxjoints`
  and dies must not leave the server enforcing 3.
- **nothing runs unless asked.** No test on world create, ever.

### Where the results go

Into the same `Checklist.json` the manual panel writes, **under the same ids**,
marked `by = "auto"`. One file holds the whole ledger, the panel shows an
auto-PASS beside a hand-given one with its provenance visible, and
`dev/checklist_report.py` grows a column rather than a second reader.

**An auto result must never silently overwrite a human one that disagrees.** If
the harness passes something a person marked FAIL, that is the most interesting
event of the session and it should be reported as a conflict, not resolved.

---

## What it would cost

Roughly the size of `Crowd.lua` — 500 to 700 lines, plus checks driving the
runner against fake stages through `lupa` (the arithmetic is testable outside
the game; the engine calls are the whole point and are not).

The order that makes sense: **run the V57 manual list once first.** It covers
the same rules today, it takes one sitting, and what it turns red is the list of
things worth being able to re-run automatically after every change. Building the
harness first means guessing which rules break.
