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
	sledgehammer = {
		sm.uuid.new( "bb641a4f-e391-441c-bc6d-0ae21a069476" ),
		sm.uuid.new( "ed185725-ea12-43fc-9cd7-4295d0dbf88b" ),   -- creative variant
	},
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
	lift = { sm.uuid.new( "8f190ce2-3a59-423e-8483-a7aa67bd5bc0" ) },
	glowsticks = { sm.uuid.new( "9506abb9-e415-4229-a824-28a479cca788" ) },
}

-- Every setting is { key, kind, default, help, apply }. Adding one means adding
-- a row here and nothing else -- /set and /settings pick it up automatically.
Settings.SCHEMA = {
	-- Two halves, because the engine has two mechanisms. setFireLimit caps how
	-- many fire instances may exist; AttachedFireManager is the separate system
	-- that walks burning shapes and lights their neighbours. Capping instances
	-- without stopping the manager would leave spread logic running against a
	-- zero budget, so our World also declines to tick it (see World.lua).
	{ key = "fire", kind = "bool", default = false,
	  help = "let fire exist and spread at all",
	  apply = function( v )
		pcall( sm.fire.setFireLimit, v and ( FIRE_INSTANCE_LIMIT or 128 ) or 0 )
		g_swFireEnabled = v and true or false
	  end },

	{ key = "terraindamage", kind = "bool", default = false,
	  help = "let explosions crater the ground",
	  apply = function( v ) g_swProtectTerrain = not v end },

	{ key = "aggro", kind = "bool", default = false,
	  help = "let tapebots and other units attack",
	  apply = function( v ) pcall( sm.game.setEnableAggro, v ) end },

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
	{ key = "lift", kind = "bool", default = true, help = "allow the lift" },

	{ key = "plots", kind = "bool", default = false, help = "restrict building to owned plots" },
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
	{ key = "protection", kind = "string", default = "open", hidden = true,
	  help = "current protection mode: open, locked or display" },

	{ key = "alarmdrop", kind = "number", default = 250,
	  help = "blocks that must vanish at once to trip the grief alarm" },
	{ key = "alarmlock", kind = "bool", default = true,
	  help = "grief alarm locks the world by itself" },
	{ key = "autosave", kind = "number", default = 10,
	  help = "minutes between automatic snapshots, 0 for off" },
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
		value = tostring( raw )
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
function Settings.Sv_SetQuiet( key, value )
	Settings.values[key] = value
	Settings.Sv_Save()
end


--[[ presets ]]

-- A named bundle of settings, so a host can flip the whole server between phases
-- of an event with one command instead of a dozen. Only the keys listed change;
-- anything not mentioned keeps its current value, so a host's own tuning is not
-- silently thrown away.
Settings.PRESETS = {
	build = {
		label = "BUILD -- an event in progress",
		values = {
			buildopen = true, plots = true, pushintruders = true,
			protection = "open",
			fire = false, terraindamage = false, aggro = false,
			claygun = false, firelauncher = false, extinguisher = false,
			cornades = false, beacons = false, fireworks = false,
			plasmadrills = false, radios = false, horns = false,
			sledgehammer = true, spudguns = true, glowsticks = true,
			painttool = true, connecttool = true, weldtool = true, lift = true,
			alarmlock = true, alarmdrop = 250, autosave = 10, autoremove = true,
		},
	},
	show = {
		label = "SHOW -- locked, but seats and buttons still work",
		values = {
			buildopen = false, protection = "display",
			plots = true, pushintruders = false,
			alarmlock = true, alarmdrop = 100, autosave = 0,
		},
	},
	lockdown = {
		label = "LOCKDOWN -- locked hard, seats and controllers dead too",
		values = {
			buildopen = false, protection = "locked",
			plots = true, pushintruders = true,
			alarmlock = true, alarmdrop = 50, autosave = 0,
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
			painttool = true, connecttool = true, weldtool = true, lift = true,
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
function Settings.Sv_BlockedTools()
	local blocked = {}
	for name, uuids in pairs( TOOLS ) do
		if Settings.Get( name ) == false then
			for _, uuid in ipairs( uuids ) do
				blocked[tostring( uuid )] = name
			end
		end
	end
	return blocked
end

-- The item stays in the creative menu -- Lua cannot edit that list -- but the
-- moment it is equipped the client is told to drop it, so it never gets used.
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
