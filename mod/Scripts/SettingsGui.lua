-- SettingsGui -- the settings panel.
--
-- Built from Settings.SCHEMA at runtime rather than from a .gui file on disk.
-- sm.jsonGui.createGui():render() takes a plain Lua table, so the widget tree can
-- be generated, which means adding a setting is still one row in the schema and
-- the panel picks it up with no layout work. A hand-authored .gui would have to
-- be edited in parallel every time and would drift.
--
-- Widget vocabulary copied from Data/Gui/JsonGuis/PopUp_YN.gui, which is the only
-- documentation that exists for this format. onClickData is the important part
-- (Survival/Scripts/game/interactables/HideoutTrader.lua:318): it carries
-- arbitrary data into the click handler, so one callback serves every row instead
-- of needing a named function per button.

SettingsGui = {}

SettingsGui.ROWS = 11
SettingsGui.W = 660
SettingsGui.H = 560

local ROW_H = 34
local ROW_TOP = 92
local LABEL_X = 28
local LABEL_W = 400
local VALUE_X = 452
local VALUE_W = 176

local function widget( t )
	t.Childs = t.Childs or {}
	if t.NeedKey == nil then t.NeedKey = true end
	if t.NeedMouse == nil then t.NeedMouse = true end
	return t
end

local function label( name, caption, x, y, w, font, align, colour )
	return widget{
		Name = name, Caption = caption, Type = "EditBox", Skin = "EditBoxEmpty",
		Static = true, FontName = font or "SM_Text", TextAlign = align or "Left",
		TextColour = colour, x = x, y = y, width = w, height = ROW_H - 6,
	}
end

local function button( name, caption, x, y, w, skin, data )
	local b = widget{
		Name = name, Caption = caption, Type = "Button", Skin = skin or "SecondaryButton",
		FontName = "SM_Button", TextAlign = "Center",
		x = x, y = y, width = w, height = ROW_H - 6,
	}
	b.onClick = "cl_onSettingsGuiClick"
	b.onClickData = data
	return b
end

-- Settings a host should not be poking from a panel: they are bookkeeping, or
-- they are the sort of thing that wants an exact number typed with /set.
local HIDDEN = { protection = true }

function SettingsGui.VisibleRows()
	local rows = {}
	for _, row in ipairs( Settings.SCHEMA ) do
		if not row.hidden and not HIDDEN[row.key] then
			rows[#rows + 1] = row
		end
	end
	return rows
end

function SettingsGui.PageCount()
	local n = #SettingsGui.VisibleRows()
	return math.max( 1, math.ceil( n / SettingsGui.ROWS ) )
end

local function shown( row, value )
	if row.kind == "bool" then
		return value and "ON" or "OFF"
	end
	return tostring( value )
end

-- values is a plain { key = value } table sent from the server, because the
-- client has no business reading the server's Settings module directly.
function SettingsGui.Build( values, page )
	local rows = SettingsGui.VisibleRows()
	local pages = SettingsGui.PageCount()
	page = math.max( 1, math.min( page or 1, pages ) )

	local root = widget{
		Name = "BackPanel", Type = "Widget", Skin = "BackgroundPromptNarrow",
		Anchor = "Center", InheritsPick = true, NeedKey = false, NeedMouse = false,
		x = 0, y = 0, width = SettingsGui.W, height = SettingsGui.H,
	}
	root.onClose = "cl_onSettingsGuiClose"

	local kids = root.Childs
	kids[#kids + 1] = label( "Title", "SERVER WORKS  --  SETTINGS", 0, 26,
		SettingsGui.W, "SM_HeaderLarge_Medium", "Center" )
	kids[#kids + 1] = label( "Sub",
		string.format( "page %d of %d   --   click a value to change it", page, pages ),
		0, 60, SettingsGui.W, "SM_Text", "Center", "0.564706 0.564706 0.564706 1" )

	local first = ( page - 1 ) * SettingsGui.ROWS + 1
	for i = 0, SettingsGui.ROWS - 1 do
		local row = rows[first + i]
		if row == nil then break end
		local y = ROW_TOP + i * ROW_H
		local value = values[row.key]

		kids[#kids + 1] = label( "L" .. i, row.help or row.key, LABEL_X, y, LABEL_W,
			"SM_Text", "Left", "0.694118 0.694118 0.694118 1" )
		kids[#kids + 1] = button( "V" .. i,
			string.format( "%s: %s", row.key, shown( row, value ) ),
			VALUE_X, y, VALUE_W,
			( row.kind == "bool" and value ) and "PrimaryButton" or "SecondaryButton",
			{ action = "cycle", key = row.key } )
	end

	local footY = SettingsGui.H - 66
	kids[#kids + 1] = button( "Prev", "< PREV", LABEL_X, footY, 120, "SecondaryButton",
		{ action = "page", page = page - 1 } )
	kids[#kids + 1] = button( "Next", "NEXT >", LABEL_X + 132, footY, 120, "SecondaryButton",
		{ action = "page", page = page + 1 } )
	kids[#kids + 1] = button( "Close", "CLOSE", VALUE_X, footY, VALUE_W, "PrimaryButton",
		{ action = "close" } )

	return root
end

-- Numbers cycle through sensible presets rather than offering free entry: a
-- json GUI has no usable number field, and /set still takes an exact value for
-- anything these steps do not cover.
SettingsGui.STEPS = {
	maxjoints = { 0, 5, 10, 15, 20, 30, 50 },
	maxbots = { 0, 1, 2, 3, 5 },
	maxlights = { 0, 10, 25, 50, 100 },
	minbuildheight = { 0, -4, -8, 4 },
	alarmdrop = { 50, 100, 250, 500, 1000 },
	autosave = { 0, 2, 5, 10, 20, 30 },
}

function SettingsGui.NextValue( row, current )
	if row.kind == "bool" then
		return not current
	end
	local steps = SettingsGui.STEPS[row.key]
	if steps == nil then
		return current
	end
	for i, v in ipairs( steps ) do
		if v == current then
			return steps[( i % #steps ) + 1]
		end
	end
	return steps[1]
end
