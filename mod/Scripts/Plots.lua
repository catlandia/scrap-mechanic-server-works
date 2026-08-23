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
-- Geometry is in BLOCKS. One block is 0.25 m; vanilla's own lift code converts
-- with `self.liftPos * 0.25` (Data/Scripts/game/Lift.lua).

Plots = class( nil )

Plots.BLOCK = 0.25

-- Defaults: 10x10 plots of 20x20 blocks, one block of filler between them.
-- 21 blocks of stride x 10 = 210 blocks = 52.5 m square for the whole city,
-- which is small enough to stay inside a couple of terrain cells.
Plots.DEFAULT = { plot = 20, gap = 1, cols = 10, rows = 10, roadevery = 0, roadwidth = 6 }

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
	local cfg = ( saved and saved.grid ) or Plots.DEFAULT
	self.grid = {
		plot = cfg.plot or Plots.DEFAULT.plot,
		gap = cfg.gap or Plots.DEFAULT.gap,
		cols = cfg.cols or Plots.DEFAULT.cols,
		rows = cfg.rows or Plots.DEFAULT.rows,
	}
	self.grid.roadevery = cfg.roadevery or 0
	self.grid.roadwidth = cfg.roadwidth or 6
	self.owners = ( saved and saved.owners ) or {}     -- plotIndex -> permaId
	self.teams = ( saved and saved.teams ) or {}       -- plotIndex -> { otherIndex = true }
	self.requests = {}                                  -- fromIndex -> { toIndex = true }
	self.zoneOpen = {}
	self.overBudget = {}      -- plotIndex -> true, set by the rules audit
	self.lastPush = {}
	self.enabled = ( saved and saved.enabled ) or false
end

function Plots.sv_serialise( self )
	return { grid = self.grid, owners = self.owners, teams = self.teams,
		enabled = self.enabled, spawn = Plots.SPAWN }
end

function Plots.sv_stride( self )
	return self.grid.plot + self.grid.gap
end

-- Blocks from world centre to the grid's corner, so the city sits on origin.
function Plots.sv_originBlocks( self )
	local s = self:sv_stride()
	return -( self.grid.cols * s ) * 0.5, -( self.grid.rows * s ) * 0.5
end


--[[ geometry ]]
--
-- The city axis is NOT a uniform stride any more. A filler is the one-block seam
-- between neighbouring plots -- shared ground once those two team up. A ROAD is a
-- proper street: wider, never shareable, never claimable. They are different
-- things and the layout has to model both, so each axis is built as an explicit
-- run of segments and positions come from a prefix sum rather than col * stride.
--
-- segment = { start, size, kind = "plot" | "filler" | "road", index }

function Plots.sv_axis( self, count )
	local g = self.grid
	local segs, at = {}, 0
	for i = 0, count - 1 do
		segs[#segs + 1] = { start = at, size = g.plot, kind = "plot", index = i }
		at = at + g.plot
		local isRoad = ( g.roadevery or 0 ) > 0 and ( ( i + 1 ) % g.roadevery == 0 )
		local width = isRoad and ( g.roadwidth or 6 ) or g.gap
		if width > 0 and i < count - 1 then
			segs[#segs + 1] = { start = at, size = width,
				kind = isRoad and "road" or "filler", index = i }
			at = at + width
		end
	end
	return segs, at
end

function Plots.sv_extent( self )
	local _, w = self:sv_axis( self.grid.cols )
	local _, h = self:sv_axis( self.grid.rows )
	return w, h
end

function Plots.sv_originBlocks( self )
	local w, h = self:sv_extent()
	return -w * 0.5, -h * 0.5
end

-- kept so old callers still work; the axis is authoritative now
function Plots.sv_stride( self )
	return self.grid.plot + self.grid.gap
end

local function segmentAt( segs, v )
	for _, s in ipairs( segs ) do
		if v >= s.start and v < s.start + s.size then return s end
	end
	return nil
end

-- Which zone a world position falls in. nil means outside the city entirely.
function Plots.sv_locate( self, pos )
	local ox, oy = self:sv_originBlocks()
	local bx = pos.x / Plots.BLOCK - ox
	local by = pos.y / Plots.BLOCK - oy
	local cols, w = self:sv_axis( self.grid.cols )
	local rows, h = self:sv_axis( self.grid.rows )
	if bx < 0 or by < 0 or bx >= w or by >= h then return nil end

	local sx = segmentAt( cols, bx )
	local sy = segmentAt( rows, by )
	if sx == nil or sy == nil then return nil end

	if sx.kind == "plot" and sy.kind == "plot" then
		return { kind = "plot", col = sx.index, row = sy.index,
			index = sy.index * self.grid.cols + sx.index + 1 }
	end
	-- a road in either direction beats a filler: roads are public, always
	if sx.kind == "road" or sy.kind == "road" then
		return { kind = "road", col = sx.index, row = sy.index }
	end
	if sx.kind == "plot" then
		return { kind = "fillerY", col = sx.index, row = sy.index }
	end
	if sy.kind == "plot" then
		return { kind = "fillerX", col = sx.index, row = sy.index }
	end
	return { kind = "corner", col = sx.index, row = sy.index }
end

function Plots.sv_indexAt( self, col, row )
	if col < 0 or row < 0 or col >= self.grid.cols or row >= self.grid.rows then
		return nil
	end
	return row * self.grid.cols + col + 1
end

function Plots.sv_zoneKey( self, z )
	if z == nil then return nil end
	if z.kind == "plot" then return key_plot( z.index ) end
	if z.kind == "fillerX" then return key_fillerX( z.col, z.row ) end
	if z.kind == "fillerY" then return key_fillerY( z.col, z.row ) end
	return "corner"
end

function Plots.sv_teamed( self, a, b )
	return a ~= nil and b ~= nil and self.teams[a] ~= nil and self.teams[a][b] == true
end

-- Everyone allowed to build in a zone, as a set of permaIds.
function Plots.sv_authorised( self, z )
	local out = {}
	if z == nil or z.kind == "corner" or z.kind == "road" then
		return out          -- roads belong to everyone, so nobody may build there
	end

	local function add( index )
		local owner = index and self.owners[index]
		if owner then out[owner] = true end
	end

	if z.kind == "plot" then
		add( z.index )
		for other in pairs( self.teams[z.index] or {} ) do
			add( other )
		end
		return out
	end

	-- Filler. It belongs to nobody until the two plots either side team up, and
	-- then it belongs to both of them -- "that extra block becomes yours".
	local a = self:sv_indexAt( z.col, z.row )
	local b = ( z.kind == "fillerX" )
		and self:sv_indexAt( z.col + 1, z.row )
		or self:sv_indexAt( z.col, z.row + 1 )

	if self:sv_teamed( a, b ) then
		add( a )
		add( b )
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

	local s = self:sv_stride()
	local ox, oy = self:sv_originBlocks()
	-- Middle of the filler strip on the far side of this plot.
	local bx = ox + z.col * s + self.grid.plot + self.grid.gap * 0.5
	local by = oy + z.row * s + self.grid.plot * 0.5
	local pos = sm.vec3.new( bx * Plots.BLOCK, by * Plots.BLOCK, character.worldPosition.z )

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
	if z.kind == "corner" then
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

function Plots.sv_adjacent( self, a, b )
	if a == nil or b == nil then return false end
	local ca, ra = ( a - 1 ) % self.grid.cols, math.floor( ( a - 1 ) / self.grid.cols )
	local cb, rb = ( b - 1 ) % self.grid.cols, math.floor( ( b - 1 ) / self.grid.cols )
	return math.abs( ca - cb ) + math.abs( ra - rb ) == 1
end

function Plots.sv_request( self, fromPerma, toPerma )
	local a = self:sv_plotOf( fromPerma )
	local b = self:sv_plotOf( toPerma )
	if a == nil then return false, "claim a plot first" end
	if b == nil then return false, "they do not own a plot" end
	if not self:sv_adjacent( a, b ) then
		return false, "you can only team up with a neighbour"
	end
	if self:sv_teamed( a, b ) then return false, "already teamed" end

	-- Their request already pending? Then this is the acceptance.
	if self.requests[b] and self.requests[b][a] then
		self.requests[b][a] = nil
		self.teams[a] = self.teams[a] or {}
		self.teams[b] = self.teams[b] or {}
		self.teams[a][b] = true
		self.teams[b][a] = true
		return true, string.format( "plots %d and %d are teamed -- the filler between you is now shared", a, b )
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
	return true, string.format( "left %d team(s)", n )
end

function Plots.sv_describe( self, index, nameOf )
	local owner = self.owners[index]
	if owner == nil then
		return string.format( "plot %d -- unclaimed", index )
	end
	local mates = {}
	for b in pairs( self.teams[index] or {} ) do
		mates[#mates + 1] = tostring( b )
	end
	return string.format( "plot %d -- %s%s", index, nameOf( owner ) or owner,
		#mates > 0 and ( "  teamed with plot " .. table.concat( mates, ", " ) ) or "" )
end

function Plots.sv_counts( self )
	local claimed = 0
	for _ in pairs( self.owners ) do claimed = claimed + 1 end
	return claimed, self.grid.cols * self.grid.rows
end


--[[ the visible city ]]

-- Each plot is its OWN creation: a concrete slab on a pillar. That is the whole
-- point of the pillar -- when a player builds on their slab their blocks weld to
-- that body, so the plot and everything on it is a single creation that can be
-- exported and saved as one thing when the event ends.
--
-- Which is why each plot is imported separately rather than as one big blueprint.
-- sm.body.getCreationsFromBodies groups by creation, so a single import would
-- make the entire city one creation and per-plot snapshot and restore would
-- collapse into all-or-nothing.
--
-- The walkways are one further creation of their own. Separately imported bodies
-- do not weld to each other just by touching -- welding needs the weld tool or a
-- contiguous build action -- so the grid stays as separate pieces.
--
-- Blueprint children carry a `bounds`, so a 20x20 slab is ONE shape rather than
-- 400 (ChallengeMode_PotatoLevel_01.blueprint is full of examples). Positions are
-- in BLOCKS, relative to the import position.

Plots.CONCRETE = "a6c6ce30-dd47-4587-b475-085d55c6a3b4"   -- blk_concrete1
Plots.METAL2 = "1016cafc-9f6b-40c9-8713-9019d399783f"     -- blk_metal2
Plots.CONCRETE_COLOR = "8d8f89"
Plots.METAL2_COLOR = "68615c"
Plots.ROAD_COLOR = "3c3c40"

Plots.METAL3 = "c0dfdea5-a39d-433a-b94a-299345a5df46"     -- blk_metal3
Plots.METAL3_COLOR = "4a4a4a"

Plots.DECK_Z = 4        -- blocks above ground that the city deck sits at
Plots.PILLAR = 4        -- pillar footprint, blocks square
Plots.SPAWN = 50        -- spawn plaza, blocks square, centred on world origin

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

-- The spawn plaza occupies the middle of the city, so the plots that would sit
-- under it are simply not built. A city with a square hole in the centre is what
-- a plaza looks like; overlapping geometry is what a bug looks like.
function Plots.sv_spawnBounds( self )
	local half = math.floor( Plots.SPAWN / 2 )
	return -half, -half, half, half        -- in blocks, inclusive-exclusive
end

function Plots.sv_plotHitsSpawn( self, col, row )
	if Plots.SPAWN <= 0 then return false end
	local g = self.grid
	local s = self:sv_stride()
	local ox, oy = self:sv_originBlocks()
	local x0, y0 = ox + col * s, oy + row * s
	local x1, y1 = x0 + g.plot, y0 + g.plot
	local sx0, sy0, sx1, sy1 = self:sv_spawnBounds()
	return x0 < sx1 and x1 > sx0 and y0 < sy1 and y1 > sy0
end

-- The plaza: a metal 3 plate on its own pillar, centred on the world origin.
function Plots.sv_spawnBlueprint( self )
	if Plots.SPAWN <= 0 then return nil end
	local x0, y0 = self:sv_spawnBounds()
	local pil = math.max( Plots.PILLAR, math.floor( Plots.SPAWN / 4 ) )
	local inset = math.floor( ( Plots.SPAWN - pil ) / 2 )
	return blueprint{
		child( Plots.METAL3, Plots.METAL3_COLOR,
			x0 + inset, y0 + inset, 0, pil, pil, Plots.DECK_Z ),
		child( Plots.METAL3, Plots.METAL3_COLOR,
			x0, y0, Plots.DECK_Z, Plots.SPAWN, Plots.SPAWN, 1 ),
	}
end

-- One plot: just the slab. Only the PLAZA has a pillar now -- the whole deck is
-- static, so it needs no support, and a forest of 100 columns read as clutter
-- rather than architecture. The city is one raised platform standing on its
-- centre.
function Plots.sv_plotBlueprint( self, col, row )
	local g = self.grid
	local cols = self:sv_axis( g.cols )
	local rows = self:sv_axis( g.rows )
	local ox, oy = self:sv_originBlocks()
	local sx, sy
	for _, seg in ipairs( cols ) do if seg.kind == "plot" and seg.index == col then sx = seg end end
	for _, seg in ipairs( rows ) do if seg.kind == "plot" and seg.index == row then sy = seg end end
	if sx == nil or sy == nil then return nil end

	return blueprint{
		child( Plots.CONCRETE, Plots.CONCRETE_COLOR,
			ox + sx.start, oy + sy.start, Plots.DECK_Z, g.plot, g.plot, 1 ),
	}
end

-- Every seam in the city as one creation: fillers in metal 2, roads in metal 3
-- so a street reads as a street and not as a wide gap.
function Plots.sv_walkwayBlueprint( self )
	local g = self.grid
	local cols, w = self:sv_axis( g.cols )
	local rows, h = self:sv_axis( g.rows )
	local ox, oy = self:sv_originBlocks()
	local childs = {}
	local sx0, sy0, sx1, sy1 = self:sv_spawnBounds()

	local function clear( x, y, sw, sh )
		if Plots.SPAWN <= 0 then return true end
		return not ( x < sx1 and x + sw > sx0 and y < sy1 and y + sh > sy0 )
	end

	local function strip( cx, cy, cw, ch, kind )
		if not clear( ox + cx, oy + cy, cw, ch ) then return end
		local uuid = ( kind == "road" ) and Plots.METAL3 or Plots.METAL2
		local colour = ( kind == "road" ) and Plots.ROAD_COLOR or Plots.METAL2_COLOR
		childs[#childs + 1] = child( uuid, colour, ox + cx, oy + cy, Plots.DECK_Z, cw, ch, 1 )
	end

	-- vertical seams run the full height, which also fills the crossings
	for _, seg in ipairs( cols ) do
		if seg.kind ~= "plot" then strip( seg.start, 0, seg.size, h, seg.kind ) end
	end
	-- horizontal seams only span the plot columns, so nothing overlaps
	for _, seg in ipairs( rows ) do
		if seg.kind ~= "plot" then
			for _, c in ipairs( cols ) do
				if c.kind == "plot" then strip( c.start, seg.start, c.size, seg.size, seg.kind ) end
			end
		end
	end

	if #childs == 0 then return nil end
	return blueprint( childs )
end

-- Streets and the spawn plaza are the parts of the city that must never be
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

-- Anything sitting at or below the deck is city, not a build.
function Plots.sv_isCityBody( self, body )
	local ok, pos = pcall( function() return body.worldPosition end )
	if not ok or pos == nil then return false end
	return pos.z <= ( Plots.DECK_Z + 2 ) * Plots.BLOCK
end
