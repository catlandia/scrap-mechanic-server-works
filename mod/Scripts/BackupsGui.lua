-- BackupsGui -- save the world, and put it back.
--
-- REPORTED: "I want the MENU to be the menu." /snapshot, /snapshots and
-- /restore were three commands with no button between them, and restore in
-- particular is the one thing a host reaches for when an event has gone wrong
-- -- which is exactly the moment to not be remembering command syntax.
--
-- RESTORE DELETES THE WORLD BEFORE IT REBUILDS. That is not a side effect, it
-- is how it works: the inherited CreativeBaseWorld.sv_e_clear runs first, then
-- the snapshot is imported back. Anything not in the snapshot is gone -- which
-- includes a creation somebody happens to have on a lift, because a blueprint
-- being held is deliberately not captured.
--
-- So every restore goes through ConfirmGui's two doors, the same as CLEAR CITY,
-- and the row says how many creations are coming back so the number can be
-- sanity-checked before rather than after.
--
-- Same widget vocabulary as every other panel here; see SettingsGui.lua for
-- where it came from.

BackupsGui = {}

BackupsGui.W = 700
-- Header, the save strip, six rows, a pager, a status line and the footer. The
-- layout check computes whether that fits rather than trusting the eye.
BackupsGui.H = 600

-- How many saves fit on one page. /autosave rotates through a handful of slots
-- and a host may keep a dozen named ones, so the pager is not decoration.
BackupsGui.ROWS = 6

local PAD = 26
local ROW_H = 44
local ROW_TOP = 176

local BG = "0.055 0.062 0.078 1"
local PANEL = "1 1 1 1"
local ACCENT = "1 0.54 0.18 1"
local GREEN = "0.30 0.86 0.42 1"
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

local function button( name, caption, x, y, w, h, skin, data )
	local b = widget{ Name = name, Type = "Button", Skin = skin or "SecondaryButton",
		Caption = caption, FontName = "SM_ButtonLarge", TextAlign = "Center",
		x = x, y = y, width = w, height = h }
	b.onClick = "cl_onBackupsGuiClick"
	b.onClickData = data
	return b
end


--[[ the pure half ]]

-- Which slice of the list this page shows, and how many pages there are.
-- Clamped rather than validated: a page number left over from a longer list has
-- to land on the last page, not on an empty panel. Same shape as FocusGui.Page,
-- and deliberately so -- two pagers that behave differently is one more thing
-- to remember.
function BackupsGui.Page( list, page )
	local total = #list
	local pages = math.max( 1, math.ceil( total / BackupsGui.ROWS ) )
	page = math.max( 1, math.min( pages, math.floor( tonumber( page ) or 1 ) ) )
	local from = ( page - 1 ) * BackupsGui.ROWS + 1
	local slice = {}
	for i = from, math.min( total, from + BackupsGui.ROWS - 1 ) do
		slice[#slice + 1] = list[i]
	end
	return slice, page, pages
end


--[[ the panel ]]

-- state: {
--   saves     { { name, count } ... }, newest first
--   page      which page
--   busy      a capture or restore already running, as a progress line
--   autosave  minutes between automatic saves, 0 for off
--   status    what the last press did
-- }
function BackupsGui.Build( state )
	state = state or {}
	local saves = state.saves or {}
	local slice, page, pages = BackupsGui.Page( saves, state.page )

	local root = widget{ Name = "BackPanel", Type = "Widget", Skin = "PanelEmpty",
		Anchor = "Center", InheritsPick = true, NeedKey = false, NeedMouse = false,
		x = 0, y = 0, width = BackupsGui.W, height = BackupsGui.H }
	root.onClose = "cl_onBackupsGuiClose"
	local kids = root.Childs
	local W = BackupsGui.W - PAD * 2

	kids[#kids + 1] = fill( "BG", 0, 0, BackupsGui.W, BackupsGui.H, BG, 0.96 )
	kids[#kids + 1] = fill( "Band", 0, 0, BackupsGui.W, 64, PANEL, 0.05 )
	kids[#kids + 1] = fill( "Rule", 0, 64, BackupsGui.W, 2, ACCENT, 1 )
	kids[#kids + 1] = text( "Title", "BACKUPS", PAD, 16, 400, 30,
		"SM_Header", LABEL, "Left" )
	kids[#kids + 1] = text( "Sub",
		"a full world save: every build AND who owns which plot",
		PAD, 42, 500, 18, "SM_TextTiny", DIM, "Left" )

	--[[ save now, and whether anything is already running ]]

	kids[#kids + 1] = fill( "SaveStrip", PAD, 78, W, 52, PANEL, 0.06 )
	kids[#kids + 1] = button( "Save", "SAVE NOW", PAD + 12, 88, 180, 32,
		"StyledButtonLarge", { action = "snapshot" } )

	local auto = tonumber( state.autosave ) or 0
	local right = state.busy and tostring( state.busy )
		or ( auto > 0
			and string.format( "automatic save every %d minutes", auto )
			or "automatic saves are off -- turn them on in SERVER SETTINGS" )
	kids[#kids + 1] = text( "SaveNote", right, PAD + 206, 96, W - 218, 18,
		"SM_TextTiny", state.busy and ACCENT or DIM, "Left" )

	--[[ the saves ]]

	kids[#kids + 1] = text( "ListHead",
		( #saves > 0 )
			and string.format( "%d save(s) -- restore DELETES the world first, then rebuilds it", #saves )
			or "no saves yet. SAVE NOW writes one",
		PAD, 148, W, 18, "SM_LabelTiny", DIM, "Left" )

	local y = ROW_TOP
	for i, s in ipairs( slice ) do
		kids[#kids + 1] = fill( "Row" .. i, PAD, y, W, ROW_H - 6, PANEL, 0.05 )
		kids[#kids + 1] = text( "Name" .. i, tostring( s.name ), PAD + 14, y + 5,
			W - 200, 18, "SM_Text", LABEL, "Left" )
		kids[#kids + 1] = text( "Count" .. i,
			string.format( "%d creations", tonumber( s.count ) or 0 ),
			PAD + 14, y + 23, W - 200, 14, "SM_TextTiny", DIM, "Left" )
		kids[#kids + 1] = button( "R" .. i, "RESTORE", BackupsGui.W - PAD - 150,
			y + 4, 150, 30, "SecondaryButton",
			{ action = "restore", name = s.name } )
		y = y + ROW_H
	end

	--[[ the pager, BENEATH the rows and above the status line ]]

	if pages > 1 then
		local py = ROW_TOP + BackupsGui.ROWS * ROW_H + 6
		kids[#kids + 1] = button( "Prev", "PREV", PAD, py, 90, 26,
			"SecondaryButton", { action = "page", page = page - 1 } )
		kids[#kids + 1] = text( "Pages",
			string.format( "page %d of %d", page, pages ),
			PAD + 100, py + 4, 200, 18, "SM_TextTiny", DIM, "Left" )
		kids[#kids + 1] = button( "Next", "NEXT", PAD + 240, py, 90, 26,
			"SecondaryButton", { action = "page", page = page + 1 } )
	end

	kids[#kids + 1] = text( "Status", tostring( state.status or "" ),
		PAD, BackupsGui.H - 86, W, 18, "SM_TextTiny", ACCENT, "Left" )

	kids[#kids + 1] = button( "Back", "BACK", PAD, BackupsGui.H - 50, 124, 32,
		"StyledButtonLarge", { action = "back" } )
	kids[#kids + 1] = button( "Close", "CLOSE", BackupsGui.W - 148,
		BackupsGui.H - 50, 124, 32, "StyledButtonLarge", { action = "close" } )
	return root
end
