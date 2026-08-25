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
-- catch bodies created since. The patrol reads a handful of cheap getters as a
-- sentinel
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
		-- TRUE, AND IT WAS FALSE FOR THREE VERSIONS OF "still static".
		--
		-- REPORTED, over and over, about an imported creation: "welded to air",
		-- "still is statick", "still doesnt work". Three fixes went into the
		-- lift -- placing one, verifying it, releasing it -- and none of them
		-- could ever have worked, because this line undid all of them a second
		-- later.
		--
		-- MEASURED, the real resolver against a body outside the city:
		--
		--   open terrain  zone=sweep  profile=sweep  convertibleToDynamic=False
		--   on a plot     zone=true   profile=open   convertibleToDynamic=True
		--
		-- Anything that lands on ground nobody may build on is swept, and swept
		-- meant "can never become a moving body". So an import outside a plot
		-- was pinned static by the patrol within a second of arriving, whatever
		-- the lift did. On a plot it worked; on terrain it was impossible.
		--
		-- The old value was not defensible on its own terms either. This profile
		-- is already liftable = true -- you may pick the thing up -- and a body
		-- that can go ON a lift but can never come OFF one is a contradiction,
		-- not a rule. Lifting it was the one thing the false value made useless.
		--
		-- It costs nothing that matters. convertibleToDynamic PERMITS a
		-- conversion, it does not cause one: litter sits static exactly as
		-- before until something actually converts it, so the static-bodies-are
		-- -cheap argument still holds for everything that is really litter.
		convertibleToDynamic = true,
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

-- BUFFER TIME. Asked for as: "in bufer time you can paint. edit settings. use
-- controllers. and other stuff like that. but not place or brake blocks. so you
-- can polish some mechanic stuff if you messed it up a bit."
--
-- So it is the open profile with the two destructive verbs taken out. Everything
-- that adjusts a build you have already made stays: repaint it, rewire a
-- controller, sit in the seat and drive it, press the buttons. What you cannot
-- do is add a block or take one away, which is what makes the buffer a judging
-- window rather than extra build time.
--
-- convertibleToDynamic stays TRUE on purpose -- "use controllers" means the
-- thing has to be able to move.
PROFILES.polish = {
	buildable = false,
	erasable = false,
	connectable = true,
	paintable = true,
	liftable = false,
	usable = true,
	destructable = false,
	convertibleToDynamic = true,
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

-- OVER BUDGET: the open profile with PLACING taken out, and nothing else.
--
-- REPORTED: "I cant break the block if I hit the limit. so like I am stuck in a
-- loop I cant remove the bearing that prevents from building."
--
-- Going over the per-plot part limit used to hand the plot the LOCKED profile,
-- and locked is erasable = false. So the limit forbade the one action that could
-- satisfy it. The owner could not trim, could not undo, could not do anything
-- except find the host -- which is the worst possible failure mode for a rule
-- whose whole purpose is to be a brake rather than a punishment.
--
-- Trim keeps everything else: erase, repaint, rewire, sit in it and drive it.
-- Add a part and nothing happens. Five seconds after the offending bearing comes
-- off, the audit reopens the plot.
--
-- Two profiles, because the open profile it is derived from depends on the
-- `destructible` setting. See TRIM_OF below.
PROFILES.trim = {
	buildable = false,
	erasable = true,
	connectable = true,
	paintable = true,
	liftable = true,
	usable = true,
	destructable = false,
	convertibleToDynamic = true,
}

PROFILES.trim_destructible = {
	buildable = false,
	erasable = true,
	connectable = true,
	paintable = true,
	liftable = true,
	usable = true,
	destructable = true,
	convertibleToDynamic = true,
}

-- THE GROUND IS PINNED, WHATEVER ELSE ITS PROFILE ALLOWS.
--
-- Every profile above gets a twin with liftable and convertibleToDynamic forced
-- false, and any body that is part of the city floor gets the twin.
--
-- This is a real bug being fixed and it is worth writing down. `open` -- the
-- profile the whole city runs under during build time -- sets liftable = true
-- and convertibleToDynamic = true. Plot slabs are not scenery (sv_isScenery
-- requires every shape to be metal, and a plot has concrete in it), so during an
-- event EVERY PLOT FLOOR IN THE CITY was liftable and convertible. Anyone with a
-- lift could pick up somebody's plot, and a slab that converts to dynamic is a
-- floating object with nothing holding it.
--
-- World.sv_pinCity does set both to false at import, but the protection patrol
-- reapplies the full profile over the top of it seconds later, so the pinning
-- never survived. It has to live in the profile or it does not live at all.
--
-- REPORTED, repeatedly, as "the concrete is not attached" -- and a floor you can
-- carry away with a lift is not attached in the most literal sense there is.
local PINNED = {}
for name, profile in pairs( PROFILES ) do
	local twin = {}
	for flag, value in pairs( profile ) do twin[flag] = value end
	twin.liftable = false
	twin.convertibleToDynamic = false
	PINNED[name] = twin
end

-- The profile table, for dev/test_logic.py only. PROFILES is file-local on
-- purpose -- nothing outside this file should be picking flags out of it -- but
-- a check that re-declares the table cannot catch a change to the real one.
function Protection.Sv_ProfilesForTest()
	return PROFILES
end

Protection.MODES = { "open", "locked", "display", "sweep", "polish" }

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
		-- paintable and connectable are here for `polish`, which agrees with
		-- `display` on all four flags above. Without them, prep -> buffer found
		-- every body already correct and applied nothing, so buffer time never
		-- actually became paintable. Exactly the V15 bug in a new profile, and
		-- dev/test_logic.py caught it before the game did -- it reads the field
		-- list straight out of this function, so the two cannot drift.
		and body:isPaintable() == p.paintable
		and body:isConnectable() == p.connectable
end

-- Which profile a given body should be under. /lockdown deliberately outranks
-- everything: when the host or the grief alarm seals the world, a plot owner
-- standing on their own plot must not punch a hole in it.
-- Returns the profile AND its name, so a sweep can say what it decided rather
-- than only how many bodies it touched. "99 bodies, 99 changed" does not tell
-- you whether the plots came out buildable; "open 96, locked 2, sweep 1" does.
-- The ground's twin, if this body is the ground. One place, so every return path
-- below goes through it and none can forget.
-- Modes in which the ground is NOT pinned: build time, and build time only.
--
-- "the stand the plot is on. and the plot it self shall be destructuble and
-- placable. aka not protected when build time."
--
-- While the clock is running, a plot and the stand under it belong to whoever
-- is building on them, to change however they like -- and presence enforcement
-- is what keeps that to their own plot, not a flag on the body.
--
-- Every other mode still pins. That is when pinning actually earns its keep:
-- nobody should be able to lift somebody's plot away during prep, during the
-- buffer, after the event has ended, or under a /lockdown.
-- trim is build time too -- a plot over its budget is still a plot somebody is
-- building on, and pinning the ground under it would stop them lifting their own
-- slab for no reason connected to the part limit.
local GROUND_FREE = {
	open = true, open_destructible = true,
	trim = true, trim_destructible = true,
}

-- Which trim profile goes with which open profile.
--
-- polish maps to ITSELF on purpose. During buffer time nobody may place OR erase
-- anything, so being over budget blocks nothing that was not already blocked,
-- and handing out the trim profile there would quietly reintroduce erasing into
-- the one window that exists to have neither.
local TRIM_OF = {
	open = "trim",
	open_destructible = "trim_destructible",
	polish = "polish",
}

local function forBody( self, profile, name, body )
	if self.groundTest and PINNED[name] and not GROUND_FREE[name] then
		local ok, ground = pcall( self.groundTest, body )
		if ok and ground then
			return PINNED[name], name
		end
	end
	return profile, name
end

local function profileFor( self, body )
	if isLockedMode( self.mode ) then
		-- One thing escapes a locked world: litter on ground nobody may build on.
		--
		-- /lockdown and the end of an event both lock everything, and that used
		-- to include the craftbots and gems dropped on the plaza -- which made
		-- them permanent, since the world stays locked between events. Freezing
		-- the builds is the point; freezing the rubbish with them is not.
		--
		-- Only a "sweep" verdict gets through. Everything the resolver considers
		-- buildable ground is still locked, which is what /lockdown means.
		if self.resolver then
			local verdict = self.resolver( body )
			if verdict == "sweep" then
				return forBody( self, PROFILES.sweep, "sweep", body )
			end
		end
		return forBody( self, PROFILES[self.mode], self.mode, body )
	end
	-- What "you may build here" resolves to depends on the MODE, not just on the
	-- settings. In polish mode a plot you are allowed to touch gets the polish
	-- profile rather than the open one -- so buffer time keeps every plot rule
	-- intact (somebody else's occupied plot is still locked to you) and only
	-- changes what being allowed lets you DO.
	local openProfile, openName = PROFILES.open, "open"
	if Settings.Get( "destructible" ) == true then
		openProfile, openName = PROFILES.open_destructible, "open_destructible"
	end
	if self.mode == "polish" then
		openProfile, openName = PROFILES.polish, "polish"
	end
	if self.resolver then
		local verdict = self.resolver( body )
		-- true/false for the common two, or a profile name for anything else.
		if verdict == true then return forBody( self, openProfile, openName, body ) end
		if verdict == false then return forBody( self, PROFILES.locked, "locked", body ) end
		-- Named rather than left to the generic string branch below, because
		-- which trim profile is right depends on the mode: see TRIM_OF.
		if verdict == "trim" then
			local name = TRIM_OF[openName] or "trim"
			return forBody( self, PROFILES[name], name, body )
		end
		if type( verdict ) == "string" and PROFILES[verdict] then
			return forBody( self, PROFILES[verdict], verdict, body )
		end
	end
	if self.mode == "open" then
		return forBody( self, openProfile, openName, body )
	end
	return forBody( self, PROFILES[self.mode], self.mode, body )
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

-- Which bodies are the city floor. Set by World; see Plots.sv_isGround.
function Protection.sv_setGroundTest( self, fn )
	self.groundTest = fn
end

function Protection.sv_setResolver( self, fn )
	self.resolver = fn
end

-- Does the current MODE already deny building on its own?
--
-- `polish` (buffer time) is buildable = false and erasable = false in its own
-- right, so the separate `buildopen` blanket has nothing left to add -- and
-- applying it anyway replaced the polish profile with `locked`, which took away
-- the paint, the seats and the controllers that are the entire point of a
-- buffer. Buffer was identical to prep. REPORTED as "please make as I said to
-- the buffer time. because it doesnt work this way yet."
function Protection.sv_modeClosesBuilding( self )
	local p = PROFILES[self.mode]
	return p ~= nil and p.buildable == false
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
	local tally = {}

	for _, body in ipairs( bodies ) do
		if sm.exists( body ) and not isGhostBody( body ) then
			local p, name = profileFor( self, body )
			tally[name] = ( tally[name] or 0 ) + 1
			if not matchesProfile( body, p ) then
				applyProfile( body, p )
				changed = changed + 1
			end
		end
	end

	self.cursor = 1
	self.lastSweep = { bodies = #bodies, changed = changed }

	-- What the sweep actually decided, per profile. This is the line that says
	-- whether a plot slab came out buildable, which "N bodies, N changed" never
	-- did -- and "I cant build on my plot even when the time has started" is
	-- exactly the question it answers.
	local parts = {}
	for name, n in pairs( tally ) do
		parts[#parts + 1] = string.format( "%s %d", name, n )
	end
	table.sort( parts )
	return true, string.format( "%d bodies, %d changed [%s]",
		#bodies, changed, table.concat( parts, ", " ) )
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
		-- The body list SHRANK under a pass that was half done -- a cell
		-- unloading, a creation removed. Whatever this pass had counted is a
		-- fragment of a world that no longer exists, and adding it to the next
		-- pass would publish a census larger than the world. Void it.
		self.cursor = 1
		self.cycleShapes = 0
	end

	local last = math.min( self.cursor + Protection.BODIES_PER_PATROL - 1, n )
	for i = self.cursor, last do
		local body = bodies[i]
		-- Ghosts are skipped for the census too, not just the profile: a
		-- blueprint preview appearing and vanishing would swing the whole-world
		-- shape count by the size of the creation and set off the grief alarm.
		if sm.exists( body ) and isGhostBody( body ) then
			-- Said ONCE, ever. A ghost is a creation being placed by a lift, and
			-- pinning convertibleToDynamic = false on one makes the placement
			-- silently do nothing -- three versions were lost to that. If this
			-- line never appears in a log where somebody used a lift, the guard
			-- is not recognising ghosts and that is where to look next.
			if not self.sawGhost then
				self.sawGhost = true
				sm.log.info( "[ServerWorks] ghost body seen and skipped -- the lift guard works" )
			end
		elseif sm.exists( body ) then
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
		--
		-- THE CURSOR GOES BACK TO 1 HERE, NOT AT THE TOP OF THE NEXT TICK, AND
		-- THAT ONE LINE IS A FALSE GRIEF ALARM.
		--
		-- MEASURED, 2026-08-26, with 95 crowd bots building on 95 plots:
		--
		--     GRIEF ALARM: 2101 shapes lost in 20s
		--     GRIEF ALARM: 2618 shapes lost in 20s
		--     GRIEF ALARM: 3151 shapes lost in 20s
		--     GRIEF ALARM: 4334 shapes lost in 20s
		--
		-- Nothing was deleted. The world was GROWING the whole time.
		--
		-- The old code left the cursor at n+1 and relied on the guard at the top
		-- of the next tick to wrap it. That guard is `cursor > n` -- so if the
		-- world had grown even by one body in the meantime, n+1 was no longer
		-- past the end, the wrap did not happen, and the pass resumed from n+1.
		-- It then counted only the handful of bodies added since, hit the end,
		-- and published THAT as the whole-world census.
		--
		-- So on any growing world the census alternated between the true total
		-- and a tiny number, and the alarm -- which compares the current census
		-- against the peak within its window -- read the tiny one as the entire
		-- world vanishing. It then arms /lockdown on its own, which is the part
		-- that makes this worth a long comment: a real event, where twenty
		-- people are adding blocks as fast as they can, is exactly the condition
		-- that triggers it.
		--
		-- A census is a full pass over the CURRENT list. It has to begin at the
		-- beginning, whatever the list does next.
		self.census = self.cycleShapes
		self.cycleShapes = 0
		self.cursor = 1
	end
end

-- Whole-world shape count as of the last completed patrol cycle, or nil before
-- the first one finishes.
-- The resolved profile for one body. Exists so dev/test_logic.py can ask the
-- real resolver what a body would get, rather than reading the profile table and
-- assuming a body ever receives it -- which is how buffer time shipped with the
-- right profile and no way to reach it.
function Protection.sv_profileForTest( self, body )
	return profileFor( self, body )
end

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
