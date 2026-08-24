# Changelog

The version is on the mod thumbnail, so a host can tell which build a machine is
running from the Custom Game list without opening a file. `VERSION` holds it —
**not** `description.json`, whose `version` is the game content version and must
stay `1` for a Custom Game on this build.

Bugs below are marked **MEASURED** where the game log named them outright, which
was most of them.

---

## V37 — the theory pass over the cleaner

*"because I cant test right now. just on theory. make sure it works."*

So every call the cleaner makes was checked against the base game, and four of
them did not survive it.

| what | verdict | what changed |
|---|---|---|
| `sm.gui.chatMessage` from a tool | **no vanilla tool calls it, ever** | wrapped; anything that matters is said by the server through `Game.sv_e_swReply` instead |
| `body:getWorld()` | **never called on a body in the base game** | goes through `player:getCharacter():getWorld()`, which vanilla uses in three places |
| `sv_n_*( self, params, player )` | some tools declare the player, some are `( self, params )` | falls back to `self.tool:getOwner()`, the server-side idiom from `CarryTool.lua:376`. Without it the host check would have compared against nil and refused every delete |
| `previewRotation` | copied from the lift | copied from the creative sledgehammer instead, since the rotation belongs to the renderable and ours is the sledgehammer's |

And what *did* survive, with the vanilla line behind it:

- **shapes and harvestables cross the network in tool params** —
  `Fertilizer.lua:246` sends `{ targetSoil = <Harvestable or Shape> }` to its own
  server half and checks it with `sm.exists`. That is the exact pattern the
  cleaner uses.
- `result:getBody()` — `StickyWheel.lua:517`, `Vault.lua:178`
- `result:getHarvestable()` — `CarryTool.lua:862`, `Fertilizer.lua:225`
- `sm.localPlayer.getRaycast( range, start, direction )` — `Sledgehammer.lua:362`
- `return true, true` from an equipped update — `CarryTool.lua:936`
- `sm.tool.interactState.start` — used throughout
- the toolset entry shape — identical to the lift's, which is the scripted-tool
  case (the *creative* sledgehammer has no script at all; it is
  `"sledgehammer": {}`, engine-side)

`Sledgehammer.client_onUpdate` is also now wrapped. It reads
`clientPublicData.perks` while a swing animation plays — our tool never swings,
so it should never reach that line, but a tool that throws once per frame is
exactly the 1.79 GB log this project already has one of. It gives up after the
first failure instead.

The wiring check was rewritten too: it parsed a 400-character window around the
class name, and adding a comment above the uuid broke it. It parses the toolset
as JSON now. A check that depends on how a file is commented is a check that will
lie.

---

## V36 — the cleaner: point at it, press F, it is gone

*"look. the problem is I cant remove them. remove like delete then. I want to be
able to DELETE them when pressing F while removing."*

V35 made craftbots and gems *erasable*. That was necessary and it was not
sufficient, because **carryable props are picked up by the remove tool rather
than erased** — no permission flag reaches them at all. Script-side
`destroyShape()` is the only mechanism that deletes one.

### F is `ForceBuild`, and only a tool can see it

**MEASURED**, from `keybinds.json`: `"ForceBuild": [ { "K": 70 } ]`. 70 is F.

That action reaches Lua in exactly one place — the third argument of a tool's
`client_onEquippedUpdate( self, primary, secondary, forceBuild )`. A Game script,
a World script and a player script get no key state whatsoever;
`client_onAction` exists only on interactables that lock the player. So a key
press means a tool, and a Custom Game toolset can **add** a tool but never
override one — which together leave exactly one shape for this feature.

### The cleaner

A new tool, new uuid, so it is an addition and provably resolves to our class.

- **click** — delete the block or prop you are pointing at
- **F + click** (or right click) — delete the whole creation
- works on harvestables too
- **host only** by default, because a delete-anything tool in a lobby is a
  griefing tool. Setting `hostcleaner`.
- **never touches the city floor.** CLEAR CITY exists for that, asks twice, and
  snapshots first. "Whole creation" also stops at our concrete, so deleting a
  build welded to a plot slab leaves the plot.

It is defensive about the Lua environment: a tool script may not share the
Game/World globals, so `Settings` and `g_swPlots` are both guarded and both fall
back to the safe answer — host-only if the settings cannot be read, "that is city
floor" if a shape cannot be classified. Replies go through `Game.sv_e_swReply`,
because a tool's network has `sendToServer` and `sendToClients` and no vanilla
tool ever calls `sendToClient( player, ... )`.

A check asserts the uuid, the class, the tool-guard entry and the host gate all
agree — a tool named consistently in two of those three places is one that either
cannot be blocked or blocks something else.

---

## V35 — unremovable craftbots, and a sweep button that would have deleted the city

**REPORTED:** *"you need to fix the unremovable craft bots, gems and others."*

Three separate rules were locking shared ground, and any one of them alone was
enough to make a dropped craftbot permanent.

1. **The plaza returned `"locked"`.** That line existed to stop a guest deleting
   spawn — but the plaza is where everyone arrives, so it is precisely where the
   spam lands, and locking the ground locked the spam with it. The decking never
   needed that defence: `sv_isScenery` catches it one step earlier and is a much
   better test, because our plaza is metal at deck height and a craftbot standing
   on top of it is not. The plaza is shared ground now, like every street.
2. **`buildopen == false` locked everything before the zone was consulted.**
   Prep, buffer and the end of an event all close building, and the world stays
   locked *between* events — so anything dropped during any of those was
   permanent from that moment. The zone verdict is asked for first now.
3. **A locked mode never reached the resolver at all.** `/lockdown` froze the
   rubbish along with the builds. A `sweep` verdict escapes a locked world now;
   nothing else does, so lockdown still means lockdown.

### Carryable props cannot be erased at all, so the sweep is a button

Gems, crates and harvestables are **picked up** by the remove tool rather than
erased, so making them erasable does not make them removable. Script-side
`destroyShape()` ignores every permission flag, which is the only way to be rid
of one — so **SWEEP LITTER** is now a button on the city panel rather than a chat
command nobody would remember at the moment they needed it.

### And wiring that button found a much worse bug

`/purge walkways` removed every body **not standing on a plot** — which is the
deck, the streets, the plaza and the pillar. The entire city floor. It had never
bitten anyone only because it was a chat command nobody ran; one press of a
SWEEP LITTER button would have deleted the world.

Every bulk purge now skips any body holding a city shape. The guard is per
SHAPE, not per body, because the moment somebody builds on a plot their build and
our slab are one body — so the same test protects their work. A check asserts it,
written by taking the guard back out and watching it fail.

---

## V34 — buffer time polishes, the lift is everyone's, and a plot is one welded body

### Buffer time is for polishing, not waiting

Asked for as: *"in bufer time you can paint. edit settings. use controllers. and
other stuff like that. but not place or brake blocks. so you can polish some
mechanic stuff if you messed it up a bit."*

That is a new protection profile, `polish` — the open profile with the two
destructive verbs removed:

| | build | erase | paint | connect | use | drive |
|---|---|---|---|---|---|---|
| `open` (build time) | yes | yes | yes | yes | yes | yes |
| **`polish` (buffer)** | **no** | **no** | yes | yes | yes | yes |
| `display` (prep) | no | no | no | no | yes | no |
| `locked` (ended) | no | no | no | no | no | no |

Plot rules still apply during it: somebody else's occupied plot is still locked
to you. Only what *being allowed* lets you do changes.

**And the check caught a real bug on the way in.** `matchesProfile` — the cheap
sentinel that lets the patrol skip bodies already in the right state — compared
only buildable, destructable, usable and erasable. `polish` and `display` agree
on all four, so prep → buffer would have found every body "already correct" and
applied nothing: buffer time would have looked identical to prep. That is the
V15 bug exactly, in a new profile. The sentinel now also reads paintable and
connectable, and the test reads the field list *out of `matchesProfile` itself*
so the two can never drift again.

### The lift belongs to everyone

*"okay look. for this fix of the lift. allow everyone to use the lift. dont lock
it. because I still cant interact with it."*

`hostlift` defaulted **on**, and the host bypass deliberately does not cover
host-only tools — so with the host restriction switched on as well, the lift was
being pulled out of everyone's hands, the host's included, every 2 ticks by
`forceTool( nil )`. Default is off now.

A default alone would not have reached anyone who has already run the server,
because their value is written down. So settings gained **migrations**: one-time
changes that apply to a settings file that already exists, recorded in the same
file so they run once.

### A plot is one welded body of concrete and metal

**MEASURED**, and this is the useful part. The owner built a reference creation
in game and saved it so its structure could be read directly — *"concrete panel
with metal all around it"*, `Blueprints/038852d7`. One body, nine children,
concrete and metal 2 side by side in the same `childs` array.

That is the answer to "how are blocks connected in Scrap Mechanic": **one body's
`childs` array IS the weld group.** Two separate blueprints are two separate
bodies that merely touch, however perfectly they line up. Material has nothing to
do with it.

So the border moved *inside* the plot. Each plot is now a single welded body — a
concrete pad with a metal ring all the way round it, exactly the reference
creation. It costs the outer ring of buildable area: a 20-block plot gives an
18-block pad.

**The plot still cannot be welded to the deck, and that is forced rather than
chosen.** Body permission flags are per-BODY — there is no
`setBuildableBy( player )` — so one plot per body is the only reason plot
ownership can exist at all. Weld the city into one body and it is buildable by
everyone or by nobody.

### The sweep now says what it decided

`"99 bodies, 99 changed"` never answered the question that matters. It now reads

    event build -> protection open (99 bodies, 99 changed) [locked 2, open 96, sweep 1]

so a plot slab that comes out `locked` when it should be `open` says so in the
log — which is exactly the open report, *"I cant build on my plot even when the
time has started"*.

---

## V32 — one GUI, not six

**REPORTED**, with a screenshot of the host section of the menu: *"these buttons
dont work for no reason. I am the host. let me use them."*

The screenshot is what named it. The three entries in it — EVENT CLOCK, CITY
LAYOUT, SERVER SETTINGS — are exactly the three that open **a second panel**. The
four above them answer in the **chat log**, and those had been working since V30.
The host check was never involved: the menu hides host entries from guests, so a
visible button means the check already passed.

A json GUI has **no `destroy()`**. `close()` hides it and the object stays. The
mod made one per panel — menu, city, settings, event, my plot, confirm — so
opening a second panel meant a second live interactive GUI on the same client
script, and nothing in the base game ever does that. Vanilla creates **one** and
re-renders it (`HideoutTrader.lua:1242` rebuilds its whole item list that way).

They all share `Game.cl_showPanel( name, tree )` now. Switching panels is one
render call: no close, no gap, no window where two interactive GUIs are both
alive. A check fails if a second one appears; it was written by putting one back
and watching it fail.

**And the close race that fell out of it.** Once panels share a GUI, queueing a
close on a click that is about to open something can shut the panel that just
arrived. So only a real CLOSE closes. BACK, a cancelled confirmation, and every
menu entry that opens a panel now leave the GUI alone and let the reply render
into it — which is also, finally, what "make so that the menu doesnt close after
every action" actually looks like.

**Also found**: there are two GUI systems. `sm.gui.createGuiFromLayout` takes a
`.layout` file, has `open()`, and uses `setButtonCallback` — and vanilla's Game
script uses it for the creative CLEAR dialog (`CreativeGame.lua:283`), which
proves a Game script can own a working button. `sm.jsonGui` is the newer, freer
one we use. `/guitest` test 5 compares them directly.

`docs/BUTTONS.md` now carries the lot: the tree, both APIs, the callback
signatures, the lifecycle, the coordinate space, the close rule, the one-GUI
rule, and a plain checklist of what a *player* has to do for a panel to open.

---

## V30 — the actual reason no button has ever worked

V29 said one button was dead. That was true and it was not the story.

**Closing a json GUI from inside its own click callback kills the rest of the
callback.** `close()` destroys the widget whose `onClick` is on the Lua stack and
the engine tears the callback down with it, so every statement after the close is
dead code. No Lua error is raised. The only trace is an engine assert that has
been sitting in the logs for weeks:

    ERROR: ASSERT: 'itrStackWalk != m_vecLastMethodStack.rend()' : LuaVM.cpp:716

The hub menu did exactly that:

    self:cl_closeMenu()                                 -- destroys
    self.network:sendToServer( "sv_n_menuOpen", ... )   -- never runs

So the menu closed and the request was never sent. **Every host feature is
reached through the hub**, which is why "I am the host why cant I access
features" (V26) and "I click on city layout in menu and it does nothing" (now)
are the same defect, and why V29's panel-stays-open work made no visible
difference: the panels were never opening in the first place.

The correlation across the six click handlers is what proves it. The three that
sent before closing all worked, and the logs show them working — BUILD CITY built
a city, the event panel ran phases, the settings panel applied a preset. The
three that closed first did nothing, every time. Vanilla always sends first and
closes last (`CreativePlayer.lua:48`).

Fixed structurally rather than by reordering: **a close is queued and drained on
the next tick.** A widget cannot be destroyed while its own callback is running
if the close happens after that callback returns. `cl_closeLater` /
`cl_drainCloses`, and an `onClose` handler now only drops the handle instead of
closing again — which was the same bug from the other side.

`dev/test_logic.py` asserts no `cl_on*` handler calls a closer directly. Removing
the fix makes the check fail, which is the only way to know a check works.

### The compass marker, third attempt and this time from the right place

V29 moved it from the Game script to the player script. The warning came back
word for word:

    WARNING: compass marker unavailable: PlotMarker.lua:72:
             Calling world dependent functions in a no world script!

A player script has no world either. It runs from **World.lua** now, sent
straight to one client the way vanilla sends a beacon —
`self.network:sendToClient( player, "cl_n_createBeacon", params )` at
`CreativeBaseWorld.lua:278`. That is the pattern for "a marker only one player
sees", it was there all along, and every vanilla caller of the compass lives in a
world-attached script.

---

## V29 — the buttons answer back, and the city becomes one platform

Three things reported, all three real, and the log named two of them outright.

### One dead button, and nine that looked exactly like it

**REPORTED:** *"you should fix the buttons. since they sadly dont work. like I
mean I press them and menu closes."*

There was exactly one dead button in V28 and it was **CLEAR CITY**. The panel
sent `/citycensus` to the world; `World.sv_e_swCommand` had no branch for it. The
command was written on one side of the bridge and never on the other, so the
panel shut and the world did nothing.

What made it a report about *the buttons* rather than about one button is that
every panel closed on every click, so a button that worked and a button that
didn't looked identical from the outside. That is fixed as a convention, not as a
patch:

- **only CLOSE and BACK close a panel.** Everything else runs, and the panel
  re-renders in place with the world's answer on it.
- **every panel has a status line** under its header saying what the last press
  did. PAUSE says it paused. CLAIM on somebody else's ground says whose.
- **a confirmation is modal** and names what to reopen when it is done, so
  cancelling CLEAR CITY puts you back on the city panel rather than nowhere.
- **BACK on every panel** returns to `/menu`, so the hub is a hub.

The city panel also gains a **CLOSE** button, which it never had — the only way
out of it was the escape key.

Two checks now walk that plumbing from both ends: every `sv_toWorld("...")`
string in `Game.lua` must have a `cmd == "..."` branch in `World.lua`, and every
`action = "..."` a panel can emit must be named in `Game.lua`. Both are string
matching, but a name that appears on one side of a bridge and nowhere on the
other is always a bug — and it was this one.

### The city is one platform now

**REPORTED:** *"I dont think the concrete sticks to the borders still"*, the
third time this has come up. Asked what it actually looked like, the answer was
**flush, but a visible seam / separate body** — so the geometry was never wrong.
`test_layout.py` proves it is a gapless partition and always did. The city simply
read as a hundred loose tiles, because that is what it was.

They cannot be welded into one body: a plot slab must stay its own creation,
because a player's build welds onto it and `sv_plotOfBody` finds that build by
asking which plot its *body* is on. Weld the city and per-plot restore collapses
into all-or-nothing, which is the exact failure this project exists to prevent.

So the platform goes **underneath**. One continuous slab across the whole
footprint, one block below the deck, welded into the deck creation, with the
concrete plots and metal streets inlaid flush in its top surface. The city is now
a raised platform two blocks thick with a proper edge all the way round — and
every plot is still the separate creation everything else needs. The central
pillar stops one block lower to make room, because two shapes in one block is how
an import quietly loses one of them.

### The log was writing a traceback every second

**MEASURED**, and this one corrects a claim in `CLAUDE.md` that was wrong:

    [Gui] ERROR: MyGUI_FontManager.cpp:101 | Font 'SM_HeaderSmall_Medium' not
                 found. Replaced with default font.
    [Lua] ----- Lua Error Traceback -----
          Game.lua:620: in function 'cl_updateEventHud'

once a second, for the whole session. `CLAUDE.md` said a font name that does not
exist is *safe* because MyGUI falls back to a complete font. It does fall back —
and it logs an error with a full Lua traceback every time it renders. The event
HUD redraws once a second, so that is 3,600 tracebacks an hour written to disk,
and log spam is the largest performance bug this project has ever measured.

Three of the fonts in use did not exist (`SM_HeaderSmall_Medium`) or were
glyph-limited (`SM_Label` holds only `0123456789:EIMQTestu`; `SM_NumberSmall` is
worse). All seven fonts the mod now uses are real and unlimited. The font check
tests existence *first*, then glyphs, and the registry is the union of two files
— `ManualFontDataInput.xml` and `LimitedFontData.xml` — because eleven real fonts
appear only in the second.

### The compass marker never worked, and said so

    WARNING: [ServerWorks] compass marker unavailable: PlotMarker.lua:72:
             Calling world dependent functions in a no world script!

`compassSetIconWorldPosition` needs a world, and every vanilla caller of it is a
world-attached script. It was being called from `Game.lua`, which has no world —
the same trap that moved every `sm.body.*` call into `World.lua` on day one. It
runs from `Player.lua` now, reached the way `CreativeGame` reaches
`CreativePlayer` for the unstuck popup: `sm.event.sendToPlayer`.

### Measured while looking

- **The GUI canvas is the real screen resolution**, 1:1 — `gui canvas 3440x1440`
  on a 3440x1440 monitor. No scaling, contrary to an earlier guess.
- **A root widget's `x`/`y` is its CENTRE, from the centre of the screen, +y
  down.** Derived from vanilla's own status-panel arithmetic; written down in
  `CLAUDE.md` so the next HUD does not have to be found by screenshot.
- **DEFAULTS on the city panel** was resetting to `spawn = 50`, a field that
  stopped existing in V28. It reads `Layout.DEFAULT` now.

---

## V28 — the plaza stops being a wasteland, and the clock actually works

### "I cant build when prep time is out"

A real bug with a sharp cause. `Protection.profileFor` short-circuits:

    if isLockedMode( self.mode ) then return PROFILES[self.mode] end

The phases were only setting `buildopen` and then re-applying *whatever mode
happened to be current*. So once an event ENDED — which sets the mode to
`locked` and saves it — every later event ran with the world still locked, and
`buildopen` was never consulted again.

The event owns the mode explicitly now, in one table:

| phase | mode | what it means |
|---|---|---|
| prep | `display` | can't build. **Nothing else changes** — seats, buttons, every other rule |
| build | `open` | the event |
| buffer | `display` | building closed, nothing frozen yet |
| ended | `locked` | + full snapshot |
| off | `open` | the host has the controls back |

That table is also the answer to *"the prep time just doesnt allow you to build.
it maintains other rules"* — `display` is exactly buildable-false and
usable-true.

### The buffer phase

    off  →  prep  →  build  →  buffer  →  ended

Optional and off by default. Building has closed but the world is not sealed:
time to walk round, take pictures and judge before anything becomes permanent.

### The plaza was a band. Now it is a square.

**REPORTED:** *"there are these huge chuncks metal three whcih is wasted space
and looks ugly"*, with a screenshot of decking to the horizon.

V24 made the plaza a *segment* on both axes so a plot could never start inside
it. That fixed the overlap and created this: a segment on an axis is a **band
across the entire city**, so a 50-block plaza also meant a 50-block avenue
running the full width *and* the full height.

The plaza is a block of grid **cells** now. The axis is an ordinary uniform run
of plots and seams; the plots under the plaza simply aren't built; every street
is normal width. The whole run is then translated so the plaza's middle lands on
the origin, which keeps spawn at 0,0 with no coordinate going fractional.

Default 10×10 with a 2-cell plaza: **96 plots and a 41×41 square**, instead of
100 plots and a cross of decking. `dev/test_layout.py` now asserts that *nothing
on either axis is a plaza segment* — the band bug, asserted away — and that the
plaza is never more than 40% of the city.

Plots the plaza covers cannot be claimed or teamed with: `Layout.plotIndex`
returns nil for them, which is the one choke point everything downstream already
goes through.

### UI instead of typing

*"everything needs to have a nice UI since I dont want to type commands to find
what I need to start the event."*

**`EventGui`** — `/menu` → EVENT CLOCK. The three durations as steppers (no way
to type "6O minutes"), and every control a running event has: pause, resume,
skip ahead, ±5 minutes, stop. It says what will happen before you press start.

### Deleting the city asks twice, and the second ask moves

*"the remove city button shall have double confirmation... it says are you sure
you want to delete the city? and lists what is on it... another pop up will
happen and it will say LAST CHANCE TO CANCEL."*

Two things make it more than a nag:

1. **It lists what is actually out there**, counted from the live world: how many
   plots, how many claimed, how many blocks built, by how many people. "Are you
   sure" is answered by reflex; "12,406 blocks built by 9 people" is answered by
   reading.
2. **The buttons swap sides between the two steps.** YES on step two sits where
   CANCEL sat on step one, so double-clicking through by muscle memory lands on
   cancel. There is a check asserting exactly that.

### Backups say when they were taken

*"the backups need to be the full world backups. just to be sure with exact date
and minutes writen."*

Every capture already took the whole world — `sv_beginCapture` enumerates every
creation there is. What was missing was telling them apart. Now:

    auto2-2026-08-24_2247
    eventend-2026-08-24_2312
    manual-2026-08-24_2250

Alphabetical order is chronological order, which is what makes the list readable.

## V26 — the event clock, and four bugs off a screenshot

### The event has a shape now

    off  ->  prep  ->  build  ->  ended

**prep** is the point: people arrive and claim a plot, and nobody can build yet.
Twenty people racing to claim ground at the same moment they start building is
how you get a scramble decided by who loaded the world fastest.

Custom minutes for both. `/event start 10 60`, plus `pause`, `resume`, `skip`,
`add <min>`, `stop`, `status`. `/buildtime N` still works and is now an alias for
`/event start 0 N`, which is what it always meant — one clock instead of two.

**Deadlines are wall-clock, not ticks.** `os.time()` works here (the ban list has
been stamping entries with it all along) and the tick counter restarts with the
server, so a deadline in ticks is meaningless after a reload. The event survives
a restart with the right time left; there is a check for exactly that.

### The clock in the top right, and the handover

A json GUI with `isHud = true` — the four flags copied from NotificationManager's
own timer rather than guessed. Phase colour down the left edge, `MM:SS` or
`H:MM:SS`, and a line saying what you may do right now.

At five minutes it hands over to the **warehouse explosion timer**, which is the
engine's own:

    NotificationManager.Cl_CreateEventTimer( priority, "explosion" )

**Five minutes is not a round number, it is the right one.**
`survival_constants.lua:186` sets `WAREHOUSE_DESTRUCTION_TICKS = 40 * 60 * 5`, and
NotificationManager splits exactly that span into three escalating alarms — one
from 5:00, the next from 3:20, the last from 1:40. Hand over at five and they
land where the sound designer put them.

### Fonts: the game does not ship whole fonts

**MEASURED**, from a screenshot:

| we wrote | it drew |
|---|---|
| `HOST` | `⊠OST` |
| `YOU OWN` | `⊠O⊠ OW⊠` |
| `TOP DOWN` | `TO⊠ DOW⊠` |
| `YOUR TEAM` | `⊠O⊠R TEA⊠` |

All four in `SM_LabelMini`, whose glyph atlas is exactly
`0123456789ACDEILORSTVW`. Every missing letter is outside that set — five
strings, five exact matches.

Scrap Mechanic ships a **limited glyph atlas per font**, built from the strings
the game itself renders. A mod writes strings the game has never seen, so this is
a trap laid specifically for mods. And it is backwards from intuition: a font
name that **does not exist** is safe, because MyGUI falls back to a complete
font — which is the only reason `SM_Label`, `SM_HeaderSmall_Medium` and
`SM_NumberSmall` ever worked. The *real* fonts are the dangerous ones.

`dev/test_logic.py` now builds every panel and checks every caption against the
real atlas. It found eleven more broken captions in the settings panel the same
minute it was written.

### The host's buttons had no labels

`UpgradeButton` is a **progress bar**, not a button: it drew as a gold-and-teal
bar with no caption at all, so the two host entries on `/menu` read as broken
widgets and the host reasonably concluded the features were missing. They were
there and clickable the whole time. Now `StyledButtonLarge`, the skin CLOSE on
the same panel already proved draws its text.

### "The plot is not connected to the rest of the build"

Ground showing between a plot and the walkway beside it — on a city whose
geometry is *proved* to be a gapless partition. Geometry was never the problem;
timing was. The build cleared the old city and imported the new one **in the same
tick**, and `shape:destroyShape()` does not take effect until the tick ends. The
importer was being asked to place blocks into space the old blocks still
occupied.

There is a settling stage now — clear, wait, then import — and each shared-ground
import reports how many shapes it asked for against how many landed, so a hole
gets named in the log instead of noticed in a screenshot.

### /tool

Says exactly which item is in your hand, and names it if it is one of the ones
that matter. There are two lifts and they look identical in the menu; this is the
only way to tell them apart from inside the game.

## V25 — the lift, for real this time

### There are two lifts, and this game only had the wrong one

Third attempt, and the first one built on evidence rather than inference.

The game log prints the class every uuid resolves to at the moment a tool is
created. Ours said, in every single session:

    Created Tool 18 of type {8f190ce2-3a59-423e-8483-a7aa67bd5bc0(SurvivalLift)}

Two things follow, and both were believed otherwise.

**A Custom Game's toolset cannot override a uuid the base content declares.** It
can only ADD. First declaration wins and the mod's is loaded last. The proof it
is precedence and not a broken file sits in the same toolset: the nugdupS canary,
a uuid nothing else declares, resolves exactly as written. So V19's lift override
and V22's `GuardedClayRifle` / `GuardedPotatoLauncher` **never ran** — and what
actually stopped the clay gun was the client-side `forceTool` guard that shipped
in the same build and got none of the credit.

**The creative lift is a different item entirely.**

| uuid | class | declared by |
|---|---|---|
| `5cc12f03` | `Lift` | `Data/Tools/ToolSets/tools.json`, named `tool_lift_creative` at `ChallengeData/Scripts/game/challenge_tools.lua:2` |
| `8f190ce2` | `SurvivalLift` | `Survival/Tools/ToolSets/tools.json:44` |

`baseGameContent: "Survival"` loads `Survival/Tools/toolsets.json`, which never
lists the creative index — so this game had only the survival lift, and no amount
of Lua was going to change that. The blueprint menu the **E** key opens is
engine-side: `GarageImportGui` driving `Data/Gui/Layouts/Lift/Lift_Import.layout`.

The fix is one toolset entry adding `5cc12f03`, which is the case that provably
works. **Unconfirmed in game** — it is a strong inference from three independent
pieces of evidence, not a measurement.

### Find my plot

`g_compassHud` already exists in our game: `CreativeGame.client_onCreate` calls
`sm.gui.createCompassHudGui()` and we call that parent. So the compass needed
pointing at something, not building. Claiming a plot, `/home`, or joining an
event you already own ground in now puts a marker on it. It is that client's own
HUD, so nobody else sees it — *"only they can see it so it doesnt interfier"*
comes free.

### /myplot

Claiming was a typed command, run while standing in the right square, answered by
a line of chat that scrolls away. Now one panel: what you own, what you are
standing on, who is on your team, a live map with your plot in green — and
buttons to claim it, find it again, or give it up. The hint line under the
buttons says why CLAIM will not do anything when it will not.

`/players` marks the host, because "who has the buttons" is a fair question and
there was no way to answer it.

### Removed

`dev/check_uuids.py` now reads `baseGameContent` and indexes only the tool
databases that setting actually loads — which is what turns "this uuid exists
somewhere in the install" into the useful question, "does this uuid exist in
*our* game". It immediately found a second dead uuid: the creative sledgehammer
`ed185725`, which our settings had been gating for nothing.

## V24 — the lift, the city, and a test harness that runs the mod

### The lift finally has the right cause, and V19's was wrong

Reported twice: *"I cant use the lift to spawn creations"*. V19 blamed survival
owning uuid `8f190ce2` and pointed the toolset at creative's `Lift` instead.
**That diagnosis was wrong.** `SurvivalLift = class( Lift )` with exactly one
live method — `client_onUpdate`, calling `setBlockSprint` — and the rest of the
file inside a `--[[ ]]` block. It inherits every piece of blueprint handling
there is. V19 swapped a working class for an identical one.

The real cause was ours. Picking a creation out of the blueprint menu does not
hand the lift a picture of a build: **it spawns real bodies into the world,
marked as ghosts.** Vanilla proves it — `Lift.client_onForceTool( self, bodies )`
takes body objects and `Lift.sv_n_removeGhostBody` calls `body:destroyCreation()`
on one. So a ghost turns up in `sm.body.getAllBodies()` like anything else, and
the protection patrol reached it within a fraction of a second and pinned
`convertibleToDynamic = false` on it. **A ghost that cannot convert to dynamic
cannot become a creation** — silently, with nothing in the log.

`body:isGhost()` is a real binding (`python dev/dump_api.py Body`). Ghosts are
now invisible to everything the mod does: not protected, not counted in the
shape census that arms the grief alarm, not captured into a snapshot, not
counted against a plot's part budget, not caught by any of the clear commands.

### The city is built from the middle outwards

*"the city maker is broken since some stuff is overlaid. make sure you start
building from the middle and going out of it."*

The old builder ran a grid from a corner and then skipped the plots that hit the
spawn plaza. Two rules for one shape. Three confirmed defects:

- **every coordinate landed on a half block.** Ten plots of 20 with 1-block
  seams is 209 across, so centring put the origin at −104.5 and every child of
  every blueprint at `x.5`.
- **3 of 9 vertical seams were never built.** A full-height strip that crossed
  the plaza band was discarded whole instead of split, so the city had three
  full-length gaps in it.
- **rebuilding laid a second city on top of the first.** `sv_clearFloor` found
  city bodies by `worldPosition.z <= 1.5 m`, and a plot slab with a build welded
  onto it has its body position dragged above that. The slab survived the clear
  and the rebuild imported another one into the same space. That is what
  "overlaid" looks like.

Now the plaza is not a hole punched in a grid — it is the **first thing on the
axis**, sitting on the origin, with plots laid outwards from its edge in both
directions. A plot can never overlap the plaza because it never starts inside
one, not because something checked. Where the two plaza bands cross is spawn;
where a band crosses plots is a grand avenue running out to the city edge.

Clearing is now by **shape** against the three city uuids at deck height, which
is exact and leaves a player's build alone.

### One geometry, three callers

`Layout.lua` is new and holds all of it. It is pure — no `sm.*` calls at all —
so the Game script, the World script and the client panel all compute the city
from the same code. `PlotsGui` used to carry a hand-copied mirror of the axis
under a comment reading *"the panel has to lay the city out the same way the
builder does or the map is a decoration that lies"*. It drifted, and the map
lied. The copy is gone.

Teaming now follows the seam rather than the grid: two plots may team up only
when the ground between them is a **filler**. A road between them, or the plaza,
means there is nothing to share — and that falls out of the segment list instead
of being a second rule to keep in step.

### Teams chain; links do not

*"the teams shall only be able to team if the plot is either behind, front, left,
right. nothing in between. unless another teammate connects."*

Half of that already held — a link was already refused for anything but an
orthogonal neighbour with a shared filler. The other half did not: teams were
**pairwise**, so A–B and B–C left A and C strangers.

A team is now the connected component over the link graph. A diagonal plot is a
teammate exactly when somebody links you both, and not otherwise. A filler is
shared across the whole team rather than only between two plots that exchanged a
request, so a ring of four teammates no longer has a locked strip through the
middle of its own land. Leaving cuts everyone who was only reachable through you.

Refusals now say which rule you hit — "corner to corner does not count", "too far
apart", "there is a road between you" — because "not a neighbour" is the one
message people argue with, and diagonal *looks* adjacent.

The city map paints your plot bright green and your team dark green, since a team
is a shape you cannot work out by looking at the grid.

### The mod can now be tested without the game

`lupa` embeds a real Lua interpreter, so the mod's own code can be executed
outside Scrap Mechanic.

- **`dev/test_layout.py`** runs `Layout.lua` over twelve configurations and
  rasterises every block of every piece: no block claimed twice, no gap, no
  fractional coordinate. This is the check that would have caught the overlay.
- **`dev/test_logic.py`** runs `Settings`, `Identity`, `Protection` and `Plots`
  against small honest stubs — 22 checks covering who may build where, whether a
  ban survives a restart, whether the profile sentinel still tells all five
  profiles apart (the V15 bug), whether the lift can ever land in the hazard list.

Neither can tell you anything about bodies, tools, GUIs or the network. Those
are still in-game work, and both files say so.

## V23 — one central pillar, roads, 2D map, /menu
- Plots lost their pillars. The deck is static and needs no support; 100 columns
  read as clutter. The city is one raised platform on its centre.
- **Roads** became a first-class thing, distinct from fillers. A filler is the
  one-block seam shared by two teamed neighbours; a road is a public street.
  Forced the grid off a uniform stride onto an explicit segment run with prefix
  sums. Verified 0 overlapping cells.
- The city panel draws a **top-down map** from the same axis function the builder
  uses, so it cannot drift from what gets built.
- `/menu` — the front door. Guests see only what they may open.

## V22 — disable the TOOL, not the item
- **MEASURED:** `took firelauncher from CyberSlime2077` ×12 in one second while
  the player stood holding it. **A creative inventory is infinite**
  (`enableLimitedInventory = false`), so stripping a slot refills instantly and
  reports success forever. That loop was also the chat spam.
- Clay gun and fire launcher now point at **subclasses of their real scripts**
  with the fire buttons swallowed. Subclass, not replace, so the setting still
  means something.
- A locked world forces every hazard tool off regardless of the panel.
- Found: `ClayRifle.client_onEquippedUpdate`'s 4th arg is `forceBuildActive`.
  **F is readable inside a tool script.**

## V21 — banned tools taken from the inventory
Superseded by V22. `forceTool( nil )` only *unequips*; the player picks it
straight back up.

## V20 — the lift is host only
`hostlift`, default on. The lift spawns whole saved creations, which is right for
a host and wrong for a lobby.

## V19 — give back the creative lift
- **Survival content wins a shared uuid.** `8f190ce2` resolved to `SurvivalLift`,
  which has no `sm.player.placeLift` and no blueprint handling — so the lift could
  not spawn creations, silently, with no error.
- Our toolset re-declares the uuid pointing at `$GAME_DATA/Scripts/game/Lift.lua`.
- Second instance of this class of bug; the first was `Sledgehammer` reading
  `clientPublicData.perks`.

## V17 — /purge look and /purge carry
Carryable props (gems, crates, harvestables) get *picked up* by the remove tool
rather than erased. `/purge look` raycasts and destroys what you point at.

## V16 — city layout panel, hazard tools bind the host
- `/plotmenu`, showing what the numbers mean before building anything.
- **The clay gun kept working because the HOST was exempt.** Hazard tools now
  bind everyone.

## V15 — the sentinel that made lockdown and show identical
- **Reported:** buttons still worked in lockdown. `matchesProfile` compared only
  `buildable` and `destructable`, which `locked`, `display` and `sweep` all share
  — so switching between them found every body "already correct" and applied
  nothing. Four flags now, verified unique by enumeration.

## V14 — destructibility is a setting
`destructable` was pinned false in *every* profile including open, so explosives
could never do anything even when enabled. Now follows `destructible`, but only
in open mode: a locked world stays locked.

## V13 — settings take effect, not just display
- **MEASURED:** `setting fire = false` logged, `Settings.json` written, no errors,
  nothing changed in the world. `Settings.Sv_Set` runs apply hooks from the **Game
  script**, and `sm.fire.setFireLimit` is world-dependent and threw — into a
  `pcall` that swallowed it silently.
- The world re-applies on `/settingschanged`. A failing hook now logs.

## V12 — /why, debris vacuum, tighter scenery test
- `/why` reports a body's zone and every permission flag. Three rounds of guessing
  why a lift would not work is two too many.
- Scenery detection required only "metal near the ground", so anyone building in
  metal had their creation classed as city and locked.
- `sm.debris.createBlackHole` vacuums explosion debris.

## V11 — settings panel buttons work
- **MEASURED:** `Unknown member 'open' in userdata`. A json GUI has no `open()`,
  the same way it has no `destroy()`. `render()` **is** the show.
- The onClick signature is `( self, widgetName, data )`, not `( self, data )`.

## V10 — the panel reopens; tool guard moved to the client
- **MEASURED:** `Unknown member 'destroy' in userdata`. One CLOSE press made the
  panel unopenable for the rest of the session.

## V8 — a real settings panel
The first version stretched `BackgroundPromptNarrow`, a 346×346 alert skin, over
660×560. Rebuilt at 1120×690 — `Handbook.gui` scale. The useful discovery:
`Widget + Skin WhiteSkin + Colour` is a tintable rectangle, so a whole panel can
be drawn with no bespoke texture.

## V5–V7 — the city
Built as a blueprint and imported, not block by block: blueprint children carry
`bounds`, so a 20×20 plot is **one shape, not 400**. Each plot imported separately
so `getCreationsFromBodies` does not collapse the city into one creation.

## V2 — the three bugs the first real run found
- **MEASURED:** `Calling world dependent functions in a no world script!` — a
  Game script has no world; `sm.body.*` cannot be called from it. Protection,
  Plots, Rules and Snapshots moved to `World.lua`.
- `/help` is a reserved command name.
- `Sledgehammer.lua:193` — `clientPublicData.perks` nil, the first Survival +
  Creative pairing bug.

## V1 — first build
2,638 lines, compiled, installed, never executed. Everything above is what
happened when it finally was.
