dofile( "$GAME_DATA/Scripts/game/CreativeGame.lua" )
-- Layout first: it is pure geometry with no dependencies, and both PlotsGui
-- (client) and Plots (server) read it at load time.
dofile( "$CONTENT_DATA/Scripts/Layout.lua" )
dofile( "$CONTENT_DATA/Scripts/Settings.lua" )
dofile( "$CONTENT_DATA/Scripts/Identity.lua" )
dofile( "$CONTENT_DATA/Scripts/SettingsGui.lua" )
dofile( "$CONTENT_DATA/Scripts/PlotsGui.lua" )
dofile( "$CONTENT_DATA/Scripts/GuardedTools.lua" )
dofile( "$CONTENT_DATA/Scripts/MenuGui.lua" )
dofile( "$CONTENT_DATA/Scripts/Event.lua" )
dofile( "$CONTENT_DATA/Scripts/EventHud.lua" )
dofile( "$CONTENT_DATA/Scripts/MyPlotGui.lua" )
dofile( "$CONTENT_DATA/Scripts/PlotMarker.lua" )
-- IndexWidgets and friends. BasePlayer pulls this in too, but relying on load
-- order for a global is how you get a nil at the worst moment.
dofile( "$SURVIVAL_DATA/Scripts/util.lua" )

-- The Game script. Chat, identity, settings, players.
--
-- What is NOT here, and must never come back: anything that touches a body. A
-- Game script has no world, and sm.body.* is world-dependent. The first run of
-- this mod died on exactly that:
--
--   [C]: in function 'getAllBodies'
--   ERROR: Calling world dependent functions in a no world script!
--
-- All of it lives in World.lua now and is reached with sm.event.sendToWorld.
-- Game and World share one Lua global environment (this is how vanilla's
-- g_unitManager, created in CreativeGame, is reachable from CreativeBaseWorld),
-- so Settings and Identity are visible from both without any plumbing.

Game = class( CreativeGame )

-- Our own World subclass. Flat because a build event wants flat ground, and flat
-- terrain is cheaper to load and render than generated terrain.
Game.worldScriptFilename = "$CONTENT_DATA/Scripts/World.lua"
Game.worldScriptClass = "World"

local TICKS_PER_SECOND = 40
-- Every 2 ticks, not 10. A banned tool has to be dead on arrival, not usable
-- for a quarter of a second first -- long enough to fire a clay gun. The cost is
-- one getCurrentToolUuid per guest per 2 ticks, which is nothing.
local TOOL_CHECK_TICKS = 2

-- Commands that need a world. Forwarded rather than handled here.
local WORLD_COMMANDS = {
	["/lockdown"] = true, ["/unlock"] = true, ["/protection"] = true,
	["/buildtime"] = true, ["/snapshot"] = true, ["/snapshots"] = true,
	["/restore"] = true, ["/purge"] = true, ["/plot"] = true,
	["/plots"] = true, ["/plotgrid"] = true, ["/home"] = true,
	["/plotbuild"] = true, ["/plotclear"] = true, ["/why"] = true,
	["/plotapply"] = true,
}

-- Commands a guest may use. Everything else is host-only.
local PLAYER_COMMANDS = {
	["/sw"] = true, ["/swhelp"] = true, ["/plot"] = true, ["/players"] = true,
	["/rules"] = true, ["/home"] = true, ["/menu"] = true, ["/myplot"] = true,
	["/tool"] = true,
}

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
	local key = string.lower( tostring( token ) )
	for _, p in ipairs( sm.player.getAllPlayers() ) do
		if string.lower( p.name ) == key then return p, p.name end
	end
	return nil, Identity.Sv_NameOf( token ) or token
end


--[[ server ]]

function Game.server_onCreate( self )
	-- Settings and identity load BEFORE the base call, because the base call is
	-- what creates the world and World.server_onCreate reads settings the moment
	-- it runs. Values only: applying them needs a world, so the World does that.
	Settings.Sv_Load( false )
	Identity.Sv_Load()

	-- Must not be skipped. CreativeGame.server_onCreate creates g_unitManager,
	-- g_kinematicManager and g_beaconManager; a Custom Game that overrides this
	-- without calling up leaves them nil and then every collision throws with a
	-- full traceback. That is what produced a 1.79 GB log and 11 Hz.
	CreativeGame.server_onCreate( self )

	if g_unitManager == nil then
		sm.log.warning( "[ServerWorks] g_unitManager is nil after base create -- collisions will error" )
	end

	self.sv.kickQueue = {}
	self.sv.nextToolCheck = 0
	self.sv.nextBanReload = 0
	self.sv.blockedTools = Settings.Sv_BlockedTools()
	self.sv.hazardTools = Settings.Sv_HazardTools()
	self.sv.hostOnlyTools = Settings.Sv_HostOnlyTools()
	self.sv.pendingRestore = nil

	-- The event clock. Loaded from its own file rather than the Game script's
	-- storage, for the same reason Plots is: it has to be readable the instant
	-- the world asks, without depending on save ordering.
	g_swEvent = Event()
	g_swEvent:sv_onCreate( Event.Sv_LoadFile() )
	self.sv.nextEventPush = 0
	if g_swEvent:sv_running() then
		sm.log.info( string.format( "[ServerWorks] event resumed: %s, %s left",
			g_swEvent.phase, Event.Clock( g_swEvent:sv_remaining() ) ) )
	end
end

-- CreativeGame drops new players at 16,16, which with a centred city is somebody
-- else's plot. Spawn on the plaza instead. CreativeBaseWorld.sv_e_spawnNewCharacter
-- spherecasts straight down from z=1024 at the given x,y, so it lands on top of
-- whatever is there -- the plate, once it is built.
function Game.sv_createNewPlayer( self, world, x, y, player )
	sm.event.sendToWorld( self.sv.saved.world, "sv_e_spawnNewCharacter",
		{ player = player, x = 0, y = 0 } )
end

-- Two ready-made lists rather than making the client reason about who it is:
-- guests get everything switched off PLUS the host-only tools, the host gets
-- only the hazards.
function Game.sv_toolPayload( self )
	local guest = {}
	for k, v in pairs( self.sv.blockedTools or {} ) do guest[k] = v end
	for k, v in pairs( self.sv.hostOnlyTools or {} ) do guest[k] = v end
	return { guest = guest, host = self.sv.hazardTools or {} }
end

function Game.sv_world( self )
	return self.sv.saved and self.sv.saved.world or nil
end

function Game.sv_toWorld( self, cmd, args, player, extra )
	local world = self:sv_world()
	if world == nil or not sm.exists( world ) then
		self.network:sendToClient( player, "client_showMessage", "world not ready yet" )
		return
	end
	local payload = { cmd = cmd, args = args, player = player }
	if extra then
		for k, v in pairs( extra ) do payload[k] = v end
	end
	sm.event.sendToWorld( world, "sv_e_swCommand", payload )
end

-- Replies come back from the world as events: a world script has no network of
-- its own to talk to a client with.
function Game.sv_e_swReply( self, params )
	if params.player and sm.exists( params.player ) then
		self.network:sendToClient( params.player, "client_showMessage", params.text )
	end
end

-- The world knows where plots are; only the Game script has a network to reach
-- a client with. Same bridge sv_e_swReply uses.
function Game.sv_e_swMarker( self, params )
	if params.player == nil or not sm.exists( params.player ) then return end
	self.network:sendToClient( params.player, "client_setPlotMarker",
		{ position = params.position, ping = params.ping } )
end

-- /buildtime is an alias now, forwarded from the world because that is where the
-- command still lands.
function Game.sv_e_swBuildTime( self, params )
	if g_swEvent == nil then return end
	local minutes = tonumber( params.minutes ) or 0
	if minutes <= 0 then
		g_swEvent:sv_stop()
		Settings.Sv_SetQuiet( "buildopen", true )
		self:sv_applyEventPhase( "off" )
	else
		local _, phase = g_swEvent:sv_start( 0, minutes )
		self:sv_applyEventPhase( phase )
	end
	Event.Sv_SaveFile( g_swEvent )
	self:sv_pushEvent()
end

function Game.sv_e_swToolsChanged( self, params )
	self.sv.blockedTools = Settings.Sv_BlockedTools()
	self.sv.hazardTools = Settings.Sv_HazardTools()
	self.sv.hostOnlyTools = Settings.Sv_HostOnlyTools()
	self.network:sendToClients( "client_setBlockedTools", self:sv_toolPayload() )
end

function Game.sv_e_swBroadcast( self, params )
	self.network:sendToClients( "client_showMessage", params.text )
end

function Game.sv_broadcast( self, text )
	self.network:sendToClients( "client_showMessage", text )
end

function Game.server_onFixedUpdate( self, dt )
	CreativeGame.server_onFixedUpdate( self, dt )

	local tick = sm.game.getCurrentTick()
	self:sv_checkToolGuard( tick )
	self:sv_flushKicks()
	self:sv_tickEvent( tick )

	-- Re-read the ban file so a tool outside the game can push a ban mid-event.
	if tick >= self.sv.nextBanReload then
		self.sv.nextBanReload = tick + Identity.RELOAD_SECONDS * TICKS_PER_SECOND
		pcall( Identity.Sv_Reload )
		local host = sm.player.getHostPlayer()
		for _, player in ipairs( sm.player.getAllPlayers() ) do
			if player ~= host and Identity.Sv_IsBanned( player ) then
				table.insert( self.sv.kickQueue, player )
			end
		end
	end
end

-- Forbidden tools are pulled out of the player's hands as soon as they equip one.
-- The item is still listed in the creative menu -- nothing in Lua can edit that
-- list -- but it can never be held long enough to be used.
function Game.sv_checkToolGuard( self, tick )
	if tick < self.sv.nextToolCheck then return end
	self.sv.nextToolCheck = tick + TOOL_CHECK_TICKS

	if next( self.sv.blockedTools ) == nil
		and next( self.sv.hostOnlyTools or {} ) == nil
		and next( self.sv.hazardTools or {} ) == nil then
		return
	end

	local host = sm.player.getHostPlayer()
	local guests, hosts = {}, {}
	for _, p in ipairs( sm.player.getAllPlayers() ) do
		if p == host then hosts[#hosts + 1] = p else guests[#guests + 1] = p end
	end

	-- Only speak when something was actually taken. The old version messaged on
	-- every poll while the tool stayed in the player's hands, which is how a ban
	-- turned into a wall of chat instead of a removal.
	local drop = function( player, name )
		self.network:sendToClient( player, "client_dropTool", { name = name } )
	end
	local blocked = self.sv.blockedTools
	local guestBlocked = self:sv_toolPayload().guest
	Settings.Sv_CheckTools( guests, guestBlocked, drop )
	Settings.Sv_CheckTools( hosts, self.sv.hazardTools or {}, drop )
end

--[[ the event clock ]]

-- Runs on the server every tick. Three jobs: cross a phase boundary when the
-- deadline passes, make the "N minutes left" calls, and keep every client's HUD
-- fed. Only the first two do anything most ticks.
function Game.sv_tickEvent( self, tick )
	if g_swEvent == nil then return end

	local moved = g_swEvent:sv_advance()
	if moved then
		Event.Sv_SaveFile( g_swEvent )
		self:sv_applyEventPhase( moved )
		self:sv_pushEvent()
		return
	end

	local call = g_swEvent:sv_dueCall()
	if call then
		Event.Sv_SaveFile( g_swEvent )
		self:sv_broadcast( string.format( "%d minute%s of build time left.",
			call, call == 1 and "" or "s" ) )
	end

	-- One small message a second, which is all a clock that shows whole seconds
	-- can use. Clients interpolate between them; see Game.cl_eventRemaining.
	if tick >= self.sv.nextEventPush then
		self.sv.nextEventPush = tick + TICKS_PER_SECOND
		self:sv_pushEvent()
	end
end

function Game.sv_pushEvent( self, player )
	if g_swEvent == nil then return end
	local state = g_swEvent:sv_clientState()
	if player then
		self.network:sendToClient( player, "client_setEvent", state )
	else
		self.network:sendToClients( "client_setEvent", state )
	end
end

-- What each phase actually DOES. Building is a body-level thing, so the work
-- itself happens in the world; this decides and announces, and forwards.
--
-- The event owns `buildopen` while it is running. A host who wants manual
-- control back stops the event -- two things quietly fighting over one setting
-- is worse than one of them plainly winning.
function Game.sv_applyEventPhase( self, phase )
	local open = ( phase == "build" )
	Settings.Sv_SetQuiet( "buildopen", open )

	local world = self:sv_world()
	if world and sm.exists( world ) then
		sm.event.sendToWorld( world, "sv_e_swEventPhase", { phase = phase } )
	end

	if phase == "prep" then
		self:sv_broadcast( string.format(
			"PREP TIME -- %s. Claim a plot now; building opens when the clock runs out.",
			Event.Clock( g_swEvent:sv_remaining() ) ) )
	elseif phase == "build" then
		self:sv_broadcast( string.format( "BUILD TIME -- %s on the clock. Go.",
			Event.Clock( g_swEvent:sv_remaining() ) ) )
	elseif phase == "ended" then
		self:sv_broadcast( "TIME. Builds are locked and everything has been saved." )
	elseif phase == "off" then
		self:sv_broadcast( "The event clock has been stopped." )
	end
end

-- The host's controls for the clock. Everything here is one line of chat away
-- because a host mid-event has both hands full; the panel is the nicer surface
-- but this is the one that works while somebody is shouting at you.
function Game.sv_eventCommand( self, params, reply )
	if g_swEvent == nil then reply( "no event clock" ) return end
	local action = params[2] or "status"
	local a, b = tonumber( params[3] ), tonumber( params[4] )

	if action == "status" then
		reply( string.format( "event: %s", Event.LABELS[g_swEvent.phase] or g_swEvent.phase ) )
		local left = g_swEvent:sv_remaining()
		if left then
			reply( string.format( "  %s left%s", Event.Clock( left ),
				g_swEvent:sv_paused() and "  (PAUSED)" or "" ) )
		end
		reply( string.format( "  configured: %g min prep, %g min build",
			g_swEvent.prepMinutes, g_swEvent.buildMinutes ) )
		reply( "  /event start <prep> <build>   both in minutes, any number you like" )
		return
	end

	if action == "start" then
		local prep = a or g_swEvent.prepMinutes
		local build = b or g_swEvent.buildMinutes
		local _, phase = g_swEvent:sv_start( prep, build )
		Event.Sv_SaveFile( g_swEvent )
		self:sv_applyEventPhase( phase )
		self:sv_pushEvent()
		reply( string.format( "event started: %g min prep, then %g min build",
			prep, build ) )

	elseif action == "stop" then
		g_swEvent:sv_stop()
		Event.Sv_SaveFile( g_swEvent )
		-- Stopping hands `buildopen` back to the host rather than leaving it
		-- wherever the clock happened to put it. Two things quietly fighting
		-- over one setting is worse than one of them plainly winning.
		Settings.Sv_SetQuiet( "buildopen", true )
		self:sv_applyEventPhase( "off" )
		self:sv_pushEvent()
		reply( "event stopped -- building is open and yours to control again" )

	elseif action == "pause" or action == "resume" then
		local ok, detail = ( action == "pause" )
			and g_swEvent:sv_pause() or g_swEvent:sv_resume()
		Event.Sv_SaveFile( g_swEvent )
		self:sv_pushEvent()
		reply( detail )
		if ok then
			self:sv_broadcast( action == "pause"
				and "The clock is PAUSED." or "The clock is running again." )
		end

	elseif action == "skip" then
		local ok, phase = g_swEvent:sv_skip()
		if not ok then reply( phase ) return end
		Event.Sv_SaveFile( g_swEvent )
		self:sv_applyEventPhase( phase )
		self:sv_pushEvent()
		reply( "skipped to " .. phase )

	elseif action == "add" then
		local ok, detail = g_swEvent:sv_addMinutes( a or 0 )
		Event.Sv_SaveFile( g_swEvent )
		self:sv_pushEvent()
		reply( detail )
		if ok then self:sv_broadcast( "The host changed the clock: " .. detail ) end

	else
		reply( "start | stop | pause | resume | skip | add <min> | status" )
	end
end

function Game.sv_flushKicks( self )
	if #self.sv.kickQueue == 0 then return end
	local pending = self.sv.kickQueue
	self.sv.kickQueue = {}
	for _, player in ipairs( pending ) do
		if sm.exists( player ) then
			sm.log.info( "[ServerWorks] kicking " .. tostring( player.name ) )
			sm.game.kickPlayer( player )
		end
	end
end

function Game.server_onPlayerJoined( self, player, newPlayer )
	CreativeGame.server_onPlayerJoined( self, player, newPlayer )

	local rec = Identity.Sv_Touch( player )
	local host = sm.player.getHostPlayer()

	-- Allow list first: it is the stronger check. A ban names the person who must
	-- stay out and loses to a rename; an allow list names everyone who may come
	-- in, and a rename just produces another name that is not on it.
	if Settings.Get( "allowlist" ) and player ~= host and not Identity.Sv_IsAllowed( player ) then
		sm.log.info( "[ServerWorks] not on allow list: " .. tostring( player.name ) )
		table.insert( self.sv.kickQueue, player )
		return
	end

	if Identity.Sv_IsBanned( player ) then
		-- Not kicked inline: the player is still being constructed here and the
		-- base class has spawn work queued behind us. One tick later is safe.
		table.insert( self.sv.kickQueue, player )
		return
	end

	self.network:sendToClient( player, "client_setBlockedTools", self:sv_toolPayload() )
	self.network:sendToClient( player, "client_welcome", {
		perma = rec.perma,
		plots = Settings.Get( "plots" ) == true,
		event = g_swEvent and g_swEvent.phase or "off",
	} )
	self:sv_pushEvent( player )

	-- If they already own a plot from a previous session, put it back on their
	-- compass straight away. Coming back to an event and having to remember
	-- which square was yours is exactly the friction this removes.
	--
	-- Sent quietly: sv_toWorld tells the player "world not ready yet" when it
	-- cannot deliver, and a join is the one moment where that is both possible
	-- and completely meaningless to them.
	local world = self:sv_world()
	if world and sm.exists( world ) then
		sm.event.sendToWorld( world, "sv_e_swCommand",
			{ cmd = "/marker", args = {}, player = player } )
	end
end


--[[ client ]]

function Game.client_welcome( self, data )
	local lines = {
		"------------------------------------------",
		"  Welcome. This server runs SERVER WORKS.",
		string.format( "  Your permanent id is %s.", tostring( data.perma ) ),
		"",
	}
	if data.plots then
		lines[#lines + 1] = "  This is a PLOT event:"
		lines[#lines + 1] = "   1. Stand on an empty plot and type  /plot claim"
		lines[#lines + 1] = "   2. You can only build on your own plot."
		lines[#lines + 1] = "   3. Walk onto someone else's plot and you get pushed off."
		lines[#lines + 1] = "   4. To build with a neighbour, both type  /plot team <them>"
		lines[#lines + 1] = "      Only front, behind, left or right -- never corner to corner."
		lines[#lines + 1] = "      Teams chain: team your neighbour, they team theirs, all three share."
		lines[#lines + 1] = "      Then the gap between your plots becomes shared ground."
	else
		lines[#lines + 1] = "  Free build. The host may lock builds at any time."
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = "  /sw for commands, /rules for the server rules."
	lines[#lines + 1] = "------------------------------------------"

	for _, line in ipairs( lines ) do
		sm.gui.chatMessage( line )
	end
end

function Game.client_showMessage( self, text )
	sm.gui.chatMessage( text )
end

-- The plot marker. The server says where it is; only this client is ever told,
-- so nobody else's compass shows it -- which is the behaviour the owner wanted
-- and, on the compass HUD, the only behaviour available.
function Game.client_setPlotMarker( self, data )
	if self.cl == nil then self.cl = {} end
	if data == nil or data.position == nil then
		self.cl.plotMarker = nil
		PlotMarker.Cl_Hide()
		return
	end
	self.cl.plotMarker = data.position
	PlotMarker.Cl_Show( data.position )
	if data.ping then
		PlotMarker.Cl_Ping()
	end
end

-- The blocked list is pushed to clients so the check can happen where the tool
-- actually is. The server poll stays as a backstop, but a server round trip is
-- too slow to stop a tool that only needs one click -- which is why the clay gun
-- was still getting a shot off.
function Game.client_setBlockedTools( self, data )
	if self.cl == nil then self.cl = {} end
	self.cl.toolsGuest = ( data and data.guest ) or {}
	self.cl.toolsHost = ( data and data.host ) or {}

	-- GuardedTools reads this by NAME, because a tool script has no idea which
	-- uuid it was instantiated from.
	g_swBlockedNames = {}
	for _, name in pairs( sm.isHost and self.cl.toolsHost or self.cl.toolsGuest ) do
		g_swBlockedNames[name] = true
	end
end

--[[ the event clock, on the client ]]

-- The server sends the remaining time about once a second. That is plenty for a
-- MM:SS readout and visibly jerky on the warehouse timer, which draws tenths and
-- hundredths -- so remember which tick the update landed on and subtract elapsed
-- ticks since. The display is interpolated; the truth is still the server's.
function Game.client_setEvent( self, state )
	if self.cl == nil then self.cl = {} end
	self.cl.event = state
	self.cl.eventAtTick = sm.game.getCurrentTick()
	self.cl.eventDirty = true
end

function Game.cl_eventRemaining( self )
	local e = self.cl and self.cl.event
	if e == nil or e.remaining == nil then return nil end
	if e.paused then return e.remaining end
	local elapsed = ( sm.game.getCurrentTick() - ( self.cl.eventAtTick or 0 ) ) / 40
	return math.max( 0, e.remaining - elapsed )
end

function Game.cl_updateEventHud( self )
	local e = self.cl.event
	if e == nil then return end

	-- The corner clock. Rendered once a second rather than every frame: it shows
	-- whole seconds, so 39 of every 40 renders would draw the same thing.
	local tick = sm.game.getCurrentTick()
	local left = self:cl_eventRemaining()
	local whole = left and math.floor( left ) or -1
	if self.cl.eventDirty or whole ~= self.cl.eventShownSecond then
		self.cl.eventShownSecond = whole
		self.cl.eventDirty = false
		if self.cl.eventHud == nil or not sm.exists( self.cl.eventHud ) then
			-- Same four flags NotificationManager uses for its own timer.
			local ok, gui = pcall( sm.jsonGui.createGui, { layer = "Wallpaper",
				isInteractive = false, needsCursor = false, isHud = true } )
			if not ok then
				if not self.cl.eventHudFaulted then
					self.cl.eventHudFaulted = true
					sm.log.warning( "[ServerWorks] event HUD unavailable: " .. tostring( gui ) )
				end
				return
			end
			self.cl.eventHud = gui
		end
		local shown = { phase = e.phase, remaining = left,
			paused = e.paused, panic = e.panic }
		pcall( function() self.cl.eventHud:render( EventHud.Build( shown ) ) end )
	end

	--[[ the warehouse timer ]]
	--
	-- Handed over to the engine's own, which brings the red destruction warning,
	-- the explosion icon and three escalating alarms with it. Its native span is
	-- five minutes (WAREHOUSE_DESTRUCTION_TICKS = 40 * 60 * 5), which is why the
	-- handover happens at five and not at some rounder-sounding number.
	local wantPanic = e.panic == true and left ~= nil and left > 0
	if wantPanic and self.cl.panicTimer == nil and not self.cl.panicFaulted then
		local ok, timer = pcall( NotificationManager.Cl_CreateEventTimer, 100, "explosion" )
		if ok and timer then
			self.cl.panicTimer = timer
		else
			-- Once. Never per frame.
			self.cl.panicFaulted = true
			sm.log.warning( "[ServerWorks] warehouse timer unavailable: " .. tostring( timer ) )
		end
	end
	if self.cl.panicTimer then
		if wantPanic then
			pcall( function() self.cl.panicTimer:update( true, left ) end )
		else
			pcall( function() self.cl.panicTimer:destroy() end )
			self.cl.panicTimer = nil
		end
	end
end

function Game.client_onFixedUpdate( self, dt )
	CreativeGame.client_onFixedUpdate( self, dt )

	if self.cl and self.cl.event then
		self:cl_updateEventHud()
	end

	-- The host still gets every BUILD tool, but not the hazards. The bypass was
	-- so whoever runs the event can place and clear things; it was never meant to
	-- hand them a clay gun.
	if self.cl == nil then return end
	local blocked = sm.isHost and self.cl.toolsHost or self.cl.toolsGuest
	if blocked == nil or next( blocked ) == nil then return end

	local ok, uuid = pcall( function()
		return sm.localPlayer.getPlayer():getCurrentToolUuid()
	end )
	if not ok or uuid == nil then return end

	local name = blocked[tostring( uuid )]
	if name == nil then
		self.cl.lastBlockedWarn = nil
		return
	end

	pcall( sm.tool.forceTool, nil )

	-- One message per pickup, not one per tick. The server strips the item on its
	-- own poll; this just makes the hand empty immediately.
	if self.cl.lastBlockedWarn ~= name then
		self.cl.lastBlockedWarn = name
		sm.gui.chatMessage( ( name == "lift" )
			and "The lift is host only on this server."
			or string.format( "The %s is disabled on this server.", name ) )
	end
end

function Game.client_dropTool( self, data )
	local name = type( data ) == "table" and data.name or data

	-- forceTool is client-side only: the server can see what you hold, but only
	-- your own client can put it away. The server has already taken the item out
	-- of the inventory; this is what clears it from the hand this instant.
	pcall( sm.tool.forceTool, nil )

	if self.cl == nil then self.cl = {} end
	if self.cl.lastDropWarn == name then
		return                      -- do not narrate the same ban over and over
	end
	self.cl.lastDropWarn = name

	sm.gui.chatMessage( ( name == "lift" )
		and "The lift is host only on this server."
		or string.format( "The %s is disabled on this server.", tostring( name ) ) )
end

function Game.client_onCreate( self )
	CreativeGame.client_onCreate( self )

	-- NOT "/help". The engine reserves it -- measured, first run:
	--   ERROR: Command name '/help' is reserved
	-- NOT "/help". The engine reserves that name and bindChatCommand refuses it --
	-- measured, first run: "Command name '/help' is reserved". /swhelp is the
	-- mod's own help, kept separate from the game's so neither shadows the other.
	sm.game.bindChatCommand( "/sw", {}, "cl_onAdminCommand",
		"Server Works: how this server works and what you can type" )
	sm.game.bindChatCommand( "/swhelp", {}, "cl_onAdminCommand",
		"Server Works help -- same as /sw" )
	sm.game.bindChatCommand( "/rules", {}, "cl_onAdminCommand",
		"The server rules and the numbers currently in force" )
	sm.game.bindChatCommand( "/home", {}, "cl_onAdminCommand",
		"Teleport back to your own plot" )
	sm.game.bindChatCommand( "/plot",
		{ { "string", "action", false, { "claim", "info", "team", "leave", "list" } },
		  { "string", "who", true } },
		"cl_onAdminCommand", "claim | info | team <player> (front, behind, left or right) | leave | list" )
	sm.game.bindChatCommand( "/players", {}, "cl_onAdminCommand",
		"Who is here, with session id and permanent id" )
	-- Everything a builder does with their own ground, on one panel. NOT host
	-- gated: this is the command the twenty people at the event actually use.
	sm.game.bindChatCommand( "/myplot", {}, "cl_onAdminCommand",
		"Your plot: claim ground, find it again, see your team" )
	-- Says exactly which item is in your hand. There are two lifts and they look
	-- identical in the menu; this is the only way to tell them apart from inside
	-- the game, and three builds were spent guessing which one was being held.
	sm.game.bindChatCommand( "/tool", {}, "cl_onAdminCommand",
		"What am I holding? Prints the uuid of the tool in your hand" )
	sm.game.bindChatCommand( "/event",
		{ { "string", "action", true,
		    { "start", "stop", "pause", "resume", "skip", "add", "status" } },
		  { "number", "a", true }, { "number", "b", true } },
		"cl_onAdminCommand",
		"Host: start <prep> <build> | stop | pause | resume | skip | add <min> | status" )

	sm.game.bindChatCommand( "/preset",
		{ { "string", "name", true, { "build", "show", "lockdown", "sandbox" } } },
		"cl_onAdminCommand", "Host: apply a whole set of settings at once" )
	sm.game.bindChatCommand( "/settings", {}, "cl_onAdminCommand",
		"Host: open the settings panel" )
	sm.game.bindChatCommand( "/settingslist", {}, "cl_onAdminCommand",
		"Host: print settings to chat instead of opening the panel" )
	sm.game.bindChatCommand( "/set",
		{ { "string", "setting", false }, { "string", "value", false } },
		"cl_onAdminCommand", "Host: change a setting, e.g. /set fire off" )
	sm.game.bindChatCommand( "/plots", { { "string", "onoff", true, { "on", "off" } } },
		"cl_onAdminCommand", "Host: shortcut for /set plots on|off" )
	sm.game.bindChatCommand( "/menu", {}, "cl_onAdminCommand",
		"Open the Server Works menu" )
	sm.game.bindChatCommand( "/plotmenu", {}, "cl_onAdminCommand",
		"Host: lay out the city, see what the numbers mean, then build it" )
	sm.game.bindChatCommand( "/why", {}, "cl_onAdminCommand",
		"Host: point at a build and ask why it is locked" )
	sm.game.bindChatCommand( "/plotbuild", {}, "cl_onAdminCommand",
		"Host: build the visible city floor -- concrete plots, metal 2 lines" )
	sm.game.bindChatCommand( "/plotclear", {}, "cl_onAdminCommand",
		"Host: remove the city floor" )
	sm.game.bindChatCommand( "/plotgrid",
		{ { "number", "plotBlocks", false }, { "number", "gapBlocks", false },
		  { "number", "cols", false }, { "number", "rows", false } },
		"cl_onAdminCommand", "Host: reshape the city grid (wipes claims)" )

	sm.game.bindChatCommand( "/lockdown", { { "string", "mode", true, { "strict", "display" } } },
		"cl_onAdminCommand", "Host: lock every build. strict also blocks seats and controllers" )
	sm.game.bindChatCommand( "/unlock", {}, "cl_onAdminCommand", "Host: reopen building" )
	sm.game.bindChatCommand( "/protection", {}, "cl_onAdminCommand",
		"Host: protection state, shape count, running jobs" )
	sm.game.bindChatCommand( "/buildtime", { { "number", "minutes", false } }, "cl_onAdminCommand",
		"Host: lock builds in N minutes and snapshot then. 0 cancels" )
	sm.game.bindChatCommand( "/autosave", { { "number", "minutes", false } }, "cl_onAdminCommand",
		"Host: snapshot every N minutes. 0 turns it off" )

	sm.game.bindChatCommand( "/snapshot", { { "string", "name", true } }, "cl_onAdminCommand",
		"Host: save every build so it can be restored" )
	sm.game.bindChatCommand( "/snapshots", {}, "cl_onAdminCommand", "Host: list snapshots" )
	sm.game.bindChatCommand( "/restore",
		{ { "string", "name", false }, { "number", "plot", true } }, "cl_onAdminCommand",
		"Host: rebuild from a snapshot. Add a plot number to repair one plot. Run twice to confirm" )
	sm.game.bindChatCommand( "/purge",
		{ { "string", "what", false, { "look", "carry", "here", "plot", "walkways" } },
		  { "number", "n", true } },
		"cl_onAdminCommand",
		"Host: delete junk. look | carry | here <m> | plot <n> | walkways" )

	sm.game.bindChatCommand( "/known", {}, "cl_onAdminCommand", "Host: everyone who has ever joined" )
	sm.game.bindChatCommand( "/ban", nameParams(), "cl_onAdminCommand",
		"Host: permanently ban by name, session id or perma id" )
	sm.game.bindChatCommand( "/unban", nameParams(), "cl_onAdminCommand", "Host: lift a ban" )
	sm.game.bindChatCommand( "/banlist", {}, "cl_onAdminCommand", "Host: show the ban list" )
	sm.game.bindChatCommand( "/kick", nameParams(), "cl_onAdminCommand",
		"Host: kick for this session only" )
	sm.game.bindChatCommand( "/allow", nameParams(), "cl_onAdminCommand",
		"Host: let someone in when allowlist is on. Works before they ever join" )
	sm.game.bindChatCommand( "/unallow", nameParams(), "cl_onAdminCommand",
		"Host: take someone off the allow list" )
	sm.game.bindChatCommand( "/allowlist", {}, "cl_onAdminCommand", "Host: show who is allowed in" )
end

function Game.cl_onAdminCommand( self, params )
	self.network:sendToServer( "sv_n_adminCommand", params )
end


--[[ settings panel ]]

-- The panel is client side, but settings live on the server, so the values are
-- shipped over rather than read locally. Every click round-trips: the client
-- asks, the server decides and saves, the server sends the new values back and
-- the panel re-renders. That keeps a guest's client from ever being the
-- authority on what the server allows.
function Game.sv_openSettingsGui( self, player, group, page )
	local values = {}
	for _, row in ipairs( Settings.SCHEMA ) do
		values[row.key] = Settings.Get( row.key )
	end
	self.network:sendToClient( player, "client_openSettingsGui",
		{ values = values, group = group, page = page } )
end

function Game.sv_n_settingsGuiClick( self, data, player )
	if player ~= sm.player.getHostPlayer() then
		return
	end

	if data.action == "preset" then
		local ok, detail = Settings.Sv_ApplyPreset( data.preset )
		if ok then
			self.sv.blockedTools = Settings.Sv_BlockedTools()
			self.sv.hazardTools = Settings.Sv_HazardTools()
			self.sv.hostOnlyTools = Settings.Sv_HostOnlyTools()
			self.network:sendToClients( "client_setBlockedTools", self:sv_toolPayload() )
			self:sv_toWorld( "/settingschanged", {}, player )
			self:sv_broadcast( "Server preset: " .. detail )
		else
			self.network:sendToClient( player, "client_showMessage", detail )
		end

	elseif data.action == "cycle" then
		local row
		for _, r in ipairs( Settings.SCHEMA ) do
			if r.key == data.key then row = r end
		end
		if row then
			local current = Settings.Get( row.key )
			local nextValue = SettingsGui.NextValue( row, current )
			if nextValue ~= current then
				local raw = ( row.kind == "bool" ) and ( nextValue and "on" or "off" )
					or tostring( nextValue )
				local ok, detail = Settings.Sv_Set( row.key, raw )
				if ok then
					self.sv.blockedTools = Settings.Sv_BlockedTools()
					self:sv_toWorld( "/settingschanged", {}, player )
					self:sv_broadcast( "Server setting changed: " .. detail )
				end
			end
		end
	end

	self:sv_openSettingsGui( player, data.group, data.page or 1 )
end

function Game.client_openSettingsGui( self, data )
	if self.cl == nil then self.cl = {} end
	self.cl.settingsValues = data.values
	self.cl.settingsGroup = data.group or "safety"
	self.cl.settingsPage = data.page or 1

	-- Reuse the GUI and just render the new tree into it. Closing and recreating
	-- on every click threw the panel away and built another, which is wasteful
	-- and makes the whole thing flicker. Re-rendering is what vanilla does
	-- (HideoutTrader rebuilds its item list this way).

	local root = SettingsGui.Build( data.values, self.cl.settingsGroup, self.cl.settingsPage )
	if self.cl.settingsGui == nil or not sm.exists( self.cl.settingsGui ) then
		self.cl.settingsGui = sm.jsonGui.createGui( { isInteractive = true, needsCursor = true } )
	end
	-- render() IS the show. A json GUI has neither open() nor destroy() --
	-- MEASURED: "Unknown member 'open' in userdata" at Game.lua:473, thrown on
	-- every render, and the throw is what shut the panel again on every click.
	-- Vanilla only ever calls createGui / render / close
	-- (CreativePlayer.cl_e_unstuck).
	self.cl.settingsGui:render( root )
end

-- ( self, widgetName, data ) -- NOT ( self, data ). Confirmed against
-- Survival/.../HideoutTrader.lua:1536 `cl_selectTrade( self, widgetName, data )`.
-- Getting this wrong handed every click the widget's NAME as a string, so
-- data.action was always nil and no branch ever matched.
function Game.cl_onSettingsGuiClick( self, widgetName, data )
	if type( data ) ~= "table" then return end
	if data.action == "close" then
		self:cl_closeSettingsGui()
		return
	end

	-- Switching tab or page is pure presentation, so it re-renders locally
	-- instead of round-tripping to the server. Only a value change needs the
	-- server, because only the server decides what the settings are.
	if data.action == "group" then
		self.cl.settingsGroup = data.group
		self.cl.settingsPage = 1
		self.cl.settingsGui:render( SettingsGui.Build(
			self.cl.settingsValues, self.cl.settingsGroup, 1 ) )
		return
	end

	if data.action == "page" then
		local pages = SettingsGui.PageCount( self.cl.settingsGroup )
		local page = data.page
		if page < 1 then page = pages elseif page > pages then page = 1 end
		self.cl.settingsPage = page
		self.cl.settingsGui:render( SettingsGui.Build(
			self.cl.settingsValues, self.cl.settingsGroup, page ) )
		return
	end

	-- A value change has to go to the server; the client does not decide.
	self.network:sendToServer( "sv_n_settingsGuiClick", {
		action = data.action, key = data.key, preset = data.preset,
		group = self.cl.settingsGroup, page = self.cl.settingsPage,
	} )
end

function Game.cl_onSettingsGuiClose( self, widgetName )
	self:cl_closeSettingsGui()
end

function Game.cl_closeSettingsGui( self )
	if self.cl == nil then return end
	local gui = self.cl.settingsGui
	-- Cleared BEFORE closing: close() fires onClose, which calls back into here,
	-- and without this the second pass would close an already-closing GUI.
	self.cl.settingsGui = nil
	if gui and sm.exists( gui ) then
		pcall( function() gui:close() end )
	end
end


--[[ hub menu ]]

-- One place to reach everything, because remembering eight slash commands is not
-- a user interface. A guest is only shown what a guest may open, so nobody is
-- offered a button that answers "Host only."
function Game.sv_openMenu( self, player )
	self.network:sendToClient( player, "client_openMenu",
		{ host = ( player == sm.player.getHostPlayer() ) } )
end

function Game.client_openMenu( self, data )
	if self.cl == nil then self.cl = {} end
	if self.cl.menuGui == nil or not sm.exists( self.cl.menuGui ) then
		self.cl.menuGui = sm.jsonGui.createGui( { isInteractive = true, needsCursor = true } )
	end
	self.cl.menuGui:render( MenuGui.Build( data.host ) )
end

function Game.cl_onMenuClick( self, widgetName, data )
	if type( data ) ~= "table" then return end
	self:cl_closeMenu()
	if data.action == "close" then return end
	self.network:sendToServer( "sv_n_menuOpen", { what = data.action } )
end

function Game.cl_onMenuClose( self, widgetName )
	self:cl_closeMenu()
end

function Game.cl_closeMenu( self )
	if self.cl == nil then return end
	local gui = self.cl.menuGui
	self.cl.menuGui = nil
	if gui and sm.exists( gui ) then pcall( function() gui:close() end ) end
end

function Game.sv_n_menuOpen( self, data, player )
	local isHost = ( player == sm.player.getHostPlayer() )
	local what = data.what
	if what == "settings" and isHost then
		self:sv_openSettingsGui( player, "safety", 1 )
	elseif what == "city" and isHost then
		self:sv_openPlotsGui( player )
	elseif what == "myplot" then
		self:sv_toWorld( "/myplot", {}, player )
	elseif what == "rules" then
		self:sv_n_adminCommand( { "/rules" }, player )
	elseif what == "help" then
		self:sv_n_adminCommand( { "/sw" }, player )
	elseif what == "players" then
		self:sv_n_adminCommand( { "/players" }, player )
	elseif what == "plot" then
		self:sv_toWorld( "/myplot", {}, player )
	end
end


--[[ city layout panel ]]

function Game.sv_openPlotsGui( self, player )
	-- Read the live grid back out of the world; the Game script does not own it.
	local cfg
	if g_swPlots then
		local claimed = {}
		for index, owner in pairs( g_swPlots.owners ) do
			claimed[tostring( index )] = Identity.Sv_NameOf( owner ) or owner
		end
		local g = g_swPlots.grid
		cfg = {
			plot = g.plot, gap = g.gap, cols = g.cols, rows = g.rows,
			roadevery = g.roadevery, roadwidth = g.roadwidth, spawn = g.spawn,
			claimed = claimed,
			-- so the map can paint the viewer's own plot green rather than just
			-- "somebody's": "so that I cant alter plots that arent mine" starts
			-- with being able to see which one is yours.
			mine = g_swPlots:sv_plotOf( Identity.Sv_PermaOf( player ) ),
		}
		-- The team as well, so the map can show at a glance which ground you may
		-- build on. A team is a connected run of plots, not a pair, so it is not
		-- something a player can work out by looking at the grid.
		if cfg.mine then
			cfg.team = {}
			for index in pairs( g_swPlots:sv_teamOf( cfg.mine ) ) do
				if index ~= cfg.mine then
					cfg.team[tostring( index )] = true
				end
			end
		end
	else
		cfg = Layout.config( {} )
		cfg.claimed = {}
	end
	self.network:sendToClient( player, "client_openPlotsGui", cfg )
end

function Game.client_openPlotsGui( self, cfg )
	if self.cl == nil then self.cl = {} end
	self.cl.plotCfg = cfg
	if self.cl.plotsGui == nil or not sm.exists( self.cl.plotsGui ) then
		self.cl.plotsGui = sm.jsonGui.createGui( { isInteractive = true, needsCursor = true } )
	end
	self.cl.plotsGui:render( PlotsGui.Build( cfg ) )
end

--[[ my plot panel ]]

-- Built on the server because only the world knows what square the player is
-- standing on, and re-sent rather than patched: the whole state is four fields
-- and a grid, and a panel that redraws from one source cannot get out of step
-- with the world the way an incrementally-updated one can.
function Game.client_openMyPlotGui( self, state )
	if self.cl == nil then self.cl = {} end
	self.cl.myPlotState = state
	if self.cl.myPlotGui == nil or not sm.exists( self.cl.myPlotGui ) then
		self.cl.myPlotGui = sm.jsonGui.createGui( { isInteractive = true, needsCursor = true } )
	end
	self.cl.myPlotGui:render( MyPlotGui.Build( state ) )
end

function Game.cl_closeMyPlotGui( self )
	-- A json GUI has no destroy() and no open(); render() IS the show and close()
	-- is the hide. Measured twice, as "Unknown member 'destroy' in userdata" and
	-- then again as "Unknown member 'open'".
	if self.cl and self.cl.myPlotGui and sm.exists( self.cl.myPlotGui ) then
		self.cl.myPlotGui:close()
	end
end

function Game.cl_onMyPlotClose( self )
	self:cl_closeMyPlotGui()
end

function Game.cl_onMyPlotClick( self, widgetName, data )
	if type( data ) ~= "table" then return end
	if data.action == "close" then
		self:cl_closeMyPlotGui()
		return
	end
	self.network:sendToServer( "sv_n_myPlotAction", { action = data.action } )
	self:cl_closeMyPlotGui()
end

function Game.sv_n_myPlotAction( self, data, player )
	if type( data ) ~= "table" then return end
	local map = { claim = "claim", leave = "leave" }
	if data.action == "find" then
		self:sv_toWorld( "/home", {}, player )
	elseif map[data.action] then
		self:sv_toWorld( "/plot", { "/plot", map[data.action] }, player )
	end
end

-- The world assembles the state and hands it back through here, because a world
-- script has no network of its own.
function Game.sv_e_swMyPlot( self, params )
	if params.player == nil or not sm.exists( params.player ) then return end
	self.network:sendToClient( params.player, "client_openMyPlotGui", params.state )
end

function Game.cl_onPlotsGuiClick( self, widgetName, data )
	if type( data ) ~= "table" or self.cl == nil then return end
	local cfg = self.cl.plotCfg
	if cfg == nil then return end

	if data.action == "step" then
		cfg[data.key] = PlotsGui.Step( data.key, cfg[data.key], data.dir )
		self.cl.plotsGui:render( PlotsGui.Build( cfg ) )       -- local, instant
		return
	end
	if data.action == "reset" then
		self.cl.plotCfg = { plot = 20, gap = 1, cols = 10, rows = 10,
			roadevery = 0, roadwidth = 6, spawn = 50,
			claimed = self.cl.plotCfg and self.cl.plotCfg.claimed or {} }
		self.cl.plotsGui:render( PlotsGui.Build( self.cl.plotCfg ) )
		return
	end
	if data.action == "close" then
		self:cl_closePlotsGui()
		return
	end
	-- build and clear are the server's business
	self.network:sendToServer( "sv_n_plotsGuiAction", { action = data.action, cfg = cfg } )
	self:cl_closePlotsGui()
end

function Game.cl_onPlotsGuiClose( self, widgetName )
	self:cl_closePlotsGui()
end

function Game.cl_closePlotsGui( self )
	if self.cl == nil then return end
	local gui = self.cl.plotsGui
	self.cl.plotsGui = nil
	if gui and sm.exists( gui ) then
		pcall( function() gui:close() end )
	end
end

function Game.sv_n_plotsGuiAction( self, data, player )
	if player ~= sm.player.getHostPlayer() then return end
	if data.action == "clear" then
		self:sv_toWorld( "/plotclear", {}, player )
	elseif data.action == "build" then
		self:sv_toWorld( "/plotapply", {}, player, { cfg = data.cfg } )
	end
end


--[[ command dispatch ]]

function Game.sv_n_adminCommand( self, params, player )
	local function reply( text )
		self.network:sendToClient( player, "client_showMessage", text )
	end

	local cmd = params[1]
	local isHost = ( player == sm.player.getHostPlayer() )

	if not isHost and not PLAYER_COMMANDS[cmd] then
		reply( "Host only." )
		return
	end

	-- Anything that touches a body goes to the world.
	if WORLD_COMMANDS[cmd] then
		if cmd == "/restore" then
			local name, plot = params[2], tonumber( params[3] )
			local token = tostring( name ) .. "/" .. tostring( plot )
			-- Two-step on purpose. This deletes before it rebuilds; a fat-fingered
			-- /restore mid-event would do more damage than the griefer did.
			if self.sv.pendingRestore ~= token then
				self.sv.pendingRestore = token
				reply( plot
					and string.format( "/restore %s %d will DELETE everything on plot %d and rebuild it.",
						tostring( name ), plot, plot )
					or string.format( "/restore %s will DELETE THE WHOLE WORLD and rebuild from it.",
						tostring( name ) ) )
				reply( "Run the same command again to confirm." )
				return
			end
			self.sv.pendingRestore = nil
			self:sv_toWorld( cmd, params, player, { plot = plot } )
			return
		end
		self:sv_toWorld( cmd, params, player )
		return
	end

	if cmd == "/sw" or cmd == "/swhelp" then
		reply( "SERVER WORKS" )
		reply( "  /plot claim         claim the plot you are stood on" )
		reply( "  /plot info          who owns this ground" )
		reply( "  /myplot             claim, find and give up your plot, on one panel" )
		reply( "  /plot team <name>   ask a neighbour to team up (they type it back)" )
		reply( "                      front, behind, left or right only -- not diagonal." )
		reply( "                      Teams chain, so a corner joins via whoever links you." )
		reply( "  /plot leave         give up your plot" )
		reply( "  /home               teleport back to your own plot" )
		reply( "  /players            who is here     /rules  the server rules" )
		if isHost then
			reply( "HOST" )
			reply( "  /preset build|show|lockdown|sandbox" )
			reply( "  /settings           open the settings panel" )
			reply( "  /settingslist  /set <name> <value>" )
			reply( "  /plotmenu           lay the city out, then build it" )
			reply( "  /plots on|off  /plotbuild  /plotclear" )
			reply( "  /plotgrid <plot> <gap> <cols> <rows>" )
			reply( "  /event start <prep> <build>   minutes. Prep = claim only, no building" )
			reply( "  /event pause|resume|skip|add <min>|stop|status" )
			reply( "  /lockdown [display]  /unlock  /protection  /buildtime N  /autosave N" )
			reply( "  /snapshot [name]  /snapshots  /restore <name> [plot]" )
			reply( "  /purge look         delete whatever you are pointing at" )
			reply( "  /purge look 1       delete the whole creation, not one block" )
			reply( "  /purge carry        destroy whatever you picked up" )
			reply( "  /purge here <m> | /purge plot <n> | /purge walkways" )
			reply( "  /why                point at a build, ask why it is locked" )
			reply( "  /ban <who>  /unban <who>  /banlist  /known  /kick <who>" )
			reply( "  /allow <who>  /unallow <who>  /allowlist" )
		end

	elseif cmd == "/rules" then
		-- Read from live settings, so the board can never drift from what the
		-- server actually enforces.
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
		reply( "     Only with the plot in front, behind, left or right of you." )
		reply( "  9. No griefing or trolling. Bans are permanent." )
		reply( "  10. Max " .. num( "maxjoints" ) .. " combined bearings/pistons/suspensions per plot" )
		reply( "  11. Fireworks " .. onoff( "fireworks" ) .. ", plasma drills " .. onoff( "plasmadrills" ) )
		reply( "  12. Beacons " .. onoff( "beacons" ) )
		reply( "Go over a limit and your plot locks until you trim it. Nothing is taken away." )

	elseif cmd == "/preset" then
		local name = params[2]
		if name == nil or name == "" then
			reply( "presets -- /preset <name>" )
			for _, line in ipairs( Settings.Sv_PresetLines() ) do reply( line ) end
			return
		end
		local ok, detail = Settings.Sv_ApplyPreset( name )
		reply( detail )
		if ok then
			self.sv.blockedTools = Settings.Sv_BlockedTools()
			self.sv.hazardTools = Settings.Sv_HazardTools()
			self.sv.hostOnlyTools = Settings.Sv_HostOnlyTools()
			self.network:sendToClients( "client_setBlockedTools", self:sv_toolPayload() )
			self:sv_toWorld( "/settingschanged", params, player )
			self:sv_broadcast( "Server preset: " .. detail )
		end

	elseif cmd == "/menu" then
		self:sv_openMenu( player )

	elseif cmd == "/plotmenu" then
		self:sv_openPlotsGui( player )

	elseif cmd == "/settings" then
		self:sv_openSettingsGui( player, "safety", 1 )

	elseif cmd == "/settingslist" then
		reply( "settings -- /set <name> <value>" )
		for _, line in ipairs( Settings.Sv_Lines() ) do reply( line ) end

	elseif cmd == "/set" then
		local ok, detail = Settings.Sv_Set( params[2], params[3] )
		reply( detail )
		if ok then
			self.sv.blockedTools = Settings.Sv_BlockedTools()
			self.sv.hazardTools = Settings.Sv_HazardTools()
			self.sv.hostOnlyTools = Settings.Sv_HostOnlyTools()
			self.network:sendToClients( "client_setBlockedTools", self:sv_toolPayload() )
			self:sv_toWorld( "/settingschanged", params, player )
			self:sv_broadcast( "Server setting changed: " .. detail )
		end

	elseif cmd == "/autosave" then
		local ok, detail = Settings.Sv_Set( "autosave", params[2] )
		reply( detail )
		if ok then self:sv_toWorld( "/settingschanged", params, player ) end

	elseif cmd == "/event" then
		self:sv_eventCommand( params, reply )

	elseif cmd == "/tool" then
		-- getCurrentToolUuid is a Player binding, so the server can read it
		-- directly -- no client round trip and no way for it to disagree with
		-- what the server thinks you are holding.
		local ok, uuid = pcall( function() return player:getCurrentToolUuid() end )
		if not ok or uuid == nil then
			reply( "your hands are empty" )
			return
		end
		local id = tostring( uuid )
		reply( "holding: " .. id )
		local KNOWN = {
			["5cc12f03-275e-4c8e-b013-79fc0f913e1b"] =
				"the CREATIVE lift -- this is the one that opens the creations menu",
			["8f190ce2-3a59-423e-8483-a7aa67bd5bc0"] =
				"the SURVIVAL lift -- it carries and raises, but has no creations menu",
			["748b6656-84b2-440f-8f4c-8cc7deeba63c"] =
				"nugdupS, the stale-mod canary. Mod content is reaching the game",
		}
		if KNOWN[id] then reply( "  " .. KNOWN[id] ) end
		local blocked = self.sv.blockedTools[id] or self.sv.hostOnlyTools[id]
		if blocked then
			reply( string.format( "  gated by the '%s' setting", blocked ) )
		end

	elseif cmd == "/players" then
		-- The host is whoever is running the server -- sm.player.getHostPlayer()
		-- IS that person, and it is the same test every host-only path uses. Say
		-- so out loud, because "who has the buttons" is a fair question for a
		-- lobby and there is no other way to find out.
		local players = sm.player.getAllPlayers()
		local hostPlayer = sm.player.getHostPlayer()
		reply( string.format( "%d player(s) here:", #players ) )
		for _, p in ipairs( players ) do
			reply( string.format( "  id %-3d %-10s %s%s", p.id,
				Identity.Sv_PermaOf( p ) or "?", p.name,
				p == hostPlayer and "   <- HOST" or "" ) )
		end
		if hostPlayer == nil then
			reply( "  no host player -- host-only commands will refuse everyone" )
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
			sm.log.info( "[ServerWorks] banned " .. tostring( name ) )
			if target and sm.exists( target ) then
				sm.game.banPlayer( target )
				self:sv_broadcast( name .. " was banned." )
			else
				reply( "(not online -- they will be kicked if they ever join)" )
			end
		end

	elseif cmd == "/unban" then
		local _, detail = Identity.Sv_Unban( joinName( params, 2 ) )
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
			sm.log.info( "[ServerWorks] kicking " .. tostring( name ) )
			sm.game.kickPlayer( target )
			self:sv_broadcast( name .. " was kicked." )
		end
	end
end
