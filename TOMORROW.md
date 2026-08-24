# Next session

V32 is installed. **Restart Scrap Mechanic** — scripts are read at world load, so
a running game will not pick it up.

## Try the three host buttons first

Your screenshot named the bug. EVENT CLOCK, CITY LAYOUT and SERVER SETTINGS are
the only three entries that open **a second panel**; the ones above them answer
in chat, and those had been working. Being host was never the problem — the menu
hides host entries from guests, so a visible button means that check passed.

A json GUI has no `destroy()`: `close()` hides it and the object stays. The mod
made one per panel, so opening a second panel meant two live interactive GUIs on
one script, which nothing in the base game ever does. They all share one now.

`/menu` → CITY LAYOUT should open the city panel. Then BACK, then SERVER
SETTINGS, then EVENT CLOCK.

## If they still do nothing, run /guitest — five times

Type `/guitest`, press both buttons on the panel that appears, then `/guitest`
again for the next test. If the panel rewrites itself to say **CLICK RECEIVED**,
that arrangement works.

| test | what it is |
|---|---|
| 1 | Game script, jsonGui, tree built in Lua — what the mod ships |
| 2 | Game script, jsonGui, tree from vanilla's own `.gui` file |
| 3 | Player script, jsonGui, tree built in Lua |
| 4 | Player script, jsonGui, tree from vanilla's own `.gui` file |
| 5 | Game script, **createGuiFromLayout** — the other GUI api |

Test 5 is new and it matters: there are two GUI systems, and vanilla's Game
script uses the *other* one for its creative CLEAR dialog
(`CreativeGame.lua:283`). That proves a Game script can own a working button; it
does not prove `sm.jsonGui` can.

Tell me which tests said CLICK RECEIVED and that decides the fix.

## The menu path is traced

One click on `/menu` writes four lines to `Logs/game-*.log`. The last one printed
is where it stops:

    [ServerWorks] gui 1/4 menu click: widget=B6 data=table
    [ServerWorks] gui 2/4 server got menu open: what=city host=true
    [ServerWorks] gui 3/4 sending the city panel
    [ServerWorks] gui 4/4 client rendering the city panel

All four printing means the panel is being built and rendered, and the problem is
that you cannot see it.

## What you have to do for a panel to open

Written up in `docs/BUTTONS.md`, but the one that matters: **when a panel is up,
do you get a mouse cursor?** If not, your clicks are going to the world and no
amount of fixing the panel will help. Also: not seated, nothing else holding the
mouse (Tab inventory, handbook, pause menu, the lift's blueprint window), and the
game restarted since the last sync.

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
