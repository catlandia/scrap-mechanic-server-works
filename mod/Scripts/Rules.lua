-- Rules -- the server's posted rules, enforced instead of just posted.
--
-- Straight off the rules board from the 2026-08-22 event. Every number here is a
-- setting, because the numbers on that board are one host's taste and the next
-- event will want different ones.
--
--   1  No basements                              minbuildheight
--   2  One plot per player                       (already enforced in Plots)
--   3  No building before build time starts      buildopen
--   4  Don't spam lights                         maxlights
--   5  Don't leave radios on                     radios
--   6  Max 1 cook/dress/craft bot per plot       maxbots
--   7  No noise pollution                        (see the note on horns below)
--   8  Multiple people can share plots           (already enforced in Plots)
--   9  No griefing; bans are permanent           (already enforced in Identity)
--  10  Max 10 combined bearings/pistons/         maxjoints
--      suspensions per plot
--  11  No fireworks, explosives or plasmadrills  fireworks / plasmadrills
--  12  No beacons                                beacons
--
-- Rule 10 is worth noticing: the community independently arrived at counting
-- JOINTS rather than blocks. That is the correct performance metric -- a large
-- static sculpture is nearly free, twenty bearings are not -- and it means the
-- rules board and the server's own interests already agree.
--
-- Counting joints does not need a uuid list at all: body:getCreationJoints()
-- returns them directly. The uuid sets below are only for the parts that have to
-- be recognised individually.

Rules = class( nil )

-- TWO CADENCES, NOT ONE.
--
-- REPORTED: "item detection is a bit too slow. you can run it faster if you only
-- check ocupied places with players curently on the server ocupied."
--
-- Which is the right optimisation and worth spelling out. A plot can only go
-- over its budget if somebody is BUILDING on it, and somebody building on it is
-- standing on it. Every other plot in the city is a plot whose contents cannot
-- have changed since the last pass, and walking it is pure cost.
--
-- So the fast pass runs five times as often over the handful of plots that have
-- people on them, and the full pass keeps its old five seconds and still covers
-- everything -- contraband dropped on a road, a plot whose owner logged off
-- mid-build, a body that drifted somewhere nobody is standing. Nothing is lost;
-- the common case just answers five times sooner.
--
-- Plots.sv_updateOccupancy already knows who is standing where -- it runs every
-- tick and is the only thing in the mod that looks -- so the scope costs nothing
-- to compute.
Rules.AUDIT_SECONDS = 5      -- the FULL pass: every body, every plot, contraband
Rules.FAST_SECONDS = 1       -- the SCOPED pass: only plots somebody is on

local function set( list )
	local out = {}
	for _, u in ipairs( list ) do out[u] = true end
	return out
end

-- Uuids read out of the game's own shapesets under Objects/Database/ShapeSets.
local BOTS = set{
	"b63c6440-dfc2-4da7-acdb-3c385080b2e4",   -- craftbot1
	"b7571f6f-9d53-44ba-99d2-3b4f05e6fd0f",   -- craftbot2
	"1c83675f-7c77-4cbb-875b-79d4bd46100d",   -- craftbot3
	"c69a7855-d915-4784-af81-d0a8849e458f",   -- craftbot4
	"4fcb4cb8-7623-11ea-bc55-0242ac130003",   -- craftbot5
	"05900757-a49f-4907-b498-96bfd2b15176",   -- portablecraftbot
	"5cb15c93-4fa9-48da-9974-2e95ca6c9e1c",   -- refinery
	"a930a42f-63ed-4fb0-933e-56ce8a889cc5",   -- resourcecontainer
	"2af00456-b22e-4743-b338-a91934aba7c5",   -- cookbot
	"767a3121-2c31-473c-a5ab-27e188fdd55a",   -- dressbot
	"2ff2b13f-5a50-443c-bbda-1f40f6aa917f",   -- workbench
}

-- Not exhaustive and cannot be: every shapeset and every Blocks-and-Parts mod
-- can add more lights. This covers vanilla's own light parts. Treat maxlights as
-- a strong nudge rather than an airtight cap.
local LIGHTS = set{
	"5e3dff9b-2450-44ae-ad46-d2f6b5148cbf", "695d66c8-b937-472d-8bc2-f3d72dd92879",
	"e91b0bf2-dafa-439e-a503-286e91461bb0", "7b2c96af-a4a1-420e-9370-ea5b58f23a7e",
	"ed27f5e2-cac5-4a32-a5d9-49f116acc6af", "1e2485d7-f600-406e-b348-9f0b7c1f5077",
	"16ba2d22-7b96-4c5e-9eb7-f6422ed80ad4", "85339a1d-e67f-4c63-94fd-4a1cf8c25810",
	"6620ceb4-3c35-4a61-9d98-f923d2277395", "13ce3374-841a-4ad2-a6c3-ad0dabc1963d",
	"da6e54df-a223-4a0e-b42f-ddeddd33f5b3", "073f92af-f37e-4aff-96b3-d66284d5081c",
	"47062936-5d28-43ec-81b5-8fdb619e97e4", "2c90e412-9476-40d9-a440-228c888186bd",
	"ebefa387-fe4a-4839-bdd9-b6b4da39368f",
	-- dekotora set: the single biggest source of "don't spam lights"
	"eb5ba645-ef8c-430c-a037-d15d752bbcd3", "7b57beb6-26c2-42e1-b252-33a5441924fe",
	"1506a3ab-b545-424a-92a0-7395be9e76f6", "7dad8565-b3c3-4ffb-aec2-6df8eb82f06e",
	"382924d1-66f5-49e2-949c-aa5aa319ad72", "67900105-8c85-45b4-a35c-038b69f5eacf",
	"cdd6762b-263f-4dbc-b859-bceb56dbe92d", "fc0d73fa-d01f-407d-b5e2-2318a61d27df",
	"64a83163-23f6-4f10-bb6b-97c43c43f601", "d84d768a-774e-491e-8a95-da1d4afa6df7",
	"85a5f261-dd80-42db-9386-cb8606382d9c", "aba65407-60a8-4640-881f-a67cb58b5956",
	"e392d6d0-cfc3-48b5-8617-d5c9a7c624aa",
}

-- Contraband. Each maps to the setting that permits it.
--
-- alwaysRemove means "delete on sight regardless of the autoremove setting".
-- A beacon is a rule infraction and a warning is the right response. A live
-- cornade is a hazard, and warning the chat that one exists while leaving it
-- sitting there is useless -- which is why explosives kept going off after the
-- tool guard started blocking the cornade TOOL: these are placeable shapes, and
-- sm.tool.forceTool has no reach over a shape someone has already put down.
local CONTRABAND = {
	["e3bdeea5-d349-4d08-9b5a-5695ea05537e"] =
		{ setting = "cornades", label = "cornade", alwaysRemove = true },
	["a4c1590f-c491-4e7f-974a-f1cd09503c18"] =
		{ setting = "cornades", label = "armed explosive", alwaysRemove = true },
	["a5985971-1f95-4373-a5d9-4ce0a3e74851"] = { setting = "beacons", label = "beacon" },
	["78677314-1885-4c9e-87ee-04cdc929b0dc"] = { setting = "fireworks", label = "fireworks" },
	["9b9c0a82-a9bf-41d4-a599-58182f162058"] = { setting = "plasmadrills", label = "plasma drill" },
	["660c50e1-081d-449c-a405-785d4c26328d"] = { setting = "plasmadrills", label = "plasma drill" },
	["4a3d40d4-ce86-4a68-b042-8d107ea39d78"] = { setting = "plasmadrills", label = "plasma drill" },
	-- Rules 5 and 7, noise. There is no binding to mute a part or rate-limit a
	-- sound, so the only lever over "don't leave radios on" and "no noise
	-- pollution" is whether the noisemaker may exist at all.
	["dfefc9d7-db03-4d25-ad85-eae1d824d8c0"] = { setting = "radios", label = "radio" },
	["818f4e15-ff51-4fed-b874-723a25d62e1c"] = { setting = "horns", label = "horn" },
	["967b042a-2f92-4fa1-9d7a-801b7faf4a6e"] = { setting = "horns", label = "LED horn" },
}

function Rules.sv_onCreate( self )
	self.nextFull = 0
	self.nextFast = 0
	self.violations = {}      -- plotIndex -> { reason strings }
	self.lastPerPlot = {}     -- plotIndex -> counts, what /budget prints
	self.lastReported = {}
end

-- One pass over the bodies, bucketed by plot. Runs on a timer rather than every
-- tick: budgets are a slow-moving property and paying for the scan 40 times a
-- second buys nothing. See Rules.FAST_SECONDS for the two cadences.
function Rules.sv_audit( self, tick, plots, getSetting )
	local full = tick >= ( self.nextFull or 0 )
	if not full and tick < ( self.nextFast or 0 ) then
		return nil
	end
	self.nextFast = tick + Rules.FAST_SECONDS * 40

	-- nil scope means "everything". A scoped pass looks only at the plots
	-- somebody is standing on or beside; see the note by Rules.FAST_SECONDS.
	local scope = nil
	if full then
		self.nextFull = tick + Rules.AUDIT_SECONDS * 40
	else
		scope = plots:sv_activePlots()
		if next( scope ) == nil then
			return nil            -- nobody near a plot: nothing can have changed
		end
	end

	local maxJoints = tonumber( getSetting( "maxjoints" ) ) or 0
	local maxBots = tonumber( getSetting( "maxbots" ) ) or 0
	local maxLights = tonumber( getSetting( "maxlights" ) ) or 0
	local minZ = tonumber( getSetting( "minbuildheight" ) )

	local perPlot = {}
	local contraband = {}
	-- getCreationJoints returns the joints of the WHOLE creation, and every body
	-- in that creation returns the same list. Counting per body would multiply a
	-- 4-bearing car by its body count and fail the budget instantly, so each
	-- creation is only counted once.
	local countedCreations = {}

	local function bucket( i )
		perPlot[i] = perPlot[i] or { joints = 0, bots = 0, lights = 0, deep = 0 }
		return perPlot[i]
	end

	-- A scoped plot has to be recomputed even when it turns out to hold nothing
	-- at all, or a plot whose last offending part was just deleted would keep
	-- its stale violation until the next full pass. Seeding an empty bucket is
	-- what makes "trim it and it reopens" take one second rather than five.
	if scope then
		for index in pairs( scope ) do bucket( index ) end
	end

	-- Ghosts excluded: a creation held on the lift is not built yet, and counting
	-- it would put a plot over budget -- and therefore lock it -- for as long as
	-- somebody stood there holding a blueprint.
	for _, body in ipairs( sm.body.getAllBodies() ) do
		if sm.exists( body ) and not isGhostBody( body ) then
			local z = plots:sv_bodyZone( body )
			local index = ( z and z.kind == "plot" ) and z.index or nil

			-- The whole saving. Everything below this line is per-SHAPE work,
			-- and on a scoped pass a body that is not on a plot somebody is
			-- standing on never reaches any of it.
			if scope == nil or ( index ~= nil and scope[index] ) then

			local shapes = body:getShapes()
			for _, shape in ipairs( shapes ) do
				local uuid = tostring( shape.shapeUuid )
				-- Only on a full pass. A scoped pass never looks at a road or
				-- the plaza, which is where dropped contraband actually
				-- lands, so collecting it there would report a shrinking
				-- subset once a second and make it look like things were
				-- vanishing on their own.
				local banned = full and CONTRABAND[uuid]
				if banned and getSetting( banned.setting ) == false then
					contraband[#contraband + 1] = { shape = shape, label = banned.label, plot = index }
				end
				if index then
					local b = bucket( index )
					if BOTS[uuid] then b.bots = b.bots + 1 end
					if LIGHTS[uuid] then b.lights = b.lights + 1 end
					if minZ and shape.worldPosition.z < minZ then b.deep = b.deep + 1 end
				end
			end

			if index then
				local okId, creationId = pcall( function() return body:getCreationId() end )
				local key = okId and tostring( creationId ) or nil
				if key == nil or not countedCreations[key] then
					if key then countedCreations[key] = true end
					local ok, joints = pcall( function() return body:getCreationJoints() end )
					if ok and joints then
						bucket( index ).joints = bucket( index ).joints + #joints
					end
				end
			end

			end
		end
	end

	-- A full pass replaces the verdict outright. A scoped pass edits it, so a
	-- plot nobody is standing on keeps whatever the last full pass said about it
	-- rather than silently becoming compliant because it was not looked at.
	if full then
		self.violations = {}
		self.lastPerPlot = {}
	end

	for index, b in pairs( perPlot ) do
		local reasons = {}
		if maxJoints > 0 and b.joints > maxJoints then
			reasons[#reasons + 1] = string.format( "%d bearings/pistons/suspensions (max %d)",
				b.joints, maxJoints )
		end
		if maxBots > 0 and b.bots > maxBots then
			reasons[#reasons + 1] = string.format( "%d craft/cook/dress bots (max %d)", b.bots, maxBots )
		end
		if maxLights > 0 and b.lights > maxLights then
			reasons[#reasons + 1] = string.format( "%d lights (max %d)", b.lights, maxLights )
		end
		if b.deep > 0 then
			reasons[#reasons + 1] = string.format( "%d blocks below ground (no basements)", b.deep )
		end
		-- nil, not "leave it alone": clearing a violation is exactly what a
		-- scoped pass exists to do quickly.
		self.violations[index] = ( #reasons > 0 ) and reasons or nil
		-- Kept so /budget can SHOW the numbers rather than leaving somebody to
		-- infer them from whether their plot locked. "I am a bit sceptical of
		-- that if it works" is a fair thing to be, and a readout answers it.
		self.lastPerPlot[index] = b
	end

	return { perPlot = perPlot, contraband = contraband, full = full, scope = scope }
end

-- What a plot is using, against what it is allowed. nil until the first audit,
-- which is at most Rules.AUDIT_SECONDS old.
function Rules.sv_budgetLines( self, index, getSetting )
	local out = {}
	local counts = self.lastPerPlot and self.lastPerPlot[index]
	if counts == nil then
		out[#out + 1] = string.format( "plot %d: nothing counted yet", index )
		return out
	end

	local rows = {
		{ "bearings/pistons/suspensions", counts.joints, "maxjoints" },
		{ "craft/cook/dress bots", counts.bots, "maxbots" },
		{ "lights", counts.lights, "maxlights" },
	}
	out[#out + 1] = string.format( "plot %d, as of the last audit:", index )
	for _, row in ipairs( rows ) do
		local limit = tonumber( getSetting( row[3] ) ) or 0
		out[#out + 1] = string.format( "   %-30s %d / %s%s", row[1], row[2],
			limit > 0 and tostring( limit ) or "unlimited",
			( limit > 0 and row[2] > limit ) and "   OVER" or "" )
	end
	if counts.deep > 0 then
		out[#out + 1] = string.format( "   %-30s %d   OVER", "blocks below ground", counts.deep )
	end

	local why = self.violations and self.violations[index]
	out[#out + 1] = why
		and "   -> no NEW parts until you trim it -- removing still works"
		or "   -> within the limits"
	return out
end

function Rules.sv_overBudget( self, index )
	return self.violations[index] ~= nil
end

function Rules.sv_lines( self, index )
	return self.violations[index]
end

-- Report a plot's problems to its owner at most once per audit, so a plot that
-- stays over budget does not spam the chat every five seconds.
function Rules.sv_shouldReport( self, index, tick )
	local last = self.lastReported[index]
	if last and tick - last < Rules.AUDIT_SECONDS * 40 * 6 then
		return false
	end
	self.lastReported[index] = tick
	return true
end
