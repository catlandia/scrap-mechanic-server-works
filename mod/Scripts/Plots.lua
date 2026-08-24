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
	-- Layout.config handles migrating an old grid, including the plaza, which
	-- used to be a width in blocks and is now a count of cells.
	self:sv_setGrid( ( saved and saved.grid ) or Layout.DEFAULT )
	self.owners = ( saved and saved.owners ) or {}     -- plotIndex -> permaId
	self.teams = ( saved and saved.teams ) or {}       -- plotIndex -> { otherIndex = true }
	self.requests = {}                                  -- fromIndex -> { toIndex = true }
	self.zoneOpen = {}
	self.zoneHeld = {}
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
	-- Everything public: roads, the plaza, and the corner squares where two
	-- seams cross. Belonging to everyone means nobody may build there.
	if z == nil or z.kind == "corner" or z.kind == "road" or z.kind == "plaza" then
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
	-- Zones whose owner (or a teammate) is standing on the team's land right now.
	-- See the end of sv_bodyIsOpen: an empty claimed plot is locked, and this is
	-- what stops that locking somebody out of their own plot the moment they step
	-- onto the seam at its edge.
	self.zoneHeld = {}
	if not self.enabled then
		return
	end

	local occupied = {}
	for _, player in ipairs( sm.player.getAllPlayers() ) do
		local character = player:getCharacter()
		if character and sm.exists( character ) then
			local at = character.worldPosition
			local z = self:sv_locate( at )
			local zk = self:sv_zoneKey( z )
			if zk then
				occupied[zk] = occupied[zk] or { zone = z, players = {} }
				table.insert( occupied[zk].players, player )
			end
			-- Standing NEAR your own land holds it open, wherever you happen to
			-- be standing. See Plots.HOLD_RANGE: without this, stepping onto a
			-- road locked your own plot behind you.
			self:sv_holdNearby( identify( player ), at )
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

		-- Somebody standing on land they are authorised for holds that whole
		-- team's ground open, so stepping onto the seam at the edge of your own
		-- plot does not lock the plot behind you. The host holds everything,
		-- because the host is authorised everywhere.
		for _, player in ipairs( entry.players ) do
			local perma = identify( player )
			if player == host or ( perma and allowed[perma] ) then
				self:sv_holdTeam( entry.zone )
				break
			end
		end
	end
end

-- Mark every zone of the team that owns `z` as held. Held means "an owner is
-- present on their own land", which is what keeps a claimed plot open while its
-- owner is working on it even if they are stood one block off the edge.
-- How far from your own land you may stand and still have it open, in blocks.
--
-- REPORTED: "I cant build while standing on protected blocks which sucks." Fair,
-- and it was V42's doing. A claimed plot with nobody standing IN it is locked --
-- that is what stops somebody on the road reaching over your work -- and the
-- only thing that reopened it was standing inside the plot or on one of its own
-- seams. Step onto a ROAD, or onto the plaza, and your own plot locked behind
-- you while you were looking at it.
--
-- Distance, not zone. You are next to your land or you are not, and a road being
-- protected ground has nothing to do with it.
Plots.HOLD_RANGE = 12      -- blocks, so three metres past the edge of your plot

-- Everything this player is authorised for that they are standing near.
--
-- Cheap by construction: it only ever looks at the plots on THEIR OWN team,
-- which is one for almost everybody, rather than at every plot in the city.
function Plots.sv_holdNearby( self, perma, pos )
	if perma == nil or pos == nil then return end
	local mine = self:sv_plotOf( perma )
	if mine == nil then return end

	local bx, by = pos.x / Plots.BLOCK, pos.y / Plots.BLOCK
	for index in pairs( self:sv_teamOf( mine ) ) do
		local col, row = Layout.plotColRow( self.layout, index )
		local r = col and Layout.plotRect( self.layout, col, row )
		if r then
			-- distance from the point to the rectangle, zero when inside it
			local dx = math.max( r.x - bx, 0, bx - ( r.x + r.w ) )
			local dy = math.max( r.y - by, 0, by - ( r.y + r.h ) )
			if dx <= Plots.HOLD_RANGE and dy <= Plots.HOLD_RANGE then
				self:sv_holdTeam( { kind = "plot", index = index } )
				return
			end
		end
	end
end

function Plots.sv_holdTeam( self, z )
	local index = nil
	if z.kind == "plot" then
		index = z.index
	elseif z.col ~= nil and z.row ~= nil then
		index = self:sv_indexAt( z.col, z.row )
	end
	if index == nil then return end

	for other in pairs( self:sv_teamOf( index ) ) do
		self.zoneHeld[key_plot( other )] = true
		local col, row = Layout.plotColRow( self.layout, other )
		if col then
			-- and the seams around it, which are the team's ground too
			self.zoneHeld[key_fillerX( col, row )] = true
			self.zoneHeld[key_fillerY( col, row )] = true
			if col > 0 then self.zoneHeld[key_fillerX( col - 1, row )] = true end
			if row > 0 then self.zoneHeld[key_fillerY( col, row - 1 )] = true end
		end
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
	local z = self:sv_bodyZone( body )

	-- "sweep" rather than "locked" for every zone nobody is allowed to build in.
	-- Locking them would make junk dumped on a walkway permanent, which is how a
	-- spawn-spam griefer wins: protect the world and their litter is protected
	-- too. Nothing legitimate can be built here, so anything present is rubbish
	-- and anyone may clear it.
	if z == nil then
		return "sweep"        -- outside the city
	end
	-- The plaza used to return "locked" here, to stop "anywhere you cannot build,
	-- anyone can clean" from letting a guest delete spawn. That was the wrong
	-- place to defend it, and it is why craftbots and gems dropped on the plaza
	-- could never be removed by anybody: the plaza is where everyone spawns, so
	-- it is exactly where the spam lands.
	--
	-- The decking is already safe. sv_isScenery catches it one step earlier in
	-- the resolver and locks it in every mode, and it is a much better test --
	-- our own plaza is metal at deck height, and a craftbot standing on top of it
	-- is not. So the plaza is shared ground like the roads: nothing legitimate
	-- can be built on it, which means anything sitting there is litter and anyone
	-- may clear it.
	if z.kind == "plaza" then
		return "sweep"
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

	-- SOMEBODY IS STANDING HERE. Open only if everyone standing here belongs.
	-- An occupied-but-locked plot stays fully locked and never sweepable: the
	-- whole point is that the intruder standing on it cannot erase anything.
	if self.zoneOpen[zk] ~= nil then
		return self.zoneOpen[zk]
	end

	-- NOBODY IS STANDING HERE.
	--
	-- This used to return true -- "unoccupied zones stay open so owners are not
	-- locked out of empty plots" -- and that was a hole straight through "only
	-- build on your own tiles".
	--
	-- Body permission flags are GLOBAL. If a plot is buildable it is buildable by
	-- everybody, from anywhere within reach. So an empty claimed plot being open
	-- meant standing on the road beside somebody's work and reaching over it, and
	-- the owner did not even have to be online.
	--
	-- Claimed and empty is locked. Unclaimed and empty stays open: there is
	-- nothing there to protect and the host needs to be able to place things.
	local allowed = self:sv_authorised( z )
	if next( allowed ) == nil then
		return true
	end

	-- ...unless somebody it belongs to is standing on their own land nearby. An
	-- owner working at the edge of their plot steps onto the one-block seam all
	-- the time, and locking their plot the moment they do would be unusable.
	return self.zoneHeld[zk] == true
end


--[[ claims and teams ]]

function Plots.sv_claim( self, index, perma )
	if not Layout.plotExists( self.layout, index ) then
		return false, "there is no plot there -- that is the plaza"
	end
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
	-- A plot the plaza sits on does not exist, so nothing is next to it.
	if not ( Layout.plotExists( self.layout, a )
		and Layout.plotExists( self.layout, b ) ) then return false end
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
-- Darker than the deck, so a stand reads as structure from ground level.
Plots.STAND_COLOR = "35353a"

Plots.DECK_Z = 4        -- blocks above ground that the city deck sits at

-- SEPARATION IS THE DESIGN. IT IS NOT A BUG, AND V32 GOT THIS BACKWARDS.
--
-- Three reports read as "the city is not joined up" -- "the plot is not attached
-- to the rest of the build", "I dont think the concrete sticks to the borders
-- still" -- so V32 welded a single slab under the entire footprint to tie it
-- together. Wrong fix, real observation, and the owner is the one who caught it:
--
--   "the things NEED to be separated from the main city! in the original event
--    they were separated with wedges so updating one block wont update whole
--    city. but just the block! the block between the panels NEEDS to be
--    detached. and each panel shall have its own stand!"
--
-- That is operational experience from an event they actually ran, and the
-- mechanism behind it is the same one their blueprint showed: **a body is the
-- unit the engine rebuilds.** Change one block and the whole body it belongs to
-- is reprocessed. Weld a hundred plots into one city and every block anyone
-- places, anywhere, costs a rebuild of all of it -- at an event with twenty
-- people building at once, which is goal 1 of this project.
--
-- So the city is deliberately MANY bodies and nothing spans the footprint:
--
--   one body per plot     its ring, its pad and its own stand, welded
--   one body per street   detached from the plots on either side of it
--   one body for the plaza and the pillar under it
--
-- What looked like sloppiness was the point. The base slab is gone.

-- How wide a plot's stand is, in blocks. "each panel shall have its own stand":
-- a column from the ground to the underside of the plot, welded into the plot's
-- own body, so the panel is held up by itself and by nothing shared.
Plots.STAND = 4

-- How wide a plot's own metal border is, in blocks.
--
-- MEASURED, from a reference creation the owner built and saved in game so the
-- structure could be read directly -- "concrete panel with metal all around it",
-- Blueprints/038852d7. It came back as ONE body with nine children, concrete
-- (a6c6ce30) and metal 2 (1016cafc) side by side in the same `childs` array:
--
--   bodies[0].childs = [ {metal2 21x1}, {metal2 1x22}, {metal2 1x21},
--                        {concrete 16x12}, {metal2 20x1}, {concrete 8x8}, ... ]
--
-- That is the whole answer to "how are blocks connected in Scrap Mechanic":
-- **one body's childs array IS the weld group.** Two materials in the same array
-- are one welded piece; two separate blueprints are two separate bodies that
-- merely touch, however perfectly they line up.
--
-- So the border moved INSIDE the plot. Each plot is now a single body -- a
-- concrete panel with a metal ring welded all the way round it, which is exactly
-- the reference creation. It costs the outer ring of buildable area: a 20-block
-- plot gives an 18-block concrete pad.
--
-- The plot cannot be welded to the DECK as well, and that is not a choice. Body
-- permission flags are per-BODY -- there is no setBuildableBy( player ) -- so
-- one plot per body is the only reason plot ownership can exist at all. Weld the
-- city into one body and it becomes buildable by everyone or by nobody.
Plots.BORDER = 1

-- Every uuid the city is made of. sv_clearFloor clears by SHAPE against this
-- set rather than by body position: a plot slab with a build welded onto it has
-- its body position dragged up above any height test, so the old test missed it
-- and a rebuild imported a fresh slab into the same space. That is what
-- "some stuff is overlaid" looked like.
-- Above this world height, a block of our own materials is SOMEBODY'S BUILD.
--
-- REPORTED: "whatever the block is metal 2 or concrete it counts as part of the
-- city whatever of it actualy being so." Right, and the slop was the cause.
--
-- The city's top layer is block z = DECK_Z, which spans world z 1.00 to 1.25. A
-- player builds ON it, so their first block is the layer above: 1.25 to 1.50.
-- The old test allowed anything up to 1.30 -- so if shape.worldPosition is the
-- MINIMUM CORNER rather than the centre, a player's first block sat at exactly
-- 1.25 and was classed as city floor. The cleaner then refused to delete it and
-- CLEAR CITY would have taken it.
--
-- 1.1875 is three quarters of the way up our own layer, which clears both
-- readings with room on either side:
--
--   our deck      min corner 1.0000   centre 1.1250   -> city
--   their block   min corner 1.2500   centre 1.3750   -> not city
--
-- Guessing between two possible meanings of worldPosition is not something to
-- rely on, so the threshold is set where both give the same answer.
Plots.CITY_CEILING = ( Plots.DECK_Z + 0.75 ) * Plots.BLOCK

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

	local b = Plots.BORDER
	-- A plot too small to carry a ring is left as a plain slab rather than
	-- turned into a block of solid metal.
	if b <= 0 or r.w <= b * 2 or r.h <= b * 2 then
		return blueprint{
			child( Plots.CONCRETE, Plots.CONCRETE_COLOR,
				r.x, r.y, Plots.DECK_Z, r.w, r.h, 1 ),
		}
	end

	-- Four metal strips and one concrete pad, all in ONE body's childs array,
	-- which is what welds them. The strips are cut so no two overlap: top and
	-- bottom run the full width, left and right fill only what is between them.
	local z = Plots.DECK_Z
	local M, MC = Plots.METAL2, Plots.METAL2_COLOR
	local childs = {
		child( M, MC, r.x, r.y, z, r.w, b, 1 ),                      -- bottom
		child( M, MC, r.x, r.y + r.h - b, z, r.w, b, 1 ),            -- top
		child( M, MC, r.x, r.y + b, z, b, r.h - b * 2, 1 ),          -- left
		child( M, MC, r.x + r.w - b, r.y + b, z, b, r.h - b * 2, 1 ),-- right
		child( Plots.CONCRETE, Plots.CONCRETE_COLOR,
			r.x + b, r.y + b, z, r.w - b * 2, r.h - b * 2, 1 ),      -- the pad
	}

	-- Its own stand, welded into the same body. The panel stands on itself and
	-- on nothing shared -- see the note by Plots.STAND.
	local stand = Plots.sv_standChild( self, r )
	if stand then childs[#childs + 1] = stand end
	return blueprint( childs )
end

-- A column from the ground to the underside of a rectangle, centred on it.
-- Shared by the plots and the plaza, because both stand the same way.
function Plots.sv_standChild( self, r, colour )
	if Plots.DECK_Z <= 0 then return nil end
	local size = math.max( 2, math.min( Plots.STAND, math.min( r.w, r.h ) ) )
	local x = r.x + math.floor( ( r.w - size ) / 2 )
	local y = r.y + math.floor( ( r.h - size ) / 2 )
	return child( Plots.METAL3, colour or Plots.STAND_COLOR,
		x, y, 0, size, size, Plots.DECK_Z )
end

-- Every piece of shared ground, as a SEPARATE blueprint each.
--
-- One creation per street, not one for the whole deck. "the block between the
-- panels NEEDS to be detached" -- so it is its own body, welded to neither of
-- the plots it runs between, and editing one part of the city can never
-- reprocess another. See the note by Plots.STAND for why that is the whole
-- design rather than a detail.
--
-- The pieces come from Layout.deckPieces, which is a partition by construction
-- and is proved to be one over a dozen configurations by dev/test_layout.py, so
-- nothing here has to test whether a strip collides with the plaza.
--
-- Returns a list of { label, bp }. The plaza is first, because it is the middle
-- of the city and seeing it appear first is how the host knows the centre landed
-- where they meant it to.
function Plots.sv_deckBlueprints( self )
	local out = {}
	local plaza = nil

	for _, p in ipairs( Layout.deckPieces( self.layout ) ) do
		local m = DECK_MATERIAL[p.kind] or DECK_MATERIAL.filler
		local childs = { child( m[1], m[2], p.x, p.y, Plots.DECK_Z, p.w, p.h, 1 ) }

		-- The plaza gets a stand of its own too, sized to it rather than to a
		-- plot: it is the biggest single piece of the city and the one everybody
		-- spawns on.
		if p.kind == "plaza" then
			local size = math.max( 4, math.floor( math.min( p.w, p.h ) / 4 ) * 2 )
			local stand = Plots.sv_standChild( self,
				{ x = p.x, y = p.y, w = p.w, h = p.h }, Plots.METAL3_COLOR )
			if stand then
				stand.bounds.x, stand.bounds.y = size, size
				stand.pos.x = p.x + math.floor( ( p.w - size ) / 2 )
				stand.pos.y = p.y + math.floor( ( p.h - size ) / 2 )
				childs[#childs + 1] = stand
			end
			plaza = { label = "plaza", bp = blueprint( childs ) }
		else
			out[#out + 1] = { label = p.kind, bp = blueprint( childs ) }
		end
	end

	if plaza then table.insert( out, 1, plaza ) end
	return out
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
-- WHERE A BODY IS, for the purpose of deciding whose ground it is on.
--
-- NOT body.worldPosition. That is a body's own origin, and for a creation
-- imported at sm.vec3.zero() -- which is every piece of this city, because the
-- blueprint carries absolute block coordinates -- it can report a point nowhere
-- near the thing you are looking at.
--
-- REPORTED: "I cant place blocks on the concrete but I can delete it. I can
-- delete others plots." Buildable false with erasable true is exactly ONE
-- profile out of six: `sweep`. And sweep is what sv_bodyIsOpen returns when it
-- cannot place a body in the city at all -- so every plot in the city was being
-- located somewhere it was not, and treated as litter on open ground.
--
-- The AABB centre cannot be an origin artefact: it is the middle of where the
-- body actually IS. A build welded to a plot slab keeps its centre over the
-- plot, and a tall tower on it still does.
function Plots.sv_bodyZone( self, body )
	local ok, aabbMin, aabbMax = pcall( function() return body:getWorldAabb() end )
	if ok and aabbMin and aabbMax then
		local x = ( aabbMin.x + aabbMax.x ) * 0.5
		local y = ( aabbMin.y + aabbMax.y ) * 0.5
		return Layout.locate( self.layout, x / Plots.BLOCK, y / Plots.BLOCK )
	end
	local got, pos = pcall( function() return body.worldPosition end )
	if not got or pos == nil then return nil end
	return self:sv_locate( pos )
end

-- Is this body part of the city floor, or welded to it?
--
-- ONE aabb call, not a walk over every shape, because this runs per body per
-- patrol slice and a player's 500-block build would otherwise be 500 uuid
-- comparisons every cycle.
--
-- The heights are unambiguous and that is what makes the cheap test correct:
--
--   deck body   min z = BASE_Z * 0.25          = 0.75
--   plot slab   min z = DECK_Z * 0.25          = 1.00
--   anything merely STANDING on the floor      = 1.25
--
-- A player's build welded onto a plot slab is ONE body with the slab, so it
-- keeps the slab's 1.00 and is pinned too -- which is right: their tower is part
-- of the ground now and must not be liftable either.
function Plots.sv_isGround( self, body )
	local ok, aabbMin = pcall( function() return body:getWorldAabb() end )
	if not ok or aabbMin == nil then return false end
	return aabbMin.z <= ( Plots.DECK_Z + 0.4 ) * Plots.BLOCK
end

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

	-- HEIGHT ALONE IS NOT ENOUGH, and this was the second half of the same
	-- report: "I still cant remove metal 2 via the tool. even if its not on the
	-- platform." A metal 2 block dropped on the terrain outside the city is
	-- LOWER than our deck, so a pure height test called it city floor and the
	-- cleaner refused to delete it.
	--
	-- It has to be inside the city's footprint as well.
	local bx, by = pos.x / Plots.BLOCK, pos.y / Plots.BLOCK
	local zone = Layout.locate( self.layout, bx, by )
	if zone == nil then
		return false                       -- not over the city at all
	end
	if pos.z >= Plots.CITY_CEILING then
		return false                       -- above our layer: somebody's build
	end
	if pos.z >= Plots.DECK_Z * Plots.BLOCK then
		return true                        -- our own deck layer
	end
	-- Below the deck the only thing of ours is a STAND, so anything else down
	-- there -- somebody building underneath the platform -- is theirs to delete.
	return self:sv_isStandBlock( bx, by, zone )
end

-- The column under a plot or under the plaza, in blocks. Mirrors what
-- sv_standChild actually builds; if one changes the other has to.
function Plots.sv_isStandBlock( self, bx, by, zone )
	local r, size
	if zone.kind == "plot" then
		r = Layout.plotRect( self.layout, zone.col, zone.row )
		if r == nil then return false end
		size = math.max( 2, math.min( Plots.STAND, math.min( r.w, r.h ) ) )
	elseif zone.kind == "plaza" then
		r = self.layout.plaza
		if r == nil then return false end
		size = math.max( 4, math.floor( math.min( r.w, r.h ) / 4 ) * 2 )
	else
		return false                       -- streets have no stand
	end

	local x = r.x + math.floor( ( r.w - size ) / 2 )
	local y = r.y + math.floor( ( r.h - size ) / 2 )
	return bx >= x and bx < x + size and by >= y and by < y + size
end
