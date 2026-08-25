-- StyleGui -- what the city is made of, PICKED rather than cycled.
--
-- REPORTED: "city build settings. specialy the material and colour selection.
-- make it not a slider like. but like a list so its easier to select. and use
-- the color pallete selection of paint tool for the city part color selection."
--
-- What it replaces: ten rows on the settings panel, each one a single button
-- that stepped to the next value and wrapped round at the end. Twenty-five
-- blocks and forty colours behind one button each, which makes reaching "wood 2"
-- from "concrete" sixteen clicks -- and every one of those clicks was a server
-- round trip, because a value change is the server's decision. Worse than the
-- click count: you could not SEE what you were choosing between. A stepper shows
-- one option at a time, so picking a colour meant clicking forty times and
-- remembering what each one looked like.
--
-- Everything is on one screen now: the five pieces down the left, all
-- twenty-five blocks as a list, and all forty colours as the paint tool's own
-- grid -- four rows of ten, in the tool's order, at the tool's colours.
--
--
-- A COLOURED, CLICKABLE SWATCH IS TWO VANILLA FACTS PUT TOGETHER
--
-- Neither half is invented, but the combination is ours, so both halves are
-- written down here.
--
--   a Button may use WhiteSkin      Data/Gui/EditorSkin.xml:27 --
--                                   <Widget type="Button" skin="WhiteSkin">
--                                   WhiteSkin is a 2x2 white patch with only a
--                                   "normal" state (MyGUI_BlackOrangeSkins.xml
--                                   :778), so it draws as a flat rectangle and
--                                   has no hover art. That is exactly what a
--                                   swatch is.
--
--   a Button may carry Colour       Data/Gui/JsonGuis/DigitalSign.gui -- all
--                                   eight of its colour-option buttons set both
--                                   Colour and onClick.
--
-- Because the source texel is white, Colour multiplies straight through and the
-- swatch is the colour asked for. This mod already relies on that for every
-- panel background it draws (see the fill() helper, which is the same skin on a
-- plain Widget).
--
-- BELT AND BRACES: each swatch is drawn TWICE -- a fill() rectangle first, then
-- the Button on top of it. The fill is the construction this mod has proven in
-- game a hundred times over; the Button is the half with only a vanilla-json
-- precedent behind it. If the Button somehow draws nothing, the grid still shows
-- the right colours and still takes clicks. If it draws as intended the two are
-- pixel-identical and nothing is lost. Forty extra widgets on a panel that is
-- built once per click is not a cost worth caring about.
--
--
-- Same widget vocabulary as SettingsGui -- PanelEmpty containers, WhiteSkin
-- rectangles, TextBox for type, onClickData to carry which thing was pressed.
-- See SettingsGui.lua for where that came from.

StyleGui = {}

StyleGui.W = 1120
StyleGui.H = 690

local BG = "0.055 0.062 0.078 1"
local PANEL = "1 1 1 1"
local ACCENT = "1 0.54 0.18 1"
local DIM = "0.62 0.65 0.72 1"
local LABEL = "0.90 0.92 0.96 1"

-- column 1 -- which piece of the city is being styled
local PIECE_X, PIECE_W = 24, 252
local PIECE_TOP, PIECE_PITCH, PIECE_H = 104, 66, 30

-- the whole-city styles, under the pieces
local PRESET_TOP, PRESET_W, PRESET_H = 452, 122, 28
local PRESET_XPITCH, PRESET_YPITCH = 130, 34

-- column 2 -- the block list. Two columns of thirteen holds the twenty-five
-- materials with one to spare, so adding a block does not reflow the panel.
local BLOCK_X, BLOCK_W, BLOCK_H = 300, 190, 26
local BLOCK_XPITCH, BLOCK_YPITCH = 198, 30
local BLOCK_TOP, BLOCK_ROWS = 104, 13

-- column 3 -- the paint tool's grid, at the tool's own proportions
local SW_X, SW_TOP, SW, SW_PITCH = 712, 104, 34, 37
local RING = 4                    -- how far the selection ring sticks out


local function widget( t )
	t.Childs = t.Childs or {}
	if t.NeedKey == nil then t.NeedKey = true end
	if t.NeedMouse == nil then t.NeedMouse = true end
	return t
end

local function fill( name, x, y, w, h, colour, alpha )
	return widget{
		Name = name, Type = "Widget", Skin = "WhiteSkin",
		Colour = colour, Alpha = alpha,
		x = x, y = y, width = w, height = h,
		NeedKey = false, NeedMouse = false,
	}
end

local function text( name, caption, x, y, w, h, font, colour, align )
	return widget{
		Name = name, Type = "TextBox", Skin = "TextBox",
		Caption = caption, FontName = font or "SM_Text",
		Colour = colour or LABEL, TextAlign = align or "Left",
		x = x, y = y, width = w, height = h,
		NeedKey = false, NeedMouse = false,
	}
end

local function button( name, caption, x, y, w, h, skin, data, font )
	local b = widget{
		Name = name, Type = "Button", Skin = skin or "SecondaryButton",
		Caption = caption, FontName = font or "SM_ButtonLarge", TextAlign = "Center",
		x = x, y = y, width = w, height = h,
	}
	b.onClick = "cl_onStyleGuiClick"
	b.onClickData = data
	return b
end

-- A swatch: no caption, no font, just a colour and a click. See the note at the
-- top of this file for why it is a Button on top of an identical fill.
local function swatch( name, x, y, size, colour, data )
	local b = widget{
		Name = name, Type = "Button", Skin = "WhiteSkin",
		Colour = colour,
		x = x, y = y, width = size, height = size,
	}
	b.onClick = "cl_onStyleGuiClick"
	b.onClickData = data
	return b
end


-- What the panel was handed, defended. A client that renders before its first
-- update, or a piece key that is not one of the five, must draw something rather
-- than throw inside a render callback -- an error in there takes the whole panel
-- down and the host sees an empty screen with no message.
function StyleGui.PieceFor( st )
	local want = st and st.piece
	for _, p in ipairs( Palette.PIECES ) do
		if p.key == want then return p end
	end
	return Palette.PIECES[1]
end

local function valuesFor( st, key )
	local s = st and st.style and st.style[key]
	return ( s and s.block ) or "", ( s and s.colour ) or ""
end


function StyleGui.Build( st )
	st = st or {}
	local piece = StyleGui.PieceFor( st )
	local block, colour = valuesFor( st, piece.key )

	local root = widget{
		Name = "BackPanel", Type = "Widget", Skin = "PanelEmpty", Anchor = "Center",
		InheritsPick = true, NeedKey = false, NeedMouse = false,
		x = 0, y = 0, width = StyleGui.W, height = StyleGui.H,
	}
	root.onClose = "cl_onStyleGuiClose"
	local kids = root.Childs

	kids[#kids + 1] = fill( "BG", 0, 0, StyleGui.W, StyleGui.H, BG, 0.96 )
	kids[#kids + 1] = fill( "HeaderBand", 0, 0, StyleGui.W, 68, PANEL, 0.05 )
	kids[#kids + 1] = fill( "HeaderRule", 0, 68, StyleGui.W, 2, ACCENT, 1 )
	kids[#kids + 1] = text( "Title", "CITY STYLE", 28, 18, 460, 34,
		"SM_Header", LABEL, "Left" )
	-- The status line is the only feedback a click gets: nothing on this panel
	-- closes it, so without this a block that was accepted and a block that was
	-- refused look identical.
	kids[#kids + 1] = text( "Sub",
		st.status or "pick a piece on the left, then a block or a colour",
		28, 46, StyleGui.W - 56, 20, "SM_TextTiny", st.status and ACCENT or DIM, "Left" )

	--[[ column 1 -- the five pieces ]]

	kids[#kids + 1] = text( "PieceHead", "CITY PIECE", PIECE_X, 82, PIECE_W, 16,
		"SM_LabelTiny", DIM, "Left" )

	for i, p in ipairs( Palette.PIECES ) do
		local y = PIECE_TOP + ( i - 1 ) * PIECE_PITCH
		local on = ( p.key == piece.key )
		local b, c = valuesFor( st, p.key )
		if on then
			kids[#kids + 1] = fill( "PieceSel", PIECE_X - 6, y - 6, 4, PIECE_H + 12, ACCENT, 1 )
		end
		kids[#kids + 1] = button( "Piece" .. p.key, p.label, PIECE_X, y, PIECE_W, PIECE_H,
			on and "StyledButtonLarge" or "SecondaryButton",
			{ action = "piece", piece = p.key }, "SM_ButtonLarge" )
		kids[#kids + 1] = text( "PieceVal" .. p.key, Palette.MaterialLabel( b ),
			PIECE_X + 6, y + PIECE_H + 4, PIECE_W - 40, 16,
			"SM_TextTiny", on and LABEL or DIM, "Left" )
		-- The colour, shown rather than named: the row is 252 wide and
		-- "deepgreen" next to "Fancy carpet" is more words than it is worth.
		kids[#kids + 1] = fill( "PieceSw" .. p.key, PIECE_X + PIECE_W - 26,
			y + PIECE_H + 4, 22, 16, Palette.GuiColour( c ), 1 )
	end

	--[[ the whole-city styles ]]

	kids[#kids + 1] = text( "StyleHead", "WHOLE CITY STYLES", PIECE_X, 428, PIECE_W, 16,
		"SM_LabelTiny", DIM, "Left" )
	for i, name in ipairs( Palette.STYLE_ORDER ) do
		local col = ( i - 1 ) % 2
		local row = math.floor( ( i - 1 ) / 2 )
		kids[#kids + 1] = button( "Style" .. name, string.upper( name ),
			PIECE_X + col * PRESET_XPITCH, PRESET_TOP + row * PRESET_YPITCH,
			PRESET_W, PRESET_H, "SecondaryButton",
			{ action = "stylepreset", preset = name }, "SM_ButtonSmall" )
	end
	kids[#kids + 1] = text( "StyleNote", "a style sets all ten at once",
		PIECE_X, 556, PIECE_W, 16, "SM_TextTiny", DIM, "Left" )

	--[[ column 2 -- every block, as a list ]]

	kids[#kids + 1] = text( "BlockHead", "BLOCK  --  " .. piece.label,
		BLOCK_X, 82, 380, 16, "SM_LabelTiny", DIM, "Left" )

	for i, name in ipairs( Palette.MATERIAL_ORDER ) do
		local col = math.floor( ( i - 1 ) / BLOCK_ROWS )
		local row = ( i - 1 ) % BLOCK_ROWS
		local on = ( name == block )
		kids[#kids + 1] = button( "Block" .. name, Palette.MaterialLabel( name ),
			BLOCK_X + col * BLOCK_XPITCH, BLOCK_TOP + row * BLOCK_YPITCH,
			BLOCK_W, BLOCK_H,
			on and "StyledButtonLarge" or "SecondaryButton",
			{ action = "block", value = name }, "SM_ButtonSmall" )
	end

	--[[ column 3 -- the paint tool's palette ]]

	kids[#kids + 1] = text( "ColourHead", "COLOUR  --  " .. piece.label,
		SW_X, 82, 380, 16, "SM_LabelTiny", DIM, "Left" )

	-- The ring goes down BEFORE the swatches so the swatch draws over the middle
	-- of it and what is left showing is a border. Later children draw on top.
	for r, row in ipairs( Palette.ROWS ) do
		for c, hex in ipairs( row ) do
			if Palette.NameOfHex( hex ) == colour or hex == colour then
				kids[#kids + 1] = fill( "SwRing",
					SW_X + ( c - 1 ) * SW_PITCH - RING, SW_TOP + ( r - 1 ) * SW_PITCH - RING,
					SW + RING * 2, SW + RING * 2, ACCENT, 1 )
			end
		end
	end

	for r, row in ipairs( Palette.ROWS ) do
		for c, hex in ipairs( row ) do
			local name = Palette.NameOfHex( hex )
			local x = SW_X + ( c - 1 ) * SW_PITCH
			local y = SW_TOP + ( r - 1 ) * SW_PITCH
			local gui = Palette.GuiColour( hex )
			kids[#kids + 1] = fill( "SwBG" .. name, x, y, SW, SW, gui, 1 )
			kids[#kids + 1] = swatch( "Sw" .. name, x, y, SW, gui,
				{ action = "colour", value = name } )
		end
	end

	--[[ what the selected piece currently is ]]

	local previewY = 290
	kids[#kids + 1] = text( "SelHead", "SELECTED", SW_X, 268, 380, 16,
		"SM_LabelTiny", DIM, "Left" )
	kids[#kids + 1] = fill( "SelSwBorder", SW_X - 2, previewY - 2, 76, 76, PANEL, 0.18 )
	kids[#kids + 1] = fill( "SelSw", SW_X, previewY, 72, 72, Palette.GuiColour( colour ), 1 )
	kids[#kids + 1] = text( "SelPiece", piece.label, SW_X + 84, previewY, 290, 22,
		"SM_Text", ACCENT, "Left" )
	kids[#kids + 1] = text( "SelBlock", Palette.MaterialLabel( block ),
		SW_X + 84, previewY + 26, 290, 20, "SM_TextSmall", LABEL, "Left" )
	-- The name AND the hex. A host who typed /set padcolour ff00ff has a colour
	-- with no swatch on the grid, and the name alone would just echo the hex
	-- back at them with no indication that is what happened.
	kids[#kids + 1] = text( "SelColour",
		tostring( colour ) .. "   " .. ( Palette.Hex( colour ) or "?" ),
		SW_X + 84, previewY + 48, 290, 18, "SM_TextTiny", DIM, "Left" )
	kids[#kids + 1] = text( "SelHelp", piece.help, SW_X, previewY + 84, 380, 16,
		"SM_TextTiny", DIM, "Left" )

	--[[ footer ]]

	local fy = StyleGui.H - 56
	kids[#kids + 1] = fill( "FooterRule", 24, fy - 14, StyleGui.W - 48, 1, PANEL, 0.12 )
	-- Said on the panel because it is the question this feature will always be
	-- asked: the city is imported blueprints, and a blueprint is not a live
	-- thing that can be repainted.
	kids[#kids + 1] = text( "Hint",
		"nothing changes until the city is built again  --  BUILD CITY on the city panel",
		24, fy + 8, 780, 18, "SM_TextTiny", DIM, "Left" )
	kids[#kids + 1] = button( "Back", "BACK", StyleGui.W - 286, fy, 126, 32,
		"SecondaryButton", { action = "back" } )
	kids[#kids + 1] = button( "Close", "CLOSE", StyleGui.W - 150, fy, 126, 32,
		"StyledButtonLarge", { action = "close" } )

	return root
end
