# Changelog

The version is on the mod thumbnail, so a host can tell which build a machine is
running from the Custom Game list without opening a file. `VERSION` holds it —
**not** `description.json`, whose `version` is the game content version and must
stay `1` for a Custom Game on this build.

Bugs below are marked **MEASURED** where the game log named them outright, which
was most of them.

---

## V59 -- the first session driven from outside the game, and the two bugs it found

V58 built the bridge. This is what happened the first time it carried a real
session, and it is the best argument for the whole idea: **two bugs in an hour,
in features that had been shipped for weeks and never once run.**

### THE PLAZA-SHAPED HOLE

REPORTED, with a screenshot, thirty seconds after the first restore ever run in
this project: *"the load back in WORKS! the issue is the middle doesnt"*.

The restore said **`195 creations, 0 failed`** and left a hole where the plaza
had been. Those two facts are not a contradiction, and the reason is the whole
lesson:

- `sv_beginRestore` cleared the world and the driver stepped on the **very next
  tick**, four creations at a time.
- `shape:destroyShape()` does not take effect immediately -- the engine tears
  shapes down at the *end* of a tick.
- So the first four creations were handed to the importer while the old blocks
  were still standing in that space. What lands in occupied space is anybody's
  guess; here the answer was nothing.
- **The plaza is entry one in every snapshot**, which is why it is the middle
  that vanishes and nothing else.
- `importFromString` reports success either way, so all 195 counted as fine.

**The city builder already knew this.** `World.CITY_SETTLE_TICKS` exists for
exactly this hazard and its comment describes the same symptom -- *"brown ground
showing between a plot and the walkway beside it"*. The fix never travelled to
the other place that clears and rebuilds, and nothing noticed, because restore
had never been run.

Restore now waits the same 20 ticks, and a check asserts the two waits stay in
step so they cannot drift apart again. Written by putting the bug back: it
reports *"6 creations were imported into space the old world still occupies"*.

**Confirmed fixed, same session:** 195 bodies back, and the profile breakdown
reads `locked 99, open_destructible 96` -- 99 deck creations *including the
plaza*, where a hole would have shown 98. The import count was never the
evidence; it said 195 while the plaza was missing.

**A whole-city restore takes about a second.** That was never known, and it is
what makes `/restore` usable as a panic button in the middle of an event.

### /lockdown DID NOT BLOCK THE LIFT, AND NEVER GAVE ANYTHING BACK

REPORTED: *"I still could use the lift, and the clay gun. look make sure that
thing works. the lockdown"* and *"the lockdown shall block EVERYTHING"*.

Two faults, both real, both found by reading the code the report pointed at:

1. **The lift was never in the list.** `/lockdown` turned off exactly four
   things -- clay gun, fire launcher, cornades, extinguisher. Not the lift, the
   sledgehammer, the paint tool, the weld tool or NOTlift. A locked world could
   still have whole creations carried around in it.
2. **`/unlock` never restored them.** Lockdown worked by *writing the host's
   settings false*, and unlock had no memory of what it had changed. **One
   lockdown disabled four tools permanently** and the only way to notice was to
   find them missing later. The owner's live `Settings.json` had `claygun
   false` from a lockdown rather than from a choice.

Both have the same root, so both go away the same way: **the blocked set is
derived from the protection MODE instead of being written into the settings.**
Nothing is remembered, so nothing has to be restored, and unlocking returns to
whatever the host actually chose.

A locked world now blocks everything except two, and both exceptions are
load-bearing:

- **the cleaner**, because it is the only thing in the game that can remove a
  dropped craftbot and the world stays locked BETWEEN events -- take it away and
  every piece of dropped litter is permanent. That rule has already cost three
  separate fixes.
- **focus**, because it changes nothing in the world; it draws on screens.

And it now binds **the host too**. The host keeps every build tool normally --
that bypass is so whoever runs the event can place and clear things -- and it
stops applying the moment the world is shut, or `/lockdown` stops the lobby and
not the person who called it.

**What is still not explained.** The clay gun should already have been blocked
for the host: the setting was false and the host guard list contained it. The
code alone does not explain how it got through, so rather than guess, two things
changed. `/tool` now prints the server's own view -- whether the world is shut,
what is blocked for the host, what is blocked for a guest -- so the next test
says which half is lying. And the guard **repairs itself**: the tool guard is
client side (`sm.tool.forceTool` is client-only, so the server can see what you
hold and cannot put it away), which makes the client's copy of the list
load-bearing, and a client whose copy arrived empty enforces nothing while
looking perfectly healthy. The server now re-sends the list the moment it
catches a blocked tool in a hand -- one message in exactly the case where
something is already wrong.

Five checks, all written by putting the bug back, including *"the host keeps
their tools in a lockdown"* and *"the cleaner is taken away, litter made
permanent"*.

### What else the first bridge session established

- **The grief alarm fired, by itself, for the first time.** `/plotclear` tripped
  it: *"\*\*\* 678 blocks have disappeared \*\*\*"* in chat, unprompted. An item
  that had never been tested passed by accident. It also means **a host clearing
  their own city trips their own alarm** -- the rebuild silences it, the clear
  does not. Noted, not yet fixed.
- **`PhysicsQuality` is 9** on this machine. The closest thing to a simulation
  knob this project has found, and nobody had ever read the value.
- **An empty claimed plot really is locked** while every unclaimed one stays
  open -- `locked 100, open_destructible 95` with one plot claimed. V46's rule,
  confirmed for the first time, from the profile breakdown rather than by hand.
- **The log was silent all session.** Zero Lua errors, zero tracebacks; the only
  warnings are vanilla's own texture and particle ones.

### Two things that are not bugs but will bite at an event

- **Nothing that is not resting on a plot has anything holding it up.** Clearing
  the city removed the ground under a creation the owner had just imported and
  it fell out of the world. `/restore` deletes the world first, so at an event
  anybody's build survives a rollback only if it is in the snapshot.
- **A creation on a lift is not in the snapshot.** Deliberate -- a blueprint
  somebody happens to be holding must not be saved into the world and spawned
  for real later -- but it means "snapshot everything" has an exception worth
  knowing before relying on it.

### Smaller findings, recorded and not fixed

- **`/protection`'s "shapes in world" is stale after a mass deletion.** It read
  676 with the world empty. Misleading for exactly the host who is checking
  whether a clear worked.
- **The `where the city landed` census runs a moment too early.** It counted 191
  of 195 bodies; a forced sweep immediately afterwards saw all 195. The four
  missing are a timing artefact of the line, not missing bodies -- but that line
  is what the checklist tells you to trust.

---

## V58 -- the bridge: a running world can be driven from outside the game

Asked for as *"we can make you dirrectly connect to the game?"*, after the owner
put their finger on what is actually slow here:

> *"this is wildly inefficent because we two have different thoughts on how
> something is supposed to work."*

Both halves of that are true and they need different answers. The round trip --
write a change, load a world, try it, come back and describe it -- is what this
version removes. The other half, two people meaning different things by the same
sentence, is not a testing problem and nothing here fixes it; that is what the
plain-English *IT WORKED IF* line on every checklist item is for.

**In the game, once:** `/bridge on`. **From outside:**

    python dev/bridge.py /protection
    python dev/bridge.py "/set plots on" "/plot claim" "/why"
    python dev/bridge.py --wait 30 /plotbuild
    python dev/bridge.py --status

A file appears in the mod's own folder, the mod runs it as the host, and
everything said for the next second and a half comes back as a transcript.

### The one thing that could have killed it, designed out rather than tested

The engine keeps compiled copies of the data files it reads -- MEASURED,
2026-08-23: every `.rco` in the mod's `Cache/` was stamped hours before the
`.lua` it came from. If `sm.json.open` serves a cached copy, a channel built on
rewriting one file would answer the first command forever and nothing would say
why.

**So no file is ever read twice.** The sequence number is in the *filename*:
`Cmd-7.json`, then `Cmd-8.json`. A path that has never been read cannot be a
stale read, which turns an unknown that needed an experiment into a property of
the design. What is left is `fileExists` on a path that did not exist a moment
ago; if that turns out to be cached too, the fix is one line and
`Bridge.sv_poll` is written so that it is the only line.

### The capture closes on a CLOCK, not on a call

The part that would have made it look broken for half the mod. A world command
does not answer while it runs: Game hands it to the world as an event, the world
deals with it on its own tick, and the reply arrives through `sv_e_swReply` some
time later. A capture that closed when the call returned would have caught every
reply from `Game.lua` and almost none from `World.lua` -- which is `/plot`,
`/why`, `/budget`, `/protection`, `/purge`, `/snapshot` and the entire city.

So a batch runs, and then *listens* -- 1.5 seconds by default, up to 120 for
something slow like building a city. Everything said in the window is the
transcript.

### Why it is safe, in four rules

It is a remote control for a game server, so:

- **Off unless switched on.** `bridge` is a setting, default false, and while it
  is off the poll does not run at all. `allow_add_mods` is false in this mod
  because the mod list is the trust boundary; this is the same argument pointed
  at a file.
- **Host only**, to switch on and to run. Every command goes through the same
  dispatch a typed one does, *as the host player*, so the bridge can reach
  nothing the host could not type and every existing host gate still applies.
- **Its own `pcall`**, separate from everything else on the tick. A control
  channel must never take the server down, and a fault elsewhere must never
  leave a batch half-run -- the same separation `/crowd` and `/bench` have.
- **Loud.** Every command is written to the log *before* it runs, so a session
  driven from outside reads back exactly like one driven by hand. The setting
  persists, so a world that comes up with the bridge open says so in the log at
  create time. A door left open is fine; a door left open quietly is not.

### Seven checks, five of them mutation-tested

| the bug put back | the check that caught it |
|---|---|
| the bridge on by default | shut unless somebody opens it |
| one fixed filename, so reads could go stale | never reads the same path twice |
| a malformed file left on the same number | a file it cannot use does not wedge it |
| world replies not reaching the capture | every reply funnel tells it |
| the tick driven without a `pcall` | runs inside its own pcall |

The third of those is a bug this found in itself: a file that exists but is not
a command file used to leave the sequence number where it was, which would have
polled the same bad file twice a second for the rest of the session -- and from
outside that is indistinguishable from a bridge that is on, listening, and
ignoring you.

### What it does not reach, and will not

- **A second player.** Everything runs as the host, and the host is authorised
  everywhere on purpose. The eleven `needs a guest` items are untouched.
- **A tool, a key or a button.** No `F`, no held tool, no GUI click.
- **The screen.** Colours, layout, whether a marker looks right -- all still
  need eyes.
- **A bot as a stand-in for a person.** Bots can hold a plot open and can never
  lock one (`Plots.lua`: they are deliberately kept out of the push-out list,
  because pushing needs a real `Player`). And a bot's blocks go in through a
  script import that ignores permission flags entirely, so a bot "trying to
  build" on a locked plot succeeds regardless and proves nothing. The useful
  pairing is the bot as hands, the flags and the log as eyes.

---

## V57 -- the checklist is in the game now, where the testing happens

Asked for as *"you make an ingame check list. for devs. so I can test stuff. if
something doesnt work I can exactly test it and then write result like did it
work yes or no. because if I have to switch every time here. I waste my time if
the feature is still broken on writing it again."*

That cost is real and it is the reason `docs/STATUS.md` reads the way it does.
Every red line in it has to be turned green by somebody standing in the world
doing the thing -- and until now the only way to record the answer was to alt-tab
out and type it. So the answers were mostly never recorded at all, and the
ledger is written days later from memory.

**`/check`, or DEV CHECKLIST on `/menu`.** Eighty-three items, grouped in the
order to run them in, each with what to do, what counts as a pass, and the log
line that settles it. Answer with one click. It writes
`$CONTENT_DATA/Checklist.json` immediately, and `python dev/checklist_report.py`
reads it back out on this side.

| | |
|---|---|
| the list | eleven groups down the left, eight rows a page, PASS and FAIL on every row |
| an item | the steps, the pass condition, the log line, a note box, and BLOCKED / SKIP / CLEAR |
| **NEXT UNANSWERED** | walks the whole catalogue in order and stops when there is nothing left one person can answer |
| **RUN IT** | fires that item's own command -- `/protection`, `/crowd 5`, `/set maxjoints 10` -- through the ordinary host-gated path |
| `/check next` | the same walk from the chat box, when your hands are already there |
| `/check summary` | the counts and every failure by name, to chat **and** to the log |

### Nothing on the panel sends you to a log file

REPORTED, while the first version of the list was being read:

> *"so that there are only things I can directly test in games since I dont want
> to go in logs to test something. since stuff like that you can basicaly do
> your self."*

Right, and it is not only a preference. Reading a log happens afterwards, from
outside the game -- so an item that needs one cannot be answered by somebody
standing in the world with the panel open, and it stalls the walk through the
list.

**`/why` is what made the rewrite possible**, and it was already there. Point at
anything and it prints, to chat: the zone and its plot number, the protection
mode, whether `buildopen` is on, whether the body is a ghost or on a lift, and
all eight permission flags. That is every fact the log lines were being consulted
for. So:

| was | is now |
|---|---|
| *read the line the city prints* -- the most important item in the list | stand on a pad, point down, **`/why`** -> `zone: plot 34` |
| *read the phase line, 96 open* | during build, `/why` on your own plot -> `buildable=true` |
| *read the four opening lines* | `/protection` answers at all, which is the same proof `World.lua` loaded |
| *read the gui canvas line* | open `/settings` and look at whether its bottom row is on screen |
| *it announces and arms lockdown* | chat says `*** N blocks have disappeared ***` |

Two items have no on-screen form at all, because the engine writes them to the
log and nowhere else: **a quiet log** and **the per-client network budget**.
Those carry `who = "log"`, are off the panel entirely, and are answered from this
side with `python dev/checklist_report.py --set <id> pass`. One ledger, two
halves, and the panel stays a list of things a person in the world can actually
do. Two checks hold the line -- no panel item may mention a log, and no log item
may appear on the panel.

### What BLOCKED means, on the panel itself

Asked outright, which means it was not obvious, which means it needed to be on
the screen rather than in a document:

    PASS worked   FAIL did not   BLOCKED could not try   SKIP not now

**BLOCKED is not FAIL.** It means the answer is still owed -- nobody else was
online, the city would not build, an earlier item failed and this one needed it.
**SKIP** means it is not: you could have tried and chose not to. The distinction
matters because the report chases blocked items and lets skipped ones lie.

### Four things in the list described a mod that no longer exists

REPORTED: *"some things are just olden. like not up to date like use clear city
but we removed that. find all the outaded things and remove them. I want to have
the list that is possible now."*

All four had the same shape -- an instruction inherited from a DOCUMENT rather
than read out of the code:

| the list said | what is true |
|---|---|
| `/purge walkways` | removed on the owner's instruction, together with the SWEEP LITTER button that ran it. `/purge` takes look, carry, plot, here |
| `/set maxparts 105` | **there is no `maxparts`, and there never was.** `Rules.lua` enforces `maxjoints`, `maxbots` and `maxlights` and nothing else -- there is no per-plot block budget at all |
| all the limits are off | they are 10 bearings, 1 craftbot, 25 lights by default. What is off is `plots`, and nothing is enforced until that is on |
| `/citystyle brutalist` | real, but the owner had already said they disliked it. `arctic` now |

**The second one had been repeated in `docs/NEXT.md` as the headline
recommendation of the whole project**: *"`/set maxparts 105` is now a defensible
number rather than a taste call."* It was a defensible number for a setting that
does not exist. `CLAUDE.md` was offering the removed SWEEP LITTER button in the
same way. Both are corrected, and whether a per-plot BLOCK budget should exist
at all is now an open decision rather than an assumed feature.

### The check that stops it happening again

`everything_the_checklist_tells_you_to_type_still_exists` reads the mod and
asks whether each instruction is still possible:

- every `/command` is one `bindChatCommand` actually binds
- every `type /x y` step has a `y` the handler for `x` still accepts --
  subcommands pulled out of `sv_plotCommand`, `sv_eventCommand`,
  `sv_crowdCommand` and the `/purge` branch by reading their source
- every `/set key` is a key in the settings schema, which is executed rather
  than parsed
- every ALL-CAPS phrase is a caption some panel really draws
- every RUN button would type something real

**None of the valid values are written down in the check.** A hardcoded list
would go stale in exactly the way this exists to prevent, and it would go stale
silently. Five mutations were used to build it -- the removed purge target, the
never-existent setting, the removed button, an unknown city style and an unknown
plot subcommand -- and it catches all five.

It also caught its own first version reading a step boundary as an argument, and
accusing `/citystyle` of not taking `look` -- the word that started the NEXT
step. Steps are scanned one at a time now.

### Written for the person holding the mouse, not for the person who wrote it

REPORTED, on reading the first version:

> *"can you make it like simpler to understand and use? I dont know exactly how
> the code works and some things are just too complex for me."*

Fair, and the first draft was indefensible: items said things like *"any sweep
where a plot should be means V46's fix did not take"*, which names a version
number, an internal word and a function, and tells the reader nothing they can
do. All eighty-three were rewritten:

| was | is |
|---|---|
| The plots land as PLOTS, not as filler | The game knows a plot is a plot |
| 96 bodies come out 'plot'. If plots land as filler then sv_bodyZone is wrong | the reply says zone: plot and a number. If it says filler, STOP AND TELL ME -- the plots are in the wrong place |
| over budget stops placing and nothing else -- the trim profile | You can still REMOVE things while over the limit |
| PASS / FAIL / BLOCKED / SKIP | IT WORKED / IT DID NOT WORK / CANNOT TRY IT / SKIP IT |
| WHAT TO DO -- IT PASSES WHEN | DO THIS -- IT WORKED IF |
| BOOT, PROTECT, ADMIN, LOAD | START UP, LOCKING, BANS, FAKE CROWD |

Every item now ends in something visible: a chat reply, a block that does or
does not go down, a marker on screen. Where a failure has a known cause worth
reporting, the item says *tell me* rather than naming the function.

### And a font rule the panel is now held to

The game builds a limited glyph set per font from the strings it renders itself,
and a character outside it draws as a hollow box -- MEASURED, `SM_LabelMini`
drew `HOST` as `(X)OST`. The fonts here have no declared limit and mixed case
and digits are known good, but **punctuation has never been measured**, and the
checklist is by far the most text this mod has ever drawn.

So a check computes the characters the already-shipped panels draw and asserts
the checklist stays inside them. It immediately found an apostrophe in four
items and `%`, `*`, `;`, `?` and brackets elsewhere -- none of which any panel
in this mod had ever asked a font for. The set is computed rather than written
down, so it grows on its own the day another panel draws something new.

### Why a result is written on the press and not at the end

A test session ends when the game crashes or when somebody stops playing.
Neither runs a shutdown hook, so anything held in memory is exactly the data
that would be lost by the failure it was recording. Every press writes the file
and writes a line to the log -- which means a FAIL and the traceback that caused
it end up a few lines apart in `game-*.log`, where every other piece of evidence
in this project already lives.

### The results file is the one thing a new world must NOT clear

Every other state file here describes a WORLD, and `sv_newWorldReset` exists
because a fresh world inheriting the last one's claims is a real bug that was
reported. The checklist is the opposite case: it records what the CODE did, and
making a fresh world is the usual way to test something. Wiping it at world
create would delete the session that was being recorded, every time. A check
asserts `sv_newWorldReset` never touches it.

Each result carries the build it was recorded against, and the panel shows that
build in dim text when it is not the current one. A PASS from V56 is still a
PASS; a result whose provenance is lost is worth less than no result.

### The check that was passing for the wrong reason

Each item may name the log line that settles it, and a check asserts the mod
actually writes that line -- otherwise the instruction sends somebody looking for
something that was never there.

**The first version of that check searched every script in `mod/Scripts`,
including `Checklist.lua` itself, and passed.** Four of the cited lines existed
nowhere but in the catalogue quoting itself: `event prep`, `event build ->
protection open`, `[ServerWorks] new world` and `[ServerWorks] ALARM`. The real
literals are `[ServerWorks] event`, `[ServerWorks] NEW WORLD` and
`[ServerWorks] GRIEF ALARM`. A check that reads its own answer back is not a
check, and this is the second time this project has written that mistake.

### Sixteen new checks, eight of them mutation-tested

`dev/test_logic.py` is at **164**. The eight that were written by putting the bug
back and watching them fail:

| the bug put back | the check that caught it |
|---|---|
| `Checklist.BUILD` left at 55 | it knows which build it is |
| an item citing a log line nobody writes | every log line it cites is one the mod writes |
| a RUN button offering an unbound command | every command it offers to run exists |
| NEXT walking a solo host into a guest item | it walks every item exactly once |
| the note dropped when the answer is given | a note outlives the answer it was written for |
| the panel grown past the canvas height | the panel fits for every item and every page |
| a result kept only in memory | answering writes the file at once |
| `sv_newWorldReset` clearing the results | a new world never clears it |

### The hub menu is one entry taller

Nine entries plus the HOST header do not fit at the old 58-pixel pitch -- the
ninth lands on top of CLOSE. The pitch is 54 now and the panel is the same
height, because the canvas is about 720 tall and a taller panel would put its
own footer off screen. The layout check computes that rather than trusting the
eye; it caught this exact panel overflowing when the EVENT CLOCK entry was added.

---

## V56 -- the focus tool: point at one person, the whole lobby finds them

Asked for as *"an admin tool. with the tool you can search for nicknames that
are curently on the server. and when selected it will highlight them. so people
can see the focus person. usefull for event stuff."*

Three ways in, one piece of state, one marker.

| | |
|---|---|
| **Focus** | a new tool. Aim at a player and click. Aim at nothing and click to open the list. Hold **F** to clear. |
| **FOCUS PLAYER** | a new host entry on `/menu`: everyone online, one row each, a search box, a FOCUS button per name |
| `/focus <name>` | and `/focus off`, `/unfocus`. Multi-word names work -- same rejoin the `/kick` parser already uses |

A focused player gets a billboard over their head drawn **through walls at any
distance**, their name in world text under it, an icon on the game's own
compass, and a FOCUS line on the top-left roster panel. Everybody sees all four.
One person at a time: focusing somebody replaces whoever was focused before, so
there is no way to leave stale markers standing across the city.

### The engine already had all of it, in five places

Nothing here is invented. Every call is copied from a vanilla file that does the
same job:

| what | vanilla |
|---|---|
| a marker over a character | `sm.effect.createEffect( "EnemyMarker", character, nil, sm.effect.axis.all )` -- `BaseEnemyCharacter.lua:16` |
| lifting it clear of the head | `setOffsetPosition( vec3( 0, 0, character:getHeight() ) )` -- same file, `:17` |
| a compass icon that follows a person | `compassSetIconHost( name, character )` -- `:25`, `RaidManager.lua:981`, `WorldMarkerManager.lua:285` |
| text in an effect, set at runtime | `setParameter( "TextContent", str )` on `RaidMarkerNear` -- `RaidManager.lua:1539` |
| a raycast that hits a player | `result.type == "character"` then `getCharacter():getPlayer()` -- `Feeder.lua:218`, `RayProjectileManager.lua:29` |

The one number that mattered was **`maxRenderDistance`**. Vanilla's `EnemyMarker`
stops at **26 metres**, which is useless across an event city; `QuestMarker_Far`
is **1000000**, with `behindFadeAlpha 0.6` so it draws through geometry. Those
are the numbers our own effectset uses.

### The first effectset this mod has ever shipped, and it has a fallback

`mod/Effects/Database/EffectSets/serverworks.effectset` declares
`ServerWorks - Focus` and `ServerWorks - FocusName`. 87 Workshop mods ship an
effectset and the Empty Custom Game template includes the folder, so the
mechanism is real -- but nothing here has run one, and **`createEffect` on a
name the engine does not know throws rather than returning nil**. So the pcall
IS the existence test, and the last name tried is `QuestMarker_Far`, which is
base content. Worst case the marker is a vanilla quest diamond with no name
under it. There is no case where this errors per frame.

`dev/check_uuids.py` now resolves effects too. It had never looked at them,
because **effects are named by string and not by uuid** -- the entire uuid scan
was blind to them. It also resolves every texture our effectset names and the
compass icon.

Getting there meant teaching `strip_comments` the three ways the game's own JSON
is not JSON: `//` lines, `/* */` blocks, and trailing commas. Five of the game's
forty-odd effectsets use one of them, and refusing those files would have meant
reporting an effect that plainly exists as missing.

### The marker is drawn from World.lua, and that is not a style choice

The compass turns a position into a bearing, so it needs a world, and a Game
script has none. MEASURED, and it is the whole reason `PlotMarker` moved:

    WARNING: compass marker unavailable: PlotMarker.lua:72:
             Calling world dependent functions in a no world script!

Going via the player script gave the same warning verbatim. A check now asserts
that `Game.lua` touches neither `g_compassHud` nor `sm.effect.createEffect`.

### The search box, and the crash it was written around

The event clock crashed the game **twice** over typed input, and the second
crash came after the redraw had already been deferred by a tick -- so deferring
is not known to be enough. The surviving rules are one `EditBox` per panel and a
text handler that touches no widget at all.

So searching is a **server round trip**: Enter sends the query, the server sends
the whole panel back filtered, and the tree is rebuilt from a network callback
rather than from inside the text callback. One tick slower, and it cannot crash.
Paging stays local through `cl_renderLater`, which `ConfirmGui` already does
from its own click handler.

`FocusGui.Filter` passes `plain = true` to `string.find`, because a Steam name
may contain `%`, `[` or `-` and all of those are Lua pattern syntax -- without
it, typing a bracket does not return no matches, it throws and takes the panel
with it. A check searches four names full of punctuation.

### Smaller things

- **The roster HUD grows.** The focused name is a third row on the top-left
  panel rather than a HUD of its own -- that panel already exists, already sits
  where a host looks, and already redraws once a second. `RosterHud.Height`
  feeds the position arithmetic, because a root widget's x,y is its CENTRE and a
  panel that grows without saying so is placed as if it were still short.
- **A marker never outlives its target.** There is no player-left callback on
  this class, so the focus is validated on the same once-a-second beat as the
  roster. A client that joins mid-focus is told two seconds later -- during the
  join its world script does not exist yet, so a push then would land nowhere.
- **Host only, with no switch at all.** Five gates -- the tool's client half,
  its server half, the Game bridge it talks through, the panel action and the
  chat command -- and every one is `sm.player.getHostPlayer()` with nothing in
  front of it. `HOST_ONLY.focus` is the literal `true` rather than a settings
  key, so the tool is also pulled out of a guest's hands by the guard.

  Deliberately **stricter than the other three host tools**. `hostcleaner`,
  `hostlift` and `hostnotlift` all let a host delegate a tool that changes the
  WORLD, where that tool's own server-side rules still apply. A `hostfocus`
  would have been worse than useless here: it could only ever have opened the
  TOOL, because the panel and `/focus` are gated outright -- so a guest would
  have got a marker they could place one way and not the other. The check turns
  every boolean setting off and asserts focus is the only entry left in the
  guard. `focus` still removes the tool from everybody, host included, and
  `focusname` turns off the in-world text if the glyph atlas mangles a name.
- **Crowd bots are not in the list and the panel says so.** They are units, not
  players; `getAllPlayers` does not return one and there is no `Player` to find
  a character through.

### A panel check that verifies coverage cannot verify KIND

The focus panel shipped its first draft 620 tall, and every existing check
passed: `panel_fits` said every widget was inside the panel, `no_button_is_buried`
said no two buttons collided. The status line was drawn **on top of the page
counter** anyway -- the footer rule sat at `H-78` while the pager row ran to
562. Everything was inside the panel; the wrong things were in the same place.

Same shape as the road-seam bug written up in CLAUDE.md -- the partition was
intact, `dev/test_layout.py` checked overlap, gaps and fractional blocks and all
of them passed, and a one-block strip of the wrong MATERIAL still ran the height
of the city through every road. A suite that verifies coverage does not verify
kind. The panel is 660 tall now and a check walks every pair of text and button widgets across five
states. Reverting the height fails it by name.

Two things it found on the way, both left alone as out of scope: `SettingsGui`
draws its `Hint` text box from x 256 to 916 with the BACK button at 834, and the
same on the paged variant with PREV and NEXT. Nothing visible today, because the
hints are short and left aligned -- but a longer hint would run under a button.

### CONFIRMED IN GAME, same day: *"thanks it works!"*

A screenshot of the marker over the host's own head, their name under it, and
the compass icon with a `1m` readout beside it. Three things at once, and the
middle one settles the risk this entry opened with.

**The name is the proof the effectset loaded**, and the reasoning is worth more
than the result. `Focus.bind` only attempts the name tag when the marker
resolved to `MARKER_EFFECTS[1]` -- our own effect. The vanilla fallback
`QuestMarker_Far` has no `text` element and never gets one. So a visible name is
not merely *consistent with* our effectset loading; it is **unreachable unless
it did.** A fallback chain whose fallback is visibly poorer than the real thing
is a free experiment: the screenshot says which one fired, with no logging and
no second session.

It also settles the in-world font question outright. `SM_Header` drew
`CyberSlime2077` -- mixed case and digits, a string the game has certainly never
rendered itself -- clean. **The font tiers apply to 3D text as well as GUI
text**, which was assumed and is now measured.

Still unrun, and [`STATUS.md`](STATUS.md) has the full list: **anybody but the
host seeing it** (one machine, no guest -- and this is the one feature whose
entire purpose is what other people see), the marker through a wall or at range
(the compass read `1m`), the whole panel, clearing, and two of the three doors
in.

---

## V55 -- a lobby of bots, and the harness that became the load

The question was *"we need to start testing the mod optimitsation for players.
the issue is... we dont have real players. how can we have many players. without
actual people?"* The answer is [`CROWD.md`](CROWD.md); this entry is what broke
along the way.

### The three measurements that came out of it

**The server does not die.** `/bench` walked a crowd from 0 to 128 characters and
195 to 2,102 bodies. The tick rate never left 40 Hz -- not once, at any size. The
premise this whole project started from, that Scrap Mechanic hates a lot of
players, is not what this owner's hardware does.

**One character costs about 24 shapes of frame time.** Two benches, same steps,
one in `build` mode where the world grows with the crowd and one in `churn` mode
where it does not. Subtracting: 128 characters cost 17.5 fps, the 1,838 shapes
they built cost 10.6. Twenty players' characters are ~2.7 fps. Content is the
thing to budget.

**The network budget is the real hazard.** Thirteen sessions in `Logs/` show
genuine per-client starvation, worst case **6.8 seconds** with a client receiving
no state at all. It needed no guest -- the data was already on disk, and the
"invite somebody" recommendation had been repeated half a dozen times without
anyone checking whether it was necessary.

### MEASURED: a character script's globals are shared across threads

Every bot spawned, walked and collided correctly while wearing the wrong outfit:
*"BOTS WORK! just without the skins stuff"*.

    ERROR: BotCharacter.lua:525: attempt to call field 'Name' (a nil value)
         [Logic Task:25332]  [Logic Task:4764]  [Logic Task:22328]

Round one blamed `dofile`, on the grounds that twelve vanilla character scripts
all load `$SURVIVAL_DATA` paths and never mod content. Tidy, and wrong. Moving
the table into the calling file, four hundred lines above its only reader,
reproduced it exactly -- which is what settled it. The engine instantiates a
character script per character on its own logic task, and `Wardrobe = {}` at the
top of one instance's chunk blanks the shared global another instance's callback
is reading. It is an upvalue now, and a check enforces that.

### MEASURED: `setmetatable` does not exist in a character script's callback

The second bug behind the first. The random generator was an ordinary metatable
class and threw at callback time, while `class( nil )` ten lines below the
failing call worked -- so the name is there while the chunk executes and gone by
the time a callback runs. **Zero** vanilla character scripts call it. Closures
instead.

### MEASURED: the costume system was the load

    0 bots  60.0 fps    10 bots  15.0 fps    20 bots  8 fps

Reported as *"fps is 8 when even on the event with a lot of builds and REAL
players the fps was higer"*. Twenty-three extra bodies do not cost forty-five
frames. The controlled comparison was already in the logs: an earlier 95-bot run
held 30 fps **while the appearance code was throwing**, so every bot fell back to
one shared renderable set. That good-looking number had been written up as
evidence the crowd was cheap.

A fixed renderable list on a characterset entry is loaded once and shared. A list
built per character with `overrideRenderableList` cannot be batched. Vanilla says
so twice: that call has **one caller in the whole game**, and vanilla's ten
different-looking mechanics are **ten characterset entries**. Ours are eleven
now, generated by `dev/gen_characterset.py` from vanilla's own in-game mechanics.
20 bots went from 8 fps to 128 bots at 32.

### MEASURED: the grief alarm fires on a world that is only growing

    GRIEF ALARM: 2101 shapes lost in 20s
    GRIEF ALARM: 4334 shapes lost in 20s

Nothing was deleted. The patrol left its cursor at `n+1` and relied on the wrap
at the top of the next tick, but that guard is `cursor > n` -- so once the world
had grown by one body the wrap never happened, the pass resumed near the end, and
it published the shapes of the last few bodies as the whole-world census. The
alarm reads a small census as mass deletion **and arms `/lockdown` on its own**.
A real event with twenty people building fast is exactly that condition.

### Smaller, all reported

- **Bots walked off the edge of the world.** `home` was captured in
  `server_onCreate`, before `self.unit.character` existed, so the out-of-bounds
  branch could never fire.
- **Bots queued along one edge.** Plot indices run row by row, so the first N
  bots took the first two rows. Shuffled per layout now -- twenty builders in one
  corner concentrate every cost the bench exists to measure.
- **A 50/50 split is not random.** Gender was exactly 50% male and strictly
  alternating, `MfMfMf`, because an LCG is affine and `n = 2` uses one bit. The
  ratio check could not see it; the new check counts *runs*.
- **Cosmetics that are not in the game.** *"it is in the files yes. but not
  accesible."* The wardrobe enumerated every `.rend` on disk and `check_uuids`
  proved every path resolved -- which proved the wrong thing.
- **The benchmark reported `0.0 tick/s`.** Game sent `ticks`, World read
  `params.tick`. A new check matches every `sendToWorld` payload key against what
  the far side reads.
- **`dev/sync_mod.py` now prunes.** A script deleted from the repo stayed in the
  Mods folder and the engine kept compiling it.

### New

`/crowd`, `/bench`, `mod/Characters/`, `dev/bench_report.py`,
`dev/gen_characterset.py`, network-budget reporting in `dev/session_stats.py`.
139 checks, up from 90.

---

## V54 -- the mod list turns out to be the trust boundary, not the code

The city style picker also landed in this version and is described in
[`STATUS.md`](STATUS.md) under "New in V54". This entry covers the security work
only.

### A mod loaded beside us can do more than our own code can stop

Prompted by a real one. **T mod** (Workshop `3438987478`, Blocks and Parts) ships
a deliberate host-takeover backdoor, and the author documents it in a comment at
`BASE.lua:487`: a client holding a companion mod's `codes.json` sends the
factorisation of a hardcoded ~2048-bit semiprime, the server multiplies and
checks it, and a match grants operator -- ~90 commands including `ban`, `kick`,
`clear`, `op` (which can **deop the host**) and a bundled Lua-in-Lua interpreter.

The crypto is sound, so it is a key one person holds rather than a hole anyone
walks through. That turned out not to be the point.

### It cost 4.6 Hz without anyone attacking anything

MEASURED, `Logs/game-20260825-143811.log` -- T mod enabled in a **Server Works**
world, two players, 27 minutes:

    log size   95.6 MB    (a clean Server Works session the same day: 126 KB)
    tick/s     min 4.6    (healthy = 40)
    frame/s    min 4.4

760x the log volume. 6,341 of the 6,342 `__mul` errors carry T mod's content id.
A missing font in its console spammed MyGUI per render; `sv_force_field_tick`
produced a non-finite number and dumped a player-state table every tick. Against
this project's own ledger -- 19 players, 0 of 86 windows below target -- **one
player plus one co-loaded mod beat nineteen players building.**

### So `allow_add_mods` is a security setting, and it is now false

Two things were measured first, because they bound the whole problem:

- **A guest cannot bring their own mods.** Joined a world while subscribed to 101
  Blocks-and-Parts mods; the world loaded one, the host's.
- **An installed mod that is not ticked executes nothing.** 12,766 lines with it
  enabled, 0 without, same machine, same day.

So the only door is the host ticking the box at world creation -- and with
`allow_add_mods: false` that box is not there to tick. Cost: no extra building
parts. Reverting is one word.

### Two host gates that were missing, and a check that found one of them

Audited all 14 `sv_n_*` handlers. The design was already right nearly everywhere
-- authority comes from the engine-supplied sender and, where it matters, the
player's actual world position. `/plot claim` cannot be told to claim plot 47;
you have to stand there.

Two exceptions, both the same class -- a modified client opening a host UI on its
own screen. Neither could **change** anything, because every action handler
behind them tests the sender; what leaked was reading.

- `Game.sv_n_openPanel` -- city, event and settings panels
- `NotLift.sv_n_swOpenImport` -- the blueprint browser

Then two checks in `dev/test_logic.py` so it cannot regress: every `sv_n_*` must
test `getHostPlayer()` or be named in `GUEST_REACHABLE` with a reason, and none
may read an identity out of its payload -- named after T mod's `opCheck`, which
ops `data[3]`, a player id the *client* supplies.

**The first check caught `sv_n_swOpenImport` on its first run**, after a hand
audit had already passed over it and wrongly called it gated. 108 -> 110 checks.

The whole argument is in [`MODS-AND-TRUST.md`](MODS-AND-TRUST.md).

---

## V53 -- a rule that forbade its own remedy, a faster audit, and the city gets a look

### "I cant break the block if I hit the limit"

*"so like I am stuck in a loop I cant remove the bearing that prevents from
building."*

That is the whole bug in one sentence, and it was a plain one. Going over the
per-plot part budget handed the plot the **locked** profile, and locked is
`erasable = false`. So the single action that could satisfy the limit was the one
the limit forbade, and the only way out was to find the host.

Two things were wrong with it, not one:

- it returned **locked**, which takes away removing as well as placing
- it ran **first**, before any of the ownership logic, so it also overrode
  "this is somebody else's plot"

There is a `trim` profile now: everything the open profile allows, minus placing.
Remove, repaint, rewire, sit in it and drive it -- just do not add. And the check
runs **after** the ordinary verdict and only ever *downgrades* one, so a plot
that was locked to a passer-by stays locked to them. Body flags are per-body, so
a version that granted erasing would have turned the part limit into a griefing
tool.

`trim` maps to `polish` during the buffer, deliberately: buffer time is the one
window with neither verb, and handing out erasing there would quietly undo it.

### The audit has two cadences now

*"item detection is a bit too slow. you can run it faster if you only check
ocupied places with players curently on the server ocupied."*

Right, and the reasoning is worth keeping: a plot can only go over its budget if
somebody is **building** on it, and somebody building on it is standing on it.
Every other plot in the city is one whose contents cannot have changed.

So the fast pass runs **once a second** over the plots people are actually on,
and the full pass keeps its five seconds and still covers everything -- a plot
whose owner logged off mid-build, contraband dropped on a road, a body that
drifted. Nothing is lost; the common case answers five times sooner.

The scope costs nothing to compute. `Plots.sv_updateOccupancy` runs every tick
and is already the only thing in the mod that looks at where people stand, so it
records the answer as it goes.

One trap, and it has a check: a scoped pass only writes buckets for bodies it
FINDS, so deleting the last offending part would have left the violation standing
until the next full pass. Every scoped plot is seeded with an empty bucket, which
is what makes "trim it and it reopens" mean one second rather than five.

### The city has a style, and the colours are the paint tool's own

*"for style because I dont like brutalist that much... make a choice for blocks.
so you can select custom blocks for the city foundation for style. and also their
colour bassed on the in game paint tool pallete."*

Five pieces of the city -- pad, border, road, plaza, stand -- each with a block
and a colour, all ten on one page of the settings panel, all cyclable by
clicking. `/citystyle` lists them; `/citystyle garden` sets all ten at once.

**The palette is the real one, and finding it took reading the executable.**
`Tool_PaintTool.layout` is twenty lines and declares one empty widget called
`ColorGrid` -- the swatches are engine-side, so there is nothing in `Data/` or
`Survival/` to read. They are not stored as text either: the hex strings in the
string table are the *shapeset* colours, sorted alphabetically, which is a
different list. They are BGRA uint32s, forty of them, in a zero-terminated run at
offset `0x13e9b90`. `df7f00` in there is the default orange every new block is
painted, and `4a4a4a` is what this mod was already using -- which is how the run
was confirmed to be the right one rather than a coincidence.

Four rows of ten, exactly as the tool draws them: a greyscale column and nine
hues in four shades each. So the names are `green`, `palegreen`, `deepgreen`,
`darkgreen`, and `white` / `grey` / `darkgrey` / `black`. A raw six-digit hex is
accepted too.

The default is `garden` -- the green carpet that was asked for before the ask
became "make a choice". `/citystyle brutalist` is the concrete-and-grey it was.

**A style change does not restyle a city that already stands.** The city is
imported blueprints and a blueprint is not a live thing that can be repainted;
BUILD CITY again. Every reply says so, because otherwise it reads as a setting
that did nothing.

Two things that only became possible once the materials were a setting, and both
have checks:

- **A plot must never count as scenery.** Scenery is locked in every mode, and
  the test used to be "is every shape metal 2 or metal 3", which was safe only
  because the pad was always concrete. Nothing stops a host setting the pad and
  the roads to the same block, so the pad material is now excluded explicitly.
- **`CITY_UUIDS` covers every selectable material, not the three in use.**
  Otherwise restyling would make the city the cleaner had been protecting stop
  looking like city.

### A counter in the top left

*"a counter of amount of players curently. and amount of residents. resident list
is list of players that were here - the banned ones."*

    ONLINE        7
    RESIDENTS    23

Online is `sm.player.getAllPlayers()`. Residents is every record in Players.json
that is not banned -- which is the number a recurring event actually cares about,
because it is the community the server has built up and it survives a restart,
which the online count never does.

Sent once a second and **only when a number moves**, because the panel redraws on
receipt and an identical payload every second would be a redraw every second for
every client forever.

---

## V52 -- /budget, and the switch that would have made the part limit look broken

`plots` defaults to OFF, and with plots off `sv_bodyIsOpen` returns nil before
the over-budget check is ever reached -- so the audit counted, warned, and locked
nothing. Testing the per-tile part limit without `/set plots on` would have
looked exactly like a feature that does not work.

`/budget` prints what a plot is using against what it is allowed, says outright
when plots are off, and is open to everyone: a builder needs it more than the
host does.

---

## V51 -- the lifts leave the tool gate, and a comment stops overclaiming

*"in survival lift is disabled by default. which means. just remove that thing
that disables lifts."* All three lifts are out of `Settings.TOOLS`, and the
`lift` / `hostlift` settings are gone with them. Nothing this mod does can take
a lift out of anybody's hands any more.

The `enableBuildOn*` comment claimed MEASURED and was caught: *"stop. read thje
title. you sure its the right one?"* `DungeonWorld` does set three of those
flags by hand -- but no creative world sets them either, and lifts work in
vanilla creative, so the evidence is **against** these having been the lift bug.
The comment says so now.

---

## V50 -- the alarm stops locking, and a save on every phase boundary

### The automatic lockdown is off by default

*"by default the auto lockdown shall be off."*

Right call, and worth the reasoning: a false alarm that shouts is a nuisance; a
false alarm that **freezes twenty people mid-build in front of a stream** is
worse than the griefing it was guarding against -- and the alarm cannot tell
somebody clearing their own work from somebody wrecking yours.

It still announces and still logs. `/set alarmlock on` arms it, and the
`lockdown` preset still does. A migration turns it off for anyone who has already
played, since a changed default reaches nobody.

### "I cant build while standing on protected blocks which sucks"

That was V42's doing. A claimed plot with nobody standing **in** it is locked --
which is what stops somebody on the road reaching over your work -- but the only
thing that reopened it was standing inside the plot or on one of its own seams.
Step onto a **road**, or onto the plaza, and your own plot locked behind you
while you were looking at it.

It is a **distance** now, not a zone: `Plots.HOLD_RANGE`, twelve blocks. You are
next to your own land or you are not, and a road being protected ground has
nothing to do with whether the plot beside it is yours. Cheap by construction --
it only ever looks at the plots on your own team, which is one for almost
everybody, never at every plot in the city.

The check covers all four cases: standing on it, standing just off the edge,
standing out at the limit, and standing across the city -- plus a stranger
standing on your plot, who holds nothing open.

### A snapshot at every phase boundary

*"the save shall happen on those times: prep time start, build time start, build
time end, buffer end. all those shall happen besides the auto saving."*

| when | named |
|---|---|
| prep begins | `prepstart` |
| build begins | `buildstart` |
| build ends | `buildend` |
| the event ends | `eventend` |

Better than a timer alone, and it is worth saying why: an autosave lands wherever
the clock happens to be, but these land on the moments you would want to roll
back **to**. Each is taken *before* the phase's protection change, so `buildend`
records the builds as they stood when the clock stopped rather than the world
after it was shut -- and a check asserts that ordering, because it is the kind of
thing that would silently reverse.

---

## V49 -- the Import Lift, and the reason the cleaner had no name

*"make a new lift called import lift that is just regular lift just with the
functions of the creative lift"* -- and the answer to whether that was even
possible came from the owner: **"we litteraly made a nugdupS."**

Quite right. The toolset has no name field at all, but
`mod/Gui/Language/English/inventoryDescriptions.json` does, keyed by uuid, and
the nugdupS canary has been the standing proof of it since V25.

**Import Lift**: a fresh uuid nothing else in the game declares, pointed at the
creative `Lift` class, named in our own inventory descriptions so it cannot be
confused with either of the two lifts already in the menu. Being an addition is
the whole point -- nothing can win the first-declaration race against a uuid
nobody else owns, which is the one case a Custom Game toolset can rely on.

It is governed by the same `lift` setting as the other two, and by the same
"building is shut" warning.

**And the cleaner has a name now.** It never had an entry in that file, so it sat
in the menu with nothing to call itself -- which is what "I dont see my deleting
thing appear" actually was, about a tool the logs had already proved was being
created and held.

`dev/check_uuids.py` now prints the menu name of every tool the toolset adds and
flags **NO NAME IN THE MENU** on any that lack one. Written by taking the
cleaner's entry back out and watching it fire.

---

## V48 — a dead event was resurrecting itself on every load

*"still broken red colour"* — and it was never the remove tool. It was the event
clock, and the log said so in two lines nobody had reason to connect:

    [ServerWorks] event resumed: build, 00:00 left
    [ServerWorks] event buffer -> protection polish

`Event.sv_advance` set each new deadline from **`now`** instead of from the
**previous deadline**. So an event that had expired hours earlier resumed, saw
that build was over, and started a **fresh five-minute buffer counted from the
moment the world loaded**.

Buffer is the `polish` profile: no placing, no breaking. So *every single load*
dropped the world into a window where the remove tool drew no red preview and
nothing could be built — and when that window expired, the next load opened
another one.

Deadlines are absolute epoch seconds by design; scheduling from `now` threw that
away. They now come from the previous deadline, and `sv_advance` loops until it
lands somewhere the clock has not already passed — so a stale event goes straight
to `ended` in one step instead of walking through phases that finished while the
game was shut, announcing each one.

### And it now says so out loud

The state was knowable and nobody could reasonably have known it, which is a
design failure of its own. On load:

    event resumed: buffer, 04:12 left -- building is SHUT
      nothing can be placed or removed until the clock reaches build, or /event stop

And anyone joining into a shut world is told directly, with the host also told
where the off switch is.

---

## V47 — the alarm was wrong in both directions, and banning is load-bearing

### 16x16 is the number everything hangs off

The owner's fact: **the remove tool deletes at most 16x16 = 256 shapes in one
action.** Both halves of the grief alarm were wrong because of it.

- The threshold was **250, compared cycle to cycle** — so a *single ordinary
  delete* tripped the alarm and locked the world.
- Raise it above 256 and the opposite appears: the patrol finishes a census every
  four hundredths of a second on a 200-body city, so somebody deleting 256 at a
  time, forever, never shows a drop bigger than 256 in any one cycle and **never
  trips it at all**.

The alarm now measures a **20-second window** against its **high-water mark**
rather than the previous sample, so pausing between deletes does not hand out a
fresh baseline. Default **400**: one big sweep is quiet, two inside the window are
not. A migration raises any saved value of 256 or less, because a default alone
reaches nobody who has already played.

### Banning

*"we need to make sure banning works. cause its the only way."*

It is the only way, and for a reason worth stating: build permission is per-BODY
and cannot be aimed at a person, so removing the person **is** the enforcement.

Every path that decides somebody is banned now reaches **`sm.game.banPlayer`** —
including the one that fires when somebody banned while offline comes back, which
previously only kicked them, over and over, forever.

And what has to be said out loud: **our list is keyed on the display name.** Lua
is handed no stable player id — the `Player` binding list has `id` (a session slot
that shifts) and `name`, and nothing else. No Steam id. So the list catches
renames it has *seen*, and a brand new name is a brand new identity. **The allow
list is the stronger tool**, and the docs now say so: a ban loses to a rename, an
allow list does not.

### Backups

*"and also backups. the whole save backups. we need to make sure they work too."*

There is now a check that drives a real capture end to end — the job, the index,
the file it writes, the list afterwards. It needed the stub to grow
`getCreationsFromBodies` and an `sm.creation` shim, which is itself the honest
limit: **`exportToString` / `importFromString` are the engine's, and nothing
outside the game can prove them.** Everything around them is proved now.

### Also

The vanilla right-click delete preview not showing red was almost certainly the
V46 body-location bug — every plot was resolving to `sweep`, which is
`buildable = false, erasable = true`. Worth re-testing now that bodies locate
properly.

---

## V46 — every plot in the city was being located somewhere it was not

*"I cant place blocks on the concrete but I can delete it. I can delete others
plots."*

**buildable = false with erasable = true is exactly ONE profile out of six:
`sweep`.** And `sweep` is what `sv_bodyIsOpen` returns when it cannot place a
body in the city at all — the profile for litter on open ground, where nobody may
build and anybody may clear.

So every plot in the city was being located somewhere it was not.

The cause: **`body.worldPosition` is a body's own ORIGIN.** Every piece of this
city is imported at `sm.vec3.zero()`, because the blueprint carries absolute
block coordinates — so an origin can report a point nowhere near the thing you
are looking at. `Plots.sv_bodyZone` uses the **centre of the AABB** instead,
which cannot be an origin artefact: it is the middle of where the body actually
is. A build welded to a plot keeps its centre over that plot; a tall tower on it
still does.

All six call sites moved, and a check fails if any of them goes back.

**This may well be the answer to "I cant build on my plot even when the time has
started"**, which has been open and unexplained since V28. Not confirmed — but it
is the first explanation that produces exactly the symptoms, including the ones
in this report that the old theories never accounted for.

### The city now says where it landed

The diagnostic that would have caught this the moment the city was built, rather
than eighteen versions later. Once per build:

    [ServerWorks] where the city landed: 196 bodies -- filler 99, plot 96, plaza 1

Every plot slab should locate to a **plot**. If they come back as plaza or as
nothing, the plot rules are being applied to the wrong ground and nothing
downstream can possibly be right — and it says so in as many words.

### The cleaner tool

*"I dont see my deleting thing appear."*

It is there — the logs confirm `Created Tool ... {bbbb0cc8(CleanerTool)}`, so the
toolset addition resolves and the tool has been in somebody's hands. It looks
like a sledgehammer in the menu, which is not obvious.

What was missing was any sign it was live. It now shows a crosshair prompt —
*delete this block — hold F for the whole creation* — using
`sm.gui.setInteractionText`, which is **proven inside a tool script**
(`Fertilizer.lua:242`), unlike `sm.gui.chatMessage`, which no vanilla tool calls
at all.

---

## V45 — the lift is not broken, the world is shut; and the text boxes touch nothing

### The lift

*"oh also the lift is still fuc-SAD"* — and the answer is in the top right corner
of the screenshot that came with it. The event HUD reads **ENDED / builds are
locked**.

In that state protection is `locked`, every body is
`convertibleToDynamic = false`, and **a creation that cannot convert to dynamic
cannot be placed**. So the lift does nothing, says nothing, and looks broken.

That is not a bug — a locked world *should* refuse new creations, that is what
locked means. It is a thing to **say**. Picking up a lift while building is shut
now prints, once:

    The lift will not place anything: the event has ended, so builds are locked.
      It works again the moment building opens -- /menu, EVENT CLOCK.

The client had no way to know this. It could see the event phase but not
`/lockdown` or a host toggle, so `sv_pushEvent` now carries `canBuild` and the
protection mode with it.

**And a check on the thing that has cost three versions**: the patrol logs, once
per session, `ghost body seen and skipped -- the lift guard works`. A ghost is a
creation being placed by a lift; pinning `convertibleToDynamic = false` on one
makes the placement silently do nothing. If that line never appears in a log
where somebody used a lift, the guard is not recognising ghosts, and that is
where to look next instead of guessing again.

(`isGhost`, `isOnLift` and `isOnVirtualLift` were all confirmed present in the
`wrap_Body` binding list while checking this.)

### The crash, again

*"the game still crashes when I try to select build time"* — after V44 had already
deferred the redraw by a tick.

The screenshot shows PREP TIME focused with a cursor in it, so **one** box is
fine. It is moving to the **second** one that kills it: a focus transfer between
two EditBoxes in the same GUI. The base game has exactly one editable box in its
one editable panel, so two in a single tree is territory the engine is never
asked to handle by its own content.

Deferring was the right instinct and it was not enough. So the typed-time handler
now touches the GUI **not at all** — no render, no deferred render, no close. It
takes the value, chat says what was accepted, and the panel shows the true
numbers the next time anything else redraws it. Slightly worse to look at, and it
cannot crash. A check fails if that handler ever gains a GUI call.

**And typing is now optional.** The steppers reach much further — build time
steps 1, 2, 3, 5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240, 360, 480 — so every
sensible duration is one or two clicks away without touching a text box at all.
`/event start <prep> <build> <buffer>` still takes any number from chat with no
GUI involved.

---

## V44 — the crash, and the canvas is half the screen

*"game crashed when I tried to change the number of build time."*

The log ends mid-line: no Lua error, no shutdown sequence. A hard crash.

**Redrawing a panel from inside a widget's own callback destroys the widget that
is currently running.** V30 found that for `close()` and a click, where it
silently killed the rest of the handler. An `EditBox` also holds the keyboard
focus, so destroying one mid-callback leaves the engine holding a pointer to
something that no longer exists — and that is not a Lua error, it is a crash.

Vanilla *does* render from inside its text callback (`DigitalSign.lua:149`) — but
it re-renders the **same table**, mutated in place. We build a fresh tree every
time. Not the same thing, and the difference is the crash.

So redraws are now queued exactly like closes: `cl_renderLater` /
`cl_drainRenders`, drained beside them at the top of `client_onFixedUpdate`. **Not
just the text box** — all six in-callback redraws, including the steppers, which
had merely not crashed yet. One tick of latency on a button press is
imperceptible; the whole class is gone. The check now fails on any `cl_on*`
handler that calls `cl_showPanel` or a closer directly, and it was written by
putting one back.

The typed-time handler is also wrapped end to end and logs once. It runs on a
keypress, and finding out about a Lua error there mid-event is not acceptable.

### The canvas is HALF the screen

Also from that log, and worth having: `gui canvas 1720x720` on a 3440x1440
monitor. `getScreenSize` says 3440x1440; **`getViewSize` says 1720x720** — exactly
half. So widget coordinates live in a space about half the window's width, which
confirms V33's fix was measuring the right thing and gives the real number at
last. Worth noting `SettingsGui` is 1120x690 in a 720-tall canvas: thirty units
of headroom, and anything taller would be off screen.

### Rebuilding the city is not griefing

`GRIEF ALARM: 628 shapes lost`, seconds after a rebuild. Clearing the old city
*is* a mass deletion — it is just ours. An alarm that cries wolf every time the
host lays out the city is one nobody will believe at the moment it matters, so
`sv_buildFloor` quiets it for two minutes the way `/purge` and `/restore` already
do.

---

## V43 — the floor is the builder's while the clock is running

*"theoretical explanation its because its connected to the rest. so look. the
stand the plot is on. and the plot it self shall be destructuble and placable.
aka not protected when build time."*

V38 pinned the city floor — never liftable, never convertible to dynamic — because
`open` left every plot in the city liftable during an event and anyone could
carry one off. That was real. But it applied in **every** mode, including the one
where the ground is supposed to be the builder's to change.

The pin is about **when**, not about what:

| mode | the ground is |
|---|---|
| **build** (`open`) | **free** — placeable, removable, liftable, convertible |
| buffer (`polish`) | pinned |
| prep (`display`) | pinned |
| ended / lockdown | pinned |

Presence enforcement is what keeps a builder to their own plot; a flag on the
body was never able to do that anyway, because body flags are global.

Worth writing down: `locked` and `display` are already `liftable = false` in
their own right, so the pin only *changes* anything for `polish` and `open`. The
check tests `polish` for that reason — a check written against `locked` would
have passed no matter what the code did, and I confirmed that by trying it.

The check also runs the **real resolver** now instead of reading the PROFILES
table, which is the lesson from V41: a profile that exists is not a profile any
body receives.

**Whether this is the cause of "I cant build on my plot" is still unknown.**
Every path traced says a plot should be buildable during build time, and the
report predates V38's pinning entirely — so this is the requested change, made
because it was asked for and is defensible on its own, not because it is a
diagnosis.

---

## V42 — "only build on your own tiles" had a hole, and metal 2 off the platform was undeletable

### The plot rule

*"the function that only build on your tiles. and only when time started."*

Body permission flags are **global**. If a plot is buildable it is buildable by
everybody, from anywhere within reach — and the old rule said an *unoccupied*
zone stays open. So a claimed plot with nobody standing on it was open to
anyone: stand on the road beside somebody's work and reach over it, with the
owner not even online.

Now:

| | |
|---|---|
| occupied | open only if every player standing there is authorised |
| **empty and claimed** | **locked** |
| empty and unclaimed | open — nothing to protect, and the host needs it |

`zoneHeld` keeps that from locking an owner out of their own plot: an authorised
player standing anywhere on their team's land holds the whole team's ground open,
so stepping onto the one-block seam at the edge while building does not lock the
plot behind you.

### Metal 2 off the platform

*"I still cant remove metal 2 via the tool. even if its not on the platform."*

The city-shape test was uuid plus height, and a block dropped on the terrain
outside the city is **lower** than our deck — so it passed the height test and
the cleaner refused to delete it.

`sv_isCityShape` now also requires the shape to be inside the city's footprint,
and below the deck it must be inside an actual **stand** — so somebody building
underneath the platform still owns what they built. It is deliberately not on the
patrol path (it runs on a cleaner click, a `/purge`, a census and a rebuild),
which is what lets it afford a `Layout.locate`.

`CleanerTool` keeps a cruder copy for when it cannot see `g_swPlots`, and that
copy got the same fix: a narrow band at exactly our deck layer rather than
"anything low", since nothing of a player's can be in that band anyway.

Both checks were written by putting each bug back and watching them fail.

---

## V41 — buffer time never actually ran, and your blocks were mistaken for the city

### "whatever the block is metal 2 or concrete it counts as part of the city"

Right, and the slop was the cause. The city's top layer is block `z = DECK_Z`,
world z **1.00 to 1.25**. People build *on* it, so their first block is the layer
above: **1.25 to 1.50**.

**And `shape.worldPosition` might be the minimum corner or the centre** — nothing
in the base game settles which. The test allowed anything up to 1.30, so under
the min-corner reading a player's first block sat at exactly 1.25 and was classed
as city floor: the cleaner refused to delete it, and CLEAR CITY would have taken
it with the rest.

`Plots.CITY_CEILING` is now `( DECK_Z + 0.75 ) * BLOCK` = **1.1875** — three
quarters of the way up our own layer, which gives the same answer whichever way
`worldPosition` is meant, with room on both sides. The check tests both readings
against all three materials. `CleanerTool` restates the number, because a tool
script may not share the Game/World environment, and a check asserts the two
never drift apart.

### "please make as I said to the buffer time. because it doesnt work this way yet"

It did not, and V34's check passed anyway — which is the more useful half of this.

V34 added the `polish` profile and pointed buffer at it. The check read the
PROFILES table and asserted polish was paintable, usable and not buildable. All
true. But `sv_applyEventPhase` sets `buildopen = false` for every phase that is
not `build`, and the resolver's blanket

    if Settings.Get( "buildopen" ) == false then return false end

fired **first** and returned `locked`. **Buffer time was identical to prep.** The
profile was correct and completely unreachable.

Two things changed:

- **`buildopen` is a host toggle and must not override a mode that already denies
  building.** `Protection.sv_modeClosesBuilding` reports whether the current
  mode's own profile is already `buildable = false`; when it is, the blanket has
  nothing to add and does real harm.
- **The check now runs the resolver**, not the table. It builds a real
  `Protection`, a real `Plots`, the actual resolver and a body standing on a real
  plot, then asks what that body would be given. Reading a data table can only
  ever prove the data.

The fixture stands on `Layout.plotCentre( grid, 1 )` and asserts the zone is a
buildable plot *before* testing anything — the origin is the **plaza**, which
resolves to `sweep`, and a check written there would have passed for entirely the
wrong reason. It caught that on the first run.

---

## V40 — type your own times, and the sweep is gone

### The sweep is removed

*"remove the sweep function since it just doesnt work as intended and just
deletes stuff. DONT try to fix this I know you cant. just remove the function."*

Gone: the SWEEP LITTER button and the `/purge walkways` branch behind it.

The reasoning is worth keeping, because it is right. "Not standing on a plot" is
not a test for litter. It cannot tell a dropped craftbot from a car somebody
parked on a road, or from a build that overhangs its own plot edge, and there is
no flag on a body that says *this is rubbish*. A sweep that guesses will
eventually delete something that mattered and nobody will know which press did
it. The cleaner tool replaces it: it deletes exactly what is under the crosshair,
which is a decision a person makes rather than a rule.

`/purge here <radius>` is the same shape and is still there — say the word and it
goes too.

### Any number can be typed into the event clock

*"on event clock. allow for custom numbers from the keyboard so I can set my own
time."*

Click a duration, type a number, press Enter. The steppers stay for the usual
values.

Typed input in a json GUI needs an `EditBox` with **`Static = false`** — that one
flag is the whole difference between a box that displays a number and one that
accepts it — plus `NeedKey = true` and an `onTextEnter` callback. The base game
has exactly one editable box (`DigitalSign.gui`'s `EnterTextBox`), so that is
where every property came from, and `DigitalSign.lua:157` gives the signature:
`( self, widgetName, text )`.

**A text event carries no `onClickData`**, unlike a click — so the widget *name*
is the only thing that says which field was typed into, and it has to map back
by hand.

What it does with what you type: strips anything that is not a number, rounds to
whole minutes, clamps to the field's range and **says so when it clamps** — a
build time of 0 becomes 1 with a message, rather than silently starting an event
with no build phase. Nonsense leaves the value alone and puts the real one back
in the box.

The check covers all of that, and caught two things: `.get()` on a lupa table
silently resolves to the Lua key `"get"` and returns nil, and a Lua function
returning `( value, reason )` arrives in Python as a tuple — so "did it clamp?"
is testable, and now asserted in both directions.

---

## V39 — separation was the design, and V32 had it backwards

> "WAIT I REMEMBERED!!!! the things NEED to be separated from the main city! in
> the original event they were separated with wedges so updating one block wont
> update whole city. but just the block! so my bad. the block between the panels
> NEEDS to be detached. and each panel shall have its own stand!"

Three reports read as *"the city is not joined up"* and V32 answered them by
welding a single slab under the entire footprint. Wrong fix, real observation —
and the reason it was wrong is the same mechanism the reference blueprint
showed: **a body is the unit the engine rebuilds.**

Change one block and the whole body it belongs to is reprocessed. Weld a hundred
plots into one city and every block anyone places, anywhere, costs a rebuild of
all of it. At an event with twenty people building at once — goal 1 of this
project — that is the difference between a server that works and one that does
not. Separating the panels was not sloppiness at the original event; it was the
thing that made it run.

### What changed

- **The base slab is gone.** It was the single biggest thing welding the city
  into one rebuild unit.
- **Every street is its own creation.** One import per piece, so the block
  between two panels is welded to neither of them.
- **Every plot has its own stand** — a metal column from the ground to the
  underside of the pad, welded into the plot's own body. The panel is held up by
  itself and by nothing shared.
- **The plaza keeps its pillar**, now welded into the plaza's own body rather
  than imported separately.

The city goes from 2 bodies of shared ground to one per piece. More bodies, each
far smaller, which is the trade the whole design is making.

### Two checks hold the line

One asserts **no piece spans the bounding box** — the base slab, asserted away.
Written by putting the slab back and watching it fail.

The other rasterises a plot **in three dimensions** and proves the ring, the pad
and the stand are one body with no block claimed twice. The first version of that
check worked in 2D and reported the stand as an overlap with the pad above it —
a 2D check on a 3D structure will lie about exactly the thing it exists to catch.

---

## V38 — the plot floor could be carried away with a lift

Checking what else the blueprint answered turned up a live bug, and it is the
most literal possible reading of *"the concrete is not attached"*.

`PROFILES.open` — the profile the whole city runs under during **build time** —
sets `liftable = true` and `convertibleToDynamic = true`. A plot slab is not
scenery, because `sv_isScenery` requires every shape to be metal and a plot has
concrete in it. So during an event **every plot floor in the city was liftable
and convertible to dynamic**. Anyone holding a lift could pick up somebody's
plot, and a slab that converts to dynamic is a floating object with nothing
holding it up.

`World.sv_pinCity` does pin both at import. The patrol then reapplies the full
profile over the top of it a second later, so the pinning never survived a single
cycle. It has to be in the profile or it does not exist.

Every profile now has a twin with those two flags forced false, and a ground test
decides which bodies get it: `Plots.sv_isGround`, **one AABB call**, because the
heights leave no ambiguity — the deck sits at z 0.75, a plot slab at 1.00, and
anything merely *standing* on the floor starts at 1.25. One call rather than a
walk over every shape matters, because this runs per body per patrol slice and a
500-block build would otherwise be 500 uuid comparisons every cycle.

A build welded to a slab is one body with it and gets pinned too, which is right:
it is part of the ground now, and the ground does not get carried off.

A check asserts every return path in `profileFor` goes through the pin — six of
them — and it was written by taking the pin off one and watching it fail.

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
