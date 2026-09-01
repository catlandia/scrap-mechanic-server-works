-- Settings -- one place to turn things off.
--
-- The point of this file, in the owner's words: "explosives using is worse than
-- just turning them off". Neutralising damage after the fact still leaves the
-- bang, the fling and the noise. Where the engine lets something be switched off
-- outright, this switches it off outright.
--
-- Be clear about which is which, because they are not the same strength:
--
--   REAL OFF     fire. sm.fire.setFireLimit( 0 ) caps live fire instances at
--                zero. Vanilla sets this to FIRE_INSTANCE_LIMIT in
--                CreativeBaseWorld.server_onCreate; we just set it lower.
--
--   REAL OFF     terrain cratering. Our World.server_onExplosion declines to
--                call sphereVoxelDensitySubtraction.
--
--   FORCED DOWN  tools. sm.tool.forceTool( nil ) rips the tool out of the
--                player's hands the moment they equip it. The item is still in
--                the creative menu -- Lua cannot edit that list -- but it cannot
--                be held, so it cannot be used.
--
--                These all DEFAULT ON and are not the anti-grief mechanism. Do
--                not reach for them to stop a griefer: the paint tool and the
--                connect tool are how people build, and turning them off to stop
--                one person punishes everyone else. Bodies carry their own
--                permissions, so a build on someone else's plot is already
--                unpaintable and unweldable to them. Scope the ground, not the
--                toolbox.
--
--   DAMAGE ONLY  explosives as *items* (cornades). They are consumables, not
--                tools, so forceTool does not reach them. They already cannot
--                hurt a build (destructable is pinned false) or the ground (see
--                above), so what is left is noise and knockback. Removing them
--                properly needs our own Objects database, which is a content
--                change, not a script change. Not done yet -- say so, do not
--                pretend the toggle is stronger than it is.

Settings = {}

Settings.PATH = "$CONTENT_DATA/Settings.json"
Settings.values = {}

-- Tool uuids, read out of the game's own scripts rather than a wiki:
--   Survival/Scripts/game/survival_items.lua
--   ChallengeData/Scripts/game/challenge_tools.lua
-- Every tool uuid in vanilla, recovered from Survival/Tools/ToolSets/*.json
-- (each entry there maps a uuid to its script class). That list is the whole
-- set: there is NO flamethrower tool in vanilla Scrap Mechanic. If one is
-- wanted it is coming from a Blocks-and-Parts mod and its uuid has to be added
-- here by hand.
-- HAZARD tools are blocked for EVERYONE, host included. The host bypass exists
-- so whoever runs the event can place and clear things -- it was never meant to
-- hand them a clay gun. Reported: "the clay gun still works", from the host.
local HAZARD = {
	claygun = true, firelauncher = true, cornades = true, extinguisher = true,
}

-- WHICH MODES MEAN "THE WORLD IS SHUT". One definition, because two files need
-- it: Protection.lua short-circuits its resolver on these, and the tool guard
-- below blocks nearly everything while one is in force. They drifted apart once
-- already -- see the note on LOCKDOWN_KEEPS.
Settings.LOCKED_MODES = { locked = true, display = true }

function Settings.WorldIsShut()
	return Settings.LOCKED_MODES[tostring( Settings.Get( "protection" ) )] == true
end

-- DEVELOPER MODE. Off by default, and off means the test tools are not on the
-- menu at all rather than merely discouraged.
--
-- ASKED FOR: "add a /developer on feature that adds the developer buttons to
-- the menu. it is off by default." Right, and for a reason bigger than tidiness.
-- Every one of the four things behind it changes the world in a way a live
-- event does not survive: /crowd stands up to 128 characters on the city,
-- /bench walks that number up on its own for several minutes and ends with a
-- full city, /bridge opens a channel that runs host commands from outside the
-- game, and the checklist runs whichever command the item under your cursor
-- happens to name. A misclick on any of them during an event is not a mistake
-- somebody notices later.
--
-- ONE DEFINITION, because five places ask the question: which entries the menu
-- draws, the command gate, the panel opener, the bridge poll, and the help.
function Settings.DeveloperOn()
	return Settings.Get( "developer" ) == true
end

-- COMMANDS BEHIND /developer on. Each one changes the world in a way an event
-- does not survive, and none has any business being one mistyped word away
-- during one.
--
-- Hiding the two menu entries is not enough on its own. A chat command is its
-- own door, and a switch that only tidied up the menu would be a switch that
-- did not do what it says.
--
-- THE VALUE IS THE ESCAPE, AND IT IS THE IMPORTANT HALF. "A rule must never
-- forbid its own remedy" is a lesson this project has already paid for once:
-- going over the per-plot part budget returned the LOCKED profile, so the one
-- action that could satisfy the limit -- removing a part -- was the action the
-- limit forbade. Switch developer mode off with a hundred bots standing on the
-- city and it is exactly that shape again, so every one of these keeps its OFF
-- switch reachable whatever the mode. You can always stop a dev tool running;
-- you just cannot start one.
--
-- `false` means there is nothing to stop -- /check reads and writes a file and
-- leaves nothing running behind it.
Settings.DEV_COMMANDS = {
	["/crowd"] = "off", ["/bench"] = "stop",
	["/bridge"] = "off", ["/check"] = false,
}

-- params is the raw chat-command argument list: params[1] is the command.
-- Pure, so dev/test_logic.py runs the real gate rather than a restatement of it.
function Settings.DevCommandAllowed( params )
	local escape = Settings.DEV_COMMANDS[params[1]]
	if escape == nil then return true end            -- not a dev command
	if Settings.DeveloperOn() then return true end
	if escape == false then return false end         -- nothing to stop
	local arg = string.lower( tostring( params[2] or "" ) )
	-- "0" as well as "off", because a panel that steps a bot count down sends
	-- the number rather than the word.
	return arg == escape or ( params[1] == "/crowd" and arg == "0" )
end

-- MAY PEOPLE BUILD ON THE CITY ITSELF -- the roads, the plaza, the decking?
--
-- ASKED FOR: "add a settings that alows for the city to be modified too.
-- because in the stream. the host allowed to modify the plaza. and the road."
--
-- Off by default, because the default is a plot event and the whole reason a
-- plot event works is that the ground between the plots is not anybody's to
-- change. On, the city becomes ordinary buildable ground.
--
-- WHAT IT COSTS, said plainly because it is a real loss and not a detail. The
-- roads and the plaza are the only ground this mod can be SURE is litter: a
-- craftbot on a road is rubbish precisely because nothing legitimate can be
-- built there. Switch that on and the mod can no longer tell a dropped craftbot
-- from somebody's sculpture, so shared ground stops being sweepable-by-anyone
-- and behaves like an unclaimed plot instead -- open while building is open,
-- locked when it is not. Junk dropped on a road during prep is then the host's
-- to clear with the Cleaner or /purge.
--
-- That is the same trade the strict lockdown already makes, and it is the
-- honest one: you cannot have "anyone may clear anything here" and "anyone may
-- build anything here" about the same square of ground.
function Settings.CityIsOpen()
	return Settings.Get( "citybuild" ) == true
end

-- WHO CAN JOIN THIS WORLD -- read out of the GAME's settings, not ours.
--
-- `Multiplayer` is a real key in Scrap Mechanic's own settings table. MEASURED:
-- it sits directly beside `PhysicsQuality` in the executable's string run of
-- setting names, with its five option labels around it
-- (MENU_OPTIONS_GAMEPLAY_MULTIPLAYER_{PRIVATE,INVITE_ONLY,FRIENDS,
-- FRIENDS_OF_FRIENDS,PUBLIC}). So sm.game.getSettingValue can read it, exactly
-- the way /protection already reads PhysicsQuality.
--
-- WHY THE MOD CARES. Reported from Dr Pixel Plays' 40-player survival stream:
-- on Public, joining stopped working after about six players, and the whole
-- event had to move to invite-only with invites sent one at a time. A host who
-- cannot see which mode they are in cannot tell "nobody else can join" from
-- "nobody else is trying".
--
-- THE ORDER IS NOW EVIDENCE, NOT A GUESS -- though not yet complete.
--
--   2 = Friends              CONFIRMED in game, 2026-09-01, through the bridge:
--                            the host's world read `Multiplayer = 2` while the
--                            setting was Friends.
--   0 = Private              consistent with the logs: setting it to 0 with two
--                            people connected evicted BOTH one tick later, so 0
--                            is the most restrictive value there is.
--   3 = Friends of friends   consistent: a non-friend who had been refused
--                            seven times connected on the next attempt after
--                            the host moved to 3.
--   1, 4                     unconfirmed, and they are the only two left in an
--                            ordered list of five, so this is effectively
--                            settled rather than assumed.
--
-- The raw value is still printed beside the label, because two of five have not
-- been seen and a readout that hid the number could be quietly wrong about
-- them.
Settings.JOIN_MODES = {
	[0] = "Private", [1] = "Invite only", [2] = "Friends",
	[3] = "Friends of friends", [4] = "Public",
}

-- Returns ( label, raw ). label is nil when the setting cannot be read at all.
function Settings.JoinMode()
	local ok, raw = pcall( sm.game.getSettingValue, "Multiplayer" )
	if not ok or raw == nil then
		local okS, str = pcall( sm.game.getSettingString, "Multiplayer" )
		if okS and str ~= nil and str ~= "" then return tostring( str ), str end
		return nil, nil
	end
	local n = tonumber( raw )
	local label = ( n ~= nil ) and Settings.JOIN_MODES[n] or nil
	return label, raw
end

-- One line a host can read. Names the mode, the raw value behind it, and -- on
-- the one mode that has been reported to break -- what to do instead.
function Settings.JoinModeLine()
	local label, raw = Settings.JoinMode()
	if label == nil then
		return "who can join: unreadable (game setting 'Multiplayer')"
	end
	local line = string.format( "who can join: %s  (Multiplayer = %s)",
		label, tostring( raw ) )
	if label == "Public" then
		line = line .. "  -- joining has been reported to stall past ~6 people"
	end
	return line
end

-- THE OUTSIDE DOOR IS DERIVED, NEVER WRITTEN -- the same rule as Sv_HazardOff
-- below, and it is here for the same reason that one exists.
--
-- /developer off could have written `bridge = false`, and that is exactly the
-- mistake V52's lockdown made: it wrote four tool settings false, /unlock had
-- no idea what it had changed, and one lockdown disabled four tools for good.
-- Derived instead: developer off shuts the door without touching the host's own
-- choice, and developer on gives back whatever they had actually chosen.
function Settings.BridgeOpen()
	return Settings.Get( "bridge" ) == true and Settings.DeveloperOn()
end

-- "LOCK down EVERYTHING" -- the owner, 2026-08-31, about a lockdown that only
-- reached tools and body flags.
--
-- Three world hazards are neither. Fire, explosion cratering and unit aggro are
-- engine switches, not permissions, so a body being unbuildable says nothing
-- about them: a host who had turned fire on for an event still had a burning
-- world after typing /lockdown.
--
-- DERIVED FROM THE MODE, never written. This is the same rule the tool guard
-- learned the hard way -- V52's lockdown wrote four settings false and /unlock
-- could not put them back, so one lockdown disabled four tools for good. A
-- shut world reads `false` for each of these; unlocking reads the host's own
-- choice again, because the choice was never overwritten.
--
-- Sv_ApplyAll re-runs on every protection change (World.lua, /lockdown), which
-- is what makes a derived value actually reach the engine.
function Settings.Sv_HazardOff( v )
	if Settings.WorldIsShut() then return false end
	return v == true
end


-- Tools only the host may hold, even when the tool itself is switched on. The
-- lift is here because it spawns whole saved creations out of thin air: fine for
-- whoever is running the event, not something a lobby of guests should each have.
-- Tools only the host may hold, even when the tool itself is switched on.
--
-- NOTlift is here because "its too powerful" -- and it is. It spawns a whole
-- saved creation out of nothing, which is a bigger single action than anything
-- else in the game: the cleaner deletes what you point at, the lift moves what
-- already exists, this one CREATES. The server-side rules on it (own plot,
-- building open, part cap) bound the damage; they do not make it a guest tool.
local HOST_ONLY = {
	cleaner = "hostcleaner",
	lift    = "hostlift",
	notlift = "hostnotlift",
	-- TRUE, NOT A SETTING NAME. This is the one host tool with no way to open
	-- it up, and the difference is deliberate.
	--
	-- The other three gate a tool that changes the WORLD, so a host may
	-- reasonably want to hand one to somebody they trust -- and if they do, the
	-- server-side rules on that tool still apply. Focus does not change the
	-- world; it writes on everybody else's SCREEN. There is no half of that to
	-- delegate, and a guest able to stick a marker over anyone they liked has a
	-- toy for annoying people.
	--
	-- It also has to match the rest of the feature. The panel and /focus are
	-- gated on sm.player.getHostPlayer() outright, with no setting in the path,
	-- so a `hostfocus` that opened the tool alone would have produced a guest
	-- who could mark people with a tool but not with the panel that does the
	-- same thing. `focus` in the schema still removes the tool from everyone.
	focus   = true,
}

local TOOLS = {
	-- default OFF
	claygun = {
		sm.uuid.new( "6993e5df-6852-4e84-88ae-df49f765e784" ),   -- ClayRifle
		sm.uuid.new( "9c47acb7-ef4c-48b3-8e08-c1ce2e8beb58" ),   -- ClayTool
	},
	extinguisher = { sm.uuid.new( "2c7e0586-2534-44cc-9f4b-e28c436446b6" ) },
	-- The Fire Launcher is grouped separately below, not with the spud guns.
	-- Cornade turns out to be a TOOL, not a consumable (tools_shared.json), so
	-- forceTool does reach it. "No explosives" is a real off switch after all,
	-- not just damage-neutering as previously assumed.
	cornades = { sm.uuid.new( "f978a804-0685-4c3e-b282-cedec6140f33" ) },

	-- default ON
	-- THE SURVIVAL SLEDGEHAMMER. There are two, and only one exists at a time --
	-- whichever tool index baseGameContent loads:
	--
	--   bb641a4f  Survival/Tools/ToolSets/tools.json  loaded by "Survival"  <- us
	--   ed185725  Data/Tools/ToolSets/tools.json      loaded by "Creative"
	--
	-- This flipped to ed185725 for one build when config.json went to "Creative",
	-- and flipped back with it. dev/check_uuids.py is what keeps the two in step;
	-- it fails on a uuid the loaded content does not know.
	sledgehammer = { sm.uuid.new( "bb641a4f-e391-441c-bc6d-0ae21a069476" ) },
	-- Names below are the IN-GAME titles from
	-- Survival/Gui/Language/English/inventoryDescriptions.json, not the script
	-- class names. That distinction matters: uuid a2a2bb33 has the script class
	-- "PotatoLauncher" but is called the FIRE LAUNCHER in game and shoots balls
	-- of fire. Grouping it with the spud guns on class name alone left a
	-- flamethrower enabled by default. Always check the title, not the class.
	spudguns = {
		sm.uuid.new( "c5ea0c2f-185b-48d6-b4df-45c386a575cc" ),   -- Spud Gun
		sm.uuid.new( "f6250bf4-9726-406f-a29a-945c06e460e5" ),   -- Spud Shotgun
		sm.uuid.new( "9fde0601-c2ba-4c70-8d5c-2a7a9fdd122b" ),   -- Spudling Gun
		sm.uuid.new( "d51ec758-057b-4263-bd16-7a731e149480" ),   -- Scrap Spud Gun
	},
	firelauncher = { sm.uuid.new( "a2a2bb33-a841-4b23-88da-b758063d9206" ) },
	painttool = { sm.uuid.new( "c60b9627-fc2b-4319-97c5-05921cb976c6" ) },
	connecttool = { sm.uuid.new( "8c7efc37-cd7c-4262-976e-39585f8527bf" ) },
	weldtool = { sm.uuid.new( "fdb8b8be-96e7-4de0-85c7-d2f42e4f33ce" ) },
	-- BOTH lifts. They are different items: 5cc12f03 is the creative lift
	-- (tool_lift_creative, class Lift) and 8f190ce2 is the survival one
	-- (SurvivalLift). baseGameContent "Survival" only ships the second, so our
	-- toolset adds the first -- and a gate that named one of them would let the
	-- other straight through.
	-- THE LIFT IS BACK IN THE GATE, AND THIS TIME IT IS NOT A GUESS.
	--
	-- It was taken out in V51: the lift had been reported broken for a dozen
	-- versions, the tool gate was the one suspect we owned, and removing it was
	-- how that question got settled rather than argued about. It settled it --
	-- the gate was never the cause. The cause was engine-side content, see
	-- NotLift.lua.
	--
	-- It goes back because the ask changed once importing existed elsewhere:
	-- "make a NOT lift and make the menu of it opened via it and limit the lift
	-- to the host." NOTlift is host only as well -- "its too powerful" -- so at
	-- an event neither lifting nor importing is a guest action. Guests build;
	-- the host arranges. That is the whole shape of it.
	--
	-- Gated by `hostlift`, not by `lift`: `lift = false` would remove it from
	-- everyone including the host, which is a themed-round switch, not this.
	-- ONE LIFT. The two this mod used to add are gone -- see the toolset -- so
	-- the only one in the game is survival's, which is base content and cannot
	-- be removed. Gating it is the whole of "the lift is host only".
	lift = { sm.uuid.new( "8f190ce2-3a59-423e-8483-a7aa67bd5bc0" ) },
	-- NOTlift, and it is HOST ONLY -- see HOST_ONLY above. The gate pulls it out
	-- of a guest's hands within a couple of ticks, and
	-- World.sv_e_swImportCreation refuses a non-host outright, because "fast" is
	-- not the same as "impossible" for a tool that spawns whole creations.
	notlift = { sm.uuid.new( "7b3d5c91-4a2e-4f88-9c17-2e6d0b5a13ff" ) },
	glowsticks = { sm.uuid.new( "9506abb9-e415-4229-a824-28a479cca788" ) },
	-- Ours. See CleanerTool.lua: point at anything and it is deleted, including
	-- the carryable props -- craftbots, gems, crates -- that the remove tool
	-- picks up instead of erasing and which nothing else in the game can get rid
	-- of.
	cleaner = { sm.uuid.new( "bbbb0cc8-5dd0-46e1-9299-8080c3cc80db" ) },
	-- Ours. See FocusTool.lua: point at a player and everybody in the world
	-- gets a marker over them. It changes nothing about the world and cannot
	-- destroy anything, so it is the mildest of the three host tools -- but it
	-- writes on everyone's screen, so it is gated all the same.
	focus = { sm.uuid.new( "f0c5a11e-7d3b-4c6a-9e21-5b8a4d0f9c33" ) },
}

-- Every setting is { key, kind, default, help, apply }. Adding one means adding
-- a row here and nothing else -- /set and /settings pick it up automatically.
-- Choice lists are FUNCTIONS, not tables. Settings.lua and Palette.lua are
-- separate files loaded by two different scripts, and a table here would make
-- the schema depend on which one got there first. A closure does not.
local function materials() return Palette.MATERIAL_ORDER end
local function colours() return Palette.COLOUR_ORDER end

Settings.SCHEMA = {
	-- Two halves, because the engine has two mechanisms. setFireLimit caps how
	-- many fire instances may exist; AttachedFireManager is the separate system
	-- that walks burning shapes and lights their neighbours. Capping instances
	-- without stopping the manager would leave spread logic running against a
	-- zero budget, so our World also declines to tick it (see World.lua).
	-- All three go through Sv_HazardOff, so a shut world forces them off
	-- without touching what the host chose. See the note on it.
	{ key = "fire", kind = "bool", default = false,
	  help = "let fire exist and spread at all",
	  apply = function( v )
		v = Settings.Sv_HazardOff( v )
		pcall( sm.fire.setFireLimit, v and ( FIRE_INSTANCE_LIMIT or 128 ) or 0 )
		g_swFireEnabled = v and true or false
	  end },

	{ key = "terraindamage", kind = "bool", default = false,
	  help = "let explosions crater the ground",
	  apply = function( v ) g_swProtectTerrain = not Settings.Sv_HazardOff( v ) end },

	{ key = "aggro", kind = "bool", default = false,
	  help = "let tapebots and other units attack",
	  apply = function( v ) pcall( sm.game.setEnableAggro, Settings.Sv_HazardOff( v ) ) end },

	-- BUILD TOOLS DEFAULT ON. All of them. They are how people build, and
	-- switching them off to stop griefing punishes the 99 players who are not
	-- griefing. Scoping is the plot system's job, not the tool list's: a body on
	-- someone else's plot is already unpaintable, unerasable and unweldable to
	-- everyone but its owner, so the paint tool in a griefer's hands does nothing
	-- on ground that is not theirs. These switches exist for a host who wants a
	-- themed round ("no paint"), not as anti-grief.
	--
	-- The sledgehammer is on for the same reason plus a stronger one: destructable
	-- is pinned false in every protection profile, so it already cannot break a
	-- single block anywhere. Disabling it was protecting against nothing.
	{ key = "sledgehammer", kind = "bool", default = true,
	  help = "allow the sledgehammer (it cannot break protected builds anyway)" },
	{ key = "spudguns", kind = "bool", default = true,
	  help = "allow the Spud Gun / Shotgun / Spudling / Scrap Spud Gun" },
	{ key = "glowsticks", kind = "bool", default = true, help = "allow glowsticks" },

	-- The three the owner wants off out of the box. Everything else is a build
	-- tool and stays on.
	{ key = "claygun", kind = "bool", default = false, help = "allow the Clay Gun" },
	{ key = "firelauncher", kind = "bool", default = false,
	  help = "allow the Fire Launcher (the flamethrower -- shoots balls of fire)" },
	{ key = "extinguisher", kind = "bool", default = false, help = "allow the fire extinguisher" },
	{ key = "cornades", kind = "bool", default = false, help = "allow cornades (explosives)" },
	{ key = "painttool", kind = "bool", default = true, help = "allow the paint tool" },
	{ key = "connecttool", kind = "bool", default = true, help = "allow the connect tool" },
	{ key = "weldtool", kind = "bool", default = true, help = "allow the weld tool" },

	-- The cleaner IS gated, unlike the lifts: it deletes whatever it is pointed
	-- at and ignores every permission flag, which is precisely why it is host
	-- only and why it must stay switchable.
	{ key = "cleaner", kind = "bool", default = true,
	  help = "allow the Server Works cleaner (deletes anything you point at)" },
	{ key = "hostcleaner", kind = "bool", default = true,
	  help = "only the host may use the cleaner -- leave this on" },

	-- THE HOST'S BUBBLE. "I should be able to build and delete stuff anywhere."
	--
	-- Body permission flags are per-BODY -- there is no setBuildableBy( player )
	-- and dev/dump_api.py confirms it, 39 Body bindings and not one of them
	-- takes a player. So "everyone is locked out, the host is not" cannot be
	-- expressed as a flag, and the only lever the engine leaves is the one the
	-- plot system already runs on: PRESENCE.
	--
	-- So a locked world unlocks the small piece of itself the host is standing
	-- in, and locks it again the moment they walk away. See
	-- Plots.sv_hostReaches for the radius and the guard.
	-- OFF BY DEFAULT, and the default is the whole point.
	--
	-- REPORTED, after V60 shipped it on: "even on lock down. I still can build
	-- everything and delete everything. and I mean the lockdown feature."
	--
	-- Both halves of that are true and they are the same fact. The bubble
	-- follows the host, so from the host's own screen -- the only screen there
	-- is, on a server with nobody else on it -- a lockdown looks exactly like a
	-- lockdown that did nothing. There is no way to tell them apart by playing,
	-- which is the failure this project keeps paying for: a panel that closes on
	-- every click cannot be told from a broken one.
	--
	-- So /lockdown is TOTAL again, host included, and the exemption is a
	-- deliberate press on the PROTECTION panel rather than a thing that is
	-- quietly always on. You get the lockdown you can verify, and the freedom to
	-- fix things, in that order and never by accident.
	{ key = "hostbuild", kind = "bool", default = false,
	  help = "let the host build where they stand during a lockdown -- off by "
	      .. "default, so a lockdown is a lockdown until you say otherwise" },

	-- THE FOCUS TOOL. Point at a player and everybody sees a marker over them,
	-- for showing off one person's build mid-event. It creates nothing and
	-- deletes nothing; what makes it host-only is that it draws on every other
	-- player's screen.
	-- There is no `hostfocus`. Focusing is host only with no switch at all --
	-- see the note on HOST_ONLY. This one removes the tool from EVERYBODY,
	-- host included, the way `lift` does.
	{ key = "focus", kind = "bool", default = true,
	  help = "allow the focus tool at all (host only either way; off removes it "
	         .. "from the host too)" },
	-- The name is drawn as world text beside the marker, and world text comes
	-- out of the same limited glyph atlas as GUI text -- see the font note in
	-- CLAUDE.md. SM_Header is a full-character-set font so this should be fine;
	-- the switch exists because "should" is not "measured", and a name that
	-- draws as hollow boxes is worse than no name.
	{ key = "focusname", kind = "bool", default = true,
	  help = "draw the focused player's name in the world under their marker" },

	{ key = "lift", kind = "bool", default = true,
	  help = "allow the lift at all (off removes it from the host too)" },
	{ key = "hostlift", kind = "bool", default = true,
	  help = "only the host may hold a lift -- guests import with NOTlift" },
	{ key = "notlift", kind = "bool", default = true,
	  help = "allow NOTlift, the creations importer" },
	{ key = "hostnotlift", kind = "bool", default = true,
	  help = "only the host may import creations -- leave this on" },

	-- THE IMPORT CAP, OFF BY DEFAULT.
	--
	-- "maximum parts since its a host tool shall be inf."
	--
	-- It shipped at 2000 for one build, when NOTlift was going to be a guest
	-- tool and an unbounded import was a griefing vector. It is host only now,
	-- and a cap on the host is a cap on the person who decides what the event
	-- is -- pure friction, protecting the host from themselves.
	--
	-- The mechanism stays, because the reason it existed has not gone away:
	-- blueprints on this machine reach 3.1 MB and the browser showed one with
	-- 40,087 of a single part, and goal 1 of this project is twenty people
	-- building at once. If a host ever hands NOTlift to guests with
	-- /set hostnotlift off, /set maximportparts N is the brake, already built
	-- and already enforced server-side.
	{ key = "maximportparts", kind = "number", default = 0,
	  help = "biggest creation NOTlift will import, in parts (0 = no limit)" },

	{ key = "plots", kind = "bool", default = false, help = "restrict building to owned plots" },
	-- See Settings.CityIsOpen for what this costs as well as what it gives.
	{ key = "citybuild", kind = "bool", default = false,
	  help = "let people build on the roads, the plaza and the decking" },
	{ key = "pushintruders", kind = "bool", default = true,
	  help = "shove players off plots they do not own" },

	-- "Allowlists sounds like a good idea" -- JuneCarya, stream chat, endorsed by
	-- the owner in the same conversation. Nobody who is not on the list gets in.
	-- PLAYER-VS-PLAYER COLLISION CANNOT BE DISABLED. Asked for twice; the answer
	-- did not change, so here is the evidence in full so nobody has to re-derive it:
	--
	--   * The complete wrap_Character.cpp binding list is setSwimming, setDiving,
	--     setClimbing, setDowned, setHovering, setVisible, setColor, applyImpulse,
	--     setUpDirection, setWorldPosition and friends. No collision anything.
	--   * The executable's entire string table contains exactly three
	--     collision-related identifiers reachable from Lua: isGhost (a BODY
	--     getter, no setter and not a character), setCollisionSoundEnabled
	--     (audio only), and the onCollision callbacks (notifications).
	--   * setFlying and setHovering exist but the binary itself carries the
	--     string "Player characters can not activate flying."
	--
	-- No switch is exposed here, because a setting that appears in /settings and
	-- silently does nothing is worse than an honest gap. /home is the mitigation:
	-- it fixes being shoved somewhere, which is the actual complaint.

	{ key = "allowlist", kind = "bool", default = false,
	  help = "only players on the allow list may join (/allow <name>)" },

	-- The posted rules from the 2026-08-22 event, as settings. Numbers are that
	-- host's taste; the next event will want different ones, so all of them are
	-- editable and 0 means "no limit".
	{ key = "maxjoints", kind = "number", default = 10,
	  help = "rule 10: bearings + pistons + suspensions per plot, 0 = unlimited" },
	{ key = "maxbots", kind = "number", default = 1,
	  help = "rule 6: craft/cook/dress bots per plot, 0 = unlimited" },
	{ key = "maxlights", kind = "number", default = 25,
	  help = "rule 4: lights per plot, 0 = unlimited" },
	{ key = "minbuildheight", kind = "number", default = 0,
	  help = "rule 1: no basements -- lowest z anything may be built at" },
	{ key = "buildopen", kind = "bool", default = true,
	  help = "rule 3: building allowed. off = nobody builds until you say go" },
	{ key = "beacons", kind = "bool", default = false, help = "rule 12: allow beacons" },
	{ key = "fireworks", kind = "bool", default = false, help = "rule 11: allow fireworks" },
	{ key = "plasmadrills", kind = "bool", default = false, help = "rule 11: allow plasma drills" },
	{ key = "radios", kind = "bool", default = false,
	  help = "rule 5: allow radios (they cannot be muted, only banned)" },
	{ key = "horns", kind = "bool", default = false,
	  help = "rule 7: allow horns -- the noise pollution lever" },
	-- Off by default because an event does not want anything breakable. Turn it
	-- on and explosives and the sledgehammer work for real -- but only while the
	-- world is OPEN. A locked world stays locked whatever this says.
	{ key = "destructible", kind = "bool", default = false,
	  help = "let explosives and the sledgehammer actually break builds" },
	{ key = "cleanupdebris", kind = "bool", default = true,
	  help = "vacuum up the debris an explosion leaves behind" },
	{ key = "autoremove", kind = "bool", default = false,
	  help = "delete banned parts automatically instead of only warning" },

	-- Not shown as a toggle; /lockdown and /unlock write it. Kept in settings so
	-- the World can read the mode back on load without touching Game storage.
	-- Which WORLD the state in this file belongs to. See Game.sv_newWorldReset.
	{ key = "worldstamp", kind = "string", default = "", hidden = true,
	  help = "internal: the world this mod's saved state belongs to" },

	{ key = "protection", kind = "string", default = "open", hidden = true,
	  help = "current protection mode: open, polish, display, sweep or locked" },

	-- Above 256, deliberately. The remove tool deletes at most 16x16 = 256
	-- shapes in one action, so anything at or below that fires on an ordinary
	-- delete. 400 means one big sweep is quiet and two inside the window are not.
	{ key = "alarmdrop", kind = "number", default = 400,
	  help = "blocks that must vanish within 20s to trip the grief alarm" },
	-- Default OFF, on the owner's call. The alarm still announces and still
	-- logs; what it no longer does is lock the world without being asked.
	--
	-- It is the right default. A false alarm that shouts is a nuisance; a false
	-- alarm that freezes twenty people mid-build in front of a stream is worse
	-- than the griefing it was guarding against -- and the alarm cannot tell
	-- somebody clearing their own work from somebody wrecking yours.
	-- /set alarmlock on for an unattended server.
	{ key = "alarmlock", kind = "bool", default = false,
	  help = "grief alarm locks the world by itself (off: it only shouts)" },
	-- THE OUTSIDE-THE-GAME CONTROL CHANNEL. Default false and it must stay
	-- false: while it is off, Bridge.lua does not read, write or poll anything.
	-- Switched on, a file dropped into the mod folder runs commands as the host.
	-- That is a door, and the reason this mod sets allow_add_mods false is that
	-- the door list IS the trust boundary -- see docs/MODS-AND-TRUST.md.
	{ key = "bridge", kind = "bool", default = false,
	  help = "let this world be driven from outside the game (dev only)" },
	-- DEVELOPER MODE, off by default. See Settings.DeveloperOn for what it
	-- gates and why it is not simply a matter of tidiness. /developer on|off is
	-- the same switch with a shorter name, because it is reached for in the
	-- middle of a test session rather than while reading a settings page.
	-- The tutorial opens itself the first time somebody joins. Off is for a host
	-- who is testing and does not want it in their face on every fresh world.
	{ key = "tutorialonjoin", kind = "bool", default = true,
	  help = "show HOW THIS WORKS to somebody the first time they join" },
	{ key = "developer", kind = "bool", default = false,
	  help = "show the dev tools: crowd, benchmark, outside control, checklist" },
	{ key = "autosave", kind = "number", default = 10,
	  help = "minutes between automatic snapshots, 0 for off" },

	-- CITY STYLE. "make a choice for blocks. so you can select custom blocks for
	-- the city foundation for style. and also their colour bassed on the in game
	-- paint tool pallete."
	--
	-- The block names come from Palette.MATERIAL_ORDER, read out of the
	-- installed shapesets. The colour names come from Palette.COLOUR_ORDER,
	-- which is the paint tool's own forty swatches read out of the executable --
	-- see the note at the top of Palette.lua. A raw six-digit hex is accepted
	-- too, so nobody is boxed in by the forty.
	--
	-- CHANGING ONE OF THESE DOES NOT RESTYLE A CITY THAT ALREADY EXISTS. The
	-- city is a set of imported blueprints, and a blueprint is not a live thing
	-- that can be repainted -- run BUILD CITY again and the new style is what
	-- comes out. Every reply says so, because otherwise it reads as a setting
	-- that did nothing.
	--
	-- The defaults are the green carpet that was asked for before the ask turned
	-- into "make a choice": a deep green carpet pad with a dark metal frame.
	-- /citystyle brutalist is the concrete-and-grey the city used to be.
	{ key = "padblock", kind = "string", default = "carpet", choices = materials,
	  help = "block: the buildable pad in the middle of a plot" },
	{ key = "padcolour", kind = "string", default = "deepgreen", choices = colours,
	  help = "colour: the buildable pad" },
	{ key = "borderblock", kind = "string", default = "metal2", choices = materials,
	  help = "block: the frame welded round each plot" },
	{ key = "bordercolour", kind = "string", default = "darkgrey", choices = colours,
	  help = "colour: the frame round each plot" },
	{ key = "roadblock", kind = "string", default = "metal3", choices = materials,
	  help = "block: the streets between plots" },
	{ key = "roadcolour", kind = "string", default = "black", choices = colours,
	  help = "colour: the streets" },
	{ key = "plazablock", kind = "string", default = "metal3", choices = materials,
	  help = "block: the plaza everybody spawns on" },
	{ key = "plazacolour", kind = "string", default = "darkgrey", choices = colours,
	  help = "colour: the plaza" },
	{ key = "standblock", kind = "string", default = "metal3", choices = materials,
	  help = "block: the column under each plot and under the plaza" },
	{ key = "standcolour", kind = "string", default = "black", choices = colours,
	  help = "colour: the columns" },
}

local function schemaFor( key )
	for _, row in ipairs( Settings.SCHEMA ) do
		if row.key == string.lower( key or "" ) then
			return row
		end
	end
	return nil
end

function Settings.Get( key )
	local v = Settings.values[key]
	if v ~= nil then return v end
	local row = schemaFor( key )
	return row and row.default or nil
end

-- applyNow defaults to true. The Game script loads with it FALSE, because half
-- the apply hooks (sm.fire.setFireLimit, for one) are world-dependent and a Game
-- script has no world -- calling them there throws. The World calls
-- Settings.Sv_ApplyAll() once it exists.
-- One-time changes to settings that are ALREADY WRITTEN DOWN.
--
-- A default only ever applies to a settings file that does not have the key yet.
-- Anybody who has run the server once has the old value saved, so changing a
-- default reaches new hosts and nobody else. A migration is how a decision like
-- "the lift is not host-only any more" actually lands.
--
-- Each runs once, and the fact that it ran is recorded in the same file.
Settings.MIGRATIONS = {
	{ key = "lift_free_v34", run = function( values )
		values.hostlift = false
	end },
	-- 250 and below fires on a single ordinary delete: the remove tool takes
	-- 16x16 = 256 shapes at once. Anybody who has played already has the old
	-- number written down, so it needs a migration to reach them.
	{ key = "alarmdrop_above_one_delete_v47", run = function( values )
		local n = tonumber( values.alarmdrop )
		if n == nil or n <= 256 then values.alarmdrop = 400 end
	end },
	-- The alarm shouts; it does not lock. A changed default reaches nobody who
	-- has already played, so it needs a migration to land.
	{ key = "alarm_does_not_lock_v50", run = function( values )
		values.alarmlock = false
	end },
	-- THE OPPOSITE OF lift_free_v34, and it needs a migration for the same
	-- reason that one did -- plus a sharper one. `hostlift = false` is still
	-- sitting in every existing Settings.json, written by that migration, and a
	-- changed DEFAULT never reaches a key that is already present. Without this,
	-- "limit the lift to the host" would have quietly done nothing on the only
	-- machine that matters.
	-- V60 shipped the host's bubble ON, and V62 turns it off. The default change
	-- reaches a new host and nobody who has already played -- and this owner has,
	-- with `hostbuild = true` sitting in their Settings.json since the build that
	-- produced the report. Without this the fix would land everywhere except the
	-- one machine it was written for.
	--
	-- REPORTED: "even on lock down. I still can build everything and delete
	-- everything. and I mean the lockdown feature."
	{ key = "hostbuild_off_by_default_v62", run = function( values )
		values.hostbuild = false
	end },
	{ key = "lift_host_only_v55", run = function( values )
		values.hostlift = true
		values.lift = true
	end },
	-- The import cap shipped at 2000 and is already written into Settings.json
	-- on this machine -- verified, it is there. NOTlift is host only now, so the
	-- cap comes off: "maximum parts since its a host tool shall be inf." A
	-- changed default cannot do that on its own, because a default only ever
	-- applies to a key that is ABSENT.
	{ key = "import_cap_off_for_host_v56", run = function( values )
		values.maximportparts = 0
	end },
}

function Settings.Sv_Migrate()
	local values = Settings.values
	values.migrations = ( type( values.migrations ) == "table" ) and values.migrations or {}
	local ran = {}
	for _, m in ipairs( Settings.MIGRATIONS ) do
		if not values.migrations[m.key] then
			local ok, err = pcall( m.run, values )
			values.migrations[m.key] = true
			ran[#ran + 1] = m.key .. ( ok and "" or ( " FAILED: " .. tostring( err ) ) )
		end
	end
	if #ran > 0 then
		Settings.Sv_Save()
		sm.log.info( "[ServerWorks] settings migrated: " .. table.concat( ran, ", " ) )
	end
end

function Settings.Sv_Load( applyNow )
	Settings.values = {}
	local ok, exists = pcall( sm.json.fileExists, Settings.PATH )
	if ok and exists then
		local read, loaded = pcall( sm.json.open, Settings.PATH )
		if read and type( loaded ) == "table" then
			Settings.values = loaded
		end
	end
	for _, row in ipairs( Settings.SCHEMA ) do
		if Settings.values[row.key] == nil then
			Settings.values[row.key] = row.default
		end
	end
	Settings.Sv_Migrate()
	if applyNow ~= false then
		Settings.Sv_ApplyAll()
	end
end

function Settings.Sv_Save()
	local ok, err = pcall( sm.json.save, Settings.values, Settings.PATH )
	if not ok then
		sm.log.warning( "[ServerWorks] could not write settings: " .. tostring( err ) )
	end
end

function Settings.Sv_ApplyAll()
	for _, row in ipairs( Settings.SCHEMA ) do
		if row.apply then
			local ok, err = pcall( row.apply, Settings.values[row.key] )
			if not ok then
				sm.log.warning( string.format( "[ServerWorks] setting '%s' failed to apply: %s",
					row.key, tostring( err ) ) )
			end
		end
	end
end

-- Returns ok, message. Accepts on/off/true/false/yes/no/1/0 for bools.
function Settings.Sv_Set( key, raw )
	local row = schemaFor( key )
	if row == nil then
		return false, string.format( "no setting called '%s' -- /settings to list them", tostring( key ) )
	end

	local value
	if row.kind == "string" then
		value = string.lower( tostring( raw ) )
		-- A choice list is checked here rather than left to whoever reads the
		-- value later. A typo'd block name would otherwise be stored happily and
		-- only surface as a city built out of nothing, several minutes and one
		-- BUILD CITY later.
		local allowed = row.choices and row.choices()
		if allowed then
			local ok = false
			for _, name in ipairs( allowed ) do
				if name == value then ok = true break end
			end
			-- Colours also take a raw six-digit hex, so a host is never boxed in
			-- by the forty swatches the paint tool happens to ship.
			if not ok and string.match( row.key, "colour$" )
				and string.match( value, "^%x%x%x%x%x%x$" ) then
				ok = true
			end
			if not ok then
				return false, string.format( "'%s' is not a value for %s -- /citystyle lists them",
					value, row.key )
			end
		end
	elseif row.kind == "bool" then
		local t = string.lower( tostring( raw ) )
		if t == "on" or t == "true" or t == "yes" or t == "1" then
			value = true
		elseif t == "off" or t == "false" or t == "no" or t == "0" then
			value = false
		else
			return false, string.format( "'%s' takes on or off", row.key )
		end
	else
		value = tonumber( raw )
		if value == nil then
			return false, string.format( "'%s' takes a number", row.key )
		end
	end

	Settings.values[row.key] = value
	if row.apply then
		-- Deliberately NOT silent. Several apply hooks are world-dependent and
		-- throw when this runs from the Game script; the World re-applies them
		-- on /settingschanged, which is where they actually take. Logging the
		-- failure is what would have made "settings do nothing" obvious.
		local ok, err = pcall( row.apply, value )
		if not ok then
			sm.log.info( string.format(
				"[ServerWorks] %s deferred to world (%s)", row.key, tostring( err ) ) )
		end
	end
	Settings.Sv_Save()
	sm.log.info( string.format( "[ServerWorks] setting %s = %s", row.key, tostring( value ) ) )
	return true, string.format( "%s = %s", row.key, tostring( value ) ), row
end

function Settings.Sv_Lines()
	local lines = {}
	for _, row in ipairs( Settings.SCHEMA ) do
		if not row.hidden then
			local v = Settings.values[row.key]
			local shown = ( row.kind == "bool" ) and ( v and "on" or "off" ) or tostring( v )
			lines[#lines + 1] = string.format( "  %-14s %-5s  %s", row.key, shown, row.help )
		end
	end
	return lines
end


-- Write a value without running its apply hook or announcing it. Used for
-- bookkeeping values like the current protection mode, which are a consequence
-- of a command rather than a setting the host typed.
-- Keys whose applied value is DERIVED from the protection mode rather than read
-- straight out of the file. See Sv_HazardOff.
local DERIVED_FROM_MODE = { "fire", "terraindamage", "aggro" }

-- Re-apply just those three. Six places write the protection mode -- /lockdown,
-- /unlock, the grief alarm twice, the event clock and the new-world reset -- and
-- a derived value that nothing re-applies is a value that never changed. Hooking
-- the write itself is the only version of this that cannot be forgotten at a
-- seventh call site.
--
-- Silent about failure by design: Game.lua writes this key too and a Game script
-- has no world, so sm.fire.setFireLimit throws there. The world re-applies
-- everything at load and on its own /lockdown path, so a miss here is corrected
-- rather than lost -- and logging it per phase change would be noise in the one
-- file this project has already lost 1.79 GB to.
function Settings.Sv_ApplyHazards()
	for _, key in ipairs( DERIVED_FROM_MODE ) do
		for _, row in ipairs( Settings.SCHEMA ) do
			if row.key == key and row.apply then
				pcall( row.apply, Settings.values[key] )
			end
		end
	end
end

function Settings.Sv_SetQuiet( key, value )
	Settings.values[key] = value
	Settings.Sv_Save()
	if key == "protection" then
		Settings.Sv_ApplyHazards()
	end
end


--[[ presets ]]

-- A named bundle of settings, so a host can flip the whole server between phases
-- of an event with one command instead of a dozen. Only the keys listed change;
-- anything not mentioned keeps its current value, so a host's own tuning is not
-- silently thrown away.
Settings.PRESETS = {
	-- BUILD IS THE ONE PRESET THAT HAS TO BE COMPLETE, because it is the one a
	-- host presses with a lobby already in the world. Anything it does not name
	-- keeps whatever the host last set it to, and "whatever it was last time" is
	-- not a safety position.
	--
	-- ASKED FOR: "the building preset shall disable explosives. clay gun, fires.
	-- damage. and other stuff we talked about."
	--
	-- `destructible` was the hole. Its help reads "let explosives and the
	-- sledgehammer actually break builds" -- it is the DAMAGE switch -- and the
	-- preset never mentioned it, so a host who had turned it on for a themed
	-- round kept working explosives through the next build event. It was on in
	-- this owner's live settings when this was written.
	build = {
		label = "BUILD -- an event in progress",
		values = {
			buildopen = true, plots = true, pushintruders = true,
			protection = "open",

			-- NOTHING MAY DAMAGE ANYTHING. Fire, cratering and aggro are engine
			-- switches; destructible is the one that decides whether a build can
			-- be broken at all.
			fire = false, terraindamage = false, aggro = false,
			destructible = false, cleanupdebris = true,

			-- The hazard tools, off for everybody including the host.
			claygun = false, firelauncher = false, extinguisher = false,
			cornades = false,

			-- Rules 4, 5, 7, 11 and 12 -- the noise and nuisance board.
			beacons = false, fireworks = false,
			plasmadrills = false, radios = false, horns = false,

			-- What people actually build with.
			sledgehammer = true, spudguns = true, glowsticks = true,
			painttool = true, connecttool = true, weldtool = true,

			-- THE THREE POWERFUL TOOLS EXIST AND ARE THE HOST'S. Each changes
			-- more in one press than anything a guest should hold: the cleaner
			-- deletes whatever it points at ignoring every permission flag, the
			-- lift carries whole creations, and NOTlift spawns one out of
			-- nothing. Leaving these unset meant an event inherited whoever had
			-- last opened one up.
			cleaner = true, hostcleaner = true,
			lift = true, hostlift = true,
			notlift = true, hostnotlift = true,
			focus = true,

			-- The rules board, at the numbers /rules prints. Without these the
			-- board is a lie: /rules reads the live settings, so a limit left at
			-- 0 makes it announce a rule the server is not enforcing.
			maxjoints = 10, maxbots = 1, maxlights = 25,

			-- DEVELOPER MODE OFF. A live event is exactly where a stray /crowd
			-- or /bench does the most harm. `bridge` is deliberately NOT written
			-- here -- it is derived from this one (see Settings.BridgeOpen), so
			-- turning developer back on gives the host the channel they chose
			-- rather than one this preset silently took away.
			developer = false,

			alarmlock = false, alarmdrop = 400, autosave = 10, autoremove = true,
		},
	},
	show = {
		label = "SHOW -- locked, but seats and buttons still work",
		values = {
			buildopen = false, protection = "display",
			plots = true, pushintruders = false,
			alarmlock = false, alarmdrop = 300, autosave = 0,
		},
	},
	lockdown = {
		label = "LOCKDOWN -- locked hard, seats and controllers dead too",
		values = {
			buildopen = false, protection = "locked",
			plots = true, pushintruders = true,
			alarmlock = true, alarmdrop = 260, autosave = 0,
		},
	},
	sandbox = {
		label = "SANDBOX -- free build, no plots, nothing restricted",
		values = {
			destructible = true,
			buildopen = true, plots = false, protection = "open",
			fire = true, terraindamage = true, aggro = true,
			claygun = true, firelauncher = true, extinguisher = true,
			cornades = true, beacons = true, fireworks = true,
			plasmadrills = true, radios = true, horns = true,
			sledgehammer = true, spudguns = true, glowsticks = true,
			painttool = true, connecttool = true, weldtool = true,
			maxjoints = 0, maxbots = 0, maxlights = 0,
			alarmlock = false, autoremove = false,
		},
	},
}

Settings.PRESET_ORDER = { "build", "show", "lockdown", "sandbox" }

function Settings.Sv_ApplyPreset( name )
	local preset = Settings.PRESETS[string.lower( tostring( name ) )]
	if preset == nil then
		return false, string.format( "no preset called '%s'", tostring( name ) )
	end
	local changed = 0
	for key, value in pairs( preset.values ) do
		if Settings.values[key] ~= value then
			Settings.values[key] = value
			changed = changed + 1
		end
	end
	Settings.Sv_ApplyAll()
	Settings.Sv_Save()
	sm.log.info( string.format( "[ServerWorks] preset %s applied, %d settings changed",
		name, changed ) )
	return true, string.format( "%s  (%d settings changed)", preset.label, changed )
end

function Settings.Sv_PresetLines()
	local lines = {}
	for _, key in ipairs( Settings.PRESET_ORDER ) do
		lines[#lines + 1] = string.format( "  %-9s %s", key, Settings.PRESETS[key].label )
	end
	return lines
end


--[[ tool guard ]]

-- Which tool uuids are currently forbidden, rebuilt whenever settings change.
-- Returns two tables: everything blocked, and the subset the host does not get
-- a pass on.
-- THE TWO TOOLS THAT SURVIVE A LOCKDOWN, and both are load-bearing.
--
-- REPORTED: "the lockdown shall block EVERYTHING. so clay gun = blocked. and
-- other stuff." Right -- and the reason it did not is worth keeping, because it
-- was two separate faults:
--
--   1. /lockdown wrote four settings false -- claygun, firelauncher, cornades,
--      extinguisher -- and nothing else. The LIFT was never in that list, which
--      is why a locked world could still have creations moved around in it.
--   2. It wrote them by CHANGING THE HOST'S SETTINGS, and /unlock never put
--      them back. One lockdown disabled four tools permanently, and the only
--      way to notice was to find them missing later.
--
-- Both go away by deriving the blocked set from the MODE instead of writing
-- settings: nothing is remembered, so nothing has to be restored, and unlocking
-- returns to whatever the host actually chose.
--
-- The cleaner stays because litter must never become permanent -- it is the only
-- thing in the game that can remove a dropped craftbot, and the world stays
-- locked BETWEEN events. The focus marker stays because it changes nothing in
-- the world at all; it draws on screens.
local LOCKDOWN_KEEPS = { cleaner = true, focus = true }

-- Everything a locked world takes out of everyone's hands, host included.
function Settings.Sv_LockdownTools()
	local blocked = {}
	if not Settings.WorldIsShut() then return blocked end
	for name, uuids in pairs( TOOLS ) do
		if not LOCKDOWN_KEEPS[name] then
			for _, uuid in ipairs( uuids ) do
				blocked[tostring( uuid )] = name
			end
		end
	end
	return blocked
end

function Settings.Sv_BlockedTools()
	local blocked = {}
	for name, uuids in pairs( TOOLS ) do
		if Settings.Get( name ) == false then
			for _, uuid in ipairs( uuids ) do
				blocked[tostring( uuid )] = name
			end
		end
	end
	-- A LOCKED WORLD MEANS LOCKED.
	for uuid, name in pairs( Settings.Sv_LockdownTools() ) do
		blocked[uuid] = name
	end
	return blocked
end

-- Blocked for guests but not the host: the setting names which gate applies.
function Settings.Sv_HostOnlyTools()
	local blocked = {}
	for name, gate in pairs( HOST_ONLY ) do
		-- gate == true means "always host only, there is no switch". See the
		-- note on HOST_ONLY.
		if gate == true or Settings.Get( gate ) == true then
			for _, uuid in ipairs( TOOLS[name] or {} ) do
				blocked[tostring( uuid )] = name
			end
		end
	end
	return blocked
end

function Settings.Sv_HazardTools()
	local blocked = {}
	for name, uuids in pairs( TOOLS ) do
		if HAZARD[name] and Settings.Get( name ) == false then
			for _, uuid in ipairs( uuids ) do
				blocked[tostring( uuid )] = name
			end
		end
	end
	-- THE HOST IS GUARDED BY THIS LIST AND NOTHING ELSE (see
	-- Game.sv_toolPayload and the client tick that reads `host`), and a lockdown
	-- deliberately does NOT add to it.
	--
	-- THIS IS A REVERSAL, and it is the owner's call, 2026-08-31: "I should be
	-- able to build and delete stuff anywhere. and place lift."
	--
	-- V53 folded Sv_LockdownTools() in here, so /lockdown took every tool off
	-- the host too. The reasoning was "or /lockdown stops the lobby and not the
	-- person who called it" -- which answered a report ("I still could use the
	-- lift, and the clay gun") that was really about GUESTS keeping tools. The
	-- guest half is Sv_BlockedTools and it still carries the whole lockdown.
	--
	-- It also broke the lift specifically, in the exact way the check right
	-- beside this one already warned about: a tool in the hazard list is
	-- force-unequipped on the host's own client every tick, and the blueprint
	-- menu cannot hand a lift being ripped out of your hands anything. So the
	-- host running an event could not move a creation during the one mode where
	-- moving creations is most of what a host does.
	--
	-- The host is the person who typed /lockdown. Binding them was never the
	-- point of it.
	return blocked
end

-- The item stays in the creative MENU -- Lua cannot edit that list -- but it does
-- not have to stay in the player's hands or their inventory.
--
-- sm.tool.forceTool( nil ) alone was not enough: it unequips, and the player just
-- picks the thing straight back up, which is why a banned tool only ever produced
-- a stream of "disabled" messages. Taking the item OUT is the fix, and vanilla
-- shows how -- setItem with a nil uuid inside a transaction
-- (ChallengeGame.lua:86, BuilderWorld.lua:121).
--
-- Returns the name of whatever was taken, or nil.
function Settings.Sv_StripBlocked( player, blocked )
	local removed = nil
	local ok = pcall( function()
		sm.container.beginTransaction()
		for _, container in ipairs( { player:getInventory(), player:getCarry() } ) do
			if container and sm.exists( container ) then
				for i = 0, container:getSize() - 1 do
					local item = container:getItem( i )
					if item and item.uuid then
						local name = blocked[tostring( item.uuid )]
						if name then
							sm.container.setItem( container, i, sm.uuid.getNil(), 0 )
							removed = name
						end
					end
				end
			end
		end
		sm.container.endTransaction()
	end )
	if not ok then
		pcall( sm.container.abortTransaction )
		return nil
	end
	return removed
end

-- NO stripping. A creative inventory is infinite (CreativeGame sets
-- enableLimitedInventory = false), so clearing a slot refills instantly and
-- reports success forever -- measured as "took firelauncher" twelve times in a
-- second while the player stood there holding it. The item cannot be taken away;
-- the TOOL is disabled instead, in GuardedTools.lua.
function Settings.Sv_CheckTools( players, blocked, notify )
	for _, player in ipairs( players ) do
		local ok, uuid = pcall( function() return player:getCurrentToolUuid() end )
		if ok and uuid then
			local name = blocked[tostring( uuid )]
			if name then
				notify( player, name )
			end
		end
	end
end


-- WORLD STATE, CLEARED WHEN THE WORLD CHANGES.
--
-- Everything in Settings.json is one file for the whole MOD, shared by every
-- world ever created from it -- so a brand new world inherits the last one's
-- protection mode and buildopen flag. That is not a leftover, it happens every
-- single time, and it is why a fresh world came up locked.
--
-- Split deliberately rather than wiping the file: most settings are the HOST's
-- preferences -- which tools are on, alarm thresholds, plot size, city style --
-- and losing those on every new world would be its own bug. Only the two that
-- describe the state of a particular world are reset.
function Settings.Sv_ResetWorldState( stamp )
	Settings.Sv_SetQuiet( "protection", "open" )
	Settings.Sv_SetQuiet( "buildopen", true )
	Settings.Sv_SetQuiet( "worldstamp", stamp )
end
