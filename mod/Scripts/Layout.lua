-- Layout -- the city's geometry, and the ONLY place it is computed.
--
-- This file exists because the geometry used to live in three places: the
-- builder in Plots.lua, the locator in Plots.lua, and a hand-copied mirror in
-- PlotsGui.lua whose comment said "Mirrors Plots.sv_axis. The panel has to lay
-- the city out the same way the builder does or the map is a decoration that
-- lies." It drifted, the map lied, and the plaza got drawn over plots that the
-- builder had not skipped. One function, three callers, no copies.
--
-- It is deliberately pure: no sm.* calls at all, so it loads in the Game script
-- (which has no world), in the World script, and on a client, and so the whole
-- of it can be executed and checked outside the game by dev/test_layout.py.
--
-- Everything is in BLOCKS and every coordinate is an INTEGER. One block is
-- 0.25 m; vanilla's own lift converts with `self.liftPos * 0.25`
-- (Data/Scripts/game/Lift.lua:299).
--
--
-- THE PLAZA IS A BLOCK OF CELLS, NOT A BAND
--
-- Two designs have been wrong here, and the second one is worth writing down
-- because it looked right and read badly.
--
-- First: a grid laid from a corner with a hole punched where the plaza went.
-- The hole was computed by different arithmetic than the grid, so the two could
-- disagree, and they did.
--
-- Second: the plaza as a wide SEGMENT on both axes, sitting on the origin, with
-- the plots laid outwards from its edges. That fixed the overlap -- a plot can
-- never start inside the plaza if it never starts there -- but a segment on an
-- axis is a band across the whole city, so a 50-block plaza also meant a
-- 50-block avenue running the full width and the full height. REPORTED:
-- "there are these huge chuncks metal three whcih is wasted space and looks
-- ugly", with a screenshot of nothing but decking to the horizon.
--
-- Third and current: the axis is an ordinary uniform run of plots and seams, and
-- the plaza is a square block of GRID CELLS at the middle of it. The plots in
-- that block are not built; the plaza covers them and the seams between them.
-- Streets everywhere else are ordinary width. That is what a city square is.
--
--
--   cols = 6, plot = 20, gap = 1, plazacells = 2
--
--     +----+----+---------+----+----+
--     | 20 | 20 |         | 20 | 20 |      the plaza is 2x2 cells:
--     +----+----+  PLAZA  +----+----+      20 + 1 + 20 = 41 blocks square,
--     | 20 | 20 |  41x41  | 20 | 20 |      and every street is 1 block
--     +----+----+---------+----+----+      like every other street
--     | 20 | 20 | 20 | 20 | 20 | 20 |
--
-- The whole run is then translated so the plaza's middle sits on the world
-- origin, which keeps spawn at 0,0 without any coordinate going fractional.

Layout = {}

Layout.BLOCK = 0.25

Layout.DEFAULT = {
	plot = 20, gap = 1, cols = 10, rows = 10,
	roadevery = 0, roadwidth = 6, plazacells = 2,
}

-- Fill in anything the caller left out. Every entry point runs this, so no
-- function below has to cope with a nil field.
function Layout.config( cfg )
	local d = Layout.DEFAULT
	cfg = cfg or {}
	return {
		plot = math.max( 1, math.floor( tonumber( cfg.plot ) or d.plot ) ),
		gap = math.max( 0, math.floor( tonumber( cfg.gap ) or d.gap ) ),
		cols = math.max( 1, math.floor( tonumber( cfg.cols ) or d.cols ) ),
		rows = math.max( 1, math.floor( tonumber( cfg.rows ) or d.rows ) ),
		roadevery = math.max( 0, math.floor( tonumber( cfg.roadevery ) or d.roadevery ) ),
		roadwidth = math.max( 1, math.floor( tonumber( cfg.roadwidth ) or d.roadwidth ) ),
		-- How many plot cells across the central plaza is. 0 means no plaza.
		-- Migration: this used to be `spawn`, a width in BLOCKS. An old saved
		-- grid is converted rather than ignored, so a host who laid out a city
		-- before V28 gets the nearest thing to it instead of the default.
		plazacells = plazaCells( cfg, d ),
	}
end

function plazaCells( cfg, d )
	if cfg.plazacells ~= nil then
		return math.max( 0, math.floor( tonumber( cfg.plazacells ) or d.plazacells ) )
	end
	if cfg.spawn ~= nil then
		local blocks = math.max( 0, math.floor( tonumber( cfg.spawn ) or 0 ) )
		if blocks <= 0 then return 0 end
		local stride = ( tonumber( cfg.plot ) or d.plot ) + ( tonumber( cfg.gap ) or d.gap )
		return math.max( 1, math.floor( blocks / stride + 0.5 ) )
	end
	return d.plazacells
end

-- Which cells the plaza occupies on one axis: [first, last]. nil when there is
-- no plaza, or when it would swallow the whole grid.
function Layout.plazaRange( cfg, count )
	local k = cfg.plazacells
	if k <= 0 or k >= count then return nil end
	local first = math.floor( ( count - k ) / 2 )
	return first, first + k - 1
end

-- Is the seam AFTER plot i a road?
local function seamIsRoad( cfg, i )
	return cfg.roadevery > 0 and ( ( i + 1 ) % cfg.roadevery == 0 )
end


--[[ the axis ]]

-- One axis of the city, as an ordered run of segments. Segment kinds:
--
--   plot    ground, carries `index` 0..count-1 left to right. A plot inside the
--           plaza block is still a plot segment on the axis -- it is only in
--           two dimensions that a cell becomes plaza -- so the axis stays a
--           plain uniform run and nothing special-cases the middle.
--   filler  the one-block seam between two neighbouring plots, shared ground
--           once those two team up. Carries the index of the plot BELOW it.
--   road    a public street. Never claimable, never shared, never teamable
--           across.
--
-- The run is laid out from zero and then TRANSLATED so the plaza's centre sits
-- on the world origin. The shift is a whole number of blocks, so nothing ever
-- lands on a half block -- which is the bug that started this file.
--
-- Returns segs, minBlock, maxBlock.
function Layout.axis( cfg, count )
	local segs = {}
	local at = 0
	for i = 0, count - 1 do
		segs[#segs + 1] = { start = at, size = cfg.plot, kind = "plot", index = i }
		at = at + cfg.plot
		if i < count - 1 then
			local road = seamIsRoad( cfg, i )
			local width = road and cfg.roadwidth or cfg.gap
			if width > 0 then
				segs[#segs + 1] = { start = at, size = width,
					kind = road and "road" or "filler", index = i }
				at = at + width
			end
		end
	end

	-- Put the middle of the city on the origin: the plaza when there is one,
	-- otherwise the whole run.
	local lo, hi = 0, at
	local first, last = Layout.plazaRange( cfg, count )
	if first then
		for _, seg in ipairs( segs ) do
			if seg.kind == "plot" and seg.index == first then lo = seg.start end
			if seg.kind == "plot" and seg.index == last then hi = seg.start + seg.size end
		end
	end
	local shift = -math.floor( ( lo + hi ) / 2 )
	for _, seg in ipairs( segs ) do
		seg.start = seg.start + shift
	end

	return segs, shift, at + shift
end

-- Both axes and the bounding box, which is what most callers actually want.
function Layout.grid( cfg )
	cfg = Layout.config( cfg )
	local cols, x0, x1 = Layout.axis( cfg, cfg.cols )
	local rows, y0, y1 = Layout.axis( cfg, cfg.rows )
	local cx0, cx1 = Layout.plazaRange( cfg, cfg.cols )
	local cy0, cy1 = Layout.plazaRange( cfg, cfg.rows )
	local grid = { cfg = cfg, cols = cols, rows = rows,
		x0 = x0, x1 = x1, y0 = y0, y1 = y1,
		width = x1 - x0, height = y1 - y0,
		-- which CELLS the plaza covers, on each axis, or nil for no plaza
		pcx0 = cx0, pcx1 = cx1, pcy0 = cy0, pcy1 = cy1 }
	grid.plaza = Layout.plazaRect( grid )
	return grid
end

-- The plaza in blocks: the cells it covers plus the seams between them, as one
-- rectangle. nil when there is no plaza.
function Layout.plazaRect( grid )
	if grid.pcx0 == nil or grid.pcy0 == nil then return nil end
	local x0, x1, y0, y1
	for _, s in ipairs( grid.cols ) do
		if s.kind == "plot" and s.index == grid.pcx0 then x0 = s.start end
		if s.kind == "plot" and s.index == grid.pcx1 then x1 = s.start + s.size end
	end
	for _, s in ipairs( grid.rows ) do
		if s.kind == "plot" and s.index == grid.pcy0 then y0 = s.start end
		if s.kind == "plot" and s.index == grid.pcy1 then y1 = s.start + s.size end
	end
	if x0 == nil or y0 == nil then return nil end
	return { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
end

-- Is this grid cell part of the plaza? Plots here are not built.
function Layout.isPlazaCell( grid, col, row )
	return grid.pcx0 ~= nil and grid.pcy0 ~= nil
		and col >= grid.pcx0 and col <= grid.pcx1
		and row >= grid.pcy0 and row <= grid.pcy1
end

local function segmentAt( segs, v )
	for _, s in ipairs( segs ) do
		if v >= s.start and v < s.start + s.size then return s end
	end
	return nil
end

-- The seam between plot i and plot i+1 on this axis, but ONLY if it is a filler.
-- A road between two plots, or the plaza between them, means there is no shared
-- ground and therefore no teaming: that is the whole difference between a filler
-- and a road, and it falls out of the segment list rather than being a rule
-- written down twice.
function Layout.fillerBetween( segs, i )
	for _, s in ipairs( segs ) do
		if s.kind == "filler" and s.index == i then return s end
	end
	return nil
end


--[[ locating ]]

-- Which zone a point in BLOCK coordinates falls in. nil means off the city.
--
-- A plaza band in either direction wins, then a road, then a filler, because
-- that is the order of "how public is this ground": the plaza and the avenues
-- belong to the event, roads belong to everyone, a filler belongs to at most
-- two neighbours.
function Layout.locate( grid, bx, by )
	local sx = segmentAt( grid.cols, bx )
	local sy = segmentAt( grid.rows, by )
	if sx == nil or sy == nil then return nil end

	-- The plaza swallows whole cells and the seams between them, so a point is
	-- on it whenever it is inside that one rectangle -- including the seams,
	-- which is why this is tested before the segment kinds.
	local p = grid.plaza
	if p and bx >= p.x and bx < p.x + p.w and by >= p.y and by < p.y + p.h then
		return { kind = "plaza" }
	end
	if sx.kind == "road" or sy.kind == "road" then
		return { kind = "road" }
	end
	if sx.kind == "plot" and sy.kind == "plot" then
		return { kind = "plot", col = sx.index, row = sy.index,
			index = sy.index * grid.cfg.cols + sx.index + 1 }
	end
	if sx.kind == "plot" then
		return { kind = "fillerY", col = sx.index, row = sy.index }
	end
	if sy.kind == "plot" then
		return { kind = "fillerX", col = sx.index, row = sy.index }
	end
	return { kind = "corner", col = sx.index, row = sy.index }
end

-- The rectangle a plot occupies, in blocks. nil if that plot is off the grid.
function Layout.plotRect( grid, col, row )
	if Layout.isPlazaCell( grid, col, row ) then return nil end
	local sx, sy
	for _, s in ipairs( grid.cols ) do
		if s.kind == "plot" and s.index == col then sx = s end
	end
	for _, s in ipairs( grid.rows ) do
		if s.kind == "plot" and s.index == row then sy = s end
	end
	if sx == nil or sy == nil then return nil end
	return { x = sx.start, y = sy.start, w = sx.size, h = sy.size }
end

-- nil for a cell the plaza covers: there is no plot there to claim, to team with
-- or to stand on. One choke point, so nothing downstream has to remember.
function Layout.plotIndex( grid, col, row )
	local cfg = grid.cfg
	if col < 0 or row < 0 or col >= cfg.cols or row >= cfg.rows then return nil end
	if Layout.isPlazaCell( grid, col, row ) then return nil end
	return row * cfg.cols + col + 1
end

-- Does a plot with this index exist, or is it under the plaza?
function Layout.plotExists( grid, index )
	local col, row = Layout.plotColRow( grid, index )
	if col == nil then return false end
	return not Layout.isPlazaCell( grid, col, row )
end

function Layout.plotColRow( grid, index )
	local cfg = grid.cfg
	if index == nil or index < 1 or index > cfg.cols * cfg.rows then return nil end
	return ( index - 1 ) % cfg.cols, math.floor( ( index - 1 ) / cfg.cols )
end

-- The middle of a plot in blocks -- where /home puts you, and where the map
-- draws a marker.
function Layout.plotCentre( grid, index )
	local col, row = Layout.plotColRow( grid, index )
	if col == nil then return nil end
	local r = Layout.plotRect( grid, col, row )
	if r == nil then return nil end
	return r.x + r.w * 0.5, r.y + r.h * 0.5
end


--[[ the deck ]]

-- Every piece of shared ground, as non-overlapping rectangles in blocks.
--
-- This is a PARTITION and it is one by construction, not by checking:
--
--   * the plaza cell is emitted once, and only once
--   * a non-plot column becomes one strip running the full height of the city,
--     which is what fills every crossing -- except the plaza column, which is
--     emitted as the part below the plaza and the part above it, so it cannot
--     cover the plaza cell twice
--   * a non-plot row is emitted only across the PLOT columns, because every
--     other column was already covered by its full-height strip
--
-- What is left over is exactly the plot squares, and those are separate
-- creations built by Plots.plotBlueprint.
--
-- dev/test_layout.py enumerates every block of every piece over a spread of
-- configurations and asserts no block is ever claimed twice.
function Layout.deckPieces( grid )
	local out = {}
	local cols, rows = grid.cols, grid.rows
	local P = grid.plaza

	local function piece( x, y, w, h, kind )
		if w > 0 and h > 0 then
			out[#out + 1] = { x = x, y = y, w = w, h = h, kind = kind }
		end
	end

	-- Does this x range cross the plaza?
	local function crossesX( x, w )
		return P ~= nil and x < P.x + P.w and x + w > P.x
	end

	-- A vertical strip, split around the plaza when it runs through it. That
	-- split is the whole reason the plaza can be a block of cells rather than a
	-- band: the seams that would have crossed it stop at its edge instead.
	local function vstrip( x, w, kind )
		if not crossesX( x, w ) then
			piece( x, grid.y0, w, grid.height, kind )
			return
		end
		piece( x, grid.y0, w, P.y - grid.y0, kind )
		piece( x, P.y + P.h, w, grid.y1 - ( P.y + P.h ), kind )
	end

	if P then
		piece( P.x, P.y, P.w, P.h, "plaza" )
	end

	for _, cs in ipairs( cols ) do
		if cs.kind ~= "plot" then
			vstrip( cs.start, cs.size, cs.kind )
		end
	end

	-- Horizontal seams, only across the PLOT columns -- every other column was
	-- covered by its full-height strip above. Skipped where the plaza already
	-- covers the ground.
	for _, rs in ipairs( rows ) do
		if rs.kind ~= "plot" then
			for _, cs in ipairs( cols ) do
				if cs.kind == "plot" then
					local inside = P ~= nil
						and cs.start >= P.x and cs.start + cs.size <= P.x + P.w
						and rs.start >= P.y and rs.start + rs.size <= P.y + P.h
					if not inside then
						piece( cs.start, rs.start, cs.size, rs.size, rs.kind )
					end
				end
			end
		end
	end

	return out
end

-- Plots in the order they should be built: nearest the middle first, so a host
-- watching the city go up sees it grow outwards from spawn rather than sweep in
-- from a corner. Chebyshev distance, so it fills in rings.
function Layout.buildOrder( grid )
	local cfg = grid.cfg
	local list = {}
	for row = 0, cfg.rows - 1 do
		for col = 0, cfg.cols - 1 do
			local r = Layout.plotRect( grid, col, row )
			if r then
				local cx = math.abs( r.x + r.w * 0.5 )
				local cy = math.abs( r.y + r.h * 0.5 )
				list[#list + 1] = { col = col, row = row,
					index = Layout.plotIndex( grid, col, row ),
					d = math.max( cx, cy ) }
			end
		end
	end
	table.sort( list, function( a, b )
		if a.d ~= b.d then return a.d < b.d end
		return a.index < b.index
	end )
	return list
end

-- What the numbers actually produce, for the panel. Worth showing, because "20
-- blocks" means nothing until you know it is five metres.
function Layout.summary( cfg )
	local grid = Layout.grid( cfg )
	local c = grid.cfg
	local pieces = Layout.deckPieces( grid )
	local plots = #Layout.buildOrder( grid )
	local eaten = c.cols * c.rows - plots
	return {
		plots = plots,
		eaten = eaten,
		plotM = c.plot * Layout.BLOCK,
		acrossM = grid.width * Layout.BLOCK,
		deepM = grid.height * Layout.BLOCK,
		spawnM = grid.plaza and grid.plaza.w * Layout.BLOCK or 0,
		-- +1 for the base slab under the whole footprint. It is not a deck piece
		-- -- it deliberately overlaps every one of them one block lower -- so it
		-- is counted here rather than emitted by deckPieces, which has to stay a
		-- partition for dev/test_layout.py to mean anything.
		shapes = plots + #pieces + 1,
		pieces = #pieces,
	}
end
