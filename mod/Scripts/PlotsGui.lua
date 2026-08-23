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
	{ key = "plazacells", label = "SPAWN PLAZA",
	  help = "how many plots across the central square is. 0 for none",
	  steps = { 0, 1, 2, 3, 4 } },
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
		Caption = caption, FontName = font or "SM_ButtonLarge", TextAlign = "Center",
		x = x, y = y, width = w, height = h }
	b.onClick = "cl_onPlotsGuiClick"
	b.onClickData = data
	return b
end

-- A true top-down map, drawn from Layout -- the SAME code the builder runs, not
-- a copy of it. The copy that used to live here is exactly why this comment used
-- to say "the panel has to lay the city out the same way the builder does or the
-- map is a decoration that lies", and then the map lied: it drew a full street
-- grid over plots the builder had skipped for the plaza.
--
-- Claimed plots come from the server so a host can see at a glance which ground
-- is already spoken for.
function PlotsGui.AddMap( kids, cfg, x, y, size )
	local grid = Layout.grid( cfg )
	local span = math.max( grid.width, grid.height, 1 )
	local scale = size / span
	local ox = x + ( size - grid.width * scale ) * 0.5 - grid.x0 * scale
	local oy = y + ( size - grid.height * scale ) * 0.5 - grid.y0 * scale

	kids[#kids + 1] = fill( "MapBG", x - 8, y - 8, size + 16, size + 16, PANEL, 0.04 )
	kids[#kids + 1] = text( "MapTitle", "TOP DOWN", x, y - 30, size, 18,
		"SM_LabelTiny", DIM, "Left" )

	local function cell( name, cx, cy, cw, ch, colour, alpha )
		if cw * scale < 1 or ch * scale < 1 then return end
		kids[#kids + 1] = fill( name,
			math.floor( ox + cx * scale ), math.floor( oy + cy * scale ),
			math.max( 1, math.floor( cw * scale ) ), math.max( 1, math.floor( ch * scale ) ),
			colour, alpha )
	end

	local SHADE = {
		plaza = "1 0.74 0.35 1",
		road = "0.30 0.31 0.34 1",
		filler = "0.42 0.40 0.38 1",
	}

	-- Shared ground first, from the same partition the builder imports, so what
	-- is drawn here is what gets built -- piece for piece.
	local n = 0
	for _, p in ipairs( Layout.deckPieces( grid ) ) do
		n = n + 1
		cell( "md" .. n, p.x, p.y, p.w, p.h, SHADE[p.kind] or SHADE.filler, 1 )
	end

	local claimed = cfg.claimed or {}
	local mine = cfg.mine
	local team = cfg.team or {}
	for row = 0, grid.cfg.rows - 1 do
		for col = 0, grid.cfg.cols - 1 do
			local r = Layout.plotRect( grid, col, row )
			local index = Layout.plotIndex( grid, col, row )
			if r and index then
				local key = tostring( index )
				local owned = claimed[key] ~= nil
				local colour, alpha
				if index == mine then
					colour, alpha = "0.30 0.86 0.42 1", 1          -- yours
				elseif team[key] then
					colour, alpha = "0.24 0.55 0.34 1", 0.95        -- your team's
				elseif owned then
					colour, alpha = ACCENT, 0.95                    -- somebody else's
				else
					colour, alpha = "0.62 0.63 0.60 1", 0.8         -- free
				end
				cell( "mp" .. index, r.x, r.y, r.w, r.h, colour, alpha )
			end
		end
	end

	kids[#kids + 1] = text( "MapKey",
		"bright green = yours    dark green = your team    orange = taken    grey = free",
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

	local s = Layout.summary( cfg )
	local sy = ROW_TOP + #PlotsGui.FIELDS * ROW_H + 8
	kids[#kids + 1] = fill( "SumRule", PAD, sy, rowW, 1, PANEL, 0.12 )
	kids[#kids + 1] = text( "Sum1", string.format(
		"%d plots of %.1f m    city %.0f x %.0f m    plaza %.1f m",
		s.plots, s.plotM, s.acrossM, s.deepM, s.spawnM ),
		PAD, sy + 12, rowW, 22, "SM_Label", LABEL, "Left" )
	-- No plots are ever "given up to the plaza" any more: the plaza is the middle
	-- of the axis and the plots are laid outwards from it, so every plot the
	-- numbers promise is a plot that gets built.
	kids[#kids + 1] = text( "Sum2", string.format(
		"%d shapes total    %d pieces of shared ground    every plot gets built",
		s.shapes, s.pieces ),
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
