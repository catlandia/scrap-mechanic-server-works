-- Plots -- a claimable grid, and the only enforcement the engine actually allows.
--
-- READ THIS BEFORE CHANGING ANYTHING HERE.
--
-- Build permissions in Scrap Mechanic are a property of the BODY, not of the
-- player: setBuildable/setErasable/etc. There is no setBuildableBy( player ).
-- There is also no callback when a block is placed, so nothing can be blocked
-- at the moment it happens. Those two facts together mean "only build on your
-- own plot" cannot be implemented the obvious way.
--
-- What *is* enforceable is presence. A zone's bodies are unlocked only while
-- every player standing in that zone is authorised for it. The moment someone
-- unauthorised walks in, the zone's bodies lock, so there is nothing for them
-- to erase, repaint, rewire or carry off.
--
-- That leaves one hole -- standing in someone's plot to keep it locked and
-- block them from working -- so unauthorised occupants are also pushed back
-- out. Without the push, presence enforcement is itself a griefing tool.
--
-- GEOMETRY IS NOT IN THIS FILE. It is in Layout.lua, which is pure -- no sm.*
-- calls at all -- so the Game script, the World script and the client panel all
-- compute the city from the same code, and dev/test_layout.py can execute that
-- code outside the game and prove the result is a partition. It used to live
-- here and in a hand-copied mirror inside PlotsGui.lua, and the copies drifted.

Plots = class( nil )

Plots.BLOCK = 0.25

Plots.DEFAULT = Layout.DEFAULT

Plots.PUSH_INTRUDERS = true
Plots.PUSH_COOLDOWN_TICKS = 20      -- don't fight the player's own movement every tick

local function key_plot( i )        return "p" .. i end
local function key_fillerX( c, r )  return "x" .. c .. "_" .. r end
local function key_fillerY( c, r )  return "y" .. c .. "_" .. r end


-- Plot state lives in its own JSON file rather than the Game script's storage.
-- The World is created from inside CreativeGame.server_onCreate, so at the
-- moment World.server_onCreate runs there is no guarantee the Game has finished
-- populating its saved table. A file has no ordering problem.
Plots.FILE = "$CONTENT_DATA/Plots.json"

function Plots.Sv_LoadFile()
	local ok, exists = pcall( sm.json.fileExists, Plots.FILE )
	if not ok or not exists then return nil end
	local read, loaded = pcall( sm.json.open, Plots.FILE )
	return ( read and type( loaded ) == "table" ) and loaded or nil
end

function Plots.Sv_SaveFile( plots )
	local ok, err = pcall( sm.json.save, plots:sv_serialise(), Plots.FILE )
	if not ok then
		sm.log.warning( "[ServerWorks] could not write plots: " .. tostring( err ) )
	end
end

function Plots.sv_onCreate( self, saved )
	local cfg = ( saved and saved.grid ) or Layout.DEFAULT
	-- Migration. The plaza size used to be a module-level global written beside
	-- the grid rather than inside it, so a restart rebuilt a different city than
	-- the one the host laid out. It lives in the grid now; fold an old file in.
	if saved and saved.spawn ~= nil and cfg.spawn == nil then
		cfg.spawn = saved.spawn
	end
	self:sv_setGrid( cfg )
	self.owners = ( saved and saved.owners ) or {}     -- plotIndex -> permaId
	self.teams = ( saved and saved.teams ) or {}       -- plotIndex -> { otherIndex = true }
	self.requests = {}                                  -- fromIndex -> { toIndex = true }
	self.zoneOpen = {}
	self.overBudget = {}      -- plotIndex -> true, set by the rules audit
	self.lastPush = {}
	self.enabled = ( saved and saved.enabled ) or false
end

-- The grid and the derived segment lists are computed ONCE and cached. sv_locate
-- runs per player per tick and sv_bodyIsOpen runs per body per patrol slice, so
-- rebuilding the axis inside either of them would be the one genuinely hot piece
-- of arithmetic in the mod.
function Plots.sv_setGrid( self, cfg )
	self.grid = Layout.config( cfg )
	self.layout = Layout.grid( self.grid )
end

function Plots.sv_serialise( self )
	return { grid = self.grid, owners = self.owners, teams = self.teams,
		enabled = self.enabled }
end

function Plots.sv_extent( self )
	return self.layout.width, self.layout.height
end

-- Which zone a world position falls in. nil means outside the city entirely.
function Plots.sv_locate( self, pos )
	return Layout.locate( self.layout, pos.x / Plots.BLOCK, pos.y / Plots.BLOCK )
end

function Plots.sv_indexAt( self, col, row )
	return Layout.plotIndex( self.layout, col, row )
end

function Plots.sv_zoneKey( self, z )
	if z == nil then return nil end
	if z.kind == "plot" then return key_plot( z.index ) end
	if z.kind == "fillerX" then return key_fillerX( z.col, z.row ) end
	if z.kind == "fillerY" then return key_fillerY( z.col, z.row ) end
	return z.kind
end

-- Where /home and the plot marker point: the middle of a plot, on the deck.
function Plots.sv_plotWorldCentre( self, index )
	local bx, by = Layout.plotCentre( self.layout, index )
	if bx == nil then return nil end
	return sm.vec3.new( bx * Plots.BLOCK, by * Plots.BLOCK,
		( Plots.DECK_Z + 1 ) * Plots.BLOCK + 0.5 )
end

--[[ teams ]]
--
-- A LINK is a direct agreement between two plots, and it can only ever be made
-- between plots that are front, behind, left or right of each other -- never
-- diagonal, and never across a road or the plaza, because there is no shared
-- filler there to hand over. sv_adjacent is what enforces that.
--
-- A TEAM is everything those links join up into. So a diagonal neighbour CAN end
-- up on your team, but only by way of somebody who links you both:
--
--     A - B        A and C are teammates because B links them.
--         |        D is nobody's teammate: the only plot it touches is C,
--         C   D    and C never agreed to it.
--
-- Which is the owner's rule exactly: "only if the plot is behind, front, left,
-- right, nothing in between, unless another teammate connects".
--
-- The group is a connected component over the link graph. It is worked out once
-- and cached, because sv_authorised runs per body per patrol slice and per
-- occupied zone per tick, and a flood fill on that path would be the one piece
-- of genuinely hot arithmetic in the mod. Links change when somebody teams,
-- unteams or gives up a plot -- rarely, and always through sv_dirtyTeams.

function Plots.sv_dirtyTeams( self )
	self.groups = nil
end

-- plotIndex -> a set of every plot in the same team, itself included.
function Plots.sv_teamGroups( self )
	if self.groups then return self.groups end

	local groups, seen = {}, {}
	for start in pairs( self.teams ) do
		if not seen[start] then
			-- Breadth first over the links. Bounded by the plot count, and every
			-- plot is visited once, so this is O(plots) however tangled the
			-- links are.
			local group, queue, head = { [start] = true }, { start }, 1
			seen[start] = true
			while head <= #queue do
				local at = queue[head]
				head = head + 1
				for other in pairs( self.teams[at] or {} ) do
					if not group[other] then
						group[other] = true
						seen[other] = true
						queue[#queue + 1] = other
					end
				end
			end
			for index in pairs( group ) do
				groups[index] = group
			end
		end
	end

	self.groups = groups
	return groups
end

-- Everyone on a plot's team, itself included. A plot with no links is a team of
-- one, which keeps every caller free of a special case.
function Plots.sv_teamOf( self, index )
	if index == nil then return {} end
	local g = self:sv_teamGroups()[index]
	if g == nil then return { [index] = true } end
	return g
end

-- Teammates, not neighbours. Two plots are teamed when they are in the same
-- group, whether they linked directly or through somebody else.
function Plots.sv_teamed( self, a, b )
	if a == nil or b == nil then return false end
	if a == b then return true end
	return self:sv_teamOf( a )[b] == true
end

-- Everyone allowed to build in a zone, as a set of permaIds.
function Plots.sv_authorised( self, z )
	local out = {}
	-- Everything public: roads, the avenues that run out of the plaza, the plaza
	-- itself, and the corner squares where two seams cross. Belonging to everyone
	-- means nobody may build there.
	if z == nil or z.kind == "corner" or z.kind == "road"
		or z.kind == "avenue" or z.kind == "plaza" then
		return out
	end

	local function add( index )
		local owner = index and self.owners[index]
		if owner then out[owner] = true end
	end

	if z.kind == "plot" then
		for other in pairs( self:sv_teamOf( z.index ) ) do
			add( other )
		end
		return out
	end

	-- Filler. It belongs to nobody until the two plots either side are on the
	-- same team, and then it belongs to that whole team -- "that extra block
	-- becomes yours".
	--
	-- Same team rather than directly linked, deliberately. Four plots teamed in a
	-- ring would otherwise have a locked one-block strip running through the
	-- middle of their own land, purely because that particular pair never
	-- exchanged a request.
	local a = self:sv_indexAt( z.col, z.row )
	local b = ( z.kind == "fillerX" )
		and self:sv_indexAt( z.col + 1, z.row )
		or self:sv_indexAt( z.col, z.row + 1 )

	if a ~= nil and b ~= nil and self:sv_teamed( a, b ) then
		for other in pairs( self:sv_teamOf( a ) ) do
			add( other )
		end
	end
	return out
end


--[[ per-tick occupancy ]]

-- Recompute which zones are open. Cost is players x 1, not bodies x plots, so
-- this is cheap enough to run every tick.
function Plots.sv_updateOccupancy( self, identify, tick )
	self.zoneOpen = {}
	if not self.enabled then
		return
	end

	local occupied = {}
	for _, player in ipairs( sm.player.getAllPlayers() ) do
		local character = player:getCharacter()
		if character and sm.exists( character ) then
			local z = self:sv_locate( character.worldPosition )
			local zk = self:sv_zoneKey( z )
			if zk then
				occupied[zk] = occupied[zk] or { zone = z, players = {} }
				table.insert( occupied[zk].players, player )
			end
		end
	end

	-- The host is authorised on every square of the map. They are running the
	-- event: they have to be able to stand anywhere, place things and clear
	-- things, and a host who gets shoved off a plot while fixing it is useless.
	local host = sm.player.getHostPlayer()

	for zk, entry in pairs( occupied ) do
		local allowed = self:sv_authorised( entry.zone )
		local clean = true
		for _, player in ipairs( entry.players ) do
			if player ~= host then
				local perma = identify( player )
				if not ( perma and allowed[perma] ) then
					clean = false
					self:sv_pushOut( player, entry.zone, tick )
				end
			end
		end
		self.zoneOpen[zk] = clean
	end
end

-- Shove an unauthorised player back onto the nearest filler walkway. Without
-- this, simply standing on someone's plot keeps it locked and stops the owner
-- working -- presence enforcement would become a griefing tool of its own.
function Plots.sv_pushOut( self, player, z, tick )
	if not Plots.PUSH_INTRUDERS or z == nil or z.kind ~= "plot" then
		return
	end
	if player == sm.player.getHostPlayer() then
		return
	end
	local last = self.lastPush[player.id]
	if last and tick - last < Plots.PUSH_COOLDOWN_TICKS then
		return
	end
	self.lastPush[player.id] = tick

	local character = player:getCharacter()
	if not ( character and sm.exists( character ) ) then
		return
	end

	-- Onto the seam just outside this plot, whatever that seam turns out to be.
	-- Asking the layout where the plot ends beats reconstructing the position
	-- from a stride, which is what this did while a stride still existed and
	-- which put people in the wrong place the moment roads arrived.
	local r = Layout.plotRect( self.layout, z.col, z.row )
	if r == nil then return end
	local pos = sm.vec3.new(
		( r.x + r.w + 0.5 ) * Plots.BLOCK,
		( r.y + r.h * 0.5 ) * Plots.BLOCK,
		character.worldPosition.z )

	pcall( function() character:setWorldPosition( pos ) end )
end

-- Called by Protection for each body it sweeps.
function Plots.sv_bodyIsOpen( self, body )
	if not self.enabled then
		return nil     -- plots off: let the global mode decide
	end
	local z = self:sv_locate( body.worldPosition )

	-- "sweep" rather than "locked" for every zone nobody is allowed to build in.
	-- Locking them would make junk dumped on a walkway permanent, which is how a
	-- spawn-spam griefer wins: protect the world and their litter is protected
	-- too. Nothing legitimate can be built here, so anything present is rubbish
	-- and anyone may clear it.
	if z == nil then
		return "sweep"        -- outside the city
	end
	-- The plaza and the avenues are the city itself, not shared standing room:
	-- they are permanent scenery and must never become erasable, or "anywhere
	-- you cannot build, anyone can clean" would let a guest delete spawn.
	if z.kind == "plaza" or z.kind == "avenue" then
		return "locked"
	end
	if z.kind == "corner" or z.kind == "road" then
		return "sweep"
	end
	if z.kind ~= "plot" then
		-- Filler strip: shared ground only once the two plots either side team up.
		local allowed = self:sv_authorised( z )
		if next( allowed ) == nil then
			return "sweep"
		end
	end

	-- Over its part budget: locked until trimmed, but never sweepable, so the
	-- owner does not lose work to a passer-by while they are sorting it out.
	if z.kind == "plot" and self.overBudget[z.index] then
		return false
	end

	local zk = self:sv_zoneKey( z )
	-- Unoccupied zones stay open so owners are not locked out of empty plots;
	-- an unclaimed plot with nobody in it is harmless.
	if self.zoneOpen[zk] == nil then
		return true
	end
	-- An occupied-but-locked plot stays fully locked, never sweepable: the whole
	-- point is that the intruder standing on it must not be able to erase.
	return self.zoneOpen[zk]
end


--[[ claims and teams ]]

function Plots.sv_claim( self, index, perma )
	if self.owners[index] ~= nil then
		return false, ( self.owners[index] == perma )
			and "you already own this plot"
			or "that plot is already claimed"
	end
	for i, owner in pairs( self.owners ) do
		if owner == perma then
			return false, string.format( "you already own plot %d -- /plot leave first", i )
		end
	end
	self.owners[index] = perma
	return true, string.format( "plot %d is yours", index )
end

function Plots.sv_release( self, perma )
	for i, owner in pairs( self.owners ) do
		if owner == perma then
			self.owners[i] = nil
			self.teams[i] = nil
			for _, set in pairs( self.teams ) do
				set[i] = nil
			end
			self:sv_dirtyTeams()
			return true, string.format( "released plot %d", i )
		end
	end
	return false, "you do not own a plot"
end

function Plots.sv_plotOf( self, perma )
	for i, owner in pairs( self.owners ) do
		if owner == perma then return i end
	end
	return nil
end

-- Neighbours for the purpose of teaming up, which is NOT the same as being next
-- to each other in the grid. Teaming is what turns the seam between two plots
-- into shared ground, so it is only meaningful when that seam is a FILLER. Two
-- plots separated by a road, or by the plaza band running through the middle of
-- the city, have no seam to share: the ground between them is public.
--
-- Asking the layout for the filler rather than testing index arithmetic is what
-- makes that fall out on its own instead of being a second rule that has to be
-- kept in step with the first.
function Plots.sv_adjacent( self, a, b )
	if a == nil or b == nil then return false end
	local ca, ra = Layout.plotColRow( self.layout, a )
	local cb, rb = Layout.plotColRow( self.layout, b )
	if ca == nil or cb == nil then return false end

	if ra == rb and math.abs( ca - cb ) == 1 then
		return Layout.fillerBetween( self.layout.cols, math.min( ca, cb ) ) ~= nil
	end
	if ca == cb and math.abs( ra - rb ) == 1 then
		return Layout.fillerBetween( self.layout.rows, math.min( ra, rb ) ) ~= nil
	end
	return false
end

function Plots.sv_request( self, fromPerma, toPerma )
	local a = self:sv_plotOf( fromPerma )
	local b = self:sv_plotOf( toPerma )
	if a == nil then return false, "claim a plot first" end
	if b == nil then return false, "they do not own a plot" end
	if a == b then return false, "that is your own plot" end
	if not self:sv_adjacent( a, b ) then
		-- Named precisely, because "not a neighbour" is the one refusal people
		-- argue with. Diagonal is the common case and it looks adjacent.
		return false, self:sv_whyNotNeighbours( a, b )
	end
	if self:sv_teamed( a, b ) then
		return false, "you are already on the same team"
	end

	-- Their request already pending? Then this is the acceptance.
	if self.requests[b] and self.requests[b][a] then
		self.requests[b][a] = nil
		self.teams[a] = self.teams[a] or {}
		self.teams[b] = self.teams[b] or {}
		self.teams[a][b] = true
		self.teams[b][a] = true
		self:sv_dirtyTeams()
		local size = 0
		for _ in pairs( self:sv_teamOf( a ) ) do size = size + 1 end
		return true, string.format(
			"plots %d and %d are teamed -- the block between you is now shared. Team of %d.",
			a, b, size )
	end

	self.requests[a] = self.requests[a] or {}
	self.requests[a][b] = true
	return true, string.format( "request sent to plot %d -- they run the same command back to accept", b )
end

function Plots.sv_unteam( self, perma )
	local a = self:sv_plotOf( perma )
	if a == nil then return false, "you do not own a plot" end
	local n = 0
	for b in pairs( self.teams[a] or {} ) do
		if self.teams[b] then self.teams[b][a] = nil end
		n = n + 1
	end
	self.teams[a] = nil
	self:sv_dirtyTeams()
	-- Leaving cuts your links, and anyone who was only reachable THROUGH you is
	-- no longer on the team either. That is the same rule read backwards, and it
	-- is worth saying out loud so it is not a surprise.
	return true, string.format(
		"left the team -- %d link(s) cut", n )
end

-- Why two plots cannot link. The refusal people argue with is the diagonal one,
-- so it gets said in words rather than as "not a neighbour".
function Plots.sv_whyNotNeighbours( self, a, b )
	local ca, ra = Layout.plotColRow( self.layout, a )
	local cb, rb = Layout.plotColRow( self.layout, b )
	if ca == nil or cb == nil then return "that plot is not on the grid" end

	local dc, dr = math.abs( ca - cb ), math.abs( ra - rb )
	if dc == 1 and dr == 1 then
		return "corner to corner does not count -- team up with whoever is between you first"
	end
	if dc + dr > 1 then
		return "too far apart -- only the plot in front, behind, left or right of you"
	end
	-- Orthogonal but no filler: a road or the plaza runs between them, and there
	-- is no shared block to hand over.
	return "there is a road between you, not a shared block -- nothing to team over"
end

function Plots.sv_describe( self, index, nameOf )
	local owner = self.owners[index]
	if owner == nil then
		return string.format( "plot %d -- unclaimed", index )
	end
	local mates = {}
	for b in pairs( self:sv_teamOf( index ) ) do
		if b ~= index then mates[#mates + 1] = b end
	end
	table.sort( mates )
	for i, b in ipairs( mates ) do
		local who = self.owners[b]
		mates[i] = string.format( "%d (%s)", b,
			( who and nameOf( who ) ) or who or "unclaimed" )
	end
	return string.format( "plot %d -- %s%s", index, nameOf( owner ) or owner,
		#mates > 0 and ( "  team: " .. table.concat( mates, ", " ) ) or "" )
end

function Plots.sv_counts( self )
	local claimed = 0
	for _ in pairs( self.owners ) do claimed = claimed + 1 end
	return claimed, self.grid.cols * self.grid.rows
end


--[[ the visible city ]]

-- Each plot is its OWN creation: a slab that a player's build welds onto, so the
-- plot and everything on it is a single creation that can be exported and saved
-- as one thing when the event ends. Which is why each plot is imported
-- separately rather than as one big blueprint -- sm.body.getCreationsFromBodies
-- groups by creation, so a single import would make the entire city one creation
-- and per-plot snapshot and restore would collapse into all-or-nothing.
--
-- Blueprint children carry a `bounds`, so a 20x20 slab is ONE shape rather than
-- 400 (ChallengeMode_PotatoLevel_01.blueprint is full of examples). Positions
-- are in BLOCKS relative to the import position, and the import position is
-- always the world origin -- which is why Layout works in absolute blocks
-- centred on zero and no offset is applied anywhere below.

Plots.CONCRETE = "a6c6ce30-dd47-4587-b475-085d55c6a3b4"   -- blk_concrete1
Plots.METAL2 = "1016cafc-9f6b-40c9-8713-9019d399783f"     -- blk_metal2
Plots.METAL3 = "c0dfdea5-a39d-433a-b94a-299345a5df46"     -- blk_metal3

Plots.CONCRETE_COLOR = "8d8f89"
Plots.METAL2_COLOR = "68615c"
Plots.ROAD_COLOR = "3c3c40"
Plots.METAL3_COLOR = "4a4a4a"
Plots.PLAZA_COLOR = "5a5651"

Plots.DECK_Z = 4        -- blocks above ground that the city deck sits at

-- Every uuid the city is made of. sv_clearFloor clears by SHAPE against this
-- set rather than by body position: a plot slab with a build welded onto it has
-- its body position dragged up above any height test, so the old test missed it
-- and a rebuild imported a fresh slab into the same space. That is what
-- "some stuff is overlaid" looked like.
Plots.CITY_UUIDS = {
	[Plots.CONCRETE] = true, [Plots.METAL2] = true, [Plots.METAL3] = true,
}

local function child( uuid, colour, x, y, z, sx, sy, sz )
	return {
		bounds = { x = sx, y = sy, z = sz },
		color = colour,
		pos = { x = x, y = y, z = z },
		shapeId = uuid,
		xaxis = 1,
		zaxis = 3,
	}
end

local function blueprint( childs )
	return { version = 4, bodies = { { childs = childs } }, joints = {} }
end

local DECK_MATERIAL = {
	plaza = { Plots.METAL3, Plots.PLAZA_COLOR },
	avenue = { Plots.METAL3, Plots.METAL3_COLOR },
	road = { Plots.METAL3, Plots.ROAD_COLOR },
	filler = { Plots.METAL2, Plots.METAL2_COLOR },
}

-- One plot: just the slab. Only the PLAZA has a pillar -- the whole deck is
-- static, so it needs no support, and a forest of 100 columns read as clutter
-- rather than architecture. The city is one raised platform standing on its
-- centre.
function Plots.sv_plotBlueprint( self, col, row )
	local r = Layout.plotRect( self.layout, col, row )
	if r == nil then return nil end
	return blueprint{
		child( Plots.CONCRETE, Plots.CONCRETE_COLOR,
			r.x, r.y, Plots.DECK_Z, r.w, r.h, 1 ),
	}
end

-- Every piece of shared ground as one creation. The pieces come from
-- Layout.deckPieces, which is a partition by construction and is proved to be
-- one over a dozen configurations by dev/test_layout.py -- so nothing here has
-- to test whether a strip collides with the plaza, because nothing ever can.
function Plots.sv_deckBlueprint( self )
	local childs = {}
	for _, p in ipairs( Layout.deckPieces( self.layout ) ) do
		local m = DECK_MATERIAL[p.kind] or DECK_MATERIAL.filler
		childs[#childs + 1] = child( m[1], m[2], p.x, p.y, Plots.DECK_Z, p.w, p.h, 1 )
	end
	if #childs == 0 then return nil end
	return blueprint( childs )
end

-- The single pillar the whole city stands on, under the plaza. This is the only
-- one: "the center pillar shall be the only one, the spawn shall be the center
-- pillar".
function Plots.sv_pillarBlueprint( self )
	local half = Layout.plazaHalf( self.grid )
	if half <= 0 then return nil end
	local size = math.max( 4, math.floor( half / 2 ) * 2 )
	local at = -math.floor( size / 2 )
	return blueprint{
		child( Plots.METAL3, Plots.METAL3_COLOR, at, at, 0, size, size, Plots.DECK_Z ),
	}
end

-- Where a player spawns and where /home sends them when they own nothing: the
-- middle of the plaza, on top of the deck.
function Plots.sv_spawnPoint( self )
	return sm.vec3.new( 0, 0, ( Plots.DECK_Z + 1 ) * Plots.BLOCK + 0.5 )
end

-- Streets, avenues and the plaza are the parts of the city that must never be
-- erased, and they are identifiable because nothing can ever be built on them: a
-- body made entirely of metal 2 or metal 3 sitting at deck height is scenery and
-- nothing else. Plot slabs are concrete, so they never match this.
--
-- The plot slabs deliberately are NOT protected this way. A player's build welds
-- onto its slab, so the slab is part of their creation and follows the ordinary
-- plot rules -- which is exactly what makes the whole plot exportable as one
-- piece. The cost is that an owner can erase their own floor; /plotbuild puts it
-- back.
function Plots.sv_isScenery( self, body )
	local ok, pos = pcall( function() return body.worldPosition end )
	if not ok or pos == nil then return false end
	if pos.z > ( Plots.DECK_Z + 2 ) * Plots.BLOCK then return false end

	-- Must be a flat plate exactly one block thick sitting at deck height. A
	-- player's build rises above the deck, so its AABB gives it away instantly.
	-- Without this, anyone building out of metal near the ground had their
	-- creation classed as scenery and locked -- which is what stops a lift.
	local hasBox, aabbMin, aabbMax = pcall( function() return body:getWorldAabb() end )
	if hasBox and aabbMax then
		local ceiling = ( Plots.DECK_Z + 1 ) * Plots.BLOCK + 0.05
		if aabbMax.z > ceiling then return false end
	end

	local got, shapes = pcall( function() return body:getShapes() end )
	if not got or shapes == nil or #shapes == 0 then return false end
	for _, shape in ipairs( shapes ) do
		local u = tostring( shape.shapeUuid )
		if u ~= Plots.METAL2 and u ~= Plots.METAL3 then
			return false
		end
	end
	return true
end

-- Is this one of OUR shapes, sitting at deck height?
--
-- Clearing the city used to ask whether a BODY was low enough to be city, and
-- that is wrong as soon as anyone builds: a plot slab welded to a build has its
-- body position dragged up above any height test, so the slab survived the clear
-- and the rebuild imported a second slab into the same space. Testing the shape
-- instead is exact -- a shape's position never moves relative to its body, and
-- the deck is exactly one block thick at a known height.
function Plots.sv_isCityShape( self, shape )
	local ok, u = pcall( function() return tostring( shape.shapeUuid ) end )
	if not ok or not Plots.CITY_UUIDS[u] then return false end
	local got, pos = pcall( function() return shape.worldPosition end )
	if not got or pos == nil then return false end
	-- The deck is at DECK_Z, the pillar runs from 0 up to it. Anything at or
	-- below the deck's top surface is ours; anything above it is somebody's build.
	return pos.z <= ( Plots.DECK_Z + 1 ) * Plots.BLOCK + 0.05
end
