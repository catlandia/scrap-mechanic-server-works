-- GuiProbe -- the experiment that settles what a json GUI button needs.
--
-- Three versions have now been spent on "the buttons dont work", and each fix
-- was a real bug that was not the whole story. Reasoning from the code has run
-- out of road: the widget tree matches vanilla's own PopUp_YN.gui property for
-- property, every skin resolves, every font is real, and no Lua error is raised.
--
-- So stop reasoning and measure. There are two things about our GUIs that no
-- vanilla GUI does, and this probe tests both, separately, one press at a time:
--
--   1. OUR CALLBACKS LIVE ON THE GAME SCRIPT.
--      Every jsonGui onClick in the base game belongs to a player script
--      (CreativePlayer.cl_e_unstuckYes), an interactable (ElectricEngine,
--      HideoutTrader, GarageConsole, PartUnlockStation) or a character. Not one
--      belongs to a Game script. A Game script is already special -- it has no
--      world -- so "it also does not receive GUI callbacks" is exactly the kind
--      of thing this engine does without saying so.
--
--   2. OUR WIDGET TREES ARE BUILT IN LUA.
--      Every vanilla jsonGui is sm.json.open()ed from a .gui file and then
--      indexed. Nothing in the base game hands render() a table it built itself.
--
-- Four combinations, one per /guitest. The panel says which one you are looking
-- at and rewrites itself when a press lands, so the answer is on the screen and
-- does not need the log.
--
--   1  game script,   tree built in Lua        <- what we ship today
--   2  game script,   tree from vanilla's .gui
--   3  player script, tree built in Lua
--   4  player script, tree from vanilla's .gui
--
-- Whichever tests report CLICK RECEIVED say what a button needs, and that goes
-- in CLAUDE.md as a rule rather than as another guess.

GuiProbe = {}

GuiProbe.W = 520
GuiProbe.H = 300

-- The order matters: it walks from what we ship to what vanilla does, so the
-- first test that passes is the smallest change that would fix the mod.
GuiProbe.MODES = {
	{ owner = "game", tree = "lua",
	  title = "TEST 1 of 4",
	  what = "GAME script, tree built in Lua",
	  note = "this is exactly what the mod ships today" },
	{ owner = "game", tree = "file",
	  title = "TEST 2 of 4",
	  what = "GAME script, tree from vanilla's own .gui file",
	  note = "if 1 fails and 2 works, the tree is the problem" },
	{ owner = "player", tree = "lua",
	  title = "TEST 3 of 4",
	  what = "PLAYER script, tree built in Lua",
	  note = "if 1 fails and 3 works, the Game script is the problem" },
	{ owner = "player", tree = "file",
	  title = "TEST 4 of 4",
	  what = "PLAYER script, tree from vanilla's own .gui file",
	  note = "the fully vanilla arrangement. if this fails, nothing here works" },
}

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

local function text( name, caption, x, y, w, h, font, colour )
	return widget{ Name = name, Type = "TextBox", Skin = "TextBox",
		Caption = caption, FontName = font or "SM_Text", Colour = colour or LABEL,
		TextAlign = "Left", x = x, y = y, width = w, height = h,
		NeedKey = false, NeedMouse = false }
end

-- The tree we ship: assembled in Lua, property for property the same as the
-- buttons in Data/Gui/JsonGuis/PopUp_YN.gui.
function GuiProbe.BuildLua( state, callback, closeCallback )
	state = state or {}
	local mode = GuiProbe.MODES[state.mode or 1] or GuiProbe.MODES[1]

	local root = widget{ Name = "BackPanel", Type = "Widget", Skin = "PanelEmpty",
		Anchor = "Center", InheritsPick = true, NeedKey = false, NeedMouse = false,
		x = 0, y = 0, width = GuiProbe.W, height = GuiProbe.H }
	root.onClose = closeCallback
	local kids = root.Childs

	kids[#kids + 1] = fill( "BG", 0, 0, GuiProbe.W, GuiProbe.H, BG, 0.97 )
	kids[#kids + 1] = fill( "Rule", 0, 60, GuiProbe.W, 3, state.hits and GREEN or ACCENT, 1 )
	kids[#kids + 1] = text( "Title", mode.title, 24, 16, 300, 30, "SM_Header", LABEL )
	kids[#kids + 1] = text( "What", mode.what, 24, 44, GuiProbe.W - 48, 18,
		"SM_TextTiny", DIM )

	local line, colour
	if state.hits then
		line = string.format( "CLICK RECEIVED  --  %d press%s, last was %s",
			state.hits, state.hits == 1 and "" or "es", tostring( state.last ) )
		colour = GREEN
	else
		line = "no press has arrived yet"
		colour = DIM
	end
	kids[#kids + 1] = text( "Result", line, 24, 80, GuiProbe.W - 48, 24, "SM_Text", colour )
	kids[#kids + 1] = text( "Note", mode.note, 24, 108, GuiProbe.W - 48, 18,
		"SM_TextTiny", DIM )
	kids[#kids + 1] = text( "Canvas", state.canvas or "", 24, 130, GuiProbe.W - 48, 18,
		"SM_TextTiny", DIM )
	kids[#kids + 1] = text( "Next", "type /guitest again for the next test", 24,
		GuiProbe.H - 34, GuiProbe.W - 48, 18, "SM_TextTiny", DIM )

	local by = GuiProbe.H - 100
	local a = widget{ Name = "ProbeA", Type = "Button", Skin = "PrimaryButton",
		Caption = "PRESS ME", FontName = "SM_ButtonLarge", TextAlign = "Center",
		x = 24, y = by, width = 200, height = 34 }
	a.onClick = callback
	a.onClickData = { probe = "A" }
	kids[#kids + 1] = a

	-- No onClickData at all. ElectricEngine.cl_onBearingSettingClick takes only
	-- ( self, widgetName ), so if a data table is what breaks dispatch, this
	-- button works and the one above does not.
	local b = widget{ Name = "ProbeB", Type = "Button", Skin = "SecondaryButton",
		Caption = "PRESS ME (no data)", FontName = "SM_ButtonLarge",
		TextAlign = "Center", x = 240, y = by, width = 240, height = 34 }
	b.onClick = callback
	kids[#kids + 1] = b

	return root
end

-- Vanilla's own file, with our callbacks attached exactly the way
-- CreativePlayer attaches them (Data/Scripts/game/CreativePlayer.lua:6-11).
-- If a hand-built table is the problem, this is the control that proves it.
function GuiProbe.BuildFromFile( state, callback, closeCallback )
	state = state or {}
	local mode = GuiProbe.MODES[state.mode or 1] or GuiProbe.MODES[1]
	local ok, root = pcall( sm.json.open, "$GAME_DATA/Gui/JsonGuis/PopUp_YN.gui" )
	if not ok or root == nil then return nil, tostring( root ) end

	-- IndexWidgets comes from $SURVIVAL_DATA/Scripts/util.lua. Both scripts that
	-- use this probe pull it in, but relying on load order for a global is how
	-- you get a nil at the worst moment.
	if type( IndexWidgets ) ~= "function" then
		return nil, "IndexWidgets is not loaded"
	end
	local index = IndexWidgets( root )
	if index["Title"] then
		index["Title"].Caption = mode.title .. " -- " .. mode.what
	end
	if index["Message"] then
		index["Message"].Caption = state.hits
			and string.format( "CLICK RECEIVED, %d press(es)", state.hits )
			or "no press has arrived yet. Press YES."
	end
	if index["Yes"] then
		index["Yes"].onClick = callback
		index["Yes"].onClickData = { probe = "Yes" }
	end
	if index["No"] then
		index["No"].onClick = callback
	end
	root.onClose = closeCallback
	return root
end

-- What the engine thinks the screen is. Two different questions with two
-- different answers, and the mod has been guessing which one a panel is
-- measured in:
--   sm.jsonGui.getViewSize  the canvas widget coordinates are in. What matters.
--   sm.gui.getScreenSize    the actual window.
function GuiProbe.CanvasLine()
	local parts = {}
	local ok, w, h = pcall( sm.jsonGui.getViewSize )
	parts[#parts + 1] = ok and string.format( "view %sx%s", tostring( w ), tostring( h ) )
		or "view unreadable"
	local ok2, sw, sh = pcall( sm.gui.getScreenSize )
	parts[#parts + 1] = ok2 and string.format( "screen %sx%s", tostring( sw ), tostring( sh ) )
		or "screen unreadable"
	parts[#parts + 1] = "host " .. tostring( sm.isHost )
	return table.concat( parts, "   " )
end
