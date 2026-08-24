# Next session

**The buttons work.** Confirmed in game 2026-08-24. Four bugs stacked on top of
each other, each hiding the next — the whole story is in `docs/BUTTONS.md` under
*SETTLED*, and `/guitest` stays in the mod for re-checking after a game update.

That unblocks everything built in V29-V32, none of which has ever been seen.
In rough order of what matters:

## 1. Does building work when prep ends?

Still the single most important thing to confirm, and it has never been verified
in game. `/menu` -> EVENT CLOCK -> set prep to 2 minutes -> START. When the prep
clock runs out, try to place a block.

- **prep** should close building and change nothing else — seats and buttons
  still work
- **build** opens it
- the last 5 minutes of build get the warehouse alarm
- **buffer** (optional) closes building again without locking anything
- **ending** locks every build and takes a full world snapshot

## 2. Rebuild the city and look at it

`/menu` -> CITY LAYOUT -> BUILD CITY. There is a continuous slab under the whole
city now, so it should read as one raised platform two blocks thick with a proper
edge all round — not a hundred loose tiles. That was the "concrete doesnt stick
to the borders" report.

## 3. The panels stay open now

Press PAUSE on the event panel: it should stay put with "paused" written under
the title. Same for every control. BACK returns to the hub. Only CLOSE closes.

## 4. CLEAR CITY asks twice

`/menu` -> CITY LAYOUT -> CLEAR CITY. The first ask lists what is actually on the
city, counted live. On the second the buttons swap sides so a reflex double-click
lands on CANCEL. Cancelling puts you back on the city panel.

## 5. FIND MY PLOT

Claim a plot, walk away, `/menu` -> MY PLOT -> FIND MY PLOT. A marker should
appear on the compass. It has never worked before — it was being driven from a
script with no world, twice.

## Housekeeping

`/menu` still writes four `gui 1/4`..`gui 4/4` trace lines per click. Harmless
(four lines per *click*, not per tick) and useful while the other panels get
exercised for the first time. Say the word and they come out.

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
