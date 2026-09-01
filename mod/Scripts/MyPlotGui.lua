-- MyPlotGui -- the panel a player actually uses.
--
-- Asked for as "make it easy to use stuff and claim plots". Claiming was
-- /plot claim, typed, while standing in the right square, with the result
-- arriving as a line of chat that scrolls away. Everything a builder needs to do
-- with their ground is on one panel now: see which square they are stood on,
-- claim it, find it again, see who is on their team, and leave.
--
-- Deliberately NOT the city layout panel. That one is the host laying out a
-- city and it can destroy every build in the world; this one is for the twenty
-- people at the event and can only ever affect the square they are stood on.
--
-- Same widget vocabulary as SettingsGui and PlotsGui -- PanelEmpty containers,
-- WhiteSkin rectangles for panels and dividers, TextBox for type, onClickData to
-- carry which action a button means. See SettingsGui.lua for where it came from.
--
-- The map is PlotsGui.AddMap, not a copy of it: one drawing routine, fed from
-- Layout, which is the same code the builder runs.

MyPlotGui = {}

MyPlotGui.W = 900
MyPlotGui.H = 560

local PAD = 28
local MAP = 320

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
	b.onClick = "cl_onMyPlotClick"
	b.onClickData = data
	return b
end

-- state: {
--   mine        plot index you own, or nil
--   standing    { index, kind, owner, free } for the ground under your feet
--   team        { index -> ownerName }
--   plotsOn     is the plot system switched on at all
--   cfg         the grid, for the map
-- }
function MyPlotGui.Build( state )
	state = state or {}
	local cfg = state.cfg or {}

	local root = widget{ Name = "BackPanel", Type = "Widget", Skin = "PanelEmpty",
		Anchor = "Center", InheritsPick = true, NeedKey = false, NeedMouse = false,
		x = 0, y = 0, width = MyPlotGui.W, height = MyPlotGui.H }
	root.onClose = "cl_onMyPlotClose"
	local kids = root.Childs

	kids[#kids + 1] = fill( "BG", 0, 0, MyPlotGui.W, MyPlotGui.H, BG, 0.96 )
	kids[#kids + 1] = fill( "HeaderBand", 0, 0, MyPlotGui.W, 68, PANEL, 0.05 )
	kids[#kids + 1] = fill( "HeaderRule", 0, 68, MyPlotGui.W, 2, ACCENT, 1 )
	kids[#kids + 1] = text( "Title", "MY PLOT", PAD, 18, 400, 34,
		"SM_Header", LABEL, "Left" )

	local colW = MyPlotGui.W - PAD * 2 - MAP - 32
	local y = 92

	if not state.plotsOn then
		kids[#kids + 1] = text( "Sub", "the host has not switched plots on",
			PAD, 46, 520, 20, "SM_TextTiny", DIM, "Left" )
		kids[#kids + 1] = text( "Off",
			"Plots are off. Build anywhere the host allows.",
			PAD, y, colW, 24, "SM_Text", LABEL, "Left" )
		kids[#kids + 1] = button( "Back", "BACK", MyPlotGui.W - PAD - 288,
			MyPlotGui.H - 56, 130, 34, "SecondaryButton", { action = "back" } )
		kids[#kids + 1] = button( "Close", "CLOSE", MyPlotGui.W - PAD - 150,
			MyPlotGui.H - 56, 150, 34, "StyledButtonLarge", { action = "close" } )
		return root
	end

	kids[#kids + 1] = text( "Sub",
		state.status or "your ground, and what you may do with it",
		PAD, 46, MyPlotGui.W - PAD * 2 - 40, 20, "SM_TextTiny",
		state.status and ACCENT or DIM, "Left" )

	--[[ what you own ]]
	kids[#kids + 1] = text( "OwnHead", "YOU OWN", PAD, y, 200, 16,
		"SM_LabelTiny", DIM, "Left" )
	y = y + 20
	kids[#kids + 1] = fill( "OwnBox", PAD, y, colW, 54, PANEL, 0.035 )
	if state.mine then
		kids[#kids + 1] = text( "OwnVal", string.format( "PLOT %d", state.mine ),
			PAD + 16, y + 14, colW - 32, 28, "SM_HeaderSmall", GREEN, "Left" )
	else
		kids[#kids + 1] = text( "OwnVal", "nothing yet",
			PAD + 16, y + 16, colW - 32, 24, "SM_Text", DIM, "Left" )
	end
	y = y + 68

	--[[ what you are stood on ]]
	kids[#kids + 1] = text( "HereHead", "YOU ARE STANDING ON", PAD, y, 300, 16,
		"SM_LabelTiny", DIM, "Left" )
	y = y + 20
	kids[#kids + 1] = fill( "HereBox", PAD, y, colW, 54, PANEL, 0.035 )

	local here = state.standing
	local hereLine, hereColour = "nowhere in the city", DIM
	if here then
		if here.kind ~= "plot" then
			hereLine = ( here.kind == "plaza" and "the spawn plaza" )
				or ( here.kind == "avenue" and "an avenue" )
				or ( here.kind == "road" and "a road" )
				or "shared ground"
			hereLine = hereLine .. " -- nobody builds here"
		elseif here.free then
			hereLine, hereColour = string.format( "plot %d -- FREE", here.index ), GREEN
		elseif here.mine then
			hereLine, hereColour = string.format( "plot %d -- yours", here.index ), GREEN
		else
			hereLine, hereColour =
				string.format( "plot %d -- %s", here.index, tostring( here.owner ) ), ACCENT
		end
	end
	kids[#kids + 1] = text( "HereVal", hereLine, PAD + 16, y + 16, colW - 32, 24,
		"SM_Text", hereColour, "Left" )
	y = y + 68

	--[[ your team ]]
	kids[#kids + 1] = text( "TeamHead", "YOUR TEAM", PAD, y, 200, 16,
		"SM_LabelTiny", DIM, "Left" )
	y = y + 20
	local mates = state.team or {}
	local line = "just you"
	if #mates > 0 then
		line = table.concat( mates, ",  " )
	end
	kids[#kids + 1] = text( "TeamVal", line, PAD, y, colW, 40,
		"SM_TextTiny", LABEL, "Left" )
	y = y + 46
	kids[#kids + 1] = text( "TeamHelp",
		"team up with the plot in front, behind, left or right -- both of you run it",
		PAD, y, colW, 18, "SM_TextTiny", DIM, "Left" )

	--[[ the map ]]
	if state.cfg then
		PlotsGui.AddMap( kids, cfg, MyPlotGui.W - PAD - MAP, 100, MAP )
	end

	--[[ actions ]]
	local by = MyPlotGui.H - 56
	local canClaim = state.mine == nil and here ~= nil
		and here.kind == "plot" and here.free
	kids[#kids + 1] = button( "Claim",
		canClaim and "CLAIM THIS PLOT" or "CLAIM",
		PAD, by, 190, 34,
		canClaim and "StyledButtonLarge" or "SecondaryButton",
		{ action = "claim" } )
	kids[#kids + 1] = button( "Find", "FIND MY PLOT", PAD + 202, by, 170, 34,
		"SecondaryButton", { action = "find" } )
	kids[#kids + 1] = button( "Leave", "GIVE IT UP", PAD + 384, by, 150, 34,
		"SecondaryButton", { action = "leave" } )
	-- THE TWO QUESTIONS A BUILDER ACTUALLY ASKS, and both were chat commands
	-- nobody knew existed. "why cant I place this" is the single most common
	-- thing a plot system has to answer, and /why answered it to a chat log that
	-- is behind the panel.
	--
	-- Under the MAP rather than in the button row: the row is full at five, and
	-- the layout check said so the first time these were added to it -- "Budget
	-- runs 36px past the right edge". The map ends at y 420 and the hint starts
	-- at by - 22, so this band is the free space on the panel.
	local qy = MyPlotGui.H - 130
	kids[#kids + 1] = button( "Why", "WHY CANNOT I BUILD",
		MyPlotGui.W - PAD - MAP, qy, 200, 32, "SecondaryButton",
		{ action = "why" } )
	kids[#kids + 1] = button( "Budget", "MY LIMITS",
		MyPlotGui.W - PAD - 110, qy, 110, 32, "SecondaryButton",
		{ action = "budget" } )
	kids[#kids + 1] = button( "Back", "BACK", MyPlotGui.W - PAD - 268, by, 120, 34,
		"SecondaryButton", { action = "back" } )
	kids[#kids + 1] = button( "Close", "CLOSE", MyPlotGui.W - PAD - 130, by, 130, 34,
		"SecondaryButton", { action = "close" } )

	-- One line under the buttons saying what the big one will do, because
	-- "CLAIM" greyed out with no reason is the thing people ask about.
	local hint
	if state.mine then
		hint = "You already own a plot. Give it up before claiming another."
	elseif canClaim then
		hint = "This square is free. CLAIM makes it yours."
	elseif here and here.kind == "plot" then
		hint = "Someone already owns this one. Stand on a grey square on the map."
	else
		hint = "Stand on a plot -- the grey squares on the map -- then press CLAIM."
	end
	kids[#kids + 1] = text( "Hint", hint, PAD, by - 22, MyPlotGui.W - PAD * 2, 18,
		"SM_TextTiny", DIM, "Left" )

	return root
end
