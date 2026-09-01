dofile( "$GAME_DATA/Scripts/game/CreativeGame.lua" )
-- Layout first: it is pure geometry with no dependencies, and both PlotsGui
-- (client) and Plots (server) read it at load time.
dofile( "$CONTENT_DATA/Scripts/Layout.lua" )
dofile( "$CONTENT_DATA/Scripts/Palette.lua" )
dofile( "$CONTENT_DATA/Scripts/Settings.lua" )
dofile( "$CONTENT_DATA/Scripts/Identity.lua" )
dofile( "$CONTENT_DATA/Scripts/SettingsGui.lua" )
dofile( "$CONTENT_DATA/Scripts/PlotsGui.lua" )
dofile( "$CONTENT_DATA/Scripts/StyleGui.lua" )
dofile( "$CONTENT_DATA/Scripts/GuardedTools.lua" )
dofile( "$CONTENT_DATA/Scripts/MenuGui.lua" )
dofile( "$CONTENT_DATA/Scripts/Event.lua" )
dofile( "$CONTENT_DATA/Scripts/EventHud.lua" )
dofile( "$CONTENT_DATA/Scripts/RosterHud.lua" )
dofile( "$CONTENT_DATA/Scripts/EventGui.lua" )
dofile( "$CONTENT_DATA/Scripts/ConfirmGui.lua" )
dofile( "$CONTENT_DATA/Scripts/MyPlotGui.lua" )
dofile( "$CONTENT_DATA/Scripts/FocusGui.lua" )
dofile( "$CONTENT_DATA/Scripts/ProtectionGui.lua" )
dofile( "$CONTENT_DATA/Scripts/BackupsGui.lua" )
dofile( "$CONTENT_DATA/Scripts/PeopleGui.lua" )
dofile( "$CONTENT_DATA/Scripts/DevGui.lua" )
dofile( "$CONTENT_DATA/Scripts/Checklist.lua" )
dofile( "$CONTENT_DATA/Scripts/ChecklistGui.lua" )
dofile( "$CONTENT_DATA/Scripts/Bridge.lua" )
dofile( "$CONTENT_DATA/Scripts/GuiProbe.lua" )
dofile( "$CONTENT_DATA/Scripts/NotLift.lua" )
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
	["/nolift"] = true, ["/clearclay"] = true,
	["/buildtime"] = true, ["/snapshot"] = true, ["/snapshots"] = true,
	["/restore"] = true, ["/purge"] = true, ["/plot"] = true,
	["/plots"] = true, ["/plotgrid"] = true, ["/home"] = true,
	["/plotbuild"] = true, ["/plotclear"] = true, ["/why"] = true,
	["/budget"] = true,
	["/plotapply"] = true,
	["/crowd"] = true, ["/bench"] = true,
}

-- WHAT A GUEST MAY TYPE, AND WHAT A GUEST'S PANEL MAY RUN. Two lists, because
-- they are two different questions, and after this build they have two very
-- different answers.
--
-- ASKED FOR: "every command for players in the chat shall also be disabled
-- appart for host." So the typed list is ONE entry -- and it has to be that one,
-- because /menu is the only way into the menu. There is no key a Game script can
-- see (F reaches Lua only through a tool's equipped update, see CLAUDE.md), so a
-- guest with no commands at all would have no way to claim a plot, read the
-- rules or see who is here. Taking /menu away does not make the server stricter;
-- it makes it unusable.
--
-- That is the whole shape of the change: a guest still DOES everything they
-- could do before, through buttons. What they no longer have is a second,
-- undocumented, typo-prone way in -- which is the point of the menu existing.
local GUEST_TYPED = {
	["/menu"] = true,
}

-- What a guest's own panels may cause on their behalf. Reached only with
-- viaPanel = true, which the network cannot set -- see sv_n_adminCommand.
--
-- IT HAS TO AGREE WITH THE PANELS, and the agreement is now the other way round
-- from V61's: the button works and the typed command does not, deliberately. A
-- command that a guest panel forwards and that is missing from here is a button
-- that answers "Host only", which is the failure this list exists to catch.
local GUEST_PANEL = {
	["/sw"] = true, ["/swhelp"] = true, ["/plot"] = true, ["/players"] = true,
	["/budget"] = true, ["/why"] = true,
	["/rules"] = true, ["/home"] = true, ["/menu"] = true, ["/myplot"] = true,
}

-- /plotmenu IS NOT ON THAT LIST, AND IT USED TO BE.
--
-- V61 added it to the guest set with the note "a plain alias of /myplot, which
-- is on this list". It is not: it runs sv_openPlotsGui, which is the CITY
-- LAYOUT panel -- the grid, every claim, and who owns each one. So any guest
-- who typed it read the whole city configuration. Nothing could be CHANGED
-- that way, because every action behind that panel tests the sender; what
-- leaked was the reading, which is the same leak sv_n_openPanel was written to
-- close and which this one walked straight past.
--
-- Found by auditing rather than by anyone hitting it, and found only because
-- gating the OPENER made the question "which panel does this actually open"
-- worth asking about every command in the list. The gate in sv_openPlotsGui
-- closes it even if this list is wrong again.
--
-- /tool went too: it is a diagnostic nothing forwards, so listing it claimed a
-- panel that does not exist.

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

	-- A PERMA ID RESOLVES TO WHOEVER IS WEARING IT RIGHT NOW.
	--
	-- The people panel sends permas rather than names, because a Scrap Mechanic
	-- display name can hold characters a host cannot type. Without this step a
	-- perma only ever matched the OFFLINE path: banning somebody standing in
	-- front of you would file them correctly and never call sm.game.banPlayer,
	-- so they would stay in the world until they happened to reconnect.
	local named = Identity.Sv_NameOf( token )
	if named ~= nil then
		local alias = string.lower( named )
		for _, p in ipairs( sm.player.getAllPlayers() ) do
			if string.lower( p.name ) == alias then return p, p.name end
		end
		return nil, named
	end
	return nil, token
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

	-- A NEW WORLD MUST NOT INHERIT THE LAST ONE'S STATE.
	--
	-- REPORTED: "every time I create a new world. and fix something you havent
	-- updated yet in a long time."
	--
	-- Every state file this mod writes lives in $CONTENT_DATA -- one folder for
	-- the whole MOD, not per world. Settings.json, Plots.json and Event.json are
	-- shared by every world ever created from it, and nothing here has ever used
	-- per-world storage at all. So a brand new world starts with the previous
	-- world's protection mode, its buildopen flag, its plot claims and its event
	-- phase.
	--
	-- What that looks like from the outside: a fresh world comes up LOCKED, with
	-- claims on plots that do not exist yet and an event that already ended.
	-- Every time. It is also what was misread this morning as "one test event
	-- left it locked" -- it was never a leftover, it is structural.
	--
	-- self.storage IS per world (CreativeGame keeps self.sv.saved in it), so a
	-- stamp written there and mirrored into Settings.json says whether the files
	-- on disk belong to THIS world.
	--
	-- Deliberately AFTER the base call: writing to self.storage before it would
	-- make CreativeGame's own `if self.sv.saved == nil` test see a non-empty
	-- table and skip creating the world entirely -- which is exactly the
	-- no-world-at-all failure that came out of the baseGameContent experiment.
	self:sv_newWorldReset()

	self.sv.kickQueue = {}
	self.sv.nextToolCheck = 0
	self.sv.nextBanReload = 0
	self.sv.blockedTools = Settings.Sv_BlockedTools()
	self.sv.hazardTools = Settings.Sv_HazardTools()
	self.sv.hostOnlyTools = Settings.Sv_HostOnlyTools()
	self.sv.pendingRestore = nil

	-- Who the lobby is being asked to look at. Deliberately NOT persisted: a
	-- focus is a thing a host does for thirty seconds, and a world that came
	-- back up still pointing at somebody who left last week is exactly the kind
	-- of stale state sv_newWorldReset exists to kill.
	self.sv.focus = nil

	-- The dev checklist. Loaded here rather than lazily so a fault in the file
	-- is reported at world create, in the log, where somebody is already
	-- looking -- rather than the first time a host opens the panel mid-session.
	--
	-- NOT cleared by sv_newWorldReset, deliberately. Every other state file here
	-- describes a WORLD and a new one must not inherit it; this one records what
	-- the CODE did, and making a fresh world is the usual way to test something.
	self.sv.checklist = Checklist.Sv_Load()

	-- The outside-the-game control channel. Created always, polled only while the
	-- `bridge` setting is on -- see Bridge.lua for why a door like this is shut
	-- by default.
	self.sv.bridge = Bridge.sv_new()
	Bridge.sv_load( self.sv.bridge )

	-- SAID OUT LOUD AT EVERY WORLD CREATE, because the setting persists.
	-- Leaving it on is convenient and correct for a machine with one user on
	-- it; leaving it on WITHOUT SAYING SO is a door standing open that nobody
	-- remembers opening. One line in the log costs nothing and there is no state
	-- in this mod that deserves it more.
	if Settings.Get( "bridge" ) == true then
		sm.log.warning( string.format(
			"[ServerWorks] BRIDGE IS ON -- this world can be driven from outside "
			.. "the game. Waiting for %s. /bridge off to shut it.",
			Bridge.CmdPath( self.sv.bridge.seq ) ) )
	end
	Bridge.sv_save( self.sv.bridge, Settings.Get( "bridge" ) == true )
	do
		local c = Checklist.Counts( self.sv.checklist )
		sm.log.info( string.format(
			"[ServerWorks] checklist: %d of %d answered (%d pass, %d fail) -- /check",
			c.done, c.total, c.pass, c.fail ) )
	end

	-- The event clock. Loaded from its own file rather than the Game script's
	-- storage, for the same reason Plots is: it has to be readable the instant
	-- the world asks, without depending on save ordering.
	g_swEvent = Event()
	g_swEvent:sv_onCreate( Event.Sv_LoadFile() )
	self.sv.nextEventPush = 0
	if g_swEvent:sv_running() then
		-- Say what the world is going to be like, not just which phase it is in.
		-- A resumed `buffer` or `ended` means the remove tool draws no red
		-- preview and nothing can be placed, and nobody connects that to a clock
		-- they did not know was still running: "still broken red colour".
		local phase = g_swEvent.phase
		local shut = ( Event.PROTECTION[phase] ~= "open" )
		sm.log.info( string.format(
			"[ServerWorks] event resumed: %s, %s left -- building is %s",
			phase, Event.Clock( g_swEvent:sv_remaining() ),
			shut and "SHUT" or "open" ) )
		if shut then
			sm.log.info( "[ServerWorks]   nothing can be placed or removed until "
				.. "the clock reaches build, or /event stop" )
		end
	else
		-- A WORLD THAT COMES UP SHUT USED TO COME UP SILENT, and that silence is
		-- most of why "I cant use the lift" outlived a dozen versions.
		--
		-- `ended` is terminal: sv_running() is false for it, so the branch above
		-- never ran, and the two settings the ended phase persisted -- protection
		-- "locked" and buildopen false -- were simply re-read at load with no log
		-- line, no chat, and nothing on the HUD to connect them to a clock that
		-- finished days ago. Every session after one finished event started in a
		-- world where the lift hovers nothing, selects nothing and places
		-- nothing, because every body is on the locked profile with liftable
		-- false (Lift.lua:127 needs isLiftable() to do any of the three).
		--
		-- So say it, at load, with the command that fixes it.
		local mode = Settings.Get( "protection" )
		local shut = ( Settings.Get( "buildopen" ) == false ) or ( mode ~= "open" )
		if shut then
			sm.log.info( string.format(
				"[ServerWorks] world is SHUT at load: protection %s, buildopen %s",
				tostring( mode ), tostring( Settings.Get( "buildopen" ) ) ) )
			sm.log.info( "[ServerWorks]   no building, no erasing, and the lift "
				.. "cannot pick up or place anything. /unlock reopens it." )
			self.sv.warnShutAtLoad = true
		end
	end
end

-- See the note in server_onCreate. Returns true if this world was new to us.
function Game.sv_newWorldReset( self )
	local saved = self.sv and self.sv.saved
	if type( saved ) ~= "table" then return false end

	local stamp = saved.swWorldStamp
	if stamp == nil then
		-- os.time alone is not enough: two worlds made in the same second would
		-- share a stamp. The tick counter restarts per session, so the pair is
		-- unique in practice for the one thing it has to distinguish.
		stamp = string.format( "%d-%d", os.time(), sm.game.getCurrentTick() )
		saved.swWorldStamp = stamp
		pcall( function() self.storage:save( saved ) end )
	end

	if Settings.Get( "worldstamp" ) == stamp then
		return false                      -- same world as the files on disk
	end

	-- The files belong to a different world. Reset what describes a world and
	-- keep what describes the HOST.
	Settings.Sv_ResetWorldState( stamp )
	Plots.Sv_ResetFile()
	Event.Sv_ResetFile()

	sm.log.info( "[ServerWorks] NEW WORLD -- protection, building, plot claims "
		.. "and the event clock reset. Tool settings, bans and snapshots kept." )
	-- Snapshots are the host's own data and belong to the world they were taken
	-- in, so they are NOT deleted -- silently throwing away somebody's backups
	-- would be a far worse bug than a stale index. They just will not match this
	-- world's city.
	local ok, index = pcall( sm.json.open, Snapshots.INDEX )
	if ok and type( index ) == "table" and next( index ) ~= nil then
		sm.log.info( "[ServerWorks]   NOTE: existing snapshots were taken in a "
			.. "different world. /snapshots still lists them; restoring one here "
			.. "will rebuild that world's creations." )
	end
	return true
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
	-- The bridge listens here too. This is the funnel every WORLD reply comes
	-- through, and world replies are most of what this mod says.
	self:sv_bridgeSay( params.text )
	if params.player and sm.exists( params.player ) then
		self.network:sendToClient( params.player, "client_showMessage", params.text )
	end
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

-- The other half of /unlock. World.lua sets the protection MODE; this sets the
-- `buildopen` blanket, and clears a stale `ended` clock so nothing puts it back.
--
-- Kept here rather than in World because the event clock and the settings live
-- on this side, and because sv_pushEvent has to run afterwards -- the client's
-- canBuild flag is what Game.cl_warnIfBuildingIsShut reads, and leaving it stale
-- would have every lift in the lobby still announcing that builds are locked
-- seconds after they were unlocked.
--
-- Deliberately NOT sv_applyEventPhase( "off" ): that broadcasts "The event clock
-- has been stopped" to everyone, which is a lie when no clock was running. The
-- two writes it would make are made here directly.
function Game.sv_e_swOpenBuilding( self, params )
	-- `ended` is a terminal phase -- sv_advance returns nil once the deadline is
	-- gone -- so it sits in Event.json forever and is re-read on every load. It
	-- writes nothing by itself, but leaving it there means the HUD keeps saying
	-- ENDED / builds are locked over a world that is now open, and the next
	-- /event start would be the only thing that ever cleared it.
	if g_swEvent ~= nil and g_swEvent.phase == "ended" then
		g_swEvent:sv_stop()
		Event.Sv_SaveFile( g_swEvent )
	end
	Settings.Sv_SetQuiet( "buildopen", true )
	self.sv.warnShutAtLoad = nil        -- said once; it is not true any more
	self:sv_pushEvent()
	sm.log.info( "[ServerWorks] building reopened: buildopen true, protection open" )
end

function Game.sv_e_swToolsChanged( self, params )
	self.sv.blockedTools = Settings.Sv_BlockedTools()
	self.sv.hazardTools = Settings.Sv_HazardTools()
	self.sv.hostOnlyTools = Settings.Sv_HostOnlyTools()
	self.network:sendToClients( "client_setBlockedTools", self:sv_toolPayload() )
end

function Game.sv_e_swBroadcast( self, params )
	self:sv_bridgeSay( params.text )
	self.network:sendToClients( "client_showMessage", params.text )
end

function Game.sv_broadcast( self, text )
	-- Announcements are captured too: "City built: 96 plots" is a broadcast, and
	-- it is the answer to the command that caused it.
	self:sv_bridgeSay( text )
	self.network:sendToClients( "client_showMessage", text )
end

function Game.server_onFixedUpdate( self, dt )
	CreativeGame.server_onFixedUpdate( self, dt )

	local tick = sm.game.getCurrentTick()
	-- Its own pcall, separate from everything else on this tick: a control
	-- channel must never be able to take the server down with it, and a fault
	-- anywhere else must never leave a batch half-run.
	pcall( function() self:sv_bridgeTick( tick ) end )
	self:sv_checkToolGuard( tick )
	self:sv_flushKicks()
	self:sv_tickEvent( tick )

	-- Once a second, and it only sends when a number actually moved.
	if tick >= ( self.sv.nextRoster or 0 ) then
		self.sv.nextRoster = tick + TICKS_PER_SECOND
		-- A marker over somebody who has left would hang in the air until a
		-- host noticed and cleared it by hand. This class has no player-left
		-- callback, so the focus is validated on the same beat the roster is --
		-- one sm.exists call a second, and only while somebody is focused.
		pcall( function() self:sv_checkFocusAlive() end )
		pcall( function() self:sv_pushRoster() end )
		pcall( function() self:sv_checkJoinMode() end )
	end

	-- A CLIENT THAT JOINED MID-FOCUS HAS NEVER BEEN TOLD. The marker is pushed
	-- when it CHANGES, so somebody walking in two minutes later would be the
	-- one person in the world who cannot see who everybody is looking at.
	--
	-- Two seconds after the join rather than during it: the world script on
	-- that client is still being built while server_onPlayerJoined runs, and
	-- sendToClients into a client with no world script yet is a message with
	-- nowhere to land.
	if self.sv.focusRepush ~= nil and tick >= self.sv.focusRepush then
		self.sv.focusRepush = nil
		pcall( function() self:sv_pushFocus() end )
	end

	-- Re-read the ban file so a tool outside the game can push a ban mid-event.
	-- The first-join tutorial, once its three seconds are up.
	if self.sv.tutorialFor ~= nil then
		local keep = {}
		for _, job in ipairs( self.sv.tutorialFor ) do
			if tick < job.at then
				keep[#keep + 1] = job
			elseif sm.exists( job.player ) then
				pcall( function()
					self:sv_openTutorialGui( job.player, "all", 1 )
				end )
			end
		end
		self.sv.tutorialFor = ( #keep > 0 ) and keep or nil
	end

	-- Deferred from the join path, for the reason written at Identity.Sv_Touch.
	if tick >= ( self.sv.nextIdentityFlush or 0 ) then
		self.sv.nextIdentityFlush = tick + TICKS_PER_SECOND
		pcall( Identity.Sv_FlushPlayers )
	end

	if tick >= self.sv.nextBanReload then
		self.sv.nextBanReload = tick + Identity.RELOAD_SECONDS * TICKS_PER_SECOND
		pcall( Identity.Sv_Reload )
		local host = sm.player.getHostPlayer()
		for _, player in ipairs( sm.player.getAllPlayers() ) do
			if player ~= host and Identity.Sv_IsBanned( player ) then
				-- Banned by another machine editing the shared list while they
				-- were already in. The engine gets told too, so it sticks.
				table.insert( self.sv.kickQueue, { player = player, ban = true } )
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
		-- SELF-REPAIR. The guard that actually takes a tool out of a hand runs on
		-- the CLIENT -- sm.tool.forceTool is client-side only, so the server can
		-- see what you hold and cannot put it away. That makes the client's copy
		-- of the blocked list load-bearing, and a client whose copy is empty
		-- enforces nothing at all while looking perfectly healthy.
		--
		-- The server is standing here having just seen a blocked tool in a hand,
		-- which is proof that client is not enforcing. So send the list again
		-- rather than only asking for the tool to be dropped. Costs one message
		-- in exactly the case something is already wrong, and nothing otherwise.
		self.network:sendToClient( player, "client_setBlockedTools", self:sv_toolPayload() )
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

-- WHO IS HERE, AND WHO HAS EVER BEEN HERE.
--
-- "a counter of amount of players curently. and amount of residents. resident
-- list is list of players that were here - the banned ones."
--
-- Residents is deliberately the number of RECORDS minus the number of banned
-- records, not "records with a lastSeen". A record is created the first time
-- somebody joins under a name, so the count is exactly "people who have been
-- here", and taking the bans off it makes it "people who have been here and are
-- still welcome" -- which is the number worth putting on screen.
--
-- Cheap: two array lengths and one loop over the ban list, once a second, and
-- only sent when it changes.
-- The crowd lives in the World script (it needs plots and bodies), and this
-- lives in Game (it needs the network). The world pushes its size across
-- whenever it changes; nothing polls.
function Game.sv_e_swCrowdCount( self, params )
	local n = tonumber( params and params.count ) or 0
	if n == self.sv.crowdCount then return end
	self.sv.crowdCount = n
	pcall( function() self:sv_pushRoster() end )
end

function Game.sv_rosterCounts( self )
	-- BOTS COUNT. They claim plots and stand on them through the same system a
	-- person does, so anything that scales with "how many people are here" has
	-- to see them or the test measures a server nobody is on. The count is kept
	-- separate as well as added, so the HUD can say which is which -- a host
	-- must never read the online number and think that many people turned up.
	local bots = self.sv.crowdCount or 0
	local online = #sm.player.getAllPlayers() + bots
	local records = Identity.players and Identity.players.records or {}
	local banned = 0
	for _, entry in ipairs( Identity.bans and Identity.bans.bans or {} ) do
		if Identity.Sv_FindByPerma( entry.perma ) then
			-- Only bans that match somebody we have a record for. A ban pushed
			-- by dev/resolve_ids.py for a name nobody has ever used here is not
			-- a resident we lost.
			banned = banned + 1
		end
	end
	-- Bots are residents too while they are standing: a resident is somebody the
	-- server knows and still welcomes, and for the length of a test that is what
	-- they are. They are NOT written to Players.json -- see Identity -- so the
	-- real resident count is exactly what it was the moment they are cleared.
	return online, math.max( 0, #records - banned ) + bots, bots
end

-- WATCH WHO IS ALLOWED TO JOIN, BECAUSE CHANGING IT MID-SESSION KICKS PEOPLE.
--
-- MEASURED, from this owner's own log archive rather than from reasoning --
-- game-20260710-192923.log, five players, one host:
--
--   19:52:45  user X   Connecting -> None      turned away
--   19:52:59  user X   Connecting -> None      ...and again, six more times
--   19:53:35  Multiplayer: Multiplayer(3)      the host widens the setting
--   19:53:35  user X   Connecting -> Finding Route
--   19:53:36  user X   Finding Route -> Connected
--
--   20:22:39  Multiplayer: Multiplayer(0)      the host narrows it again
--   20:22:39  User A is not authenticated      ONE TICK LATER
--   20:22:39  User B is not authenticated
--   20:22:39  A, B:  Connected -> None         both thrown out
--
-- Two facts, both worth more than the guess they replace. Somebody who cannot
-- join retries silently and the host sees nothing at all -- seven attempts over
-- fifty seconds, no message anywhere. And narrowing the setting while people
-- are in the world REMOVES them, one tick later, reported as an authentication
-- failure rather than as anything to do with the setting.
--
-- The mod cannot change the setting -- there is no setter, only
-- getSettingValue -- so this says what happened rather than preventing it. That
-- is still the whole difference between "the server is broken" and "I pressed
-- something".
function Game.sv_checkJoinMode( self )
	local label, raw = Settings.JoinMode()
	if raw == nil then return end
	local key = tostring( raw )
	if self.sv.joinMode == nil then
		self.sv.joinMode = key
		sm.log.info( "[ServerWorks] " .. Settings.JoinModeLine() )
		return
	end
	if self.sv.joinMode == key then return end

	local was = self.sv.joinMode
	self.sv.joinMode = key
	sm.log.info( string.format( "[ServerWorks] MULTIPLAYER SETTING CHANGED: %s -> %s  (%s)",
		was, key, tostring( label ) ) )

	-- Only the host can have changed it, and only the host can do anything
	-- about it. A guest being told the rules moved as they are thrown out is
	-- noise at the worst moment.
	local host = sm.player.getHostPlayer()
	if host == nil or not sm.exists( host ) then return end
	local others = math.max( 0, #sm.player.getAllPlayers() - 1 )
	self.network:sendToClient( host, "client_showMessage",
		"Multiplayer setting changed -- " .. Settings.JoinModeLine() )
	if others > 0 then
		self.network:sendToClient( host, "client_showMessage", string.format(
			"  %d other player(s) are in the world. Anyone the new setting does not "
			.. "allow is dropped within a second, reported as 'not authenticated'.",
			others ) )
	end
end

function Game.sv_pushRoster( self, player )
	local online, residents, bots = self:sv_rosterCounts()
	-- The focused player's NAME rides along on the roster rather than getting a
	-- push of its own. The roster HUD is already the top-left panel, it already
	-- re-renders once a second, and it is already only sent when something
	-- moves -- so a third line on it costs one string in a message that was
	-- being sent anyway, instead of a second HUD with its own widget, its own
	-- position arithmetic and its own redraw timer.
	local state = { online = online, residents = residents, bots = bots,
		focus = self.sv.focus and self.sv.focus.name or nil }
	if player then
		self.network:sendToClient( player, "client_setRoster", state )
		return
	end
	-- Only when it changes. This is a HUD that redraws on receipt, and sending
	-- an identical payload once a second would be a redraw once a second for
	-- every client, forever, for a number that changes a handful of times a day.
	if self.sv.roster and self.sv.roster.online == online
		and self.sv.roster.residents == residents
		and self.sv.roster.bots == bots
		and self.sv.roster.focus == state.focus then
		return
	end
	self.sv.roster = state
	self.network:sendToClients( "client_setRoster", state )
end

function Game.sv_pushEvent( self, player )
	if g_swEvent == nil then return end
	local state = g_swEvent:sv_clientState()
	-- Whether building is open AT ALL, and why not. The client has no way to
	-- know: it can see the phase, but /lockdown and a host toggle are invisible
	-- to it, and a lift that silently refuses to place anything is the single
	-- most confusing thing this mod does.
	state.mode = g_swProtection and g_swProtection:sv_getMode() or nil
	state.canBuild = ( Settings.Get( "buildopen" ) ~= false )
		and ( state.mode == "open" or state.mode == "open_destructible" )
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
	local open = ( phase == "build" or phase == "off" )
	Settings.Sv_SetQuiet( "buildopen", open )
	-- And the protection MODE, explicitly. Setting buildopen alone was the bug:
	-- profileFor short-circuits on a locked mode and never reaches the resolver,
	-- so an event that had once ENDED left the world locked forever.
	Settings.Sv_SetQuiet( "protection", Event.PROTECTION[phase] or "open" )

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
	elseif phase == "buffer" then
		self:sv_broadcast( string.format(
			"TIME. Building is closed -- %s to look around before anything is locked.",
			Event.Clock( g_swEvent:sv_remaining() ) ) )
	elseif phase == "ended" then
		self:sv_broadcast( "Builds are locked and everything has been saved." )
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
	for _, entry in ipairs( pending ) do
		-- Entries used to be bare players; accept both so an in-flight queue
		-- across a reload cannot throw.
		local player = ( type( entry ) == "table" and entry.player ) or entry
		local ban = ( type( entry ) == "table" ) and entry.ban == true or false
		if player and sm.exists( player ) then
			local ok = pcall( function()
				if ban then
					sm.game.banPlayer( player )
				else
					sm.game.kickPlayer( player )
				end
			end )
			sm.log.info( string.format( "[ServerWorks] %s %s%s",
				ban and "banning" or "kicking", tostring( player.name ),
				ok and "" or " -- FAILED (host?)" ) )
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
		table.insert( self.sv.kickQueue, { player = player, ban = false } )
		return
	end

	if Identity.Sv_IsBanned( player ) then
		-- Not kicked inline: the player is still being constructed here and the
		-- base class has spawn work queued behind us. One tick later is safe.
		--
		-- BANNED, not kicked. sm.game.banPlayer is the engine's own ban and it
		-- is the only part of this that a rename cannot walk around -- our list
		-- is keyed on the display name, because Lua is given no stable player
		-- id at all (the Player binding list has `id`, which is a session slot,
		-- and `name`, and nothing else). So when somebody banned while offline
		-- turns up, the engine is told too, and from then on it is the engine
		-- keeping them out rather than us.
		table.insert( self.sv.kickQueue, { player = player, ban = true } )
		return
	end

	-- See server_onFixedUpdate: the actual push is deferred, because this
	-- client's world script does not exist yet.
	if self.sv.focus ~= nil then
		self.sv.focusRepush = sm.game.getCurrentTick() + 2 * TICKS_PER_SECOND
	end

	self.network:sendToClient( player, "client_setBlockedTools", self:sv_toolPayload() )
	self.network:sendToClient( player, "client_welcome", {
		perma = rec.perma,
		plots = Settings.Get( "plots" ) == true,
		event = g_swEvent and g_swEvent.phase or "off",
		-- So the one message everybody reads does not advertise commands the
		-- reader is not allowed to type. Telling a guest to use /sw and then
		-- refusing them is exactly the shape of thing that gets reported as the
		-- mod being broken.
		host = ( player == host ),
	} )
	self:sv_pushEvent( player )
	self:sv_pushRoster( player )
	-- EVERYBODY ELSE IS NOT TOLD HERE, and that is the fix rather than an
	-- omission. server_onFixedUpdate already pushes the roster once a second
	-- and already sends nothing when no number moved, so this broadcast bought
	-- at most one second of freshness -- and it cost one message to every
	-- client for every join.
	--
	-- That is N x N during exactly the window this engine cannot take it.
	-- Dr Pixel Plays' stream could not get two people in at the same time
	-- without the handshake failing; forty people arriving through a Steam
	-- group is a burst of forty joins, which was a burst of up to 1,600 roster
	-- messages from this mod alone, on top of whatever the engine was already
	-- failing to do. The count is still correct within a second.

	-- The single most confusing state this mod can be in: a clock nobody knew
	-- was running has shut building, so the remove tool draws no red preview and
	-- blocks will not place. Say it on the way in rather than leaving them to
	-- work it out.
	if g_swEvent and g_swEvent:sv_running()
		and Event.PROTECTION[g_swEvent.phase] ~= "open" then
		self.network:sendToClient( player, "client_showMessage", string.format(
			"%s -- building is closed. %s left.",
			Event.LABELS[g_swEvent.phase] or g_swEvent.phase,
			Event.Clock( g_swEvent:sv_remaining() ) ) )
		if player == sm.player.getHostPlayer() then
			self.network:sendToClient( player, "client_showMessage",
				"  /menu -> EVENT CLOCK -> STOP THE EVENT gives you the controls back." )
		end

	-- THE SAME MESSAGE FOR THE CASE NOBODY WAS TOLD ABOUT: shut with no clock
	-- running. The branch above only fires while sv_running() is true, and
	-- `ended` is not running -- so the state that actually persists between
	-- events, and across restarts, was the one state that said nothing.
	--
	-- Host only. A guest can do nothing about it and "the world is locked" is
	-- already on the HUD; the host is the one holding the command.
	elseif self.sv.warnShutAtLoad and player == sm.player.getHostPlayer() then
		self.network:sendToClient( player, "client_showMessage",
			"Building is CLOSED on this world -- nothing places, nothing erases, "
			.. "and the lift will not pick up or place anything." )
		self.network:sendToClient( player, "client_showMessage",
			"  /unlock reopens it. (Left over from an event that ended.)" )
	end

	-- THE TUTORIAL MEETS PEOPLE WHO HAVE NEVER SEEN THIS BEFORE.
	--
	-- ASKED FOR: "in game tutorial. when you are joining. it tells how to use
	-- the mod." A line in the welcome text is not that -- chat scrolls, and the
	-- one person who needs it is busy looking at a city they do not understand.
	--
	-- ONLY ON A FIRST JOIN. Identity.Sv_Touch returns whether it had to invent a
	-- perma id, which is exactly "this is somebody new". Opening it every time
	-- would be the mod interrupting a regular for the fiftieth time.
	--
	-- DEFERRED, for the same reason the focus marker is: this client's world
	-- script does not exist yet while server_onPlayerJoined runs, and a panel
	-- pushed into a client that is still being built is a panel with nowhere to
	-- land.
	if rec.firstJoin and Settings.Get( "tutorialonjoin" ) ~= false then
		self.sv.tutorialFor = self.sv.tutorialFor or {}
		self.sv.tutorialFor[#self.sv.tutorialFor + 1] = {
			player = player,
			at = sm.game.getCurrentTick() + 3 * TICKS_PER_SECOND,
		}
	end

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
		-- SAID ON THE WAY IN, and said to everyone rather than only the host.
		-- A guest who hits a rough edge has no way of knowing whether the mod
		-- is unfinished or the server is broken, and they will report the
		-- second. Also on the front of /menu, because this scrolls away.
		"  It is a WORK IN PROGRESS -- expect rough edges.",
		string.format( "  Your permanent id is %s.", tostring( data.perma ) ),
		"",
	}
	if data.plots then
		lines[#lines + 1] = "  This is a PLOT event:"
		lines[#lines + 1] = "   1. Stand on an empty plot and press CLAIM on the MY PLOT panel."
		lines[#lines + 1] = "   2. You can only build on your own plot."
		lines[#lines + 1] = "   3. Walk onto someone else's plot and you get pushed off."
		lines[#lines + 1] = "   4. To build with a neighbour, both press TEAM UP on that panel."
		lines[#lines + 1] = "      Only front, behind, left or right -- never corner to corner."
		lines[#lines + 1] = "      Teams chain: team your neighbour, they team theirs, all three share."
		lines[#lines + 1] = "      Then the gap between your plots becomes shared ground."
	else
		lines[#lines + 1] = "  Free build. The host may lock builds at any time."
	end
	lines[#lines + 1] = ""
	-- /menu FIRST, and for a guest it is the ONLY one. "the point of menu was so
	-- theres no need to use the command line besides the stuff you know /menu",
	-- and chat commands are host-only now -- so naming /sw to somebody who
	-- cannot run it would be advertising a refusal.
	lines[#lines + 1] = "  /menu   everything on buttons -- your plot, the rules, who is here."
	-- The one line a new arrival is guaranteed to read, pointing at the one
	-- place that explains the rest. A builder who has never seen this mod does
	-- not know a plot has to be CLAIMED, and nothing else tells them.
	lines[#lines + 1] = "          then HOW THIS WORKS, if you have not used this before."
	if data.host then
		lines[#lines + 1] = "  /sw for commands, /rules for the server rules."
	else
		lines[#lines + 1] = "  That is the only command you need -- everything else is on it."
	end
	lines[#lines + 1] = "------------------------------------------"

	for _, line in ipairs( lines ) do
		sm.gui.chatMessage( line )
	end
end

function Game.client_showMessage( self, text )
	sm.gui.chatMessage( text )
end

-- The plot marker is NOT here. It went through this script for three versions
-- and never once drew, because compassSetIconWorldPosition is world-dependent
-- and a Game script has no world. It lives in World.lua now; see
-- World.sv_refreshMarker.

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

function Game.client_setRoster( self, state )
	if self.cl == nil then self.cl = {} end
	self.cl.roster = state
	self.cl.rosterDirty = true
end

-- Rendered only when the numbers change or the panel does not exist yet. There
-- is no clock in it, so there is nothing to redraw on a timer.
-- ON AT ALL TIMES, which is not what "redraw when it changes" gives you.
--
-- REPORTED: "where is the player and citizen counter? it shall be on for now at
-- all times." It rendered only when self.cl.rosterDirty was set, and that flag
-- is only set when the SERVER pushes -- and the server only pushes when a number
-- actually moves, which on a single-player world is once, at join, and never
-- again. So there was exactly one render, at the one moment the HUD was least
-- likely to exist yet, and nothing to put it back afterwards.
--
-- Two changes, and the second is the one that makes it robust: the panel starts
-- with a state of its own so it draws before the server has ever spoken, and it
-- re-renders once a second whatever happens, so anything that takes the widget
-- away -- a graphics reload, another GUI, a world rebuild -- gets it back within
-- a second instead of never.
--
-- Once a second is not a cost worth avoiding: it is two numbers on a Wallpaper
-- layer, which is what the event clock already does beside it.
function Game.cl_updateRosterHud( self )
	local r = self.cl.roster
	if r == nil then return end

	local tick = sm.game.getCurrentTick()
	if not self.cl.rosterDirty and tick < ( self.cl.rosterNext or 0 ) then return end
	self.cl.rosterDirty = false
	self.cl.rosterNext = tick + 40

	if self.cl.rosterHud == nil or not sm.exists( self.cl.rosterHud ) then
		-- The same four flags NotificationManager uses for its own timer, and
		-- the same ones the event clock uses. isHud draws over the game and
		-- isInteractive = false means it can never eat a click.
		local ok, gui = pcall( sm.jsonGui.createGui, { layer = "Wallpaper",
			isInteractive = false, needsCursor = false, isHud = true } )
		if not ok then
			if not self.cl.rosterHudFaulted then
				self.cl.rosterHudFaulted = true
				sm.log.warning( "[ServerWorks] roster HUD unavailable: " .. tostring( gui ) )
			end
			return
		end
		self.cl.rosterHud = gui
	end

	local sw, sh = EventHud.ScreenSize()
	pcall( function() self.cl.rosterHud:render( RosterHud.Build( r, sw, sh ) ) end )
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
		-- Re-read the screen size on every render rather than caching it: the
		-- player can change resolution or alt-tab out of fullscreen mid-event,
		-- and a cached size would leave the clock stranded off the edge.
		local sw, sh = EventHud.ScreenSize()
		-- Once per session, so the GUI canvas size stops being something we infer
		-- from a screenshot. Every fixed-size panel in this mod is declared in
		-- these units -- SettingsGui is 1120x690 -- so if this ever prints a
		-- height near or below 690 those panels are overflowing the screen and
		-- that is why a button is unreachable.
		if not self.cl.screenLogged then
			self.cl.screenLogged = true
			sm.log.info( string.format(
				"[ServerWorks] gui canvas %gx%g (panels are declared in these units)",
				sw, sh ) )
		end
		pcall( function() self.cl.eventHud:render( EventHud.Build( shown, sw, sh ) ) end )
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

	-- First, before anything: shut whatever a click asked to be shut. A panel is
	-- never closed from inside its own callback -- see cl_closeLater for the
	-- three versions of "the buttons dont work" that came out of doing so.
	self:cl_drainCloses()
	self:cl_drainRenders()

	if self.cl and self.cl.event then
		self:cl_updateEventHud()
	end
	-- Unconditional, unlike the clock: the roster is there whether or not an
	-- event has ever been started, which is most of the time this server is up.
	if self.cl then
		self:cl_updateRosterHud()
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

	self:cl_warnIfBuildingIsShut( uuid )

	local name = blocked[tostring( uuid )]
	if name == nil then
		self.cl.lastBlockedWarn = nil
		return
	end

	pcall( sm.tool.forceTool, nil )

	-- One message per pickup, not one per tick. The server strips the item on its
	-- own poll; this just makes the hand empty immediately.
	-- ONE KEY FOR BOTH PATHS. There are two, and they say the same sentence:
	-- this client tick, and client_dropTool sent by the server's own poll when
	-- it catches a blocked tool in a hand. Each used to keep its own dedupe key,
	-- so every blocked tool was announced TWICE -- MEASURED, from a screenshot
	-- with "The claygun is disabled on this server." three times in six lines.
	self:cl_sayToolBlocked( name )
end

-- The one place either path speaks. Returns having said it at most once per
-- tool, whichever path got here first.
function Game.cl_sayToolBlocked( self, name )
	if self.cl == nil then self.cl = {} end
	if self.cl.lastBlockedWarn == name then return end
	self.cl.lastBlockedWarn = name
	sm.gui.chatMessage( ( name == "lift" )
		and "The lift is host only on this server."
		or string.format( "The %s is disabled on this server.", tostring( name ) ) )
end

--[[ the frame-rate probe ]]
--
-- THE ONLY WALL CLOCK IN THIS ENGINE'S LUA.
--
-- `os` does not exist in the sandbox, and sm.game.getCurrentTick() is the
-- simulation counter -- which is the very thing /bench is trying to measure, so
-- it cannot also be the reference. Drop to 20 Hz and a stage timed in ticks
-- silently takes twice as long and reports 40 Hz anyway.
--
-- client_onUpdate's `dt` is real seconds. Proven by what vanilla does with it:
-- CreativeGame.lua:208 advances the day with `timeOfDay + dt / DAYCYCLE_TIME`,
-- which would drift against the sun if it were anything else.
--
-- So this is the stopwatch, and it is also the only place frame rate is visible
-- at all -- client_onFixedUpdate runs at the simulation rate and would report 40
-- on a machine drawing 12.
--
-- ARMED, NOT ALWAYS ON. One message per client per second is nothing next to
-- what a crowd of bots costs, but it is not nothing, and a probe that ran during
-- an event would be adding traffic to the thing it exists to measure. The server
-- turns it on for the length of a run and off again (sv_e_swBenchArm).
function Game.client_onUpdate( self, dt )
	CreativeGame.client_onUpdate( self, dt )

	local s = self.cl and self.cl.bench
	if s == nil or not s.armed then return end

	s.frames = s.frames + 1
	s.secs = s.secs + dt
	if s.secs < 1.0 then return end

	-- A tick DELTA, not a tick. The delta and the wall-clock delta then cover
	-- exactly the same interval, which absolute ticks do not: N samples span N
	-- seconds but only N-1 gaps between their timestamps, so a ten-second window
	-- reported 36 Hz on a server running a clean 40. Caught by
	-- dev/test_logic.py, which is the whole reason that check exists -- a
	-- benchmark reading 10% low is entirely plausible and would have been
	-- believed.
	--
	-- Measured here rather than on the server for a second reason: reading the
	-- tick when the message LANDS puts a packet's latency between the two
	-- quantities, which at 40 Hz is another whole percent.
	-- Note what is NOT in here: whether this client is the host. That is an
	-- identity, and an identity in a payload is a claim -- the server works it
	-- out from the sender instead. It matters more than it looks: the host's
	-- sample is the one the stage timer and the whole tick-rate column are built
	-- on, so a guest able to say "I am the host" could drive the run.
	local now = sm.game.getCurrentTick()
	self.network:sendToServer( "sv_n_benchSample", {
		frames = s.frames,
		secs = s.secs,
		ticks = now - ( s.tick0 or now ),
	} )
	s.frames, s.secs, s.tick0 = 0, 0, now
end

function Game.cl_n_benchArm( self, params )
	if self.cl == nil then return end
	self.cl.bench = { armed = params and params.on == true, frames = 0, secs = 0,
		tick0 = sm.game.getCurrentTick() }
	if self.cl.bench.armed then
		sm.gui.chatMessage( "#dfbf00Frame-rate probe on. Stand still until the bench finishes." )
	end
end

-- From the world, which is where Bench lives (it needs the crowd and the shape
-- census). A world script has no network of its own, hence the hop.
function Game.sv_e_swBenchArm( self, params )
	self.network:sendToClients( "cl_n_benchArm", { on = params and params.on == true } )
end

-- THE LIFT IS NOT BROKEN, THE WORLD IS SHUT.
--
-- REPORTED over and over as "the lift is still fuc-SAD", and the screenshot that
-- came with it has the answer in the top right corner of the frame: the event
-- HUD reads ENDED / builds are locked. In that state protection is `locked`,
-- every body is convertibleToDynamic = false, and a creation that cannot convert
-- cannot be placed. The lift does nothing, says nothing, and looks broken.
--
-- It is not something to fix -- a locked world SHOULD refuse new creations, that
-- is what locked means. It is something to SAY.
-- One entry, because there is one lift. The creative lift and the Import Lift
-- were both removed from the toolset once NOTlift took over importing.
local LIFT_UUIDS = {
	["8f190ce2-3a59-423e-8483-a7aa67bd5bc0"] = true,
}

function Game.cl_warnIfBuildingIsShut( self, uuid )
	if not LIFT_UUIDS[tostring( uuid )] then
		self.cl.liftWarned = nil
		return
	end
	local e = self.cl.event
	if e == nil or e.canBuild ~= false then return end
	if self.cl.liftWarned then return end
	self.cl.liftWarned = true

	-- THE HOST GETS A DIFFERENT SENTENCE, because V60 made it a different fact.
	--
	-- MEASURED, from a screenshot: the host typed /lockdown and was told "The
	-- lift will not place anything ... It works again the moment building opens"
	-- -- which is the message written for a GUEST, and which now contradicts the
	-- thing V60 was built for: "I should be able to build and delete stuff
	-- anywhere. and place lift."
	--
	-- What is actually true for the host is narrower than "it works" and wider
	-- than "it will not place anything", so it says the narrow true thing: the
	-- world is shut, you kept every tool, and the ground is only unlocked within
	-- a few metres of you. Whether a lift can PLACE inside that bubble has not
	-- been measured, so it is not claimed.
	-- pcall: this runs on a CLIENT, and both halves are bindings a client half
	-- of a Game script has never been asked for here before. Getting it wrong
	-- must cost the right sentence, never the whole handler.
	local okHost, amHost = pcall( function()
		return sm.localPlayer.getPlayer() == sm.player.getHostPlayer()
	end )
	if okHost and amHost then
		sm.gui.chatMessage(
			"The world is locked, and you still have every tool." )
		sm.gui.chatMessage(
			"  Bodies are only unlocked within a few metres of you -- "
				.. "/menu, PROTECTION says whether that is open." )
		return
	end

	local why = ( e.phase == "ended" and "the event has ended" )
		or ( e.phase == "prep" and "it is prep time" )
		or ( e.phase == "buffer" and "it is buffer time" )
		or "the host has closed building"
	sm.gui.chatMessage( string.format(
		"The lift will not place anything: %s, so builds are locked.", why ) )
	sm.gui.chatMessage(
		"  It works again the moment building opens -- /menu, EVENT CLOCK." )
end

function Game.client_dropTool( self, data )
	local name = type( data ) == "table" and data.name or data

	-- forceTool is client-side only: the server can see what you hold, but only
	-- your own client can put it away. The server has already taken the item out
	-- of the inventory; this is what clears it from the hand this instant.
	pcall( sm.tool.forceTool, nil )

	-- The SAME dedupe key the client tick uses, not a second one of its own.
	-- Two keys meant two announcements for one tool.
	self:cl_sayToolBlocked( name )
end

function Game.client_onCreate( self )
	CreativeGame.client_onCreate( self )

	-- Disarmed until the server says otherwise. client_onUpdate runs every frame
	-- and reads this, so it has to exist before the first one.
	self.cl = self.cl or {}
	self.cl.bench = { armed = false, frames = 0, secs = 0, tick0 = 0 }

	-- A state of its own, so the counter is on screen from the first frame
	-- rather than waiting for a server push that may already have happened. The
	-- real numbers overwrite it the moment they arrive.
	self.cl.roster = self.cl.roster or { online = 1, residents = 0 }
	self.cl.rosterDirty = true

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
	sm.game.bindChatCommand( "/citystyle", { { "string", "name", true } },
		"cl_onAdminCommand",
		"style the city -- /citystyle for the list. Rebuild the city to apply it." )
	sm.game.bindChatCommand( "/settings", {}, "cl_onAdminCommand",
		"Host: open the settings panel" )
	sm.game.bindChatCommand( "/settingslist", {}, "cl_onAdminCommand",
		"Host: print settings to chat instead of opening the panel" )
	sm.game.bindChatCommand( "/set",
		{ { "string", "setting", false }, { "string", "value", false } },
		"cl_onAdminCommand", "Host: change a setting, e.g. /set fire off" )
	sm.game.bindChatCommand( "/plots", { { "string", "onoff", true, { "on", "off" } } },
		"cl_onAdminCommand", "Host: shortcut for /set plots on|off" )
	-- nameParams() rather than one string: bindChatCommand splits on spaces and
	-- has no quoting, so "June Carya" would otherwise arrive as two arguments
	-- and be unreachable. Same fix /kick and /ban already use.
	sm.game.bindChatCommand( "/focus", nameParams(), "cl_onAdminCommand",
		"Host: mark a player so everyone can see them -- /focus off to clear" )
	sm.game.bindChatCommand( "/unfocus", {}, "cl_onAdminCommand",
		"Host: clear the focus marker" )
	sm.game.bindChatCommand( "/menu", {}, "cl_onAdminCommand",
		"Open the Server Works menu" )
	-- The dev checklist. Two optional words, so /check on its own opens the
	-- panel and /check pass <id> answers one without leaving the chat box.
	-- The outside-the-game control channel. Off by default; see Bridge.lua.
	sm.game.bindChatCommand( "/clearclay", { { "number", "radius", true } },
		"cl_onAdminCommand",
		"Host: level the ground around you -- the only way to remove clay" )
	sm.game.bindChatCommand( "/developer",
		{ { "string", "onoff", true, { "on", "off" } } }, "cl_onAdminCommand",
		"Host: show or hide the dev tools -- /developer on|off. Off by default" )
	sm.game.bindChatCommand( "/bridge",
		{ { "string", "onoff", true, { "on", "off", "status" } } }, "cl_onAdminCommand",
		"Host: let this world be driven from outside the game -- /bridge on|off" )
	sm.game.bindChatCommand( "/check",
		{ { "string", "what", true }, { "string", "id", true } }, "cl_onAdminCommand",
		"Host: the dev checklist -- /check [next|summary|pass <id>|fail <id>]" )
	-- Client only, no server hop. Four combinations of who owns the callback and
	-- where the widget tree came from; see GuiProbe.lua.
	sm.game.bindChatCommand( "/bptest", { { "string", "blueprintUuid", true } },
		"cl_onBpTest",
		"Probe Q1: can we read a blueprint file? Reads only, changes nothing" )
	sm.game.bindChatCommand( "/bptest2", {}, "cl_onBpTest2",
		"Probe Q2: will the blueprint browser open? Run /bptest first -- may crash" )
	sm.game.bindChatCommand( "/guitest", {}, "cl_onGuiTest",
		"Diagnostic: does a GUI button work here? Run it four times." )
	sm.game.bindChatCommand( "/plotmenu", {}, "cl_onAdminCommand",
		"Host: lay out the city, see what the numbers mean, then build it" )
	-- Not host-gated: a builder needs to see their own budget more than the host
	-- does, and it reads numbers rather than changing anything.
	sm.game.bindChatCommand( "/budget", { { "number", "plot", true } },
		"cl_onAdminCommand",
		"What this plot is using against the server limits" )
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
	-- Host only, and a load-test tool rather than an event one. Two trailing
	-- optional strings because the sub-commands take a word each -- the parser
	-- splits on spaces and has no quoting, so "churn on" is two params.
	sm.game.bindChatCommand( "/crowd",
		{ { "string", "n|off|churn|claim", true }, { "string", "on|off", true } },
		"cl_onAdminCommand",
		"Host: stand in a lobby of bots to load-test the server" )

	sm.game.bindChatCommand( "/bench",
		{ { "string", "start|stop|results", true },
		  { "number", "step", true }, { "number", "seconds", true } },
		"cl_onAdminCommand",
		"Host: walk the crowd up in steps and record fps and tick rate" )

	sm.game.bindChatCommand( "/nolift", {}, "cl_onAdminCommand",
		"Host: clear every lift in the world and drop what is on them" )
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
		{ { "string", "what", false, { "look", "carry", "here", "plot" } },
		  { "number", "n", true } },
		"cl_onAdminCommand",
		"Host: delete junk. look | carry | here <m> | plot <n>" )

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
-- HOST ONLY, AT THE OPENER. "for non host the buttons shall not be seen and not
-- accesible" -- the menu already does the not-seen half, and this is the other
-- one. The opener is the single choke point every route ends at, so gating it
-- here cannot be forgotten by a new caller the way gating each route can.
function Game.sv_openSettingsGui( self, player, group, page, status )
	if player ~= sm.player.getHostPlayer() then return end
	local values = {}
	for _, row in ipairs( Settings.SCHEMA ) do
		values[row.key] = Settings.Get( row.key )
	end
	self.network:sendToClient( player, "client_openSettingsGui",
		{ values = values, group = group, page = page, status = status } )
end

function Game.sv_n_settingsGuiClick( self, data, player )
	if player ~= sm.player.getHostPlayer() then
		return
	end

	local status = nil

	if data.action == "preset" then
		local ok, detail = Settings.Sv_ApplyPreset( data.preset )
		status = detail
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
				status = detail
				if ok then
					self.sv.blockedTools = Settings.Sv_BlockedTools()
					self:sv_toWorld( "/settingschanged", {}, player )
					self:sv_broadcast( "Server setting changed: " .. detail )
				end
			end
		end
	end

	self:sv_openSettingsGui( player, data.group, data.page or 1, status )
end

function Game.client_openSettingsGui( self, data )
	if self.cl == nil then self.cl = {} end
	self.cl.settingsValues = data.values
	self.cl.settingsGroup = data.group or "safety"
	self.cl.settingsPage = data.page or 1
	self.cl.settingsStatus = data.status

	-- Reuse the GUI and just render the new tree into it. Closing and recreating
	-- on every click threw the panel away and built another, which is wasteful
	-- and makes the whole thing flicker. Re-rendering is what vanilla does
	-- (HideoutTrader rebuilds its item list this way).

	self:cl_showPanel( "settings", SettingsGui.Build( data.values,
		self.cl.settingsGroup, self.cl.settingsPage, self.cl.settingsStatus ) )
end

-- ( self, widgetName, data ) -- NOT ( self, data ). Confirmed against
-- Survival/.../HideoutTrader.lua:1536 `cl_selectTrade( self, widgetName, data )`.
-- Getting this wrong handed every click the widget's NAME as a string, so
-- data.action was always nil and no branch ever matched.
function Game.cl_onSettingsGuiClick( self, widgetName, data )
	if type( data ) ~= "table" then return end
	if data.action == "close" then
		self:cl_closeLater( "panel" )
		return
	end
	if data.action == "back" then
		-- No close: the hub renders into this same GUI a moment from now, and a
		-- queued close would land on top of it.
		self.network:sendToServer( "sv_n_openMenu", {} )
		return
	end

	-- CITY STYLE is a panel of its own now rather than a tab of ten steppers:
	-- twenty-five blocks and forty colours behind one button each is not a
	-- selection, it is a slot machine. See StyleGui.lua.
	if data.action == "style" then
		self.network:sendToServer( "sv_n_openPanel",
			{ panel = "style", back = "settings" } )
		return
	end

	-- Switching tab or page is pure presentation, so it re-renders locally
	-- instead of round-tripping to the server. Only a value change needs the
	-- server, because only the server decides what the settings are.
	if data.action == "group" then
		self.cl.settingsGroup = data.group
		self.cl.settingsPage = 1
		self.cl.settingsStatus = nil
		self:cl_renderLater( "settings", SettingsGui.Build(
			self.cl.settingsValues, self.cl.settingsGroup, 1 ) )
		return
	end

	if data.action == "page" then
		local pages = SettingsGui.PageCount( self.cl.settingsGroup )
		local page = data.page
		if page < 1 then page = pages elseif page > pages then page = 1 end
		self.cl.settingsPage = page
		self.cl.settingsStatus = nil
		self:cl_renderLater( "settings", SettingsGui.Build(
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
	self:cl_forgetPanel()
end


--[[ city style panel ]]

-- Split out of the settings panel, where the ten style settings used to be ten
-- stepper rows. REPORTED: "make it not a slider like. but like a list so its
-- easier to select. and use the color pallete selection of paint tool for the
-- city part color selection." See StyleGui.lua.
--
-- Same shape as every other panel here: the server owns the values, the client
-- owns the presentation, and a click that changes something round-trips so a
-- guest's client is never the authority on what the city is made of.
--
-- `back` is carried through every hop because this panel is reached from two
-- places -- the settings nav and the city layout panel -- and BACK that always
-- went to the same one would be wrong from whichever place it was not.
function Game.sv_openStyleGui( self, player, piece, status, back )
	if player ~= sm.player.getHostPlayer() then return end
	local style = {}
	for _, p in ipairs( Palette.PIECES ) do
		style[p.key] = {
			block = Settings.Get( p.key .. "block" ),
			colour = Settings.Get( p.key .. "colour" ),
		}
	end
	self.network:sendToClient( player, "client_openStyleGui", {
		style = style, piece = piece or "pad",
		status = status, back = back or "menu",
	} )
end

function Game.client_openStyleGui( self, state )
	if self.cl == nil then self.cl = {} end
	self.cl.styleState = state
	self:cl_showPanel( "style", StyleGui.Build( state ) )
end

function Game.cl_onStyleGuiClick( self, widgetName, data )
	if type( data ) ~= "table" or self.cl == nil then return end
	local st = self.cl.styleState
	if st == nil then return end

	if data.action == "close" then
		self:cl_closeLater( "panel" )
		return
	end
	if data.action == "back" then
		-- No close: whatever we go back to renders into this same GUI a moment
		-- from now, and a queued close would land on top of it.
		if st.back == nil or st.back == "menu" then
			self.network:sendToServer( "sv_n_openMenu", {} )
		else
			self.network:sendToServer( "sv_n_openPanel", { panel = st.back } )
		end
		return
	end
	-- Which piece is being styled is pure presentation, so it re-renders locally
	-- rather than asking the server what it already told us.
	if data.action == "piece" then
		st.piece = data.piece
		st.status = nil
		self:cl_renderLater( "style", StyleGui.Build( st ) )
		return
	end
	self.network:sendToServer( "sv_n_styleGuiClick", {
		action = data.action, value = data.value, preset = data.preset,
		piece = st.piece, back = st.back,
	} )
end

function Game.cl_onStyleGuiClose( self, widgetName )
	self:cl_forgetPanel()
end

function Game.sv_n_styleGuiClick( self, data, player )
	if player ~= sm.player.getHostPlayer() then return end
	if type( data ) ~= "table" then return end

	local piece = tostring( data.piece or "pad" )
	local status = nil

	if data.action == "block" or data.action == "colour" then
		-- The key is built from the piece, so a client that sent a piece name
		-- that is not one of the five gets a key Sv_Set does not know and is
		-- refused there. Nothing here has to trust it.
		local key = piece .. ( ( data.action == "block" ) and "block" or "colour" )
		local ok, detail = Settings.Sv_Set( key, tostring( data.value ) )
		status = detail
		if ok then
			self:sv_toWorld( "/settingschanged", {}, player )
		end

	elseif data.action == "stylepreset" then
		local name = string.lower( tostring( data.preset or "" ) )
		local style = Palette.STYLES[name]
		if style == nil then
			status = "no style called '" .. name .. "'"
		else
			for key, value in pairs( style ) do
				Settings.Sv_Set( key, value )
			end
			self:sv_toWorld( "/settingschanged", {}, player )
			status = "style: " .. name .. " -- BUILD CITY to apply it"
			self:sv_broadcast( "City style: " .. name .. " -- BUILD CITY to apply it." )
		end
	end

	self:sv_openStyleGui( player, piece, status, data.back )
end



--[[ ONE panel, re-rendered ]]

-- Every interactive panel in the mod shares a single jsonGui object.
--
-- It used to make one per panel -- menu, city, settings, event, my plot,
-- confirm -- six live objects on one client script. Nothing in the base game
-- does that: vanilla creates ONE interactive jsonGui per script and re-renders
-- it when the content changes (HideoutTrader rebuilds its whole item list that
-- way, Survival/.../HideoutTrader.lua:1242).
--
-- It matters because a json GUI has no destroy(). close() hides it; the object
-- stays. So every /menu and every panel added another one that could never be
-- disposed of, and the moment a second interactive GUI existed the mod was in
-- territory the engine is never asked to handle by its own content.
--
-- REPORTED, with a screenshot of the host section of the menu: "these buttons
-- dont work for no reason. I am the host." What separates those three entries
-- from the four above them is not the host check -- the menu hides host entries
-- from guests, so a visible button means the check already passed. It is that
-- MY PLOT, SERVER RULES, WHO IS HERE and COMMANDS answer in CHAT, while EVENT
-- CLOCK, CITY LAYOUT and SERVER SETTINGS all try to open A SECOND PANEL. The
-- ones that worked are exactly the ones that never needed a second GUI.
--
-- One object also makes switching panels free: there is no close, no gap, and no
-- window where two interactive GUIs are both alive. Going from the menu to the
-- city layout is one render call.
function Game.cl_panelGui( self )
	if self.cl == nil then self.cl = {} end
	if self.cl.panelGui == nil or not sm.exists( self.cl.panelGui ) then
		self.cl.panelGui = sm.jsonGui.createGui( { isInteractive = true, needsCursor = true } )
	end
	return self.cl.panelGui
end

-- render() IS the show. A json GUI has neither open() nor destroy() -- MEASURED,
-- as "Unknown member 'open' in userdata" thrown on every render, which is what
-- shut the panel again on every click.
function Game.cl_showPanel( self, name, tree )
	if self.cl == nil then self.cl = {} end
	self.cl.panelName = name
	self:cl_panelGui():render( tree )
end

function Game.cl_closePanel( self )
	if self.cl == nil then return end
	local gui = self.cl.panelGui
	-- Cleared BEFORE closing: close() fires onClose, which calls back into here,
	-- and the second pass would otherwise close a GUI that is already closing.
	self.cl.panelGui = nil
	self.cl.panelName = nil
	self.cl.confirm = nil
	if gui and sm.exists( gui ) then
		pcall( function() gui:close() end )
	end
end


--[[ closing a panel is a NEXT TICK job ]]

-- THE bug behind every "the buttons dont work" report since V26, and it is one
-- line of ordering.
--
--   function Game.cl_onMenuClick( self, widgetName, data )
--       self:cl_closePanel()                                 -- <-- destroys
--       self.network:sendToServer( "sv_n_menuOpen", ... )   -- <-- never runs
--
-- close() destroys the widget whose onClick is CURRENTLY ON THE LUA STACK, and
-- the engine tears the callback down with it. Everything after the close is
-- dead code. It leaves a fingerprint in the log:
--
--   ERROR: ASSERT: 'itrStackWalk != m_vecLastMethodStack.rend()' : LuaVM.cpp:716
--
-- Vanilla never does it. CreativePlayer.cl_e_unstuckYes sends FIRST and closes
-- last (Data/Scripts/game/CreativePlayer.lua:48), and every jsonGui in the base
-- game follows that order.
--
-- The correlation is exact, and it is what proves this rather than suggests it.
-- Of our six click handlers, the three that sent before closing all worked --
-- BUILD CITY built a city, the event panel started events, the settings panel
-- applied presets, every one of them visible in the logs. The three that closed
-- first did nothing at all, every time. The hub menu was one of them, which is
-- why EVERY host feature looked broken: they are all reached through the hub.
--
-- Ordering alone would fix it, but ordering is a rule somebody has to remember
-- every single time. Deferring the close by one tick removes the whole class:
-- the widget cannot be destroyed while its own callback is running, because its
-- own callback has already returned.
function Game.cl_closeLater( self, which )
	if self.cl == nil then self.cl = {} end
	self.cl.closeSoon = self.cl.closeSoon or {}
	self.cl.closeSoon[which] = true
end

local CLOSERS = {
	panel = "cl_closePanel",
	probe = "cl_closeProbe",
}

function Game.cl_drainCloses( self )
	local queued = self.cl and self.cl.closeSoon
	if queued == nil then return end
	self.cl.closeSoon = nil
	for which in pairs( queued ) do
		local fn = CLOSERS[which]
		if fn then self[fn]( self ) end
	end
end

-- REDRAW ON THE NEXT TICK, not now.
--
-- Same rule as cl_closeLater and for the same reason, learned the harder way:
-- REPORTED, "game crashed when I tried to change the number of build time", and
-- the log ends mid-sentence with no error and no shutdown -- a hard crash, not a
-- Lua fault.
--
-- Re-rendering builds a brand new widget tree, which destroys every widget the
-- old one had. Doing that from inside a widget's OWN callback destroys the
-- widget currently executing. For a click that silently killed the rest of the
-- handler (V30). For an EDIT BOX, which also holds the keyboard focus, the
-- engine is left holding a pointer to a widget that no longer exists.
--
-- Vanilla renders from inside its text callback (DigitalSign.lua:149) -- but it
-- re-renders the SAME table, mutated in place. We build a fresh tree every time,
-- which is not the same thing at all.
function Game.cl_renderLater( self, name, tree )
	if self.cl == nil then self.cl = {} end
	self.cl.renderSoon = { name = name, tree = tree }
end

function Game.cl_drainRenders( self )
	local queued = self.cl and self.cl.renderSoon
	if queued == nil then return end
	self.cl.renderSoon = nil
	pcall( function() self:cl_showPanel( queued.name, queued.tree ) end )
end

-- The engine telling us a panel has gone -- escape, or our own close(). It must
-- only DROP THE HANDLE. Calling close() again from in here would be closing a
-- GUI from inside its own callback, which is the bug this section is about.
function Game.cl_forgetGui( self, field )
	if self.cl then self.cl[field] = nil end
end

function Game.cl_forgetPanel( self )
	if self.cl == nil then return end
	self.cl.panelGui = nil
	self.cl.panelName = nil
	self.cl.confirm = nil
end


--[[ the button probe ]]

--[[ NOTLIFT -- the blueprint importer ]]

-- The chain, and every hop in it is one this mod already does elsewhere:
--
--   NotLift click  -> tool server  -> sv_e_swOpenImport (here)
--                  -> client_openImport (here)  -> the engine's browser
--   player picks   -> cl_onNotLiftPick (here)   -> sv_n_swImport (here)
--                  -> World.sv_e_swImportCreation, which does the import
--
-- It is long because the callback is only PROVEN to land on a Game script. See
-- the header of NotLift.lua for the measurement.
function Game.sv_e_swOpenImport( self, params )
	local player = params and params.player
	if player == nil or not sm.exists( player ) then return end
	self.network:sendToClient( player, "client_openImport", {} )
end

function Game.client_openImport( self, data )
	if self.cl == nil then self.cl = {} end
	-- Remember who asked, so a stale callback from some other source cannot be
	-- mistaken for this one.
	self.cl.importArmed = true
	local ok, err = pcall( function()
		sm.gui.openGarageImportGui()
		sm.gui.setGarageButtonCallback( "cl_onNotLiftPick" )
		sm.gui.setGarageErrorCallback( "cl_onNotLiftError" )
	end )
	if not ok then
		self.cl.importArmed = nil
		sm.gui.chatMessage( "The creations browser refused to open: " .. tostring( err ) )
		sm.log.warning( "[ServerWorks] NOTlift browser refused: " .. tostring( err ) )
	end
end

-- ( self, path, name ) -- vanilla's own signature
-- (GarageConsole.cl_e_trackBlueprint), and MEASURED to arrive here.
--
-- THIS HANDLER MUST NOT TOUCH A GUI. The browser widget is alive and this
-- callback is on its stack; closing or redrawing from inside a callback is the
-- one bug that accounted for every "the buttons dont work" report in this
-- project, and with a focused widget it crashed the game outright. Send, and
-- let the browser be dismissed with Escape.
function Game.cl_onNotLiftPick( self, path, name )
	if self.cl == nil then self.cl = {} end
	if not self.cl.importArmed then return end
	self.cl.importArmed = nil

	if type( path ) ~= "string" or path == "" then
		sm.gui.chatMessage( "That creation has no file behind it (Workshop item not "
			.. "downloaded?)." )
		return
	end
	self.network:sendToServer( "sv_n_swImport",
		{ path = path, name = tostring( name or "creation" ) } )
end

function Game.cl_onNotLiftError( self, err )
	sm.log.warning( "[ServerWorks] NOTlift browser error: " .. tostring( err ) )
end

function Game.sv_n_swImport( self, data, player )
	if type( data ) ~= "table" or player == nil then return end
	local world = self:sv_world()
	if world == nil or not sm.exists( world ) then
		self:sv_e_swReply( { player = player, text = "The world is not ready yet." } )
		return
	end
	sm.event.sendToWorld( world, "sv_e_swImportCreation",
		{ player = player, path = data.path, name = data.name } )
end

-- /bptest -- the NOTlift probe. See the NOTLIFT PROBE block in GuiProbe.lua.
--
-- Client only, everything pcall'd, and it changes nothing: it reads and it asks
-- the engine to open its own browser. Nothing is imported, nothing is spawned,
-- no body is touched. Safe to run mid-event.
function Game.cl_onBpTest( self, params )
	if self.cl == nil then self.cl = {} end
	local uuid = ( type( params ) == "table" and type( params[2] ) == "string" )
		and params[2] or nil

	sm.gui.chatMessage( "-- Q1: can we read a blueprint file, and in what form? --" )
	sm.log.info( "[ServerWorks] bptest Q1: sm.json path forms" )
	for _, row in ipairs( GuiProbe.BlueprintPaths( uuid ) ) do
		local label, path = row[1], row[2]

		-- fileExists returns a bool and does not raise, so it is safe to ask
		-- about a path the sandbox may hate. open() DOES raise, hence the pcall.
		local okE, exists = pcall( sm.json.fileExists, path )
		local verdict
		if not okE then
			verdict = "fileExists RAISED: " .. tostring( exists )
		elseif exists ~= true then
			verdict = "no such file"
		else
			local okO, data = pcall( sm.json.open, path )
			if not okO then
				verdict = "EXISTS but open RAISED: " .. tostring( data )
			else
				-- A blueprint has a `bodies` array. Saying so proves we read the
				-- real thing rather than an empty table.
				local bodies = ( type( data ) == "table" ) and data.bodies or nil
				verdict = ( bodies ~= nil ) and "READABLE, it has bodies"
					or "READABLE (no bodies field -- not a blueprint?)"
			end
		end
		sm.gui.chatMessage( string.format( "  %-22s %s", label, verdict ) )
		sm.log.info( string.format( "[ServerWorks] bptest   %-22s %s", label, verdict ) )
	end

	sm.gui.chatMessage( "Q1 done. /bptest2 runs Q2 -- read the warning it prints." )
end

-- Q2 IS A SEPARATE COMMAND BECAUSE IT MIGHT TAKE THE GAME DOWN.
--
-- GarageConsole never calls openGarageImportGui() without calling
-- setGarageImportGuiStorage( containers ) first, and it returns early when the
-- containers are missing rather than opening anyway (GarageConsole.lua:455-460).
-- We have no containers to give it. Whether the engine copes with that or
-- dereferences nothing is exactly the kind of thing that has crashed this game
-- twice already -- and a pcall does not catch a native crash.
--
-- So Q1 runs, prints and LOGS on its own command, and is safely on disk before
-- this one is ever typed. If this crashes, the useful half is already saved.
function Game.cl_onBpTest2( self, params )
	if self.cl == nil then self.cl = {} end
	self.cl.bpPicked = nil

	sm.gui.chatMessage( "-- Q2: will the game's own blueprint browser open? --" )
	sm.gui.chatMessage( "  If the game dies here, that IS the answer -- say so." )
	sm.log.info( "[ServerWorks] bptest Q2: about to call openGarageImportGui "
		.. "with no storage set. A crash after this line is the result." )

	local ok, err = pcall( function()
		sm.gui.openGarageImportGui()
		sm.gui.setGarageButtonCallback( "cl_onBpPick" )
		sm.gui.setGarageErrorCallback( "cl_onBpError" )
	end )
	if ok then
		sm.gui.chatMessage( "  it did not raise. If a list of your creations is on" )
		sm.gui.chatMessage( "  screen, PICK ONE -- the path it hands back is the answer." )
		sm.log.info( "[ServerWorks] bptest Q2: openGarageImportGui did not raise" )
	else
		sm.gui.chatMessage( "  REFUSED: " .. tostring( err ) )
		sm.log.info( "[ServerWorks] bptest Q2 refused: " .. tostring( err ) )
	end
end

-- The callback the browser is told to use. Signature copied from vanilla's own
-- ( GarageConsole.cl_e_trackBlueprint( self, path, name ) ) -- a real filesystem
-- path and the creation's name.
--
-- THIS FIRING AT ALL IS THE RESULT. It would mean the engine dispatches that
-- callback to a Game script, which is the thing no vanilla code does and which
-- decides whether NOTlift can borrow the browser.
function Game.cl_onBpPick( self, path, name )
	if self.cl == nil then self.cl = {} end
	self.cl.bpPicked = path
	sm.gui.chatMessage( "  CALLBACK FIRED -- the browser reaches a Game script." )
	sm.gui.chatMessage( "    name: " .. tostring( name ) )
	sm.gui.chatMessage( "    path: " .. tostring( path ) )
	sm.log.info( string.format( "[ServerWorks] bptest PICK name=%s path=%s",
		tostring( name ), tostring( path ) ) )

	-- And immediately: is that path one WE can read? That is the whole of Q1,
	-- answered with the engine's own path instead of a guessed one.
	local okE, exists = pcall( sm.json.fileExists, path )
	sm.gui.chatMessage( "    fileExists: " .. tostring( okE and exists or "RAISED" ) )
	local okO, data = pcall( sm.json.open, path )
	local shape = okO and ( type( data ) == "table" and data.bodies ~= nil
		and "READABLE, it has bodies" or "READABLE" ) or ( "open RAISED: " .. tostring( data ) )
	sm.gui.chatMessage( "    " .. shape )
	sm.log.info( "[ServerWorks] bptest PICK read: " .. shape )
end

function Game.cl_onBpError( self, err )
	sm.gui.chatMessage( "  browser error callback: " .. tostring( err ) )
	sm.log.info( "[ServerWorks] bptest browser error: " .. tostring( err ) )
end

-- /guitest. See GuiProbe.lua for why this exists: three versions of "the
-- buttons dont work", three real bugs found and fixed, and they still do not
-- work. This stops reasoning about it and measures it, one press at a time.
--
-- Client only. It never touches the server, so nothing about kicks, hosts,
-- settings or the world can be blamed for the result.
function Game.cl_onGuiTest( self, params )
	if self.cl == nil then self.cl = {} end
	local mode = ( self.cl.probeMode or 0 ) + 1
	if mode > #GuiProbe.MODES then mode = 1 end
	self.cl.probeMode = mode
	self.cl.probeHits = nil
	self.cl.probeLast = nil

	local m = GuiProbe.MODES[mode]
	sm.gui.chatMessage( string.format( "guitest %d/%d: %s", mode, #GuiProbe.MODES, m.what ) )
	sm.gui.chatMessage( "  " .. GuiProbe.CanvasLine() )
	sm.log.info( string.format( "[ServerWorks] guitest %d: %s owner=%s tree=%s  %s",
		mode, m.what, m.owner, m.tree, GuiProbe.CanvasLine() ) )

	if m.tree == "layout" then
		-- The other gui api, exactly as vanilla's Game script uses it. open() is a
		-- real method here; a jsonGui has no such thing.
		self:cl_closeLater( "probe" )
		local ok, err = pcall( function()
			local gui = sm.gui.createGuiFromLayout( "$GAME_DATA/Gui/Layouts/PopUp/PopUp_YN.layout" )
			gui:setButtonCallback( "Yes", "cl_onProbeLayoutClick" )
			gui:setButtonCallback( "No", "cl_onProbeLayoutClick" )
			gui:setText( "Title", "TEST 5 of 5" )
			gui:setText( "Message", "createGuiFromLayout, from the GAME script. Press YES." )
			gui:setOnCloseCallback( "cl_onProbeLayoutClose" )
			gui:open()
			self.cl.probeLayoutGui = gui
		end )
		if not ok then
			sm.gui.chatMessage( "  createGuiFromLayout failed: " .. tostring( err ) )
			sm.log.warning( "[ServerWorks] guitest 5 failed: " .. tostring( err ) )
		end
		return
	end

	if m.owner == "player" then
		-- Hand the whole test to the player script, which is where every vanilla
		-- jsonGui callback lives. CreativeGame reaches CreativePlayer exactly this
		-- way for the unstuck popup (Data/Scripts/game/CreativeGame.lua:244).
		self:cl_closeLater( "probe" )
		local ok, err = pcall( sm.event.sendToPlayer, sm.localPlayer.getPlayer(),
			"cl_e_swGuiProbe", { mode = mode } )
		if not ok then
			sm.gui.chatMessage( "  could not reach the player script: " .. tostring( err ) )
		end
		return
	end

	-- Whichever half is not being tested puts its panel away.
	pcall( sm.event.sendToPlayer, sm.localPlayer.getPlayer(), "cl_e_swGuiProbe", {} )
	self:cl_renderProbe()
end

function Game.cl_renderProbe( self )
	local mode = self.cl.probeMode or 1
	local m = GuiProbe.MODES[mode]
	local state = { mode = mode, hits = self.cl.probeHits, last = self.cl.probeLast,
		canvas = GuiProbe.CanvasLine() }

	local root, err
	if m.tree == "file" then
		root, err = GuiProbe.BuildFromFile( state, "cl_onProbeClick", "cl_onProbeClose" )
	else
		root = GuiProbe.BuildLua( state, "cl_onProbeClick", "cl_onProbeClose" )
	end
	if root == nil then
		sm.gui.chatMessage( "  could not build the probe: " .. tostring( err ) )
		return
	end

	if self.cl.probeGui == nil or not sm.exists( self.cl.probeGui ) then
		self.cl.probeGui = sm.jsonGui.createGui( { isInteractive = true, needsCursor = true } )
	end
	self.cl.probeGui:render( root )
end

-- The whole point. If this never runs, a Game script does not receive jsonGui
-- clicks, and every panel in the mod has to move to the player script.
function Game.cl_onProbeClick( self, widgetName, data )
	self.cl.probeHits = ( self.cl.probeHits or 0 ) + 1
	self.cl.probeLast = tostring( widgetName )
	local kind = ( type( data ) == "table" ) and "with data" or ( "no data (" .. type( data ) .. ")" )
	sm.gui.chatMessage( string.format( "CLICK RECEIVED on the GAME script: %s, %s",
		tostring( widgetName ), kind ) )
	sm.log.info( string.format( "[ServerWorks] guitest: GAME script click %s %s",
		tostring( widgetName ), kind ) )
	self:cl_renderProbe()
end

function Game.cl_onProbeClose( self )
	self:cl_forgetGui( "probeGui" )
end

-- createGuiFromLayout hands the callback ( self, buttonName ) -- no data table.
-- CreativeGame.cl_onClearConfirmButtonClick( self, name ) is the shape.
function Game.cl_onProbeLayoutClick( self, buttonName )
	sm.gui.chatMessage( "CLICK RECEIVED on the GAME script via createGuiFromLayout: "
		.. tostring( buttonName ) )
	sm.log.info( "[ServerWorks] guitest: layout click " .. tostring( buttonName ) )
	local gui = self.cl.probeLayoutGui
	self.cl.probeLayoutGui = nil
	if gui and sm.exists( gui ) then pcall( function() gui:close() end ) end
end

function Game.cl_onProbeLayoutClose( self )
	if self.cl then self.cl.probeLayoutGui = nil end
end

function Game.cl_closeProbe( self )
	if self.cl == nil then return end
	local gui = self.cl.probeGui
	self.cl.probeGui = nil
	if gui and sm.exists( gui ) then pcall( function() gui:close() end ) end
	local layout = self.cl.probeLayoutGui
	self.cl.probeLayoutGui = nil
	if layout and sm.exists( layout ) then pcall( function() layout:close() end ) end
end


--[[ hub menu ]]

-- One place to reach everything, because remembering eight slash commands is not
-- a user interface. A guest is only shown what a guest may open, so nobody is
-- offered a button that answers "Host only."
function Game.sv_openMenu( self, player )
	self.network:sendToClient( player, "client_openMenu", {
		host = ( player == sm.player.getHostPlayer() ),
		-- THE SERVER DECIDES, not the client. The menu is drawn client side, so
		-- a modified client could always draw itself the two dev buttons -- and
		-- that is fine, because sv_n_menuOpen, sv_n_openPanel and the command
		-- gate each ask Settings.DeveloperOn again. What is hidden here is a
		-- button; what is shut is the door behind it.
		developer = Settings.DeveloperOn(),
	} )
end

function Game.client_openMenu( self, data )
	self:cl_showPanel( "menu", MenuGui.Build( data.host, data.developer ) )
end

-- The hub is the one panel that DOES close on a click, because what it opens
-- would otherwise be drawn on top of it. Everything it opens carries a BACK
-- button that comes straight back here.
function Game.cl_onMenuClick( self, widgetName, data )
	-- Traced end to end, because "it does nothing" has been the whole report
	-- three times and there is no error in the log to read. Four lines, one per
	-- hop; whichever is the last one printed is where it stops.
	sm.log.info( string.format( "[ServerWorks] gui 1/4 menu click: widget=%s data=%s",
		tostring( widgetName ), type( data ) ) )
	if type( data ) ~= "table" then return end
	if data.action == "close" then
		self:cl_closeLater( "panel" )
		return
	end
	self.network:sendToServer( "sv_n_menuOpen", { what = data.action } )
	-- Only entries that answer in CHAT close the menu. An entry that opens
	-- another panel leaves it alone: the reply renders straight into this same
	-- GUI, and queueing a close here would race it and shut what just arrived.
	if not data.panel then
		self:cl_closeLater( "panel" )
	end
end

-- BACK, from any sub-panel.
function Game.sv_n_openMenu( self, data, player )
	self:sv_openMenu( player )
end

function Game.cl_onMenuClose( self, widgetName )
	self:cl_forgetPanel()
end


function Game.sv_n_menuOpen( self, data, player )
	local isHost = ( player == sm.player.getHostPlayer() )
	local what = data.what
	sm.log.info( string.format( "[ServerWorks] gui 2/4 server got menu open: what=%s host=%s",
		tostring( what ), tostring( isHost ) ) )
	if what == "settings" and isHost then
		self:sv_openSettingsGui( player, "safety", 1 )
	elseif what == "city" and isHost then
		self:sv_openPlotsGui( player )
	elseif what == "event" and isHost then
		self:sv_openEventGui( player )
	elseif what == "focus" and isHost then
		self:sv_openFocusGui( player )
	elseif what == "checklist" and isHost and Settings.DeveloperOn() then
		self:sv_openChecklistGui( player )
	elseif what == "protection" and isHost then
		self:sv_openProtectionGui( player )
	elseif what == "backups" and isHost then
		self:sv_openBackupsGui( player )
	elseif what == "dev" and isHost and Settings.DeveloperOn() then
		self:sv_openDevGui( player )
	elseif what == "myplot" then
		self:sv_toWorld( "/myplot", {}, player )
	elseif what == "howto" then
		self:sv_openTutorialGui( player )
	elseif what == "rules" then
		-- viaPanel: a guest may press this and may not type it. See the two
		-- command tables at the top of this file.
		self:sv_n_adminCommand( { "/rules" }, player, true )
	elseif what == "bans" and isHost then
		-- Straight to the picker. It lists everyone the server has ever seen,
		-- says which of them are banned, and is the only view that can add one.
		self:sv_openPeopleGui( player, nil, "known" )
	elseif what == "players" then
		self:sv_openPeopleGui( player )
	end
end


--[[ city layout panel ]]

function Game.sv_openPlotsGui( self, player, status )
	if player ~= sm.player.getHostPlayer() then return end
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
			roadevery = g.roadevery, roadwidth = g.roadwidth, plazacells = g.plazacells,
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
	cfg.status = status
	sm.log.info( "[ServerWorks] gui 3/4 sending the city panel" )
	self.network:sendToClient( player, "client_openPlotsGui", cfg )
end

function Game.client_openPlotsGui( self, cfg )
	sm.log.info( "[ServerWorks] gui 4/4 client rendering the city panel" )
	if self.cl == nil then self.cl = {} end
	self.cl.plotCfg = cfg
	self:cl_showPanel( "city", PlotsGui.Build( cfg ) )
end

--[[ my plot panel ]]

-- Built on the server because only the world knows what square the player is
-- standing on, and re-sent rather than patched: the whole state is four fields
-- and a grid, and a panel that redraws from one source cannot get out of step
-- with the world the way an incrementally-updated one can.
function Game.client_openMyPlotGui( self, state )
	if self.cl == nil then self.cl = {} end
	self.cl.myPlotState = state
	self:cl_showPanel( "myplot", MyPlotGui.Build( state ) )
end


function Game.cl_onMyPlotClose( self )
	self:cl_forgetPanel()
end

-- Nothing here closes the panel except CLOSE and BACK.
--
-- REPORTED: "I press them and menu closes. and make so that the menu doesnt
-- close after every action alright?" -- and they were right twice over. Every
-- action used to shut its own panel, so a button that worked and a button that
-- did nothing looked identical from the outside, and the one dead button in the
-- build (CLEAR CITY, see World.sv_cityCensus) was indistinguishable from the
-- nine live ones.
function Game.cl_onMyPlotClick( self, widgetName, data )
	if type( data ) ~= "table" then return end
	if data.action == "close" then
		self:cl_closeLater( "panel" )
		return
	end
	if data.action == "back" then
		-- No close: the hub renders into this same GUI a moment from now, and a
		-- queued close would land on top of it.
		self.network:sendToServer( "sv_n_openMenu", {} )
		return
	end
	self.network:sendToServer( "sv_n_myPlotAction", { action = data.action } )
end

function Game.sv_n_myPlotAction( self, data, player )
	if type( data ) ~= "table" then return end
	local map = { claim = "claim", leave = "leave" }
	-- panel = "myplot" tells the world to redraw the panel with the reply on it
	-- rather than only writing to a chat log that is behind the panel.
	if data.action == "find" then
		self:sv_toWorld( "/home", {}, player, { panel = "myplot" } )
	elseif data.action == "why" then
		self:sv_toWorld( "/why", { "/why" }, player, { panel = "myplot" } )
	elseif data.action == "budget" then
		self:sv_toWorld( "/budget", { "/budget" }, player, { panel = "myplot" } )
	elseif map[data.action] then
		self:sv_toWorld( "/plot", { "/plot", map[data.action] }, player,
			{ panel = "myplot" } )
	elseif data.action == "refresh" then
		self:sv_toWorld( "/myplot", {}, player )
	end
end

-- The world finished something a panel asked for and wants that panel redrawn.
-- Only the Game script has a network to reach a client with, so it comes back
-- through here the same way replies and markers do.
function Game.sv_e_swPanelRefresh( self, params )
	if params.player == nil or not sm.exists( params.player ) then return end
	if params.panel == "city" then
		self:sv_openPlotsGui( params.player, params.status )
	elseif params.panel == "protection" then
		self:sv_openProtectionGui( params.player, params.status )
	elseif params.panel == "backups" then
		self:sv_openBackupsGui( params.player, params.status )
	elseif params.panel == "dev" then
		self:sv_openDevGui( params.player, params.status )
	end
end

-- The world assembles the state and hands it back through here, because a world
-- script has no network of its own.
function Game.sv_e_swCityCensus( self, params )
	if params.player == nil or not sm.exists( params.player ) then return end
	local lines = {}
	for _, l in pairs( params.lines or {} ) do lines[#lines + 1] = l end
	self:sv_askConfirm( params.player, "clearcity",
		"DELETE THE WHOLE CITY?", lines, "city" )
end

function Game.sv_e_swMyPlot( self, params )
	if params.player == nil or not sm.exists( params.player ) then return end
	self.network:sendToClient( params.player, "client_openMyPlotGui", params.state )
end

--[[ event panel ]]

function Game.sv_openEventGui( self, player, status )
	if player ~= sm.player.getHostPlayer() then
		self.network:sendToClient( player, "client_showMessage", "Host only." )
		return
	end
	if g_swEvent == nil then return end
	self.network:sendToClient( player, "client_openEventGui", {
		phase = g_swEvent.phase,
		remaining = g_swEvent:sv_remaining(),
		paused = g_swEvent:sv_paused(),
		prep = g_swEvent.prepMinutes,
		build = g_swEvent.buildMinutes,
		buffer = g_swEvent.bufferMinutes,
		status = status,
	} )
end

function Game.client_openEventGui( self, state )
	sm.log.info( "[ServerWorks] gui: rendering the event panel" )
	if self.cl == nil then self.cl = {} end
	self.cl.eventCfg = state
	self:cl_showPanel( "event", EventGui.Build( state ) )
end


function Game.cl_onEventGuiClose( self )
	self:cl_forgetPanel()
end

function Game.cl_onEventGuiClick( self, widgetName, data )
	if type( data ) ~= "table" or self.cl == nil then return end
	local cfg = self.cl.eventCfg
	if cfg == nil then return end

	-- Stepping a duration is local and instant: nothing has happened on the
	-- server yet, so there is nothing to round trip.
	if data.action == "step" then
		cfg[data.key] = EventGui.Step( data.key, cfg[data.key] or 0, data.dir )
		self:cl_renderLater( "event", EventGui.Build( cfg ) )
		return
	end
	if data.action == "close" then
		self:cl_closeLater( "panel" )
		return
	end
	if data.action == "back" then
		-- No close: the hub renders into this same GUI a moment from now, and a
		-- queued close would land on top of it.
		self.network:sendToServer( "sv_n_openMenu", {} )
		return
	end
	-- Stays open. Running an event means pressing several of these in a row --
	-- pause, look, +5 min, resume -- and re-opening the panel between each one
	-- was the difference between a control surface and a set of one-shot
	-- commands wearing buttons.
	self.network:sendToServer( "sv_n_eventGuiAction",
		{ action = data.action, n = data.n,
		  prep = cfg.prep, build = cfg.build, buffer = cfg.buffer } )
end

-- A typed duration. ( self, widgetName, text ) -- a text event carries no
-- onClickData, so the widget NAME is the only thing saying which field it was;
-- see EventGui.FieldForBox. Signature confirmed against DigitalSign.lua:157.
-- NOTHING in here touches the GUI. Not a render, not a deferred render, not a
-- close. Nothing.
--
-- REPORTED twice: "game crashed when I tried to change the number of build
-- time", and then again after V44 deferred the redraw by a tick. The screenshot
-- shows PREP TIME focused with a cursor in it, so ONE box is fine -- it is
-- moving to the SECOND one that kills it, which is a focus transfer between two
-- EditBoxes in the same GUI. The base game has exactly one editable box in its
-- one editable panel (DigitalSign.gui), so two of them in one tree is territory
-- the engine is never asked to handle by its own content.
--
-- Deferring was the right instinct and it was not enough, so this goes further:
-- the value is taken and NOTHING is drawn. The box keeps showing what was typed
-- because the engine put it there; chat says what was actually accepted; and the
-- panel shows the true numbers the next time anything else redraws it. Slightly
-- worse to look at, and it cannot crash.
--
-- The steppers are unaffected, and /event start <prep> <build> <buffer> takes
-- any number from chat with no GUI involved at all.
function Game.cl_onEventTimeTyped( self, widgetName, text )
	local ok, err = pcall( function()
		if self.cl == nil or self.cl.eventCfg == nil then return end
		local field = EventGui.FieldForBox( widgetName )
		if field == nil then return end

		local minutes, why = EventGui.ParseTime( widgetName, text )
		if minutes == nil then
			pcall( sm.gui.chatMessage, why or "type a number of minutes" )
			return
		end

		self.cl.eventCfg[field.key] = minutes
		self.cl.eventCfg.status =
			string.format( "%s set to %d min", field.label, minutes )
		pcall( sm.gui.chatMessage, string.format( "%s: %d minutes.%s",
			field.label, minutes, why and ( "  " .. why ) or "" ) )
	end )
	if not ok and not ( self.cl and self.cl.typedFaulted ) then
		if self.cl then self.cl.typedFaulted = true end
		sm.log.warning( "[ServerWorks] typed time failed: " .. tostring( err ) )
	end
end

function Game.cl_onEventTimeEdited( self, widgetName, text )
end

function Game.sv_n_eventGuiAction( self, data, player )
	if player ~= sm.player.getHostPlayer() then return end
	if g_swEvent == nil or type( data ) ~= "table" then return end

	-- Collected, not just chatted: the panel is still open in front of the chat
	-- log and it is the thing the host is looking at.
	local said = {}
	local function reply( text )
		said[#said + 1] = tostring( text )
		self.network:sendToClient( player, "client_showMessage", text )
	end

	if data.action == "start" then
		local _, phase = g_swEvent:sv_start( data.prep, data.build, nil, data.buffer )
		Event.Sv_SaveFile( g_swEvent )
		self:sv_applyEventPhase( phase )
		self:sv_pushEvent()
		reply( string.format( "event started: %g prep, %g build, %g buffer",
			data.prep or 0, data.build or 0, data.buffer or 0 ) )
	else
		local params = { "/event", data.action }
		if data.action == "add" then params[3] = data.n end
		self:sv_eventCommand( params, reply )
	end

	self:sv_openEventGui( player, ( #said > 0 ) and said[1] or nil )
end


--[[ confirmations ]]

-- Anything that destroys work goes through here twice. See ConfirmGui.lua for
-- why the buttons swap sides between the two steps.
--[[ FOCUS -- one person, marked so the whole lobby can find them ]]

-- Asked for as: "an admin tool. with the tool you can search for nicknames that
-- are curently on the server. and when selected it will highlight them. so
-- people can see the focus person. usefull for event stuff."
--
-- Three pieces, and this file owns only the middle one:
--
--   FocusTool.lua   point at somebody, or hold F to clear. The only thing in
--                   the mod that can see a key press.
--   HERE            who is focused, who is allowed to say so, and the panel
--   Focus.lua       what a marked player looks like, on every client, driven
--                   from World.lua because the compass needs a world
--
-- ONE AT A TIME, on purpose. "the focus person" is a single subject the lobby
-- is being pointed at, so focusing somebody replaces whoever was focused
-- before and there is no way to leave three stale markers across the city.

-- Everyone online, in the shape FocusGui draws. Sorted by name, because the
-- panel is something a host scans with their eyes under time pressure and join
-- order is not an order anybody can search.
--
-- Crowd bots are NOT in here. They are units, not players -- getAllPlayers does
-- not return one, and Focus.Cl_Set needs a Player to find a character through
-- -- so the panel says how many there are rather than leaving a host wondering
-- where 128 names went.
function Game.sv_focusRoster( self )
	local out = {}
	for _, p in ipairs( sm.player.getAllPlayers() ) do
		local perma = Identity.Sv_PermaOf( p )
		local plot = nil
		if g_swPlots ~= nil and perma ~= nil then
			-- g_swPlots lives in the world and may not exist yet while one is
			-- still coming up. A missing plot number is a missing line of
			-- detail; it must never cost the host the whole panel.
			local ok, index = pcall( function() return g_swPlots:sv_plotOf( perma ) end )
			if ok then plot = index end
		end
		out[#out + 1] = { id = p.id, name = p.name, perma = perma, plot = plot,
			-- PeopleGui draws no KICK or BAN on the host's own row. The engine
			-- refuses both anyway ("Unable to kick host" is in the executable),
			-- so a button there could only ever be one that does nothing.
			host = ( p == sm.player.getHostPlayer() ) or nil,
			allowed = Identity.Sv_IsAllowed( p ) or nil }
	end
	table.sort( out, function( a, b )
		return string.lower( a.name ) < string.lower( b.name )
	end )
	return out
end

function Game.sv_focusPlayerById( self, id )
	if id == nil then return nil end
	for _, p in ipairs( sm.player.getAllPlayers() ) do
		if p.id == id then return p end
	end
	return nil
end

-- THE ONE PLACE THAT CHANGES WHO IS FOCUSED. The tool, the panel and the chat
-- command all end up here, so there is exactly one thing to read when the
-- markers are wrong.
function Game.sv_setFocus( self, target, by )
	if target ~= nil and not sm.exists( target ) then target = nil end

	local wasName = self.sv.focus and self.sv.focus.name or nil
	self.sv.focus = target and { player = target, name = target.name } or nil

	self:sv_pushFocus()
	-- The top-left HUD line rides on the roster message; see sv_pushRoster.
	pcall( function() self:sv_pushRoster() end )

	-- SAID OUT LOUD, TO EVERYONE. A marker appearing over somebody with no
	-- explanation reads as a bug the first time it happens, and half the value
	-- of the feature is the lobby knowing to go and look.
	if target ~= nil then
		self:sv_broadcast( string.format( "Look at %s -- follow the marker.",
			tostring( target.name ) ) )
		sm.log.info( string.format( "[ServerWorks] focus: %s (by %s)",
			tostring( target.name ), by and tostring( by.name ) or "server" ) )
	elseif wasName ~= nil then
		self:sv_broadcast( "Focus cleared." )
		sm.log.info( "[ServerWorks] focus cleared" )
	end
	return true
end

-- Markers are drawn from the WORLD's client, not from here. The compass turns a
-- position into a bearing and therefore needs a world, and a Game script has
-- none -- MEASURED, and it is the whole reason PlotMarker moved:
--
--   WARNING: compass marker unavailable: PlotMarker.lua:72:
--            Calling world dependent functions in a no world script!
function Game.sv_pushFocus( self )
	local world = self:sv_world()
	if world == nil or not sm.exists( world ) then return end
	local f = self.sv.focus
	pcall( sm.event.sendToWorld, world, "sv_e_swFocusPush", {
		target = f and f.player or nil,
		name = f and f.name or nil,
		-- Decided HERE, not on each client. Settings is a server-side table, so
		-- a client reading `focusname` would get the schema default whatever the
		-- host had chosen -- which would make the switch do nothing for anybody
		-- but the host, on a feature whose whole point is what everyone else
		-- sees.
		showName = ( Settings.Get( "focusname" ) ~= false ),
	} )
end

-- Called once a second beside the roster push. Cheap: one comparison unless
-- somebody is actually focused.
function Game.sv_checkFocusAlive( self )
	local f = self.sv.focus
	if f == nil then return end
	if f.player ~= nil and sm.exists( f.player ) then return end
	sm.log.info( "[ServerWorks] focus cleared -- " .. tostring( f.name ) .. " has left" )
	self.sv.focus = nil
	self:sv_pushFocus()
	pcall( function() self:sv_pushRoster() end )
	self:sv_broadcast( string.format( "%s has left -- focus cleared.", tostring( f.name ) ) )
end

-- The bridge from FocusTool. A tool script has no route to the Game class, so
-- it goes through sm.event.sendToGame, the same way CleanerTool sends its
-- replies.
--
-- HOST GATED AGAIN, HERE. The tool checks too, and that is not redundant: an
-- event is reachable by anything sharing this Lua environment, so the class
-- that owns the state has to be the class that decides.
--
-- AND THERE IS NO SETTING IN THE WAY. Every other host tool in this mod can be
-- handed to a guest by a host who wants to -- `hostcleaner`, `hostlift`,
-- `hostnotlift` -- because each of those changes the WORLD and the server-side
-- rules on it still apply. This one changes what is drawn on everybody else's
-- SCREEN, which is not a thing to delegate, so the test is the same one the
-- panel and /focus use and nothing can relax it. See HOST_ONLY in Settings.lua.
function Game.sv_e_swFocus( self, params )
	if type( params ) ~= "table" then return end
	local by = params.player
	if by == nil or not sm.exists( by ) then return end

	local function reply( text )
		self.network:sendToClient( by, "client_showMessage", text )
	end

	if by ~= sm.player.getHostPlayer() then
		reply( "Focusing a player is host only." )
		return
	end

	if params.panel then
		self:sv_openFocusGui( by )
		return
	end
	if params.clear then
		if self.sv.focus == nil then
			reply( "Nobody is focused." )
			return
		end
		self:sv_setFocus( nil, by )
		return
	end
	if params.target == nil or not sm.exists( params.target ) then
		reply( "That player is not here any more." )
		return
	end
	self:sv_setFocus( params.target, by )
end


--[[ the protection panel ]]

-- Everything /protection prints, minus the parts only the world can answer, in
-- one table. The Game script can reach all of it: Settings is a shared global,
-- the tool lists are its own, and g_swPlots and g_swEvent are world globals that
-- Game and World share a Lua environment for -- which is the same route
-- sv_openPlotsGui already uses to read the live grid.
--
-- Guarded rather than assumed, because this panel can be opened before the
-- world finishes creating those, and a nil index here would take the menu down
-- with it.
function Game.sv_protectionState( self, status )
	local function nameList( set )
		local seen, out = {}, {}
		for _, name in pairs( set or {} ) do
			if not seen[name] then
				seen[name] = true
				out[#out + 1] = name
			end
		end
		table.sort( out )
		return ( #out > 0 ) and table.concat( out, " " ) or "nothing"
	end

	local bubble = "unknown"
	if g_swPlots and g_swPlots.sv_bubbleStatus then
		local ok, got = pcall( g_swPlots.sv_bubbleStatus, g_swPlots )
		if ok then bubble = tostring( got ) end
	end

	local clock = nil
	if g_swEvent and g_swEvent.sv_running then
		local ok, running = pcall( g_swEvent.sv_running, g_swEvent )
		if ok and running then clock = tostring( g_swEvent.phase ) end
	end

	local okq, quality = pcall( sm.game.getSettingValue, "PhysicsQuality" )

	return {
		mode = tostring( Settings.Get( "protection" ) ),
		buildopen = Settings.Get( "buildopen" ),
		bubble = bubble,
		guest = nameList( self:sv_toolPayload().guest ),
		host = nameList( self.sv.hazardTools ),
		physics = okq and tostring( quality ) or nil,
		clock = clock,
		hostbuild = Settings.Get( "hostbuild" ) == true,
		status = status,
	}
end

function Game.sv_openProtectionGui( self, player, status )
	if player ~= sm.player.getHostPlayer() then return end
	self.network:sendToClient( player, "client_openProtectionGui",
		self:sv_protectionState( status ) )
end

function Game.client_openProtectionGui( self, state )
	if self.cl == nil then self.cl = {} end
	self.cl.protectionState = state
	self:cl_showPanel( "protection", ProtectionGui.Build( state ) )
end

function Game.cl_onProtectionGuiClose( self )
	self:cl_forgetPanel()
	if self.cl then self.cl.protectionState = nil end
end

-- ONLY CLOSE AND BACK CLOSE THE PANEL. Everything else runs, the world sends
-- the whole state back, and it re-renders in place with a status line saying
-- what happened. And nothing here calls cl_showPanel or a closer directly:
-- close() destroys the widget whose callback is on the Lua stack.
function Game.cl_onProtectionGuiClick( self, widgetName, data )
	if type( data ) ~= "table" or self.cl == nil then return end
	if self.cl.protectionState == nil then return end

	if data.action == "close" then
		self:cl_closeLater( "panel" )
		return
	end
	if data.action == "back" then
		-- Send FIRST, close never: the hub renders into this same one GUI.
		self.network:sendToServer( "sv_n_openMenu", {} )
		return
	end
	self.network:sendToServer( "sv_n_protectionGuiAction", { action = data.action } )
end

function Game.sv_n_protectionGuiAction( self, data, player )
	if type( data ) ~= "table" then return end
	if player ~= sm.player.getHostPlayer() then return end

	-- Every one of these is a WORLD command -- protection walks bodies, and a
	-- Game script has no world. They come back through sv_e_swPanelRefresh with
	-- whatever the world said collected into the status line.
	-- QUOTED KEYS, deliberately. every_button_reaches_a_branch looks for the
	-- action as a string literal in this file, and a bare table key is not one --
	-- so `nolift = ...` reads to the check exactly like an action nothing
	-- handles. It flagged this the first time it ran, which is the check doing
	-- its job: the rule is that a name on one side of the bridge and nowhere on
	-- the other is always a bug, and the cheap way to keep that true is to write
	-- the name as a name.
	local send = {
		["lockdown"]     = { "/lockdown", { "/lockdown" } },
		["lockdownshow"] = { "/lockdown", { "/lockdown", "display" } },
		["unlock"]       = { "/unlock", { "/unlock" } },
		["nolift"]       = { "/nolift", { "/nolift" } },
		["clearclay"]    = { "/clearclay", { "/clearclay" } },
	}
	if data.action == "hostbuild" then
		-- A setting rather than a world command: it changes what the resolver
		-- decides, and the patrol picks that up on its next pass without being
		-- told. Sv_Set runs the apply hooks and writes the file.
		Settings.Sv_SetQuiet( "hostbuild", data.on == true )
		self:sv_toWorld( "/settingschanged", {}, player )
		self:sv_openProtectionGui( player, data.on
			and "your bubble is ON -- the ground where you stand is unlocked"
			or "your bubble is OFF -- the lockdown binds you too" )
		return
	end

	local job = send[data.action]
	if job == nil then return end
	self:sv_toWorld( job[1], job[2], player, { panel = "protection" } )
end

--[[ the dev tools panel ]]

function Game.sv_openDevGui( self, player, status )
	if player ~= sm.player.getHostPlayer() then return end
	-- The same question the menu asked, asked again where it counts. A client
	-- that never opened the menu can still send this, so the mode is checked
	-- here rather than trusted from the fact that a panel was drawn.
	if not Settings.DeveloperOn() then return end

	-- The crowd and the benchmark both live in the WORLD -- bots are units and a
	-- Game script has no world. Read through the shared globals, guarded, the
	-- same way the protection and backups panels do.
	local bots, mode, bench = 0, "off", nil
	if g_swCrowd then
		local ok, st = pcall( g_swCrowd.sv_status, g_swCrowd )
		if ok and st then
			bots = st.count or 0
			mode = st.mode or "off"
		end
	end
	if g_swBench then
		local ok, line = pcall( g_swBench.sv_status, g_swBench )
		if ok then bench = line end
	end

	self.network:sendToClient( player, "client_openDevGui", {
		bots = bots,
		mode = mode,
		bench = bench,
		bridge = Settings.Get( "bridge" ) == true,
		status = status,
	} )
end

function Game.client_openDevGui( self, state )
	if self.cl == nil then self.cl = {} end
	self.cl.devState = state
	self:cl_showPanel( "dev", DevGui.Build( state ) )
end

function Game.cl_onDevGuiClose( self )
	self:cl_forgetPanel()
	if self.cl then self.cl.devState = nil end
end

function Game.cl_onDevGuiClick( self, widgetName, data )
	if type( data ) ~= "table" or self.cl == nil then return end
	if self.cl.devState == nil then return end

	if data.action == "close" then
		self:cl_closeLater( "panel" )
		return
	end
	if data.action == "back" then
		self.network:sendToServer( "sv_n_openMenu", {} )
		return
	end
	self.network:sendToServer( "sv_n_devGuiAction", {
		action = data.action, size = data.size, mode = data.mode,
		how = data.how, on = data.on } )
end

function Game.sv_n_devGuiAction( self, data, player )
	if type( data ) ~= "table" then return end
	if player ~= sm.player.getHostPlayer() then return end
	-- The same question the menu asked, asked again where it counts. A client
	-- that never opened the menu can still send this, so the mode is checked
	-- here rather than trusted from the fact that a panel was drawn.
	if not Settings.DeveloperOn() then return end

	if data.action == "crowd" then
		local n = math.floor( tonumber( data.size ) or 0 )
		local arg = ( n <= 0 ) and "off" or tostring( n )
		self:sv_toWorld( "/crowd", { "/crowd", arg }, player, { panel = "dev" } )

	elseif data.action == "crowdmode" then
		self:sv_toWorld( "/crowd", { "/crowd", "mode", tostring( data.mode ) },
			player, { panel = "dev" } )

	elseif data.action == "bench" then
		self:sv_toWorld( "/bench", { "/bench", tostring( data.how ) }, player,
			{ panel = "dev" } )

	elseif data.action == "bridge" then
		-- Not a world command: the bridge is a Game-side file watcher.
		self:sv_bridgeCommand( { "/bridge", data.on and "on" or "off" }, player,
			function( line )
				self:sv_openDevGui( player, tostring( line ) )
			end )
	end
end

--[[ moderation, in one place ]]

-- KICK, BAN, UNBAN and ALLOW each used to live only inside the chat command
-- that ran them. The people panel needs the same four, and a second copy of
-- "ban unless it is the host, then broadcast, then log" is how the two drift --
-- so each is a method returning ( ok, message ) and both callers use it.
--
-- The message is what the caller shows: chat for a command, the panel's status
-- line for a button. Neither replies on its own.

function Game.sv_doKick( self, token )
	local target, name = resolveTarget( token )
	if target == nil then
		return false, string.format( "'%s' is not here", tostring( token ) )
	end
	if target == sm.player.getHostPlayer() then
		return false, "You cannot kick the host."
	end
	sm.log.info( "[ServerWorks] kicking " .. tostring( name ) )
	sm.game.kickPlayer( target )
	self:sv_broadcast( name .. " was kicked." )
	return true, name .. " was kicked."
end

function Game.sv_doBan( self, token, reason )
	local target, name = resolveTarget( token )
	if target == sm.player.getHostPlayer() then
		return false, "You cannot ban the host."
	end
	local ok, detail = Identity.Sv_Ban( name, reason or "" )
	if not ok then return false, detail end
	sm.log.info( "[ServerWorks] banned " .. tostring( name ) )
	if target and sm.exists( target ) then
		sm.game.banPlayer( target )
		self:sv_broadcast( name .. " was banned." )
		return true, detail
	end
	-- A ban on somebody who is not here is still a ban: Identity checks it on
	-- join, so they are refused whenever they next turn up.
	return true, detail .. "  (not online -- they will be kicked if they join)"
end

function Game.sv_doUnban( self, token )
	local _, detail = Identity.Sv_Unban( token )
	return true, detail
end

function Game.sv_doAllow( self, token, allowed )
	local target, name = resolveTarget( token )
	local ok, detail = Identity.Sv_SetAllowed( name or token, allowed )
	if ok and not allowed and Settings.Get( "allowlist" ) then
		local victim = resolveTarget( token )
		if victim and sm.exists( victim ) and victim ~= sm.player.getHostPlayer() then
			-- Taken off the allow list, not banned: a kick, not a ban.
			table.insert( self.sv.kickQueue, { player = victim, ban = false } )
		end
	end
	return ok, detail
end


--[[ the tutorial ]]

-- OPEN TO EVERYBODY, and that is the point of it. A builder who has just joined
-- an event is the person who most needs to be told that a plot has to be
-- claimed, and they have exactly one chat command.
--
-- The server decides `host` and `developer`, the same way sv_openMenu does. A
-- client that lies about either gets to READ two more pages of prose, which is
-- the one place in this mod where that costs nothing.
function Game.sv_openTutorialGui( self, player, section, page, status )
	local isHost = ( player == sm.player.getHostPlayer() )
	local dev = Settings.DeveloperOn()
	self.network:sendToClient( player, "client_openTutorialGui", {
		host = isHost,
		developer = dev,
		-- Clamped on the SERVER as well as in the panel. The panel is drawn on
		-- the reader's machine, so the only copy of this decision that a client
		-- cannot edit is this one.
		section = Tutorial.SectionFor( section, isHost, dev ),
		page = page,
		status = status,
	} )
end

function Game.client_openTutorialGui( self, state )
	if self.cl == nil then self.cl = {} end
	self.cl.tutorialState = state
	self:cl_showPanel( "howto", TutorialGui.Build( state ) )
end

function Game.cl_onTutorialClose( self )
	self:cl_forgetPanel()
	if self.cl then self.cl.tutorialState = nil end
end

function Game.cl_onTutorialClick( self, widgetName, data )
	if type( data ) ~= "table" or self.cl == nil then return end
	local state = self.cl.tutorialState
	if state == nil then return end

	if data.action == "close" then
		self:cl_closeLater( "panel" )
		return
	end
	if data.action == "back" then
		self.network:sendToServer( "sv_n_openMenu", {} )
		return
	end
	if data.action == "page" or data.action == "section" then
		-- Local. Nothing on this panel changes anything on the server, so a
		-- round trip would only add a tick of latency to turning a page.
		-- cl_renderLater rather than a direct render: building a new tree
		-- destroys the widget whose callback is running.
		--
		-- Switching section starts at page one: carrying page 4 across into a
		-- section with two pages would land on the last one, which reads as the
		-- button having done something odd.
		if data.action == "section" then
			state.section = data.section
			state.page = 1
		else
			state.page = data.page
		end
		self:cl_renderLater( "howto", TutorialGui.Build( state ) )
	end
end

--[[ the people panel ]]

-- OPEN TO A GUEST, and it is the only host-shaped panel that is. The roster is
-- what /players always gave anybody, and a lobby knowing who is in it is fair.
-- What the host check decides is whether the BUTTONS are drawn -- and the
-- actions behind them are gated again on the server, so a client that lies
-- about being the host gets buttons that refuse.
function Game.sv_openPeopleGui( self, player, status, view, page, query )
	local isHost = ( player == sm.player.getHostPlayer() )
	self.network:sendToClient( player, "client_openPeopleGui", {
		host = isHost,
		players = self:sv_focusRoster(),
		bans = isHost and Identity.Sv_BanList() or {},
		-- EVERYONE THE SERVER HAS EVER SEEN, so banning is a click on a row
		-- rather than a name typed exactly. Host only: it is the whole history
		-- of who has been here, which is not a lobby's business.
		known = isHost and Identity.Sv_KnownList() or {},
		allowlist = Settings.Get( "allowlist" ) == true,
		-- The panel a host opens when somebody says they cannot get in.
		join = isHost and Settings.JoinModeLine() or nil,
		view = isHost and view or "here",
		page = page,
		query = isHost and query or nil,
		status = status,
	} )
end

function Game.client_openPeopleGui( self, state )
	if self.cl == nil then self.cl = {} end
	self.cl.peopleState = state
	self:cl_showPanel( "people", PeopleGui.Build( state ) )
end

function Game.cl_onPeopleGuiClose( self )
	self:cl_forgetPanel()
	if self.cl then self.cl.peopleState = nil end
end

function Game.cl_onPeopleGuiClick( self, widgetName, data )
	if type( data ) ~= "table" or self.cl == nil then return end
	local state = self.cl.peopleState
	if state == nil then return end

	if data.action == "close" then
		self:cl_closeLater( "panel" )
		return
	end
	if data.action == "back" then
		self.network:sendToServer( "sv_n_openMenu", {} )
		return
	end
	if data.action == "page" or data.action == "view" then
		-- Local. Neither changes anything on the server, and cl_renderLater
		-- rather than a direct render because building a new tree destroys the
		-- widget whose callback is running.
		if data.action == "view" then
			state.view = data.view
			state.page = 1
		else
			state.page = data.page
		end
		self:cl_renderLater( "people", PeopleGui.Build( state ) )
		return
	end

	self.network:sendToServer( "sv_n_peopleGuiAction", {
		action = data.action, name = data.name, on = data.on,
		view = state.view, page = state.page, query = state.query } )
end

-- THE BOX FILTERS. It never bans, and nothing it contains is ever a target --
-- the BAN button on a row carries a perma id, and that is the only thing that
-- bans. So a stray Return costs a narrowed list and nothing else.
--
-- It also may not touch the GUI at all -- not render, not close, not defer a
-- render by a tick. Both were tried on the event clock and the second one
-- crashed the game outright. So this sends and returns, and the panel that
-- comes back from the server is what shows the filtered list. Same shape as
-- cl_onFocusSearchTyped, which is the proven one.
function Game.cl_onPeopleSearchTyped( self, widgetName, text )
	local ok, err = pcall( function()
		local state = self.cl and self.cl.peopleState
		if state == nil then return end
		if widgetName ~= PeopleGui.SEARCH_BOX then return end
		self.network:sendToServer( "sv_n_peopleGuiAction", {
			action = "search", name = tostring( text or "" ),
			view = state.view, page = 1 } )
	end )
	if not ok and not ( self.cl and self.cl.peopleSearchFaulted ) then
		if self.cl then self.cl.peopleSearchFaulted = true end
		sm.log.warning( "[ServerWorks] people search failed: " .. tostring( err ) )
	end
end

function Game.sv_n_peopleGuiAction( self, data, player )
	if type( data ) ~= "table" then return end
	if player ~= sm.player.getHostPlayer() then return end

	local token = tostring( data.name or "" )

	-- The allow list SWITCH, as opposed to its membership. No token: it is the
	-- setting rather than a person.
	--
	-- It goes through the same Sv_Set every other setting does, so the
	-- broadcast, the log line and the world's re-read all happen exactly as
	-- they would from /set or the settings panel. A second way to write a
	-- setting is how two ways to write it drift apart.
	if data.action == "allowlist" then
		local ok, detail = Settings.Sv_Set( "allowlist", data.on and "on" or "off" )
		if ok then
			self:sv_toWorld( "/settingschanged", {}, player )
			self:sv_broadcast( "Server setting changed: " .. detail )
		end
		self:sv_openPeopleGui( player, detail, data.view, data.page, data.query )
		return
	end

	-- Filtering is the one action allowed to be empty: clearing the box is how
	-- you get the whole list back.
	if data.action == "search" then
		self:sv_openPeopleGui( player, nil, "known", 1, token )
		return
	end

	if token == "" then return end

	local ok, status
	if data.action == "kick" then
		ok, status = self:sv_doKick( token )
	elseif data.action == "ban" then
		ok, status = self:sv_doBan( token, "" )
	elseif data.action == "unban" then
		ok, status = self:sv_doUnban( token )
	elseif data.action == "allow" then
		ok, status = self:sv_doAllow( token, true )
	elseif data.action == "unallow" then
		ok, status = self:sv_doAllow( token, false )
	else
		return
	end
	self:sv_openPeopleGui( player, status, data.view, data.page, data.query )
end

--[[ the backups panel ]]

function Game.sv_openBackupsGui( self, player, status )
	if player ~= sm.player.getHostPlayer() then return end

	-- The index lives in the WORLD -- a Game script has no world and cannot
	-- touch a body, so capture and restore both live there. Game and World share
	-- one Lua environment, which is the same route sv_openPlotsGui uses to read
	-- the live grid, and it is guarded for the same reason: this panel can be
	-- opened before the world has finished creating them.
	local saves, busy = {}, nil
	if g_swSnapshots then
		local ok, list = pcall( g_swSnapshots.sv_list, g_swSnapshots )
		if ok and list then saves = list end
		local okp, progress = pcall( g_swSnapshots.sv_progress, g_swSnapshots )
		if okp then busy = progress end
	end

	self.network:sendToClient( player, "client_openBackupsGui", {
		saves = saves,
		busy = busy,
		autosave = Settings.Get( "autosave" ),
		status = status,
	} )
end

function Game.client_openBackupsGui( self, state )
	if self.cl == nil then self.cl = {} end
	self.cl.backupsState = state
	self:cl_showPanel( "backups", BackupsGui.Build( state ) )
end

function Game.cl_onBackupsGuiClose( self )
	self:cl_forgetPanel()
	if self.cl then self.cl.backupsState = nil end
end

function Game.cl_onBackupsGuiClick( self, widgetName, data )
	if type( data ) ~= "table" or self.cl == nil then return end
	local state = self.cl.backupsState
	if state == nil then return end

	if data.action == "close" then
		self:cl_closeLater( "panel" )
		return
	end
	if data.action == "back" then
		self.network:sendToServer( "sv_n_openMenu", {} )
		return
	end
	if data.action == "page" then
		-- Local. Paging changes nothing on the server and a round trip for it
		-- would be a visible stutter. cl_renderLater, never a direct render:
		-- building a new tree destroys the widget whose callback is running.
		state.page = data.page
		self:cl_renderLater( "backups", BackupsGui.Build( state ) )
		return
	end

	self.network:sendToServer( "sv_n_backupsGuiAction",
		{ action = data.action, name = data.name } )
end

function Game.sv_n_backupsGuiAction( self, data, player )
	if type( data ) ~= "table" then return end
	if player ~= sm.player.getHostPlayer() then return end

	if data.action == "snapshot" then
		self:sv_toWorld( "/snapshot", { "/snapshot", "manual" }, player,
			{ panel = "backups" } )
		return
	end

	if data.action == "restore" then
		-- TWO DOORS, the same as CLEAR CITY, and for a bigger reason.
		--
		-- "/restore deletes the world before it rebuilds." Anything not in the
		-- snapshot does not come back -- including a creation somebody has on a
		-- lift, which is deliberately never captured. A fat-fingered restore
		-- mid-event beats the griefer it was reached for.
		local name = tostring( data.name or "" )
		if name == "" then return end
		self:sv_askConfirm( player, "restore",
			"PUT THE WORLD BACK?",
			{ "restoring: " .. name,
			  "everything in the world now is DELETED first",
			  "anything not in this save does not come back",
			  "a creation somebody has on a lift is not in any save" },
			"backups", name )
		return
	end
end

--[[ the focus panel ]]

function Game.sv_openFocusGui( self, player, status, query, page )
	if player ~= sm.player.getHostPlayer() then return end

	local f = self.sv.focus
	local focus = nil
	if f ~= nil and f.player ~= nil and sm.exists( f.player ) then
		focus = { id = f.player.id, name = f.name }
	end

	self.network:sendToClient( player, "client_openFocusGui", {
		players = self:sv_focusRoster(),
		bots = self.sv.crowdCount or 0,
		query = query,
		page = page,
		focus = focus,
		status = status,
	} )
end

function Game.client_openFocusGui( self, state )
	if self.cl == nil then self.cl = {} end
	self.cl.focusState = state
	self:cl_showPanel( "focus", FocusGui.Build( state ) )
end

function Game.cl_onFocusGuiClose( self )
	self:cl_forgetPanel()
	if self.cl then self.cl.focusState = nil end
end

-- ONLY CLOSE AND BACK CLOSE THE PANEL. Everything else runs and the panel stays
-- put with a status line saying what happened -- see the note in CLAUDE.md
-- about a panel that closes on every click being indistinguishable from a
-- broken one.
--
-- And nothing in here calls cl_showPanel or a closer directly: close() destroys
-- the widget whose callback is on the Lua stack. dev/test_logic.py asserts it.
function Game.cl_onFocusGuiClick( self, widgetName, data )
	if type( data ) ~= "table" or self.cl == nil then return end
	local state = self.cl.focusState
	if state == nil then return end

	if data.action == "close" then
		self:cl_closeLater( "panel" )
		return
	end
	if data.action == "back" then
		-- Send FIRST. The hub renders into this same one GUI, so queueing a
		-- close here would race the panel that is about to arrive.
		self.network:sendToServer( "sv_n_openMenu", {} )
		return
	end
	if data.action == "page" then
		-- Local, because paging changes nothing on the server and a round trip
		-- for it would be a visible stutter. cl_renderLater, never a direct
		-- render: ConfirmGui does exactly this from its own click handler.
		state.page = data.page
		self:cl_renderLater( "focus", FocusGui.Build( state ) )
		return
	end

	self.network:sendToServer( "sv_n_focusGuiAction", {
		action = data.action, id = data.id,
		query = state.query, page = state.page } )
end

-- A typed search. ( self, widgetName, text ) -- a text event carries no
-- onClickData, so the widget NAME is the only thing that says which box it was.
-- Signature from DigitalSign.lua:157.
--
-- IT DRAWS NOTHING. Not a render, not a deferred render, not a close. The event
-- clock crashed the game twice over exactly this, and the second crash was
-- AFTER the redraw had already been deferred by a tick, so deferring is not
-- known to be enough. Sending IS safe -- cl_onMenuClick sends from inside a
-- click callback and that is the ordering vanilla itself uses -- so the search
-- is a round trip, and the panel is rebuilt by client_openFocusGui, which is a
-- network callback rather than this widget's own.
function Game.cl_onFocusSearchTyped( self, widgetName, text )
	local ok, err = pcall( function()
		if self.cl == nil or self.cl.focusState == nil then return end
		if widgetName ~= FocusGui.SEARCH_BOX then return end
		local query = tostring( text or "" )
		self.cl.focusState.query = query
		self.cl.focusState.page = 1
		self.network:sendToServer( "sv_n_focusGuiAction",
			{ action = "search", query = query, page = 1 } )
	end )
	if not ok and not ( self.cl and self.cl.focusSearchFaulted ) then
		if self.cl then self.cl.focusSearchFaulted = true end
		sm.log.warning( "[ServerWorks] focus search failed: " .. tostring( err ) )
	end
end

function Game.sv_n_focusGuiAction( self, data, player )
	if type( data ) ~= "table" then return end
	if player ~= sm.player.getHostPlayer() then return end

	local status = nil
	local query, page = data.query, data.page

	if data.action == "focus" then
		local target = self:sv_focusPlayerById( tonumber( data.id ) )
		if target == nil then
			status = "that player has left"
		else
			self:sv_setFocus( target, player )
			status = string.format( "focusing %s -- everyone can see the marker",
				tostring( target.name ) )
		end

	elseif data.action == "clear" then
		if self.sv.focus == nil then
			status = "nobody was focused"
		else
			local was = self.sv.focus.name
			self:sv_setFocus( nil, player )
			status = string.format( "cleared -- %s is no longer marked", tostring( was ) )
		end

	elseif data.action == "search" then
		local matched = FocusGui.Filter( self:sv_focusRoster(), query )
		status = ( tostring( query or "" ) == "" )
			and "showing everyone"
			or string.format( "%d name%s matched", #matched,
				#matched == 1 and "" or "s" )
		page = 1
	end

	self:sv_openFocusGui( player, status, query, page )
end


--[[ the bridge -- driving a session from outside the game ]]

-- See Bridge.lua for the whole argument. In short: the slow part of this
-- project is the round trip, not the work, and $CONTENT_DATA is the one place
-- both sides can reach. A file appears, it gets run as the host, everything
-- said in the next second and a half is written back out.

function Game.sv_bridgeSay( self, text )
	local b = self.sv and self.sv.bridge
	if b == nil then return end
	Bridge.sv_capture( b, text )
end

-- Called from server_onFixedUpdate inside its own pcall.
function Game.sv_bridgeTick( self, tick )
	local b = self.sv and self.sv.bridge
	if b == nil then return end

	-- A batch that has run and is still LISTENING. Nothing else happens until
	-- its clock runs out -- not another poll, not another batch -- so replies
	-- can never be filed under the wrong command.
	if b.pending ~= nil then
		if tick < b.pending.deadline then return end
		local done = b.pending
		b.pending = nil
		local lines = b.capture or {}
		b.capture = nil
		Bridge.sv_writeResult( b, done.seq, done.entries, done.note, lines )
		b.seq = done.seq + 1
		Bridge.sv_save( b, true )
		sm.log.info( string.format(
			"[ServerWorks] bridge: wrote Out-%d.json -- %d command(s), %d line(s) said",
			done.seq, #done.entries, #lines ) )
		return
	end

	-- BOTH switches, and the second one is derived rather than written. See
	-- Settings.BridgeOpen: /developer off shuts this door without overwriting
	-- the host's own `bridge` choice, so switching developer back on gives back
	-- exactly what they had -- which is the mistake V52's lockdown made with
	-- four tool settings and could not undo.
	if not Settings.BridgeOpen() then return end
	if tick < ( b.nextPoll or 0 ) then return end
	b.nextPoll = tick + Bridge.POLL_TICKS

	-- Everything runs AS THE HOST, so every host gate in the mod still applies
	-- and the bridge can reach nothing a host could not type. No host, no
	-- bridge -- which also means a dedicated-server-shaped future would have to
	-- decide this again rather than inherit it.
	local host = sm.player.getHostPlayer()
	if host == nil or not sm.exists( host ) then return end

	local data = Bridge.sv_poll( b )
	if data == nil then return end
	self:sv_bridgeRun( b, data, host, tick )
end

function Game.sv_bridgeRun( self, b, data, host, tick )
	local batch = Bridge.Parse( data )
	local entries = {}

	-- Open BEFORE the first command, closed by the clock in sv_bridgeTick.
	b.capture = {}

	for _, words in ipairs( batch ) do
		local line = table.concat( words, " " )
		-- In the log before it runs, not after. If a command takes the server
		-- down, the last line in the log is the one that did it.
		sm.log.info( "[ServerWorks] bridge runs: " .. line )
		local ok, err = pcall( function()
			self:sv_n_adminCommand( words, host )
		end )
		if not ok then
			sm.log.warning( "[ServerWorks] bridge command failed: " .. line
				.. " -- " .. tostring( err ) )
		end
		entries[#entries + 1] = {
			command = line,
			ok = ok and true or false,
			error = ( not ok ) and tostring( err ) or nil,
		}
		b.ran = ( b.ran or 0 ) + 1
	end

	local wait = Bridge.Wait( data )
	b.pending = {
		seq = b.seq,
		entries = entries,
		note = data.note,
		deadline = tick + math.floor( wait * TICKS_PER_SECOND ),
	}
	sm.log.info( string.format(
		"[ServerWorks] bridge: Cmd-%d.json -- %d command(s), listening %.1fs",
		b.seq, #batch, wait ) )
end

-- /bridge on|off|status. Host only, like everything else that can change a
-- world -- and unlike the rest, this one can change it from outside the game,
-- which is why it says so out loud when it is switched on.
function Game.sv_bridgeCommand( self, params, player, reply )
	local b = self.sv and self.sv.bridge
	if b == nil then
		reply( "the bridge did not start with this world" )
		return
	end
	local what = params[2]

	if what == "on" or what == "off" then
		local on = ( what == "on" )
		-- The word, not the boolean. Sv_Set parses "on"/"off" for a bool and
		-- tostring( true ) only happens to land on a value it accepts.
		Settings.Sv_Set( "bridge", what )
		Bridge.sv_save( b, on )
		if on then
			reply( "BRIDGE ON -- this world can now be driven from outside." )
			reply( "It runs commands as you, and everything it runs is in the log." )
			reply( string.format( "waiting for %s", Bridge.CmdPath( b.seq ) ) )
			sm.log.info( "[ServerWorks] bridge ON -- waiting for "
				.. Bridge.CmdPath( b.seq ) )
		else
			reply( "bridge off -- nothing outside the game can reach this world." )
			sm.log.info( "[ServerWorks] bridge OFF" )
		end
		return
	end

	-- The switch and the door are two different questions and /bridge status is
	-- the one place both have to be answered, because they can disagree: the
	-- setting says ON while developer mode holds it shut. Printing only one of
	-- them is how "it says it is on and nothing happens" gets reported.
	local on = ( Settings.Get( "bridge" ) == true )
	reply( string.format( "bridge %s   waiting for %s   %d command(s) run",
		Settings.BridgeOpen() and "ON"
			or ( on and "on, but SHUT while developer mode is off" or "off" ),
		Bridge.CmdPath( b.seq ), b.ran or 0 ) )
	if b.pending ~= nil then
		reply( "  a batch is still listening" )
	end
	reply( "/bridge on | off | status" )
end

--[[ the dev checklist ]]

-- ASKED FOR: "you make an ingame check list. for devs. so I can test stuff ...
-- because if I have to switch every time here. I waste my time if the feature
-- is still broken on writing it again."
--
-- The catalogue and the arithmetic are in Checklist.lua and the panel is in
-- ChecklistGui.lua; what lives here is the state, which is the part that has to
-- be on the server. A result is written the moment a button is pressed rather
-- than batched at the end, because the way a test session actually ends is that
-- the game crashes or somebody stops playing.

function Game.sv_checklist( self )
	if self.sv.checklist == nil then
		self.sv.checklist = Checklist.Sv_Load()
	end
	return self.sv.checklist
end

-- os.time is guarded everywhere else in this project and is guarded here for
-- the same reason: the sandbox's `os` is not documented anywhere and a
-- checklist that cannot record a result because a clock is missing would be a
-- poor sort of test harness. A result with no timestamp is still a result.
local function checklistNow()
	local ok, t = pcall( os.time )
	return ok and t or nil
end

function Game.sv_openChecklistGui( self, player, status, view )
	if player ~= sm.player.getHostPlayer() then return end
	-- The same question the menu asked, asked again where it counts. A client
	-- that never opened the menu can still send this, so the mode is checked
	-- here rather than trusted from the fact that a panel was drawn.
	if not Settings.DeveloperOn() then return end
	view = view or {}
	self.network:sendToClient( player, "client_openChecklistGui", {
		results = self:sv_checklist(),
		group = view.group,
		page = view.page,
		item = view.item,
		build = Checklist.BUILD,
		status = status,
	} )
end

function Game.client_openChecklistGui( self, state )
	if self.cl == nil then self.cl = {} end
	self.cl.checklistState = state
	self:cl_showPanel( "checklist", ChecklistGui.Build( state ) )
end

function Game.cl_onChecklistClose( self )
	self:cl_forgetPanel()
	if self.cl then self.cl.checklistState = nil end
end

-- ONLY CLOSE AND BACK CLOSE THE PANEL, and nothing in here renders directly:
-- close() and render() both destroy the widget whose callback is on the Lua
-- stack. cl_renderLater is the only route -- see the long note at
-- Game.cl_closeLater for what that cost to learn.
function Game.cl_onChecklistClick( self, widgetName, data )
	if type( data ) ~= "table" or self.cl == nil then return end
	local state = self.cl.checklistState
	if state == nil then return end

	if data.action == "close" then
		self:cl_closeLater( "panel" )
		return
	end
	if data.action == "back" then
		-- Send FIRST. The hub renders into this same one GUI, so queueing a
		-- close here would race the panel that is about to arrive.
		self.network:sendToServer( "sv_n_openMenu", {} )
		return
	end

	-- Paging, switching group and opening an item change NOTHING on the server:
	-- the whole results table is already on this client, so a round trip for a
	-- page turn would be a visible stutter for no gain. Everything that writes
	-- a result goes to the server, because the server owns the file.
	if data.action == "page" then
		state.page = data.page
		self:cl_renderLater( "checklist", ChecklistGui.Build( state ) )
		return
	end
	if data.action == "group" then
		state.group = data.group
		state.page = 1
		state.item = nil
		state.status = nil
		self:cl_renderLater( "checklist", ChecklistGui.Build( state ) )
		return
	end
	if data.action == "open" then
		state.item = data.id
		self:cl_renderLater( "checklist", ChecklistGui.Build( state ) )
		return
	end
	if data.action == "list" then
		state.item = nil
		self:cl_renderLater( "checklist", ChecklistGui.Build( state ) )
		return
	end

	self.network:sendToServer( "sv_n_checklistAction", {
		action = data.action, id = data.id, state = data.state,
		group = state.group, page = state.page, item = state.item } )
end

-- A typed note. ( self, widgetName, text ) -- a text event carries no
-- onClickData, so the widget NAME is the only thing that says which box it was.
--
-- IT DRAWS NOTHING: not a render, not a deferred render, not a close. The event
-- clock crashed the game twice over exactly this, and the second crash was
-- after the redraw had already been deferred by a tick. Sending IS safe, so the
-- note is a round trip and the panel is rebuilt by client_openChecklistGui,
-- which is a network callback rather than this widget's own.
function Game.cl_onChecklistNoteTyped( self, widgetName, text )
	local ok, err = pcall( function()
		local state = self.cl and self.cl.checklistState
		if state == nil then return end
		if widgetName ~= ChecklistGui.NOTE_BOX then return end
		self.network:sendToServer( "sv_n_checklistAction", {
			action = "note", id = state.item, note = tostring( text or "" ),
			group = state.group, page = state.page, item = state.item } )
	end )
	if not ok and not ( self.cl and self.cl.checklistNoteFaulted ) then
		if self.cl then self.cl.checklistNoteFaulted = true end
		sm.log.warning( "[ServerWorks] checklist note failed: " .. tostring( err ) )
	end
end

-- Saving on every press rather than at the end. A test session ends when the
-- game crashes or when somebody stops playing, and neither of those runs a
-- shutdown hook -- so anything held in memory is exactly the data that would be
-- lost by the failure it was recording.
function Game.sv_recordChecklist( self, id, state, player )
	local item = Checklist.Find( id )
	if item == nil then return nil end
	Checklist.Set( self:sv_checklist(), id, state, nil, Checklist.BUILD, checklistNow() )
	Checklist.Sv_Save( self:sv_checklist() )
	-- In the log as well as in the file, because the log is where every other
	-- piece of evidence about a session already is: a FAIL and the traceback
	-- that caused it end up four lines apart.
	sm.log.info( string.format( "[ServerWorks] checklist %s = %s  (%s)",
		tostring( id ), string.upper( tostring( state ) ), tostring( item.title ) ) )
	return item
end

function Game.sv_n_checklistAction( self, data, player )
	if type( data ) ~= "table" then return end
	if player ~= sm.player.getHostPlayer() then return end
	-- The same question the menu asked, asked again where it counts. A client
	-- that never opened the menu can still send this, so the mode is checked
	-- here rather than trusted from the fact that a panel was drawn.
	if not Settings.DeveloperOn() then return end

	local results = self:sv_checklist()
	local view = { group = data.group, page = data.page, item = data.item }
	local status = nil

	if data.action == "mark" then
		local item = self:sv_recordChecklist( data.id, data.state, player )
		if item == nil then
			status = "no such item: " .. tostring( data.id )
		else
			status = string.format( "%s -- %s", string.upper( tostring( data.state ) ),
				tostring( item.title ) )
			-- ON THE DETAIL VIEW, ANSWERING MOVES YOU ON. That is the whole
			-- shape of a test session: do it, answer it, next. On the LIST it
			-- must not, or marking the second row would jump the page out from
			-- under the hand that is about to mark the third.
			if view.item ~= nil then
				local nextId = Checklist.NextUntested( results, view.item, false )
				if nextId ~= nil then
					local nextItem = Checklist.Find( nextId )
					view.item = nextId
					view.group = nextItem.group
					status = status .. "   >>   " .. tostring( nextItem.title )
				else
					view.item = nil
					status = status .. "   -- nothing unanswered left"
				end
			end
		end

	elseif data.action == "clearmark" then
		Checklist.Set( results, data.id, nil )
		Checklist.Sv_Save( results )
		status = "cleared -- back to unanswered"

	elseif data.action == "note" then
		Checklist.SetNote( results, data.id, data.note )
		Checklist.Sv_Save( results )
		status = ( tostring( data.note or "" ) == "" )
			and "note cleared"
			or ( "note saved: " .. tostring( data.note ) )

	elseif data.action == "next" then
		local nextId = Checklist.NextUntested( results, view.item, false )
		if nextId == nil then
			-- Everything a host can answer alone IS answered. Say what is left
			-- rather than "done", because the guest group is not done, it is
			-- waiting for somebody.
			local c = Checklist.Counts( results, "guest" )
			view.item = nil
			status = string.format( "nothing left that one person can answer -- "
				.. "%d of %d in NEEDS A GUEST still open", c.untested, c.total )
		else
			local item = Checklist.Find( nextId )
			view.item = nextId
			view.group = item.group
			status = "next: " .. tostring( item.title )
		end

	elseif data.action == "run" then
		local item = Checklist.Find( data.id )
		if item == nil or item.run == nil then
			status = "nothing to run for this one"
		else
			local words = ""
			for _, w in ipairs( item.run ) do
				words = ( words == "" ) and tostring( w ) or ( words .. " " .. tostring( w ) )
			end
			-- Straight through the normal command path, host gate and all, so
			-- the panel can never reach a command a typed one could not. The
			-- answer arrives in CHAT, because that is where that path replies.
			self:sv_n_adminCommand( item.run, player )
			status = "sent " .. words .. " -- the answer is in chat"
		end

	elseif data.action == "logdump" then
		local lines = Checklist.Summary( results )
		for _, line in ipairs( lines ) do
			sm.log.info( "[ServerWorks] " .. line )
			self.network:sendToClient( player, "client_showMessage", line )
		end
		status = "written to chat and to the log"
	end

	self:sv_openChecklistGui( player, status, view )
end

-- `arg` names WHICH thing, for a confirmation where "what" is not enough on its
-- own. CLEAR CITY has exactly one meaning; RESTORE has one per save, and a
-- dialog that asks "are you sure" without carrying the answer to "sure about
-- what" would restore whatever the server guessed.
function Game.sv_askConfirm( self, player, what, title, lines, back, arg )
	self.network:sendToClient( player, "client_openConfirm",
		{ step = 1, what = what, title = title, lines = lines, back = back,
		  arg = arg } )
end

function Game.client_openConfirm( self, state )
	if self.cl == nil then self.cl = {} end
	self.cl.confirm = state
	-- Modal, and free: it renders into the same one GUI, so the panel that asked
	-- the question is simply replaced by the question. `back` says what to put
	-- back afterwards.
	self:cl_showPanel( "confirm", ConfirmGui.Build( state ) )
end


function Game.cl_onConfirmClose( self )
	self:cl_forgetPanel()
	if self.cl then self.cl.confirm = nil end
end

function Game.cl_onConfirmClick( self, widgetName, data )
	if type( data ) ~= "table" or self.cl == nil or self.cl.confirm == nil then return end
	local c = self.cl.confirm
	local back = c.back
	-- "no" cancels, and so does anything unrecognised: on a dialog that deletes a
	-- city, the branch you fall into by accident has to be the safe one.
	if data.action ~= "yes" then
		sm.gui.chatMessage( ( data.action == "no" )
			and "Cancelled. Nothing was deleted."
			or "Cancelled. Nothing was deleted (unrecognised button)." )
		if back then
			-- The panel that asked comes back; do not close over the top of it.
			self.network:sendToServer( "sv_n_openPanel", { panel = back } )
		else
			self:cl_closeLater( "panel" )
		end
		return
	end
	if ( c.step or 1 ) < 2 then
		-- The first yes does not count, which is the whole point.
		c.step = 2
		self:cl_renderLater( "confirm", ConfirmGui.Build( c ) )
		return
	end
	-- The server does the work and sends the panel back with the result written
	-- on it (sv_e_swPanelRefresh), so nothing is closed here either.
	self.network:sendToServer( "sv_n_confirmed", { what = c.what, arg = c.arg } )
end

function Game.sv_n_confirmed( self, data, player )
	if player ~= sm.player.getHostPlayer() then return end
	if type( data ) ~= "table" then return end
	if data.what == "clearcity" then
		self:sv_toWorld( "/plotclear", {}, player, { panel = "city" } )
	elseif data.what == "restore" then
		local name = tostring( data.arg or "" )
		if name == "" then return end
		self:sv_toWorld( "/restore", { "/restore", name }, player,
			{ panel = "backups" } )
	end
end

-- Reopen a named panel. Used by BACK and by a cancelled confirmation.
--
-- HOST GATED, and it was not always. A json GUI is opened by the SERVER onto a
-- named client, so a modified client that sent this message itself got the
-- host's panels drawn on its own screen -- the city panel, the event clock, the
-- whole settings tree. Nothing could be CHANGED that way, because every action
-- handler behind those panels tests the sender; what leaked was the READING --
-- the server's settings, the event state, the city configuration.
--
-- myplot is the one panel a guest is entitled to, so it answers before the gate.
function Game.sv_n_openPanel( self, data, player )
	if type( data ) ~= "table" then return end

	if data.panel == "myplot" then
		self:sv_toWorld( "/myplot", {}, player )
		return
	end

	if player ~= sm.player.getHostPlayer() then return end

	if data.panel == "city" then
		self:sv_openPlotsGui( player, "nothing was deleted" )
	elseif data.panel == "event" then
		self:sv_openEventGui( player )
	elseif data.panel == "settings" then
		self:sv_openSettingsGui( player, "safety", 1 )
	elseif data.panel == "style" then
		self:sv_openStyleGui( player, nil, nil, data.back )
	elseif data.panel == "focus" then
		self:sv_openFocusGui( player )
	elseif data.panel == "protection" then
		self:sv_openProtectionGui( player )
	elseif data.panel == "backups" then
		self:sv_openBackupsGui( player )
	elseif data.panel == "people" then
		self:sv_openPeopleGui( player )
	elseif data.panel == "bans" then
		self:sv_openPeopleGui( player, nil, "known" )
	elseif data.panel == "howto" then
		self:sv_openTutorialGui( player )
	elseif data.panel == "dev" and Settings.DeveloperOn() then
		self:sv_openDevGui( player )
	end
end

function Game.cl_onPlotsGuiClick( self, widgetName, data )
	if type( data ) ~= "table" or self.cl == nil then return end
	local cfg = self.cl.plotCfg
	if cfg == nil then return end

	if data.action == "step" then
		cfg[data.key] = PlotsGui.Step( data.key, cfg[data.key], data.dir )
		cfg.status = nil                                    -- stale the moment they edit
		self:cl_renderLater( "city", PlotsGui.Build( cfg ) ) -- next tick, never now
		return
	end
	if data.action == "reset" then
		-- Layout.DEFAULT, not a second copy of it. The old copy here still said
		-- spawn = 50 months after `spawn` became `plazacells`, so DEFAULTS reset
		-- the panel to a layout the builder no longer speaks.
		local d = Layout.DEFAULT
		self.cl.plotCfg = { plot = d.plot, gap = d.gap, cols = d.cols, rows = d.rows,
			roadevery = d.roadevery, roadwidth = d.roadwidth, plazacells = d.plazacells,
			claimed = cfg.claimed or {}, mine = cfg.mine, team = cfg.team,
			status = "reset to the defaults -- nothing is built until you press BUILD" }
		self:cl_renderLater( "city", PlotsGui.Build( self.cl.plotCfg ) )
		return
	end
	if data.action == "style" then
		-- What the city is MADE of, next to what it is shaped like. BACK comes
		-- back here rather than to the hub.
		self.network:sendToServer( "sv_n_openPanel", { panel = "style", back = "city" } )
		return
	end
	if data.action == "close" then
		self:cl_closeLater( "panel" )
		return
	end
	if data.action == "back" then
		-- No close: the hub renders into this same GUI a moment from now, and a
		-- queued close would land on top of it.
		self.network:sendToServer( "sv_n_openMenu", {} )
		return
	end
	-- build and clear are the server's business. The panel STAYS OPEN; the
	-- server sends it back with a status line when the work has started.
	self.network:sendToServer( "sv_n_plotsGuiAction", { action = data.action, cfg = cfg } )
end

function Game.cl_onPlotsGuiClose( self, widgetName )
	self:cl_forgetPanel()
end


function Game.sv_n_plotsGuiAction( self, data, player )
	if player ~= sm.player.getHostPlayer() then return end
	if data.action == "clear" then
		-- Two doors, and the first one lists what is actually out there. The
		-- world has to count it, so the ask happens from there.
		self:sv_toWorld( "/citycensus", {}, player )
	elseif data.action == "build" then
		self:sv_toWorld( "/plotapply", {}, player,
			{ cfg = data.cfg, panel = "city" } )
	end
end


--[[ command dispatch ]]

-- One second of one client's frames, on its way to Bench in the world script.
--
-- GUEST REACHABLE ON PURPOSE, and it is the only handler in this mod for which
-- that is the whole point rather than a tolerance: what /bench most wants to
-- know is what the frame rate is on OTHER PEOPLE'S machines, and only their
-- machine can say. The one real event on record degraded in exactly that number
-- while the server's own tick rate never moved.
--
-- Safe to leave open because nothing here is authority. The sender is taken from
-- the third argument, never from the payload; a guest cannot claim to be the
-- host and so cannot drive the run; the numbers are validated as arithmetic in
-- Bench.sv_sample; and a client that lies only spoils the row labelled with its
-- own name. It also does nothing at all unless a bench is running.
function Game.sv_n_benchSample( self, data, player )
	if type( data ) ~= "table" or not sm.exists( player ) then return end
	local world = self:sv_world()
	if world == nil or not sm.exists( world ) then return end

	sm.event.sendToWorld( world, "sv_e_swBenchSample", {
		-- The NAME is the server's answer to who sent this, not the client's.
		name = player:getName(),
		isHost = ( player == sm.player.getHostPlayer() ),
		frames = data.frames,
		secs = data.secs,
		ticks = data.ticks,
	} )
end

function Game.sv_n_adminCommand( self, params, player, viaPanel )
	local function reply( text )
		self:sv_bridgeSay( text )
		self.network:sendToClient( player, "client_showMessage", text )
	end

	local cmd = params[1]
	local isHost = ( player == sm.player.getHostPlayer() )

	-- viaPanel IS TRUSTWORTHY BECAUSE THE NETWORK CANNOT SET IT.
	--
	-- A network callback is handed exactly ( self, data, player ) -- the engine
	-- supplies the third and there is no fourth. So a client cannot claim to be
	-- a panel; only code inside this script can, and the only code that does is
	-- the menu router acting for the player who pressed the button.
	--
	-- DEFAULT DENY, still: a command nobody classified lands on the host side in
	-- both lists, which produces "Host only" on something harmless rather than a
	-- guest running something nobody thought about.
	if not isHost then
		if viaPanel ~= true then
			if not GUEST_TYPED[cmd] then
				reply( "Chat commands are for the host. Type  /menu  instead --" )
				reply( "  your plot, the rules and who is here are all on it." )
				return
			end
		elseif not GUEST_PANEL[cmd] then
			return
		end
	end

	-- After the host gate and before anything is forwarded, because /crowd and
	-- /bench are WORLD_COMMANDS and would otherwise be gone by the next line.
	if not Settings.DevCommandAllowed( params ) then
		reply( string.format( "%s is a developer tool, and developer mode is off.",
			tostring( cmd ) ) )
		reply( "  /developer on   switches it on and puts DEV TOOLS back on the menu." )
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
		reply( "SERVER WORKS -- WORK IN PROGRESS. Expect rough edges." )
		reply( "  /menu               everything below, on buttons. Start here." )
		reply( "  /plot claim         claim the plot you are stood on" )
		reply( "  /plot info          who owns this ground" )
		reply( "  /myplot             claim, find and give up your plot, on one panel" )
		reply( "  /plot team <name>   ask a neighbour to team up (they type it back)" )
		reply( "                      front, behind, left or right only -- not diagonal." )
		reply( "                      Teams chain, so a corner joins via whoever links you." )
		reply( "  /plot leave         give up your plot" )
		reply( "  /home               teleport back to your own plot" )
		reply( "  /players            who is here     /rules  the server rules" )
		reply( "  /budget             what your plot is using, against what it is allowed" )
		if isHost then
			reply( "HOST" )
			reply( "  /preset build|show|lockdown|sandbox" )
			reply( "  /settings           open the settings panel" )
			reply( "  /settingslist  /set <name> <value>" )
			reply( "  /plotmenu           lay the city out, then build it" )
			reply( "  /citystyle          pick the blocks and colours the city is made of" )
			reply( "  /plots on|off  /plotbuild  /plotclear" )
			reply( "  /plotgrid <plot> <gap> <cols> <rows>" )
			reply( "  /event start <prep> <build>   minutes. Prep = claim only, no building" )
			reply( "  /event pause|resume|skip|add <min>|stop|status" )
			reply( "  /lockdown [display]  /unlock  /protection  /buildtime N  /autosave N" )
			reply( "  /snapshot [name]  /snapshots  /restore <name> [plot]" )
			reply( "  /purge look         delete whatever you are pointing at" )
			reply( "  /purge look 1       delete the whole creation, not one block" )
			reply( "  /purge carry        destroy whatever you picked up" )
			reply( "  /purge here <m> | /purge plot <n>" )
			reply( "  /why                point at a build, ask why it is locked" )
			reply( "  /focus <who>        mark them so the whole lobby can find them" )
			reply( "  /unfocus            take the marker off again" )
			reply( "  /ban <who>  /unban <who>  /banlist  /known  /kick <who>" )
			reply( "  /allow <who>  /unallow <who>  /allowlist" )
			-- The dev half of this list only prints while the switch is on.
			-- Forty lines of help for tools that will refuse to run is not
			-- help, and it is the same reasoning that keeps the two entries off
			-- the menu: the surface should say what is actually reachable.
			if Settings.DeveloperOn() then
				reply( "DEVELOPER -- /developer off hides all of this" )
				reply( "  /check              the dev checklist -- test it, then answer it" )
				reply( "  /check next         the next thing nobody has tried" )
				reply( "  /check summary      what is answered, and what failed" )
				reply( "  /bridge on          drive this world from outside the game" )
				reply( "LOAD TESTING -- not for a live event" )
				reply( "  /crowd <n>          stand n bots on the city, one per plot" )
				reply( "  /crowd churn on     have them place and remove blocks" )
				reply( "  /bench start        walk the crowd up, record fps and tick rate" )
				reply( "  /bench results      the table from the last run" )
			else
				reply( "  /developer on       the test tools: crowd, benchmark, checklist" )
			end
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

	elseif cmd == "/citystyle" then
		local name = params[2]
		if name == nil or name == "" then
			-- The panel is the answer to this question now; the lines below are
			-- still printed because a host who typed a command is looking at the
			-- chat log, and "a window opened somewhere" is not a reply.
			self:sv_openStyleGui( player, "pad", nil, "menu" )
			reply( "city style -- opened the picker. /citystyle <name> also works." )
			for _, line in ipairs( ( Plots and Plots.StyleLines ) and Plots.StyleLines() or {} ) do
				reply( line )
			end
			reply( "  styles: " .. table.concat( Palette.STYLE_ORDER, "  " ) )
			reply( "  /citystyle blocks   /citystyle colours   for the full lists" )
			reply( "  the picker is also on the city panel: CITY STYLE" )
			reply( "  Nothing changes until you BUILD CITY again -- the city is blueprints." )
			return
		end
		name = string.lower( name )
		if name == "blocks" then
			reply( "blocks: " .. table.concat( Palette.MATERIAL_ORDER, "  " ) )
			return
		end
		if name == "colours" or name == "colors" then
			-- Four rows of ten, the way the paint tool draws them, so a name can
			-- be found by looking at the swatch rather than by reading a list.
			for r = 1, #Palette.ROWS do
				local names = {}
				for c = 1, #Palette.ROWS[r] do
					names[#names + 1] = Palette.NameOfHex( Palette.ROWS[r][c] )
				end
				reply( "  " .. table.concat( names, " " ) )
			end
			return
		end
		local style = Palette.STYLES[name]
		if style == nil then
			reply( "no style called '" .. name .. "' -- " .. table.concat( Palette.STYLE_ORDER, ", " ) )
			return
		end
		for key, value in pairs( style ) do
			Settings.Sv_Set( key, value )
		end
		self:sv_toWorld( "/settingschanged", params, player )
		self:sv_broadcast( "City style: " .. name .. " -- BUILD CITY to apply it." )

	elseif cmd == "/menu" then
		self:sv_openMenu( player )

	elseif cmd == "/developer" then
		local arg = string.lower( tostring( params[2] or "" ) )
		if arg == "" then
			reply( string.format( "developer mode is %s.",
				Settings.DeveloperOn() and "ON" or "off" ) )
			reply( "  /developer on   adds DEV TOOLS and TESTING CHECKLIST to /menu," )
			reply( "                  and lets /crowd /bench /bridge /check run." )
			reply( "  /developer off  hides them again. Nothing else changes." )
			return
		end
		local ok, detail = Settings.Sv_Set( "developer", arg )
		if not ok then
			reply( detail )
			return
		end
		local on = Settings.DeveloperOn()
		reply( on and "Developer mode ON -- /menu now has DEV TOOLS and TESTING CHECKLIST."
			or "Developer mode off -- the dev tools are off the menu." )
		-- The bridge is DERIVED from both switches rather than written by
		-- either, so this says what just happened to it instead of changing it.
		-- Switch developer back on and the host gets back the channel they
		-- actually chose, which is the whole reason it is not written down.
		if Settings.Get( "bridge" ) == true then
			reply( on and "  Outside control is open again -- it was shut while developer mode was."
				or "  Outside control is shut while developer mode is off. It is still switched on." )
		end
		if not on then
			-- Said out loud because the command that removes them is the one
			-- that just became the only dev command still allowed, and nothing
			-- else on screen would mention it.
			local bots = self.sv.crowdCount or 0
			if bots > 0 then
				reply( string.format(
					"  %d crowd bot(s) are still standing -- /crowd off still works.", bots ) )
			end
		end
		sm.log.info( string.format( "[ServerWorks] developer mode %s",
			on and "ON" or "off" ) )

	elseif cmd == "/bridge" then
		self:sv_bridgeCommand( params, player, reply )

	elseif cmd == "/check" then
		-- The panel is the point; the words are for when your hands are already
		-- in the chat box, which during a test session they often are.
		local what = params[2]
		local results = self:sv_checklist()
		if what == nil or what == "" then
			self:sv_openChecklistGui( player )
		elseif what == "summary" or what == "status" then
			for _, line in ipairs( Checklist.Summary( results ) ) do
				reply( line )
				sm.log.info( "[ServerWorks] " .. line )
			end
		elseif what == "next" then
			local nextId = Checklist.NextUntested( results, nil, false )
			if nextId == nil then
				reply( "Nothing left that one person can answer." )
			else
				local item = Checklist.Find( nextId )
				reply( "NEXT: " .. tostring( item.title ) )
				for i, step in ipairs( item.steps or {} ) do
					reply( "  " .. i .. ". " .. tostring( step ) )
				end
				reply( "  PASSES WHEN: " .. tostring( item.pass ) )
				self:sv_openChecklistGui( player, nil,
					{ item = nextId, group = item.group } )
			end
		elseif Checklist.IsState( what ) then
			local item = self:sv_recordChecklist( params[3], what, player )
			if item == nil then
				reply( "No checklist item called " .. tostring( params[3] )
					.. " -- /check summary lists the ids that failed, the panel lists them all." )
			else
				reply( string.upper( what ) .. "  " .. tostring( item.title ) )
			end
		else
			reply( "/check | /check next | /check summary | /check pass <id> | /check fail <id>" )
		end

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
		-- TWO ENTRIES HERE HAD LOST THEIR KEYS and were array items 1 and 2, so
		-- /tool -- the command whose whole job is "say exactly which item is in
		-- your hand" -- silently could not name the Import Lift or the Cleaner,
		-- the two tools most likely to be asked about. No Lua error: a table
		-- constructor is happy to mix keyed and positional entries.
		local KNOWN = {
			["8f190ce2-3a59-423e-8483-a7aa67bd5bc0"] =
				"the lift -- it carries and raises. NOTHING in this game opens a "
					.. "creations menu from a lift; NOTlift imports instead",
			["748b6656-84b2-440f-8f4c-8cc7deeba63c"] =
				"nugdupS, the stale-mod canary. Mod content is reaching the game",
			["bbbb0cc8-5dd0-46e1-9299-8080c3cc80db"] =
				"Cleaner -- point and click to delete, hold F for the whole "
					.. "creation. Host only.",
		}
		if KNOWN[id] then reply( "  " .. KNOWN[id] ) end
		local blocked = self.sv.blockedTools[id] or self.sv.hostOnlyTools[id]
		if blocked then
			reply( string.format( "  gated by the '%s' setting", blocked ) )
		end

		-- WHAT THE SERVER CURRENTLY BLOCKS, for the host and for a guest.
		--
		-- The guard is client side -- only your own client can put a tool away
		-- -- so "is the lockdown on" has two halves that can disagree: what the
		-- server computed, and what your client was last told. REPORTED: "I
		-- still could use the lift, and the clay gun", with the world locked and
		-- claygun already false in the settings file, which the code alone could
		-- not explain. This prints the server's half so the next test can say
		-- which half is wrong instead of guessing.
		local function nameList( set )
			local seen, out = {}, {}
			for _, name in pairs( set or {} ) do
				if not seen[name] then
					seen[name] = true
					out[#out + 1] = name
				end
			end
			table.sort( out )
			return ( #out > 0 ) and table.concat( out, " " ) or "nothing"
		end
		reply( string.format( "  world is %s", Settings.WorldIsShut()
			and ( "SHUT (" .. tostring( Settings.Get( "protection" ) ) .. ") -- a guest loses every tool and every body flag" )
			or ( "open (" .. tostring( Settings.Get( "protection" ) ) .. ")" ) ) )
		reply( "  blocked for the host:  " .. nameList( self.sv.hazardTools ) )
		reply( "  blocked for a guest:   " .. nameList( self:sv_toolPayload().guest ) )
		-- THE BUBBLE, AND WHY IT IS PRINTED RATHER THAN LEFT TO BE FELT.
		--
		-- It has three states and two of them look identical from inside the
		-- game: a host who cannot build cannot tell "somebody is standing next
		-- to me" from "this feature is broken". That is the same failure as a
		-- panel that closes on every click whether or not the button worked, and
		-- this project has already paid for that one three times.
		if g_swPlots and g_swPlots.sv_bubbleStatus then
			local ok, status = pcall( g_swPlots.sv_bubbleStatus, g_swPlots )
			reply( "  host can build where they stand: " .. ( ok and tostring( status ) or "unknown" ) )
		end

	elseif cmd == "/players" then
		-- The host is whoever is running the server -- sm.player.getHostPlayer()
		-- IS that person, and it is the same test every host-only path uses. Say
		-- so out loud, because "who has the buttons" is a fair question for a
		-- lobby and there is no other way to find out.
		local players = sm.player.getAllPlayers()
		local hostPlayer = sm.player.getHostPlayer()
		local bots = self.sv.crowdCount or 0
		reply( string.format( "%d player(s) here%s:", #players,
			bots > 0 and string.format( " and %d crowd bot(s)", bots ) or "" ) )
		for _, p in ipairs( players ) do
			reply( string.format( "  id %-3d %-10s %s%s", p.id,
				Identity.Sv_PermaOf( p ) or "?", p.name,
				p == hostPlayer and "   <- HOST" or "" ) )
		end
		if bots > 0 then
			-- Named, not just counted. A bot holds a plot and shows on the
			-- roster, so "who owns plot 14" has to have an answer, and the
			-- answer must be obviously not a person.
			reply( string.format( "  + %d bot(s) under crowdbot: -- /crowd off removes them", bots ) )
		end
		if hostPlayer == nil then
			reply( "  no host player -- host-only commands will refuse everyone" )
		end

	elseif cmd == "/focus" then
		local token = joinName( params, 2 )
		-- "off" and "none" clear, because that is what somebody types before
		-- they remember /unfocus exists.
		local lowered = string.lower( token )
		if lowered == "off" or lowered == "none" or lowered == "clear" then
			if self.sv.focus == nil then
				reply( "Nobody is focused." )
			else
				self:sv_setFocus( nil, player )
			end
			return
		end
		local target = resolveTarget( token )
		if target == nil or not sm.exists( target ) then
			reply( string.format( "'%s' is not here -- try /players", token ) )
			return
		end
		self:sv_setFocus( target, player )

	elseif cmd == "/unfocus" then
		if self.sv.focus == nil then
			reply( "Nobody is focused." )
		else
			self:sv_setFocus( nil, player )
		end

	elseif cmd == "/known" then
		for _, line in ipairs( Identity.Sv_KnownLines( 25 ) ) do reply( line ) end

	elseif cmd == "/ban" then
		local _, detail = self:sv_doBan( joinName( params, 2 ), "" )
		reply( detail )

	elseif cmd == "/unban" then
		local _, detail = self:sv_doUnban( joinName( params, 2 ) )
		reply( detail )

	elseif cmd == "/banlist" then
		for _, line in ipairs( Identity.Sv_BanLines() ) do reply( line ) end

	elseif cmd == "/allow" or cmd == "/unallow" then
		local _, detail = self:sv_doAllow( joinName( params, 2 ), cmd == "/allow" )
		reply( detail )

	elseif cmd == "/allowlist" then
		reply( string.format( "allowlist is %s -- /set allowlist on|off",
			Settings.Get( "allowlist" ) and "ON" or "off" ) )
		for _, line in ipairs( Identity.Sv_AllowLines() ) do reply( line ) end

	elseif cmd == "/kick" then
		local _, detail = self:sv_doKick( joinName( params, 2 ) )
		reply( detail )
	end
end
