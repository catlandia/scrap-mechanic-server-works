# Next session

V28 is installed. **Restart Scrap Mechanic.** Then, always:

    python dev/check_all.py --sync

## Still broken — start here

### 1. The plot is not attached to the rest of the build

Reported twice, still not fixed, and I could not reproduce it from the outside.
The geometry is *proved* to be a gapless partition over 13 configurations, so the
hole is not in the arithmetic — it is in what actually lands in the world.

V26 added a settling stage (clear, wait 20 ticks, then import) because
`shape:destroyShape()` does not take effect until the tick ends. That was a real
bug and is fixed, but it may not have been this one.

**What to do:** rebuild the city, then read the log for

    [ServerWorks] deck: asked for N shapes, got M -- the city has holes

If N ≠ M the deck import is dropping pieces and that is the whole story. If they
match, the deck is complete and the problem is the *plot slabs*, which are
imported one per creation — and the next thing to try is importing a plot and
immediately counting its shapes the same way.

### 2. The lift

`/tool` while holding it. It says outright whether you have the creative lift
(`5cc12f03`) or the survival one (`8f190ce2`). **There should be two "Lift" items
in the menu now** — if `/tool` says survival, the toolset addition did not load
and that is a different problem from the lift itself.

The blueprint menu E opens is engine-side (`GarageImportGui`), so if you have the
creative lift and E still does nothing, no Lua change will fix it and the next
step is finding what else the engine gates it on.

### 3. The event HUD position

I fixed the anchor in V27 by sizing the root to the screen, but your screenshot
after that still showed it middle-left. Either V27 was not loaded yet, or
`sm.gui.getScreenSize()` is not returning what I think.

**V28 logs it once per session:**

    [ServerWorks] gui canvas 1693x693 (panels are declared in these units)

Grab that line. It settles both the HUD position *and* a second risk: every panel
here is declared in those units and `SettingsGui` is 1120x690. If that height
really is 693, the settings panel has three units of headroom and is one
resolution change away from having a button off screen.

## New in V28 — worth trying

    /menu -> EVENT CLOCK

Prep / build / buffer as steppers, then START. No typing. Pause, skip, ±5 min and
stop appear once it is running.

- **prep** closes building and nothing else — seats and buttons still work
- **buffer** is optional: building closed, nothing locked yet, time to look round
- the last 5 minutes of build get the warehouse alarm
- **ending locks every build and takes a full world snapshot**

Check that building actually works when prep ends. That was broken until V28 and
it is the single most important thing to confirm.

    /menu -> CITY LAYOUT -> CLEAR CITY

Asks twice. The first ask lists what is on the city, counted live. On the second
ask the buttons swap sides, so a reflex double-click lands on CANCEL.

**The plaza is a square now, not a cross.** 10x10 with a 2-cell plaza gives 96
plots and a 41x41 square. Look for: ordinary-width streets everywhere, no huge
metal expanses, one pillar under the plaza.

Snapshots are stamped: `auto2-2026-08-24_2247`, `eventend-2026-08-24_2312`.

## Not started

- Quest markers for plots, and the invite system — parked, as agreed.
- Frame rate. Still what the very first measurement pointed at.
- `PhysicsQuality`.

## Verified without the game

    check_lua.py      20/20 compile
    check_uuids.py    67 uuids resolve in THIS baseGameContent
    test_layout.py    13 configurations, every block rasterised, no plaza band
    test_logic.py     53 checks: settings, bans, profiles, plots, teams, event,
                      fonts, and every panel's layout at every state

The font check is the one to remember: the game ships a **limited glyph atlas per
font**, so a caption can silently lose letters. It has caught twelve broken
strings so far, all before they reached the screen.

## The rule that keeps paying

**Read the log first.** Every hard bug this project has had was named by
`Logs/game-*.log` — including the toolset one, which sat in a `Created Tool` line
for three builds before anyone looked.
