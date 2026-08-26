-- FocusGui -- pick the person everybody should be looking at.
--
-- Asked for as: "with the tool you can search for nicknames that are curently
-- on the server. and when selected it will highlight them."
--
-- Everyone online, one row each, a FOCUS button per row, and a search box that
-- narrows the list. The tool (FocusTool) is the fast path for somebody you can
-- see; this is the path for somebody you cannot -- across the city, inside a
-- build, or a name you only half remember.
--
-- Same widget vocabulary as every other panel here; see SettingsGui.lua for
-- where it came from.
--
--
-- ONE EDIT BOX, AND IT NEVER TOUCHES THE GUI
--
-- The event clock crashed the game TWICE over typed input, and both crashes are
-- written up at Game.cl_onEventTimeTyped. The surviving rules:
--
--   * ONE EditBox per panel. The second crash came from moving focus between
--     two of them, and the base game has exactly one editable box in one
--     editable panel (DigitalSign.gui), so two in a tree is territory the
--     engine is never asked to handle by its own content.
--   * the text handler may not render, close, or defer a render. Deferring by a
--     tick was tried and was not enough.
--
-- So SEARCHING IS A SERVER ROUND TRIP, not a local redraw: Enter sends the
-- query to the server, the server sends the whole panel back with the list
-- already filtered, and the panel is rebuilt from a network callback rather
-- than from inside the text callback. Slower by a tick and it cannot crash.
--
-- Filter() is pure and is therefore checked outside the game in
-- dev/test_logic.py, which is the only way any of this gets tested at all.

FocusGui = {}

FocusGui.W = 720
-- Tall enough for eight rows, the pager BENEATH them, and a footer beneath
-- that. The three were overlapping at 620 -- the status line shared pixels
-- with the page counter -- which is the kind of thing a fits-on-the-panel
-- check cannot see, because everything was inside the panel. It was the
-- geometry dump that showed it.
FocusGui.H = 660

-- How many names fit on one page. Twenty people at an event is the design
-- point; the pager exists for a full lobby and for /crowd, which can put 128
-- names in this list.
FocusGui.ROWS = 8

local PAD = 26
local ROW_H = 44
local ROW_TOP = 176

local BG = "0.055 0.062 0.078 1"
local PANEL = "1 1 1 1"
local ACCENT = "1 0.54 0.18 1"
local GREEN = "0.30 0.86 0.42 1"
local DIM = "0.62 0.65 0.72 1"
local LABEL = "0.90 0.92 0.96 1"

-- The one typed field on this panel. Named, because a text event carries no
-- onClickData and the widget NAME is the only thing that says which box it was
-- -- the same problem EventGui.FieldForBox solves.
FocusGui.SEARCH_BOX = "FocusSearch"


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
	b.onClick = "cl_onFocusGuiClick"
	b.onClickData = data
	return b
end


--[[ the pure half -- searching and paging ]]

local function lower( s )
	return string.lower( tostring( s or "" ) )
end

-- Substring, case insensitive, on the display name. Deliberately NOT a fuzzy
-- match: a host typing three letters mid-event wants the obvious answer, and a
-- clever matcher that puts somebody else first is worse than no matcher.
--
-- plain = true on string.find, because a name may legally contain "-", "(" or
-- "%" and those are pattern syntax. Without it, typing a bracket errors the
-- whole search.
function FocusGui.Filter( players, query )
	local out = {}
	local q = lower( query )
	-- gsub returns two values; the parens keep only the string, or the count
	-- would ride along into the comparison below.
	q = ( q:gsub( "^%s+", "" ):gsub( "%s+$", "" ) )
	for _, p in ipairs( players or {} ) do
		if q == "" or string.find( lower( p.name ), q, 1, true ) ~= nil then
			out[#out + 1] = p
		end
	end
	return out
end

-- Which slice of the filtered list this page shows, and how many pages there
-- are. Clamped rather than validated: a page number left over from a longer
-- list must land on the last page, not on an empty panel.
function FocusGui.Page( list, page )
	local total = #list
	local pages = math.max( 1, math.ceil( total / FocusGui.ROWS ) )
	page = math.max( 1, math.min( pages, math.floor( tonumber( page ) or 1 ) ) )
	local from = ( page - 1 ) * FocusGui.ROWS + 1
	local slice = {}
	for i = from, math.min( total, from + FocusGui.ROWS - 1 ) do
		slice[#slice + 1] = list[i]
	end
	return slice, page, pages
end


--[[ the panel ]]

-- state: {
--   players   { { id, name, perma, plot, bot } ... } everyone online
--   query     what is in the search box
--   page      which page of the filtered list
--   focus     { id, name } who is focused right now, or nil
--   bots      how many /crowd bots are standing, so a host testing with a
--             crowd is not left wondering why 128 names are missing
--   status    what the last press did
-- }
function FocusGui.Build( state )
	state = state or {}
	local players = state.players or {}
	local matched = FocusGui.Filter( players, state.query )
	local slice, page, pages = FocusGui.Page( matched, state.page )

	local root = widget{ Name = "BackPanel", Type = "Widget", Skin = "PanelEmpty",
		Anchor = "Center", InheritsPick = true, NeedKey = false, NeedMouse = false,
		x = 0, y = 0, width = FocusGui.W, height = FocusGui.H }
	root.onClose = "cl_onFocusGuiClose"
	local kids = root.Childs

	kids[#kids + 1] = fill( "BG", 0, 0, FocusGui.W, FocusGui.H, BG, 0.96 )
	kids[#kids + 1] = fill( "Band", 0, 0, FocusGui.W, 64, PANEL, 0.05 )
	kids[#kids + 1] = fill( "Rule", 0, 64, FocusGui.W, 2, ACCENT, 1 )
	kids[#kids + 1] = text( "Title", "FOCUS PLAYER", PAD, 16, 400, 30,
		"SM_Header", LABEL, "Left" )
	kids[#kids + 1] = text( "Sub", "everyone sees a marker over whoever is focused",
		PAD, 42, 460, 18, "SM_TextTiny", DIM, "Left" )

	--[[ who is focused now ]]

	local focusName = state.focus and state.focus.name or nil
	kids[#kids + 1] = fill( "FocusStrip", PAD, 78, FocusGui.W - PAD * 2, 40,
		PANEL, focusName and 0.10 or 0.04 )
	kids[#kids + 1] = text( "FocusLabel", "FOCUSED", PAD + 14, 84, 90, 16,
		"SM_LabelTiny", DIM, "Left" )
	kids[#kids + 1] = text( "FocusName", focusName or "nobody",
		PAD + 14, 100, 340, 18, "SM_TextSmall",
		focusName and GREEN or DIM, "Left" )
	if focusName then
		kids[#kids + 1] = button( "Clear", "CLEAR", FocusGui.W - PAD - 130, 84,
			130, 30, "StyledButtonLarge", { action = "clear" } )
	end

	--[[ the search box ]]

	kids[#kids + 1] = text( "SearchLabel", "SEARCH", PAD, 130, 80, 16,
		"SM_LabelTiny", DIM, "Left" )
	-- Static = false is the flag that makes an EditBox editable at all; every
	-- other TextBox in this mod is Static = true. NeedKey or it never takes the
	-- keyboard. CaptionDisableReplacing stops a name containing #{...} being
	-- read as a localisation key. Shape from DigitalSign.gui's EnterTextBox,
	-- signature from DigitalSign.lua:157.
	local box = widget{ Name = FocusGui.SEARCH_BOX, Type = "EditBox",
		Skin = "EditBoxEmpty", Caption = tostring( state.query or "" ),
		CaptionDisableReplacing = true, FontName = "SM_Text", TextAlign = "Left",
		TextColour = ACCENT, Static = false, MultiLine = false, WordWrap = false,
		HeightFromText = false, MaxTextLength = 32,
		x = PAD + 84, y = 126, width = 300, height = 26 }
	box.onTextEnter = "cl_onFocusSearchTyped"
	kids[#kids + 1] = box
	kids[#kids + 1] = text( "SearchHint", "type part of a name, then Enter",
		PAD + 394, 130, 260, 16, "SM_TextTiny", DIM, "Left" )

	kids[#kids + 1] = fill( "ListRule", PAD, 164, FocusGui.W - PAD * 2, 1, LABEL, 0.12 )

	--[[ the names ]]

	if #players == 0 then
		kids[#kids + 1] = text( "Empty", "nobody is online",
			PAD, ROW_TOP + 8, FocusGui.W - PAD * 2, 20, "SM_Text", DIM, "Left" )
	elseif #slice == 0 then
		kids[#kids + 1] = text( "Empty",
			"no name here matches " .. string.format( "%q", tostring( state.query or "" ) ),
			PAD, ROW_TOP + 8, FocusGui.W - PAD * 2, 20, "SM_Text", DIM, "Left" )
	end

	for i, p in ipairs( slice ) do
		local y = ROW_TOP + ( i - 1 ) * ROW_H
		local isFocus = state.focus ~= nil and state.focus.id == p.id
		kids[#kids + 1] = fill( "Row" .. i, PAD, y, FocusGui.W - PAD * 2, ROW_H - 6,
			PANEL, isFocus and 0.12 or 0.05 )
		kids[#kids + 1] = text( "Name" .. i, tostring( p.name ),
			PAD + 14, y + 4, 300, 20, "SM_Text", isFocus and GREEN or LABEL, "Left" )
		-- Under the name: what the host needs to tell two similar names apart --
		-- the session id they would type at /kick, their plot, and whether this
		-- is a /crowd bot rather than a person.
		local detail = "id " .. tostring( p.id )
		if p.perma then detail = detail .. "   " .. tostring( p.perma ) end
		if p.plot then detail = detail .. "   plot " .. tostring( p.plot ) end
		if p.bot then detail = detail .. "   BOT" end
		kids[#kids + 1] = text( "Detail" .. i, detail,
			PAD + 14, y + 24, 380, 14, "SM_TextTiny", DIM, "Left" )
		kids[#kids + 1] = button( "Pick" .. i, isFocus and "FOCUSED" or "FOCUS",
			FocusGui.W - PAD - 144, y + 3, 144, ROW_H - 12,
			isFocus and "StyledButtonLarge" or "SecondaryButton",
			{ action = "focus", id = p.id } )
	end

	--[[ pager, status, and the two buttons that are allowed to close ]]

	local pagerY = ROW_TOP + FocusGui.ROWS * ROW_H + 6
	if pages > 1 then
		kids[#kids + 1] = button( "Prev", "<", PAD, pagerY, 48, 28,
			"SecondaryButton", { action = "page", page = page - 1 } )
		kids[#kids + 1] = text( "Pager",
			string.format( "%d / %d   (%d of %d shown)", page, pages, #slice, #matched ),
			PAD + 58, pagerY + 5, 230, 18, "SM_TextTiny", DIM, "Left" )
		kids[#kids + 1] = button( "Next", ">", PAD + 300, pagerY, 48, 28,
			"SecondaryButton", { action = "page", page = page + 1 } )
	else
		kids[#kids + 1] = text( "Pager",
			string.format( "%d online", #players ),
			PAD, pagerY + 5, 300, 18, "SM_TextTiny", DIM, "Left" )
	end

	-- Crowd bots are units, not players, so they are not in this list and
	-- cannot be. Saying so is cheaper than the host concluding the panel is
	-- broken -- which is exactly what happened to the roster count before it
	-- started naming the bot share separately.
	local bots = tonumber( state.bots ) or 0
	if bots > 0 then
		kids[#kids + 1] = text( "Bots",
			string.format( "+ %d crowd bot%s -- units, not players, so they "
				.. "cannot be focused", bots, bots == 1 and "" or "s" ),
			FocusGui.W - PAD - 300, pagerY + 5, 300, 18,
			"SM_TextTiny", DIM, "Right" )
	end

	-- Every panel here carries a status line, because only CLOSE and BACK close
	-- a panel and a click that runs an action has no other feedback at all. See
	-- the note in CLAUDE.md: a panel that closes on every click cannot be told
	-- from a broken one.
	kids[#kids + 1] = fill( "FootRule", PAD, FocusGui.H - 82, FocusGui.W - PAD * 2, 1,
		LABEL, 0.12 )
	kids[#kids + 1] = text( "Status", tostring( state.status or "" ),
		PAD, FocusGui.H - 74, FocusGui.W - PAD * 2, 18,
		"SM_TextTiny", ACCENT, "Left" )

	kids[#kids + 1] = button( "Back", "BACK", PAD, FocusGui.H - 46, 124, 32,
		"SecondaryButton", { action = "back" } )
	kids[#kids + 1] = button( "Close", "CLOSE", FocusGui.W - PAD - 124, FocusGui.H - 46,
		124, 32, "StyledButtonLarge", { action = "close" } )

	return root
end
