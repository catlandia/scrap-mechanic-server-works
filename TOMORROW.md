# Next session

V30 is installed. **Restart Scrap Mechanic** — a running game will not pick it up.
Then, always:

    python dev/check_all.py --sync

## What was actually wrong with the buttons

Closing a json GUI from inside its own click callback **kills the rest of the
callback**. The hub menu did

    self:cl_closeMenu()                                 -- destroys the widget
    self.network:sendToServer( "sv_n_menuOpen", ... )   -- never runs

so the menu closed and the request was never sent. Every host feature is reached
through the hub, which is why *nothing* on it ever opened — CITY LAYOUT, SERVER
SETTINGS, EVENT CLOCK, all of them. It is also, eight versions later, the same
bug as "I am the host why cant I access features".

There is no Lua error for it. The only sign was an engine assert sitting in the
logs for weeks: `ASSERT: 'itrStackWalk != ...' : LuaVM.cpp:716`.

Closes are now queued and happen on the next tick, so a widget can never be
destroyed while its own callback is running. A check fails if any handler closes
directly.

**Try:** `/menu` → CITY LAYOUT. Then SERVER SETTINGS. Then EVENT CLOCK. All three
should open. Everything V29 built — the status lines, BACK, the two-step delete —
has never actually been seen, because the panels were not opening.

## Also fixed

- **The compass marker**, third attempt. It was in the Game script (no world),
  then the player script (no world either — the same warning came back word for
  word). It is in `World.lua` now, sent to one client the way vanilla sends a
  beacon. Claim a plot, walk off, press **FIND MY PLOT**.

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
