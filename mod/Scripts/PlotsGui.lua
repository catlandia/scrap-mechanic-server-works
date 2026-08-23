-- PlotsGui -- lay out the city before building it.
--
-- /plotgrid took four numbers on one chat line and built immediately, which
-- meant finding out a plot was too small only after 100 of them existed. This
-- shows the consequences of the numbers -- plot count, metres across, how much
-- the plaza eats -- and does nothing until CONFIRM.
--
-- Same widget vocabulary as SettingsGui: PanelEmpty containers, WhiteSkin
-- rectangles for the panel and dividers, TextBox for type, onClickData to carry
-- which field a button belongs to. See SettingsGui.lua for where that came from.

PlotsGui = {}

PlotsGui.W = 1060
PlotsGui.H = 620

local ROW_H = 52
local ROW_TOP = 108
local PAD = 28
local VALUE_W = 150
local MAP = 380          -- the 2D map is square and sits on the right

local BG = "0.055 0.062 0.078 1"
local PANEL = "1 1 1 1"
local ACCENT = "1 0.54 0.18 1"
local DIM = "0.62 0.65 0.72 1"
local LABEL = "0.90 0.92 0.96 1"

local BLOCK = 0.25

-- field, label, help, and the values it cycles through
PlotsGui.FIELDS = {
	{ key = "plot", label = "PLOT SIZE",
	  help = "each plot, in blocks square",
	  steps = { 8, 12, 16, 20, 24, 32, 40, 48, 64 } },
	{ key = "gap", label = "STREET WIDTH",
	  help = "metal 2 line between plots, in blocks",
	  steps = { 0, 1, 2, 3, 4, 6 } },
	{ key = "cols", label = "COLUMNS",
	  help = "plots across",
	  steps = { 2, 4, 6, 8, 10, 12, 14, 16, 20 } },
	{ key = "rows", label = "ROWS",
	  help = "plots deep",
	  steps = { 2, 4, 6, 8, 10, 12, 14, 16, 20 } },
	{ key = "roadevery", label = "ROAD EVERY",
	  help = "a proper street every N plots. 0 for none, fillers only",
	  steps = { 0, 2, 3, 4, 5, 6 } },
	{ key = "roadwidth", label = "ROAD WIDTH",
	  help = "how wide a road is, in blocks",
	  steps = { 2, 4, 6, 8, 12 } },
	{ key = "spawn", label = "SPAWN PLAZA",
	  help = "metal 3 plate at the centre, in blocks square. 0 for none",
	  steps = { 0, 20, 30, 50, 80, 120 } },
}

local function widget( t )
	t.Childs = t.Childs or {}
	if t.NeedKey == nil then t.NeedKey = true end
	if t.NeedMouse == nil then t.NeedMouse = true end
	return t
end

local function fill( name, x, y, w, h, colour, alpha )
	return widget{ Name = name, Type = "Widget", Skin = "WhiteSkin",
		Colour = colour, Alpha = alpha, x = x, y = y, width = w, height = h,
		NeedKey = false, NeedMouse = false }
end

local function text( name, caption, x, y, w, h, font, colour, align )
	return widget{ Name = name, Type = "TextBox", Skin = "TextBox",
		Caption = caption, FontName = font or "SM_Text", Colour = colour or LABEL,
		TextAlign = align or "Left", x = x, y = y, width = w, height = h,
		NeedKey = false, NeedMouse = false }
end

local function button( name, caption, x, y, w, h, skin, data, font )
	local b = widget{ Name = name, Type = "Button", Skin = skin or "SecondaryButton",
		Caption = caption, FontName = font or "SM_Button", TextAlign = "Center",
		x = x, y = y, width = w, height = h }
	b.onClick = "cl_onPlotsGuiClick"
	b.onClickData = data
	return b
end

-- Mirrors Plots.sv_axis. The panel has to lay the city out the same way the
-- builder does or the map is a decoration that lies.
function PlotsGui.Axis( cfg, count )
	local segs, at = {}, 0
	for i = 0, count - 1 do
		segs[#segs + 1] = { start = at, size = cfg.plot, kind = "plot", index = i }
		at = at + cfg.plot
		local isRoad = ( cfg.roadevery or 0 ) > 0 and ( ( i + 1 ) % cfg.roadevery == 0 )
		local width = isRoad and ( cfg.roadwidth or 6 ) or cfg.gap
		if width > 0 and i < count - 1 then
			segs[#segs + 1] = { start = at, size = width,
				kind = isRoad and "road" or "filler", index = i }
			at = at + width
		end
	end
	return segs, at
end

-- What the numbers actually produce. Worth showing, because "20 blocks" means
-- nothing until you know it is five metres.
function PlotsGui.Summary( cfg )
	local _, acrossBlocks = PlotsGui.Axis( cfg, cfg.cols )
	local _, deepBlocks = PlotsGui.Axis( cfg, cfg.rows )
	local total = cfg.cols * cfg.rows

	-- plots the plaza swallows, by the same test the builder uses
	local eaten = 0
	if cfg.spawn > 0 then
		local half = math.floor( cfg.spawn / 2 )
		local cols = PlotsGui.Axis( cfg, cfg.cols )
		local rows = PlotsGui.Axis( cfg, cfg.rows )
		local ox, oy = -acrossBlocks * 0.5, -deepBlocks * 0.5
		for _, cs in ipairs( cols ) do
			for _, rs in ipairs( rows ) do
				if cs.kind == "plot" and rs.kind == "plot" then
					local x0, y0 = ox + cs.start, oy + rs.start
					if x0 < half and x0 + cfg.plot > -half
						and y0 < half and y0 + cfg.plot > -half then
						eaten = eaten + 1
					end
				end
			end
		end
	end

	return {
		plots = total - eaten,
		eaten = eaten,
		plotM = cfg.plot * BLOCK,
		acrossM = acrossBlocks * BLOCK,
		deepM = deepBlocks * BLOCK,
		spawnM = cfg.spawn * BLOCK,
		shapes = ( total - eaten ) + cfg.cols + cfg.rows * cfg.cols + ( cfg.spawn > 0 and 2 or 0 ),
	}
end

-- A true top-down map, drawn from the SAME axis the builder uses, so what you
-- see is what gets built. Claimed plots come from the server so a host can see
-- at a glance which ground is already spoken for.
function PlotsGui.AddMap( kids, cfg, x, y, size )
	local cols, w = PlotsGui.Axis( cfg, cfg.cols )
	local rows, h = PlotsGui.Axis( cfg, cfg.rows )
	local span = math.max( w, h, 1 )
	local scale = size / span
	local ox = x + ( size - w * scale ) * 0.5
	local oy = y + ( size - h * scale ) * 0.5

	kids[#kids + 1] = fill( "MapBG", x - 8, y - 8, size + 16, size + 16, PANEL, 0.04 )
	kids[#kids + 1] = text( "MapTitle", "TOP DOWN", x, y - 30, size, 18,
		"SM_LabelMini", DIM, "Left" )

	local function cell( name, cx, cy, cw, ch, colour, alpha )
		if cw * scale < 1 or ch * scale < 1 then return end
		kids[#kids + 1] = fill( name,
			math.floor( ox + cx * scale ), math.floor( oy + cy * scale ),
			math.max( 1, math.floor( cw * scale ) ), math.max( 1, math.floor( ch * scale ) ),
			colour, alpha )
	end

	-- seams first, plots on top
	for i, cs in ipairs( cols ) do
		if cs.kind ~= "plot" then
			cell( "mc" .. i, cs.start, 0, cs.size, h,
				cs.kind == "road" and "0.30 0.31 0.34 1" or "0.42 0.40 0.38 1", 1 )
		end
	end
	for i, rs in ipairs( rows ) do
		if rs.kind ~= "plot" then
			cell( "mr" .. i, 0, rs.start, w, rs.size,
				rs.kind == "road" and "0.30 0.31 0.34 1" or "0.42 0.40 0.38 1", 1 )
		end
	end

	local claimed = cfg.claimed or {}
	local half = math.floor( ( cfg.spawn or 0 ) / 2 )
	for _, cs in ipairs( cols ) do
		for _, rs in ipairs( rows ) do
			if cs.kind == "plot" and rs.kind == "plot" then
				local index = rs.index * cfg.cols + cs.index + 1
				local x0, y0 = cs.start - w * 0.5, rs.start - h * 0.5
				local eaten = ( cfg.spawn or 0 ) > 0
					and x0 < half and x0 + cfg.plot > -half
					and y0 < half and y0 + cfg.plot > -half
				if not eaten then
					local owned = claimed[tostring( index )] ~= nil
					cell( "mp" .. index, cs.start, rs.start, cfg.plot, cfg.plot,
						owned and ACCENT or "0.62 0.63 0.60 1", owned and 0.95 or 0.8 )
				end
			end
		end
	end

	if ( cfg.spawn or 0 ) > 0 then
		cell( "mplaza", w * 0.5 - half, h * 0.5 - half, cfg.spawn, cfg.spawn,
			"1 0.74 0.35 1", 1 )
	end

	kids[#kids + 1] = text( "MapKey",
		"orange centre = spawn    orange plot = claimed    dark = road",
		x, y + size + 14, size, 18, "SM_TextTiny", DIM, "Left" )
end

function PlotsGui.Build( cfg )
	local root = widget{ Name = "BackPanel", Type = "Widget", Skin = "PanelEmpty",
		Anchor = "Center", InheritsPick = true, NeedKey = false, NeedMouse = false,
		x = 0, y = 0, width = PlotsGui.W, height = PlotsGui.H }
	root.onClose = "cl_onPlotsGuiClose"
	local kids = root.Childs

	kids[#kids + 1] = fill( "BG", 0, 0, PlotsGui.W, PlotsGui.H, BG, 0.96 )
	kids[#kids + 1] = fill( "HeaderBand", 0, 0, PlotsGui.W, 68, PANEL, 0.05 )
	kids[#kids + 1] = fill( "HeaderRule", 0, 68, PlotsGui.W, 2, ACCENT, 1 )
	kids[#kids + 1] = text( "Title", "CITY LAYOUT", PAD, 18, 460, 34,
		"SM_HeaderLarge_Medium", LABEL, "Left" )
	kids[#kids + 1] = text( "Sub", "nothing is built until you press BUILD",
		PAD, 46, 520, 20, "SM_TextTiny", DIM, "Left" )

	for i, f in ipairs( PlotsGui.FIELDS ) do
		local y = ROW_TOP + ( i - 1 ) * ROW_H
		local rowW = PlotsGui.W - PAD * 2 - MAP - 24
		kids[#kids + 1] = fill( "Row" .. i, PAD, y, rowW, ROW_H - 8,
			PANEL, ( i % 2 == 0 ) and 0.015 or 0.035 )
		kids[#kids + 1] = text( "L" .. i, f.label, PAD + 16, y + 5, 300, 20,
			"SM_Label", LABEL, "Left" )
		kids[#kids + 1] = text( "H" .. i, f.help, PAD + 16, y + 25, rowW - VALUE_W - 70, 18,
			"SM_TextTiny", DIM, "Left" )
		kids[#kids + 1] = button( "Dec" .. i, "<",
			PAD + rowW - VALUE_W - 48, y + 8, 32, ROW_H - 24, "SecondaryButton",
			{ action = "step", key = f.key, dir = -1 } )
		kids[#kids + 1] = text( "V" .. i, tostring( cfg[f.key] ),
			PAD + rowW - VALUE_W - 12, y + 10, 72, 22,
			"SM_NumberSmall", ACCENT, "Center" )
		kids[#kids + 1] = button( "Inc" .. i, ">",
			PAD + rowW - 48, y + 8, 32, ROW_H - 24, "SecondaryButton",
			{ action = "step", key = f.key, dir = 1 } )
	end

	local rowW = PlotsGui.W - PAD * 2 - MAP - 24
	PlotsGui.AddMap( kids, cfg, PlotsGui.W - PAD - MAP, ROW_TOP, MAP )

	local s = PlotsGui.Summary( cfg )
	local sy = ROW_TOP + #PlotsGui.FIELDS * ROW_H + 8
	kids[#kids + 1] = fill( "SumRule", PAD, sy, rowW, 1, PANEL, 0.12 )
	kids[#kids + 1] = text( "Sum1", string.format(
		"%d plots of %.1f m    city %.0f x %.0f m    plaza %.1f m",
		s.plots, s.plotM, s.acrossM, s.deepM, s.spawnM ),
		PAD, sy + 12, rowW, 22, "SM_Label", LABEL, "Left" )
	kids[#kids + 1] = text( "Sum2", string.format(
		"%d shapes total%s", s.shapes,
		s.eaten > 0 and string.format( "    %d plots given up to the plaza", s.eaten ) or "" ),
		PAD, sy + 34, rowW, 20, "SM_TextTiny", DIM, "Left" )

	local fy = PlotsGui.H - 58
	kids[#kids + 1] = button( "Clear", "CLEAR CITY", PAD, fy, 150, 34,
		"SecondaryButton", { action = "clear" } )
	kids[#kids + 1] = button( "Reset", "DEFAULTS", PAD + 162, fy, 130, 34,
		"SecondaryButton", { action = "reset" } )
	kids[#kids + 1] = button( "Build", "BUILD CITY", PlotsGui.W - PAD - 180, fy, 180, 34,
		"StyledButtonLarge", { action = "build" } )

	return root
end

function PlotsGui.Step( key, current, dir )
	for _, f in ipairs( PlotsGui.FIELDS ) do
		if f.key == key then
			for i, v in ipairs( f.steps ) do
				if v == current then
					local n = i + dir
					if n < 1 then n = #f.steps elseif n > #f.steps then n = 1 end
					return f.steps[n]
				end
			end
			return f.steps[1]
		end
	end
	return current
end
