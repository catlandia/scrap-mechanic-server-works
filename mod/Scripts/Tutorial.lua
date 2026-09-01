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
-- ONE ENTRY, THREE AUDIENCES. A guest sees the pages a guest needs; a host sees
-- those plus the host ones; developer mode adds the rest. The alternative was
-- three menu entries, and the menu has a hard ceiling -- see MenuGui.W.
--
-- PLAIN ASCII, and that is not decoration. The game builds a glyph atlas per
-- font out of the strings it renders itself, so an apostrophe or an ellipsis
-- can come out as a hollow box. This is by far the most prose the mod draws
-- after the checklist, and a check holds it inside the characters the
-- already-shipped panels are known to draw.

Tutorial = {}

-- who each page is for. "all" is everybody including guests.
Tutorial.AUDIENCES = { "all", "host", "dev" }

Tutorial.PAGES = {

	--[[ everybody ]]

	{ id = "what", who = "all", title = "WHAT THIS IS",
	  lines = {
		"Server Works is a custom game for running BUILDING EVENTS -- the kind",
		"where a lobby full of people build at once and somebody has to keep",
		"order.",
		"",
		"The host lays out a CITY of numbered plots. You claim one, you build on",
		"it, and nobody can touch it but you. When the event ends the host can",
		"freeze everything, and roll the whole world back if somebody wrecks it.",
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
		"You cannot build on a plot that is not yours, and if you stand on one",
		"you get pushed off. That is not a bug -- it is the whole point.",
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
		"Nothing is ever taken away from you automatically.",
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
		"You keep building where you stand, in a few metres around you, so you",
		"can still fix things. Another player standing next to you closes that.",
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
		"cannot type at all, so every button carries a permanent id instead.",
		"That id survives a rename, and the ban survives making a new world.",
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


-- Which pages this person may read. Pure, so the audience split is checkable
-- without a game.
--
-- A host sees the guest pages too, and in the guest ORDER -- somebody running
-- an event still has to know how claiming a plot works, because they are the
-- one who will be asked.
function Tutorial.PagesFor( isHost, developer )
	local out = {}
	for _, page in ipairs( Tutorial.PAGES ) do
		local who = page.who
		if who == "all"
			or ( who == "host" and isHost )
			or ( who == "dev" and isHost and developer == true ) then
			out[#out + 1] = page
		end
	end
	return out
end

function Tutorial.Count( isHost, developer )
	return #Tutorial.PagesFor( isHost, developer )
end

-- Clamped rather than validated: a page number left over from a longer list
-- must land on the last page, not on an empty panel.
function Tutorial.Page( isHost, developer, index )
	local pages = Tutorial.PagesFor( isHost, developer )
	local n = #pages
	if n == 0 then return nil, 1, 0 end
	index = math.max( 1, math.min( n, math.floor( tonumber( index ) or 1 ) ) )
	return pages[index], index, n
end
