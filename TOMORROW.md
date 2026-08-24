# Next session

V38 is installed. **Restart Scrap Mechanic** -- scripts are read at world load.

Nothing below has ever been run in game. It is ordered so that if you only have
ten minutes, the first two are the ones worth having.

## 1. Can you build on your plot? (the one still-unexplained bug)

Start an event, get to BUILD, try to place a block on your own plot.

Every path I can trace says the slab should be buildable, and no error appears in
the log, so the mod now says what it decided. Look for this line:

    event build -> protection open (99 bodies, 99 changed) [locked 2, open 96, sweep 1]

- **96 open** -- the plots ARE buildable and the problem is somewhere else
- **96 locked** -- the resolver is refusing them, and that narrows it to
  `Plots.sv_bodyIsOpen`

Or point at your plot and type **`/why`**, which prints the zone, the mode,
`buildopen` and every flag on that exact body.

## 2. The lift

`hostlift` defaulted ON, which combined with the host restriction was pulling it
out of everyone's hands. Default is off now, and a settings **migration** flips
your saved value -- a changed default alone would never have reached you.

`/tool` while holding it still says which of the two lifts you have.

## 3. The cleaner -- new tool, looks like a sledgehammer

The answer to "I cant remove them, remove like delete then". Carryable props are
*picked up* by the remove tool rather than erased, so no permission flag reaches
them; script-side destroy is the only thing that works.

- **click** -- delete the block or prop you point at
- **F + click** (or right click) -- delete the whole creation
- host only, never touches the city floor

Every call in it was checked against the base game and four did not survive --
see V37 in the changelog.

## 4. Buffer time polishes

Set a buffer of a minute or two. During it you should be able to **paint, rewire
a controller, sit in a seat and drive** -- but not place or break a block.

## 5. Litter

Craftbots and gems on the plaza should now be clearable, in every mode including
after an event has ended. `/menu` -> CITY LAYOUT -> **SWEEP LITTER** clears the
streets and the plaza in one press.

## 6. The city, and the compass

- Rebuild the city: each plot should be a concrete pad with a **metal ring welded
  round it**, and the whole thing should sit on one continuous platform.
- The plot floor should now be impossible to pick up with a lift. It was not.
- Claim a plot, walk off, **FIND MY PLOT** -- the compass marker should not be
  stretched any more.
- The **event clock should be in the top right**. It was off the edge of the
  canvas entirely, which is why you never saw it.

## The city is many bodies again (V39)

V32 welded a slab under the whole footprint to make the city "one platform".
That was the wrong fix, and you caught why: **a body is the unit the engine
rebuilds**, so welding the city means one person placing a block reprocesses
everybody's plot.

Rebuild the city and it should now be:

- **every street its own creation**, welded to neither panel beside it
- **every plot with its own stand** -- a metal column from the ground to the
  underside of its pad, welded into the plot's own body
- **the plaza on its own pillar**
- **nothing spanning the footprint**

Visually it will read as a grid of panels each on its own leg, with detached
strips between them -- separated, on purpose.

The log now says how many separate creations the shared ground came out as:

    [ServerWorks] shared ground: 31 separate creations, 0 failed, 0 short

## One decision waiting on you

Your blueprint is **22x22 with a 20x20 concrete interior** -- you put the metal
ring *around* a 20-block pad. I built it the other way: the ring eats the outer
block of a 20-block plot, leaving an **18x18** pad. That quietly shrinks
everyone's build area, which you never asked for.

Matching your blueprint means street width going from 1 to 2 (each plot's ring
takes one block of the seam, two rings fill it exactly) and the city getting
about 10% wider. Say which you want and it is a small change either way.

## Not started

- Quest markers for plots, and the invite system — parked, as agreed.
- Frame rate. Still what the very first measurement pointed at.
- `PhysicsQuality`.

## Verified without the game

    check_lua.py      20/20 compile
    check_uuids.py    67 uuids resolve in THIS baseGameContent
    test_layout.py    13 configurations, every block rasterised, no plaza band
    test_logic.py     56 checks, three of which walk the panel plumbing: every
                      command a panel sends must be answered by the world, every
                      button must reach a branch, and no click handler may close
                      its own panel. The third one was written by putting the bug
                      back and watching it fail -- which is the only way to know a
                      check works.

## The rule that keeps paying

**Read the log first** — and read the lines that are not Lua errors. The
callback bug never raised one. It showed up only as

    ERROR: ASSERT: 'itrStackWalk != m_vecLastMethodStack.rend()' : LuaVM.cpp:716

which had been in every log for weeks and was skipped over as engine noise
because it was not tagged `[Lua]`.
