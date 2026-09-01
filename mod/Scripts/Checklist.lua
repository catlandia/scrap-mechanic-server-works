-- Checklist -- the dev checklist, in the game, where the testing happens.
--
-- ASKED FOR: "you make an ingame check list. for devs. so I can test stuff. if
-- something doesnt work I can exactly test it and then write result like did it
-- work yes or no. because if I have to switch every time here. I waste my time."
--
-- That is the real cost and it is not a small one. Every red line in
-- docs/STATUS.md has to be turned green by somebody standing in the world doing
-- the thing, and up to now the only way to record the answer was to leave the
-- game and type it out. So the answers were mostly never recorded at all: the
-- ledger is written from memory, days later, which is why it says "seen
-- working" in some places and "seen once, not since" in others.
--
-- This file is the catalogue and the arithmetic. ChecklistGui.lua draws it,
-- Game.lua owns the state and writes it to disk, and dev/checklist_report.py
-- reads that file back out -- so the result of a play session is a FILE rather
-- than a conversation somebody has to remember to have.
--
--
-- WHAT IS PURE IN HERE, AND WHY THAT MATTERS
--
-- Everything except Sv_Load and Sv_Save. Counting, paging, finding the next
-- untested item and formatting the summary are all plain table work, so
-- dev/test_logic.py drives them through lupa exactly as it drives the rules --
-- which is the only reason any of this is tested at all. The moment a helper
-- here needs a body or a player it belongs in Game.lua instead.
--
--
-- THE FILE IS KEPT, NOT CLEARED
--
-- Results live in $CONTENT_DATA/Checklist.json, which is global to the mod
-- rather than per world (see CLAUDE.md: mod state is global). Everywhere else
-- that is a hazard -- a new world inheriting the last one's claims -- and
-- Game.sv_newWorldReset exists to undo it. Here it is the point: a test result
-- records what the CODE did, not what a world contains, and making a fresh
-- world is the usual way to test something. So sv_newWorldReset must never
-- touch this file, and dev/test_logic.py asserts that it does not.
--
-- Each result carries the BUILD it was recorded against. A PASS from V56 is
-- still a PASS in V57, and the panel says which build it came from rather than
-- pretending the answer is current -- an honest ledger is the whole point, and
-- a result whose provenance is lost is worth less than no result at all.

Checklist = {}

-- Bumped with VERSION. dev/test_logic.py fails if the two disagree, because a
-- stale build number silently mislabels every result recorded after it.
Checklist.BUILD = 74

Checklist.FILE = "$CONTENT_DATA/Checklist.json"

-- untested is the ABSENCE of a result, not a result. It is never written to the
-- file; clearing an item deletes its entry outright.
-- NO APOSTROPHES ANYWHERE IN HERE. The game builds a limited glyph set per font
-- out of the strings it draws itself, and a character it has never drawn comes
-- out as a hollow box. Letters and digits are known good; punctuation nobody has
-- tested is not worth the risk on a button.
Checklist.STATES = {
	{ id = "pass", label = "WORKED", button = "IT WORKED",
	  tiny = "it did what it says" },
	{ id = "fail", label = "NOPE", button = "IT DID NOT WORK",
	  tiny = "you tried, it failed" },
	{ id = "blocked", label = "STUCK", button = "CANNOT TRY IT",
	  tiny = "something stopped you trying" },
	{ id = "skip", label = "SKIP", button = "SKIP IT",
	  tiny = "not now" },
}

function Checklist.IsState( id )
	for _, s in ipairs( Checklist.STATES ) do
		if s.id == id then return true end
	end
	return false
end

-- The order these are listed in is the order to run them in. Boot first,
-- because a world that came up wrong makes every later answer meaningless.
-- Guest last, because it is the only group that cannot be answered alone.
Checklist.GROUPS = {
	{ id = "boot",    label = "START UP",  blurb = "did the world come up right. do this group first" },
	{ id = "city",    label = "THE CITY",  blurb = "building the city, and what it is made of" },
	{ id = "plots",   label = "PLOTS",     blurb = "claiming ground, and keeping other people off it" },
	{ id = "limits",  label = "LIMITS",    blurb = "the rule about how much one person may build" },
	{ id = "event",   label = "THE CLOCK", blurb = "prep, build time, last few minutes, finished" },
	{ id = "protect", label = "LOCKING",   blurb = "freezing builds, and spotting somebody wrecking things" },
	{ id = "tools",   label = "TOOLS",     blurb = "the Cleaner, NOTlift, Focus and the lift" },
	{ id = "backup",  label = "SAVES",     blurb = "saving the world, and putting it back again" },
	{ id = "admin",   label = "BANS",      blurb = "kicking, banning, and the guest list" },
	{ id = "crowd",   label = "FAKE CROWD", blurb = "filling the city with fake players. Needs /developer on" },
	{ id = "guest",   label = "TWO PEOPLE", blurb = "these need somebody else in the world with you" },
}


-- THE CATALOGUE.
--
-- One entry per thing that has never been proven to work, taken from
-- docs/STATUS.md section C and docs/ROADMAP.md phase 1. Fields:
--
--   id      stable, and the key a result is stored under. NEVER renamed: a
--           rename silently orphans every result already recorded against it,
--           and dev/test_logic.py cannot catch that because both sides move
--           together.
--   steps   what to do, in order. Short enough to read while standing in the
--           world with the panel open.
--   pass    what proves it. Not "it works" -- the specific thing to look at.
--   log     the line in Logs/game-*.log that settles it, where there is one.
--           This project's own rule is READ THE LOG FIRST, and this is that
--           rule written down per test rather than left as advice.
--   run     a command the panel can fire for you, as separate words because
--           bindChatCommand splits on spaces and so does our own dispatch.
--           Absent on anything destructive -- those get typed, on purpose.
--   needs   "guest" for the ones that cannot be answered by one person. They
--           are listed anyway: a checklist that hides what it cannot do is how
--           "this needs a second machine" stayed forgotten for three versions.
--   who     "log" for the ones whose answer is only in Logs/game-*.log. THEY
--           ARE NOT ON THE PANEL.
--
--           REPORTED: "so that there are only things I can directly test in
--           games since I dont want to go in logs to test something. since
--           stuff like that you can basicaly do your self." Exactly right, and
--           it is not only a preference -- reading a log is done afterwards,
--           from outside the game, and mixing those into a list somebody is
--           working through while standing in the world is how the whole list
--           stalls. They stay in the catalogue so the ledger is complete and so
--           dev/checklist_report.py --set can answer them from this side.
Checklist.ITEMS = {

	--[[ starting up -- nothing below this matters if this group is red ]]

	{ id = "boot-world", group = "boot",
	  title = "The world loads and you can get in",
	  steps = { "Play > Custom Game > Server Works > Create" },
	  pass = "you end up standing in the world. If the loading bar fills up "
	      .. "and just sits there, stop and tell me -- that one is serious",
	  log = "[ServerWorks] world ready" },

	{ id = "boot-lines", group = "boot",
	  title = "The mod is actually running",
	  steps = { "type /protection" },
	  pass = "it answers you in chat. If nothing comes back, half the mod did "
	      .. "not load and nothing below this is worth trying",
	  run = { "/protection" },
	  log = "[ServerWorks] build on:" },

	{ id = "boot-canvas", group = "boot",
	  title = "The big panels fit on your screen",
	  steps = { "type /settings", "look at the very bottom of the panel" },
	  pass = "you can see the buttons along the bottom edge and click them. If "
	      .. "the bottom is cut off, your screen is smaller than the panels "
	      .. "were built for -- tell me and it is a quick fix" },

	-- NOT ON THE PANEL. who = "log" means this one is answered afterwards, from
	-- the game log, which is my job and not something to do while standing in
	-- the world. REPORTED: "I dont want to go in logs to test something. since
	-- stuff like that you can basicaly do your self."
	{ id = "boot-quiet", group = "boot", who = "log",
	  title = "The game is not spewing errors in the background",
	  steps = { "just play the session", "I read the log afterwards" },
	  pass = "no error repeating over and over. This matters more than it "
	      .. "sounds: the worst slowdown ever measured on this project was the "
	      .. "game writing errors to disk, 1.8 GB of them in one session",
	  log = "Lua Error Traceback" },

	{ id = "boot-modsbox", group = "boot",
	  title = "The add-mods box is on the world creation screen",
	  steps = { "start a new world from this custom game",
	            "look for the block mods list before you press create" },
	  pass = "you can tick block mods. V74 turned this back on -- a guest cannot "
	      .. "bring mods, so the only person who can enable one is you. Whatever "
	      .. "you tick runs on your own machine with nearly the reach this mod "
	      .. "has" },

	{ id = "boot-nomods", group = "boot",
	  title = "Other mods cannot be added to the world",
	  steps = { "Play > Custom Game > Server Works",
	            "look for a list of other mods to tick" },
	  pass = "there is no list. Any mod ticked there would run its own code on "
	      .. "your machine, so it is meant to be shut off" },

	{ id = "boot-newworld", group = "boot",
	  title = "A brand new world starts clean",
	  steps = { "make a SECOND world from the mod", "type /protection",
	            "stand somewhere and type /plot info" },
	  pass = "building is open and nobody owns anything. A new world used to "
	      .. "come up locked, with the plot owners from the world before it",
	  log = "[ServerWorks] NEW WORLD" },

	--[[ the city ]]

	{ id = "city-grid", group = "city",
	  title = "You can set the size of the city",
	  steps = { "type /plotgrid 20 1 10 10" },
	  pass = "it tells you the size it stored instead of an error",
	  run = { "/plotgrid", "20", "1", "10", "10" } },

	{ id = "city-build", group = "city",
	  title = "The city gets built",
	  steps = { "type /plotmenu", "press BUILD CITY" },
	  pass = "a city appears, and the chat message afterwards does NOT say "
	      .. "anything failed",
	  log = "[ServerWorks] city built" },

	{ id = "city-zones", group = "city",
	  title = "The game knows a plot is a plot",
	  steps = { "stand on one of the concrete squares",
	            "look straight down at it", "type /why" },
	  pass = "the reply says  zone: plot  and a number. If it says filler or "
	      .. "outside city, STOP AND TELL ME -- the plots are in the wrong "
	      .. "place and nothing about owning them will work. Worth trying on a "
	      .. "road too: that one should say filler",
	  run = { "/why" },
	  log = "[ServerWorks] where the city landed" },

	{ id = "city-style-panel", group = "city",
	  title = "The colour picker shows real colours",
	  steps = { "type /citystyle", "look at the grid of colours" },
	  pass = "forty coloured squares. If they are all grey or invisible, tell "
	      .. "me -- I know which line to change",
	  run = { "/citystyle" } },

	{ id = "city-style-apply", group = "city",
	  title = "The city gets built out of what you picked",
	  steps = { "type /citystyle", "pick a block and a colour for PAD",
	            "press BUILD CITY again" },
	  pass = "the new city is made of what you picked. Note: it only changes "
	      .. "when you build it again -- an existing city never restyles" },

	{ id = "city-preset", group = "city",
	  title = "A ready-made look works",
	  steps = { "type /citystyle arctic", "press BUILD CITY again" },
	  pass = "the whole city changes look at once",
	  run = { "/citystyle", "arctic" } },

	{ id = "city-map", group = "city",
	  title = "The little map matches the real city",
	  steps = { "type /plotmenu", "compare the map on screen with what is outside" },
	  pass = "no odd line of the wrong material running across a road. The "
	      .. "plaza is the blue square in the middle" },

	{ id = "city-clear", group = "city",
	  title = "Clearing the city leaves your own build alone",
	  steps = { "build something small of your own on a plot",
	            "type /plotmenu", "press CLEAR CITY and confirm twice" },
	  pass = "the city disappears and the thing you built is still there" },

	--[[ plots ]]

	{ id = "plots-on", group = "plots",
	  title = "Plot ownership is switched on",
	  steps = { "type /set plots on" },
	  pass = "it says ok. Without this nothing in this group or the next one is "
	      .. "switched on at all",
	  run = { "/set", "plots", "on" } },

	{ id = "plots-claim", group = "plots",
	  title = "You can claim the plot you stand on",
	  steps = { "stand on a concrete square", "type /plot claim" },
	  pass = "it tells you which plot number is now yours",
	  run = { "/plot", "claim" } },

	{ id = "plots-build-own", group = "plots",
	  title = "You can build on your own plot",
	  steps = { "type /event start 0 30", "put a block down on your own concrete" },
	  pass = "the block goes down. This is the oldest problem in the project, "
	      .. "so it is worth a minute" },

	{ id = "plots-refuse-other", group = "plots",
	  title = "You cannot build on a plot that is not yours",
	  steps = { "stand on the road", "try to place a block onto a plot that is "
	            .. "claimed by somebody else" },
	  pass = "the block will not go down" },

	{ id = "plots-empty-locked", group = "plots",
	  title = "An empty claimed plot stays protected",
	  steps = { "claim a plot", "walk off it onto the road",
	            "try to place a block on it from there" },
	  pass = "it will not let you. Otherwise anybody could reach over and build "
	      .. "on your plot while you are away" },

	{ id = "plots-zoneheld", group = "plots",
	  title = "Standing on the edge of your plot does not lock you out",
	  steps = { "claim a plot", "stand right on the edge of it, on the border",
	            "build" },
	  pass = "it is still yours and you can still build" },

	{ id = "plots-team", group = "plots",
	  title = "Two neighbours can share their plots",
	  steps = { "type /plot team and their name",
	            "have them type the same at you" },
	  pass = "you are teamed up. Only works for the plot in front, behind, left "
	      .. "or right of you -- never a corner",
	  needs = "guest" },

	{ id = "plots-leave", group = "plots",
	  title = "You can give a plot back",
	  steps = { "type /plot leave" },
	  pass = "the plot is free again and shows as free on the map",
	  run = { "/plot", "leave" } },

	{ id = "plots-home", group = "plots",
	  title = "/home takes you back to your plot",
	  steps = { "walk to the far side of the city", "type /home" },
	  pass = "you end up back on your own plot",
	  run = { "/home" } },

	{ id = "plots-myplot", group = "plots",
	  title = "The MY PLOT panel works",
	  steps = { "type /menu and open MY PLOT",
	            "try claim, find, team and leave" },
	  pass = "each button does something and tells you what it did on the "
	      .. "panel, and the panel stays open",
	  run = { "/myplot" } },

	{ id = "plots-marker", group = "plots",
	  title = "The compass points at your plot",
	  steps = { "claim a plot", "walk away from it", "look at the compass" },
	  pass = "there is a marker on the compass showing where your plot is" },

	{ id = "plots-persist", group = "plots",
	  title = "Your plot is still yours after a reload",
	  steps = { "claim a plot", "quit to the menu",
	            "load the SAME world again", "type /plot info" },
	  pass = "it still says the plot is yours" },

	--[[ limits ]]

	{ id = "limit-set", group = "limits",
	  title = "Turn the limits on",
	  steps = { "type /set plots on" },
	  pass = "it says ok. The limits themselves are already set -- 10 bearings, "
	      .. "1 craftbot, 25 lights per plot -- but NOTHING is enforced until "
	      .. "plots are on. That is why none of this has ever happened at an "
	      .. "event",
	  run = { "/set", "plots", "on" } },

	{ id = "limit-locks", group = "limits",
	  title = "Going over the limit stops you building",
	  steps = { "put 12 bearings on your plot", "wait a second",
	            "try to place another block" },
	  pass = "it will not let you place any more on that plot" },

	{ id = "limit-scoped", group = "limits",
	  title = "Only the plot that went over gets stopped",
	  steps = { "with one plot over the limit, go and build on a different plot" },
	  pass = "the other plot is completely unaffected" },

	{ id = "limit-trim", group = "limits",
	  title = "You can still REMOVE things while over the limit",
	  steps = { "while over the limit, try to break one of the bearings" },
	  pass = "it breaks. This is the one you told me about -- being stuck "
	      .. "unable to remove the thing that was blocking you" },

	{ id = "limit-reopen", group = "limits",
	  title = "Removing a part unlocks the plot again quickly",
	  steps = { "delete one bearing", "count how long until you can build again" },
	  pass = "about a second. If it takes five, tell me the number -- it means "
	      .. "the fast check is not running" },

	{ id = "limit-creation", group = "limits",
	  title = "A car with 4 bearings counts as 4, not 16",
	  steps = { "build one vehicle with 4 bearings on it", "type /budget" },
	  pass = "it says 4. If a plot locks up at about a QUARTER of the limit, "
	      .. "tell me -- that is a known risk and I know what to fix",
	  run = { "/budget" } },

	{ id = "limit-budget", group = "limits",
	  title = "/budget tells you what your plot is using",
	  steps = { "stand on a plot with something built on it", "type /budget" },
	  pass = "it lists what is on the plot against what is allowed, for the "
	      .. "plot you are actually standing on",
	  run = { "/budget" } },

	{ id = "limit-lights", group = "limits",
	  title = "The light limit works",
	  steps = { "type /set maxlights 4", "put 6 lights on your plot",
	            "wait a second, then try to place another block" },
	  pass = "the plot stops taking blocks until you take some lights off. "
	      .. "There are three limits in the mod and this is the second of them",
	  run = { "/set", "maxlights", "4" } },

	{ id = "limit-bots", group = "limits",
	  title = "The craftbot limit works",
	  steps = { "type /set maxbots 1", "put 2 craftbots on your plot",
	            "wait a second, then try to place another block" },
	  pass = "the plot stops taking blocks until one of them goes",
	  run = { "/set", "maxbots", "1" } },

	--[[ the event clock ]]

	{ id = "event-start", group = "event",
	  title = "The event clock starts",
	  steps = { "type /event start 1 2, or use EVENT CLOCK on /menu" },
	  pass = "chat says the event started and a timer appears in the top right "
	      .. "corner" },

	{ id = "event-typed", group = "event",
	  title = "Typing a number into the clock does not crash the game",
	  steps = { "open EVENT CLOCK on /menu", "click one of the time boxes",
	            "type a number and press Enter" },
	  pass = "the game is still running. It used to crash outright here. The "
	      .. "number does not appear straight away -- that is on purpose" },

	{ id = "event-hud", group = "event",
	  title = "The timer counts down where you can see it",
	  steps = { "look at the top right corner of your screen" },
	  pass = "a timer, on screen, counting down, not cut off by the edge" },

	{ id = "event-prep", group = "event",
	  title = "Before build time starts, nobody can build",
	  steps = { "during the prep countdown, try to place a block",
	            "then try to paint one" },
	  pass = "you cannot build, but painting and everything else still works" },

	{ id = "event-build", group = "event",
	  title = "Build time actually opens the plots",
	  steps = { "wait for build time, or type /event skip",
	            "stand on your plot, point at the concrete, type /why",
	            "then place a block" },
	  pass = "/why says buildable=true, and the block goes down",
	  run = { "/why" },
	  log = "[ServerWorks] event" },

	{ id = "event-buffer", group = "event",
	  title = "In the last few minutes you can tidy but not build",
	  steps = { "get to the buffer phase at the end",
	            "try to paint something, then try to place a block" },
	  pass = "painting works, placing does not" },

	{ id = "event-end", group = "event",
	  title = "When the event ends, everything freezes",
	  steps = { "let the clock run out, or type /event stop" },
	  pass = "nothing can be placed or broken any more. This is the whole point "
	      .. "of the mod and it has never been tried in a real event" },

	{ id = "event-snapshots", group = "event",
	  title = "The event saves itself at each stage",
	  steps = { "run one short event from start to finish", "type /snapshots" },
	  pass = "four saves are listed, one per stage of the event",
	  run = { "/snapshots" } },

	{ id = "event-panel", group = "event",
	  title = "The event buttons all do something",
	  steps = { "on the EVENT CLOCK panel, press pause, resume, skip, add and stop" },
	  pass = "each one tells you what it did on the panel, and the panel stays "
	      .. "open" },

	--[[ protection ]]

	{ id = "prot-lockdown", group = "protect",
	  title = "/lockdown freezes everything a guest can touch",
	  steps = { "type /lockdown",
	            "walk WELL away from anything you care about -- 5 metres or more",
	            "try to place a block, then try to break one",
	            "check your hotbar: the lift, the paint tool and the rest are "
	            .. "still yours" },
	  pass = "neither placing nor breaking works out there, and you still have "
	      .. "every tool. A lockdown takes everything off a GUEST and nothing "
	      .. "off you",
	  run = { "/lockdown" } },

	{ id = "prot-hostbuild", group = "protect",
	  title = "You can still fix things where you stand",
	  steps = { "with the world still locked, walk up to something and try to "
	            .. "place a block on it",
	            "walk 10 metres away and try the same thing again",
	            "type /protection" },
	  pass = "close up it works, far away it does not, and /protection says the "
	      .. "bubble is open. There is no way to give ONE person permission in "
	      .. "this engine -- a block is placeable by everybody or by nobody -- "
	      .. "so the mod unlocks the few metres around you and locks them again "
	      .. "when you walk off. If somebody else is standing next to you it "
	      .. "stays shut, and /protection says so",
	  run = { "/protection" } },

	{ id = "prot-lockdown-fire", group = "protect",
	  title = "A lockdown puts the fire out too",
	  steps = { "/set fire on", "/unlock", "/lockdown", "/protection",
	            "then /unlock again and check /settings" },
	  pass = "fire is off while the world is shut and back to ON when you "
	      .. "unlock. Fire, cratering and tapebots are engine switches rather "
	      .. "than block permissions, so freezing every body never touched "
	      .. "them. Your own setting is never overwritten",
	  run = { "/lockdown" } },

	{ id = "prot-unlock", group = "protect",
	  title = "/unlock lets people build again",
	  steps = { "type /unlock", "place a block on your plot" },
	  pass = "it goes down. This is your emergency exit -- if anything ever "
	      .. "goes wrong mid-event and people are stuck frozen, this is the way "
	      .. "out",
	  run = { "/unlock" } },

	{ id = "prot-protection", group = "protect",
	  title = "/protection tells you what state the world is in",
	  steps = { "type /protection" },
	  pass = "it lists the mode and some counts. There is a line saying "
	      .. "PhysicsQuality -- tell me what number it says, nobody has ever "
	      .. "looked",
	  run = { "/protection" } },

	{ id = "prot-alarm-quiet", group = "protect",
	  title = "Deleting a normal amount does not set off the alarm",
	  steps = { "delete a patch of your own build, roughly 250 blocks" },
	  pass = "nothing happens. A false alarm in the middle of an event would be "
	      .. "worse than no alarm" },

	{ id = "prot-alarm-fires", group = "protect",
	  title = "Deleting a LOT does set off the alarm",
	  steps = { "delete more than 400 blocks at once" },
	  pass = "chat says that N blocks have disappeared. This is the only way "
	      .. "the mod can notice somebody wrecking the place",
	  log = "[ServerWorks] GRIEF ALARM" },

	{ id = "prot-litter", group = "protect",
	  title = "Dropped junk can always be cleared away",
	  steps = { "drop a craftbot on the plaza", "type /lockdown",
	            "try to delete it by hand, then delete it with the Cleaner tool" },
	  pass = "by hand it will NOT go -- a strict lockdown means nothing works -- "
	      .. "and the Cleaner takes it anyway, because the Cleaner ignores every "
	      .. "permission. So dropped junk is never stuck, it is just yours to "
	      .. "clear while the world is shut" },

	{ id = "prot-ground-pin", group = "protect",
	  title = "Nobody can carry a plot away outside build time",
	  steps = { "during the prep countdown, aim a lift at a plot floor",
	            "then during build time, try the same thing" },
	  pass = "prep: it will not pick it up. Build time: it will. During an event "
	      .. "the plot belongs to whoever is building on it" },

	{ id = "prot-purge-guard", group = "protect",
	  title = "A big clean-up never eats the city itself",
	  steps = { "drop something on a road", "stand next to it",
	            "type /purge here 10" },
	  pass = "the thing you dropped is gone and the road, the plaza and the "
	      .. "platform are all still there" },

	{ id = "prot-why", group = "protect",
	  title = "/why explains why something is locked",
	  steps = { "point at anything", "type /why" },
	  pass = "it tells you where that thing is and what is allowed on it. This "
	      .. "is the most useful command in the mod for testing -- it answers "
	      .. "most of the questions on this list",
	  run = { "/why" } },

	--[[ tools ]]

	{ id = "tool-list", group = "tools",
	  title = "/tool says what you are holding",
	  steps = { "hold anything", "type /tool" },
	  pass = "it names what is in your hand. Useful because there are several "
	      .. "lifts and they look identical",
	  run = { "/tool" } },

	{ id = "tool-icons", group = "tools",
	  title = "The three tools have icons and names in the menu",
	  steps = { "open the creative menu",
	            "look for NOTlift, Cleaner and Focus" },
	  pass = "each one has its own picture and a name under it. A tool with no "
	      .. "name is the reason you once could not find your deleting thing" },

	{ id = "tool-cleaner-block", group = "tools",
	  title = "The Cleaner deletes one block",
	  steps = { "equip the Cleaner", "point at a block", "click" },
	  pass = "that block disappears" },

	{ id = "tool-cleaner-f", group = "tools",
	  title = "Holding F deletes the whole build",
	  steps = { "point at a build with the Cleaner", "hold F" },
	  pass = "the whole thing goes, not just one block" },

	{ id = "tool-cleaner-prop", group = "tools",
	  title = "The Cleaner can delete a craftbot",
	  steps = { "drop a craftbot on the ground",
	            "click it with the Cleaner" },
	  pass = "it disappears. Nothing else in the game can get rid of these -- "
	      .. "the remove tool just picks them up" },

	{ id = "tool-cleaner-city", group = "tools",
	  title = "The Cleaner refuses to eat the city",
	  steps = { "click the platform with it, then a plot floor",
	            "then drop a metal 2 block OUTSIDE the city and click that" },
	  pass = "the city parts are refused with a reason, but your own block "
	      .. "outside the city deletes fine" },

	{ id = "tool-notlift", group = "tools",
	  title = "NOTlift brings in a saved creation",
	  steps = { "equip NOTlift", "click", "pick one of your saved creations" },
	  pass = "it appears, only ONE of it, sitting on a lift, and it is not "
	      .. "frozen in place" },

	{ id = "tool-notlift-release", group = "tools",
	  title = "Letting it off the lift leaves it standing",
	  steps = { "release the creation from the lift" },
	  pass = "it stays where it is and the lift is gone. Watch for a lift left "
	      .. "behind that you cannot remove" },

	{ id = "tool-lift-host", group = "tools",
	  title = "Guests cannot use the lift when you turn it off",
	  steps = { "type /set hostlift on",
	            "have somebody else try to hold the lift" },
	  pass = "it gets taken out of their hands almost immediately",
	  needs = "guest" },

	{ id = "tool-focus", group = "tools",
	  title = "The Focus tool marks somebody",
	  steps = { "equip Focus", "point at a player", "click" },
	  pass = "a marker appears over them with their name under it" },

	--[[ saves ]]

	{ id = "backup-snapshot", group = "backup",
	  title = "/snapshot saves the world",
	  steps = { "type /snapshot test" },
	  pass = "it tells you what it saved",
	  run = { "/snapshot", "test" } },

	{ id = "backup-list", group = "backup",
	  title = "/snapshots lists your saves",
	  steps = { "type /snapshots" },
	  pass = "your save is in the list",
	  run = { "/snapshots" } },

	{ id = "backup-restore", group = "backup",
	  title = "You can put the world back from a save",
	  steps = { "build something", "type /snapshot test",
	            "delete some of what you built",
	            "type /restore test TWICE -- it asks you to confirm" },
	  pass = "everything comes back the way it was. THIS IS THE MOST IMPORTANT "
	      .. "ONE ON THE WHOLE LIST. Saving is known to work, but putting it back "
	      .. "has never once been tried, and a backup you have never restored "
	      .. "from is not really a backup at all" },

	{ id = "backup-restore-plot", group = "backup",
	  title = "You can put back just one plot",
	  steps = { "type /restore test and a plot number, twice" },
	  pass = "only that plot changes. This is how you undo the damage one "
	      .. "person did without wrecking the night for everybody else" },

	{ id = "backup-autosave", group = "backup",
	  title = "Autosave keeps saving on its own",
	  steps = { "type /autosave 2", "wait a few minutes",
	            "type /snapshots" },
	  pass = "saves called auto1, auto2 and so on appear by themselves",
	  run = { "/autosave", "2" } },

	--[[ bans and kicks ]]

	{ id = "admin-players", group = "admin",
	  title = "/players lists everyone with a number",
	  steps = { "type /players" },
	  pass = "names and numbers. The number is how you target somebody whose "
	      .. "name has a space in it",
	  run = { "/players" } },

	{ id = "guest-nocommands", group = "guest",
	  title = "A guest has no chat commands except /menu",
	  steps = { "have them type /plot claim, /players and /rules",
	            "have them type /menu" },
	  pass = "the first three are refused and point them at /menu, which opens. "
	      .. "Everything they need is on it -- if anything is NOT, that is the "
	      .. "bug, not the refusal",
	  needs = "guest" },

	{ id = "admin-names", group = "admin",
	  title = "You can kick somebody whose name has a space in it",
	  steps = { "try to kick or ban somebody with a space in their name" },
	  pass = "it finds them. The kick command built into the game cannot do "
	      .. "this at all",
	  needs = "guest" },

	{ id = "admin-ban", group = "admin",
	  title = "Banning actually works",
	  steps = { "type /ban and their name" },
	  pass = "they are removed and cannot get back in. You said this one is the "
	      .. "only real defence, so it matters more than most",
	  needs = "guest" },

	{ id = "admin-banlist", group = "admin",
	  title = "The ban list survives a restart",
	  steps = { "type /banlist", "restart the game", "type /banlist again" },
	  pass = "the same names are still there",
	  run = { "/banlist" } },

	{ id = "admin-unban", group = "admin",
	  title = "/unban lets somebody back in",
	  steps = { "type /unban and their name", "type /banlist" },
	  pass = "they are gone from the list" },

	{ id = "admin-ban-offline", group = "admin",
	  title = "You can ban somebody who has left, without typing their name",
	  steps = { "open /menu and press BANS",
	            "find somebody who is not online and press BAN on their row",
	            "press BANNED and check they are on the list" },
	  pass = "they are on the ban list, filed under their SW- id. Nothing was "
	      .. "typed -- which is the whole point, because a Scrap Mechanic name "
	      .. "can hold characters you cannot type at all" },

	{ id = "admin-ban-find", group = "admin",
	  title = "The FIND box narrows the list and never bans anything",
	  steps = { "open /menu, BANS, type part of a name into FIND and press Enter",
	            "type an SW- id instead",
	            "clear the box and press Enter" },
	  pass = "the list narrows, then narrows differently, then comes back whole. "
	      .. "Pressing Enter must never ban anybody by itself" },

	{ id = "admin-joinmode", group = "admin",
	  title = "The panel names the right multiplayer mode",
	  steps = { "set Options, Gameplay, Multiplayer to Public",
	            "open /menu, BANS, and read the line in the top right",
	            "set it to Invite Only and look again" },
	  pass = "it names the mode you actually chose. The order is a guess -- the "
	      .. "five names are certain, the number behind each is not, so write "
	      .. "down the number it prints beside each mode and this gets fixed",
	  run = { "/protection" } },

	{ id = "admin-joinchange", group = "admin",
	  title = "Changing who can join warns you, and says who it will drop",
	  steps = { "with somebody else in the world, open Options, Gameplay",
	            "change Multiplayer to a narrower setting" },
	  pass = "you get a chat warning within a second naming the new mode and how "
	      .. "many other players are in the world. This is measured, not a "
	      .. "guess: narrowing it throws out everyone the new setting does not "
	      .. "allow, one tick later, and the game itself says nothing useful",
	  needs = "guest" },

	{ id = "admin-ban-across-worlds", group = "admin",
	  title = "A ban survives making a brand new world",
	  steps = { "ban somebody, then check WHO IS HERE, BANNED",
	            "quit, make a NEW world from this mod",
	            "check BANNED again" },
	  pass = "the same names are still there. A ban describes a person, not a "
	      .. "world -- unlike the plot claims and the clock, which SHOULD reset" },

	{ id = "admin-allow", group = "admin",
	  title = "The guest list keeps everyone else out",
	  steps = { "open /menu, BANS, and press the allow list switch to turn it on",
	            "press ALLOW on the people who should be let in",
	            "have somebody not on the list try to join" },
	  pass = "only people on the list can join, and your own row says you are "
	      .. "always allowed rather than claiming you are locked out. Stronger "
	      .. "than banning, and never tried",
	  needs = "guest" },

	{ id = "admin-allow-before", group = "admin",
	  title = "The allow list can be filled in before anybody arrives",
	  steps = { "with nobody else online, open /menu, BANS",
	            "turn the allow list on and press ALLOW on somebody" },
	  pass = "it works with an empty server. That is the whole point of an "
	      .. "allow list -- it has to be ready BEFORE the event, not built "
	      .. "during one" },

	{ id = "prot-citybuild", group = "protect",
	  title = "The city can be opened up for building, and is shut by default",
	  steps = { "try to place a block on a road or the plaza -- it should refuse",
	            "open /menu, SERVER SETTINGS, PLOTS, and turn citybuild on",
	            "try again" },
	  pass = "off, the roads and the plaza cannot be built on or erased. On, "
	      .. "they behave like ordinary ground. A /lockdown must still freeze "
	      .. "them either way",
	  run = { "/set", "citybuild", "on" } },

	{ id = "prot-citybuild-all", group = "protect",
	  title = "Free build reaches every part of the city, seams included",
	  steps = { "turn citybuild on",
	            "place and break a block on a road, on the plaza, and on the "
	            .. "one block wide seam between two plots" },
	  pass = "all three take a block and give it back. The seams are the ones "
	      .. "to check -- they were left out of the first version of this and "
	      .. "nothing on screen would tell you which square is a seam" },

	{ id = "boot-unstuck", group = "boot",
	  title = "The unstuck button drops you above the middle of the city",
	  steps = { "walk well away from the middle",
	            "open the game menu and press the unstuck button" },
	  pass = "you land on the plaza, in the middle, with a short drop. Vanilla "
	      .. "sent you to 16,16 -- the same wrong spot every time, off the city" },

	--[[ load test ]]

	{ id = "crowd-developer", group = "crowd",
	  title = "/developer on puts the dev tools on the menu, off takes them away",
	  steps = { "type /menu and count the buttons on the right",
	            "close it, type /developer on, open /menu again",
	            "type /developer off, and try /crowd 5" },
	  pass = "DEV TOOLS and TESTING CHECKLIST appear only while it is on, and "
	      .. "/crowd refuses while it is off. /crowd off must still work either way",
	  run = { "/developer", "on" } },

	{ id = "crowd-spawn", group = "crowd",
	  title = "/crowd puts fake players on the city",
	  steps = { "type /crowd 5" },
	  pass = "five characters appear. If it says they all failed, tell me -- "
	      .. "that part of the mod is the least proven thing in it",
	  run = { "/crowd", "5" } },

	{ id = "crowd-looks", group = "crowd",
	  title = "They do not all look the same",
	  steps = { "look at them" },
	  pass = "different outfits, men and women. Twenty identical ones means "
	      .. "something is wrong" },

	{ id = "crowd-move", group = "crowd",
	  title = "They walk around and have names",
	  steps = { "watch them for ten seconds" },
	  pass = "they wander about and each has a name floating over them" },

	{ id = "crowd-claim", group = "crowd",
	  title = "A fake player never locks you out of a plot",
	  steps = { "type /crowd claim on",
	            "stand on a plot one of them is on", "try to build" },
	  pass = "you can still build. And /crowd off should give every plot back",
	  run = { "/crowd", "claim", "on" } },

	{ id = "crowd-off", group = "crowd",
	  title = "/crowd off cleans up completely",
	  steps = { "type /crowd off", "look around, and check /plotmenu" },
	  pass = "no characters left, no blocks of theirs left, no plots still "
	      .. "owned by them",
	  run = { "/crowd", "off" } },

	{ id = "bench-run", group = "crowd",
	  title = "/bench measures how much the server can take",
	  steps = { "type /bench start", "leave it alone until it finishes" },
	  pass = "it prints a table of results at the end. If the first row says a "
	      .. "frame rate nothing like what you are actually seeing, tell me the "
	      .. "two numbers",
	  run = { "/bench", "start" } },

	--[[ needs somebody else ]]

	{ id = "guest-join", group = "guest",
	  title = "Somebody else can join at all",
	  steps = { "have one person join your world" },
	  pass = "they get in and can move around",
	  needs = "guest" },

	{ id = "guest-focus", group = "guest",
	  title = "Other people can see the focus marker",
	  steps = { "focus them, and ask what they see",
	            "focus yourself, and ask again" },
	  pass = "they can see a marker over their own head and over yours. The "
	      .. "whole point of that feature is what OTHER people see, and so far "
	      .. "only your own screen has ever been checked",
	  needs = "guest" },

	{ id = "guest-panels", group = "guest",
	  title = "A guest cannot touch the host settings",
	  steps = { "have them open /menu and try everything on it" },
	  pass = "the host buttons are not even offered to them, and nothing they "
	      .. "can reach changes the server",
	  needs = "guest" },

	{ id = "guest-plot", group = "guest",
	  title = "A guest cannot build on your plot",
	  steps = { "have them try from the road, and from standing on it" },
	  pass = "refused both ways",
	  needs = "guest" },

	{ id = "guest-budget", group = "guest", who = "log",
	  title = "The connection keeps up with them",
	  steps = { "play with somebody else for twenty minutes",
	            "I read the log afterwards" },
	  pass = "no long gaps where they stopped receiving updates. This is the "
	      .. "one thing measured on this machine that a player would call "
	      .. "broken -- almost seven seconds of somebody seeing nothing move",
	  log = "Skip sending unreliable network data",
	  needs = "guest" },

	{ id = "guest-freeze", group = "guest",
	  title = "Freezing finished builds helps the connection",
	  steps = { "with somebody connected, play for a while",
	            "type /lockdown", "play a while longer" },
	  pass = "it feels smoother for them once everything is frozen. This is a "
	      .. "guess of mine, not a fact -- it is the one thing the mod already "
	      .. "does that might help the problem above",
	  needs = "guest" },
}


--[[ the pure half -- lookup, counting, paging ]]

function Checklist.Find( id )
	for _, item in ipairs( Checklist.ITEMS ) do
		if item.id == id then return item end
	end
	return nil
end

-- WHAT THE PANEL SHOWS: everything except the ones whose answer is in a log
-- file. Counts run through here too, so the progress bar measures the work the
-- person holding the mouse can actually do -- a bar that can never reach the end
-- is one nobody finishes.
function Checklist.ItemsIn( group )
	local out = {}
	for _, item in ipairs( Checklist.ITEMS ) do
		if item.who ~= "log" and ( group == nil or group == "all" or item.group == group ) then
			out[#out + 1] = item
		end
	end
	return out
end

-- Everything, log items included. For dev/checklist_report.py and the checks:
-- the ledger is one file and both halves of it belong in the same place.
function Checklist.AllItems( group )
	local out = {}
	for _, item in ipairs( Checklist.ITEMS ) do
		if group == nil or group == "all" or item.group == group then
			out[#out + 1] = item
		end
	end
	return out
end

function Checklist.GroupLabel( id )
	for _, g in ipairs( Checklist.GROUPS ) do
		if g.id == id then return g.label end
	end
	return string.upper( tostring( id or "?" ) )
end

-- The state of one item, or "untested". Reading through a function rather than
-- indexing directly is what lets an absent file, an absent entry and a
-- malformed entry all answer the same way instead of erroring in a panel.
function Checklist.StateOf( results, id )
	if type( results ) ~= "table" then return "untested" end
	local r = results[id]
	if type( r ) ~= "table" then return "untested" end
	if not Checklist.IsState( r.state ) then return "untested" end
	return r.state
end

function Checklist.ResultOf( results, id )
	if type( results ) ~= "table" then return nil end
	local r = results[id]
	if type( r ) ~= "table" then return nil end
	return r
end

-- Counts for one group, or for the whole list. `done` is deliberately NOT
-- pass + fail: a blocked item has been looked at and answered, and a checklist
-- that keeps reporting it as outstanding is one nobody finishes.
function Checklist.Counts( results, group )
	local c = { total = 0, pass = 0, fail = 0, blocked = 0, skip = 0,
	            untested = 0, done = 0, guest = 0 }
	for _, item in ipairs( Checklist.ItemsIn( group ) ) do
		c.total = c.total + 1
		if item.needs == "guest" then c.guest = c.guest + 1 end
		local state = Checklist.StateOf( results, item.id )
		c[state] = ( c[state] or 0 ) + 1
		if state ~= "untested" then c.done = c.done + 1 end
	end
	return c
end

-- The next thing to do. Walks the catalogue in its written order from just
-- after `afterId`, wraps once, and skips anything already answered -- so
-- pressing NEXT repeatedly walks a whole session without going back over
-- ground, and stops rather than looping forever when everything is answered.
--
-- Guest-only items are skipped unless asked for: they are the six that cannot
-- be answered alone, and walking a solo host into one is how a session stalls.
function Checklist.NextUntested( results, afterId, includeGuest )
	local items = Checklist.ITEMS
	local start = 1
	if afterId ~= nil then
		for i, item in ipairs( items ) do
			if item.id == afterId then start = i + 1 break end
		end
	end
	for offset = 0, #items - 1 do
		local i = ( ( start - 1 + offset ) % #items ) + 1
		local item = items[i]
		local skippable = ( item.needs == "guest" and includeGuest ~= true )
			or item.who == "log"
		if not skippable and Checklist.StateOf( results, item.id ) == "untested" then
			return item.id
		end
	end
	return nil
end

-- Same shape as FocusGui.Page: clamped rather than validated, so a page number
-- left over from a longer list lands on the last page instead of on an empty
-- panel.
function Checklist.Page( list, page, rows )
	rows = rows or 8
	local total = #list
	local pages = math.max( 1, math.ceil( total / rows ) )
	page = math.max( 1, math.min( pages, math.floor( tonumber( page ) or 1 ) ) )
	local from = ( page - 1 ) * rows + 1
	local slice = {}
	for i = from, math.min( total, from + rows - 1 ) do
		slice[#slice + 1] = list[i]
	end
	return slice, page, pages
end

-- Which page an item is on, so opening an item from anywhere and coming BACK
-- lands on the page it was on rather than on page one.
function Checklist.PageOf( list, id, rows )
	rows = rows or 8
	for i, item in ipairs( list ) do
		if item.id == id then
			return math.floor( ( i - 1 ) / rows ) + 1
		end
	end
	return 1
end

-- The one-line version of an item, for a list row. First step if there is one,
-- because "what do I do" is the question a row has to answer at a glance.
function Checklist.Hint( item )
	if type( item ) ~= "table" then return "" end
	local steps = item.steps
	if type( steps ) == "table" and steps[1] ~= nil then
		local line = tostring( steps[1] )
		if #steps > 1 then line = line .. "  + " .. ( #steps - 1 ) .. " more" end
		return line
	end
	return tostring( item.pass or "" )
end


--[[ writing a result ]]

-- PURE: it mutates the table handed in and returns it. Saving is the caller's
-- job, which is what lets dev/test_logic.py drive every transition without a
-- filesystem.
--
-- Clearing DELETES the entry rather than storing "untested", so the file only
-- ever holds answers somebody actually gave. An untested item is the absence of
-- a record, and a file full of untested entries would make every count depend
-- on whether an item had ever been visited.
function Checklist.Set( results, id, state, note, build, at )
	if type( results ) ~= "table" then results = {} end
	if Checklist.Find( id ) == nil then return results end

	if state == nil or state == "untested" then
		results[id] = nil
		return results
	end
	if not Checklist.IsState( state ) then return results end

	local prev = results[id]
	results[id] = {
		state = state,
		build = build or Checklist.BUILD,
		at = at,
		-- A note survives a state change. Somebody who wrote down what went
		-- wrong, then pressed FAIL, must not lose it -- and passing nil here is
		-- how every state button calls this.
		note = note or ( type( prev ) == "table" and prev.note or nil ),
	}
	return results
end

function Checklist.SetNote( results, id, note )
	if type( results ) ~= "table" then results = {} end
	if Checklist.Find( id ) == nil then return results end
	local r = results[id]
	if type( r ) ~= "table" then
		-- A note on an untested item is worth keeping: "tried this, inconclusive"
		-- is a real answer and losing it would teach people not to write notes.
		r = { state = "untested", build = Checklist.BUILD }
		results[id] = r
	end
	r.note = ( note ~= nil and tostring( note ) ~= "" ) and tostring( note ) or nil
	if r.state == "untested" and r.note == nil then results[id] = nil end
	return results
end


--[[ the summary, for chat and for the log ]]

-- Written to the log as well as to chat, because the log is where this project
-- reads everything else from and a session's result should land in the same
-- place as the evidence for it.
function Checklist.Summary( results )
	local all = Checklist.Counts( results )
	local out = {}
	out[#out + 1] = string.format(
		"CHECKLIST  %d of %d answered   %d worked   %d did not   %d could not "
		.. "try   %d skipped",
		all.done, all.total, all.pass, all.fail, all.blocked, all.skip )
	for _, g in ipairs( Checklist.GROUPS ) do
		local c = Checklist.Counts( results, g.id )
		if c.total > 0 then
			out[#out + 1] = string.format( "  %-11s %2d/%-2d   worked %2d  no %2d",
				g.label, c.done, c.total, c.pass, c.fail )
		end
	end

	-- FAILURES BY NAME. A count of failures is not actionable and a list of them
	-- is: this is the part that gets pasted into a conversation, or read out of
	-- the log by dev/checklist_report.py.
	local fails = {}
	for _, item in ipairs( Checklist.ITEMS ) do
		if Checklist.StateOf( results, item.id ) == "fail" then
			local r = Checklist.ResultOf( results, item.id )
			local line = "  DID NOT WORK  " .. item.id .. "  " .. tostring( item.title )
			if r and r.note then line = line .. "   -- " .. tostring( r.note ) end
			fails[#fails + 1] = line
		end
	end
	if #fails > 0 then
		out[#out + 1] = string.format( "%d did not work:", #fails )
		for _, line in ipairs( fails ) do out[#out + 1] = line end
	end
	return out
end


--[[ persistence ]]

-- Guarded the same way every other file in this mod is. A checklist that takes
-- the server down because a json file went missing would be a poor sort of test
-- harness.
function Checklist.Sv_Load()
	local ok, exists = pcall( sm.json.fileExists, Checklist.FILE )
	if not ( ok and exists ) then return {} end
	local read, data = pcall( sm.json.open, Checklist.FILE )
	if not ( read and type( data ) == "table" ) then return {} end
	if type( data.results ) ~= "table" then return {} end

	-- Entries for ids that no longer exist are dropped on load rather than kept:
	-- they cannot be shown, cannot be cleared from the panel, and would sit in
	-- the file forever confusing the counts in the report.
	local out = {}
	for id, r in pairs( data.results ) do
		if type( r ) == "table" and Checklist.Find( id ) ~= nil then
			out[id] = { state = Checklist.IsState( r.state ) and r.state or "untested",
			            build = tonumber( r.build ) or nil,
			            at = tonumber( r.at ) or nil,
			            note = r.note ~= nil and tostring( r.note ) or nil }
		end
	end
	return out
end

function Checklist.Sv_Save( results )
	local counts = Checklist.Counts( results )
	local ok, err = pcall( sm.json.save, {
		build = Checklist.BUILD,
		-- Written for the reader, not for the loader: dev/checklist_report.py
		-- prints these without having to recompute them, and a human opening the
		-- file sees the state of the session in its first three lines.
		summary = {
			total = counts.total, answered = counts.done,
			pass = counts.pass, fail = counts.fail,
			blocked = counts.blocked, skip = counts.skip,
		},
		results = results or {},
	}, Checklist.FILE )
	if not ok then
		sm.log.warning( "[ServerWorks] could not write the checklist: " .. tostring( err ) )
		return false
	end
	return true
end
