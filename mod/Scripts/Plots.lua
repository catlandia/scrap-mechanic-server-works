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
Plots.DEFAULT = { plot = 20, gap = 1, cols = 10, rows = 10 }

Plots.PUSH_INTRUDERS = true
Plots.PUSH_COOLDOWN_TICKS = 20      -- don't fight the player's own movement every tick

local function key_plot( i )        return "p" .. i end
local function key_fillerX( c, r )  return "x" .. c .. "_" .. r end
local function key_fillerY( c, r )  return "y" .. c .. "_" .. r end


function Plots.sv_onCreate( self, saved )
	local cfg = ( saved and saved.grid ) or Plots.DEFAULT
	self.grid = {
		plot = cfg.plot or Plots.DEFAULT.plot,
		gap = cfg.gap or Plots.DEFAULT.gap,
		cols = cfg.cols or Plots.DEFAULT.cols,
		rows = cfg.rows or Plots.DEFAULT.rows,
	}
	self.owners = ( saved and saved.owners ) or {}     -- plotIndex -> permaId
	self.teams = ( saved and saved.teams ) or {}       -- plotIndex -> { otherIndex = true }
	self.requests = {}                                  -- fromIndex -> { toIndex = true }
	self.zoneOpen = {}
	self.overBudget = {}      -- plotIndex -> true, set by the rules audit
	self.lastPush = {}
	self.enabled = ( saved and saved.enabled ) or false
end

function Plots.sv_serialise( self )
	return { grid = self.grid, owners = self.owners, teams = self.teams, enabled = self.enabled }
end

function Plots.sv_stride( self )
	return self.grid.plot + self.grid.gap
end

-- Blocks from world centre to the grid's corner, so the city sits on origin.
function Plots.sv_originBlocks( self )
	local s = self:sv_stride()
	return -( self.grid.cols * s ) * 0.5, -( self.grid.rows * s ) * 0.5
end

-- Which zone a world position falls in. nil means outside the city entirely.
function Plots.sv_locate( self, pos )
	local s = self:sv_stride()
	local ox, oy = self:sv_originBlocks()
	local bx = pos.x / Plots.BLOCK - ox
	local by = pos.y / Plots.BLOCK - oy

	if bx < 0 or by < 0 or bx >= self.grid.cols * s or by >= self.grid.rows * s then
		return nil
	end

	local col = math.floor( bx / s )
	local row = math.floor( by / s )
	local inX = ( bx - col * s ) < self.grid.plot
	local inY = ( by - row * s ) < self.grid.plot

	if inX and inY then
		return { kind = "plot", col = col, row = row, index = row * self.grid.cols + col + 1 }
	elseif inX then
		return { kind = "fillerY", col = col, row = row }    -- strip toward row+1
	elseif inY then
		return { kind = "fillerX", col = col, row = row }    -- strip toward col+1
	end
	-- Where two filler strips cross, four plots meet at once. Never buildable:
	-- there is no sensible owner and it keeps the walkways clear.
	return { kind = "corner", col = col, row = row }
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
	if z == nil or z.kind == "corner" then
		return out
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

	for zk, entry in pairs( occupied ) do
		local allowed = self:sv_authorised( entry.zone )
		local clean = true
		for _, player in ipairs( entry.players ) do
			local perma = identify( player )
			if not ( perma and allowed[perma] ) then
				clean = false
				self:sv_pushOut( player, entry.zone, tick )
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
