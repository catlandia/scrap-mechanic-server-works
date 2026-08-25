dofile( "$GAME_DATA/Scripts/game/worlds/CreativeFlatWorld.lua" )
dofile( "$CONTENT_DATA/Scripts/Layout.lua" )
dofile( "$CONTENT_DATA/Scripts/Palette.lua" )
dofile( "$CONTENT_DATA/Scripts/Protection.lua" )
dofile( "$CONTENT_DATA/Scripts/Plots.lua" )
dofile( "$CONTENT_DATA/Scripts/Rules.lua" )
dofile( "$CONTENT_DATA/Scripts/Snapshots.lua" )
dofile( "$CONTENT_DATA/Scripts/PlotMarker.lua" )
dofile( "$CONTENT_DATA/Scripts/Crowd.lua" )
dofile( "$CONTENT_DATA/Scripts/Bench.lua" )

-- The World script, and the reason this file carries the weight of the mod.
--
-- MEASURED, first run, 2026-08-22 23:16:44:
--
--   [C]: in function 'getAllBodies'
--   Protection.lua:165: in function 'sv_setMode'
--   Game.lua:123: in function 'server_onCreate'
--   ERROR: Calling world dependent functions in a no world script!
--
-- A Game script has NO WORLD. sm.body.getAllBodies, and everything else that
-- touches bodies, is world-dependent and simply cannot be called from it. That
-- is why vanilla keeps restrictAllBodies() in world_util and calls it from
-- BuilderWorld -- a *world* script -- and following the vanilla structure would
-- have avoided the whole class of bug.
--
-- So: anything that touches a body lives here. Game.lua keeps chat, identity,
-- settings and timers, and forwards world work over sm.event.sendToWorld.
--
-- Game and World share one Lua global environment (this is how vanilla's
-- g_unitManager, created in CreativeGame, is reachable from CreativeBaseWorld),
-- so the Settings and Identity modules are visible from both without plumbing.
--
-- This file also exists to stop explosions cratering the ground and to stop fire
-- spreading; see server_onExplosion and server_onFixedUpdate below.

World = class( CreativeFlatWorld )

-- WHAT MAY BE BUILT ON. Set explicitly, all four of them.
--
-- "fun fact. in survival lift is disabled by default. which means. just remove
-- that thing that disables lifts."
--
-- NOT MEASURED. An earlier version of this comment claimed it was, and that
-- was wrong, so the actual state of the evidence is worth writing down.
--
-- FOR: Survival/Scripts/game/worlds/DungeonWorld.lua sets three of these ON by
-- hand, and its parent BaseWorld sets none of them, so it is writing against a
-- default rather than overriding a parent. WarehouseWorld turns one OFF.
--
-- AGAINST, and it is the stronger half: NO CREATIVE WORLD SETS THEM EITHER --
-- CreativeFlatWorld, CreativeTerrainWorld, CreativeCustomWorld, none of them --
-- and lifts plainly work in vanilla creative. So the default cannot be false in
-- creative content, and whether baseGameContent "Survival" changes it is exactly
-- the thing nobody has established.
--
-- So these are set because an unknown default is worth removing and naming four
-- flags costs nothing, NOT because they are known to be the lift bug. They
-- probably are not.
--
-- These are class fields read by the engine when the world is created
-- (LuaWorldScript.cpp's literal list), not settings, so they cannot be toggled
-- later and there is no cost to naming all four.
World.enableBuildOnLift = true      -- the lift can place a creation at all
World.enableBuildOnBodies = true    -- blocks attach to the city floor and to builds
World.enableBuildOnSurface = true   -- and to the ground itself
World.enableBuildOnAssets = true

-- Set from Settings; globals because a settings apply function cannot reach the
-- world instance.
g_swProtectTerrain = true
g_swFireEnabled = false

-- Reachable from Game.lua for read-only status queries.
g_swProtection = nil
g_swPlots = nil
g_swRules = nil
g_swSnapshots = nil

local TICKS_PER_SECOND = 40


function World.server_onCreate( self )
	CreativeFlatWorld.server_onCreate( self )

	self.sw = {
		lastCensus = nil,
		alarmQuietUntil = 0,
		nextAutoSnapshot = nil,
		patrolFaulted = false,
		rulesFaulted = false,
		crowdFaulted = false,
		cityJob = nil,
	}

	g_swSnapshots = Snapshots()
	g_swSnapshots:sv_onCreate()

	local savedPlots = Plots.Sv_LoadFile()
	g_swPlots = Plots()
	g_swPlots:sv_onCreate( savedPlots )

	-- The crowd is deliberately NOT restored from anything. Bots are live units
	-- and a saved handle to one is a dead handle; a session always starts empty
	-- and the host asks for a crowd when they want one. sv_onCreate does sweep
	-- plot claims left behind by a session that crashed mid-test.
	g_swCrowd = Crowd()
	g_swCrowd:sv_onCreate( g_swPlots )

	g_swBench = Bench()
	g_swBench:sv_onCreate( g_swCrowd )
	g_swBench:sv_load()

	g_swProtection = Protection()
	g_swProtection:sv_onCreate( Settings.Get( "protection" ) )

	-- The city floor is never liftable and never converts to dynamic, whatever
	-- profile it is otherwise running. See the PINNED note in Protection.lua.
	g_swProtection:sv_setGroundTest( function( body )
		return g_swPlots:sv_isGround( body )
	end )

	g_swProtection:sv_setResolver( function( body )
		-- The city's own decking is permanent in every mode. This is the ONLY
		-- thing protecting it, and it is a far better test than "the plaza is
		-- locked" ever was: our decking is metal at deck height, and a craftbot
		-- standing on top of it is not.
		if g_swPlots:sv_isScenery( body ) then
			return "locked"
		end

		-- SHARED GROUND STAYS CLEARABLE EVEN WHEN BUILDING IS SHUT, and this
		-- order is the whole point. REPORTED: "you need to fix the unremovable
		-- craft bots, gems and others."
		--
		-- Nothing legitimate can be built on a road or the plaza, so anything
		-- sitting there is litter. Locking it the moment building closes is how
		-- spawn spam wins: protect the world and the litter is protected with
		-- it, permanently -- prep, buffer and the end of an event all shut
		-- building, and the world stays locked between events. So the zone
		-- verdict has to be asked for BEFORE the blanket lock, not after.
		local zone = g_swPlots:sv_bodyIsOpen( body )
		if zone == "sweep" then
			return "sweep"
		end

		-- Rule 3: nothing is buildable at all until the host opens building --
		-- UNLESS the mode already says so on its own, in which case this blanket
		-- has nothing to add and does real harm. See
		-- Protection.sv_modeClosesBuilding: during buffer time it was replacing
		-- the polish profile with `locked`, so buffer behaved exactly like prep
		-- and the paint, seats and controllers a buffer exists for were gone.
		if Settings.Get( "buildopen" ) == false
			and not g_swProtection:sv_modeClosesBuilding() then
			return false
		end
		return zone
	end )

	g_swRules = Rules()
	g_swRules:sv_onCreate()

	-- Now that a world exists, the world-dependent settings can actually apply.
	-- sm.fire.setFireLimit is one of them: CreativeBaseWorld calls it from its own
	-- server_onCreate, which is the proof it belongs here and not in Game.
	Settings.Sv_ApplyAll()
	self:sv_applySettings()

	local _, detail = g_swProtection:sv_setMode( g_swProtection:sv_getMode() )
	sm.log.info( string.format( "[ServerWorks] world ready, protection %s (%s)",
		g_swProtection:sv_getMode(), tostring( detail ) ) )
	-- Say what the world actually allows. "Can the lift place anything at all"
	-- was unanswerable for a dozen versions; now it is one line at load.
	sm.log.info( string.format(
		"[ServerWorks] build on: lift=%s bodies=%s surface=%s assets=%s",
		tostring( World.enableBuildOnLift ), tostring( World.enableBuildOnBodies ),
		tostring( World.enableBuildOnSurface ), tostring( World.enableBuildOnAssets ) ) )
end

function World.sv_applySettings( self )
	g_swPlots.enabled = Settings.Get( "plots" ) == true
	-- The scenery test caches which materials count as street, and the style
	-- settings decide that. Nothing else drops the cache, so if this line goes
	-- the streets keep whatever protection the previous style gave them.
	g_swPlots:sv_restyle()
	Plots.PUSH_INTRUDERS = Settings.Get( "pushintruders" ) == true

	local minutes = tonumber( Settings.Get( "autosave" ) ) or 0
	if minutes > 0 then
		if self.sw.nextAutoSnapshot == nil then
			self.sw.nextAutoSnapshot = sm.game.getCurrentTick() + minutes * 60 * TICKS_PER_SECOND
		end
	else
		self.sw.nextAutoSnapshot = nil
	end
end

function World.sv_reply( self, player, text )
	sm.event.sendToGame( "sv_e_swReply", { player = player, text = text } )
end

function World.sv_broadcast( self, text )
	sm.event.sendToGame( "sv_e_swBroadcast", { text = text } )
end

-- The cleaner deletes things on purpose, so it must not read as mass deletion
-- to the grief alarm. It is a tool script and has no world of its own, so it
-- asks for the quiet the same way everything else does.
function World.sv_e_swQuietAlarm( self, params )
	self:sv_quietAlarm( tonumber( params and params.seconds ) or 20 )
end

function World.sv_quietAlarm( self, seconds )
	self.sw.alarmQuietUntil = sm.game.getCurrentTick() + seconds * TICKS_PER_SECOND
end


--[[ explosions and fire ]]

function World.server_onExplosion( self, center, destructionLevel, radius )
	-- An explosion cannot be cancelled -- server_onExplosion is a notification and
	-- the bang has already happened. What it leaves behind CAN be taken away:
	-- sm.debris.createBlackHole vacuums loose debris, which is the actual
	-- complaint about cornades. Vanilla drives it from the plasma drill
	-- (PlasmaDrill.lua:619), so the argument order is copied from there rather
	-- than guessed.
	if Settings.Get( "cleanupdebris" ) ~= false then
		pcall( sm.debris.createBlackHole, center, ( radius or 3 ) * 1.5, 60,
			center, -10, 2 )
	end

	if g_swProtectTerrain then
		-- server_onExplosion is a notification, not a veto: the explosion has
		-- already happened. What can still be declined is the terrain damage,
		-- which is the base class calling sphereVoxelDensitySubtraction and is
		-- not covered by any body permission flag.
		return
	end
	CreativeFlatWorld.server_onExplosion( self, center, destructionLevel, radius )
end


--[[ the tick ]]

-- The parent's body is three calls and there is no way to skip only one of them,
-- so it is restated rather than delegated. If CreativeBaseWorld gains a fourth
-- call in a game update this must gain it too -- recheck
-- Data/Scripts/game/worlds/CreativeBaseWorld.lua after any patch.
function World.server_onFixedUpdate( self )
	if g_swFireEnabled then
		AttachedFireManager.Sv_OnWorldFixedUpdate( self.world )
	end
	CablebotManager.Sv_OnWorldFixedUpdate( self.world )
	self.waterManager:sv_onFixedUpdate()

	local tick = sm.game.getCurrentTick()

	-- A fault here must never take the world down mid-event: the world stays in
	-- whatever state it is already in and /unlock still works.
	local ok, err = pcall( function()
		-- Set BEFORE the occupancy pass, which is the only reader: bots are
		-- presence, and presence is what that pass is for.
		g_swPlots:sv_setCrowd( g_swCrowd:sv_occupants() )
		g_swPlots:sv_updateOccupancy( function( player )
			return Identity.Sv_PermaOf( player )
		end, tick )
		g_swProtection:sv_onFixedUpdate()
	end )
	if not ok and not self.sw.patrolFaulted then
		self.sw.patrolFaulted = true       -- log once, never per tick
		sm.log.warning( "[ServerWorks] protection patrol disabled after error: " .. tostring( err ) )
		g_swProtection.patrolEnabled = false
	end

	-- Its own pcall, not the patrol's. A test harness must never be able to
	-- switch off protection, and protection faulting must not leave a crowd
	-- standing that nothing is able to clear.
	if not self.sw.crowdFaulted then
		local crowdOk, crowdErr = pcall( function()
			g_swCrowd:sv_onFixedUpdate( tick, function( bp )
				return ( self:sv_importBlueprint( bp ) )
			end )
		end )
		if not crowdOk then
			self.sw.crowdFaulted = true
			sm.log.warning( "[ServerWorks] crowd disabled after error: " .. tostring( crowdErr ) )
			pcall( function() g_swCrowd:sv_clear() end )
			pcall( function() g_swBench:sv_stop( nil, "abandoned: the crowd faulted" ) end )
		end
		-- The bench only advances when the host client reports; this is purely
		-- the watchdog that ends a run nobody is reporting to.
		pcall( function() g_swBench:sv_onFixedUpdate( tick ) end )
	end

	self:sv_traceStep( tick )
	self:sv_releaseImportedLift( tick )
	self:sv_stepSnapshots()
	pcall( function() self:sv_stepCity() end )
	self:sv_checkRules( tick )
	self:sv_checkGriefAlarm( tick )
	self:sv_checkTimers( tick )
end

function World.client_onFixedUpdate( self )
	if g_swFireEnabled then
		AttachedFireManager.Cl_OnWorldFixedUpdate( self.world )
	end
	CablebotManager.Cl_OnWorldFixedUpdate( self.world )
	self.waterManager:cl_onFixedUpdate()
end

function World.sv_stepSnapshots( self )
	local ok, done = pcall( function() return g_swSnapshots:sv_onFixedUpdate() end )
	if not ok then
		sm.log.warning( "[ServerWorks] snapshot job aborted: " .. tostring( done ) )
		g_swSnapshots.job = nil
		return
	end
	if done then
		self:sv_quietAlarm( 10 )
		self:sv_broadcast( done )
	end
end

-- The engine fires nothing when a plain block is destroyed, so mass deletion can
-- only be noticed by watching the world's total shape count fall. Protection's
-- patrol already produces that number once per cycle for one extra call per body.
-- The alarm watches a WINDOW, not one census cycle.
--
-- Both halves of this are wrong without it, and the owner supplied the fact that
-- shows why: **the remove tool deletes at most 16x16 at a time.** So one
-- ordinary action is up to 256 shapes.
--
--   * The old threshold was 250, compared cycle to cycle -- so a SINGLE
--     legitimate delete tripped the alarm and locked the world.
--   * Raise the threshold above 256 and the opposite appears. A census cycle is
--     128 bodies per tick at 40 Hz, so a 200-body city completes one every four
--     hundredths of a second. Somebody deleting 256 at a time, over and over,
--     never shows a drop bigger than 256 in any single cycle and never trips it
--     at all.
--
-- So the drop is measured across ALARM_WINDOW seconds. One big delete is normal
-- and stays quiet; several in twenty seconds is a rampage and is not.
World.ALARM_WINDOW = 20 * TICKS_PER_SECOND

function World.sv_checkGriefAlarm( self, tick )
	local census = g_swProtection:sv_census()
	if census == nil then return end

	local log = self.sw.censusLog
	if log == nil then
		log = {}
		self.sw.censusLog = log
	end

	-- Only record when the number actually moves, so the window is a list of
	-- changes rather than one sample per tick forever.
	if #log == 0 or log[#log].n ~= census then
		log[#log + 1] = { tick = tick, n = census }
	end

	-- Drop everything that has aged out, but always keep one sample older than
	-- the window so there is something to compare the present against.
	while #log > 1 and ( tick - log[2].tick ) > World.ALARM_WINDOW do
		table.remove( log, 1 )
	end

	if tick < self.sw.alarmQuietUntil then return end
	if g_swSnapshots:sv_busy() then return end

	-- The high-water mark inside the window, not the previous sample: a griefer
	-- who pauses between deletes must not get a fresh baseline for free.
	local peak = census
	for _, sample in ipairs( log ) do
		if sample.n > peak then peak = sample.n end
	end

	local lost = peak - census
	if lost < ( tonumber( Settings.Get( "alarmdrop" ) ) or 400 ) then return end

	sm.log.info( string.format( "[ServerWorks] GRIEF ALARM: %d shapes lost in %ds",
		lost, World.ALARM_WINDOW / TICKS_PER_SECOND ) )
	self:sv_broadcast( string.format( "*** %d blocks have disappeared ***", lost ) )
	self:sv_quietAlarm( 30 )
	self.sw.censusLog = { { tick = tick, n = census } }   -- fresh baseline

	if Settings.Get( "alarmlock" ) and g_swProtection:sv_getMode() ~= "locked" then
		local locked, detail = g_swProtection:sv_setMode( "locked" )
		if locked then
			Settings.Sv_SetQuiet( "protection", "locked" )
			self:sv_broadcast( "BUILDS LOCKED automatically -- " .. detail )
			self:sv_broadcast( "Host: /restore <name> to roll back, /unlock to resume." )
		end
	end
end

function World.sv_checkRules( self, tick )
	local ok, report = pcall( function()
		return g_swRules:sv_audit( tick, g_swPlots, Settings.Get )
	end )
	if not ok then
		if not self.sw.rulesFaulted then
			self.sw.rulesFaulted = true
			sm.log.warning( "[ServerWorks] rules audit disabled: " .. tostring( report ) )
		end
		return
	end
	if report == nil then return end       -- not due yet

	-- A plot over budget stops accepting NEW parts until its owner trims it.
	-- Removing, repainting and rewiring all still work -- see PROFILES.trim in
	-- Protection.lua, and the deadlock it exists to undo. Nothing already built
	-- is ever taken away: over-budget is a brake, not a punishment.
	g_swPlots.overBudget = {}
	for index, reasons in pairs( g_swRules.violations ) do
		g_swPlots.overBudget[index] = true
		if g_swRules:sv_shouldReport( index, tick ) then
			local owner = g_swPlots.owners[index]
			local name = owner and Identity.Sv_NameOf( owner )
			for _, p in ipairs( sm.player.getAllPlayers() ) do
				if name and p.name == name then
					self:sv_reply( p, string.format(
						"Plot %d is over the server limits -- no NEW parts until you trim it:", index ) )
					for _, reason in ipairs( reasons ) do
						self:sv_reply( p, "   " .. reason )
					end
					-- Said outright, because the previous build locked erasing
					-- too and the first thing anybody will try is removing the
					-- part the message just named.
					self:sv_reply( p, "   You CAN still remove parts, paint and rewire. /budget for the numbers." )
				end
			end
		end
	end

	-- Only a full pass collects contraband -- a scoped pass never looks at the
	-- roads, which is where dropped contraband lands. See Rules.FAST_SECONDS.
	if report.contraband and #report.contraband > 0 then
		local autoremove = Settings.Get( "autoremove" ) == true
		local labels, removedAny = {}, false
		for _, item in ipairs( report.contraband ) do
			labels[item.label] = ( labels[item.label] or 0 ) + 1
			-- Explosives go regardless of the autoremove setting: announcing that
			-- a live cornade exists and leaving it there helps nobody.
			if ( autoremove or item.alwaysRemove ) and sm.exists( item.shape ) then
				pcall( function() item.shape:destroyShape() end )
				removedAny = true
			end
		end
		for label, n in pairs( labels ) do
			self:sv_broadcast( string.format( "%d %s%s %s -- banned on this server%s",
				n, label, n > 1 and "s" or "", removedAny and "removed" or "found",
				removedAny and "" or " (host: /set autoremove on)" ) )
		end
		if removedAny then self:sv_quietAlarm( 15 ) end
	end
end

-- The build deadline used to live here as a second, independent clock. It is the
-- event clock's job now (Event.lua), and the end-of-event lock and snapshot moved
-- to sv_e_swEventPhase -- one clock, one place it can be wrong.
function World.sv_checkTimers( self, tick )
	local minutes = tonumber( Settings.Get( "autosave" ) ) or 0
	if minutes > 0 and self.sw.nextAutoSnapshot and tick >= self.sw.nextAutoSnapshot then
		self.sw.nextAutoSnapshot = tick + minutes * 60 * TICKS_PER_SECOND
		if not g_swSnapshots:sv_busy() then
			local started, detail = g_swSnapshots:sv_beginCapture(
				g_swSnapshots:sv_autoName(), self.world, self:sv_plotOfBody() )
			if started then
				sm.log.info( "[ServerWorks] auto-snapshot: " .. detail )
			end
		end
	end
end


--[[ helpers that need a world ]]

function World.sv_plotOfBody( self )
	return function( body )
		local z = g_swPlots:sv_bodyZone( body )
		return ( z and z.kind == "plot" ) and z.index or nil
	end
end

-- Wipe one plot, so a restore can repair a single build without flattening the
-- city around it.
function World.sv_clearPlot( self, index )
	local removed = 0
	for _, body in ipairs( sm.body.getAllBodies() ) do
		if sm.exists( body ) and not isGhostBody( body ) then
			local z = g_swPlots:sv_bodyZone( body )
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


--[[ commands forwarded from Game ]]

-- params = { cmd, args, player }
-- What a phase change means to the world. Building open or shut is a setting the
-- protection resolver already reads, so it only has to be re-applied; the end of
-- an event is the same lock-and-save that /buildtime used to do, kept because it
-- is right.
-- A snapshot at every phase boundary, named after what just happened.
--
-- Asked for as: "the save shall happen on those times: prep time start, build
-- time start, build time end, buffer end. all those shall happen besides the
-- auto saving."
--
-- Which is exactly right, and better than a timer alone: an autosave lands
-- wherever the clock happens to be, but these land on the moments you would
-- actually want to roll back TO -- the state before anyone built, the state the
-- moment building closed, and the finished event.
local PHASE_SNAPSHOT = {
	prep = "prepstart",       -- before anybody has touched anything
	build = "buildstart",     -- the starting line
	buffer = "buildend",      -- the builds, exactly as the clock stopped them
	ended = "eventend",       -- after the buffer, the final state
}

function World.sv_e_swEventPhase( self, params )
	local phase = params.phase

	-- Taken BEFORE the protection change, so a snapshot is of the world as it
	-- was during the phase that just finished rather than after it has been
	-- locked down.
	local label = PHASE_SNAPSHOT[phase]
	if label and not g_swSnapshots:sv_busy() then
		local ok, detail = g_swSnapshots:sv_beginCapture(
			Snapshots.Name( label ), self.world, self:sv_plotOfBody() )
		if ok then
			sm.log.info( string.format( "[ServerWorks] phase snapshot (%s): %s",
				label, tostring( detail ) ) )
		else
			sm.log.warning( string.format(
				"[ServerWorks] phase snapshot (%s) failed: %s", label, tostring( detail ) ) )
		end
	end

	if phase == "ended" then
		local locked, detail = g_swProtection:sv_setMode( "locked" )
		if locked then
			Settings.Sv_SetQuiet( "protection", "locked" )
			sm.log.info( "[ServerWorks] event ended, world locked -- " .. tostring( detail ) )
		end
		-- The eventend capture is the phase snapshot above; it has already been
		-- started, so do not start a second one on top of it.
		return
	end

	-- Every other phase sets the mode explicitly -- Event.PROTECTION says which --
	-- because re-applying "whatever mode is current" is what left the world
	-- locked after an event had ended once. sv_setMode does a full immediate
	-- sweep, which is what makes the whistle instant rather than arriving over
	-- the next few seconds.
	local mode = Event.PROTECTION[phase] or "open"
	local ok, detail = g_swProtection:sv_setMode( mode )
	if ok then
		Settings.Sv_SetQuiet( "protection", mode )
		sm.log.info( string.format( "[ServerWorks] event %s -> protection %s (%s)",
			tostring( phase ), mode, tostring( detail ) ) )
	end
end

-- Does this body contain any of the city itself?
--
-- The guard on every bulk purge, and it was missing. /purge walkways removed
-- every body that was not standing on a plot -- which is the deck, the streets,
-- the plaza and the pillar, i.e. the entire city floor. It survived only because
-- it was a chat command nobody ran; putting it behind a SWEEP LITTER button
-- would have made one press delete the world.
--
-- Per SHAPE, not per body, because the moment somebody builds on a plot their
-- build and our slab are one body -- so this protects their work too.
local function holdsCity( body )
	local ok, shapes = pcall( function() return body:getShapes() end )
	if not ok or shapes == nil then return true end     -- unreadable: keep it
	for _, shape in ipairs( shapes ) do
		if sm.exists( shape ) and g_swPlots:sv_isCityShape( shape ) then
			return true
		end
	end
	return false
end

function World.sv_e_swCommand( self, params )
	local cmd, args, player = params.cmd, params.args, params.player

	-- When a PANEL sent the command the panel is still open and waiting to hear
	-- what happened, so the replies are collected into a status line for it as
	-- well as going to chat. Chat is behind the panel; a player who has just
	-- pressed a button is looking at the button.
	local collected = params.panel and {} or nil
	local function reply( text )
		if collected then collected[#collected + 1] = tostring( text ) end
		self:sv_reply( player, text )
	end

	-- THE WORLD SHUTS WITH TWO SWITCHES AND /unlock ONLY EVER FLIPPED ONE.
	--
	-- MEASURED against this mod's own resolver, driven from dev/test_logic.py
	-- with the live Settings.json off the installed mod:
	--
	--   protection locked, buildopen false   ->  locked   liftable false
	--   protection open,   buildopen false   ->  locked   liftable false   <- /unlock
	--   protection open,   buildopen true    ->  open     liftable true
	--
	-- The middle row is what /unlock produced. `buildopen == false` fires in the
	-- resolver before the zone verdict, so every plot came back on the LOCKED
	-- profile with liftable and convertibleToDynamic false -- and vanilla's
	-- Lift.lua:127 needs targetBody:isLiftable() to hover, select or carry
	-- anything at all. The command whose help text is "reopen building" reopened
	-- nothing, announced "Building reopened", and left the lift dead.
	--
	-- Both flags are PERSISTED and the end of an event writes both
	-- (Event.PROTECTION.ended = "locked", sv_applyEventPhase -> buildopen false).
	-- So a single test event that ran to `ended` locked every later session, on
	-- every restart, with the one command named for the job unable to undo it.
	-- "A rule must never forbid its own remedy" -- CLAUDE.md, and this is the
	-- same shape as the part-limit bug.
	if cmd == "/lockdown" or cmd == "/unlock" then
		-- Not while the CLOCK owns building. prep, buffer and ended each carry
		-- their own protection mode, so the next sv_applyEventPhase would put
		-- this straight back. Saying so beats half-doing it.
		local clockOwnsIt = ( cmd == "/unlock" )
			and g_swEvent ~= nil and g_swEvent:sv_running()

		if clockOwnsIt then
			reply( string.format(
				"The event clock owns building right now (%s).", tostring( g_swEvent.phase ) ) )
			reply( "  /event stop to take it back, or wait for build time." )
		else
			local mode = "open"
			if cmd == "/lockdown" then
				mode = ( args[2] == "display" ) and "display" or "locked"
			end
			local ok, detail = g_swProtection:sv_setMode( mode )
			if ok then
				Settings.Sv_SetQuiet( "protection", mode )
				-- A locked world means locked: hazards go off regardless of what the
				-- settings panel says, and stay off until the world is reopened.
				if mode ~= "open" then
					for _, key in ipairs( { "claygun", "firelauncher", "cornades", "extinguisher" } ) do
						Settings.Sv_SetQuiet( key, false )
					end
					sm.event.sendToGame( "sv_e_swToolsChanged", {} )
				end
				-- The other half. Game owns buildopen and the event clock, so it does
				-- this bit; see Game.sv_e_swOpenBuilding.
				if mode == "open" then
					sm.event.sendToGame( "sv_e_swOpenBuilding", {} )
				end
				sm.log.info( string.format( "[ServerWorks] protection -> %s (%s)", mode, detail ) )
				self:sv_broadcast(
					mode == "locked" and ( "BUILDS LOCKED (strict) -- " .. detail )
					or mode == "display" and ( "BUILDS LOCKED, seats and buttons still work -- " .. detail )
					or ( "Building reopened -- " .. detail ) )
			else
				reply( "Failed: " .. tostring( detail ) )
			end
		end

	elseif cmd == "/nolift" then
		-- CLEAR EVERY LIFT IN THE WORLD, and the escape hatch for a lift nobody
		-- can pick up.
		--
		-- REPORTED: "the lift cant be removed and there are two". A lift made by
		-- sm.lift.createNonPlayerLift belongs to no player, so no lift tool will
		-- take it. Nothing in the mod creates one any more, but two are already
		-- standing in this world and there had to be a way out.
		--
		-- The way out is the handle: a Lift userdata has :destroy()
		-- (BuilderGuidePlatform.lua:64), and body:getLift() recovers one from a
		-- body that is standing on it. So walking the bodies finds every lift
		-- that has anything on it, whoever owns it.
		--
		-- Destroying a lift RELEASES what is on it -- the creation converts to
		-- dynamic and drops. That is not a side effect, it is the point: it is
		-- the same thing removing a lift by hand does.
		pcall( sm.player.removeLift, player )
		local destroyed, seen = 0, {}
		local okAll, bodies = pcall( sm.body.getAllBodies )
		for _, body in ipairs( okAll and bodies or {} ) do
			local okOn, onLift = pcall( function() return body:isOnLift() end )
			if okOn and onLift then
				local okGet, lift = pcall( function() return body:getLift() end )
				if okGet and lift and sm.exists( lift ) and not seen[tostring( lift )] then
					seen[tostring( lift )] = true
					if pcall( function() lift:destroy() end ) then
						destroyed = destroyed + 1
					end
				end
			end
		end
		reply( string.format( "cleared %d lift%s -- anything on them is loose now",
			destroyed, destroyed == 1 and "" or "s" ) )
		sm.log.info( string.format( "[ServerWorks] /nolift destroyed %d lifts", destroyed ) )

	elseif cmd == "/protection" then
		reply( g_swProtection:sv_status() )
		-- PhysicsQuality is a real engine setting (the name is in the executable's
		-- string table) and sm.game.getSettingValue can read it. There is no
		-- setter, so a mod cannot change it -- but the HOST runs the physics for
		-- everyone, so the host's value governs the whole server. Worth being able
		-- to see before blaming the mod for a slow event.
		local okq, quality = pcall( sm.game.getSettingValue, "PhysicsQuality" )
		reply( string.format( "host PhysicsQuality: %s  (host-side, set it in the game options)",
			okq and tostring( quality ) or "unreadable" ) )
		reply( string.format( "shapes in world: %s",
			tostring( g_swProtection:sv_census() or "counting..." ) ) )
		local claimed, total = g_swPlots:sv_counts()
		reply( string.format( "plots: %s, %d of %d claimed",
			g_swPlots.enabled and "ON" or "off", claimed, total ) )
		local progress = g_swSnapshots:sv_progress()
		if progress then reply( progress ) end
		if g_swEvent and g_swEvent:sv_running() then
			reply( string.format( "event: %s, %s left%s",
				g_swEvent.phase, Event.Clock( g_swEvent:sv_remaining() ),
				g_swEvent:sv_paused() and " (PAUSED)" or "" ) )
		end

	elseif cmd == "/buildtime" then
		-- Kept, because it is the command that already exists in the host's
		-- fingers -- but it is no longer a second clock. It is /event start with
		-- no prep phase, which is exactly what it always meant.
		reply( "use /event start 0 " .. tostring( tonumber( args[2] ) or 60 )
			.. "  -- /buildtime is now the event clock with no prep phase" )
		sm.event.sendToGame( "sv_e_swBuildTime",
			{ minutes = tonumber( args[2] ) or 0, player = player } )

	elseif cmd == "/snapshot" then
		-- Always stamped, so two manual saves an hour apart are told apart by
		-- the list rather than by memory.
		local name = args[2]
		if name == nil or name == "" then name = "manual" end
		name = Snapshots.Name( name )
		local ok, detail = g_swSnapshots:sv_beginCapture( name, self.world, self:sv_plotOfBody() )
		reply( ok and detail or ( "Failed: " .. tostring( detail ) ) )

	elseif cmd == "/snapshots" then
		local names = g_swSnapshots:sv_names()
		if #names == 0 then
			reply( "no snapshots yet -- /snapshot to make one" )
		else
			for _, line in ipairs( names ) do reply( "  " .. line ) end
		end

	elseif cmd == "/restore" then
		local opts = {}
		if params.plot then
			opts.plot = params.plot
			opts.clear = function() self:sv_clearPlot( params.plot ) end
		end
		self:sv_quietAlarm( 120 )
		local ok, detail = g_swSnapshots:sv_beginRestore( args[2], self.world, opts )
		if ok then
			self:sv_broadcast( ( params.plot
				and string.format( "Repairing plot %d -- ", params.plot )
				or "Rolling the world back -- " ) .. detail )
		else
			reply( "Failed: " .. tostring( detail ) )
		end

	elseif cmd == "/purge" then
		-- Script-side destroyShape ignores the erasable flag entirely -- vanilla's
		-- own sv_e_clear relies on that -- so this reaches litter that protection
		-- has otherwise made permanent.
		local what, n, removed = args[2], tonumber( args[3] ), 0
		if what == "look" then
			-- Point-and-delete. Carryable props -- gems, crates, harvestables --
			-- get PICKED UP by the remove tool instead of erased, so once one is
			-- on a plot there is no ordinary way to be rid of it. This reaches
			-- them: script-side destroyShape ignores every permission flag.
			local character = player:getCharacter()
			if not ( character and sm.exists( character ) ) then reply( "no character" ) return end
			local from = character.worldPosition + sm.vec3.new( 0, 0, 0.6 )
			local hit, result = sm.physics.raycast( from,
				from + character:getDirection() * 14, character )
			if not hit then reply( "nothing in front of you within 14 m" ) return end

			if result.type == "body" then
				local body = result:getBody()
				local shape = result:getShape()
				if n and n > 0 then
					-- THE WHOLE CREATION, ACROSS JOINTS. Same bug the cleaner's F
					-- key had: body:getShapes() is one WELD GROUP, and a bearing
					-- joins two separate bodies -- so this said "removed the whole
					-- creation" while removing the single body under the
					-- crosshair. A build with 20 bearings is about 21 bodies.
					--
					-- The per-shape city guard matters more here than it did
					-- before: getCreationShapes reaches further, and a build
					-- bolted to a plot slab now brings the slab into range.
					local got, shapes = pcall( function() return body:getCreationShapes() end )
					if not got or shapes == nil then
						got, shapes = pcall( function() return body:getShapes() end )
					end
					local spared = 0
					for _, sh in ipairs( got and shapes or {} ) do
						if sm.exists( sh ) then
							if g_swPlots and g_swPlots:sv_isCityShape( sh ) then
								spared = spared + 1
							else
								sh:destroyShape()
								removed = removed + 1
							end
						end
					end
					reply( string.format( "removed the whole creation (%d shapes%s)",
						removed, spared > 0
							and string.format( ", %d city shapes left alone", spared ) or "" ) )
				elseif shape and sm.exists( shape ) then
					shape:destroyShape()
					removed = 1
					reply( "removed that block" )
				end
			elseif result.type == "harvestable" then
				local h = result:getHarvestable()
				if h and sm.exists( h ) then
					pcall( function() h:destroy() end )
					removed = 1
					reply( "removed that harvestable" )
				end
			else
				reply( "that is not something I can remove (" .. tostring( result.type ) .. ")" )
			end

		elseif what == "carry" then
			-- Whatever you are holding in your hands, gone.
			local ok, carry = pcall( sm.player.getCarryData, player )
			if not ok or carry == nil then reply( "you are not carrying anything" ) return end
			pcall( sm.player.setCarryData, player, nil )
			removed = 1
			reply( "dropped and destroyed what you were carrying" )

		elseif what == "plot" then
			if n == nil then reply( "/purge plot <number>" ) return end
			removed = self:sv_clearPlot( n )
			reply( string.format( "cleared %d bodies from plot %d", removed, n ) )
		elseif what == "here" then
			local radius = n or 5
			local character = player:getCharacter()
			if not ( character and sm.exists( character ) ) then reply( "no character" ) return end
			local origin = character.worldPosition
			for _, body in ipairs( sm.body.getAllBodies() ) do
				if sm.exists( body ) and not isGhostBody( body ) and not holdsCity( body )
					and ( body.worldPosition - origin ):length() <= radius then
					for _, shape in ipairs( body:getShapes() ) do shape:destroyShape() end
					removed = removed + 1
				end
			end
			reply( string.format( "cleared %d bodies within %g m", removed, radius ) )
		end
		-- There was a "walkways" branch here -- delete every body that is not
		-- standing on a plot. REMOVED on the owner's instruction: "it just doesnt
		-- work as intended and just deletes stuff."
		--
		-- They are right about why, and it is worth keeping: "not on a plot" is
		-- not a test for litter. It cannot tell a dropped craftbot from a car
		-- somebody parked on a road, or from a build that overhangs its own plot
		-- edge, and there is no flag on a body that says "this is rubbish". A
		-- sweep that guesses will eventually delete something that mattered, and
		-- nobody will know which press did it.
		--
		-- The cleaner tool replaces it. It deletes exactly what is under the
		-- crosshair, which is a decision a person makes rather than a rule.
		if removed > 0 then
			self:sv_quietAlarm( 20 )       -- our own cleanup must not trip the alarm
			sm.log.info( string.format( "[ServerWorks] purge %s: %d bodies", tostring( what ), removed ) )
		end

	elseif cmd == "/plots" or cmd == "/plotgrid" or cmd == "/settingschanged" then
		-- THE fix for "settings display but do nothing". Settings.Sv_Set runs the
		-- apply hooks from the Game script, and the ones that matter are
		-- world-dependent -- sm.fire.setFireLimit throws there, and the pcall
		-- around it swallowed the error silently. So the value changed, the file
		-- was written, the panel updated, and the world never heard about it.
		-- Re-apply here, where a world exists and the calls are legal.
		Settings.Sv_ApplyAll()
		self:sv_applySettings()
		-- A preset can change the protection mode itself, so take it from
		-- settings rather than re-asserting whatever the world already had.
		local wanted = Settings.Get( "protection" )
		local _, detail = g_swProtection:sv_setMode( wanted or g_swProtection:sv_getMode() )
		sm.log.info( string.format( "[ServerWorks] settings applied in world: fire=%s plots=%s mode=%s (%s)",
			tostring( Settings.Get( "fire" ) ), tostring( g_swPlots.enabled ),
			g_swProtection:sv_getMode(), tostring( detail ) ) )
		if cmd == "/plots" then
			local claimed, total = g_swPlots:sv_counts()
			self:sv_broadcast( string.format( "Plot system %s (%d of %d plots claimed).",
				g_swPlots.enabled and "ON" or "OFF", claimed, total ) )
		end

	elseif cmd == "/plotapply" then
		-- Set the grid from the panel, persist it, then build in one go.
		-- Layout.config does the clamping, so the panel, the chat command and a
		-- hand-edited Plots.json all end up with the same validated grid.
		g_swPlots:sv_setGrid( params.cfg or {} )
		g_swPlots.owners = {}
		g_swPlots.teams = {}
		g_swPlots.requests = {}
		g_swPlots:sv_dirtyTeams()
		Plots.Sv_SaveFile( g_swPlots )
		-- Every claim just went away, so every compass marker is pointing at
		-- somebody else's ground until it is cleared.
		self:sv_refreshAllMarkers()
		self:sv_broadcast( "City layout changed. All plot claims cleared." )
		self:sv_buildFloor( reply )

	elseif cmd == "/plotbuild" then
		self:sv_buildFloor( reply )

	elseif cmd == "/plotclear" then
		local removed = self:sv_clearFloor()
		reply( string.format( "removed %d city shapes", removed ) )

	elseif cmd == "/why" then
		-- Three rounds of guessing why a lift would not work is two too many.
		-- Look at whatever the host is pointing at and say exactly what the
		-- protection system thinks of it.
		local character = player:getCharacter()
		if not ( character and sm.exists( character ) ) then reply( "no character" ) return end
		local from = character.worldPosition + sm.vec3.new( 0, 0, 0.6 )
		local hit, result = sm.physics.raycast( from,
			from + character:getDirection() * 12, character )
		if not hit or result.type ~= "body" then
			reply( "point at a build and try again (nothing hit within 12 m)" )
			return
		end
		local body = result:getBody()
		local z = g_swPlots:sv_bodyZone( body )
		reply( string.format( "body at %.2f,%.2f,%.2f  shapes=%d  static=%s",
			body.worldPosition.x, body.worldPosition.y, body.worldPosition.z,
			body:getShapeCount(), tostring( body:isStatic() ) ) )
		-- A GHOST is a creation being placed, not one that exists. The patrol
		-- skips them; if this ever says ghost=true for something real, or
		-- ghost=false while you are holding a blueprint, that is the bug.
		reply( string.format( "  ghost=%s  onLift=%s  virtualLift=%s  protectedByUs=%s",
			tostring( body:isGhost() ), tostring( body:isOnLift() ),
			tostring( body:isOnVirtualLift() ),
			tostring( not isGhostBody( body ) ) ) )
		reply( string.format( "  zone: %s%s", z and z.kind or "outside city",
			( z and z.kind == "plot" ) and ( " " .. z.index ) or "" ) )
		reply( string.format( "  scenery: %s   buildopen: %s   plots: %s   mode: %s",
			tostring( g_swPlots:sv_isScenery( body ) ),
			tostring( Settings.Get( "buildopen" ) ),
			tostring( g_swPlots.enabled ),
			g_swProtection:sv_getMode() ) )
		reply( string.format( "  buildable=%s erasable=%s liftable=%s paintable=%s",
			tostring( body:isBuildable() ), tostring( body:isErasable() ),
			tostring( body:isLiftable() ), tostring( body:isPaintable() ) ) )
		reply( string.format( "  connectable=%s usable=%s destructable=%s dynamicOK=%s",
			tostring( body:isConnectable() ), tostring( body:isUsable() ),
			tostring( body:isDestructable() ), tostring( body:isConvertibleToDynamic() ) ) )

	elseif cmd == "/plot" then
		self:sv_plotCommand( args, player, reply )

	elseif cmd == "/home" then
		self:sv_home( player, reply )

	elseif cmd == "/myplot" then
		self:sv_openMyPlot( player, params.status )

	elseif cmd == "/budget" then
		-- The plot you are standing on, or one named outright.
		local index = tonumber( args[2] )
		if index == nil then
			local character = player:getCharacter()
			local z = character and sm.exists( character )
				and g_swPlots:sv_locate( character.worldPosition ) or nil
			index = ( z and z.kind == "plot" ) and z.index or nil
		end
		if index == nil then
			reply( "stand on a plot, or /budget <number>" )
		else
			for _, line in ipairs( g_swRules:sv_budgetLines( index, Settings.Get ) ) do
				reply( line )
			end
			if not g_swPlots.enabled then
				reply( "   NOTE: plots are OFF, so nothing is locked. /set plots on" )
			end
		end

	elseif cmd == "/citycensus" then
		-- MEASURED as a dead button: CLEAR CITY sent this and nothing in this
		-- file answered it, so the panel shut and the world did nothing. That is
		-- what "I press them and menu closes" was. dev/test_logic.py now walks
		-- every sv_toWorld string in Game.lua against this dispatch.
		self:sv_cityCensus( player )

	elseif cmd == "/crowd" then
		self:sv_crowdCommand( args or {}, reply )

	elseif cmd == "/bench" then
		self:sv_benchCommand( args or {}, reply )

	elseif cmd == "/marker" then
		-- Not a chat command; sent by Game when a player joins.
		self:sv_refreshMarker( player, false )
	end

	-- Redraw whichever panel asked, with what just happened written on it. This
	-- is what "make so that the menu doesnt close after every action" means in
	-- practice: the action runs, the panel restates the world, nothing shuts.
	if collected and cmd ~= "/myplot" and cmd ~= "/citycensus" then
		local status = ( #collected > 0 ) and table.concat( collected, "   " ) or nil
		if params.panel == "myplot" then
			self:sv_openMyPlot( player, status )
		elseif params.panel == "city" then
			sm.event.sendToGame( "sv_e_swPanelRefresh",
				{ player = player, panel = "city", status = status } )
		end
	end
end

--[[ the crowd ]]

-- /crowd -- stand in a lobby full of builders so the server has something to
-- measure when there is nobody to invite. See Crowd.lua for what this does and
-- does not stand in for; the one line worth repeating here is that it cannot
-- reach the engine's per-client network budget, because that is only ever
-- computed for a REMOTE client. One guest measures that; no number of bots does.
function World.sv_crowdCommand( self, args, reply )
	local function status()
		local s = g_swCrowd:sv_status()
		reply( string.format( "CROWD  %d bot%s   mode %s   claim %s   blocks standing %d",
			s.count, s.count == 1 and "" or "s",
			s.mode, s.claim and "ON" or "off", s.blocks ) )
		-- What the crowd is actually building, not just how much of it. Two
		-- runs with the same block count but a different style mix are not the
		-- same measurement, and this is the only place that is visible.
		if s.count > 0 then
			reply( string.format( "  %d of them are on a team with a neighbour", s.teams ) )
			if s.done > 0 then
				reply( string.format(
					"  %d of %d have built their full %d blocks and stopped",
					s.done, s.count, s.cap ) )
			end
			local parts = {}
			for _, style in ipairs( Crowd.STYLES ) do
				if s.styles[style] then
					parts[#parts + 1] = string.format( "%s %d", style, s.styles[style] )
				end
			end
			reply( "  building: " .. table.concat( parts, "   " ) )
		end
		if s.failed > 0 then
			reply( string.format( "  %d failed to spawn -- see the log", s.failed ) )
		end
	end

	local a = args[2]

	if a == nil then
		status()
		reply( "  /crowd <n>          put n bots on the city, one per plot" )
		reply( "  /crowd off          take them all away" )
		reply( "  /crowd mode build   stack blocks on their own plot and LEAVE them" )
		reply( "  /crowd mode churn   place one and take it away -- world never grows" )
		reply( "  /crowd mode off     just stand there" )
		reply( "  /crowd claim on|off have them claim the plot they stand on" )
		reply( "  /crowd team         pair neighbouring bots up, as a lobby does" )
		return
	end

	if a == "off" then
		local had = g_swCrowd:sv_clear()
		reply( string.format( "crowd cleared -- %d bot%s removed",
			had, had == 1 and "" or "s" ) )
		sm.log.info( string.format( "[ServerWorks] crowd cleared: %d removed", had ) )
		return
	end

	if a == "mode" then
		if not g_swCrowd:sv_setMode( args[3] ) then
			reply( "/crowd mode build | churn | off" )
			return
		end
		if args[3] == "off" then
			-- Leaving the blocks standing on "mode off" would be a trap: the
			-- status line would read "0 blocks" the moment anything cleared and
			-- the city would keep whatever a test built. Off means off.
			for _, bot in ipairs( g_swCrowd.bots ) do
				g_swCrowd:sv_dropBlocks( bot )
			end
		end
		status()
		return
	end

	if a == "team" then
		local n = g_swCrowd:sv_formTeams()
		reply( string.format( "%d team%s formed", n, n == 1 and "" or "s" ) )
		status()
		return
	end

	if a == "claim" then
		local on = ( args[3] == "on" )
		if args[3] ~= "on" and args[3] ~= "off" then
			reply( "say on or off" )
			return
		end
		g_swCrowd.claim = on
		if on then
			-- The bots may already be standing. Without this the status line
			-- would read "claim ON" over a city where nothing was claimed.
			local n = g_swCrowd:sv_applyClaims()
			reply( string.format( "%d plot%s claimed", n, n == 1 and "" or "s" ) )
		else
			-- Turning it off has to hand the plots back, or they stay owned by a
			-- perma nobody can ever log in as.
			local n = g_swCrowd:sv_releaseClaims()
			reply( string.format( "%d plot%s released", n, n == 1 and "" or "s" ) )
		end
		status()
		return
	end

	local n = tonumber( a )
	if n == nil then
		reply( "/crowd <n>, or off, or churn/claim on|off" )
		return
	end
	if n > Crowd.MAX then
		reply( string.format( "%d is more than the %d cap -- see Crowd.MAX", n, Crowd.MAX ) )
		return
	end

	-- The city has to exist first. A bot spawned over empty terrain falls, and a
	-- crowd of falling bots is a rigid-body test, not a building-event one.
	if not g_swPlots.enabled or #g_swCrowd:sv_plotIndices() == 0 then
		reply( "no plots to stand on -- build the city first (/plots on, then BUILD CITY)" )
		return
	end

	local got, failed = g_swCrowd:sv_set( n )
	reply( string.format( "crowd is now %d, mode %s", got, g_swCrowd.mode ) )
	if g_swCrowd.mode == "build" then
		reply( string.format( "  they will build on their own plots, up to %d blocks each.",
			Crowd.MAX_BLOCKS ) )
		reply( "  /crowd off takes the bots AND everything they built." )
	else
		reply( "  they are only standing -- /crowd mode build to make them build." )
	end
	if failed > 0 then
		reply( string.format( "  %d failed -- is the character set loaded? see the log", failed ) )
	end
	-- Written to the log as well as to chat, because this is the line that dates
	-- a measurement: dev/session_stats.py reports tick rate per minute, and the
	-- minute the crowd changed size is the one that has to be read against it.
	sm.log.info( string.format( "[ServerWorks] crowd set to %d (%d failed, mode %s, claim %s)",
		got, failed, tostring( g_swCrowd.mode ), tostring( g_swCrowd.claim ) ) )
end

-- One client's second of frames, forwarded by Game (a world script has no
-- network of its own). The sender was resolved there, on the server, from the
-- engine's own third argument -- nothing in `params` is an identity claim.
function World.sv_e_swBenchSample( self, params )
	if params == nil then return end
	pcall( function()
		-- params.ticks, PLURAL. It was params.tick for one build, which is nil,
		-- and the whole tick-rate column read 0.0 -- a benchmark reporting that
		-- the server does not tick at all. Nothing errored, because nil simply
		-- fell through the type check in sv_sample and added zero.
		g_swBench:sv_sample( params.name, params.isHost == true,
			params.frames, params.secs, params.ticks )
	end )
end

-- /bench -- walk the crowd up in steps and write down what happens.
--
-- The measuring is all in Bench.lua; this is the door. See the header there for
-- why the host's client is the stopwatch and why a guest is sampled for frame
-- rate only.
function World.sv_benchCommand( self, args, reply )
	local a = args[2]

	if a == nil or a == "status" then
		reply( g_swBench:sv_status() )
		reply( "  /bench start [step] [secs]   default +" .. Bench.STEP
			.. " bots every " .. ( Bench.WINDOW + Bench.SETTLE ) .. "s" )
		reply( "  /bench stop                  abandon it and clear the crowd" )
		reply( "  /bench results               the table from the last run" )
		return
	end

	if a == "results" then
		for _, line in ipairs( g_swBench:sv_lines() ) do reply( line ) end
		return
	end

	if a == "stop" then
		g_swBench:sv_stop( reply )
		return
	end

	if a ~= "start" then
		reply( "/bench start | stop | results | status" )
		return
	end

	if not g_swPlots.enabled or #g_swCrowd:sv_plotIndices() == 0 then
		reply( "no plots to stand on -- build the city first (/plots on, then BUILD CITY)" )
		return
	end

	-- A bench measures the city under a crowd, so a clock running underneath it
	-- would be changing protection modes mid-run and moving the thing being
	-- measured. Refused rather than silently allowed.
	if g_swEvent ~= nil and g_swEvent:sv_running() then
		reply( "an event clock is running -- /event stop first, or the phases will" )
		reply( "change protection half way through the run and spoil the rows" )
		return
	end

	g_swBench:sv_start( tonumber( args[3] ), tonumber( args[4] ), nil, reply )
end

--[[ the my-plot panel ]]

-- Everything the panel shows, gathered in one place. Built on the server because
-- only the world knows what square a player is standing on -- the Game script
-- has no world and cannot ask.
function World.sv_openMyPlot( self, player, status )
	local perma = Identity.Sv_PermaOf( player )
	local mine = perma and g_swPlots:sv_plotOf( perma ) or nil

	local standing = nil
	local character = player:getCharacter()
	if character and sm.exists( character ) then
		local z = g_swPlots:sv_locate( character.worldPosition )
		if z then
			standing = { kind = z.kind }
			if z.kind == "plot" then
				local owner = g_swPlots.owners[z.index]
				standing.index = z.index
				standing.free = owner == nil
				standing.mine = owner ~= nil and owner == perma
				standing.owner = owner and ( Identity.Sv_NameOf( owner ) or owner ) or nil
			end
		end
	end

	-- The team as names, because "plot 34" means nothing to the person reading it
	-- and the name of the neighbour they just agreed with means everything.
	local team = {}
	if mine then
		local list = {}
		for index in pairs( g_swPlots:sv_teamOf( mine ) ) do
			if index ~= mine then list[#list + 1] = index end
		end
		table.sort( list )
		for _, index in ipairs( list ) do
			local owner = g_swPlots.owners[index]
			team[#team + 1] = string.format( "plot %d (%s)", index,
				owner and ( Identity.Sv_NameOf( owner ) or owner ) or "unclaimed" )
		end
	end

	local g = g_swPlots.grid
	local claimed = {}
	for index, owner in pairs( g_swPlots.owners ) do
		claimed[tostring( index )] = Identity.Sv_NameOf( owner ) or owner
	end
	local teamSet = {}
	if mine then
		for index in pairs( g_swPlots:sv_teamOf( mine ) ) do
			if index ~= mine then teamSet[tostring( index )] = true end
		end
	end

	sm.event.sendToGame( "sv_e_swMyPlot", { player = player, state = {
		plotsOn = g_swPlots.enabled == true,
		-- What the last press actually did. The panel stays open now, so this
		-- line is the only feedback a click gets -- without it, pressing CLAIM
		-- on a plot somebody else owns looks exactly like pressing a dead
		-- button, which is the complaint this whole version answers.
		status = status,
		mine = mine,
		standing = standing,
		team = team,
		cfg = {
			plot = g.plot, gap = g.gap, cols = g.cols, rows = g.rows,
			roadevery = g.roadevery, roadwidth = g.roadwidth, plazacells = g.plazacells,
			claimed = claimed, mine = mine, team = teamSet,
		},
	} } )
end

-- What is actually standing on the city, counted from the live world.
--
-- This is the first of the two doors in front of CLEAR CITY. "Are you sure?" is
-- answered by reflex; "12,406 blocks built by 9 people" is answered by reading,
-- and that difference is the entire reason the count is taken rather than the
-- dialog just being worded more sternly.
--
-- City shapes and player shapes are told apart per SHAPE, not per body, because
-- the moment somebody builds on a plot their build and our slab are one body.
function World.sv_cityCensus( self, player )
	local claimed, total = g_swPlots:sv_counts()
	local cityShapes, buildShapes = 0, 0
	local builders, people = {}, 0

	for _, body in ipairs( sm.body.getAllBodies() ) do
		if sm.exists( body ) and not isGhostBody( body ) then
			local ours = 0
			for _, shape in ipairs( body:getShapes() ) do
				if sm.exists( shape ) and g_swPlots:sv_isCityShape( shape ) then
					ours = ours + 1
				end
			end
			cityShapes = cityShapes + ours
			local theirs = body:getShapeCount() - ours
			if theirs > 0 then
				buildShapes = buildShapes + theirs
				local z = g_swPlots:sv_bodyZone( body )
				local owner = ( z and z.kind == "plot" ) and g_swPlots.owners[z.index] or nil
				if owner and not builders[owner] then
					builders[owner] = true
					people = people + 1
				end
			end
		end
	end

	local lines = {
		string.format( "%d plots, %d of them claimed", total, claimed ),
		string.format( "%d blocks built on them, by %d %s",
			buildShapes, people, ( people == 1 ) and "person" or "people" ),
		string.format( "%d shapes of city -- platform, streets and plaza", cityShapes ),
		"",
		"This removes the ground and everything welded to it.",
	}
	sm.event.sendToGame( "sv_e_swCityCensus", { player = player, lines = lines } )
end

function World.sv_plotCommand( self, args, player, reply )
	local action = args[2]
	local perma = Identity.Sv_PermaOf( player )

	if perma == nil then
		reply( "you are not registered yet -- rejoin" )
		return
	end
	if not g_swPlots.enabled then
		reply( "the plot system is off on this server" )
		return
	end

	local character = player:getCharacter()
	local here = character and sm.exists( character )
		and g_swPlots:sv_locate( character.worldPosition ) or nil

	local function nameOf( p ) return Identity.Sv_NameOf( p ) end

	if action == "claim" then
		if here == nil or here.kind ~= "plot" then
			reply( "stand inside a plot to claim it -- you are on the walkway or outside the city" )
			return
		end
		local ok, detail = g_swPlots:sv_claim( here.index, perma )
		reply( detail )
		if ok then
			Plots.Sv_SaveFile( g_swPlots )
			self:sv_refreshMarker( player, true )
			self:sv_broadcast( string.format( "%s claimed plot %d.", player.name, here.index ) )
		end

	elseif action == "info" then
		if here == nil then
			reply( "you are outside the city" )
		elseif here.kind == "plot" then
			reply( g_swPlots:sv_describe( here.index, nameOf ) )
		elseif here.kind == "corner" then
			reply( "walkway corner -- nobody can build here" )
		else
			local allowed = g_swPlots:sv_authorised( here )
			reply( next( allowed ) ~= nil
				and "shared filler -- the two plots either side are teamed"
				or "filler strip -- team up with the plot opposite to build here" )
		end

	elseif action == "team" then
		local other = args[3]
		if other == nil or other == "" then
			reply( "/plot team <player name>" )
			return
		end
		local rec = Identity.Sv_FindByName( other )
		local otherPerma = rec and rec.perma
		if otherPerma == nil then
			reply( string.format( "no player known as '%s'", other ) )
			return
		end
		local ok, detail = g_swPlots:sv_request( perma, otherPerma )
		reply( detail )
		if ok then
			Plots.Sv_SaveFile( g_swPlots )
			for _, p in ipairs( sm.player.getAllPlayers() ) do
				if Identity.Sv_PermaOf( p ) == otherPerma then
					self:sv_reply( p, string.format(
						"%s wants to team plots with you. Type: /plot team %s", player.name, player.name ) )
				end
			end
		end

	elseif action == "leave" then
		local ok, detail = g_swPlots:sv_unteam( perma )
		reply( detail )
		local released, detail2 = g_swPlots:sv_release( perma )
		reply( detail2 )
		if ok or released then
			Plots.Sv_SaveFile( g_swPlots )
			-- The compass must stop pointing at ground that is not theirs.
			self:sv_refreshMarker( player, false )
		end

	elseif action == "list" then
		local claimed, total = g_swPlots:sv_counts()
		reply( string.format( "%d of %d plots claimed", claimed, total ) )
		for i in pairs( g_swPlots.owners ) do
			reply( "  " .. g_swPlots:sv_describe( i, nameOf ) )
		end
	end
end

-- Player-vs-player collision cannot be turned off (see Settings.lua for the
-- evidence), so people do get shoved and flung. This does not prevent that, it
-- undoes it.
-- Point a player's compass at their own plot, or clear it if they have none.
-- Called whenever the answer could have changed: on join, on claim, on release,
-- and when the city is relaid under everybody.
function World.sv_refreshMarker( self, player, ping )
	if player == nil or not sm.exists( player ) then return end
	local perma = Identity.Sv_PermaOf( player )
	local index = perma and g_swPlots:sv_plotOf( perma )
	local pos = index and g_swPlots:sv_plotWorldCentre( index ) or nil
	-- Straight from the world to that one client, exactly the way vanilla sends a
	-- beacon: CreativeBaseWorld.sv_e_createBeacon does
	--     self.network:sendToClient( params.player, "cl_n_createBeacon", params )
	-- and cl_n_createBeacon then talks to the beacon manager
	-- (Data/Scripts/game/worlds/CreativeBaseWorld.lua:276-286).
	--
	-- It used to go out through the Game script, and that is why the marker has
	-- never once appeared:
	--
	--   WARNING: compass marker unavailable: PlotMarker.lua:72:
	--            Calling world dependent functions in a no world script!
	--
	-- compassSetIconWorldPosition needs a world to turn a position into a
	-- bearing. Game.lua has none. Going via the player script did not help
	-- either -- the same warning came back verbatim -- so the destination has to
	-- be the world's own client, which is the one context that certainly has
	-- one, and is where every vanilla caller of the compass lives.
	self.network:sendToClient( player, "cl_n_swMarker",
		{ position = pos, ping = ping == true } )
end

function World.cl_n_swMarker( self, data )
	if type( data ) ~= "table" or data.position == nil then
		PlotMarker.Cl_Hide()
		return
	end
	PlotMarker.Cl_Show( data.position )
	if data.ping then PlotMarker.Cl_Ping() end
end

function World.sv_refreshAllMarkers( self )
	for _, player in ipairs( sm.player.getAllPlayers() ) do
		self:sv_refreshMarker( player, false )
	end
end

function World.sv_home( self, player, reply )
	local perma = Identity.Sv_PermaOf( player )
	local index = perma and g_swPlots:sv_plotOf( perma )
	if index == nil then
		reply( "you do not own a plot -- stand on an empty one and /plot claim" )
		return
	end
	local character = player:getCharacter()
	if not ( character and sm.exists( character ) ) then
		reply( "no character to move" )
		return
	end
	local pos = g_swPlots:sv_plotWorldCentre( index )
	if pos == nil then
		reply( "that plot is not on the current grid -- the city was relaid" )
		return
	end
	local ok = pcall( function() character:setWorldPosition( pos ) end )
	-- Light the compass whether or not the teleport worked: "find my plot" is
	-- the more useful half of this command, and it is the half that cannot fail.
	self:sv_refreshMarker( player, true )
	reply( ok and string.format( "sent you to plot %d -- marked on your compass", index )
		or "teleport failed, but your plot is marked on your compass" )
end


--[[ NOTLIFT -- the lift trace ]]

-- A TIMELINE, NOT A SNAPSHOT.
--
-- ASKED FOR AS: "instead of just question next time. make a detailed log about
-- the lift that works real time so you can get info why tis wrong."
--
-- Right, and it is the lesson of the last five rounds. Every measurement so far
-- was taken at ONE instant, chosen by me, and every one of them was taken at the
-- wrong instant:
--
--   isOnLift() straight after placeLift   false, because placement is deferred
--                                         through RequestManager. Branching on
--                                         that made a second, unremovable lift.
--   isDynamic() straight after import     false, six ways, but that says nothing
--                                         about what happens a second later.
--   "lift=true"                           only ever meant "no Lua error".
--
-- A creation goes through at least four states -- imported, placed on a lift,
-- released, settled -- and the interesting thing is which TRANSITION fails. One
-- sample can never show that.
--
-- So this samples every tick for TRACE_SECONDS and prints a line whenever
-- anything changes, plus a heartbeat so a stuck state is visible too. It logs
-- what the BODY says (its own flags), what the RESOLVER would give it, and
-- where it is -- because "the patrol pinned it again" and "the engine never
-- converted it" look identical from the outside and need telling apart.
--
-- Bounded on purpose. Log spam is the largest performance bug this project has
-- measured (1.79 GB in one session), so: one body, one line per change, a
-- heartbeat no faster than once a second, and a hard stop.
World.TRACE_SECONDS = 25
World.TRACE_HEARTBEAT = 40      -- ticks; one line a second at most while idle

function World.sv_traceStart( self, root, player, label )
	if root == nil then return end
	local tick = sm.game.getCurrentTick()
	self.sw.trace = {
		root = root, player = player, label = label,
		started = tick, untilTick = tick + World.TRACE_SECONDS * 40,
		nextBeat = tick, last = nil,
	}
	sm.log.info( string.format(
		"[ServerWorks] lift-trace START %s -- every change for %ds",
		tostring( label ), World.TRACE_SECONDS ) )
end

-- Everything worth knowing about one body, in one line.
function World.sv_traceLine( self, body )
	local function ask( fn, default )
		local ok, value = pcall( fn )
		if not ok then return default end
		return value
	end

	local static  = ask( function() return body:isStatic() end, "?" )
	local dynamic = ask( function() return body:isDynamic() end, "?" )
	local onLift  = ask( function() return body:isOnLift() end, "?" )
	local virtual = ask( function() return body:isOnVirtualLift() end, "?" )
	local ghost   = ask( function() return body:isGhost() end, "?" )

	-- The body's OWN permission flags. If these disagree with the profile below,
	-- the patrol has not caught up yet; if convertible is false while the
	-- profile says true, something else is writing it.
	local conv  = ask( function() return body:isConvertibleToDynamic() end, "?" )
	local lift  = ask( function() return body:isLiftable() end, "?" )
	local erase = ask( function() return body:isErasable() end, "?" )
	local build = ask( function() return body:isBuildable() end, "?" )

	-- What the resolver WOULD hand it right now, and which zone that came from.
	local profile = "?"
	if g_swProtection and g_swProtection.sv_profileForTest then
		local ok, _, name = pcall( function()
			return g_swProtection:sv_profileForTest( body )
		end )
		if ok and name then profile = tostring( name ) end
	end
	local zone = "?"
	if g_swPlots then
		local ok, z = pcall( function() return g_swPlots:sv_bodyIsOpen( body ) end )
		if ok then zone = tostring( z ) end
	end

	local minz = "?"
	local okBox, aabbMin = pcall( function() return body:getWorldAabb() end )
	if okBox and aabbMin then minz = string.format( "%.2f", aabbMin.z ) end

	local hasLift = ask( function()
		local l = body:getLift()
		return ( l ~= nil and sm.exists( l ) ) and "yes" or "no"
	end, "?" )

	return string.format(
		"static=%s dyn=%s onLift=%s virt=%s ghost=%s | flags conv=%s lift=%s "
		.. "erase=%s build=%s | profile=%s zone=%s | minz=%s liftObj=%s",
		tostring( static ), tostring( dynamic ), tostring( onLift ),
		tostring( virtual ), tostring( ghost ), tostring( conv ), tostring( lift ),
		tostring( erase ), tostring( build ), profile, zone, minz, tostring( hasLift ) )
end

function World.sv_traceStep( self, tick )
	local t = self.sw.trace
	if t == nil then return end

	if t.root == nil or not sm.exists( t.root ) then
		sm.log.info( string.format( "[ServerWorks] lift-trace t+%.1fs BODY GONE (deleted)",
			( tick - t.started ) / 40 ) )
		self.sw.trace = nil
		return
	end

	local line = self:sv_traceLine( t.root )
	local changed = ( line ~= t.last )
	if changed or tick >= t.nextBeat then
		sm.log.info( string.format( "[ServerWorks] lift-trace t+%5.2fs %s %s",
			( tick - t.started ) / 40, changed and "*" or " ", line ) )
		t.last = line
		t.nextBeat = tick + World.TRACE_HEARTBEAT
	end

	if tick > t.untilTick then
		sm.log.info( "[ServerWorks] lift-trace END -- final: " .. line )
		self.sw.trace = nil
	end
end


--[[ NOTLIFT -- importing a creation ]]

-- The second half of an import, one second later.
--
-- A creation arrives static and only becomes a build by coming off a lift, so
-- the import puts it on one and this takes it off. Deferred because lift
-- placement is itself deferred: doing both in one tick removes the lift before
-- the creation has been put on it.
-- The body nearest a lift position, for picking up the creation again after the
-- engine has swapped the object out from under us.
function World.sv_bodyNear( self, liftPos )
	if liftPos == nil then return nil end
	local want = liftPos * 0.25
	local best, bestD = nil, 64        -- metres squared; well beyond any lift
	local ok, bodies = pcall( sm.body.getAllBodies )
	for _, body in ipairs( ok and bodies or {} ) do
		local okBox, aabbMin, aabbMax = pcall( function() return body:getWorldAabb() end )
		if okBox and aabbMin and aabbMax then
			local cx = ( aabbMin.x + aabbMax.x ) * 0.5 - want.x
			local cy = ( aabbMin.y + aabbMax.y ) * 0.5 - want.y
			local d = cx * cx + cy * cy
			if d < bestD then best, bestD = body, d end
		end
	end
	return best
end

function World.sv_releaseImportedLift( self, tick )
	local queue = self.sw.liftReleases
	if queue == nil or #queue == 0 then return end

	local keep = {}
	for _, job in ipairs( queue ) do
		if tick < job.atTick then
			keep[#keep + 1] = job
		else
			-- Destroying the handle is what releases the creation.
			-- BuilderGuidePlatform does exactly this (:64), and it is the only
			-- thing that removes a lift made by createNonPlayerLift -- no player
			-- owns one, so no lift tool will take it.
			--
			-- THE BODY IS DELIBERATELY NOT TRACKED HERE. MEASURED: the trace
			-- said "BODY GONE (deleted)" one tick after createNonPlayerLift,
			-- every single time. Putting a body on a lift REPLACES it -- the
			-- engine destroys the original object and makes a new one -- so any
			-- handle taken before the lift is already dead, and asking it
			-- anything is why the release logged nothing at all.
			local ok = job.lift and sm.exists( job.lift )
				and pcall( function() job.lift:destroy() end )
			sm.log.info( string.format( "[ServerWorks] NOTlift released %s: %s",
				tostring( job.name ), ok and "lift destroyed" or "lift already gone" ) )
			if job.player and sm.exists( job.player ) then
				self:sv_reply( job.player, string.format(
					"%s is off its lift and loose now.", tostring( job.name ) ) )
			end

			-- AND ONLY NOW IS THERE A BODY WORTH WATCHING.
			--
			-- Tracing from the import was useless: the body is replaced the
			-- instant it goes on a lift, so every trace ended "BODY GONE
			-- (deleted)" one tick in and told us nothing about the creation that
			-- actually survived. The interesting question was always what the
			-- thing looks like AFTER the release, so that is where it starts --
			-- found by position, because the handle we had is gone.
			self:sv_traceStart( self:sv_bodyNear( job.liftPos ), job.player, job.name )
		end
	end
	self.sw.liftReleases = keep
end

-- The end of the chain that starts at a NOTlift click. See NotLift.lua for why
-- the browser is the engine's and everything after the pick is ours.
--
-- This lives in the World script for the usual reason: sm.creation.importFromFile
-- is world-dependent, and a Game script has no world (measured, first run --
-- "Calling world dependent functions in a no world script!").
function World.sv_e_swImportCreation( self, params )
	local player = params and params.player
	if player == nil or not sm.exists( player ) then return end
	local function reply( text ) self:sv_reply( player, text ) end

	local path = params.path
	if type( path ) ~= "string" or path == "" then
		reply( "That creation has no file behind it." )
		return
	end

	-- HOST ONLY, CHECKED HERE AND NOT JUST BY THE TOOL GATE.
	--
	-- "the NOT lift shall only be host only. its too powerful."
	--
	-- The gate pulls the tool out of a guest's hands within a couple of ticks,
	-- which is fast but is not the same as impossible -- and this is the one
	-- action in the mod that creates a whole build from nothing. Same belt-and-
	-- braces as CleanerTool.sv_n_swDelete, and the same fail-safe direction: if
	-- the setting cannot be read, it stays host only, because that is the safe
	-- way to be wrong.
	local hostOnly = true
	if Settings and Settings.Get then
		local okS, value = pcall( Settings.Get, "hostnotlift" )
		if okS then hostOnly = ( value ~= false ) end
	end
	if hostOnly and player ~= sm.player.getHostPlayer() then
		reply( "Importing creations is host only on this server." )
		return
	end

	-- BUILDING HAS TO BE OPEN. Importing is placing, and a world that refuses a
	-- block has no business accepting a whole creation -- that would be the
	-- biggest hole in the freeze this mod has. Same test the client's canBuild
	-- flag uses, so the HUD and this agree.
	local mode = g_swProtection and g_swProtection:sv_getMode() or nil
	local canBuild = ( Settings.Get( "buildopen" ) ~= false )
		and ( mode == "open" or mode == "open_destructible" )
	if not canBuild then
		reply( "Building is closed, so nothing can be imported. (/unlock, or wait "
			.. "for build time.)" )
		return
	end

	-- WHERE. THE PLOT YOU ARE STANDING ON, and this changed with the host gate
	-- rather than in spite of it.
	--
	-- The first version refused unless you owned a plot, because for a GUEST the
	-- only safe target is their own ground -- body permission flags are per-body,
	-- so a creation dropped on somebody else's plot is one they cannot remove.
	-- With guests excluded that rule protects nobody, and it would have blocked
	-- the host outright: a host running an event does not claim a plot, so
	-- "import onto your own plot" would have meant "you cannot import at all".
	--
	-- Standing on it is the rule now. It is predictable, it needs no ownership,
	-- and it puts the creation where the host is looking.
	local character = player:getCharacter()
	if not ( character and sm.exists( character ) ) then
		reply( "No character to import next to." )
		return
	end
	-- THE FLOOR, NOT THE PLAYER'S MIDDLE.
	--
	-- The first attempt at this used character.worldPosition for the lift, and
	-- that is the character's CENTRE -- roughly a metre off the ground. A lift
	-- placed there hangs in mid air, which is a good candidate for why the first
	-- fix changed nothing. Vanilla's own server-side lift spawn derives its
	-- position from a SHAPE, not a character
	-- (BuilderGuideLiftPlatform.sv_spawnLift:153).
	--
	-- No raycast is needed to find our floor, because we built it: the city's
	-- walkable surface is at exactly ( DECK_Z + 1 ) * BLOCK = 1.25 everywhere --
	-- deck, road, plaza and plot slab all finish at the same height, which is why
	-- "anything merely standing on the floor starts at 1.25" holds at all.
	local charPos = character.worldPosition
	local pos = charPos
	local where = "where you are standing"
	local CITY_FLOOR = ( Plots.DECK_Z + 1 ) * Plots.BLOCK

	if g_swPlots and g_swPlots.enabled then
		local zone = g_swPlots:sv_locate( charPos )
		if zone and zone.kind == "plot" then
			local centre = g_swPlots:sv_plotWorldCentre( zone.index )
			if centre then
				pos = sm.vec3.new( centre.x, centre.y, CITY_FLOOR )
				where = "plot " .. tostring( zone.index )
			end
		elseif zone and zone.kind then
			-- On the city but not on a plot: road, plaza, anywhere with our
			-- decking under it. Same floor height, keep the x,y.
			pos = sm.vec3.new( charPos.x, charPos.y, CITY_FLOOR )
			where = "the " .. tostring( zone.kind )
		end
	end

	-- OFF THE CITY, ASK THE PHYSICS WHERE THE GROUND IS.
	--
	-- MEASURED, and it is why the last attempt still hung in the air:
	--
	--   liftPos=0,0,3   ->  world z 0.75
	--
	-- The city branches above never ran, because the host was stood on open
	-- terrain, so the fallback used character.worldPosition -- the character's
	-- CENTRE, about 0.75 m up with nothing under it.
	--
	-- sm.physics.raycast works server-side; vanilla casts straight down from a
	-- character with exactly this shape (TrashBallCharacter.lua:87). Ignoring the
	-- character matters or the cast hits the caster.
	if pos == charPos then
		local okRay, hit, result = pcall( sm.physics.raycast,
			charPos + sm.vec3.new( 0, 0, 0.5 ),
			charPos - sm.vec3.new( 0, 0, 6 ), character )
		if okRay and hit and result and result.pointWorld then
			pos = sm.vec3.new( charPos.x, charPos.y, result.pointWorld.z )
			where = "the ground under you"
		end
	end

	-- LIFT COORDINATES ARE QUARTER-BLOCKS. Lift.lua:104 builds liftPos as
	-- `raycastResult.pointWorld * 4` floored, and draws it back with
	-- `self.liftPos * 0.25` (:299). Our BLOCK is 0.25, so a lift coordinate and
	-- a city block coordinate are the same number -- which is why this is a
	-- multiply and not a conversion table.
	local liftPos = sm.vec3.new(
		math.floor( pos.x * 4 + 0.5 ),
		math.floor( pos.y * 4 + 0.5 ),
		math.floor( pos.z * 4 + 0.5 ) )

	-- AND THE IMPORT GOES TO EXACTLY THAT POINT, SNAPPED.
	--
	-- placeLift asserts "The body needs to be static, aligned and not already on
	-- a lift" (the literal is in the executable). Static and not-on-a-lift come
	-- free with a fresh import; ALIGNED does not. On a plot the centre is a
	-- multiple of BLOCK already, but the other branch above uses
	-- character.worldPosition, which is wherever the host happens to be standing
	-- -- an arbitrary float. Importing there would produce a body off the grid
	-- and placeLift would refuse it, landing us back on a static creation welded
	-- to air by a completely different route.
	pos = liftPos * 0.25

	-- HOW BIG, BEFORE IT EXISTS IF POSSIBLE.
	--
	-- A blueprint on this machine reached 3.1 MB and the browser showed one with
	-- 40,087 of a single part. Twenty people importing those is goal 1 of this
	-- project going backwards, so there is a cap.
	--
	-- Counting first is better than importing and deleting, so the file is read
	-- if it can be. $CONTENT_<uuid> is registered on the CLIENT that owns the
	-- blueprint -- whether the server resolves it is unproven, hence the pcall
	-- and the fallback below rather than an assumption either way.
	local cap = tonumber( Settings.Get( "maximportparts" ) ) or 0
	local counted = nil
	local okRead, data = pcall( sm.json.open, path )
	if okRead and type( data ) == "table" and type( data.bodies ) == "table" then
		counted = 0
		for _, body in ipairs( data.bodies ) do
			counted = counted + #( body.childs or {} )
		end
		if cap > 0 and counted > cap then
			reply( string.format( "That creation is %d parts and the limit is %d.",
				counted, cap ) )
			return
		end
	end

	-- ONE IMPORT. THE VARIANT SWEEP IS DONE AND ITS ANSWER IS RECORDED.
	--
	-- Six call shapes were tried -- with and without each of the two
	-- undocumented booleans, and with world = nil -- across two sessions.
	-- MEASURED, every time, all six:
	--
	--   NOTlift variant world, 4 args       -> 1 bodies, dynamic=false
	--   NOTlift variant world, +true        -> 1 bodies, dynamic=false
	--   NOTlift variant world, +true,true   -> 1 bodies, dynamic=false
	--   NOTlift variant world, +false       -> 1 bodies, dynamic=false
	--   NOTlift variant world, +false,false -> 1 bodies, dynamic=false
	--   NOTlift variant nil world, 4 args   -> 1 bodies, dynamic=false
	--
	-- sm.creation.importFromFile ALWAYS produces a static body and the booleans
	-- do not touch it. The question is settled, so the apparatus goes: it
	-- imported SIX copies of every creation and destroyed five, which is six
	-- times the cost on a 3 MB blueprint and leaves a duplicate standing if any
	-- one of those destroys does not take. Reported as "it spawns two and only
	-- one is not frozen".
	local function isDynamicNow( list )
		local b = ( list or {} )[1]
		if b == nil then return false end
		local ok, dyn = pcall( function() return b:isDynamic() end )
		return ok and dyn == true
	end

	local variant = "single import"
	local okImport, bodies = pcall( sm.creation.importFromFile, self.world, path,
		pos, sm.quat.identity() )
	if okImport and ( bodies == nil or #bodies == 0 ) then okImport = false end


	if not okImport then
		reply( "Could not import that creation -- every import variant refused it." )
		sm.log.warning( string.format(
			"[ServerWorks] NOTlift import failed for every variant, path=%s",
			tostring( path ) ) )
		if counted == nil then
			reply( "  (the server could not read the file either -- if you are not "
				.. "the host, this is the known limit.)" )
		end
		return
	end

	-- THE FALLBACK COUNT. If the file could not be read above, the size is only
	-- knowable after the fact -- so it is checked here and taken straight back
	-- out. A brief spike beats an unbounded one, and it is the only option when
	-- the path is a content id the server does not have.
	if counted == nil and cap > 0 then
		local shapes = 0
		for _, body in ipairs( bodies or {} ) do
			local okN, n = pcall( function() return body:getShapeCount() end )
			shapes = shapes + ( ( okN and n ) or 0 )
		end
		if shapes > cap then
			for _, body in ipairs( bodies or {} ) do
				pcall( function() body:destroyCreation() end )
			end
			reply( string.format( "That creation is %d parts and the limit is %d -- "
				.. "removed again.", shapes, cap ) )
			return
		end
		counted = shapes
	end

	-- AND ONTO A LIFT, WHICH IS THE WHOLE POINT OF THIS STEP.
	--
	-- REPORTED: "the lift spawns the creation welded to air. so I have to unweld
	-- every block by breaking it which you know doesnt work."
	--
	-- Exactly right, and it is not a bug in the import -- it is a missing step.
	-- sm.creation.importFromFile makes STATIC bodies. The engine says so itself,
	-- in the assert behind placeLift: "The body needs to be static, aligned and
	-- not already on a lift." A static body with nothing under it is a creation
	-- welded to air, and there is no Lua binding that turns one dynamic --
	-- wrap_Body.cpp has setConvertibleToDynamic, which is a PERMISSION, and
	-- isDynamic, which is a question. Nothing that converts.
	--
	-- What converts one is taking it OFF A LIFT, and that is precisely what
	-- vanilla's own import does: the creation is handed to the lift tool, placed
	-- on a lift, and released when the lift is removed. We were doing the import
	-- and skipping the lift.
	--
	-- So: put it on one. The host then has the ordinary lift controls -- raise,
	-- lower, rotate, remove -- and removing the lift drops the creation as a
	-- normal dynamic build. No unwelding, because nothing was ever welded.
	-- WHAT THE BODY ACTUALLY IS, LOGGED.
	--
	-- The first attempt reported lift=true and the creation was still static.
	-- That flag was worthless: sm.player.placeLift returns nothing, so a pcall
	-- around it only ever says "no Lua error was raised". This asks the body
	-- itself, which is the only thing that can settle it.
	local function state( b )
		local ok, text = pcall( function()
			return string.format( "static=%s dynamic=%s onLift=%s ghost=%s",
				tostring( b:isStatic() ), tostring( b:isDynamic() ),
				tostring( b:isOnLift() ), tostring( b:isGhost() ) )
		end )
		return ok and text or "unreadable"
	end

	local root = ( bodies or {} )[1]
	if root then
		sm.log.info( string.format( "[ServerWorks] NOTlift after import: %d bodies, %s",
			#bodies, state( root ) ) )
		-- NOT traced from here. Putting the body on a lift replaces it, so a
		-- trace started now reports BODY GONE one tick later and nothing else.
		-- sv_releaseImportedLift starts it after the release instead, on the
		-- body that actually survives.
	end

	-- ON A LIFT -- ONE LIFT, AND NEVER THE UNREMOVABLE KIND.
	--
	-- REPORTED: "this time it is on lift but the lift cant be removed and there
	-- are two". Both halves of that came from one mistake.
	--
	-- MEASURED, the run that produced it:
	--
	--   after import: 1 bodies, static=true dynamic=false onLift=false
	--   after lift (world lift (unconfirmed)): ... onLift=false
	--
	-- isOnLift() was false straight after sm.player.placeLift -- not because the
	-- call failed, but because LIFT PLACEMENT IS DEFERRED. The engine queues it
	-- through RequestManager and links the body on a later tick, so a same-tick
	-- check can never see it and was guaranteed to report failure. That false
	-- negative is what ran the fallback, and the fallback is what made the second
	-- lift.
	--
	-- And the fallback's lift was the one that could not be removed:
	-- sm.lift.createNonPlayerLift belongs to nobody, so no player's lift tool
	-- will take it. It is only destroyable through the handle it returns, or
	-- through body:getLift():destroy() -- see /nolift below. A lift the host
	-- cannot remove is a creation welded to air by another name, which is the
	-- bug this whole path exists to fix.
	--
	-- So: the player's own lift, once, unverified. It is the one the host can
	-- remove with the lift tool they already hold, and removing it is what
	-- converts the creation to dynamic.
	local liftHow = "none"
	local alreadyDynamic = isDynamicNow( bodies )

	-- sm.player.placeLift DOES NOT WORK ON A REAL BODY. MEASURED.
	--
	-- The 25 second trace never changed once:
	--
	--   t+ 0.00s * static=true dyn=false onLift=false ... conv=true
	--   t+25.00s   static=true dyn=false onLift=false ... conv=true
	--
	-- onLift was false immediately and stayed false for the whole window. Last
	-- round I put that down to deferred placement; the trace shows it is not
	-- deferral, the body simply never goes on the lift. Vanilla only ever calls
	-- placeLift with GHOST bodies handed over by the engine's own import
	-- (Lift.client_onForceTool), never with bodies already standing in the world.
	--
	-- sm.lift.createNonPlayerLift is the one that takes a REAL body. Vanilla
	-- passes an existing shape's body straight into it
	-- (BuilderGuideLiftPlatform.sv_spawnLift:160), which is exactly our case.
	--
	-- It was tried once and dropped because it leaves a lift nobody can pick up.
	-- That objection is gone: the handle comes back from the call, Lift:destroy()
	-- is what BuilderGuidePlatform uses on it, and the release below keeps and
	-- destroys it. Nothing is left standing.
	if root and not alreadyDynamic then
		-- UNDER THE CREATION, not under the player. The trace showed the body
		-- sitting at minz=0.50 while the lift was being asked for at z=0 -- the
		-- ground under the host's feet, which is not where the creation is. The
		-- lift belongs at the creation's own base, centred on its footprint.
		local okBox, aabbMin, aabbMax = pcall( function() return root:getWorldAabb() end )
		if okBox and aabbMin and aabbMax then
			liftPos = sm.vec3.new(
				math.floor( ( aabbMin.x + aabbMax.x ) * 0.5 * 4 + 0.5 ),
				math.floor( ( aabbMin.y + aabbMax.y ) * 0.5 * 4 + 0.5 ),
				math.floor( aabbMin.z * 4 + 0.5 ) )
		end

		local okLift, lift = pcall( sm.lift.createNonPlayerLift, self.world, liftPos,
			root, 0, 0 )
		if okLift and lift then
			liftHow = "world lift"
			-- A QUEUE, NOT A SINGLE SLOT. Three imports in under a minute each
			-- wrote their release into the same field and each overwrote the one
			-- before, so only the last creation was ever let off its lift and
			-- every earlier one stayed frozen. "it spawns two and only one is
			-- not frozen."
			self.sw.liftReleases = self.sw.liftReleases or {}
			self.sw.liftReleases[#self.sw.liftReleases + 1] = {
				player = player,
				atTick = sm.game.getCurrentTick() + 40,
				lift = lift,          -- the handle, so it can be destroyed again
				name = tostring( params.name or "creation" ),
				liftPos = liftPos,    -- where to look for the body afterwards

			}
		end
		sm.log.info( string.format(
			"[ServerWorks] NOTlift lift (%s): %s   liftPos=%s,%s,%s",
			liftHow, state( root ),
			tostring( liftPos.x ), tostring( liftPos.y ), tostring( liftPos.z ) ) )
	end
	local liftOk = ( liftHow ~= "none" )

	reply( string.format( "Imported \"%s\"%s onto %s.",
		tostring( params.name or "creation" ),
		counted and string.format( " (%d parts)", counted ) or "", where ) )
	if alreadyDynamic then
		reply( string.format( "  It is a normal build already (%s) -- no lift needed.",
			variant ) )
	elseif liftOk then
		reply( "  It came in static, so it goes on a lift and comes straight back "
			.. "off -- give it a second." )
	else
		reply( "  WARNING: it came in static and could not be put on a lift. The "
			.. "cleaner removes it -- point and click." )
	end
	sm.log.info( string.format(
		"[ServerWorks] NOTlift imported %s parts=%s onto %s variant=%s dynamic=%s lift=%s",
		tostring( params.name ), tostring( counted ), where, variant,
		tostring( alreadyDynamic ), liftHow ) )
end


--[[ the city ]]

-- One import per plot, deliberately. sm.body.getCreationsFromBodies groups by
-- creation, so importing the whole city in one blueprint would make it a single
-- creation and per-plot snapshot and restore would become all-or-nothing.
--
-- Run as a job a few plots per tick rather than 100 imports in one frame: this
-- is a setup command, but a host running it mid-event should not get a stall.
--
-- The order is nearest-the-middle-first (Layout.buildOrder), so the city grows
-- outwards from spawn while you watch it instead of sweeping in from a corner.
-- REPORTED: "the plot is not connected to the rest of the build" -- brown ground
-- showing between a plot and the walkway beside it, on a city whose geometry is
-- proved to be a gapless partition by dev/test_layout.py.
--
-- Geometry was never the problem. TIMING was. This used to clear the old city
-- and import the new one in the SAME TICK, and shape:destroyShape() does not
-- take effect immediately -- the engine tears shapes down at the end of a tick.
-- So the importer was asked to place new blocks into space the old blocks still
-- occupied, and what lands in occupied space is anybody's guess.
--
-- So the build is a job with a waiting stage now. Clear, let the tick end and
-- then some, and only then import. It costs a quarter of a second on a command
-- that already takes several, and it removes a whole class of "sometimes the
-- city comes out wrong".
World.CITY_SETTLE_TICKS = 20

function World.sv_buildFloor( self, reply )
	if self.sw.cityJob then
		reply( "already building" )
		return
	end
	local removed = self:sv_clearFloor()
	if removed > 0 then
		reply( string.format( "cleared %d old city shapes -- letting them settle", removed ) )
	end

	-- MEASURED: "GRIEF ALARM: 628 shapes lost" in the log, seconds after a
	-- rebuild. Clearing the old city IS a mass deletion -- it is just ours. The
	-- alarm exists to catch the other kind, and one that cries wolf every time
	-- the host lays the city out is one nobody will believe at the moment it
	-- matters.
	self:sv_quietAlarm( 120 )

	self.sw.cityJob = {
		stage = "settle",
		settleUntil = sm.game.getCurrentTick() + World.CITY_SETTLE_TICKS,
		queue = Layout.buildOrder( g_swPlots.layout ),
		cursor = 1, built = 0, failed = 0, shapes = 0,
	}
	reply( string.format( "building %d plots outwards from spawn...",
		#self.sw.cityJob.queue ) )
end

-- The plaza and the streets. Imported once the old city has actually gone.
-- The shared ground: the plaza first, then every street as its OWN creation.
--
-- One import per piece, deliberately. See the note by Plots.STAND: a body is the
-- unit the engine rebuilds, so a street welded to nothing else means editing
-- anything in the city can never reprocess the rest of it.
function World.sv_buildShared( self )
	local pieces = g_swPlots:sv_deckBlueprints()
	local built, failed, holes = 0, 0, 0

	for _, piece in ipairs( pieces ) do
		local want = #piece.bp.bodies[1].childs
		local bodies, err = self:sv_importBlueprint( piece.bp )
		if bodies then
			self:sv_pinCity( bodies, false )   -- nobody builds on shared ground
			built = built + 1
			-- Count what actually landed. A blueprint child with `bounds` is one
			-- shape, so placed should equal want -- and if it ever does not, that
			-- is a missing walkway named in the log rather than noticed from a
			-- screenshot weeks later.
			local placed = 0
			for _, body in ipairs( bodies ) do
				if sm.exists( body ) then placed = placed + body:getShapeCount() end
			end
			if placed ~= want then
				holes = holes + 1
				sm.log.warning( string.format(
					"[ServerWorks] %s: asked for %d shapes, got %d -- the city has holes",
					piece.label, want, placed ) )
			end
		else
			failed = failed + 1
			if failed == 1 then
				sm.log.warning( string.format( "[ServerWorks] %s import failed: %s",
					piece.label, tostring( err ) ) )
			end
		end
	end

	sm.log.info( string.format(
		"[ServerWorks] shared ground: %d separate creations, %d failed, %d short",
		built, failed, holes ) )
end

function World.sv_importBlueprint( self, bp )
	local wrote, str = pcall( sm.json.writeJsonString, bp )
	if not wrote then return nil, str end
	local placed, bodies = pcall( sm.creation.importFromString, self.world, str,
		sm.vec3.zero(), sm.quat.identity(), true, true )
	if not placed then return nil, bodies end
	return bodies or {}
end

function World.sv_pinCity( self, bodies, buildable )
	for _, body in ipairs( bodies or {} ) do
		if sm.exists( body ) then
			pcall( function()
				body:setConvertibleToDynamic( false )
				body:setDestructable( false )
				body:setLiftable( false )
				body:setBuildable( buildable )
			end )
		end
	end
end

function World.sv_stepCity( self )
	local job = self.sw.cityJob
	if job == nil then return end

	if job.stage == "settle" then
		if sm.game.getCurrentTick() < job.settleUntil then return end
		job.stage = "plots"
		self:sv_buildShared()
		return
	end

	local last = math.min( job.cursor + 3, #job.queue )
	for i = job.cursor, last do
		local cell = job.queue[i]
		local bodies, err = self:sv_importBlueprint(
			g_swPlots:sv_plotBlueprint( cell.col, cell.row ) )
		if bodies then
			-- buildable TRUE: a plot slab exists to be built on, and the build
			-- welding to it is what makes the plot exportable as one creation.
			self:sv_pinCity( bodies, true )
			job.built = job.built + 1
		else
			job.failed = job.failed + 1
			if job.failed == 1 then
				sm.log.warning( "[ServerWorks] plot import failed: " .. tostring( err ) )
			end
		end
	end
	job.cursor = last + 1

	if job.cursor > #job.queue then
		local g = g_swPlots.grid
		local w, h = g_swPlots:sv_extent()
		sm.log.info( string.format( "[ServerWorks] city built: %d plots, %d failed",
			job.built, job.failed ) )
		self:sv_reportWhereTheCityLanded()
		self:sv_broadcast( string.format(
			"City built: %d plots of %d blocks, %.0f x %.0f m across, %d block plaza at spawn.%s",
			job.built, g.plot, w * Plots.BLOCK, h * Plots.BLOCK,
			g_swPlots.layout.plaza and g_swPlots.layout.plaza.w or 0,
			job.failed > 0 and string.format( " %d failed.", job.failed ) or "" ) )
		self.sw.cityJob = nil
	end
end

-- Clear by SHAPE, not by body. A plot slab with somebody's build welded onto it
-- is part of that build's body, so destroying the body would delete their work
-- and testing the body's height missed it entirely -- which is how a rebuild
-- ended up laying a second city on top of the first.
-- Say what zone every city body actually resolves to.
--
-- The check that would have caught "I cant place blocks on the concrete but I
-- can delete it" the moment the city was built, instead of several versions
-- later. Every plot slab should locate to a PLOT; if they are coming back as
-- plaza or as nothing, the plot rules are being applied to the wrong ground and
-- nothing downstream can be right.
--
-- Once per build, not per tick.
function World.sv_reportWhereTheCityLanded( self )
	local ok, err = pcall( function()
		local kinds, checked = {}, 0
		for _, body in ipairs( sm.body.getAllBodies() ) do
			if sm.exists( body ) and not isGhostBody( body ) and holdsCity( body ) then
				local z = g_swPlots:sv_bodyZone( body )
				local kind = z and z.kind or "OFF THE CITY"
				kinds[kind] = ( kinds[kind] or 0 ) + 1
				checked = checked + 1
			end
		end
		local parts = {}
		for kind, n in pairs( kinds ) do
			parts[#parts + 1] = string.format( "%s %d", kind, n )
		end
		table.sort( parts )
		sm.log.info( string.format(
			"[ServerWorks] where the city landed: %d bodies -- %s",
			checked, table.concat( parts, ", " ) ) )
		if ( kinds.plot or 0 ) < 1 then
			sm.log.warning( "[ServerWorks] NOT ONE plot body located to a plot. "
				.. "Plot permissions cannot work in this state." )
		end
	end )
	if not ok then
		sm.log.warning( "[ServerWorks] city report failed: " .. tostring( err ) )
	end
end

function World.sv_clearFloor( self )
	local removed = 0
	for _, body in ipairs( sm.body.getAllBodies() ) do
		if sm.exists( body ) and not isGhostBody( body ) then
			for _, shape in ipairs( body:getShapes() ) do
				if sm.exists( shape ) and g_swPlots:sv_isCityShape( shape ) then
					shape:destroyShape()
					removed = removed + 1
				end
			end
		end
	end
	return removed
end
