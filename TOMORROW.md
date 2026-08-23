# Next session

V25 is installed. **Restart Scrap Mechanic** — mod content is read at startup and
the compiled script cache has been wiped.

Run this first, every time. Ten seconds, and it has caught three real bugs:

    python dev/check_all.py --sync

## 1. The lift — third attempt, first one built on evidence

**Look for a SECOND lift in the creative menu.** There should now be two items
called Lift. Take the new one.

Then place it and press **E**.

### Why there are two

The log prints the class every uuid resolves to, and ours said, every session:

    Created Tool 18 of type {8f190ce2-3a59-423e-8483-a7aa67bd5bc0(SurvivalLift)}

That one line settled two things that had been guessed at:

- **A Custom Game's toolset cannot override a base-game uuid.** It can only ADD.
  So V19's lift override and V22's guarded clay gun / fire launcher never ran at
  all. (The clay gun was stopped by the client-side `forceTool` guard that shipped
  in the same build — the subclasses got credit for someone else's work.)
- **The creative lift is a different item.** `5cc12f03` is `tool_lift_creative`;
  `8f190ce2` is the survival one. `baseGameContent: "Survival"` never loads the
  toolset that declares the creative lift, so this game simply did not have it.

V25 adds `5cc12f03`, which is the case that provably works. **This is a strong
inference, not a measurement** — the thing to confirm.

If E still does nothing, the next thing to read is the log line above: run
`grep "Created Tool" Logs/game-*.log` and see which lift you were holding.

## 2. Find my plot

Claim a plot, then look at your compass. There should be a marker on it.

- `/myplot` → **FIND MY PLOT**, or just `/home`
- It follows claiming, giving up a plot, and rejoining an event
- It is your own HUD, so nobody else can see it

## 3. /myplot

The panel for claiming. One place for: what you own, what square you're standing
on, who's on your team, a live map with your plot in green — and buttons to claim,
find, or give up. The line under the buttons says why CLAIM is doing nothing when
it is.

Worth checking the hint line is honest in each case: standing nowhere, standing on
a free plot, standing on someone else's, already owning one.

## 4. The city (V24, still unconfirmed by eye)

The log says `city built: 100 plots, 0 failed` — three times, where it used to
skip 16 for the plaza. So the geometry is right. Still worth looking at:

- one pillar, under the plaza, and no others
- two wide avenues running out of the plaza to the city edge
- no gaps in the streets — three vertical seams used to be missing entirely
- **press BUILD CITY twice.** Nothing should double up.

## 5. Teams

`/plot team <them>`, both ways. Front, behind, left, right — never diagonal.
Then have a third person team the second, and check the first and third are now
teammates: teams chain, links don't. Across a road or the plaza it should refuse
and say which.

## Still not done

- `/rules`, `/banlist`, `/known` are still chat-only.
- Frame rate. What the measurement pointed at on day one; still nothing done.
- `PhysicsQuality`. `/protection` prints the host's value. Two sessions and
  `dev/session_stats.py` would settle it.
- Quest markers and invites — parked, as agreed.

## Verified without the game

    check_lua.py      16/16 files compile through a real Lua parser
    check_uuids.py    67 uuids, all resolving in THIS baseGameContent
    test_layout.py    12 city configurations, every block rasterised
    test_logic.py     38 checks: settings, bans, profiles, plots, teams, panels

These run the mod's own Lua, not a Python restatement of it. A pass means the
rules are sound; everything touching a body, a tool, a GUI or the network is
still only as good as the citations.

## The rule that keeps paying

**Read the log first.** Every hard bug this project has had was named by
`Logs/game-*.log` — including this one, which had been sitting in a
`Created Tool` line for three builds before anyone looked at it.
