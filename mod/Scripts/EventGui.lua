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
	{ key = "prep", label = "PREP TIME",
	  help = "claim a plot, no building yet. 0 to start building at once",
	  steps = { 0, 2, 5, 10, 15, 20, 30, 45, 60 } },
	{ key = "build", label = "BUILD TIME",
	  help = "the event itself",
	  steps = { 5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240 } },
	{ key = "buffer", label = "BUFFER",
	  help = "after building closes, before anything locks. 0 for none",
	  steps = { 0, 1, 2, 5, 10, 15 } },
}

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
		kids[#kids + 1] = text( "V" .. i,
			string.format( "%d min", state[f.key] or 0 ),
			PAD + rowW - 184, y + 14, 110, 24, "SM_Text", ACCENT, "Center" )
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
		"Prep closes building and nothing else. Ending locks every build and saves the world.",
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
