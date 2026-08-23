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
-- WHY IT IS BUILT FROM THE MIDDLE OUTWARDS
--
-- The old layout ran a grid from a corner and then punched a hole where the
-- spawn plaza was. That is wrong twice over. The hole is computed by a
-- different rule than the grid, so the two can disagree -- and they did. And
-- centring a corner-anchored grid means the origin lands on a half block
-- whenever the run has an odd extent (10 plots of 20 with 1-block seams is 209
-- blocks across, so every coordinate came out at x.5).
--
-- So the plaza is not a hole. It is the FIRST thing on the axis, sitting on the
-- origin, and the plots are laid outwards from its edge in both directions. A
-- plot can then never overlap the plaza, because it never starts inside it --
-- not because something checked. Coordinates stay integers because the plaza's
-- half-width is an integer and everything else is measured from there.
--
--
-- WHAT THE AXIS LOOKS LIKE (cols = 6, plot = 20, gap = 1, spawn = 50)
--
--   ... 20 |1| 20 |1| 20 |1|<--- 50 --->|1| 20 |1| 20 |1| 20 ...
--          plots 0..2       the plaza        plots 3..5
--                        centred on x = 0
--
-- The plaza band is a segment on BOTH axes, so where the two bands cross is the
-- plaza itself and where a band crosses ordinary plots is a wide avenue running
-- out to the city edge. The city is one raised platform standing on a single
-- central pillar, with two grand avenues leading away from it.

Layout = {}

Layout.BLOCK = 0.25

Layout.DEFAULT = {
	plot = 20, gap = 1, cols = 10, rows = 10,
	roadevery = 0, roadwidth = 6, spawn = 50,
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
		spawn = math.max( 0, math.floor( tonumber( cfg.spawn ) or d.spawn ) ),
	}
end

-- The plaza is forced to an even number of blocks so its half-width is a whole
-- block and the entire axis stays on integers.
function Layout.plazaHalf( cfg )
	return math.floor( cfg.spawn / 2 )
end

-- The strip between the plaza and the first ring of plots. A road when the host
-- has roads switched on, otherwise the ordinary seam width.
local function ringWidth( cfg )
	if cfg.roadevery > 0 then return cfg.roadwidth end
	return cfg.gap
end

-- Is the seam AFTER plot i (counting outwards from the middle) a road?
local function seamIsRoad( cfg, stepsOut )
	return cfg.roadevery > 0 and ( stepsOut % cfg.roadevery == 0 )
end


--[[ the axis ]]

-- One axis of the city, as an ordered run of segments from the most negative
-- block to the most positive. Segment kinds:
--
--   plot    claimable ground, carries `index` 0..count-1 left to right
--   filler  the one-block seam between two neighbouring plots -- shared ground
--           once those two team up. Carries the index of the plot BELOW it.
--   road    a public street. Never claimable, never shared, never teamable
--           across. Includes the two rings either side of the plaza.
--   plaza   the middle. Spawn, the only pillar, and the trunk of both avenues.
--
-- Returns segs, minBlock, maxBlock.
function Layout.axis( cfg, count )
	local segs = {}
	local push = function( s ) segs[#segs + 1] = s end

	-- Split the run either side of the middle. An odd count puts the extra plot
	-- on the positive side; nothing downstream cares which side it went.
	local right = math.ceil( count / 2 )
	local left = count - right

	local half = Layout.plazaHalf( cfg )
	local ring = ringWidth( cfg )
	local rightFrom, leftFrom

	if cfg.spawn > 0 then
		push{ start = -half, size = half * 2, kind = "plaza" }
		rightFrom, leftFrom = half, -half
		if ring > 0 then
			push{ start = half, size = ring, kind = "road", ring = true }
			push{ start = -half - ring, size = ring, kind = "road", ring = true }
			rightFrom, leftFrom = half + ring, -half - ring
		end
	elseif cfg.gap > 0 and left > 0 then
		-- No plaza: the two halves still must not touch, so one ordinary seam
		-- sits on the origin. It goes entirely on the positive side rather than
		-- straddling zero, because straddling a 1-block seam would need a half
		-- block and the whole point here is that nothing is ever fractional.
		push{ start = 0, size = cfg.gap, kind = "filler", index = left - 1 }
		rightFrom, leftFrom = cfg.gap, 0
	else
		rightFrom, leftFrom = 0, 0
	end

	-- outwards, positive side
	local at = rightFrom
	for k = 0, right - 1 do
		local index = left + k
		push{ start = at, size = cfg.plot, kind = "plot", index = index }
		at = at + cfg.plot
		if k < right - 1 then
			local road = seamIsRoad( cfg, k + 1 )
			local width = road and cfg.roadwidth or cfg.gap
			if width > 0 then
				push{ start = at, size = width,
					kind = road and "road" or "filler", index = index }
				at = at + width
			end
		end
	end
	local maxBlock = at

	-- outwards, negative side. Mirrored, so plot 0 is the furthest out.
	at = leftFrom
	for k = 0, left - 1 do
		local index = left - 1 - k
		at = at - cfg.plot
		push{ start = at, size = cfg.plot, kind = "plot", index = index }
		if k < left - 1 then
			local road = seamIsRoad( cfg, k + 1 )
			local width = road and cfg.roadwidth or cfg.gap
			if width > 0 then
				at = at - width
				push{ start = at, size = width,
					kind = road and "road" or "filler", index = index - 1 }
			end
		end
	end
	local minBlock = at

	table.sort( segs, function( a, b ) return a.start < b.start end )
	return segs, minBlock, maxBlock
end

-- Both axes and the bounding box, which is what most callers actually want.
function Layout.grid( cfg )
	cfg = Layout.config( cfg )
	local cols, x0, x1 = Layout.axis( cfg, cfg.cols )
	local rows, y0, y1 = Layout.axis( cfg, cfg.rows )
	return { cfg = cfg, cols = cols, rows = rows,
		x0 = x0, x1 = x1, y0 = y0, y1 = y1,
		width = x1 - x0, height = y1 - y0 }
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

	if sx.kind == "plaza" and sy.kind == "plaza" then
		return { kind = "plaza" }
	end
	if sx.kind == "plaza" or sy.kind == "plaza" then
		return { kind = "avenue" }
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

function Layout.plotIndex( grid, col, row )
	local cfg = grid.cfg
	if col < 0 or row < 0 or col >= cfg.cols or row >= cfg.rows then return nil end
	return row * cfg.cols + col + 1
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
	local plaza = nil
	for _, s in ipairs( cols ) do
		if s.kind == "plaza" then plaza = s end
	end
	local plazaY = nil
	for _, s in ipairs( rows ) do
		if s.kind == "plaza" then plazaY = s end
	end

	local function piece( x, y, w, h, kind )
		if w > 0 and h > 0 then
			out[#out + 1] = { x = x, y = y, w = w, h = h, kind = kind }
		end
	end

	if plaza and plazaY then
		piece( plaza.start, plazaY.start, plaza.size, plazaY.size, "plaza" )
	end

	for _, cs in ipairs( cols ) do
		if cs.kind ~= "plot" then
			if cs.kind == "plaza" and plazaY then
				piece( cs.start, grid.y0, cs.size, plazaY.start - grid.y0, "avenue" )
				piece( cs.start, plazaY.start + plazaY.size, cs.size,
					grid.y1 - ( plazaY.start + plazaY.size ), "avenue" )
			else
				piece( cs.start, grid.y0, cs.size, grid.height, cs.kind )
			end
		end
	end

	for _, rs in ipairs( rows ) do
		if rs.kind ~= "plot" then
			for _, cs in ipairs( cols ) do
				if cs.kind == "plot" then
					piece( cs.start, rs.start, cs.size, rs.size,
						rs.kind == "plaza" and "avenue" or rs.kind )
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
	return {
		plots = c.cols * c.rows,
		plotM = c.plot * Layout.BLOCK,
		acrossM = grid.width * Layout.BLOCK,
		deepM = grid.height * Layout.BLOCK,
		spawnM = Layout.plazaHalf( c ) * 2 * Layout.BLOCK,
		shapes = c.cols * c.rows + #pieces + ( c.spawn > 0 and 1 or 0 ),
		pieces = #pieces,
	}
end
