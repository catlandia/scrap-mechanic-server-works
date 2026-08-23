-- SettingsGui -- the settings panel.
--
-- Sized and built like the game's own full-screen UIs, not like a popup. The
-- first version stretched BackgroundPromptNarrow, a 346x346 alert-box skin, over
-- 660x560 and looked exactly as bad as that sounds.
--
-- The vocabulary here came from reading Survival/Gui/JsonGuis/*.gui, which is the
-- only documentation this format has:
--
--   Widget + Skin "PanelEmpty"          invisible container, no art
--   Widget + Skin "WhiteSkin" + Colour  a tinted rectangle. This is the whole
--                                       trick -- the game builds its own dividers
--                                       and fills this way, so a panel can be
--                                       drawn without any bespoke texture
--   TextBox + Skin "TextBox" + FontName real text styling
--   Button + Skin "StyledButtonLarge" / "SecondaryButton" / "UpgradeButton"
--
-- Handbook.gui is 1120x560, which is what a full-size panel looks like in this
-- game; this one matches that scale.
--
-- The tree is generated from Settings.SCHEMA rather than authored as a .gui file,
-- so adding a setting is still one schema row and the panel picks it up. A
-- hand-authored layout would need editing in parallel every time and would drift.
--
-- onClickData (Survival/.../HideoutTrader.lua:318) carries data into the click
-- handler, so one callback serves every button instead of a named function each.

SettingsGui = {}

SettingsGui.W = 1120
SettingsGui.H = 690

local NAV_W = 232
local ROW_H = 46
local ROW_TOP = 104
local BODY_X = NAV_W + 24
local BODY_W = SettingsGui.W - BODY_X - 24
local VALUE_W = 190
local ROWS = 10

local BG = "0.055 0.062 0.078 1"
local PANEL = "1 1 1 1"
local ACCENT = "1 0.54 0.18 1"
local DIM = "0.62 0.65 0.72 1"
local LABEL = "0.90 0.92 0.96 1"

-- Which settings belong under which tab, and the order they appear in. Anything
-- in the schema that is not listed here lands in "Other", so a new setting shows
-- up even if this table is not updated.
SettingsGui.GROUPS = {
	{ key = "safety", title = "SAFETY", keys = {
		"fire", "terraindamage", "aggro", "cornades", "beacons",
		"fireworks", "plasmadrills", "radios", "horns", "destructible",
		"cleanupdebris", "autoremove" } },
	{ key = "tools", title = "TOOLS", keys = {
		"claygun", "firelauncher", "extinguisher", "sledgehammer", "spudguns",
		"glowsticks", "painttool", "connecttool", "weldtool", "lift" } },
	{ key = "plots", title = "PLOTS", keys = {
		"plots", "pushintruders", "buildopen", "minbuildheight" } },
	{ key = "limits", title = "LIMITS", keys = {
		"maxjoints", "maxbots", "maxlights" } },
	{ key = "event", title = "EVENT", keys = {
		"allowlist", "alarmlock", "alarmdrop", "autosave" } },
}

local HIDDEN = { protection = true }


local function widget( t )
	t.Childs = t.Childs or {}
	if t.NeedKey == nil then t.NeedKey = true end
	if t.NeedMouse == nil then t.NeedMouse = true end
	return t
end

local function fill( name, x, y, w, h, colour, alpha )
	return widget{
		Name = name, Type = "Widget", Skin = "WhiteSkin",
		Colour = colour, Alpha = alpha,
		x = x, y = y, width = w, height = h,
		NeedKey = false, NeedMouse = false,
	}
end

local function text( name, caption, x, y, w, h, font, colour, align )
	return widget{
		Name = name, Type = "TextBox", Skin = "TextBox",
		Caption = caption, FontName = font or "SM_Text",
		Colour = colour or LABEL, TextAlign = align or "Left",
		x = x, y = y, width = w, height = h,
		NeedKey = false, NeedMouse = false,
	}
end

local function button( name, caption, x, y, w, h, skin, data, font )
	local b = widget{
		Name = name, Type = "Button", Skin = skin or "SecondaryButton",
		Caption = caption, FontName = font or "SM_Button", TextAlign = "Center",
		x = x, y = y, width = w, height = h,
	}
	b.onClick = "cl_onSettingsGuiClick"
	b.onClickData = data
	return b
end


function SettingsGui.RowsFor( groupKey )
	local byKey = {}
	for _, row in ipairs( Settings.SCHEMA ) do
		if not row.hidden and not HIDDEN[row.key] then
			byKey[row.key] = row
		end
	end

	local claimed = {}
	for _, g in ipairs( SettingsGui.GROUPS ) do
		for _, k in ipairs( g.keys ) do claimed[k] = true end
	end

	local out = {}
	if groupKey == "other" then
		for _, row in ipairs( Settings.SCHEMA ) do
			if byKey[row.key] and not claimed[row.key] then out[#out + 1] = row end
		end
		return out
	end
	for _, g in ipairs( SettingsGui.GROUPS ) do
		if g.key == groupKey then
			for _, k in ipairs( g.keys ) do
				if byKey[k] then out[#out + 1] = byKey[k] end
			end
		end
	end
	return out
end

function SettingsGui.HasOther()
	return #SettingsGui.RowsFor( "other" ) > 0
end

local function shown( row, value )
	if row.kind == "bool" then return value and "ON" or "OFF" end
	return tostring( value )
end


function SettingsGui.Build( values, group, page )
	group = group or "safety"
	page = page or 1

	local root = widget{
		Name = "BackPanel", Type = "Widget", Skin = "PanelEmpty", Anchor = "Center",
		InheritsPick = true, NeedKey = false, NeedMouse = false,
		x = 0, y = 0, width = SettingsGui.W, height = SettingsGui.H,
	}
	root.onClose = "cl_onSettingsGuiClose"
	local kids = root.Childs

	-- background, header band, and the rule under it
	kids[#kids + 1] = fill( "BG", 0, 0, SettingsGui.W, SettingsGui.H, BG, 0.96 )
	kids[#kids + 1] = fill( "HeaderBand", 0, 0, SettingsGui.W, 68, PANEL, 0.05 )
	kids[#kids + 1] = fill( "HeaderRule", 0, 68, SettingsGui.W, 2, ACCENT, 1 )
	kids[#kids + 1] = text( "Title", "SERVER WORKS", 28, 18, 460, 34,
		"SM_HeaderLarge_Medium", LABEL, "Left" )
	kids[#kids + 1] = text( "Sub", "server settings  --  host only", 28, 46, 520, 20,
		"SM_TextTiny", DIM, "Left" )

	-- left hand navigation
	kids[#kids + 1] = fill( "NavBG", 0, 70, NAV_W, SettingsGui.H - 70, PANEL, 0.04 )
	local ny = 92
	for _, g in ipairs( SettingsGui.GROUPS ) do
		local on = ( g.key == group )
		if on then
			kids[#kids + 1] = fill( "NavSel" .. g.key, 0, ny - 6, NAV_W, 40, ACCENT, 0.18 )
			kids[#kids + 1] = fill( "NavBar" .. g.key, 0, ny - 6, 4, 40, ACCENT, 1 )
		end
		kids[#kids + 1] = button( "Nav" .. g.key, g.title, 14, ny, NAV_W - 28, 30,
			on and "UpgradeButton" or "SecondaryButton",
			{ action = "group", group = g.key }, "SM_TabSmall" )
		ny = ny + 44
	end
	if SettingsGui.HasOther() then
		kids[#kids + 1] = button( "Navother", "OTHER", 14, ny, NAV_W - 28, 30,
			( group == "other" ) and "UpgradeButton" or "SecondaryButton",
			{ action = "group", group = "other" }, "SM_TabSmall" )
	end

	-- presets, bottom of the nav column
	-- presets sit above the footer rule: 22 for the heading plus 30 a row
	local py = SettingsGui.H - 78 - ( 22 + 30 * #( Settings.PRESET_ORDER or {} ) )
	kids[#kids + 1] = text( "PresetHead", "PRESETS", 14, py, NAV_W - 28, 18,
		"SM_LabelMini", DIM, "Left" )
	py = py + 22
	for _, name in ipairs( Settings.PRESET_ORDER or {} ) do
		kids[#kids + 1] = button( "Preset" .. name, string.upper( name ),
			14, py, NAV_W - 28, 26, "SecondaryButton",
			{ action = "preset", preset = name }, "SM_ButtonSmall" )
		py = py + 30
	end

	-- the rows
	local rows = SettingsGui.RowsFor( group )
	local pages = math.max( 1, math.ceil( #rows / ROWS ) )
	page = math.max( 1, math.min( page, pages ) )
	local first = ( page - 1 ) * ROWS + 1

	local title = "OTHER"
	for _, g in ipairs( SettingsGui.GROUPS ) do
		if g.key == group then title = g.title end
	end
	kids[#kids + 1] = text( "GroupTitle", title, BODY_X, 80, 400, 22,
		"SM_SubHeader", ACCENT, "Left" )

	for i = 0, ROWS - 1 do
		local row = rows[first + i]
		if row == nil then break end
		local y = ROW_TOP + i * ROW_H
		local value = values[row.key]
		local isOn = ( row.kind == "bool" ) and value == true

		kids[#kids + 1] = fill( "RowBG" .. i, BODY_X, y, BODY_W, ROW_H - 6, PANEL,
			( i % 2 == 0 ) and 0.035 or 0.015 )
		kids[#kids + 1] = text( "Key" .. i, row.key, BODY_X + 16, y + 4, 240, 20,
			"SM_Label", LABEL, "Left" )
		kids[#kids + 1] = text( "Help" .. i, row.help or "", BODY_X + 16, y + 22, BODY_W - VALUE_W - 40, 18,
			"SM_TextTiny", DIM, "Left" )
		kids[#kids + 1] = button( "Val" .. i, shown( row, value ),
			BODY_X + BODY_W - VALUE_W - 12, y + 6, VALUE_W, ROW_H - 18,
			isOn and "UpgradeButton" or "SecondaryButton",
			{ action = "cycle", key = row.key } )
	end

	-- footer
	local fy = SettingsGui.H - 56
	kids[#kids + 1] = fill( "FooterRule", BODY_X, fy - 14, BODY_W, 1, PANEL, 0.12 )
	if pages > 1 then
		kids[#kids + 1] = button( "Prev", "< PREV", BODY_X, fy, 110, 32, "SecondaryButton",
			{ action = "page", page = page - 1 } )
		kids[#kids + 1] = button( "Next", "NEXT >", BODY_X + 120, fy, 110, 32, "SecondaryButton",
			{ action = "page", page = page + 1 } )
		kids[#kids + 1] = text( "Pager", string.format( "page %d / %d", page, pages ),
			BODY_X + 244, fy + 8, 160, 18, "SM_TextTiny", DIM, "Left" )
	end
	kids[#kids + 1] = text( "Hint", "click a value to change it  --  numbers cycle through presets, /set takes exact ones",
		BODY_X, fy + 8, BODY_W - 180, 18, "SM_TextTiny", DIM, "Left" )
	kids[#kids + 1] = button( "Close", "CLOSE", SettingsGui.W - 150, fy, 126, 32,
		"StyledButtonLarge", { action = "close" } )

	return root
end

-- Numbers cycle through sensible presets: a json GUI has no usable number field,
-- and /set still takes an exact value for anything these do not cover.
SettingsGui.STEPS = {
	maxjoints = { 0, 5, 10, 15, 20, 30, 50 },
	maxbots = { 0, 1, 2, 3, 5 },
	maxlights = { 0, 10, 25, 50, 100 },
	minbuildheight = { 0, -4, -8, 4 },
	alarmdrop = { 50, 100, 250, 500, 1000 },
	autosave = { 0, 2, 5, 10, 20, 30 },
}

function SettingsGui.NextValue( row, current )
	if row.kind == "bool" then return not current end
	local steps = SettingsGui.STEPS[row.key]
	if steps == nil then return current end
	for i, v in ipairs( steps ) do
		if v == current then return steps[( i % #steps ) + 1] end
	end
	return steps[1]
end

function SettingsGui.PageCount( group )
	return math.max( 1, math.ceil( #SettingsGui.RowsFor( group or "safety" ) / ROWS ) )
end
