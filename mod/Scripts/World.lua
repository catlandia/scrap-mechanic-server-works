dofile( "$GAME_DATA/Scripts/game/worlds/CreativeFlatWorld.lua" )
dofile( "$CONTENT_DATA/Scripts/Layout.lua" )
dofile( "$CONTENT_DATA/Scripts/Protection.lua" )
dofile( "$CONTENT_DATA/Scripts/Plots.lua" )
dofile( "$CONTENT_DATA/Scripts/Rules.lua" )
dofile( "$CONTENT_DATA/Scripts/Snapshots.lua" )

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
		buildDeadline = nil,
		nextAutoSnapshot = nil,
		patrolFaulted = false,
		rulesFaulted = false,
		cityJob = nil,
	}

	g_swSnapshots = Snapshots()
	g_swSnapshots:sv_onCreate()

	local savedPlots = Plots.Sv_LoadFile()
	g_swPlots = Plots()
	g_swPlots:sv_onCreate( savedPlots )

	g_swProtection = Protection()
	g_swProtection:sv_onCreate( Settings.Get( "protection" ) )

	g_swProtection:sv_setResolver( function( body )
		-- Streets and the spawn plaza can never be built on, so they are always
		-- locked -- otherwise the "sweep" profile that keeps litter clearable off
		-- shared ground would let anyone delete the streets too.
		if g_swPlots:sv_isScenery( body ) then
			return "locked"
		end
		-- Rule 3: nothing is buildable at all until the host opens building.
		if Settings.Get( "buildopen" ) == false then
			return false
		end
		return g_swPlots:sv_bodyIsOpen( body )
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
end

function World.sv_applySettings( self )
	g_swPlots.enabled = Settings.Get( "plots" ) == true
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
function World.sv_checkGriefAlarm( self, tick )
	local census = g_swProtection:sv_census()
	if census == nil then return end

	local previous = self.sw.lastCensus
	self.sw.lastCensus = census

	if previous == nil or tick < self.sw.alarmQuietUntil then return end
	if g_swSnapshots:sv_busy() then return end

	local lost = previous - census
	if lost < ( tonumber( Settings.Get( "alarmdrop" ) ) or 250 ) then return end

	sm.log.info( string.format( "[ServerWorks] GRIEF ALARM: %d shapes lost", lost ) )
	self:sv_broadcast( string.format( "*** %d blocks just disappeared ***", lost ) )
	self:sv_quietAlarm( 30 )

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

	-- A plot over budget stops being buildable until its owner trims it. Nothing
	-- already built is taken away: over-budget is a brake, not a punishment.
	g_swPlots.overBudget = {}
	for index, reasons in pairs( g_swRules.violations ) do
		g_swPlots.overBudget[index] = true
		if g_swRules:sv_shouldReport( index, tick ) then
			local owner = g_swPlots.owners[index]
			local name = owner and Identity.Sv_NameOf( owner )
			for _, p in ipairs( sm.player.getAllPlayers() ) do
				if name and p.name == name then
					self:sv_reply( p, string.format(
						"Plot %d is over the server limits and is locked until you trim it:", index ) )
					for _, reason in ipairs( reasons ) do
						self:sv_reply( p, "   " .. reason )
					end
				end
			end
		end
	end

	if #report.contraband > 0 then
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

function World.sv_checkTimers( self, tick )
	if self.sw.buildDeadline and tick >= self.sw.buildDeadline then
		self.sw.buildDeadline = nil
		local locked, detail = g_swProtection:sv_setMode( "locked" )
		if locked then
			Settings.Sv_SetQuiet( "protection", "locked" )
			self:sv_broadcast( "Build time is up. BUILDS LOCKED -- " .. detail )
		end
		g_swSnapshots:sv_beginCapture( "buildend", self.world, self:sv_plotOfBody() )
	end

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
		local z = g_swPlots:sv_locate( body.worldPosition )
		return ( z and z.kind == "plot" ) and z.index or nil
	end
end

-- Wipe one plot, so a restore can repair a single build without flattening the
-- city around it.
function World.sv_clearPlot( self, index )
	local removed = 0
	for _, body in ipairs( sm.body.getAllBodies() ) do
		if sm.exists( body ) and not isGhostBody( body ) then
			local z = g_swPlots:sv_locate( body.worldPosition )
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
function World.sv_e_swCommand( self, params )
	local cmd, args, player = params.cmd, params.args, params.player
	local function reply( text ) self:sv_reply( player, text ) end

	if cmd == "/lockdown" or cmd == "/unlock" then
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
			sm.log.info( string.format( "[ServerWorks] protection -> %s (%s)", mode, detail ) )
			self:sv_broadcast(
				mode == "locked" and ( "BUILDS LOCKED (strict) -- " .. detail )
				or mode == "display" and ( "BUILDS LOCKED, seats and buttons still work -- " .. detail )
				or ( "Building reopened -- " .. detail ) )
		else
			reply( "Failed: " .. tostring( detail ) )
		end

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
		if self.sw.buildDeadline then
			local left = ( self.sw.buildDeadline - sm.game.getCurrentTick() ) / ( 60 * TICKS_PER_SECOND )
			reply( string.format( "build time remaining: %.1f min", left ) )
		end

	elseif cmd == "/buildtime" then
		local minutes = tonumber( args[2] ) or 0
		if minutes <= 0 then
			self.sw.buildDeadline = nil
			reply( "build timer cancelled" )
		else
			self.sw.buildDeadline = sm.game.getCurrentTick() + minutes * 60 * TICKS_PER_SECOND
			self:sv_broadcast( string.format( "Building closes in %g minutes.", minutes ) )
		end

	elseif cmd == "/snapshot" then
		local name = args[2]
		if name == nil or name == "" then name = "manual" end
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
					-- a radius was given: take the whole body
					for _, s in ipairs( body:getShapes() ) do s:destroyShape() end
					removed = 1
					reply( string.format( "removed the whole creation (%d shapes)", body:getShapeCount() ) )
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
				if sm.exists( body ) and not isGhostBody( body )
					and ( body.worldPosition - origin ):length() <= radius then
					for _, shape in ipairs( body:getShapes() ) do shape:destroyShape() end
					removed = removed + 1
				end
			end
			reply( string.format( "cleared %d bodies within %g m", removed, radius ) )
		elseif what == "walkways" then
			for _, body in ipairs( sm.body.getAllBodies() ) do
				if sm.exists( body ) and not isGhostBody( body ) then
					local z = g_swPlots:sv_locate( body.worldPosition )
					if z == nil or z.kind ~= "plot" then
						for _, shape in ipairs( body:getShapes() ) do shape:destroyShape() end
						removed = removed + 1
					end
				end
			end
			reply( string.format( "cleared %d bodies off walkways and open ground", removed ) )
		end
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
		Plots.Sv_SaveFile( g_swPlots )
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
		local z = g_swPlots:sv_locate( body.worldPosition )
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
	end
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
		if ok or released then Plots.Sv_SaveFile( g_swPlots ) end

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
	reply( ok and string.format( "sent you to plot %d", index ) or "teleport failed" )
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
function World.sv_buildFloor( self, reply )
	if self.sw.cityJob then
		reply( "already building" )
		return
	end
	local removed = self:sv_clearFloor()
	if removed > 0 then
		reply( string.format( "cleared %d old city shapes", removed ) )
	end

	-- The middle goes down first: the pillar, then the deck, then the plots
	-- outwards. Nothing overlaps anything, so this is purely about what the host
	-- sees appear -- but seeing spawn appear first is how you know the centre is
	-- where you meant it to be.
	for _, label in ipairs( { "pillar", "deck" } ) do
		local bp = ( label == "pillar" ) and g_swPlots:sv_pillarBlueprint()
			or g_swPlots:sv_deckBlueprint()
		if bp then
			local bodies, err = self:sv_importBlueprint( bp )
			if bodies then
				self:sv_pinCity( bodies, false )   -- nobody builds on shared ground
			else
				sm.log.warning( string.format( "[ServerWorks] %s import failed: %s",
					label, tostring( err ) ) )
			end
		end
	end

	local queue = Layout.buildOrder( g_swPlots.layout )
	self.sw.cityJob = { queue = queue, cursor = 1, built = 0, failed = 0 }
	reply( string.format( "building %d plots outwards from spawn...", #queue ) )
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
		self:sv_broadcast( string.format(
			"City built: %d plots of %d blocks, %.0f x %.0f m across, %d block plaza at spawn.%s",
			job.built, g.plot, w * Plots.BLOCK, h * Plots.BLOCK, g.spawn,
			job.failed > 0 and string.format( " %d failed.", job.failed ) or "" ) )
		self.sw.cityJob = nil
	end
end

-- Clear by SHAPE, not by body. A plot slab with somebody's build welded onto it
-- is part of that build's body, so destroying the body would delete their work
-- and testing the body's height missed it entirely -- which is how a rebuild
-- ended up laying a second city on top of the first.
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
