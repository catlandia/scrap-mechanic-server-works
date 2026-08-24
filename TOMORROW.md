# Next session

V29 is installed. **Restart Scrap Mechanic.** Then, always:

    python dev/check_all.py --sync

## Fixed in V29 — please check these first

### The buttons

Exactly one was dead: **CLEAR CITY**. The panel sent `/citycensus` to the world
and the world had no branch for it, so the panel closed and nothing happened.

Everything else worked and *looked* dead, because every panel used to close on
every click. That is the real change:

- **only CLOSE and BACK close a panel now.** Press PAUSE and the event panel
  stays put with "the clock is paused" written under the title.
- **every panel has a status line** under its header. It is the answer to the
  press.
- **BACK** is on every panel and goes to `/menu`.
- the city panel finally has a **CLOSE** button — before, the escape key was the
  only way out.

Worth trying in this order: `/menu` → EVENT CLOCK → step the times → START →
PAUSE → +5 MIN → RESUME → BACK. Nothing should shut until you press BACK.

Then `/menu` → CITY LAYOUT → CLEAR CITY. It should now ask twice and the first
ask should list what is on the city, counted live. Cancel puts you back on the
city panel.

### The concrete

You said it was flush but read as a separate slab, and that was right — the
geometry was never wrong, the city was just a hundred loose tiles laid next to
each other.

They cannot be welded into one body: your build welds onto your plot slab, and
per-plot `/restore` finds a build by asking which plot its body is on. Weld the
city and repairing one griefed plot becomes "roll the whole world back", which is
the thing this project exists to avoid.

So there is a **base layer** now: one continuous slab across the whole city, one
block under the deck, welded into the streets. The plots and streets sit inlaid
in its top surface. It should look like one raised platform two blocks thick with
a proper edge all round.

**Rebuild the city to see it** — `/menu` → CITY LAYOUT → BUILD CITY.

### The log was writing a traceback every second

`SM_HeaderSmall_Medium` is not a real font. It rendered fine via fallback and
logged a MyGUI error plus a full Lua traceback on every redraw of the event HUD —
once a second, all session. Fixed, and the font check now tests that a font
*exists* before it tests its glyphs.

### The compass marker

It has never once worked: `compassSetIconWorldPosition` needs a world and it was
being called from `Game.lua`, which has none. Moved to `Player.lua`.

**FIND MY PLOT** should now put a marker on the compass. Claim a plot, walk away,
press it.

## Still unknown

### The lift

Untouched this round. `/tool` while holding it says outright whether you have the
creative lift (`5cc12f03`) or the survival one (`8f190ce2`). There should be two
"Lift" items in the menu.

If `/tool` says survival, the toolset addition did not load and that is a
different problem from the lift itself. If it says creative and E still does
nothing, no Lua change will fix it — the blueprint menu is engine-side
(`GarageImportGui`) and the next step is finding what else the engine gates it
on.

### Confirm building works when prep ends

Still the single most important thing to confirm. It was broken until V28 and has
not been verified in game since.

## Not started

- Quest markers for plots, and the invite system — parked, as agreed.
- Frame rate. Still what the very first measurement pointed at.
- `PhysicsQuality`.

## Verified without the game

    check_lua.py      20/20 compile
    check_uuids.py    67 uuids resolve in THIS baseGameContent
    test_layout.py    13 configurations, every block rasterised, no plaza band
    test_logic.py     55 checks, including two new ones that walk the panel
                      plumbing from both ends -- every command a panel sends must
                      be answered by the world, every button must reach a branch.
                      Those two would have caught CLEAR CITY before you did.

## The rule that keeps paying

**Read the log first.** It named the dead font, the compass marker and the
canvas size in this session alone, and it has named every hard bug this project
has had.
