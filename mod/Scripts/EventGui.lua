-- EventGui -- running the event without typing anything.
--
-- Asked for as: "everything needs to have a nice UI since I dont want to type
-- commands to find what I need to start the event."
--
-- So every control the clock has is on one panel: the three durations, and the
-- five things a host does to a running event. The chat commands still exist and
-- still work, because a host mid-event sometimes has one hand on the keyboard
-- and no time to find a button -- but nobody has to learn them to start.
--
-- Fonts are picked from the safe list. SM_LabelMini and SM_Button are NOT safe:
-- the game ships a limited glyph atlas per font and those two are missing
-- letters we use. dev/test_logic.py checks every caption here against the real
-- atlas, which is the only reason this is knowable without a screenshot.

EventGui = {}

EventGui.W = 760
EventGui.H = 560

local PAD = 28
local ROW_H = 62
local ROW_TOP = 108

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

-- An editable number field. Shape taken from DigitalSign.gui's EnterTextBox,
-- which is the base game's only typed input in a json GUI:
--
--   Static = false      the thing that makes it editable at all
--   NeedKey = true      or it never takes the keyboard
--   onTextEnter         fires on Enter, as ( self, widgetName, text )
--                       -- DigitalSign.lua:157
--
-- MaxTextLength stops somebody pasting a novel into a minutes field.
local function numberBox( name, value, x, y, w, h )
	local b = widget{ Name = name, Type = "EditBox", Skin = "EditBoxEmpty",
		Caption = tostring( value ), CaptionDisableReplacing = true,
		FontName = "SM_Text", TextAlign = "Center", TextColour = ACCENT,
		Static = false, MultiLine = false, WordWrap = false,
		HeightFromText = false, MaxTextLength = 4,
		x = x, y = y, width = w, height = h }
	b.onTextEnter = "cl_onEventTimeTyped"
	b.onTextEdit = "cl_onEventTimeEdited"
	return b
end

local function button( name, caption, x, y, w, h, skin, data )
	local b = widget{ Name = name, Type = "Button", Skin = skin or "SecondaryButton",
		Caption = caption, FontName = "SM_ButtonLarge", TextAlign = "Center",
		x = x, y = y, width = w, height = h }
	b.onClick = "cl_onEventGuiClick"
	b.onClickData = data
	return b
end

-- The three durations, and what each one is for. Steps rather than typing, so
-- there is no way to end up with an event of "6O" minutes.
EventGui.FIELDS = {
	{ key = "prep", label = "PREP TIME", box = "TypePrep",
	  help = "claim a plot, no building yet. 0 to start building at once",
	  steps = { 0, 2, 5, 10, 15, 20, 30, 45, 60 }, min = 0, max = 1440 },
	{ key = "build", label = "BUILD TIME", box = "TypeBuild",
	  help = "the event itself",
	  steps = { 5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240 }, min = 1, max = 1440 },
	{ key = "buffer", label = "BUFFER", box = "TypeBuffer",
	  help = "after building closes, before anything locks. 0 for none",
	  steps = { 0, 1, 2, 5, 10, 15 }, min = 0, max = 1440 },
}

-- Which field a typed box belongs to. A text event gives the widget NAME and the
-- text and nothing else -- there is no onClickData on the way through -- so the
-- name has to carry the answer.
function EventGui.FieldForBox( widgetName )
	for _, f in ipairs( EventGui.FIELDS ) do
		if f.box == widgetName then return f end
	end
	return nil
end

-- Whatever was typed, turned into minutes this panel will accept.
-- Returns the number, or nil and a reason.
function EventGui.ParseTime( widgetName, text )
	local f = EventGui.FieldForBox( widgetName )
	if f == nil then return nil, "unknown field" end

	local n = tonumber( ( tostring( text ):gsub( "[^%d%.%-]", "" ) ) )
	if n == nil then
		return nil, string.format( "%s: type a number of minutes", f.label )
	end
	-- Whole minutes. "2.5" is a fair thing to type and the clock counts seconds,
	-- but every other part of the event is stated in minutes and half a minute of
	-- prep is not a thing anybody means.
	n = math.floor( n + 0.5 )
	if n < f.min then
		return f.min, string.format( "%s cannot be less than %d", f.label, f.min )
	end
	if n > f.max then
		return f.max, string.format( "%s capped at %d minutes", f.label, f.max )
	end
	return n
end

function EventGui.Step( key, current, dir )
	for _, f in ipairs( EventGui.FIELDS ) do
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

-- state: { phase, remaining, paused, prep, build, buffer }
function EventGui.Build( state )
	state = state or {}
	local phase = state.phase or "off"
	local running = ( phase == "prep" or phase == "build" or phase == "buffer" )

	local root = widget{ Name = "BackPanel", Type = "Widget", Skin = "PanelEmpty",
		Anchor = "Center", InheritsPick = true, NeedKey = false, NeedMouse = false,
		x = 0, y = 0, width = EventGui.W, height = EventGui.H }
	root.onClose = "cl_onEventGuiClose"
	local kids = root.Childs

	kids[#kids + 1] = fill( "BG", 0, 0, EventGui.W, EventGui.H, BG, 0.96 )
	kids[#kids + 1] = fill( "HeaderBand", 0, 0, EventGui.W, 68, PANEL, 0.05 )
	kids[#kids + 1] = fill( "HeaderRule", 0, 68, EventGui.W, 2, ACCENT, 1 )
	kids[#kids + 1] = text( "Title", "EVENT CLOCK", PAD, 18, 460, 34,
		"SM_Header", LABEL, "Left" )

	local sub = running
		and string.format( "%s -- %s left%s", Event.LABELS[phase] or phase,
			Event.Clock( state.remaining ), state.paused and "  PAUSED" or "" )
		or "nothing running"
	kids[#kids + 1] = text( "Sub", sub, PAD, 46, 380, 20, "SM_TextTiny", DIM, "Left" )
	-- What the last press did. The panel stays open across every control now, so
	-- this is where PAUSE says it paused.
	if state.status then
		kids[#kids + 1] = text( "Status", state.status, PAD + 390, 46,
			EventGui.W - PAD * 2 - 390, 20, "SM_TextTiny", ACCENT, "Right" )
	end

	--[[ the three durations ]]
	local rowW = EventGui.W - PAD * 2
	for i, f in ipairs( EventGui.FIELDS ) do
		local y = ROW_TOP + ( i - 1 ) * ROW_H
		kids[#kids + 1] = fill( "Row" .. i, PAD, y, rowW, ROW_H - 10,
			PANEL, ( i % 2 == 0 ) and 0.015 or 0.035 )
		kids[#kids + 1] = text( "L" .. i, f.label, PAD + 16, y + 6, 300, 20,
			"SM_Text", LABEL, "Left" )
		kids[#kids + 1] = text( "H" .. i, f.help, PAD + 16, y + 28, rowW - 260, 18,
			"SM_TextTiny", DIM, "Left" )
		kids[#kids + 1] = button( "Dec" .. i, "<", PAD + rowW - 230, y + 8, 40, 36,
			"SecondaryButton", { action = "step", key = f.key, dir = -1 } )

		-- TYPE ANY NUMBER. The steppers are quick for the usual values; this is
		-- for the ones that are not. "allow for custom numbers from the keyboard
		-- so I can set my own time."
		--
		-- Static = false is what makes an EditBox editable -- the TextBoxes on
		-- every other panel are Static = true and simply display. The rest of
		-- these properties are copied from the game's own text-entry widget,
		-- Data/Gui/JsonGuis/DigitalSign.gui, which is the only editable box in
		-- the base game and therefore the only proof of what one needs.
		kids[#kids + 1] = numberBox( f.box, state[f.key] or 0,
			PAD + rowW - 184, y + 10, 110, 28 )

		kids[#kids + 1] = button( "Inc" .. i, ">", PAD + rowW - 64, y + 8, 40, 36,
			"SecondaryButton", { action = "step", key = f.key, dir = 1 } )
	end

	--[[ what happens, spelled out ]]
	local sy = ROW_TOP + #EventGui.FIELDS * ROW_H + 6
	kids[#kids + 1] = fill( "SumRule", PAD, sy, rowW, 1, PANEL, 0.12 )
	local total = ( state.prep or 0 ) + ( state.build or 0 ) + ( state.buffer or 0 )
	kids[#kids + 1] = text( "Sum1", string.format(
		"%d minutes end to end. The last 5 minutes of building get the warehouse alarm.",
		total ), PAD, sy + 12, rowW, 20, "SM_Text", LABEL, "Left" )
	kids[#kids + 1] = text( "Sum2",
		"Click a number to type your own, then press Enter. Or use the arrows.",
		PAD, sy + 34, rowW, 20, "SM_TextTiny", DIM, "Left" )

	--[[ controls ]]
	-- Two rows of controls, then CLOSE on its own line. Worked out from H rather
	-- than nudged by eye, because STOP and CLOSE overlapped when they were.
	local by = EventGui.H - 160
	if running then
		kids[#kids + 1] = button( "Pause",
			state.paused and "RESUME" or "PAUSE", PAD, by, 150, 38,
			"StyledButtonLarge", { action = state.paused and "resume" or "pause" } )
		kids[#kids + 1] = button( "Skip", "SKIP AHEAD", PAD + 162, by, 170, 38,
			"SecondaryButton", { action = "skip" } )
		kids[#kids + 1] = button( "Less", "-5 MIN", PAD + 344, by, 120, 38,
			"SecondaryButton", { action = "add", n = -5 } )
		kids[#kids + 1] = button( "More", "+5 MIN", PAD + 476, by, 120, 38,
			"SecondaryButton", { action = "add", n = 5 } )
		kids[#kids + 1] = button( "Stop", "STOP THE EVENT", PAD, by + 48,
			rowW, 38, "SecondaryButton", { action = "stop" } )
	else
		kids[#kids + 1] = button( "Start", "START THE EVENT", PAD, by, rowW, 48,
			"StyledButtonLarge", { action = "start" } )
		kids[#kids + 1] = text( "StartHint",
			( state.prep or 0 ) > 0
				and "Prep starts now. Building opens when the prep clock runs out."
				or "No prep: building opens the moment you press this.",
			PAD, by + 54, rowW, 18, "SM_TextTiny", DIM, "Left" )
	end

	kids[#kids + 1] = button( "Back", "BACK", PAD, EventGui.H - 52, 130, 36,
		"SecondaryButton", { action = "back" } )
	kids[#kids + 1] = button( "Close", "CLOSE", EventGui.W - PAD - 140,
		EventGui.H - 52, 140, 36, "SecondaryButton", { action = "close" } )
	return root
end
