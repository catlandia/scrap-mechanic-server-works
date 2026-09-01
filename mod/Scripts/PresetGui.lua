-- PresetGui -- the four built-in presets, and the host's own saved ones.
--
-- ASKED FOR: "make settings being able to set as pressets with names."
--
-- The four built-ins were already four buttons down the side of the settings
-- panel. What was missing is the other direction: a host who has spent an
-- evening getting forty switches the way they want them had no way to keep
-- that, and the next event started from whatever the last one left behind.
--
-- TYPING IS UNAVOIDABLE HERE, AND THAT IS THE OPPOSITE OF THE BAN PANEL.
--
-- "nicks in scrap mechanic to ban needs to be writen exactly. since names can
-- be strange. this wont work." Right, and the rule that came out of it was
-- offer a list, not a field -- because a display name is a value the host has
-- to REPRODUCE, and some of them cannot be typed at all.
--
-- A preset name is the other kind of value: the host is inventing it, so
-- whatever they can type is by definition a name they can type again. A list
-- cannot offer a name that does not exist yet.
--
-- ENTER IS THE SAVE, and there is no SAVE button, for a reason that is worth
-- writing down: a Button's onClickData is fixed when the tree is built, so a
-- click handler cannot see what is currently in an EditBox. The only callback
-- that is handed the text is onTextEnter. A SAVE button beside the box could
-- therefore only ever save a stale name or nothing at all, which is a dead
-- button wearing a helpful label.
--
-- One EditBox in this tree, and its handler does not touch the GUI -- both
-- rules from the event clock, which crashed the game twice over typed input.
-- See Game.cl_onEventTimeTyped.

PresetGui = {}

PresetGui.W = 760
-- Header, the save strip, six rows a column, a status line and the footer. The
-- layout check computes whether that fits rather than trusting the eye.
PresetGui.H = 560

PresetGui.ROWS = 6
PresetGui.NAME_BOX = "PresetName"

local PAD = 26
local ROW_H = 44
local ROW_TOP = 210
local COL_W = 330

local BG = "0.055 0.062 0.078 1"
local PANEL = "1 1 1 1"
local ACCENT = "1 0.54 0.18 1"
local GREEN = "0.30 0.86 0.42 1"
local RED = "0.92 0.34 0.30 1"
local DIM = "0.62 0.65 0.72 1"
local LABEL = "0.90 0.92 0.96 1"

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
	b.onClick = "cl_onPresetGuiClick"
	b.onClickData = data
	return b
end


--[[ the pure half ]]

-- Which slice of the host's own presets this page shows.
--
-- Same shape as BackupsGui.Page and FocusGui.Page, deliberately: three pagers
-- that behave differently is two more things to remember. Clamped rather than
-- validated, so a page number left over from a longer list lands on the last
-- page rather than on an empty panel.
function PresetGui.Page( list, page )
	local total = #list
	local pages = math.max( 1, math.ceil( total / PresetGui.ROWS ) )
	page = math.max( 1, math.min( pages, math.floor( tonumber( page ) or 1 ) ) )
	local from = ( page - 1 ) * PresetGui.ROWS + 1
	local slice = {}
	for i = from, math.min( total, from + PresetGui.ROWS - 1 ) do
		slice[#slice + 1] = list[i]
	end
	return slice, page, pages
end


--[[ the panel ]]

-- state: {
--   builtin  { { key, label } ... }   the four that ship with the mod
--   mine     { { key, label } ... }   what this host has saved, sorted
--   page     which page of `mine`
--   status   what the last press did
--   back     which panel BACK returns to
-- }
function PresetGui.Build( state )
	state = state or {}
	local builtin = state.builtin or {}
	local mine = state.mine or {}
	local slice, page, pages = PresetGui.Page( mine, state.page )

	local root = widget{ Name = "PresetPanel", Type = "Widget", Skin = "PanelEmpty",
		Anchor = "Center", InheritsPick = true, NeedKey = false, NeedMouse = false,
		x = 0, y = 0, width = PresetGui.W, height = PresetGui.H }
	root.onClose = "cl_onPresetGuiClose"

	local kids = root.Childs
	kids[#kids + 1] = fill( "Bg", 0, 0, PresetGui.W, PresetGui.H, BG, 0.97 )
	kids[#kids + 1] = fill( "TopRule", 0, 0, PresetGui.W, 3, ACCENT, 1 )

	kids[#kids + 1] = text( "Title", "PRESETS", PAD, 18, 400, 28,
		"SM_Header", LABEL, "Left" )
	kids[#kids + 1] = text( "Sub",
		state.status or "a whole set of settings, applied in one press",
		PAD, 50, PresetGui.W - PAD * 2 - 40, 20, "SM_TextTiny",
		state.status and ACCENT or DIM, "Left" )

	--[[ save what is set right now ]]
	kids[#kids + 1] = fill( "SaveStrip", PAD, 84, PresetGui.W - PAD * 2, 52, PANEL, 0.06 )
	kids[#kids + 1] = text( "SaveLabel", "SAVE AS", PAD + 14, 100, 90, 16,
		"SM_LabelTiny", DIM, "Left" )

	-- Static = false is the flag that makes an EditBox editable at all; every
	-- other TextBox in this mod is Static = true. NeedKey or it never takes the
	-- keyboard. CaptionDisableReplacing stops a name containing #{...} being
	-- read as a localisation key. Shape from DigitalSign.gui's EnterTextBox,
	-- signature from DigitalSign.lua:157.
	local box = widget{ Name = PresetGui.NAME_BOX, Type = "EditBox",
		Skin = "EditBoxEmpty", Caption = "",
		CaptionDisableReplacing = true, FontName = "SM_Text",
		TextAlign = "Left", TextColour = ACCENT, Static = false,
		MultiLine = false, WordWrap = false, HeightFromText = false,
		MaxTextLength = 24,
		x = PAD + 110, y = 96, width = 260, height = 28 }
	box.onTextEnter = "cl_onPresetNameTyped"
	kids[#kids + 1] = box

	kids[#kids + 1] = text( "SaveHint",
		"type a name and press Enter. It keeps every setting exactly as it is now.",
		PAD + 384, 102, PresetGui.W - PAD * 2 - 384, 16, "SM_TextTiny", DIM, "Left" )

	--[[ the two columns ]]
	local rightX = PAD + COL_W + 40

	kids[#kids + 1] = text( "BuiltHead", "BUILT IN", PAD, 172, 300, 18,
		"SM_LabelTiny", DIM, "Left" )
	kids[#kids + 1] = text( "MineHead",
		string.format( "YOURS -- %d saved", #mine ), rightX, 172, 300, 18,
		"SM_LabelTiny", DIM, "Left" )

	for i, row in ipairs( builtin ) do
		local y = ROW_TOP + ( i - 1 ) * ROW_H
		kids[#kids + 1] = fill( "BRow" .. i, PAD, y, COL_W, ROW_H - 6, PANEL, 0.035 )
		kids[#kids + 1] = text( "BName" .. i, string.upper( tostring( row.key ) ),
			PAD + 14, y + 10, 140, 20, "SM_TextSmall", LABEL, "Left" )
		kids[#kids + 1] = button( "BApply" .. i, "APPLY",
			PAD + COL_W - 100, y + 5, 90, 28, "SecondaryButton",
			{ action = "apply", preset = row.key }, "SM_ButtonSmall" )
	end
	-- One line under the built-ins saying what they are for, because four bare
	-- words is not a description and the long labels do not fit on a row.
	kids[#kids + 1] = text( "BuiltHelp",
		"build runs an event. show and lockdown freeze it. sandbox unlocks everything.",
		PAD, ROW_TOP + 4 * ROW_H + 8, COL_W, 32, "SM_TextTiny", DIM, "Left" )

	if #mine == 0 then
		kids[#kids + 1] = text( "MineNone",
			"Nothing saved yet. Set the server up the way you want it, then type a "
			.. "name above and press Enter.",
			rightX, ROW_TOP + 6, COL_W, 60, "SM_TextTiny", DIM, "Left" )
	end
	for i, row in ipairs( slice ) do
		local y = ROW_TOP + ( i - 1 ) * ROW_H
		kids[#kids + 1] = fill( "MRow" .. i, rightX, y, COL_W, ROW_H - 6, PANEL, 0.035 )
		kids[#kids + 1] = text( "MName" .. i, tostring( row.label or row.key ),
			rightX + 14, y + 10, 140, 20, "SM_TextSmall", GREEN, "Left" )
		kids[#kids + 1] = button( "MApply" .. i, "APPLY",
			rightX + COL_W - 176, y + 5, 84, 28, "SecondaryButton",
			{ action = "apply", preset = row.key }, "SM_ButtonSmall" )
		kids[#kids + 1] = button( "MDrop" .. i, "DELETE",
			rightX + COL_W - 86, y + 5, 76, 28, "SecondaryButton",
			{ action = "delete", preset = row.key }, "SM_ButtonSmall" )
	end

	--[[ footer ]]
	local by = PresetGui.H - 56
	kids[#kids + 1] = fill( "BottomRule", 0, by - 16, PresetGui.W, 1, PANEL, 0.12 )

	if pages > 1 then
		kids[#kids + 1] = button( "Prev", "PREV", rightX, by, 90, 34,
			"SecondaryButton", { action = "page", page = page - 1 } )
		kids[#kids + 1] = text( "Pager", string.format( "%d of %d", page, pages ),
			rightX + 98, by + 8, 90, 20, "SM_TextTiny", DIM, "Left" )
		kids[#kids + 1] = button( "Next", "NEXT", rightX + 190, by, 90, 34,
			"SecondaryButton", { action = "page", page = page + 1 } )
	end

	kids[#kids + 1] = button( "Back", "BACK", PAD, by, 120, 34,
		"SecondaryButton", { action = "back" } )
	kids[#kids + 1] = button( "Close", "CLOSE", PresetGui.W - PAD - 130, by, 130, 34,
		"SecondaryButton", { action = "close" } )

	return root
end
