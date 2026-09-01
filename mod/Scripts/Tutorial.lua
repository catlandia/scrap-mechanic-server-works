-- Tutorial -- what this mod is, for the three people who open it.
--
-- ASKED FOR: "tutorial. for both hosts, devs, and regular players. and adding
-- something like EULA idk. like please use this mod wisely or sum like that."
--
-- THE MOD HAD 217 CHECKS AND NOTHING THAT TOLD ANYBODY WHAT IT DOES. Every
-- panel explains its own buttons and none of them explains the point -- a
-- builder joining an event has no idea a plot has to be claimed, and a host
-- opening it for the first time is looking at eleven buttons with no order to
-- press them in.
--
-- THREE SECTIONS YOU PICK BETWEEN, one menu entry. Asked for exactly:
--
--   "you can select for players for hosts and for devs. the players can only
--    acces for players and host can access both. but not the dev. if the dev
--    mode is on then hosts can access them all"
--
-- So the access rule is a table, not prose -- see Tutorial.CanRead. A guest
-- gets one section and never sees the others exist; a host gets two; developer
-- mode is what unlocks the third, for a host only.
--
-- Sections rather than one long read because the three audiences want different
-- things at different moments: a builder wants the plot rules NOW, a host wants
-- the setup order before an event, and neither wants to page past the other.
--
-- PLAIN ASCII, and that is not decoration. The game builds a glyph atlas per
-- font out of the strings it renders itself, so an apostrophe or an ellipsis
-- can come out as a hollow box. This is by far the most prose the mod draws
-- after the checklist, and a check holds it inside the characters the
-- already-shipped panels are known to draw.

Tutorial = {}

-- THE THREE SECTIONS, in the order they are offered. `who` on a page names the
-- section it belongs to.
--
-- Ids stay "all"/"host"/"dev" and the LABELS are what anybody reads: the id is
-- the access rule and the label is the audience, and conflating them is how a
-- rename turns into a permission change.
Tutorial.SECTIONS = {
	{ id = "all",  label = "FOR PLAYERS" },
	{ id = "host", label = "FOR HOSTS" },
	{ id = "dev",  label = "FOR DEVS" },
}

-- THE ACCESS RULE, in one place because five things ask it: the tabs, the page
-- lookup, the panel opener, the clamp and the check.
--
-- Note what developer mode does NOT do: it never opens a section to a guest.
-- It is a host switch, so it can only ever widen what a host sees.
function Tutorial.CanRead( who, isHost, developer )
	if who == "all" then return true end
	if not isHost then return false end
	if who == "host" then return true end
	if who == "dev" then return developer == true end
	return false
end

-- The sections this person may choose between, in order.
function Tutorial.SectionsFor( isHost, developer )
	local out = {}
	for _, sec in ipairs( Tutorial.SECTIONS ) do
		if Tutorial.CanRead( sec.id, isHost, developer ) then
			out[#out + 1] = sec
		end
	end
	return out
end

function Tutorial.PagesIn( who )
	local out = {}
	for _, page in ipairs( Tutorial.PAGES ) do
		if page.who == who then out[#out + 1] = page end
	end
	return out
end

-- Which section this person is actually looking at. Clamped rather than
-- refused: a guest arriving with section = "dev" -- from a stale panel, or from
-- a client that made it up -- lands on the one they may read instead of an
-- empty screen they cannot explain.
function Tutorial.SectionFor( wanted, isHost, developer )
	if wanted ~= nil and Tutorial.CanRead( wanted, isHost, developer ) then
		return wanted
	end
	local open = Tutorial.SectionsFor( isHost, developer )
	return ( open[1] and open[1].id ) or "all"
end

Tutorial.PAGES = {

	--[[ everybody ]]

	{ id = "what", who = "all", title = "WHAT THIS IS",
	  lines = {
		"Server Works is a custom game for running BUILDING EVENTS -- the kind",
		"where a lobby full of people build at once and somebody has to keep",
		"order.",
		"",
		"The host lays out a CITY of numbered plots. You claim one and you build",
		"on it. While you are away it is locked to everybody. While you are",
		"standing on it, it is open, and people who do not belong get pushed off",
		"it. When the event ends the host can freeze everything, and roll the",
		"whole world back if somebody wrecks it.",
		"",
		"Press MY PLOT on the menu to get started. Everything else on that menu",
		"is optional.",
	  } },

	{ id = "plot", who = "all", title = "GETTING A PLOT",
	  lines = {
		"1. Walk onto an empty square of the city. The green squares are plots.",
		"2. Open the menu, press MY PLOT, then press CLAIM.",
		"3. That plot is now yours. Build on it.",
		"",
		"FIND MY PLOT puts a marker on your compass if you lose it.",
		"GIVE IT UP hands it back so somebody else can claim it.",
		"",
		"Walk onto a plot that is not yours and you get pushed off it. That is",
		"not a bug -- it is the whole of how ownership works here.",
		"",
		"Scrap Mechanic has no per-player permission: a block is placeable by",
		"everybody or by nobody, so being pushed off IS the protection. An empty",
		"claimed plot is locked outright, which is why nobody can touch yours",
		"while you are away.",
	  } },

	{ id = "team", who = "all", title = "BUILDING WITH A FRIEND",
	  lines = {
		"Two people can share their plots and the ground between them.",
		"",
		"Stand on your own plot, open MY PLOT, and press TEAM UP on the person",
		"you want to build with. THEY HAVE TO DO THE SAME BACK. Until both of",
		"you have asked, nothing changes.",
		"",
		"Only the plot in front, behind, left or right of yours -- never corner",
		"to corner. Teams chain, so if you team your neighbour and they team",
		"theirs, all three of you share.",
	  } },

	{ id = "rules", who = "all", title = "WHAT THE SERVER STOPS YOU DOING",
	  lines = {
		"SERVER RULES on the menu prints the limits actually in force. It reads",
		"them from the live settings, so it can never be out of date.",
		"",
		"Common ones: a cap on bearings and pistons per plot, a cap on lights,",
		"one craftbot each, and no building before the host says go.",
		"",
		"Go over a limit and your plot stops accepting NEW parts. You can still",
		"remove things -- that is deliberate, so you can get back under the cap.",
		"",
		"Banned parts are a separate thing. By default the server only warns",
		"about them, but a host can switch on automatic removal, in which case a",
		"radio or a horn you place may simply vanish. SERVER RULES says which",
		"parts those are.",
	  } },

	{ id = "chat", who = "all", title = "THE MENU IS THE CONTROLS",
	  lines = {
		"There is one command you need and it is  /menu",
		"",
		"Everything else is a button on it. Chat commands are host only, so if",
		"you type one and it refuses, that is expected -- open the menu instead.",
		"",
		"Top left shows who is online. Top right shows the event clock when one",
		"is running, and whether building is open.",
	  } },

	--[[ the host ]]

	{ id = "wisely", who = "host", title = "PLEASE USE THIS WISELY",
	  lines = {
		"This mod hands you real power over other people. Read this once.",
		"",
		"You can freeze what somebody spent an hour building, delete it, push",
		"them off ground they claimed, take their tools away, kick them, and ban",
		"them permanently. None of that asks them first and none of it is",
		"obvious from their side -- a locked plot just stops working.",
		"",
		"So: tell people the rules before you enforce them. Warn before you",
		"lock. Take a backup before you clear anything. A ban is forever and it",
		"follows a person across every world you make.",
		"",
		"The tools are here because an event needs them. They are not here to",
		"win arguments.",
	  } },

	{ id = "setup", who = "host", title = "SETTING UP AN EVENT",
	  lines = {
		"1. CITY LAYOUT -- choose how many plots and how big, then BUILD CITY.",
		"2. SERVER SETTINGS -- press the BUILD preset. It turns off fire, damage",
		"   explosives and the rest, and pins the powerful tools to you.",
		"3. EVENT CLOCK -- set prep and build minutes, then START.",
		"",
		"Prep time lets people claim a plot without building. When it ends,",
		"building opens by itself. When the clock runs out everything freezes",
		"and a snapshot is taken automatically.",
	  } },

	{ id = "protect", who = "host", title = "WHEN SOMETHING GOES WRONG",
	  lines = {
		"PROTECTION -- LOCK DOWN freezes the whole world. Nobody can place,",
		"break, paint or use anything. UNLOCK gives it back.",
		"",
		"That includes YOU. A lockdown is total by default -- you cannot build",
		"either. MY BUBBLE on the protection panel turns on a few metres around",
		"you so you can fix things, and another player standing next to you",
		"closes it again while they are there.",
		"",
		"BACKUPS -- SAVE NOW before anything risky. RESTORE puts the whole world",
		"back. It DELETES first and rebuilds, so it asks twice.",
		"",
		"The grief alarm watches for mass deletion on its own and will shout.",
	  } },

	{ id = "people", who = "host", title = "PEOPLE, BANS AND THE GUEST LIST",
	  lines = {
		"BANS lists everyone the server has ever seen. Press BAN on a row.",
		"",
		"You never type a name. Scrap Mechanic names can contain characters you",
		"cannot type at all, so every button carries a permanent id instead, and",
		"the ban survives making a new world.",
		"",
		"A ban covers every name that person has used here. It cannot know about",
		"a brand new name until they have been seen using it, so a rename buys",
		"somebody one visit, not an escape.",
		"",
		"The ALLOW LIST is stronger than banning: only people on it may join.",
		"Fill it in BEFORE the event -- that is the only time it is any use.",
	  } },

	{ id = "backupfile", who = "host", title = "THE BACKUP THAT SAVES EVERYTHING",
	  lines = {
		"SAVE NOW inside the game stores the buildings and who owns which plot.",
		"It does NOT store the terrain, your settings or the event clock.",
		"",
		"For a real whole-world backup, copy the save file itself. There is a",
		"script in the dev folder of the mod repo that does exactly that -- run",
		"it with the watch option and every world you touch is copied each time",
		"you quit the game.",
		"",
		"That is the backup that cannot half-work. The README names it.",
	  } },

	--[[ developer mode ]]

	{ id = "dev", who = "dev", title = "DEVELOPER MODE",
	  lines = {
		"You have developer mode on, which is why you can see this page.",
		"",
		"DEV TOOLS -- a fake crowd of up to 128 bots, a benchmark that walks",
		"that number up on its own, and a channel that lets a program outside",
		"the game run host commands.",
		"",
		"TESTING CHECKLIST -- every feature that has never been proven to work,",
		"one at a time, with what to do and what counts as a pass.",
		"",
		"NONE OF THIS BELONGS AT A LIVE EVENT. /developer off hides it all.",
	  } },

	{ id = "honest", who = "dev", title = "WHAT IS ACTUALLY PROVEN",
	  lines = {
		"This mod is a WORK IN PROGRESS and it says so on purpose.",
		"",
		"The checks that run outside the game touch no body, no tool and no",
		"network -- a passing suite means no known logic error, not a working",
		"mod. What has been SEEN working is written down separately, and so is",
		"what has never once been run.",
		"",
		"If something behaves oddly, it is more likely to be untested than to",
		"be broken. The checklist is where you turn one into the other.",
	  } },
}


-- Every page this person may read, across every section they may open. Kept
-- because it is the honest answer to "what can they see", which is what the
-- access checks ask.
function Tutorial.PagesFor( isHost, developer )
	local out = {}
	for _, page in ipairs( Tutorial.PAGES ) do
		if Tutorial.CanRead( page.who, isHost, developer ) then
			out[#out + 1] = page
		end
	end
	return out
end

function Tutorial.Count( isHost, developer )
	return #Tutorial.PagesFor( isHost, developer )
end

-- One page of one section. Clamped rather than validated: a page number left
-- over from a longer section must land on the last page, not on an empty panel.
function Tutorial.Page( who, index )
	local pages = Tutorial.PagesIn( who )
	local n = #pages
	if n == 0 then return nil, 1, 0 end
	index = math.max( 1, math.min( n, math.floor( tonumber( index ) or 1 ) ) )
	return pages[index], index, n
end
