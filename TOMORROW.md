# Start here

The durable record is in [`docs/PLAN.md`](docs/PLAN.md) — goals, the measurement
that reordered them, every engine constraint, the architecture, what is built,
and what is left. [`docs/CHANGELOG.md`](docs/CHANGELOG.md) has every version and
the bug it fixed. Read those before re-deriving anything.

## State

**V23 installed.** Proven in game: `/lockdown`, the clay gun cannot fire, the
city builds and looks right, `sm.json` persistence, explosives and fire off,
content updates reach the game.

## Next, in order

1. **Does the lift spawn creations now?** V19 gave uuid `8f190ce2` back to
   creative's `Lift`; unconfirmed since. If not: `/why` while pointing at
   something, and `/protection`.
2. **UI for the rest.** `/players`, `/rules`, `/banlist`, `/known` still print to
   chat. Each wants a panel like `/settings` and `/plotmenu`.
3. **Frame rate.** The measurement pointed here and nothing has been done about
   it — part budgets and plot spacing aimed at what is *rendered*.
4. **`PhysicsQuality`.** `/protection` prints the host's value. Change it in the
   host's game options, play two sessions, run `dev/session_stats.py` on both.
   The first real simulation lead, still unmeasured.

## The habit that works

    python dev/check_lua.py              # before anything
    python dev/sync_mod.py --clean-cache # install
    python dev/session_stats.py --spam   # after any run

**Read the log first.** Every hard bug in this project was named outright by
`Logs/game-*.log`. Guessing before reading has cost whole test cycles, more than
once.
