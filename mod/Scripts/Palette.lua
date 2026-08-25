-- Palette -- the blocks and the colours the city can be built out of.
--
-- Asked for as: "for style because I dont like brutalist that much. change the
-- concrete to green carpet... no screw that. make a choice for blocks. so you
-- can select custom blocks for the city foundation for style. and also their
-- colour bassed on the in game paint tool pallete."
--
-- Pure data and pure functions. No sm.* calls, so dev/test_logic.py can run the
-- whole thing outside the game.
--
--
-- THE COLOURS ARE THE PAINT TOOL'S OWN, AND THEY ARE NOT IN ANY DATA FILE
--
-- MEASURED, out of the executable. Data/Gui/Layouts/Tool/Tool_PaintTool.layout
-- is twenty lines and declares one empty widget called "ColorGrid" -- the
-- swatches are filled in engine-side, so there is nothing in Data/ or Survival/
-- to read. Nor are they stored as text: the interned hex strings in the string
-- table are the SHAPESET colours (that is where 8d8f89, our old concrete, comes
-- from), sorted alphabetically, which is a different list entirely.
--
-- They are stored as BGRA, one uint32 each, in a 40-entry run terminated by
-- zeros at file offset 0x13e9b90 of Release/ScrapMechanic.exe. dev/dump_api.py
-- has the recipe; the short version is to read four bytes per swatch and take
-- the first three in reverse.
--
-- Four rows of ten, exactly as the tool draws them: a greyscale column and then
-- nine hues, each in four shades. df7f00 in there is the default orange every
-- new block is painted, and 4a4a4a is what this mod was already using for its
-- metal 3 -- both of which is how the run was confirmed to be the right one.
--
-- Re-derive it after a game update. The offset will move; the terminator and the
-- known values will not.

Palette = {}

-- Row order is the tool's: pale, bright, deep, dark.
-- Column order is the tool's: greyscale, then nine hues.
Palette.HUES = { "grey", "yellow", "lime", "green", "cyan",
                 "blue", "purple", "pink", "red", "orange" }

Palette.ROWS = {
	{ "eeeeee", "f5f071", "cbf66f", "68ff88", "7eeded",
	  "4c6fe3", "ae79f0", "ee7bf0", "f06767", "eeaf5c" },
	{ "7f7f7f", "e2db13", "a0ea00", "19e753", "2ce6e6",
	  "0a3ee2", "7514ed", "cf11d2", "d02525", "df7f00" },
	{ "4a4a4a", "817c00", "577d07", "0e8031", "118787",
	  "0f2e91", "500aa6", "720a74", "7c0000", "673b00" },
	{ "222222", "323000", "375000", "064023", "0a4444",
	  "0a1d5a", "35086c", "520653", "560202", "472800" },
}

-- What each row is called when it is prefixed onto a hue. The grey column reads
-- badly that way -- "palegrey" for white is nonsense -- so it gets its own names.
local SHADE = { "pale", "", "deep", "dark" }
local GREY = { "white", "grey", "darkgrey", "black" }

-- name -> hex, and the order they cycle in on the settings panel.
Palette.COLOURS = {}
Palette.COLOUR_ORDER = {}

for r, row in ipairs( Palette.ROWS ) do
	for c, hex in ipairs( row ) do
		local name = ( c == 1 ) and GREY[r] or ( SHADE[r] .. Palette.HUES[c] )
		Palette.COLOURS[name] = hex
		Palette.COLOUR_ORDER[#Palette.COLOUR_ORDER + 1] = name
	end
end

-- Blocks that make a sensible floor. Every uuid here is read out of the
-- installed shapesets, and dev/check_uuids.py checks every uuid the mod names
-- against the install on each run -- so a block a future game version drops is
-- caught before the city tries to import a blueprint full of it.
--
--   Data/Objects/Database/ShapeSets/blocks.shapeset          the creative eleven
--   Survival/Objects/Database/ShapeSets/blocks.shapeset      the survival 36
--
-- Both load: baseGameContent decides which TOOL databases exist, not which
-- shapesets, and the city has been building out of a6c6ce30 -- a block declared
-- only in Data/ -- for every version that has had a city.
--
-- Ordered by what actually reads as a floor from above, because this is also the
-- order the settings panel cycles through.
Palette.MATERIAL_ORDER = {
	"concrete", "concrete2", "concrete3", "crackedconcrete", "concretetiles",
	"metal1", "metal2", "metal3", "metalbricks", "treadplate", "warehousefloor",
	"carpet", "fancycarpet", "tiles", "bricks", "wood", "wood2",
	"plastic", "plasticwall", "drywall", "spaceshipfloor", "scrapstone",
	"sand", "caution", "glass",
}

Palette.MATERIALS = {
	concrete        = { uuid = "a6c6ce30-dd47-4587-b475-085d55c6a3b4", label = "Concrete" },
	concrete2       = { uuid = "ff234e42-5da4-43cc-8893-940547c97882", label = "Concrete 2" },
	concrete3       = { uuid = "e281599c-2343-4c86-886e-b2c1444e8810", label = "Concrete 3" },
	crackedconcrete = { uuid = "f5ceb7e3-5576-41d2-82d2-29860cf6e20e", label = "Cracked concrete" },
	concretetiles   = { uuid = "cd0eff89-b693-40ee-bd4c-3500b23df44e", label = "Concrete tiles" },
	metal1          = { uuid = "8aedf6c2-94e1-4506-89d4-a0227c552f1e", label = "Metal 1" },
	metal2          = { uuid = "1016cafc-9f6b-40c9-8713-9019d399783f", label = "Metal 2" },
	metal3          = { uuid = "c0dfdea5-a39d-433a-b94a-299345a5df46", label = "Metal 3" },
	metalbricks     = { uuid = "220b201e-aa40-4995-96c8-e6007af160de", label = "Metal bricks" },
	treadplate      = { uuid = "f7d4bfed-1093-49b9-be32-394c872a1ef4", label = "Tread plate" },
	warehousefloor  = { uuid = "3e3242e4-1791-4f70-8d1d-0ae9ba3ee94c", label = "Warehouse floor" },
	carpet          = { uuid = "febce8a6-6c05-4e5d-803b-dfa930286944", label = "Carpet" },
	fancycarpet     = { uuid = "4ae689b2-b785-4cb9-94e6-6bbe10adf926", label = "Fancy carpet" },
	tiles           = { uuid = "8ca49bff-eeef-4b43-abd0-b527a567f1b7", label = "Tiles" },
	bricks          = { uuid = "0603b36e-0bdb-4828-b90c-ff19abcdfe34", label = "Bricks" },
	wood            = { uuid = "df953d9c-234f-4ac2-af5e-f0490b223e71", label = "Wood 1" },
	wood2           = { uuid = "1897ee42-0291-43e4-9645-8c5a5d310398", label = "Wood 2" },
	plastic         = { uuid = "628b2d61-5ceb-43e9-8334-a4135566df7a", label = "Plastic" },
	plasticwall     = { uuid = "e981c337-1c8a-449c-8602-1dd990cbba3a", label = "Plastic wall" },
	drywall         = { uuid = "b145d9ae-4966-4af6-9497-8fca33f9aee3", label = "Drywall" },
	spaceshipfloor  = { uuid = "4ad97d49-c8a5-47f3-ace3-d56ba3affe50", label = "Spaceship floor" },
	scrapstone      = { uuid = "30a2288b-e88e-4a92-a916-1edbfc2b2dac", label = "Scrap stone" },
	sand            = { uuid = "c56700d9-bbe5-4b17-95ed-cef05bd8be1b", label = "Sand" },
	caution         = { uuid = "09ca2713-28ee-4119-9622-e85490034758", label = "Caution" },
	glass           = { uuid = "5f41af56-df4c-4837-9b3c-10781335757f", label = "Glass" },
}

-- Every uuid the city could ever be made of. Plots.CITY_UUIDS is built from this
-- rather than from the materials currently selected: change the style and a city
-- built under the old one must still be recognised as city, or the cleaner
-- starts refusing to touch what it just stopped being able to identify.
function Palette.AllMaterialUuids()
	local out = {}
	for _, m in pairs( Palette.MATERIALS ) do out[m.uuid] = true end
	return out
end

function Palette.MaterialUuid( name )
	local m = Palette.MATERIALS[string.lower( tostring( name or "" ) )]
	return m and m.uuid or nil
end

function Palette.MaterialLabel( name )
	local m = Palette.MATERIALS[string.lower( tostring( name or "" ) )]
	return m and m.label or tostring( name )
end

-- WHOLE-CITY LOOKS, so choosing a style is one command rather than ten.
--
-- garden is the default and is the green carpet that was asked for before the
-- ask became "make a choice": a deep green pad in a dark metal frame. brutalist
-- is what the city looked like before any of this existed, in palette colours.
--
-- These write settings and nothing else. A style change does NOT restyle a city
-- that already stands -- the city is imported blueprints, and a blueprint is not
-- a live thing that can be repainted. Run BUILD CITY again.
Palette.STYLE_ORDER = { "garden", "brutalist", "boardwalk", "arctic", "warehouse", "neon" }

Palette.STYLES = {
	garden = {
		padblock = "carpet", padcolour = "deepgreen",
		borderblock = "metal2", bordercolour = "darkgrey",
		roadblock = "metal3", roadcolour = "black",
		plazablock = "metal3", plazacolour = "darkgrey",
		standblock = "metal3", standcolour = "black" },
	brutalist = {
		padblock = "concrete", padcolour = "grey",
		borderblock = "metal2", bordercolour = "darkgrey",
		roadblock = "metal3", roadcolour = "black",
		plazablock = "metal3", plazacolour = "darkgrey",
		standblock = "metal3", standcolour = "black" },
	boardwalk = {
		padblock = "wood2", padcolour = "deeporange",
		borderblock = "wood", bordercolour = "darkorange",
		roadblock = "concretetiles", roadcolour = "darkgrey",
		plazablock = "bricks", plazacolour = "deeporange",
		standblock = "wood", standcolour = "darkorange" },
	arctic = {
		padblock = "plasticwall", padcolour = "white",
		borderblock = "metal3", bordercolour = "palecyan",
		roadblock = "concrete3", roadcolour = "grey",
		plazablock = "tiles", plazacolour = "palecyan",
		standblock = "metal3", standcolour = "darkgrey" },
	warehouse = {
		padblock = "warehousefloor", padcolour = "grey",
		borderblock = "caution", bordercolour = "yellow",
		roadblock = "treadplate", roadcolour = "darkgrey",
		plazablock = "metalbricks", plazacolour = "darkgrey",
		standblock = "metal3", standcolour = "black" },
	neon = {
		padblock = "plastic", padcolour = "darkpurple",
		borderblock = "plastic", bordercolour = "pink",
		roadblock = "metal3", roadcolour = "black",
		plazablock = "plastic", plazacolour = "cyan",
		standblock = "metal3", standcolour = "darkpurple" },
}

-- A colour name, or a raw 6-digit hex so a host is never boxed in by the forty.
function Palette.Hex( name )
	local key = string.lower( tostring( name or "" ) )
	if Palette.COLOURS[key] then return Palette.COLOURS[key] end
	if string.match( key, "^%x%x%x%x%x%x$" ) then return key end
	return nil
end

-- The name for a hex, so a city built before this file existed can still say
-- what colour it is instead of printing a number.
function Palette.NameOfHex( hex )
	local key = string.lower( tostring( hex or "" ) )
	for _, name in ipairs( Palette.COLOUR_ORDER ) do
		if Palette.COLOURS[name] == key then return name end
	end
	return key
end

-- The five pieces of the city, in the order the style panel lists them, and
-- with names a host would recognise -- "pad" and "border" are what the code
-- calls them, not what they look like from the ground.
--
-- Plots.STYLE_PIECES is the same five keys in the same order. They are written
-- twice on purpose: the plot tests load Plots.lua WITHOUT Palette.lua, so a
-- load-time dependency between the two would break a dozen checks that have
-- nothing to do with styling. A check asserts the two lists never drift.
Palette.PIECES = {
	{ key = "pad",    label = "PLOT PAD",
	  help = "the buildable square in the middle of a plot" },
	{ key = "border", label = "PLOT FRAME",
	  help = "the ring welded round each plot" },
	{ key = "road",   label = "STREETS",
	  help = "the ground between the plots" },
	{ key = "plaza",  label = "SPAWN PLAZA",
	  help = "the square everybody arrives on" },
	{ key = "stand",  label = "STANDS",
	  help = "the column under each plot and under the plaza" },
}

-- "rrggbb" -> the "r g b a" string a json GUI widget wants.
--
-- The style panel draws the paint tool's own forty swatches at their own
-- colours, so the hex has to become floats somewhere. Here, because this file
-- is pure and dev/test_logic.py can therefore check the conversion without a
-- game. Anything unknown comes back white rather than nil: a widget handed nil
-- for Colour is a render error, and a white swatch is a visible bug rather than
-- a silent one.
function Palette.GuiColour( name, alpha )
	local hex = Palette.Hex( name )
	if hex == nil then return "1 1 1 1" end
	local r = tonumber( string.sub( hex, 1, 2 ), 16 ) / 255
	local g = tonumber( string.sub( hex, 3, 4 ), 16 ) / 255
	local b = tonumber( string.sub( hex, 5, 6 ), 16 ) / 255
	return string.format( "%.3f %.3f %.3f %.2f", r, g, b, alpha or 1 )
end
