# Next session

V31 is installed. **Restart Scrap Mechanic**, then do this first:

## Run /guitest four times. It takes a minute and it ends the guessing.

Three versions have gone on "the buttons dont work". Each fix was a real bug and
none of them was the whole story, so this stops reasoning about it and measures
it.

Type `/guitest`. A small panel appears. **Press both buttons on it.** If the
panel rewrites itself to say **CLICK RECEIVED**, that arrangement works. Then
type `/guitest` again for the next test. Four tests:

| test | what it is |
|---|---|
| 1 | Game script, tree built in Lua — exactly what the mod ships today |
| 2 | Game script, tree loaded from vanilla's own `.gui` file |
| 3 | Player script, tree built in Lua |
| 4 | Player script, tree loaded from vanilla's own `.gui` file |

Tell me which ones said CLICK RECEIVED. That single answer decides the fix:

- **1 works** → buttons are fine and the problem is downstream (the trace below
  will say where).
- **1 fails, 3 works** → a Game script does not receive GUI clicks, and every
  panel moves to the player script.
- **1 fails, 2 works** → a hand-built widget tree is the problem and the panels
  become `.gui` files.
- **nothing works** → it is environmental, and the canvas line the probe prints
  is the next clue.

Test 1 has two buttons on purpose: one carries a data table, one does not. If
only the second works, the data table is what breaks it.

## And the real menu is traced now

Clicking anything on `/menu` writes four lines to `Logs/game-*.log`. The last one
printed is where it stops:

    [ServerWorks] gui 1/4 menu click: widget=B6 data=table
    [ServerWorks] gui 2/4 server got menu open: what=city host=true
    [ServerWorks] gui 3/4 sending the city panel
    [ServerWorks] gui 4/4 client rendering the city panel

If all four print, the panel is being built and rendered and the problem is that
you cannot see it — wrong coordinates, wrong layer, or drawn behind something.

## Everything known about buttons is written down

`docs/BUTTONS.md` — the tree, the callback signatures, the lifecycle, the
coordinate space, and the close rule, each with the vanilla file and line it came
from. It marks what is confirmed and what `/guitest` is there to settle.

## What V30 fixed, which you have not been able to see yet

Closing a json GUI from inside its own click callback kills the rest of the
callback, so the hub menu closed and never sent the request. That was real and it
is fixed. Whether it was the last thing in the way is what `/guitest` answers.

## Still to verify from V29 — none of it has been seen yet

- **The city as one platform.** Rebuild it: `/menu` → CITY LAYOUT → BUILD CITY.
  There is a continuous slab under the whole city now, so it should read as one
  raised platform two blocks thick rather than a hundred loose tiles.
- **Panels stay open.** Press PAUSE on the event panel; it should stay put with
  "paused" written under the title.
- **CLEAR CITY asks twice** and the first ask lists what is on the city.
- **Building works when prep ends.** Still the single most important thing to
  confirm, and still never confirmed in game.

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
