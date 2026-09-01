-- TutorialGui -- one page at a time, and the pages depend on who is reading.
--
-- The content is all in Tutorial.lua; this is only the drawing. Same split as
-- Checklist / ChecklistGui, for the same reason: the words are worth checking
-- without a game, and the geometry is worth checking without the words.
--
-- Same widget vocabulary as every other panel here; see SettingsGui.lua for
-- where it came from.

TutorialGui = {}

TutorialGui.W = 1120
-- Header, up to fourteen lines of body, the pager and the footer. The layout
-- check computes whether that fits rather than trusting the eye -- and a canvas
-- check holds it under the 720 the engine actually gives us.
TutorialGui.H = 660

TutorialGui.LINES = 14           -- most a page may have; a check enforces it
TutorialGui.COLS = 78            -- wrap width, in characters

local PAD = 30
local TABS_Y = 84
local BODY_TOP = 178
local LINE_H = 30

local BG = "0.055 0.062 0.078 1"
local PANEL = "1 1 1 1"
local ACCENT = "1 0.54 0.18 1"
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
	b.onClick = "cl_onTutorialClick"
	b.onClickData = data
	return b
end


--[[ the pure half ]]

-- Word wrap. Copied in shape from ChecklistGui.Wrap rather than shared, because
-- these two panels have different line budgets and a shared helper would end up
-- taking both as arguments anyway.
--
-- A blank string is a deliberate blank LINE -- the pages use them for spacing --
-- so it survives instead of collapsing.
function TutorialGui.Wrap( str, cols )
	cols = cols or TutorialGui.COLS
	str = tostring( str or "" )
	if str == "" then return { "" } end
	local out, line = {}, ""
	for word in string.gmatch( str, "%S+" ) do
		if line == "" then
			line = word
		elseif #line + 1 + #word <= cols then
			line = line .. " " .. word
		else
			out[#out + 1] = line
			line = word
		end
		-- A single word longer than the whole line would loop forever widening.
		while #line > cols do
			out[#out + 1] = string.sub( line, 1, cols )
			line = string.sub( line, cols + 1 )
		end
	end
	if line ~= "" then out[#out + 1] = line end
	return out
end

-- Every drawn line of a page, wrapped. Indented lines keep their indent: the
-- pages use it for numbered steps and for a command somebody has to type.
function TutorialGui.Lines( page )
	local out = {}
	for _, raw in ipairs( ( page and page.lines ) or {} ) do
		local indent = string.match( tostring( raw ), "^%s*" ) or ""
		for i, wrapped in ipairs( TutorialGui.Wrap( raw ) ) do
			out[#out + 1] = ( i == 1 ) and wrapped or ( indent .. wrapped )
		end
	end
	return out
end


--[[ the panel ]]

-- state: {
--   host       whether the reader is the host
--   developer  whether developer mode is on
--   section    which of the three they are reading -- clamped to one they may
--   page       which page of that section
--   status     what the last press did
-- }
function TutorialGui.Build( state )
	state = state or {}
	local isHost = state.host == true
	local dev = state.developer == true
	-- Clamped here as well as on the server. The panel is built on the reader's
	-- own machine, so a section they may not read must not be drawable even if
	-- the state says otherwise.
	local section = Tutorial.SectionFor( state.section, isHost, dev )
	local page, index, total = Tutorial.Page( section, state.page )

	local root = widget{ Name = "BackPanel", Type = "Widget", Skin = "PanelEmpty",
		Anchor = "Center", InheritsPick = true, NeedKey = false, NeedMouse = false,
		x = 0, y = 0, width = TutorialGui.W, height = TutorialGui.H }
	root.onClose = "cl_onTutorialClose"
	local kids = root.Childs
	local W = TutorialGui.W - PAD * 2

	kids[#kids + 1] = fill( "BG", 0, 0, TutorialGui.W, TutorialGui.H, BG, 0.96 )
	kids[#kids + 1] = fill( "Band", 0, 0, TutorialGui.W, 64, PANEL, 0.05 )
	kids[#kids + 1] = fill( "Rule", 0, 64, TutorialGui.W, 2, ACCENT, 1 )
	kids[#kids + 1] = text( "Title", "HOW THIS WORKS", PAD, 16, 520, 30,
		"SM_Header", LABEL, "Left" )
	kids[#kids + 1] = text( "Sub", "pick a section, then read it a page at a time",
		PAD, 42, 520, 18, "SM_TextTiny", DIM, "Left" )
	kids[#kids + 1] = text( "Count",
		string.format( "page %d of %d", index, math.max( 1, total ) ),
		TutorialGui.W - PAD - 220, 42, 220, 18, "SM_TextTiny", DIM, "Right" )

	--[[ the section tabs ]]

	-- ONLY THE SECTIONS THIS PERSON MAY READ ARE DRAWN AT ALL. A greyed-out
	-- FOR DEVS tab would tell a guest there is something they are missing and
	-- give them nothing to do about it; a section they cannot open is better
	-- as a section they never learn exists.
	local tx = PAD
	for i, sec in ipairs( Tutorial.SectionsFor( isHost, dev ) ) do
		kids[#kids + 1] = button( "Sec" .. i, sec.label, tx, TABS_Y, 210, 32,
			( sec.id == section ) and "StyledButtonLarge" or "SecondaryButton",
			{ action = "section", section = sec.id } )
		tx = tx + 222
	end

	--[[ the page ]]

	if page == nil then
		kids[#kids + 1] = text( "Empty", "nothing to read here",
			PAD, BODY_TOP, W, 24, "SM_Text", DIM, "Left" )
	else
		kids[#kids + 1] = text( "PageTitle", tostring( page.title ),
			PAD, 132, W, 28, "SM_TextLarge", ACCENT, "Left" )
		local y = BODY_TOP
		for i, line in ipairs( TutorialGui.Lines( page ) ) do
			if line ~= "" then
				kids[#kids + 1] = text( "L" .. i, line, PAD, y, W, 22,
					"SM_Text", LABEL, "Left" )
			end
			y = y + LINE_H
		end
	end

	--[[ the pager ]]

	local py = TutorialGui.H - 106
	kids[#kids + 1] = button( "Prev", "BACK A PAGE", PAD, py, 200, 34,
		"SecondaryButton", { action = "page", page = index - 1 } )
	kids[#kids + 1] = button( "Next", "NEXT PAGE", PAD + 212, py, 200, 34,
		"StyledButtonLarge", { action = "page", page = index + 1 } )
	kids[#kids + 1] = text( "Status", tostring( state.status or "" ),
		PAD + 430, py + 8, W - 430, 18, "SM_TextTiny", ACCENT, "Left" )

	kids[#kids + 1] = button( "Back", "MENU", PAD, TutorialGui.H - 54, 140, 36,
		"StyledButtonLarge", { action = "back" } )
	kids[#kids + 1] = button( "Close", "CLOSE", TutorialGui.W - PAD - 140,
		TutorialGui.H - 54, 140, 36, "StyledButtonLarge", { action = "close" } )
	return root
end
