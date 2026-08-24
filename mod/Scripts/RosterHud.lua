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

local BG = "0.055 0.062 0.078 1"
local ACCENT = "1 0.54 0.18 1"
local DIM = "0.62 0.65 0.72 1"
local LABEL = "0.90 0.92 0.96 1"

-- Mirror of EventHud.TopRight. Same clamp, same reason: if the canvas ever comes
-- back smaller than the panel, the panel is pinned inside it rather than allowed
-- to hang off an edge where it cannot be seen.
function RosterHud.TopLeft( canvasW, canvasH )
	local m = RosterHud.MARGIN
	local x = -canvasW * 0.5 + RosterHud.W * 0.5 + m
	local y = -canvasH * 0.5 + RosterHud.H * 0.5 + m

	local maxX = canvasW * 0.5 - RosterHud.W * 0.5
	local maxY = canvasH * 0.5 - RosterHud.H * 0.5
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

-- state is { online = n, residents = n }, straight from Game.client_setRoster.
-- screenW/screenH are arguments rather than read here so dev/test_logic.py can
-- check the layout at every resolution the game ships skins for.
function RosterHud.Build( state, screenW, screenH )
	state = state or {}
	local online = tonumber( state.online ) or 0
	local residents = tonumber( state.residents ) or 0

	local x, y = RosterHud.TopLeft( screenW or 1920, screenH or 1080 )
	local root = widget{ Name = "RosterHud", Type = "Widget", Skin = "PanelEmpty",
		Anchor = "Center", InheritsPick = false,
		x = x, y = y, width = RosterHud.W, height = RosterHud.H }
	local kids = root.Childs

	kids[#kids + 1] = fill( "RosterBG", 0, 0, RosterHud.W, RosterHud.H, BG, 0.78 )
	-- The same 4px bar the event clock wears, so the two corners read as one HUD
	-- rather than as two unrelated boxes.
	kids[#kids + 1] = fill( "RosterBar", 0, 0, 4, RosterHud.H, ACCENT, 1 )

	kids[#kids + 1] = text( "OnlineLabel", "ONLINE", 16, 7, 90, 16,
		"SM_LabelTiny", DIM, "Left" )
	kids[#kids + 1] = text( "OnlineValue", tostring( online ),
		RosterHud.W - 76, 2, 60, 24, "SM_HeaderSmall", LABEL, "Right" )

	kids[#kids + 1] = fill( "RosterRule", 16, 31, RosterHud.W - 32, 1, LABEL, 0.12 )

	kids[#kids + 1] = text( "ResidentLabel", "RESIDENTS", 16, 38, 90, 16,
		"SM_LabelTiny", DIM, "Left" )
	kids[#kids + 1] = text( "ResidentValue", tostring( residents ),
		RosterHud.W - 76, 34, 60, 22, "SM_HeaderSmall", LABEL, "Right" )

	return root
end
