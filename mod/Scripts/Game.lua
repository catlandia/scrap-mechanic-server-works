dofile( "$GAME_DATA/Scripts/game/CreativeGame.lua" )
dofile( "$CONTENT_DATA/Scripts/Protection.lua" )
dofile( "$CONTENT_DATA/Scripts/Identity.lua" )
dofile( "$CONTENT_DATA/Scripts/Snapshots.lua" )
dofile( "$CONTENT_DATA/Scripts/Plots.lua" )
dofile( "$CONTENT_DATA/Scripts/World.lua" )
dofile( "$CONTENT_DATA/Scripts/Settings.lua" )
dofile( "$CONTENT_DATA/Scripts/Rules.lua" )

Game = class( CreativeGame )

-- Our own World subclasses CreativeFlatWorld. Flat because this is a build-event
-- server: plots want flat ground, and flat terrain is cheaper to load and render.
-- The subclass exists to stop explosions cratering the ground -- see World.lua.
Game.worldScriptFilename = "$CONTENT_DATA/Scripts/World.lua"
Game.worldScriptClass = "World"

local TICKS_PER_SECOND = 40

-- Tunables live in Settings.lua now; these are only the fallbacks used before
-- settings have loaded.
local TOOL_CHECK_TICKS = 10

-- How many words a player name may contain. bindChatCommand splits arguments on
-- spaces and the parser has no quoting, so a name like "June Carya" arrives as
-- separate arguments and vanilla's own /kick simply cannot target it. Declaring
-- spare trailing optional parameters and rejoining them is the fix.
local NAME_WORDS = 6

local function nameParams()
	local spec = { { "string", "name-or-id", false } }
	for i = 2, NAME_WORDS do
		spec[#spec + 1] = { "string", "w" .. i, true }
	end
	return spec
end

local function joinName( params, from )
	local parts = {}
	for i = from, #params do
		local v = params[i]
		if type( v ) == "string" and v ~= "" then
			parts[#parts + 1] = v
		end
	end
	return table.concat( parts, " " )
end

-- Accepts a display name, a perma id (SW-0007) or a session id from /players.
local function resolveTarget( token )
	local byId = tonumber( token )
	if byId then
		for _, p in ipairs( sm.player.getAllPlayers() ) do
			if p.id == byId then return p, p.name end
		end
	end
	local key = string.lower( token )
	for _, p in ipairs( sm.player.getAllPlayers() ) do
		if string.lower( p.name ) == key then return p, p.name end
	end
	local name = Identity.Sv_NameOf( token )
	return nil, name or token
end


--[[ server ]]

function Game.server_onCreate( self )
	-- Must come first and must not be skipped. CreativeGame.server_onCreate is
	-- what creates g_unitManager, g_kinematicManager and g_beaconManager; a
	-- Custom Game that overrides this without calling up leaves them nil, and
	-- then every collision and every interactable throws a Lua error with a full
	-- traceback. That is not theoretical -- it is what produced a 1.79 GB log and
	-- dragged a single-player session from 40 Hz down to 11 Hz.
	CreativeGame.server_onCreate( self )

	if g_unitManager == nil then
		sm.log.warning( "[ServerWorks] g_unitManager is nil after base create -- collisions will error" )
	end

	self.sv.kickQueue = {}
	self.sv.buildDeadline = nil
	self.sv.nextAutoSnapshot = nil
	self.sv.lastCensus = nil
	self.sv.nextToolCheck = 0
	self.sv.blockedTools = {}
	self.sv.alarmQuietUntil = 0
	self.sv.pendingRestore = nil
	self.sv.nextBanReload = 0

	Identity.Sv_Load()

	-- After the base create, so FIRE_INSTANCE_LIMIT is defined by the time the
	-- fire setting applies itself.
	Settings.Sv_Load()

	self.sv.snapshots = Snapshots()
	self.sv.snapshots:sv_onCreate()

	self.sv.plots = Plots()
	self.sv.plots:sv_onCreate( self.sv.saved and self.sv.saved.plots )

	self.sv.rules = Rules()
	self.sv.rules:sv_onCreate()

	self.sv.protection = Protection()
	self.sv.protection:sv_onCreate( self.sv.saved and self.sv.saved.protectionMode )

	-- Plot ownership decides per body; /lockdown still outranks it.
	local plots = self.sv.plots
	self.sv.protection:sv_setResolver( function( body )
		-- Rule 3: nothing is buildable at all until the host opens building.
		if Settings.Get( "buildopen" ) == false then
			return false
		end
		return plots:sv_bodyIsOpen( body )
	end )

	-- Re-assert on load: a world saved while locked must come back locked, or a
	-- host who restarts mid-event silently reopens everything to a griefer.
	self:sv_applySettings()

	local _, detail = self.sv.protection:sv_setMode( self.sv.protection:sv_getMode() )
	sm.log.info( string.format( "[ServerWorks] protection restored: %s (%s)",
		self.sv.protection:sv_getMode(), tostring( detail ) ) )
end

-- Pull settings into the live objects that cannot apply themselves, because they
-- are per-world instance state rather than globals.
function Game.sv_applySettings( self )
	self.sv.plots.enabled = Settings.Get( "plots" ) == true
	Plots.PUSH_INTRUDERS = Settings.Get( "pushintruders" ) == true
	self.sv.blockedTools = Settings.Sv_BlockedTools()

	local minutes = tonumber( Settings.Get( "autosave" ) ) or 0
	if minutes > 0 then
		self.sv.autoSnapshotMinutes = minutes
		if self.sv.nextAutoSnapshot == nil then
			self.sv.nextAutoSnapshot = sm.game.getCurrentTick() + minutes * 60 * 40
		end
	else
		self.sv.nextAutoSnapshot = nil
	end
end

-- Which plot a body sits on, for per-plot snapshot and restore.
function Game.sv_plotOfBody( self )
	local plots = self.sv.plots
	return function( body )
		local z = plots:sv_locate( body.worldPosition )
		return ( z and z.kind == "plot" ) and z.index or nil
	end
end

-- Wipe just one plot, so a restore can repair a single build without flattening
-- the city around it.
function Game.sv_clearPlot( self, index )
	local plots = self.sv.plots
	local removed = 0
	for _, body in ipairs( sm.body.getAllBodies() ) do
		if sm.exists( body ) then
			local z = plots:sv_locate( body.worldPosition )
			if z and z.kind == "plot" and z.index == index then
				for _, shape in ipairs( body:getShapes() ) do
					shape:destroyShape()
				end
				removed = removed + 1
			end
		end
	end
	return removed
end

function Game.sv_world( self )
	return self.sv.saved and self.sv.saved.world or nil
end

function Game.sv_broadcast( self, text )
	self.network:sendToClients( "client_showMessage", text )
end

function Game.sv_quietAlarm( self, seconds )
	self.sv.alarmQuietUntil = sm.game.getCurrentTick() + seconds * TICKS_PER_SECOND
end

function Game.sv_persist( self )
	if self.sv.saved then
		self.sv.saved.protectionMode = self.sv.protection:sv_getMode()
		self.sv.saved.plots = self.sv.plots:sv_serialise()
		self.storage:save( self.sv.saved )
	end
end

function Game.server_onFixedUpdate( self, dt )
	CreativeGame.server_onFixedUpdate( self, dt )

	local tick = sm.game.getCurrentTick()

	-- Never let a fault in our own code take the server down mid-event. If the
	-- patrol breaks, the world stays as it is and /unlock still works.
	local ok, err = pcall( function()
		self.sv.plots:sv_updateOccupancy( function( player )
			return Identity.Sv_PermaOf( player )
		end, tick )
		self.sv.protection:sv_onFixedUpdate()
	end )
	if not ok and not self.sv.patrolFaulted then
		self.sv.patrolFaulted = true    -- log once, never per tick
		sm.log.warning( "[ServerWorks] protection patrol disabled after error: " .. tostring( err ) )
		self.sv.protection.patrolEnabled = false
	end

	self:sv_stepSnapshots()
	self:sv_checkRules( tick )
	self:sv_checkToolGuard( tick )
	self:sv_checkGriefAlarm( tick )
	self:sv_checkTimers( tick )
	self:sv_flushKicks()

	-- Re-read the ban file so a tool outside the game can push a ban mid-event.
	if tick >= self.sv.nextBanReload then
		self.sv.nextBanReload = tick + Identity.RELOAD_SECONDS * TICKS_PER_SECOND
		pcall( Identity.Sv_Reload )
		for _, player in ipairs( sm.player.getAllPlayers() ) do
			if player ~= sm.player.getHostPlayer() and Identity.Sv_IsBanned( player ) then
				table.insert( self.sv.kickQueue, player )
			end
		end
	end
end

-- Forbidden tools are pulled out of the player's hands as soon as they equip
-- one. The item is still listed in the creative menu -- nothing in Lua can edit
-- that list -- but it can never be held long enough to be used.
-- Rules audit: per-plot budgets and banned parts. One pass every few seconds
-- rather than every tick -- a budget is a slow-moving property and paying for
-- the scan 40 times a second would cost more than the rule saves.
function Game.sv_checkRules( self, tick )
	local ok, report = pcall( function()
		return self.sv.rules:sv_audit( tick, self.sv.plots, Settings.Get )
	end )
	if not ok then
		if not self.sv.rulesFaulted then
			self.sv.rulesFaulted = true    -- once, never per tick
			sm.log.warning( "[ServerWorks] rules audit disabled: " .. tostring( report ) )
		end
		return
	end
	if report == nil then return end     -- not due yet

	-- A plot over budget stops being buildable until its owner trims it. Nothing
	-- already built is taken away: over-budget is a brake, not a punishment.
	self.sv.plots.overBudget = {}
	for index, reasons in pairs( self.sv.rules.violations ) do
		self.sv.plots.overBudget[index] = true
		if self.sv.rules:sv_shouldReport( index, tick ) then
			local owner = self.sv.plots.owners[index]
			local name = owner and Identity.Sv_NameOf( owner )
			for _, p in ipairs( sm.player.getAllPlayers() ) do
				if name and p.name == name then
					self.network:sendToClient( p, "client_showMessage",
						string.format( "Plot %d is over the server limits and is locked until you trim it:", index ) )
					for _, reason in ipairs( reasons ) do
						self.network:sendToClient( p, "client_showMessage", "   " .. reason )
					end
				end
			end
		end
	end

	if #report.contraband > 0 then
		local autoremove = Settings.Get( "autoremove" ) == true
		local labels = {}
		for _, item in ipairs( report.contraband ) do
			labels[item.label] = ( labels[item.label] or 0 ) + 1
			if autoremove and sm.exists( item.shape ) then
				pcall( function() item.shape:destroyShape() end )
			end
		end
		for label, n in pairs( labels ) do
			self:sv_broadcast( string.format( "%d %s%s %s -- banned on this server%s",
				n, label, n > 1 and "s" or "", autoremove and "removed" or "found",
				autoremove and "" or " (host: /set autoremove on)" ) )
		end
		if autoremove then self:sv_quietAlarm( 15 ) end
	end
end

function Game.sv_checkToolGuard( self, tick )
	if tick < self.sv.nextToolCheck then return end
	self.sv.nextToolCheck = tick + TOOL_CHECK_TICKS

	local blocked = self.sv.blockedTools
	if next( blocked ) == nil then return end

	-- The host runs the event: they need every tool, including the ones banned
	-- for guests, to place and clear things. Skip them entirely.
	local host = sm.player.getHostPlayer()
	local guests = {}
	for _, p in ipairs( sm.player.getAllPlayers() ) do
		if p ~= host then guests[#guests + 1] = p end
	end

	Settings.Sv_CheckTools( guests, blocked, function( player, name )
		self.network:sendToClient( player, "client_dropTool", name )
	end )
end

function Game.client_dropTool( self, name )
	-- forceTool is client-side only; the server can see what you hold but only
	-- your own client can put it away.
	pcall( sm.tool.forceTool, nil )
	sm.gui.chatMessage( string.format( "The %s is disabled on this server.", tostring( name ) ) )
end

function Game.sv_stepSnapshots( self )
	local ok, done = pcall( function() return self.sv.snapshots:sv_onFixedUpdate() end )
	if not ok then
		sm.log.warning( "[ServerWorks] snapshot job aborted: " .. tostring( done ) )
		self.sv.snapshots.job = nil
		return
	end
	if done then
		self:sv_quietAlarm( 10 )
		self:sv_broadcast( done )
	end
end

-- The engine fires nothing when a plain block is destroyed, so mass deletion can
-- only be noticed by watching the total shape count fall. Protection's patrol
-- already produces that number once per cycle for one extra call per body.
function Game.sv_checkGriefAlarm( self, tick )
	local census = self.sv.protection:sv_census()
	if census == nil then return end

	local previous = self.sv.lastCensus
	self.sv.lastCensus = census

	if previous == nil or tick < self.sv.alarmQuietUntil then return end
	if self.sv.snapshots:sv_busy() then return end

	local lost = previous - census
	if lost < ( tonumber( Settings.Get( "alarmdrop" ) ) or 250 ) then return end

	sm.log.info( string.format( "[ServerWorks] GRIEF ALARM: %d shapes lost", lost ) )
	self:sv_broadcast( string.format( "*** %d blocks just disappeared ***", lost ) )
	self:sv_quietAlarm( 30 )

	if Settings.Get( "alarmlock" ) and self.sv.protection:sv_getMode() ~= "locked" then
		local locked, detail = self.sv.protection:sv_setMode( "locked" )
		if locked then
			self:sv_persist()
			self:sv_broadcast( "BUILDS LOCKED automatically -- " .. detail )
			self:sv_broadcast( "Host: /restore <name> to roll back, /unlock to resume." )
		end
	end
end

function Game.sv_checkTimers( self, tick )
	if self.sv.buildDeadline and tick >= self.sv.buildDeadline then
		self.sv.buildDeadline = nil
		local locked, detail = self.sv.protection:sv_setMode( "locked" )
		if locked then
			self:sv_persist()
			self:sv_broadcast( "Build time is up. BUILDS LOCKED -- " .. detail )
		end
		self.sv.snapshots:sv_beginCapture( "buildend", self:sv_world(), self:sv_plotOfBody() )
	end

	if self.sv.nextAutoSnapshot and tick >= self.sv.nextAutoSnapshot then
		self.sv.nextAutoSnapshot = tick + self.sv.autoSnapshotMinutes * 60 * TICKS_PER_SECOND
		if not self.sv.snapshots:sv_busy() then
			local started, detail = self.sv.snapshots:sv_beginCapture(
				self.sv.snapshots:sv_autoName(), self:sv_world(), self:sv_plotOfBody() )
			if started then
				sm.log.info( "[ServerWorks] auto-snapshot: " .. detail )
			end
		end
	end
end

function Game.sv_flushKicks( self )
	if #self.sv.kickQueue == 0 then return end
	local pending = self.sv.kickQueue
	self.sv.kickQueue = {}
	for _, player in ipairs( pending ) do
		if sm.exists( player ) then
			sm.log.info( "[ServerWorks] kicking banned player " .. tostring( player.name ) )
			sm.game.kickPlayer( player )
		end
	end
end

function Game.server_onPlayerJoined( self, player, newPlayer )
	CreativeGame.server_onPlayerJoined( self, player, newPlayer )

	local rec = Identity.Sv_Touch( player )

	-- Allow list first. It is the stronger check: a ban names the person who must
	-- stay out and loses to a rename, an allow list names everyone who may come in
	-- and a rename just produces another name that is not on it.
	if Settings.Get( "allowlist" ) and player ~= sm.player.getHostPlayer()
		and not Identity.Sv_IsAllowed( player ) then
		sm.log.info( "[ServerWorks] not on allow list: " .. tostring( player.name ) )
		table.insert( self.sv.kickQueue, player )
		return
	end

	if Identity.Sv_IsBanned( player ) then
		-- Not kicked inline: the player is still being constructed here, and the
		-- base class has spawn work queued behind us. One tick later is safe.
		table.insert( self.sv.kickQueue, player )
		return
	end

	self.network:sendToClient( player, "client_welcome", {
		perma = rec.perma,
		plots = self.sv.plots.enabled,
	} )
end


--[[ tutorial ]]

function Game.client_welcome( self, data )
	local lines = {
		"------------------------------------------",
		"  Welcome. This server is running SERVER WORKS.",
		string.format( "  Your permanent id is %s.", tostring( data.perma ) ),
		"",
	}
	if data.plots then
		lines[#lines + 1] = "  This is a PLOT event. How it works:"
		lines[#lines + 1] = "   1. Stand on an empty plot and type  /plot claim"
		lines[#lines + 1] = "   2. You can only build on your own plot."
		lines[#lines + 1] = "   3. Walk onto someone else's plot and you get pushed off."
		lines[#lines + 1] = "   4. To build with a neighbour, both type  /plot team <them>"
		lines[#lines + 1] = "      Then the gap between your plots becomes shared ground."
		lines[#lines + 1] = "   5. /plot info tells you where you are stood."
	else
		lines[#lines + 1] = "  Free build. The host may lock builds at any time."
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = "  Type /help for commands, /rules for the server rules."
	lines[#lines + 1] = "------------------------------------------"

	for _, line in ipairs( lines ) do
		sm.gui.chatMessage( line )
	end
end

function Game.client_showMessage( self, text )
	sm.gui.chatMessage( text )
end


--[[ commands ]]

function Game.client_onCreate( self )
	CreativeGame.client_onCreate( self )

	sm.game.bindChatCommand( "/help", {}, "cl_onAdminCommand",
		"How this server works and what you can type" )
	sm.game.bindChatCommand( "/rules", {}, "cl_onAdminCommand",
		"The server rules and the numbers currently in force" )
	sm.game.bindChatCommand( "/home", {}, "cl_onAdminCommand",
		"Teleport back to your own plot" )

	sm.game.bindChatCommand( "/plot",
		{ { "string", "action", false, { "claim", "info", "team", "leave", "list" } },
		  { "string", "who", true } },
		"cl_onAdminCommand",
		"claim | info | team <player> | leave | list" )

	sm.game.bindChatCommand( "/settings", {}, "cl_onAdminCommand",
		"Host: show every server setting and what it does" )
	sm.game.bindChatCommand( "/set",
		{ { "string", "setting", false }, { "string", "value", false } },
		"cl_onAdminCommand",
		"Host: change a setting, e.g. /set fire off  or  /set alarmdrop 100" )

	sm.game.bindChatCommand( "/plots", { { "string", "onoff", true, { "on", "off" } } },
		"cl_onAdminCommand", "Host: shortcut for /set plots on|off" )
	sm.game.bindChatCommand( "/plotgrid",
		{ { "number", "plotBlocks", false }, { "number", "gapBlocks", false },
		  { "number", "cols", false }, { "number", "rows", false } },
		"cl_onAdminCommand", "Host: reshape the city grid (wipes claims)" )

	sm.game.bindChatCommand( "/lockdown", { { "string", "mode", true, { "strict", "display" } } },
		"cl_onAdminCommand",
		"Host: lock every build. strict (default) also blocks seats/buttons/controllers" )
	sm.game.bindChatCommand( "/unlock", {}, "cl_onAdminCommand",
		"Host: reopen the world for building" )
	sm.game.bindChatCommand( "/protection", {}, "cl_onAdminCommand",
		"Host: protection state, shape count, running jobs" )
	sm.game.bindChatCommand( "/buildtime", { { "number", "minutes", false } }, "cl_onAdminCommand",
		"Host: lock builds in N minutes and snapshot then. 0 cancels" )
	sm.game.bindChatCommand( "/autosave", { { "number", "minutes", false } }, "cl_onAdminCommand",
		"Host: snapshot every N minutes. 0 turns it off" )

	sm.game.bindChatCommand( "/snapshot", { { "string", "name", true } }, "cl_onAdminCommand",
		"Host: save every build so it can be restored" )
	sm.game.bindChatCommand( "/snapshots", {}, "cl_onAdminCommand", "Host: list snapshots" )
	sm.game.bindChatCommand( "/purge",
		{ { "string", "what", false, { "here", "plot", "walkways" } }, { "number", "n", true } },
		"cl_onAdminCommand",
		"Host: delete junk. here <radius> | plot <n> | walkways" )
	sm.game.bindChatCommand( "/restore",
		{ { "string", "name", false }, { "number", "plot", true } }, "cl_onAdminCommand",
		"Host: rebuild from a snapshot. Add a plot number to repair just that plot. Run twice to confirm" )

	sm.game.bindChatCommand( "/players", {}, "cl_onAdminCommand",
		"Who is here, with session id and permanent id" )
	sm.game.bindChatCommand( "/known", {}, "cl_onAdminCommand",
		"Host: everyone who has ever joined" )
	sm.game.bindChatCommand( "/ban", nameParams(), "cl_onAdminCommand",
		"Host: permanently ban by name, session id or perma id" )
	sm.game.bindChatCommand( "/unban", nameParams(), "cl_onAdminCommand", "Host: lift a ban" )
	sm.game.bindChatCommand( "/banlist", {}, "cl_onAdminCommand", "Host: show the ban list" )
	sm.game.bindChatCommand( "/allow", nameParams(), "cl_onAdminCommand",
		"Host: let someone in when allowlist is on. Works before they ever join" )
	sm.game.bindChatCommand( "/unallow", nameParams(), "cl_onAdminCommand",
		"Host: take someone off the allow list" )
	sm.game.bindChatCommand( "/allowlist", {}, "cl_onAdminCommand",
		"Host: show who is allowed in" )
	sm.game.bindChatCommand( "/kick", nameParams(), "cl_onAdminCommand",
		"Host: kick for this session only" )
end

function Game.cl_onAdminCommand( self, params )
	self.network:sendToServer( "sv_n_adminCommand", params )
end

local PLAYER_COMMANDS = {
	["/help"] = true, ["/plot"] = true, ["/players"] = true,
	["/rules"] = true, ["/home"] = true,
}

function Game.sv_n_adminCommand( self, params, player )
	local function reply( text )
		self.network:sendToClient( player, "client_showMessage", text )
	end

	local cmd = params[1]
	local isHost = ( player == sm.player.getHostPlayer() )

	-- Everything that changes what other people can do is host-only. /plot and
	-- /help are the exceptions, since guests need them to take part at all.
	if not isHost and not PLAYER_COMMANDS[cmd] then
		reply( "Host only." )
		return
	end

	if cmd == "/help" then
		reply( "SERVER WORKS" )
		reply( "  /plot claim         claim the plot you are stood on" )
		reply( "  /plot info          who owns this ground" )
		reply( "  /plot team <name>   ask a neighbour to team up (they type it back)" )
		reply( "  /plot leave         give up your plot" )
		reply( "  /players            who is here" )
		reply( "  /home               teleport back to your own plot" )
		if isHost then
			reply( "HOST" )
			reply( "  /settings  /set <name> <value>" )
			reply( "  /plots on|off  /plotgrid <plot> <gap> <cols> <rows>" )
			reply( "  /lockdown  /unlock  /protection  /buildtime N  /autosave N" )
			reply( "  /snapshot [name]  /snapshots  /restore <name> [plot]" )
			reply( "  /purge here <m> | /purge plot <n> | /purge walkways" )
			reply( "  /ban <who>  /unban <who>  /banlist  /known  /kick <who>" )
			reply( "  /allow <who>  /unallow <who>  /allowlist" )
		end
		return
	end

	if cmd == "/rules" then
		-- Read out of the live settings, so the board can never drift from what
		-- the server actually enforces.
		local function num( k ) return tostring( Settings.Get( k ) ) end
		local function onoff( k ) return Settings.Get( k ) and "allowed" or "BANNED" end
		reply( "SERVER RULES" )
		reply( "  1. No basements -- nothing below z " .. num( "minbuildheight" ) )
		reply( "  2. One plot per player" )
		reply( "  3. No building before build time starts" )
		reply( "  4. Don't spam lights -- max " .. num( "maxlights" ) .. " per plot" )
		reply( "  5. Don't leave radios on -- radios are " .. onoff( "radios" ) )
		reply( "  6. Max " .. num( "maxbots" ) .. " cook/dress/craft bot per plot" )
		reply( "  7. No noise pollution -- horns are " .. onoff( "horns" ) )
		reply( "  8. Multiple people can share plots if they agree (/plot team)" )
		reply( "  9. No griefing or trolling. Bans are permanent." )
		reply( "  10. Max " .. num( "maxjoints" ) .. " combined bearings/pistons/suspensions per plot" )
		reply( "  11. Fireworks " .. onoff( "fireworks" ) .. ", plasma drills " .. onoff( "plasmadrills" ) )
		reply( "  12. Beacons " .. onoff( "beacons" ) )
		reply( "Go over a limit and your plot locks until you trim it. Nothing is taken away." )
		return
	end

	-- Player-vs-player collision cannot be turned off (see the note in
	-- Settings.lua for the full evidence), so people do still get shoved and
	-- flung -- stream chat, verbatim: "yall are gonna have to teleport me towards
	-- here cuz i got flung real hard". This does not prevent that, it undoes it.
	if cmd == "/home" then
		local perma = Identity.Sv_PermaOf( player )
		local index = perma and self.sv.plots:sv_plotOf( perma )
		if index == nil then
			reply( "you do not own a plot -- stand on an empty one and /plot claim" )
			return
		end
		local character = player:getCharacter()
		if not ( character and sm.exists( character ) ) then
			reply( "no character to move" )
			return
		end
		local plots = self.sv.plots
		local stride = plots:sv_stride()
		local ox, oy = plots:sv_originBlocks()
		local col = ( index - 1 ) % plots.grid.cols
		local row = math.floor( ( index - 1 ) / plots.grid.cols )
		local bx = ox + col * stride + plots.grid.plot * 0.5
		local by = oy + row * stride + plots.grid.plot * 0.5
		local ok = pcall( function()
			character:setWorldPosition( sm.vec3.new( bx * Plots.BLOCK, by * Plots.BLOCK,
				character.worldPosition.z + 1 ) )
		end )
		reply( ok and string.format( "sent you to plot %d", index ) or "teleport failed" )
		return
	end

	if cmd == "/plot" then
		self:sv_plotCommand( params, player, reply )
		return
	end

	if cmd == "/settings" then
		reply( "settings -- /set <name> <value>" )
		for _, line in ipairs( Settings.Sv_Lines() ) do reply( line ) end
		reply( "note: 'explosives' is not a setting. Cornades cannot be removed from" )
		reply( "the creative menu from a script, but they can no longer damage builds" )
		reply( "or the ground, so all they do is make noise." )
		return
	end

	if cmd == "/set" then
		local ok, detail = Settings.Sv_Set( params[2], params[3] )
		reply( detail )
		if ok then
			self:sv_applySettings()
			-- Re-sweep so a changed rule takes hold on existing bodies at once.
			self.sv.protection:sv_setMode( self.sv.protection:sv_getMode() )
			self:sv_broadcast( string.format( "Server setting changed: %s", detail ) )
		end
		return
	end

	if cmd == "/plots" then
		local want = params[2]
		if want == nil or want == "" then
			want = Settings.Get( "plots" ) and "off" or "on"
		end
		local ok, detail = Settings.Sv_Set( "plots", want )
		if not ok then reply( detail ) return end
		self:sv_applySettings()
		self:sv_persist()
		self.sv.protection:sv_setMode( self.sv.protection:sv_getMode() )   -- re-sweep
		local claimed, total = self.sv.plots:sv_counts()
		self:sv_broadcast( string.format( "Plot system %s (%d of %d plots claimed).",
			self.sv.plots.enabled and "ON" or "OFF", claimed, total ) )

	elseif cmd == "/plotgrid" then
		local plots = self.sv.plots
		plots.grid = {
			plot = math.max( 2, math.floor( tonumber( params[2] ) or 20 ) ),
			gap = math.max( 0, math.floor( tonumber( params[3] ) or 1 ) ),
			cols = math.max( 1, math.floor( tonumber( params[4] ) or 10 ) ),
			rows = math.max( 1, math.floor( tonumber( params[5] ) or 10 ) ),
		}
		plots.owners = {}
		plots.teams = {}
		plots.requests = {}
		self:sv_persist()
		local s = plots:sv_stride()
		self:sv_broadcast( string.format(
			"Grid rebuilt: %dx%d plots of %d blocks, %d block gap. City is %.1f m across. All claims cleared.",
			plots.grid.cols, plots.grid.rows, plots.grid.plot, plots.grid.gap,
			plots.grid.cols * s * Plots.BLOCK ) )

	elseif cmd == "/lockdown" or cmd == "/unlock" then
		local mode = "open"
		if cmd == "/lockdown" then
			mode = ( params[2] == "display" ) and "display" or "locked"
		end
		local ok, detail = self.sv.protection:sv_setMode( mode )
		if ok then
			self:sv_persist()
			sm.log.info( string.format( "[ServerWorks] protection -> %s (%s)", mode, detail ) )
			self:sv_broadcast(
				mode == "locked" and ( "BUILDS LOCKED (strict) -- " .. detail )
				or mode == "display" and ( "BUILDS LOCKED, seats and buttons still work -- " .. detail )
				or ( "Building reopened -- " .. detail ) )
		else
			reply( "Failed: " .. tostring( detail ) )
		end

	elseif cmd == "/protection" then
		reply( self.sv.protection:sv_status() )
		reply( string.format( "shapes in world: %s",
			tostring( self.sv.protection:sv_census() or "counting..." ) ) )
		local claimed, total = self.sv.plots:sv_counts()
		reply( string.format( "plots: %s, %d of %d claimed",
			self.sv.plots.enabled and "ON" or "off", claimed, total ) )
		local progress = self.sv.snapshots:sv_progress()
		if progress then reply( progress ) end
		if self.sv.buildDeadline then
			local left = ( self.sv.buildDeadline - sm.game.getCurrentTick() ) / ( 60 * TICKS_PER_SECOND )
			reply( string.format( "build time remaining: %.1f min", left ) )
		end

	elseif cmd == "/buildtime" then
		local minutes = tonumber( params[2] ) or 0
		if minutes <= 0 then
			self.sv.buildDeadline = nil
			reply( "build timer cancelled" )
		else
			self.sv.buildDeadline = sm.game.getCurrentTick() + minutes * 60 * TICKS_PER_SECOND
			self:sv_broadcast( string.format( "Building closes in %g minutes.", minutes ) )
		end

	elseif cmd == "/autosave" then
		local ok, detail = Settings.Sv_Set( "autosave", params[2] )
		reply( detail )
		if ok then
			self.sv.nextAutoSnapshot = nil     -- force the schedule to be rebuilt
			self:sv_applySettings()
		end

	elseif cmd == "/snapshot" then
		local name = params[2]
		if name == nil or name == "" then name = "manual" end
		local ok, detail = self.sv.snapshots:sv_beginCapture( name, self:sv_world(), self:sv_plotOfBody() )
		reply( ok and detail or ( "Failed: " .. tostring( detail ) ) )

	elseif cmd == "/snapshots" then
		local names = self.sv.snapshots:sv_names()
		if #names == 0 then
			reply( "no snapshots yet -- /snapshot to make one" )
		else
			for _, line in ipairs( names ) do reply( "  " .. line ) end
		end

	elseif cmd == "/purge" then
		-- Script-side destroyShape ignores the erasable flag entirely -- vanilla's
		-- own sv_e_clear relies on that -- so this reaches litter that protection
		-- has otherwise made permanent.
		local what = params[2]
		local n = tonumber( params[3] )
		local removed = 0

		if what == "plot" then
			if n == nil then reply( "/purge plot <number>" ) return end
			removed = self:sv_clearPlot( n )
			reply( string.format( "cleared %d bodies from plot %d", removed, n ) )

		elseif what == "here" then
			local radius = n or 5
			local character = player:getCharacter()
			if not ( character and sm.exists( character ) ) then reply( "no character" ) return end
			local origin = character.worldPosition
			for _, body in ipairs( sm.body.getAllBodies() ) do
				if sm.exists( body ) and ( body.worldPosition - origin ):length() <= radius then
					for _, shape in ipairs( body:getShapes() ) do shape:destroyShape() end
					removed = removed + 1
				end
			end
			reply( string.format( "cleared %d bodies within %g m", removed, radius ) )

		elseif what == "walkways" then
			-- Everything standing on ground nobody is allowed to build on.
			local plots = self.sv.plots
			for _, body in ipairs( sm.body.getAllBodies() ) do
				if sm.exists( body ) then
					local z = plots:sv_locate( body.worldPosition )
					if z == nil or z.kind ~= "plot" then
						for _, shape in ipairs( body:getShapes() ) do shape:destroyShape() end
						removed = removed + 1
					end
				end
			end
			reply( string.format( "cleared %d bodies off walkways and open ground", removed ) )
		end

		if removed > 0 then
			self:sv_quietAlarm( 20 )   -- our own cleanup must not trip the grief alarm
			sm.log.info( string.format( "[ServerWorks] purge %s: %d bodies", tostring( what ), removed ) )
		end

	elseif cmd == "/restore" then
		local name = params[2]
		local plot = tonumber( params[3] )
		local token = tostring( name ) .. "/" .. tostring( plot )
		-- Two-step on purpose. This deletes before it rebuilds; a fat-fingered
		-- /restore mid-event would do more damage than the griefer did.
		if self.sv.pendingRestore ~= token then
			self.sv.pendingRestore = token
			reply( plot
				and string.format( "/restore %s %d will DELETE everything on plot %d and rebuild it.",
					tostring( name ), plot, plot )
				or string.format( "/restore %s will DELETE THE WHOLE WORLD and rebuild from that snapshot.",
					tostring( name ) ) )
			reply( "Run the same command again to confirm." )
			return
		end
		self.sv.pendingRestore = nil
		self:sv_quietAlarm( 120 )
		local opts = {}
		if plot then
			opts.plot = plot
			opts.clear = function() self:sv_clearPlot( plot ) end
		end
		local ok, detail = self.sv.snapshots:sv_beginRestore( name, self:sv_world(), opts )
		if ok then
			self:sv_broadcast( ( plot and string.format( "Repairing plot %d -- ", plot ) or "Rolling the world back -- " ) .. detail )
		else
			reply( "Failed: " .. tostring( detail ) )
		end

	elseif cmd == "/players" then
		local players = sm.player.getAllPlayers()
		reply( string.format( "%d player(s) here:", #players ) )
		for _, p in ipairs( players ) do
			local perma = Identity.Sv_PermaOf( p ) or "?"
			local plot = self.sv.plots:sv_plotOf( perma )
			reply( string.format( "  id %-3d %-10s %s%s", p.id, perma, p.name,
				plot and string.format( "  [plot %d]", plot ) or "" ) )
		end

	elseif cmd == "/known" then
		for _, line in ipairs( Identity.Sv_KnownLines( 25 ) ) do reply( line ) end

	elseif cmd == "/ban" then
		local token = joinName( params, 2 )
		local target, name = resolveTarget( token )
		if target == sm.player.getHostPlayer() then
			reply( "You cannot ban the host." )
			return
		end
		local ok, detail = Identity.Sv_Ban( name, "" )
		reply( detail )
		if ok then
			sm.log.info( "[ServerWorks] banned " .. name )
			if target and sm.exists( target ) then
				sm.game.banPlayer( target )     -- session-level, so they drop now
				self:sv_broadcast( name .. " was banned." )
			else
				reply( "(not online -- they will be kicked if they ever join)" )
			end
		end

	elseif cmd == "/unban" then
		local ok, detail = Identity.Sv_Unban( joinName( params, 2 ) )
		reply( detail )

	elseif cmd == "/banlist" then
		for _, line in ipairs( Identity.Sv_BanLines() ) do reply( line ) end

	elseif cmd == "/allow" or cmd == "/unallow" then
		local token = joinName( params, 2 )
		local _, name = resolveTarget( token )
		local ok, detail = Identity.Sv_SetAllowed( name or token, cmd == "/allow" )
		reply( detail )
		if ok and cmd == "/unallow" and Settings.Get( "allowlist" ) then
			local target = resolveTarget( token )
			if target and sm.exists( target ) and target ~= sm.player.getHostPlayer() then
				table.insert( self.sv.kickQueue, target )
			end
		end

	elseif cmd == "/allowlist" then
		reply( string.format( "allowlist is %s -- /set allowlist on|off",
			Settings.Get( "allowlist" ) and "ON" or "off" ) )
		for _, line in ipairs( Identity.Sv_AllowLines() ) do reply( line ) end

	elseif cmd == "/kick" then
		local token = joinName( params, 2 )
		local target, name = resolveTarget( token )
		if target == nil then
			reply( string.format( "'%s' is not here -- try /players", token ) )
		elseif target == sm.player.getHostPlayer() then
			reply( "You cannot kick the host." )
		else
			sm.log.info( "[ServerWorks] kicking " .. name )
			sm.game.kickPlayer( target )
			self:sv_broadcast( name .. " was kicked." )
		end
	end
end

function Game.sv_plotCommand( self, params, player, reply )
	local plots = self.sv.plots
	local action = params[2]
	local perma = Identity.Sv_PermaOf( player )

	if perma == nil then
		reply( "you are not registered yet -- rejoin" )
		return
	end
	if not plots.enabled then
		reply( "the plot system is off on this server" )
		return
	end

	local character = player:getCharacter()
	local here = character and sm.exists( character )
		and plots:sv_locate( character.worldPosition ) or nil

	if action == "claim" then
		if here == nil or here.kind ~= "plot" then
			reply( "stand inside a plot to claim it -- you are on the walkway or outside the city" )
			return
		end
		local ok, detail = plots:sv_claim( here.index, perma )
		reply( detail )
		if ok then
			self:sv_persist()
			self:sv_broadcast( string.format( "%s claimed plot %d.", player.name, here.index ) )
		end

	elseif action == "info" then
		if here == nil then
			reply( "you are outside the city" )
		elseif here.kind == "plot" then
			reply( plots:sv_describe( here.index, function( p ) return Identity.Sv_NameOf( p ) end ) )
		elseif here.kind == "corner" then
			reply( "walkway corner -- nobody can build here" )
		else
			local allowed = plots:sv_authorised( here )
			local n = 0
			for _ in pairs( allowed ) do n = n + 1 end
			reply( n > 0 and "shared filler -- the two plots either side are teamed"
				or "filler strip -- team up with the plot opposite to build here" )
		end

	elseif action == "team" then
		local other = params[3]
		if other == nil or other == "" then
			reply( "/plot team <player name>" )
			return
		end
		local target = resolveTarget( other )
		local otherPerma = target and Identity.Sv_PermaOf( target ) or Identity.Sv_FindByName( other )
		if type( otherPerma ) == "table" then otherPerma = otherPerma.perma end
		if otherPerma == nil then
			reply( string.format( "no player known as '%s'", other ) )
			return
		end
		local ok, detail = plots:sv_request( perma, otherPerma )
		reply( detail )
		if ok then
			self:sv_persist()
			if target and sm.exists( target ) then
				self.network:sendToClient( target, "client_showMessage",
					string.format( "%s wants to team plots with you. Type: /plot team %s",
						player.name, player.name ) )
			end
		end

	elseif action == "leave" then
		local ok, detail = plots:sv_unteam( perma )
		reply( detail )
		local released, detail2 = plots:sv_release( perma )
		reply( detail2 )
		if ok or released then self:sv_persist() end

	elseif action == "list" then
		local claimed, total = plots:sv_counts()
		reply( string.format( "%d of %d plots claimed", claimed, total ) )
		for i, owner in pairs( plots.owners ) do
			reply( "  " .. plots:sv_describe( i, function( p ) return Identity.Sv_NameOf( p ) end ) )
		end
	end
end
