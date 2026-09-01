-- DevGui -- the crowd, the benchmark and the bridge, on buttons.
--
-- REPORTED: "I want the MENU to be the menu", and then, asked whether the test
-- tools belonged on it: "Yes, but behind a DEV TOOLS entry."
--
-- Behind is the operative word. Everything here changes the world in a way an
-- event does not want: /crowd puts up to 128 characters on the city, /bench
-- walks that number up on its own for several minutes, and /bridge opens a door
-- that lets a process outside the game run host commands. So they are on their
-- own panel with their own warning rather than mixed in with the event
-- controls, and the destructive one -- the crowd -- steps rather than jumps, so
-- a misclick costs ten bots and not a hundred.
--
-- WHAT A BOT IS NOT. It has no client connection, so no number of them measures
-- the per-client network budget -- the one failure mode this project has
-- actually measured. It cannot lock a plot either: sv_pushOut needs a Player to
-- move, so a bot that could deny a zone would hold it shut forever. The panel
-- says so, because a benchmark that is trusted for the wrong thing is worse
-- than no benchmark. See docs/CROWD.md.
--
-- Same widget vocabulary as every other panel here; see SettingsGui.lua for
-- where it came from.

DevGui = {}

DevGui.W = 700
-- Header, three blocks with their own headings, a status line and the footer.
-- The layout check computes whether that fits rather than trusting the eye.
DevGui.H = 600

-- How many bots a single press adds or removes. Small on purpose: the crowd is
-- the one thing on this panel that is slow to undo.
DevGui.STEP = 10

local PAD = 26

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
	b.onClick = "cl_onDevGuiClick"
	b.onClickData = data
	return b
end


--[[ the pure half ]]

-- What the next press would leave the crowd at. Clamped at both ends, because a
-- panel that offers to remove bots from an empty city is a panel that will one
-- day be pressed and appear to do nothing.
function DevGui.NextSize( current, delta )
	local n = math.floor( tonumber( current ) or 0 ) + delta
	if n < 0 then n = 0 end
	if n > DevGui.MAX then n = DevGui.MAX end
	return n
end

-- The measured knee is around 70 to 80 bots on this machine and the curve was
-- walked to 128, so that is the top of the range rather than a guess.
DevGui.MAX = 128

DevGui.MODES = { "build", "churn", "off" }

function DevGui.NextMode( mode )
	for i, m in ipairs( DevGui.MODES ) do
		if m == mode then
			return DevGui.MODES[( i % #DevGui.MODES ) + 1]
		end
	end
	return DevGui.MODES[1]
end


--[[ the panel ]]

-- state: {
--   bots      how many crowd bots are standing
--   mode      what they are doing: build, churn or off
--   bench     one line of benchmark status
--   bridge    whether the outside-the-game channel is open
--   status    what the last press did
-- }
function DevGui.Build( state )
	state = state or {}
	local bots = math.floor( tonumber( state.bots ) or 0 )
	local mode = tostring( state.mode or "off" )

	local root = widget{ Name = "BackPanel", Type = "Widget", Skin = "PanelEmpty",
		Anchor = "Center", InheritsPick = true, NeedKey = false, NeedMouse = false,
		x = 0, y = 0, width = DevGui.W, height = DevGui.H }
	root.onClose = "cl_onDevGuiClose"
	local kids = root.Childs
	local W = DevGui.W - PAD * 2

	kids[#kids + 1] = fill( "BG", 0, 0, DevGui.W, DevGui.H, BG, 0.96 )
	kids[#kids + 1] = fill( "Band", 0, 0, DevGui.W, 64, PANEL, 0.05 )
	kids[#kids + 1] = fill( "Rule", 0, 64, DevGui.W, 2, ACCENT, 1 )
	kids[#kids + 1] = text( "Title", "DEV TOOLS", PAD, 16, 400, 30,
		"SM_Header", LABEL, "Left" )
	kids[#kids + 1] = text( "Sub",
		"for testing an empty server. Not for a live event",
		PAD, 42, 500, 18, "SM_TextTiny", ACCENT, "Left" )

	--[[ the crowd ]]

	local y = 92
	kids[#kids + 1] = text( "CrowdHead", "FAKE CROWD", PAD, y, 300, 16,
		"SM_LabelTiny", DIM, "Left" )
	y = y + 22
	kids[#kids + 1] = fill( "CrowdStrip", PAD, y, W, 44, PANEL, 0.06 )
	kids[#kids + 1] = text( "CrowdN",
		string.format( "%d bot%s, mode %s", bots, bots == 1 and "" or "s", mode ),
		PAD + 14, y + 13, 240, 18, "SM_Text",
		bots > 0 and GREEN or DIM, "Left" )
	-- Laid out left to right with the widths written down, because the first
	-- version put CLEAR at W - PAD - 90 and MODE ended four pixels past it. The
	-- fits check named them: "buttons 'CrowdMode' and 'CrowdOff' overlap -- one
	-- of them cannot be pressed", which on this panel would have meant a stray
	-- press clearing the crowd instead of changing its mode.
	kids[#kids + 1] = button( "CrowdLess",
		string.format( "-%d", DevGui.STEP ), PAD + 260, y + 8, 60, 28,
		"SecondaryButton", { action = "crowd", size = DevGui.NextSize( bots, -DevGui.STEP ) } )
	kids[#kids + 1] = button( "CrowdMore",
		string.format( "+%d", DevGui.STEP ), PAD + 326, y + 8, 60, 28,
		"SecondaryButton", { action = "crowd", size = DevGui.NextSize( bots, DevGui.STEP ) } )
	kids[#kids + 1] = button( "CrowdMode", "MODE: " .. string.upper( mode ),
		PAD + 392, y + 8, 140, 28, "SecondaryButton",
		{ action = "crowdmode", mode = DevGui.NextMode( mode ) } )
	kids[#kids + 1] = button( "CrowdOff", "CLEAR", PAD + 540, y + 8, 100, 28,
		"SecondaryButton", { action = "crowd", size = 0 } )
	y = y + 50
	kids[#kids + 1] = text( "CrowdNote",
		"a bot has no connection, so no number of them measures the network. "
			.. "And a bot can hold a plot open but never lock one",
		PAD + 2, y, W - 4, 16, "SM_TextTiny", DIM, "Left" )

	--[[ the benchmark ]]

	y = y + 34
	kids[#kids + 1] = text( "BenchHead", "BENCHMARK", PAD, y, 300, 16,
		"SM_LabelTiny", DIM, "Left" )
	y = y + 22
	kids[#kids + 1] = fill( "BenchStrip", PAD, y, W, 44, PANEL, 0.06 )
	kids[#kids + 1] = text( "BenchS", tostring( state.bench or "not running" ),
		PAD + 14, y + 13, W - 360, 18, "SM_Text", DIM, "Left" )
	kids[#kids + 1] = button( "BenchStart", "START", DevGui.W - PAD - 330, y + 8,
		100, 28, "SecondaryButton", { action = "bench", how = "start" } )
	kids[#kids + 1] = button( "BenchStop", "STOP", DevGui.W - PAD - 224, y + 8,
		100, 28, "SecondaryButton", { action = "bench", how = "stop" } )
	kids[#kids + 1] = button( "BenchRes", "RESULTS", DevGui.W - PAD - 118, y + 8,
		118, 28, "SecondaryButton", { action = "bench", how = "results" } )
	y = y + 50
	kids[#kids + 1] = text( "BenchNote",
		"walks the crowd up in steps and records frame rate and tick rate at "
			.. "each one. Takes several minutes and ends with a full city",
		PAD + 2, y, W - 4, 16, "SM_TextTiny", DIM, "Left" )

	--[[ the bridge ]]

	y = y + 34
	kids[#kids + 1] = text( "BridgeHead", "OUTSIDE CONTROL", PAD, y, 300, 16,
		"SM_LabelTiny", DIM, "Left" )
	y = y + 22
	kids[#kids + 1] = fill( "BridgeStrip", PAD, y, W, 44, PANEL, 0.06 )
	kids[#kids + 1] = text( "BridgeS",
		state.bridge and "OPEN -- commands from outside the game will run as you"
			or "shut",
		PAD + 14, y + 13, W - 240, 18, "SM_Text",
		state.bridge and ACCENT or DIM, "Left" )
	kids[#kids + 1] = button( "BridgeOn", state.bridge and "CLOSE IT" or "OPEN IT",
		DevGui.W - PAD - 210, y + 8, 210, 28,
		state.bridge and "SecondaryButton" or "StyledButtonLarge",
		{ action = "bridge", on = not state.bridge } )

	kids[#kids + 1] = text( "Status", tostring( state.status or "" ),
		PAD, DevGui.H - 86, W, 18, "SM_TextTiny", ACCENT, "Left" )
	-- Where the panel came from and how to make it go away again. This whole
	-- screen is only on the menu while developer mode is on, and somebody who
	-- turned it on to run one benchmark should not have to go looking for the
	-- switch that puts an event server back the way it was.
	kids[#kids + 1] = text( "DevNote",
		"this panel is on the menu because developer mode is on. "
			.. "/developer off takes it away again",
		PAD, DevGui.H - 66, W, 16, "SM_TextTiny", DIM, "Left" )

	kids[#kids + 1] = button( "Back", "BACK", PAD, DevGui.H - 50, 124, 32,
		"StyledButtonLarge", { action = "back" } )
	kids[#kids + 1] = button( "Close", "CLOSE", DevGui.W - 148, DevGui.H - 50,
		124, 32, "StyledButtonLarge", { action = "close" } )
	return root
end
