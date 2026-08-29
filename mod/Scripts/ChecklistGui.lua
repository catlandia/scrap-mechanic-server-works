-- ChecklistGui -- the dev checklist on screen.
--
-- Two views out of one Build(), because they share a panel object and switching
-- between them must not close anything: a list of items with the two answers
-- that get given most often on every row, and a detail view with the steps, the
-- pass condition, the log line to look for, a note box and the rest of the
-- answers.
--
-- The point of the row buttons is that the common case never opens anything.
-- You do the thing, you look at the row, you press PASS. Opening an item is for
-- when you want to read what it actually asks for, write a note, or run its
-- command.
--
--
-- THE RULES THIS PANEL OBEYS, ALL LEARNED EXPENSIVELY
--
--   * only CLOSE and BACK close it. Every other button runs, the server sends
--     the whole state back, and it re-renders in place with a status line. A
--     panel that closes on every click cannot be told from a broken one.
--   * nothing here closes or renders from inside its own callback. Game.lua
--     queues both -- see cl_closeLater and cl_renderLater.
--   * ONE EditBox, and its handler never touches the GUI. Two typed fields in
--     one tree crashed the game; a redraw from inside a text callback crashed
--     it again. The note is a server round trip like the focus search.
--   * tier 1 fonts only. SM_Label and SM_LabelMini ship a partial glyph atlas
--     and would draw half of these captions as hollow boxes.
--
-- Everything laid out here is checked by dev/test_logic.py: that it fits, that
-- no two clickable things overlap, and that every caption can be drawn by the
-- font it names.

ChecklistGui = {}

ChecklistGui.W = 1180
-- The canvas is about 1720x720 on this owner's monitor -- half the window, not
-- the window. 688 leaves a margin at that size; anything past ~690 hangs off
-- the bottom where the buttons cannot be clicked.
ChecklistGui.H = 688

ChecklistGui.ROWS = 8

local PAD = 24
local NAV_X = 24
local NAV_W = 210
local COL_X = 258
local COL_W = 898
local ROW_TOP = 120
local ROW_H = 56

local BG = "0.055 0.062 0.078 1"
local PANEL = "1 1 1 1"
local ACCENT = "1 0.54 0.18 1"
local GREEN = "0.30 0.86 0.42 1"
local RED = "0.92 0.34 0.34 1"
local AMBER = "0.98 0.78 0.28 1"
local DIM = "0.62 0.65 0.72 1"
local LABEL = "0.90 0.92 0.96 1"

-- The one typed field. Named, because a text event carries no onClickData and
-- the widget name is the only thing that says which box was typed into.
ChecklistGui.NOTE_BOX = "ChecklistNote"

local STATE_COLOUR = {
	pass = GREEN, fail = RED, blocked = AMBER, skip = DIM, untested = DIM,
}
local function stateLabel( id )
	for _, st in ipairs( Checklist.STATES ) do
		if st.id == id then return st.label end
	end
	return "-"
end

local function stateButton( id )
	for _, st in ipairs( Checklist.STATES ) do
		if st.id == id then return st.button end
	end
	return "?"
end


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
		Caption = caption, FontName = font or "SM_ButtonSmall", TextAlign = "Center",
		x = x, y = y, width = w, height = h }
	b.onClick = "cl_onChecklistClick"
	b.onClickData = data
	return b
end


--[[ the pure half -- wrapping ]]

-- A TextBox does not wrap for us in any way this panel can rely on, so long
-- text is broken into lines here and each line is its own widget. The width is
-- in CHARACTERS rather than pixels because the fonts are proportional and there
-- is no metrics binding in Lua at all -- so the counts below are deliberately
-- conservative, and the geometry check measures the widget boxes rather than
-- the glyphs inside them.
--
-- Pure, and therefore checked outside the game.
function ChecklistGui.Wrap( str, cols, maxLines )
	cols = cols or 100
	local out = {}
	local line = ""
	for word in string.gmatch( tostring( str or "" ), "%S+" ) do
		if line == "" then
			line = word
		elseif #line + 1 + #word <= cols then
			line = line .. " " .. word
		else
			out[#out + 1] = line
			line = word
		end
		-- A single word longer than the whole line would otherwise loop forever
		-- widening; break it rather than refuse to draw it.
		while #line > cols do
			out[#out + 1] = string.sub( line, 1, cols )
			line = string.sub( line, cols + 1 )
		end
	end
	if line ~= "" then out[#out + 1] = line end

	if maxLines ~= nil and #out > maxLines then
		local cut = {}
		for i = 1, maxLines do cut[i] = out[i] end
		-- Three ASCII dots. A Unicode ellipsis is one codepoint the game has
		-- probably never drawn, and it comes out as a hollow box.
		cut[maxLines] = string.sub( cut[maxLines], 1, math.max( 1, cols - 4 ) ) .. " ..."
		return cut
	end
	return out
end


--[[ shared chrome ]]

local function header( kids, W, title, sub, counts )
	kids[#kids + 1] = fill( "BG", 0, 0, W, ChecklistGui.H, BG, 0.96 )
	kids[#kids + 1] = fill( "Band", 0, 0, W, 64, PANEL, 0.05 )
	kids[#kids + 1] = fill( "Rule", 0, 64, W, 2, ACCENT, 1 )
	kids[#kids + 1] = text( "Title", title, PAD, 14, 460, 30, "SM_Header", LABEL, "Left" )
	kids[#kids + 1] = text( "Sub", sub, PAD, 42, 620, 18, "SM_TextTiny", DIM, "Left" )

	if counts == nil then return end

	-- The progress bar. Three fills: the whole width dim, then pass in green
	-- and fail in red side by side. It is the one thing on the panel that says
	-- "how much of this session is left" without being read.
	local barW, barX, barY = 320, W - PAD - 320, 26
	kids[#kids + 1] = fill( "BarBg", barX, barY, barW, 14, PANEL, 0.10 )
	local total = math.max( 1, counts.total )
	local passW = math.floor( barW * counts.pass / total )
	local failW = math.floor( barW * counts.fail / total )
	local otherW = math.floor( barW * ( counts.blocked + counts.skip ) / total )
	if passW > 0 then
		kids[#kids + 1] = fill( "BarPass", barX, barY, passW, 14, GREEN, 0.85 )
	end
	if failW > 0 then
		kids[#kids + 1] = fill( "BarFail", barX + passW, barY, failW, 14, RED, 0.85 )
	end
	if otherW > 0 then
		kids[#kids + 1] = fill( "BarOther", barX + passW + failW, barY, otherW, 14,
			AMBER, 0.55 )
	end
	kids[#kids + 1] = text( "BarText",
		string.format( "%d of %d answered", counts.done, counts.total ),
		barX, barY + 18, barW, 16, "SM_TextTiny", DIM, "Right" )
end

local function footer( kids, W, state, buttons )
	kids[#kids + 1] = fill( "FootRule", PAD, 612, W - PAD * 2, 1, LABEL, 0.12 )
	kids[#kids + 1] = text( "Status", tostring( state.status or "" ),
		PAD, 618, W - PAD * 2, 18, "SM_TextTiny", ACCENT, "Left" )
	for _, b in ipairs( buttons ) do
		kids[#kids + 1] = b
	end
end


--[[ the list ]]

local function navColumn( kids, state, results )
	local y = 92
	local entries = { { id = "all", label = "EVERYTHING" } }
	for _, g in ipairs( Checklist.GROUPS ) do
		entries[#entries + 1] = g
	end
	for i, g in ipairs( entries ) do
		local c = Checklist.Counts( results, g.id )
		local on = ( state.group or "all" ) == g.id
		kids[#kids + 1] = button( "Nav" .. i,
			string.format( "%s  %d/%d", g.label, c.done, c.total ),
			NAV_X, y, NAV_W, 34,
			on and "StyledButtonLarge" or "SecondaryButton",
			{ action = "group", group = g.id } )
		y = y + 40
	end
end

function ChecklistGui.BuildList( state )
	state = state or {}
	local results = state.results or {}
	local group = state.group or "all"
	local items = Checklist.ItemsIn( group )
	local slice, page, pages = Checklist.Page( items, state.page, ChecklistGui.ROWS )
	local all = Checklist.Counts( results )

	local root = widget{ Name = "BackPanel", Type = "Widget", Skin = "PanelEmpty",
		Anchor = "Center", InheritsPick = true, NeedKey = false, NeedMouse = false,
		x = 0, y = 0, width = ChecklistGui.W, height = ChecklistGui.H }
	root.onClose = "cl_onChecklistClose"
	local kids = root.Childs

	header( kids, ChecklistGui.W, "TESTING CHECKLIST",
		string.format( "%d worked   %d did not   %d could not try   %d skipped"
			.. "   -- %d still to do", all.pass, all.fail, all.blocked,
			all.skip, all.untested ),
		all )

	navColumn( kids, state, results )

	local blurb = "everything, in the order to run it in"
	for _, g in ipairs( Checklist.GROUPS ) do
		if g.id == group then blurb = g.blurb end
	end
	kids[#kids + 1] = text( "Blurb", blurb, COL_X, 92, COL_W, 18,
		"SM_TextTiny", DIM, "Left" )

	if #slice == 0 then
		kids[#kids + 1] = text( "Empty", "nothing in this group",
			COL_X, ROW_TOP + 8, COL_W, 20, "SM_Text", DIM, "Left" )
	end

	for i, item in ipairs( slice ) do
		local y = ROW_TOP + ( i - 1 ) * ROW_H
		local st = Checklist.StateOf( results, item.id )
		local colour = STATE_COLOUR[st] or DIM

		kids[#kids + 1] = fill( "Row" .. i, COL_X, y, COL_W, ROW_H - 6,
			PANEL, st == "untested" and 0.05 or 0.09 )
		-- The state chip. A block of colour reads faster than a word, and the
		-- word is in it anyway.
		kids[#kids + 1] = fill( "Chip" .. i, COL_X + 8, y + 8, 84, 22, colour,
			st == "untested" and 0.15 or 0.85 )
		kids[#kids + 1] = text( "ChipText" .. i, stateLabel( st ),
			COL_X + 8, y + 11, 84, 16, "SM_TextTiny",
			st == "untested" and DIM or BG, "Center" )

		kids[#kids + 1] = text( "Name" .. i, tostring( item.title ),
			COL_X + 100, y + 4, 482, 20, "SM_Text", LABEL, "Left" )
		local hint = Checklist.Hint( item )
		if item.needs == "guest" then hint = "NEEDS SOMEBODY ELSE -- " .. hint end
		kids[#kids + 1] = text( "Hint" .. i,
			( ChecklistGui.Wrap( hint, 78, 1 ) )[1] or "",
			COL_X + 100, y + 26, 482, 16, "SM_TextTiny", DIM, "Left" )

		-- A recorded answer from an older build is still an answer, and saying
		-- which build it came from is the difference between a ledger and a
		-- guess. Only shown when it is not this build.
		local r = Checklist.ResultOf( results, item.id )
		if r ~= nil and r.build ~= nil and r.build ~= ( state.build or Checklist.BUILD ) then
			kids[#kids + 1] = text( "Old" .. i, "V" .. tostring( r.build ),
				COL_X + 8, y + 32, 84, 14, "SM_TextTiny", DIM, "Center" )
		end

		local right = COL_X + COL_W
		kids[#kids + 1] = button( "Fail" .. i, "NOPE", right - 96, y + 8, 96, 34,
			"SecondaryButton", { action = "mark", id = item.id, state = "fail" } )
		kids[#kids + 1] = button( "Pass" .. i, "WORKED", right - 200, y + 8, 96, 34,
			"StyledButtonLarge", { action = "mark", id = item.id, state = "pass" } )
		-- OPEN is where the full instructions are. The two buttons beside it are
		-- for when you already know what the item is and just want to answer it.
		kids[#kids + 1] = button( "Open" .. i, "READ IT", right - 304, y + 8, 96, 34,
			"SecondaryButton", { action = "open", id = item.id } )
	end

	--[[ pager ]]

	if pages > 1 then
		kids[#kids + 1] = button( "Prev", "<", COL_X, 576, 48, 28,
			"SecondaryButton", { action = "page", page = page - 1 } )
		kids[#kids + 1] = text( "Pager",
			string.format( "page %d of %d   -   %d items", page, pages, #items ),
			COL_X + 58, 581, 240, 18, "SM_TextTiny", DIM, "Left" )
		kids[#kids + 1] = button( "Next", ">", COL_X + 306, 576, 48, 28,
			"SecondaryButton", { action = "page", page = page + 1 } )
	else
		kids[#kids + 1] = text( "Pager", string.format( "%d items", #items ),
			COL_X, 581, 300, 18, "SM_TextTiny", DIM, "Left" )
	end

	-- The very short form: this line shares a row with the pager. READ IT on any
	-- row opens the full version, which spells all four out.
	kids[#kids + 1] = text( "Legend",
		"WORKED = yes    NOPE = no    STUCK = could not try    SKIP = not now",
		COL_X + 380, 581, COL_W - 380, 16, "SM_TextTiny", DIM, "Right" )

	local right = COL_X + COL_W
	footer( kids, ChecklistGui.W, state, {
		button( "Back", "BACK", PAD, 642, 124, 32, "SecondaryButton",
			{ action = "back" } ),
		button( "Log", "SHOW SUMMARY", PAD + 136, 642, 176, 32, "SecondaryButton",
			{ action = "logdump" } ),
		button( "NextTodo", "NEXT THING TO TEST", right - 396, 642, 220, 32,
			"StyledButtonLarge", { action = "next" } ),
		button( "Close", "CLOSE", right - 124, 642, 124, 32, "StyledButtonLarge",
			{ action = "close" } ),
	} )

	return root
end


--[[ one item ]]

function ChecklistGui.BuildItem( state )
	state = state or {}
	local results = state.results or {}
	local item = Checklist.Find( state.item )
	if item == nil then return ChecklistGui.BuildList( state ) end

	local st = Checklist.StateOf( results, item.id )
	local r = Checklist.ResultOf( results, item.id )

	local root = widget{ Name = "BackPanel", Type = "Widget", Skin = "PanelEmpty",
		Anchor = "Center", InheritsPick = true, NeedKey = false, NeedMouse = false,
		x = 0, y = 0, width = ChecklistGui.W, height = ChecklistGui.H }
	root.onClose = "cl_onChecklistClose"
	local kids = root.Childs

	header( kids, ChecklistGui.W, "ONE THING TO TEST",
		string.format( "%s%s", Checklist.GroupLabel( item.group ),
			item.needs == "guest" and "   --   you need somebody else in the "
			.. "world for this one" or "" ),
		nil )

	local y = 84
	kids[#kids + 1] = text( "ItemTitle", tostring( item.title ),
		PAD, y, ChecklistGui.W - PAD * 2, 28, "SM_TextLarge", LABEL, "Left" )
	y = y + 40

	--[[ what to do ]]

	kids[#kids + 1] = text( "StepsLabel", "DO THIS", PAD, y, 200, 16,
		"SM_TextTiny", ACCENT, "Left" )
	y = y + 22
	local steps = item.steps or {}
	for i, step in ipairs( steps ) do
		kids[#kids + 1] = text( "Step" .. i,
			string.format( "%d.  %s", i, tostring( step ) ),
			PAD + 12, y, ChecklistGui.W - PAD * 2 - 12, 20, "SM_Text", LABEL, "Left" )
		y = y + 22
	end
	if #steps == 0 then
		kids[#kids + 1] = text( "Step0", "-- look at it", PAD + 12, y,
			400, 20, "SM_Text", DIM, "Left" )
		y = y + 22
	end
	y = y + 10

	--[[ what counts as a pass ]]

	kids[#kids + 1] = text( "PassLabel", "IT WORKED IF", PAD, y, 240, 16,
		"SM_TextTiny", ACCENT, "Left" )
	y = y + 22
	for i, line in ipairs( ChecklistGui.Wrap( item.pass, 120, 5 ) ) do
		kids[#kids + 1] = text( "Pass" .. i, line, PAD + 12, y,
			ChecklistGui.W - PAD * 2 - 12, 18, "SM_TextSmall", LABEL, "Left" )
		y = y + 20
	end
	y = y + 8

	-- NO LOG LINE ON THE PANEL. Items carry one -- it is what
	-- dev/checklist_report.py prints beside a failure so the log can be
	-- searched from outside -- but naming a log file here would invite the very
	-- thing this list was rewritten to stop: "I dont want to go in logs to test
	-- something." Anything whose only answer IS in a log is who = "log" and is
	-- not on this panel at all.

	--[[ the note ]]

	kids[#kids + 1] = text( "NoteLabel", "NOTE", PAD, y, 100, 16,
		"SM_TextTiny", ACCENT, "Left" )
	kids[#kids + 1] = text( "NoteHint",
		"anything odd you noticed. Type it, press Enter, and I will read it",
		PAD + 620, y, 440, 16, "SM_TextTiny", DIM, "Left" )
	y = y + 20
	-- Static = false is the flag that makes an EditBox editable; every other
	-- TextBox in this mod is Static = true. Shape from DigitalSign.gui's
	-- EnterTextBox, which is the only editable box in the whole base game.
	local box = widget{ Name = ChecklistGui.NOTE_BOX, Type = "EditBox",
		Skin = "EditBoxEmpty",
		Caption = tostring( ( r and r.note ) or "" ),
		CaptionDisableReplacing = true, FontName = "SM_Text", TextAlign = "Left",
		TextColour = ACCENT, Static = false, MultiLine = false, WordWrap = false,
		HeightFromText = false, MaxTextLength = 90,
		x = PAD, y = y, width = 1040, height = 26 }
	box.onTextEnter = "cl_onChecklistNoteTyped"
	kids[#kids + 1] = box
	y = y + 36

	--[[ what is recorded now ]]

	local recorded = "you have not answered this one yet"
	if st ~= "untested" then
		recorded = string.format( "you said: %s", stateLabel( st ) )
		if r and r.build and r.build ~= ( state.build or Checklist.BUILD ) then
			recorded = recorded .. string.format( "   -- on an older build, V%d",
				r.build )
		end
	end
	kids[#kids + 1] = fill( "NowStrip", PAD, y, ChecklistGui.W - PAD * 2, 30,
		STATE_COLOUR[st] or DIM, st == "untested" and 0.08 or 0.20 )
	kids[#kids + 1] = text( "Now", recorded, PAD + 12, y + 6,
		600, 18, "SM_TextSmall", STATE_COLOUR[st] or DIM, "Left" )
	if item.run ~= nil then
		local words = ""
		for _, w in ipairs( item.run ) do
			words = ( words == "" ) and tostring( w ) or ( words .. " " .. tostring( w ) )
		end
		kids[#kids + 1] = text( "RunText", "RUN IT types this for you:  " .. words,
			PAD + 620, y + 6, 488, 18, "SM_TextSmall", DIM, "Left" )
	end

	--[[ the answers ]]

	local by = 560
	local bw, gap = 132, 8
	local x = PAD
	kids[#kids + 1] = button( "MarkPass", stateButton( "pass" ), x, by, bw, 34,
		"StyledButtonLarge", { action = "mark", id = item.id, state = "pass" } )
	x = x + bw + gap
	kids[#kids + 1] = button( "MarkFail", stateButton( "fail" ), x, by, bw, 34,
		"SecondaryButton", { action = "mark", id = item.id, state = "fail" } )
	x = x + bw + gap
	kids[#kids + 1] = button( "MarkBlocked", stateButton( "blocked" ), x, by, bw, 34,
		"SecondaryButton", { action = "mark", id = item.id, state = "blocked" } )
	x = x + bw + gap
	kids[#kids + 1] = button( "MarkSkip", stateButton( "skip" ), x, by, bw, 34,
		"SecondaryButton", { action = "mark", id = item.id, state = "skip" } )
	x = x + bw + gap
	kids[#kids + 1] = button( "MarkClear", "CLEAR", x, by, bw, 34,
		"SecondaryButton", { action = "clearmark", id = item.id } )
	if item.run ~= nil then
		x = x + bw + gap
		kids[#kids + 1] = button( "Run", "RUN IT", x, by, bw, 34,
			"StyledButtonLarge", { action = "run", id = item.id } )
	end

	-- WHAT THE FOUR ANSWERS MEAN, spelled out. STUCK is the one nobody guesses,
	-- and the difference from SKIP is the one that matters: stuck means the
	-- answer is still owed and I should chase it, skipped means it is not.
	local legend = ""
	for _, st2 in ipairs( Checklist.STATES ) do
		legend = legend .. ( legend == "" and "" or "      " )
			.. st2.label .. " = " .. tostring( st2.tiny )
	end
	kids[#kids + 1] = text( "Legend", legend, PAD, 598,
		ChecklistGui.W - PAD * 2, 14, "SM_TextTiny", DIM, "Left" )

	local right = ChecklistGui.W - PAD
	footer( kids, ChecklistGui.W, state, {
		button( "ToList", "BACK TO LIST", PAD, 642, 176, 32, "SecondaryButton",
			{ action = "list" } ),
		button( "Menu", "MENU", PAD + 188, 642, 110, 32, "SecondaryButton",
			{ action = "back" } ),
		button( "NextTodo", "NEXT THING TO TEST", right - 356, 642, 220, 32,
			"StyledButtonLarge", { action = "next" } ),
		button( "Close", "CLOSE", right - 124, 642, 124, 32, "StyledButtonLarge",
			{ action = "close" } ),
	} )

	return root
end


-- One entry point, so Game.lua has one thing to call and the panel decides
-- which of its two faces to show.
function ChecklistGui.Build( state )
	state = state or {}
	if state.item ~= nil and Checklist.Find( state.item ) ~= nil then
		return ChecklistGui.BuildItem( state )
	end
	return ChecklistGui.BuildList( state )
end
