-- Snapshots -- undo for an event.
--
-- Locking builds only helps if someone armed the lock in time. The grief that
-- started this mod landed two minutes before an event ended, which is exactly
-- the case no amount of watching catches. So the world also needs a rollback.
--
-- The round trip is vanilla's own, not invented here:
--   export   sm.creation.exportToString( creation[1], true, onLift )
--            -- second arg true means "find the rest of the creation from this
--            -- body", so one call per creation, not per body
--   import   sm.creation.importFromString( world, str, vec3.zero(), quat.identity(), ... )
-- ChallengeData/.../BuilderWorld.lua exports a level that way and imports it
-- back at the origin, and the build lands where it was -- the blueprint carries
-- world-relative geometry, so nothing has to record positions separately.
--
-- Exporting is expensive per creation, so both directions run as amortised jobs
-- a few creations per tick rather than one long stall. A 40 Hz hitch during an
-- event is the thing this whole project is trying to avoid.

Snapshots = class( nil )

Snapshots.CREATIONS_PER_TICK = 4

-- WAIT AFTER CLEARING, BEFORE PUTTING ANYTHING BACK.
--
-- MEASURED, 2026-08-29, through the bridge: a restore of a 96-plot city
-- reported "195 creations, 0 failed" and came back with a hole where the plaza
-- had been. REPORTED, with a screenshot: "the load back in WORKS! the issue is
-- the middle doesnt".
--
-- The middle is the plaza, and the plaza is the FIRST entry in the file. The
-- restore cleared the world and then stepped on the very next tick, four
-- creations at a time -- so the first four went to the importer while the old
-- shapes were still standing in that space.
--
-- shape:destroyShape() does not take effect immediately; the engine tears
-- shapes down at the end of a tick. What lands in occupied space is anybody's
-- guess, and here the answer was nothing at all -- with no error, because
-- importFromString reports success either way. That is why "0 failed" and a
-- hole in the ground are not a contradiction.
--
-- THIS IS THE SAME BUG THE CITY BUILDER ALREADY FIXED, in another file:
-- World.CITY_SETTLE_TICKS exists for exactly this, and its comment describes
-- exactly this symptom ("brown ground showing between a plot and the walkway
-- beside it"). The fix never travelled to the other place that clears and
-- rebuilds, and nothing pointed that out because restore had never been run.
--
-- Same number, deliberately: whatever is right for one is right for the other,
-- and dev/test_logic.py asserts they stay in step.
Snapshots.SETTLE_TICKS = 20
Snapshots.INDEX = "$CONTENT_DATA/Snapshots/index.json"
Snapshots.AUTO_SLOTS = 6          -- rotating auto-snapshot names

local function snapPath( name )
	return "$CONTENT_DATA/Snapshots/" .. name .. ".json"
end

local function now()
	local ok, t = pcall( os.time )
	return ok and t or 0
end

function Snapshots.sv_onCreate( self )
	self.job = nil
	self.autoSlot = 0
	self.index = { snapshots = {} }

	local ok, exists = pcall( sm.json.fileExists, Snapshots.INDEX )
	if ok and exists then
		local read, loaded = pcall( sm.json.open, Snapshots.INDEX )
		if read and type( loaded ) == "table" and type( loaded.snapshots ) == "table" then
			self.index = loaded
		end
	end
end

function Snapshots.sv_saveIndex( self )
	local ok, err = pcall( sm.json.save, self.index, Snapshots.INDEX )
	if not ok then
		sm.log.warning( "[ServerWorks] could not write snapshot index: " .. tostring( err ) )
	end
end

function Snapshots.sv_busy( self )
	return self.job ~= nil
end

function Snapshots.sv_names( self )
	local out = {}
	for _, s in ipairs( self.index.snapshots ) do
		out[#out + 1] = string.format( "%s  (%d creations)", s.name, s.count or 0 )
	end
	return out
end

-- The same list as sv_names, STRUCTURED. sv_names formats each entry into a
-- line for chat, which a panel then has to take apart again to put a RESTORE
-- button beside the right name -- and a panel that parses a display string is a
-- panel that breaks the day the string changes.
--
-- Newest first, because a rollback almost always wants the most recent save and
-- the index appends.
function Snapshots.sv_list( self )
	local out = {}
	for i = #self.index.snapshots, 1, -1 do
		local s = self.index.snapshots[i]
		out[#out + 1] = { name = s.name, count = s.count or 0 }
	end
	return out
end

function Snapshots.sv_find( self, name )
	for i, s in ipairs( self.index.snapshots ) do
		if string.lower( s.name ) == string.lower( name ) then
			return i, s
		end
	end
	return nil
end


--[[ capture ]]

-- zoneOf( body ) -> plot index or nil. Recorded per creation so a single plot
-- can be rolled back on its own. Stream chat from the 2026-08-22 event is the
-- reason: "it was only a little bit that got broken on my build" -- the damage
-- was to a handful of plots, and wiping a whole city to repair three of them
-- would cost more than the grief did.
-- worldState is whatever describes the world besides its geometry -- today the
-- plot grid, the claims and the teams. See Plots.sv_restoreState for what is
-- deliberately left out.
function Snapshots.sv_beginCapture( self, name, world, zoneOf, worldState )
	if self.job then
		return false, "busy: " .. self.job.kind
	end

	-- Snapshot the creation LIST up front so the set stays consistent even if
	-- someone keeps building while the export runs.
	-- Ghosts filtered out first: a blueprint somebody happens to be holding on
	-- the lift is not part of the world and must not be saved into a snapshot,
	-- where a later /restore would spawn it for real.
	local real = {}
	for _, body in ipairs( sm.body.getAllBodies() ) do
		if sm.exists( body ) and not isGhostBody( body ) then
			real[#real + 1] = body
		end
	end
	local ok, creations = pcall( sm.body.getCreationsFromBodies, real )
	if not ok then
		return false, "could not enumerate creations"
	end

	self.job = {
		kind = "capture",
		name = name,
		world = world,
		creations = creations,
		cursor = 1,
		zoneOf = zoneOf,
		worldState = worldState,
		entries = {},
		failed = 0,
	}
	return true, string.format( "capturing %d creations", #creations )
end

function Snapshots.sv_stepCapture( self )
	local job = self.job
	local last = math.min( job.cursor + Snapshots.CREATIONS_PER_TICK - 1, #job.creations )

	for i = job.cursor, last do
		local creation = job.creations[i]
		local body = creation and creation[1]
		if body and sm.exists( body ) then
			local onLift = false
			pcall( function() onLift = body:isOnLift() end )
			local ok, str = pcall( sm.creation.exportToString, body, true, onLift )
			if ok and type( str ) == "string" then
				-- Parse into a table so the snapshot file is real nested JSON
				-- rather than a giant escaped string. Vanilla does the same.
				local parsed, tbl = pcall( sm.json.parseJsonString, str )
				if parsed then
					local plot = nil
					if job.zoneOf then
						local okZone, z = pcall( job.zoneOf, body )
						if okZone then plot = z end
					end
					job.entries[#job.entries + 1] = { plot = plot, bp = tbl }
				else
					job.failed = job.failed + 1
				end
			else
				job.failed = job.failed + 1
			end
		end
	end

	job.cursor = last + 1
	if job.cursor > #job.creations then
		return self:sv_finishCapture()
	end
	return nil
end

function Snapshots.sv_finishCapture( self )
	local job = self.job
	self.job = nil

	local payload = {
		name = job.name,
		at = now(),
		count = #job.entries,
		entries = job.entries,
		-- THE OTHER HALF OF A WORLD. Without this a snapshot is a pile of
		-- buildings with nobody owning any of them.
		plots = job.worldState,
	}

	local ok, err = pcall( sm.json.save, payload, snapPath( job.name ) )
	if not ok then
		sm.log.warning( "[ServerWorks] snapshot write failed: " .. tostring( err ) )
		return string.format( "snapshot '%s' FAILED to write: %s", job.name, tostring( err ) )
	end

	local i = self:sv_find( job.name )
	local entry = { name = job.name, at = payload.at, count = payload.count }
	if i then
		self.index.snapshots[i] = entry
	else
		table.insert( self.index.snapshots, entry )
	end
	self:sv_saveIndex()

	sm.log.info( string.format( "[ServerWorks] snapshot '%s': %d creations, %d failed",
		job.name, payload.count, job.failed ) )

	return string.format( "snapshot '%s' saved: %d creations%s", job.name, payload.count,
		job.failed > 0 and string.format( " (%d failed)", job.failed ) or "" )
end

-- REQUESTED: "the backups need to be the full world backups. just to be sure
-- with exact date and minutes writen."
--
-- Every capture already takes the WHOLE world -- sv_beginCapture enumerates
-- every creation there is, not the plots -- so what was missing was being able
-- to tell one from another. A rotating "auto3" tells you nothing about when it
-- was taken or what was happening.
--
-- os.date is available here for the same reason os.time is; Identity.lua has
-- been stamping the ban list with it since the beginning.
--
--   auto-2026-08-24_2247      the rotation, but readable
--   eventend-2026-08-24_2312  what happened, and when
--
-- Sorted alphabetically these also sort chronologically, which is what makes
-- /snapshots readable at a glance.
function Snapshots.Stamp()
	local ok, when = pcall( os.date, "%Y-%m-%d_%H%M" )
	if ok and type( when ) == "string" then return when end
	-- No clock: fall back to the tick count so two snapshots still differ.
	local got, tick = pcall( sm.game.getCurrentTick )
	return "t" .. tostring( got and tick or 0 )
end

function Snapshots.Name( prefix )
	return string.format( "%s-%s", prefix or "manual", Snapshots.Stamp() )
end

-- The rotation still bounds how many auto saves pile up, but each one now says
-- when it was taken.
function Snapshots.sv_autoName( self )
	self.autoSlot = ( self.autoSlot % Snapshots.AUTO_SLOTS ) + 1
	return Snapshots.Name( "auto" .. self.autoSlot )
end


--[[ restore ]]

-- Destructive by design: the world is cleared first, otherwise a restore leaves
-- every surviving build duplicated on top of itself. The caller is responsible
-- for making the host confirm.
-- opts.plot   restore only creations that were on that plot
-- opts.clear  function that wipes the area about to be rebuilt
function Snapshots.sv_beginRestore( self, name, world, opts )
	if self.job then
		return false, "busy: " .. self.job.kind
	end
	opts = opts or {}

	local _, entry = self:sv_find( name )
	if not entry then
		return false, string.format( "no snapshot called '%s'", name )
	end

	local ok, payload = pcall( sm.json.open, snapPath( entry.name ) )
	if not ok or type( payload ) ~= "table" then
		return false, string.format( "snapshot '%s' is unreadable", entry.name )
	end

	-- Whole-world only. A per-plot repair must not rewrite everybody's claims:
	-- the whole reason per-plot restore exists is that "it was only a little bit
	-- that got broken on my build", and taking the rest of the city's ownership
	-- with it would be a far bigger change than the damage.
	if opts.plot == nil and opts.restoreState and type( payload.plots ) == "table" then
		pcall( opts.restoreState, payload.plots )
	end

	local entries = payload.entries
	if type( entries ) ~= "table" then
		-- Snapshots written before per-plot capture existed: whole world only.
		if type( payload.blueprints ) ~= "table" then
			return false, string.format( "snapshot '%s' is unreadable", entry.name )
		end
		if opts.plot then
			return false, string.format( "snapshot '%s' predates per-plot restore -- whole world only", entry.name )
		end
		entries = {}
		for _, bp in ipairs( payload.blueprints ) do
			entries[#entries + 1] = { plot = nil, bp = bp }
		end
	end

	local wanted = {}
	for _, e in ipairs( entries ) do
		if opts.plot == nil or e.plot == opts.plot then
			wanted[#wanted + 1] = e
		end
	end

	if #wanted == 0 then
		return false, opts.plot
			and string.format( "snapshot '%s' has nothing on plot %d", entry.name, opts.plot )
			or string.format( "snapshot '%s' is empty", entry.name )
	end

	if opts.clear then
		opts.clear()
	else
		sm.event.sendToWorld( world, "sv_e_clear" )
	end

	self.job = {
		kind = "restore",
		name = entry.name,
		world = world,
		entries = wanted,
		cursor = 1,
		failed = 0,
		-- Nothing is imported until the tick this passes. See SETTLE_TICKS.
		settleUntil = sm.game.getCurrentTick() + Snapshots.SETTLE_TICKS,
	}
	return true, string.format( "cleared, restoring %d creation(s)%s", #wanted,
		opts.plot and string.format( " onto plot %d", opts.plot ) or "" )
end

function Snapshots.sv_stepRestore( self )
	local job = self.job
	local last = math.min( job.cursor + Snapshots.CREATIONS_PER_TICK - 1, #job.entries )

	for i = job.cursor, last do
		local ok, str = pcall( sm.json.writeJsonString, job.entries[i].bp )
		if ok and type( str ) == "string" then
			local placed = pcall( sm.creation.importFromString, job.world, str,
				sm.vec3.zero(), sm.quat.identity(), true, true )
			if not placed then
				job.failed = job.failed + 1
			end
		else
			job.failed = job.failed + 1
		end
	end

	job.cursor = last + 1
	if job.cursor > #job.entries then
		local total = #job.entries
		local failed = job.failed
		local name = job.name
		self.job = nil
		sm.log.info( string.format( "[ServerWorks] restored '%s': %d creations, %d failed",
			name, total - failed, failed ) )
		return string.format( "restored '%s': %d of %d creations", name, total - failed, total )
	end
	return nil
end


--[[ driver ]]

-- Returns a completion message when a job finishes, otherwise nil.
function Snapshots.sv_onFixedUpdate( self )
	if not self.job then
		return nil
	end
	if self.job.kind == "capture" then
		return self:sv_stepCapture()
	end
	-- The world was cleared a moment ago and the engine has not finished tearing
	-- those shapes down. Importing into space they still occupy loses whatever
	-- goes in first, silently. See Snapshots.SETTLE_TICKS.
	if self.job.settleUntil and sm.game.getCurrentTick() < self.job.settleUntil then
		return nil
	end
	return self:sv_stepRestore()
end

function Snapshots.sv_progress( self )
	local job = self.job
	if not job then
		return nil
	end
	local total = ( job.kind == "capture" ) and #job.creations or #job.entries
	return string.format( "%s '%s': %d/%d", job.kind, job.name, math.min( job.cursor - 1, total ), total )
end
