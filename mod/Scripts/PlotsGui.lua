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

PlotsGui.W = 760
PlotsGui.H = 560

local ROW_H = 52
local ROW_TOP = 108
local PAD = 28
local VALUE_W = 150

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

-- What the numbers actually produce. Worth showing, because "20 blocks" means
-- nothing until you know it is five metres.
function PlotsGui.Summary( cfg )
	local stride = cfg.plot + cfg.gap
	local acrossBlocks = cfg.cols * stride
	local deepBlocks = cfg.rows * stride
	local total = cfg.cols * cfg.rows

	-- plots the plaza swallows, by the same test the builder uses
	local eaten = 0
	if cfg.spawn > 0 then
		local half = math.floor( cfg.spawn / 2 )
		local ox = -( cfg.cols * stride ) * 0.5
		local oy = -( cfg.rows * stride ) * 0.5
		for row = 0, cfg.rows - 1 do
			for col = 0, cfg.cols - 1 do
				local x0, y0 = ox + col * stride, oy + row * stride
				if x0 < half and x0 + cfg.plot > -half
					and y0 < half and y0 + cfg.plot > -half then
					eaten = eaten + 1
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
		shapes = ( total - eaten ) * 2 + cfg.cols * cfg.rows * 2 + ( cfg.spawn > 0 and 2 or 0 ),
	}
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
		kids[#kids + 1] = fill( "Row" .. i, PAD, y, PlotsGui.W - PAD * 2, ROW_H - 8,
			PANEL, ( i % 2 == 0 ) and 0.015 or 0.035 )
		kids[#kids + 1] = text( "L" .. i, f.label, PAD + 16, y + 5, 300, 20,
			"SM_Label", LABEL, "Left" )
		kids[#kids + 1] = text( "H" .. i, f.help, PAD + 16, y + 25, 420, 18,
			"SM_TextTiny", DIM, "Left" )
		kids[#kids + 1] = button( "Dec" .. i, "<",
			PlotsGui.W - PAD - VALUE_W - 76, y + 8, 32, ROW_H - 24, "SecondaryButton",
			{ action = "step", key = f.key, dir = -1 } )
		kids[#kids + 1] = text( "V" .. i, tostring( cfg[f.key] ),
			PlotsGui.W - PAD - VALUE_W - 40, y + 10, 72, 22,
			"SM_NumberSmall", ACCENT, "Center" )
		kids[#kids + 1] = button( "Inc" .. i, ">",
			PlotsGui.W - PAD - 76, y + 8, 32, ROW_H - 24, "SecondaryButton",
			{ action = "step", key = f.key, dir = 1 } )
	end

	local s = PlotsGui.Summary( cfg )
	local sy = ROW_TOP + #PlotsGui.FIELDS * ROW_H + 8
	kids[#kids + 1] = fill( "SumRule", PAD, sy, PlotsGui.W - PAD * 2, 1, PANEL, 0.12 )
	kids[#kids + 1] = text( "Sum1", string.format(
		"%d plots of %.1f m    city %.0f x %.0f m    plaza %.1f m",
		s.plots, s.plotM, s.acrossM, s.deepM, s.spawnM ),
		PAD, sy + 12, PlotsGui.W - PAD * 2, 22, "SM_Label", LABEL, "Left" )
	kids[#kids + 1] = text( "Sum2", string.format(
		"%d shapes total%s", s.shapes,
		s.eaten > 0 and string.format( "    %d plots given up to the plaza", s.eaten ) or "" ),
		PAD, sy + 34, PlotsGui.W - PAD * 2, 20, "SM_TextTiny", DIM, "Left" )

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
