-- RosterHud -- who is here, and who has ever been here, in the top left.
--
-- Asked for as: "add on top left. a counter of amount of players curently. and
-- amount of residents. resident list is list of players that were here - the
-- banned ones. the player list is the list of players that are here curently."
--
-- Two numbers, and they answer two different questions:
--
--   ONLINE      sm.player.getAllPlayers(). Who is in the world right now.
--   RESIDENTS   every record in Players.json that is not banned. Who has ever
--               been to this server and is still welcome.
--
-- The second one is the number a recurring event actually cares about -- it is
-- the size of the community the server has built up, and it survives restarts,
-- which the online count never does.
--
-- Positioning is EventHud's problem, solved: a root widget's x,y is its CENTRE,
-- measured from the centre of the CANVAS (sm.jsonGui.getViewSize, not
-- getScreenSize), with +y downwards. Top left is therefore a negative x and a
-- negative y. See the long note at the top of EventHud.lua for why that took
-- three tries to get right, and do not re-derive it here.
--
-- FONTS: SM_LabelTiny and SM_HeaderSmall only. Both are tier 1 -- they exist and
-- they carry the full character set. A font that does not exist still renders,
-- via MyGUI's fallback, while writing an error AND a full Lua traceback to disk
-- on every single redraw. See the font note in CLAUDE.md.

RosterHud = {}

RosterHud.W = 168
RosterHud.H = 62
RosterHud.MARGIN = 18

-- The extra strip that appears only while somebody is focused. It is on this
-- panel rather than a HUD of its own because this one already exists, already
-- sits in the corner a host looks at, and already re-renders once a second --
-- see Game.sv_pushRoster for why the name travels with the roster.
RosterHud.FOCUS_H = 30

-- How tall the panel is RIGHT NOW. Two states, and the position arithmetic
-- below has to be given the real one or a grown panel is placed as if it were
-- the short one and the extra strip hangs below where it should be.
function RosterHud.Height( state )
	local focus = state and state.focus
	if focus == nil or tostring( focus ) == "" then return RosterHud.H end
	return RosterHud.H + RosterHud.FOCUS_H
end

local BG = "0.055 0.062 0.078 1"
local ACCENT = "1 0.54 0.18 1"
local DIM = "0.62 0.65 0.72 1"
local LABEL = "0.90 0.92 0.96 1"

-- Mirror of EventHud.TopRight. Same clamp, same reason: if the canvas ever comes
-- back smaller than the panel, the panel is pinned inside it rather than allowed
-- to hang off an edge where it cannot be seen.
-- height is optional and defaults to the short panel, so every existing caller
-- and every existing check keeps working unchanged.
function RosterHud.TopLeft( canvasW, canvasH, height )
	local m = RosterHud.MARGIN
	local h = height or RosterHud.H
	local x = -canvasW * 0.5 + RosterHud.W * 0.5 + m
	local y = -canvasH * 0.5 + h * 0.5 + m

	local maxX = canvasW * 0.5 - RosterHud.W * 0.5
	local maxY = canvasH * 0.5 - h * 0.5
	if x > maxX then x = maxX end
	if x < -maxX then x = -maxX end
	if y > maxY then y = maxY end
	if y < -maxY then y = -maxY end

	return math.floor( x ), math.floor( y )
end

local function widget( t )
	t.Childs = t.Childs or {}
	t.NeedKey = false
	t.NeedMouse = false
	return t
end

local function fill( name, x, y, w, h, colour, alpha )
	return widget{ Name = name, Type = "Widget", Skin = "WhiteSkin",
		Colour = colour, Alpha = alpha, x = x, y = y, width = w, height = h }
end

local function text( name, caption, x, y, w, h, font, colour, align )
	return widget{ Name = name, Type = "TextBox", Skin = "TextBox",
		Caption = caption, FontName = font, Colour = colour or LABEL,
		TextAlign = align or "Left", x = x, y = y, width = w, height = h }
end

-- state is { online = n, residents = n, bots = n }, straight from
-- Game.client_setRoster.
--
-- BOTS ARE COUNTED AND SAID SO. /crowd bots claim plots and stand on them
-- through the same system a person does, which is the point -- the per-player
-- code paths have to do real work or the test measures nothing. But a host
-- glancing at this corner must never read "21" and think twenty-one people
-- turned up, so the bot share is shown separately and only while there is one.
-- screenW/screenH are arguments rather than read here so dev/test_logic.py can
-- check the layout at every resolution the game ships skins for.
function RosterHud.Build( state, screenW, screenH )
	state = state or {}
	local online = tonumber( state.online ) or 0
	local residents = tonumber( state.residents ) or 0
	local bots = tonumber( state.bots ) or 0

	local focus = state.focus
	if focus ~= nil then
		focus = tostring( focus )
		if focus == "" then focus = nil end
	end

	local panelH = RosterHud.Height( state )
	local x, y = RosterHud.TopLeft( screenW or 1920, screenH or 1080, panelH )
	local root = widget{ Name = "RosterHud", Type = "Widget", Skin = "PanelEmpty",
		Anchor = "Center", InheritsPick = false,
		x = x, y = y, width = RosterHud.W, height = panelH }
	local kids = root.Childs

	kids[#kids + 1] = fill( "RosterBG", 0, 0, RosterHud.W, panelH, BG, 0.78 )
	-- The same 4px bar the event clock wears, so the two corners read as one HUD
	-- rather than as two unrelated boxes.
	kids[#kids + 1] = fill( "RosterBar", 0, 0, 4, panelH, ACCENT, 1 )

	-- SM_LabelTiny is tier 1 -- full character set, no hollow boxes, no font
	-- fallback traceback per redraw. See the font note in CLAUDE.md before
	-- putting any other name here.
	kids[#kids + 1] = text( "OnlineLabel",
		bots > 0 and ( "ONLINE  " .. bots .. " BOT" .. ( bots == 1 and "" or "S" ) )
			or "ONLINE",
		16, 7, 120, 16, "SM_LabelTiny", DIM, "Left" )
	kids[#kids + 1] = text( "OnlineValue", tostring( online ),
		RosterHud.W - 76, 2, 60, 24, "SM_HeaderSmall", LABEL, "Right" )

	kids[#kids + 1] = fill( "RosterRule", 16, 31, RosterHud.W - 32, 1, LABEL, 0.12 )

	kids[#kids + 1] = text( "ResidentLabel", "RESIDENTS", 16, 38, 90, 16,
		"SM_LabelTiny", DIM, "Left" )
	kids[#kids + 1] = text( "ResidentValue", tostring( residents ),
		RosterHud.W - 76, 34, 60, 22, "SM_HeaderSmall", LABEL, "Right" )

	-- WHO EVERYBODY IS MEANT TO BE LOOKING AT. Only drawn while there is one,
	-- so the corner is unchanged for the 99% of an event when nobody is
	-- focused.
	--
	-- Truncated at 20 characters because this panel is 168 units wide and a
	-- Steam name may be 32. Losing the tail of a long name is a cosmetic
	-- problem; a name running off the panel and over the game is not.
	if focus ~= nil then
		-- Three ASCII dots, NOT a Unicode ellipsis. The game builds a limited
		-- glyph atlas per font from the strings it renders itself, and a
		-- codepoint it has never drawn comes out as a hollow box -- see the
		-- font note in CLAUDE.md. A dot is a dot everywhere.
		if #focus > 20 then focus = string.sub( focus, 1, 19 ) .. "..." end
		kids[#kids + 1] = fill( "FocusRule", 16, RosterHud.H - 2,
			RosterHud.W - 32, 1, LABEL, 0.12 )
		kids[#kids + 1] = text( "FocusLabel", "FOCUS", 16, RosterHud.H + 3, 60, 14,
			"SM_LabelTiny", DIM, "Left" )
		kids[#kids + 1] = text( "FocusValue", focus, 16, RosterHud.H + 14,
			RosterHud.W - 32, 16, "SM_TextTiny", ACCENT, "Left" )
	end

	return root
end
