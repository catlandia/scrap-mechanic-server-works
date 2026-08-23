-- Protection -- the anti-grief core.
--
-- The engine fires no callback when a block is placed or a body is created, so
-- a protection state can only be held over a world by re-asserting it. Vanilla's
-- ChallengeData/.../BuilderWorld.lua does that across every body every tick at
-- 40 Hz. That is a correctness reference, not a performance one, and copying its
-- cadence is what would melt a host with a lobby on it.
--
-- So: one full sweep the instant the mode changes -- which is what makes
-- /lockdown a real panic button -- and then a slow patrol whose only job is to
-- catch bodies created since. The patrol reads two cheap getters as a sentinel
-- and skips all eight setters when a body already matches, so in steady state a
-- body costs two Lua calls per pass and nothing else.

Protection = class( nil )


--[[ ghosts ]]

-- THE LIFT FIX. Reported twice: "I cant use the lift to spawn creations".
--
-- Picking a creation out of the blueprint menu does not hand the lift a picture
-- of a build -- it spawns REAL BODIES into the world, marked as ghosts, and
-- hands the lift those. Vanilla proves it: Lift.client_onForceTool( self, bodies )
-- takes body objects, and Lift.sv_n_removeGhostBody calls body:destroyCreation()
-- on one (Data/Scripts/game/Lift.lua:383, :391).
--
-- Which means a ghost turns up in sm.body.getAllBodies() like anything else, and
-- the patrol below reached it within a fraction of a second and pinned
-- convertibleToDynamic = false and liftable = false on it -- every profile
-- except `open` does. A ghost that cannot convert to dynamic cannot become a
-- creation, so the placement quietly did nothing at all. No error, no log line,
-- nothing to read: exactly what was reported.
--
-- The earlier diagnosis -- that survival's toolset had taken uuid 8f190ce2 and
-- given us a lift with no blueprint handling -- was WRONG, and it is worth
-- writing down why, because the reasoning looked sound. Survival does own the
-- uuid. But SurvivalLift = class( Lift ) with exactly one live method
-- (client_onUpdate, calling setBlockSprint); the rest of that file is inside a
-- --[[ ]] block. It inherits every piece of blueprint handling there is. V19
-- swapped a working class for an identical one and changed nothing.
--
-- So: ghosts are invisible to us. Not protected, not counted, not cleared.
-- body:isGhost() is a real binding -- `python dev/dump_api.py Body`.
function isGhostBody( body )
	local ok, ghost = pcall( function()
		-- isOnVirtualLift as well, because that is how vanilla itself spots a
		-- body that is being placed rather than one that exists
		-- (Data/Scripts/game/Lift.lua:55, BuilderGuide.lua:159).
		return body:isGhost() or body:isOnVirtualLift()
	end )
	-- If either binding is missing on some future build, fail SAFE: treat the
	-- body as real and protect it. A protected ghost is a broken lift; an
	-- unprotected real body is a griefed event.
	return ok and ghost == true
end

-- Tuning. 128 bodies/tick at 40 Hz sweeps ~5000 bodies/second, so a busy event
-- world is fully re-checked a couple of times a second. Raise for faster
-- catch-up on new bodies, lower if the host is struggling.
Protection.BODIES_PER_PATROL = 128

-- destructable is false in every LOCKED profile and that is not negotiable: a
-- locked world is locked. In OPEN mode it follows the `destructible` setting,
-- because pinning it there meant explosives could never do anything even with
-- explosives switched on -- the host asked for a sandbox and got a museum.
--
-- Two open profiles rather than rebuilding one per body per tick: picking
-- between two static tables costs nothing.
--
-- `usable` is the one flag with a real trade-off, and stream chat from the
-- 2026-08-22 event settled it: someone griefed by "set the bearings in the
-- controller to 0" -- no blocks destroyed, the build just stopped working.
-- Tinkering a controller is an interaction, and setUsable(false) is the only
-- lever over it (client_onTinker lives on individual interactables like Seat
-- and PlasmaDrill, so there is nothing global to hook).
--
-- So locked defaults to usable = false. `/lockdown display` flips it back on
-- when you want the audience able to sit in seats and press buttons on finished
-- builds, and accept that a controller can be re-tuned.
local PROFILES = {
	open = {
		buildable = true,
		erasable = true,
		connectable = true,
		paintable = true,
		liftable = true,
		usable = true,
		destructable = false,
		convertibleToDynamic = true,
	},
	locked = {
		buildable = false,
		erasable = false,
		connectable = false,
		paintable = false,
		liftable = false,
		usable = false,
		destructable = false,
		convertibleToDynamic = false,
	},
	-- Anywhere you cannot build, you can clean. Walkways, corners and the ground
	-- outside the city are unbuildable, so nothing legitimate can exist there --
	-- which means anything that IS there is junk, and anyone should be able to
	-- sweep it up. This is what stops spawn spam ("a lot of craftbots are getting
	-- spawned") becoming permanently unremovable litter the moment the world locks.
	sweep = {
		buildable = false,
		erasable = true,
		connectable = false,
		paintable = false,
		liftable = true,
		usable = false,
		destructable = false,
		convertibleToDynamic = false,
	},
	-- Same as locked, but interactive: seats, buttons, switches still work.
	display = {
		buildable = false,
		erasable = false,
		connectable = false,
		paintable = false,
		liftable = false,
		usable = true,
		destructable = false,
		convertibleToDynamic = false,
	},
}

-- open, but explosives and the sledgehammer can actually break things.
PROFILES.open_destructible = {
	buildable = true,
	erasable = true,
	connectable = true,
	paintable = true,
	liftable = true,
	usable = true,
	destructable = true,
	convertibleToDynamic = true,
}

Protection.MODES = { "open", "locked", "display", "sweep" }

local function isLockedMode( mode )
	return mode == "locked" or mode == "display"
end

local function applyProfile( body, p )
	body:setBuildable( p.buildable )
	body:setErasable( p.erasable )
	body:setConnectable( p.connectable )
	body:setPaintable( p.paintable )
	body:setLiftable( p.liftable )
	body:setUsable( p.usable )
	body:setDestructable( p.destructable )
	body:setConvertibleToDynamic( p.convertibleToDynamic )
end

-- The sentinel has to be able to tell EVERY profile apart, or a switch between
-- two that share its fields silently does nothing.
--
--                    buildable destructable usable erasable
--   open                 T          F          T       T
--   open_destructible    T          T          T       T
--   locked               F          F          F       F
--   display              F          F          T       F
--   sweep                F          F          F       T
--
-- Four getters is what it takes for those five rows to be unique. Two was not:
-- display and locked agree on buildable and destructable, so /lockdown after a
-- /preset show found every body "already correct" and never cleared usable --
-- which is why buttons still worked in lockdown. MEASURED in game, reported as
-- "I can still press buttons on lockdown".
--
-- Cost is four calls per body per patrol pass instead of two, and only on the
-- 128-body slice. Correctness first; this is nowhere near the budget.
local function matchesProfile( body, p )
	return body:isBuildable() == p.buildable
		and body:isDestructable() == p.destructable
		and body:isUsable() == p.usable
		and body:isErasable() == p.erasable
end

-- Which profile a given body should be under. /lockdown deliberately outranks
-- everything: when the host or the grief alarm seals the world, a plot owner
-- standing on their own plot must not punch a hole in it.
local function profileFor( self, body )
	if isLockedMode( self.mode ) then
		return PROFILES[self.mode]
	end
	local openProfile = ( Settings.Get( "destructible" ) == true )
		and PROFILES.open_destructible or PROFILES.open
	if self.resolver then
		local verdict = self.resolver( body )
		-- true/false for the common two, or a profile name for anything else.
		if verdict == true then return openProfile end
		if verdict == false then return PROFILES.locked end
		if type( verdict ) == "string" and PROFILES[verdict] then
			return PROFILES[verdict]
		end
	end
	if self.mode == "open" then
		return openProfile
	end
	return PROFILES[self.mode]
end

function Protection.sv_onCreate( self, storedMode )
	self.mode = PROFILES[storedMode] and storedMode or "open"
	self.cursor = 1
	self.patrolEnabled = true
	self.lastSweep = { bodies = 0, changed = 0 }

	-- Shape census, for the grief alarm. The patrol already walks every body, so
	-- totalling getShapeCount() along the way costs one extra call per body and
	-- gives a whole-world shape count once per full cycle -- which is the only
	-- way to notice mass deletion at all, since the engine fires no callback
	-- when a plain block is destroyed.
	self.cycleShapes = 0
	self.census = nil

	-- Optional per-body override, set by Game when the plot system is on.
	-- Returns true (open), false (locked) or nil (defer to the global mode).
	self.resolver = nil
end

function Protection.sv_setResolver( self, fn )
	self.resolver = fn
end

function Protection.sv_getMode( self )
	return self.mode
end

-- Full immediate sweep. Deliberately not amortised: when the host hits the
-- panic button they need the world locked now, not over the next few seconds.
-- A brief hitch here is the correct trade.
function Protection.sv_setMode( self, mode )
	if not PROFILES[mode] then
		return false, "unknown mode"
	end

	self.mode = mode
	local bodies = sm.body.getAllBodies()
	local changed = 0

	for _, body in ipairs( bodies ) do
		if sm.exists( body ) and not isGhostBody( body ) then
			local p = profileFor( self, body )
			if not matchesProfile( body, p ) then
				applyProfile( body, p )
				changed = changed + 1
			end
		end
	end

	self.cursor = 1
	self.lastSweep = { bodies = #bodies, changed = changed }
	return true, string.format( "%d bodies, %d changed", #bodies, changed )
end

-- The patrol. Only ever touches bodies that do not already match, which after
-- the initial sweep means only bodies that appeared since.
function Protection.sv_onFixedUpdate( self )
	if not self.patrolEnabled then
		return
	end

	local bodies = sm.body.getAllBodies()
	local n = #bodies
	if n == 0 then
		self.cursor = 1
		return
	end

	if self.cursor > n then
		self.cursor = 1
	end

	local last = math.min( self.cursor + Protection.BODIES_PER_PATROL - 1, n )
	for i = self.cursor, last do
		local body = bodies[i]
		-- Ghosts are skipped for the census too, not just the profile: a
		-- blueprint preview appearing and vanishing would swing the whole-world
		-- shape count by the size of the creation and set off the grief alarm.
		if sm.exists( body ) and not isGhostBody( body ) then
			self.cycleShapes = self.cycleShapes + body:getShapeCount()
			local p = profileFor( self, body )
			if not matchesProfile( body, p ) then
				applyProfile( body, p )
			end
		end
	end

	self.cursor = last + 1

	if self.cursor > n then
		-- Full cycle complete: publish the census and start counting again.
		self.census = self.cycleShapes
		self.cycleShapes = 0
	end
end

-- Whole-world shape count as of the last completed patrol cycle, or nil before
-- the first one finishes.
function Protection.sv_census( self )
	return self.census
end

function Protection.sv_status( self )
	return string.format(
		"protection: %s  |  patrol %s  |  last sweep: %d bodies, %d changed",
		self.mode,
		self.patrolEnabled and "on" or "OFF",
		self.lastSweep.bodies,
		self.lastSweep.changed
	)
end
