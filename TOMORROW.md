# Next session

V24 is installed. **Restart Scrap Mechanic** — the game reads mod content at
startup, not on world load, and `sync_mod.py --clean-cache` has already wiped the
compiled script cache.

## Test these, in this order

Everything below is a thing that could not be verified without the game. The
things that *could* be were, and they pass — see "Already verified" at the bottom.

### 1. The lift, and the real reason it was broken

    /menu  ->  or just open the Creations menu and pick a blueprint

Pick a saved creation out of the blueprint menu and place it. It should appear.

**What changed and why.** V19 blamed survival owning the lift's uuid. That was
wrong — `SurvivalLift = class( Lift )` with one live method, so it inherits all
the blueprint handling. The real cause was ours: picking a creation spawns **real
bodies flagged as ghosts**, and the protection patrol was pinning
`convertibleToDynamic = false` on them within a fraction of a second. A ghost
that cannot convert to dynamic cannot become a creation. Ghosts are now invisible
to the mod everywhere.

If it still fails, point at something and run:

    /why

It now prints `ghost=` `onLift=` `virtualLift=` `protectedByUs=` for whatever you
are looking at. If `protectedByUs=true` while you are holding a blueprint, the
ghost test is not catching it and that is the next thread to pull.

### 2. The city, built from the middle outwards

    /menu -> CITY LAYOUT -> BUILD CITY

Watch the order: the pillar and the plaza go down first, then plots fill in
outwards in rings from spawn. Check for:

- the plaza sits exactly on spawn, and there is exactly **one** pillar
- two wide avenues run out of the plaza to the city edge
- no gaps in the streets (three vertical seams used to be missing entirely)
- no two slabs occupying the same ground

Then press **BUILD CITY a second time** without changing anything. Nothing should
double up. That is the specific bug: the old clear found city bodies by height,
and a slab with a build welded to it floats above the test, survived the clear,
and got a second slab imported into it.

### 3. The map matches the world

Open `CITY LAYOUT` and compare the top-down map against what got built, piece for
piece. It is now drawn from the same function the builder uses, so any difference
at all is a bug worth reporting. Your own plot draws green.

### 4. Teaming

Claim a plot, have someone claim the one next door, and `/plot team <them>` both
ways. Then try to team with someone **across the plaza** or across a road — it
should refuse. The seam between two plots is what makes them neighbours, not
their position in the grid.

## Then, the still-untested pile

- `/players`, `/rules`, `/banlist`, `/known` are still chat-only. They each want
  a panel.
- Frame rate. Still the thing the measurement actually pointed at, still nothing
  done about it.
- `PhysicsQuality`. `/protection` prints the host's value. Two sessions and
  `dev/session_stats.py` would settle whether it matters.

## Already verified, without the game

    python dev/check_lua.py      14/14 files compile through a real Lua parser
    python dev/test_layout.py    12 city configurations, every block rasterised
    python dev/test_logic.py     22 checks over settings, bans, profiles, plots

Run all three before any test session. They execute the mod's own Lua rather than
a Python restatement of it, so a pass means the rules themselves are sound —
what remains is everything that touches a body, a tool, a GUI or the network.

## The rule that keeps paying

**Read the log first.** `Logs/game-*.log` in the game folder. Every hard bug this
project has had was named outright by it — except this one, which named nothing
at all, which is exactly why it took three attempts.
