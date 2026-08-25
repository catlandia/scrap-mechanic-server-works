-- BotCharacter -- the client half of a crowd bot. It gives the bot its name.
--
-- That is the whole job now. What a bot LOOKS like is decided by which
-- characterset entry it was spawned from, not by anything here -- see the note
-- below, and mod/Characters/Database/CharacterSets/serverworks.characterset,
-- which dev/gen_characterset.py generates from vanilla's own mechanics.
--
--------------------------------------------------------------------------------
-- THE LOOKS ARE IN THE CHARACTERSET NOW, AND THIS FILE ONLY NAMES THINGS
--------------------------------------------------------------------------------
--
-- There used to be a whole wardrobe here -- ninety renderable paths and a
-- generator that assembled a unique outfit per bot, applied with
-- character:overrideRenderableList in client_onCreate.
--
-- MEASURED cost of that, straight off /bench:
--
--     0 bots   60.0 fps      10 bots  15.0 fps      20 bots  8 fps
--
-- Twenty-three extra bodies do not cost forty-five frames. The controlled
-- comparison was already in the logs: an earlier NINETY-FIVE bot run held 30 fps
-- while this very code was throwing, so every bot fell back to the
-- characterset's own outfit and they all shared one renderable set.
--
-- A fixed renderable list on a characterset entry is loaded once and shared by
-- every character using it. A list built per character is not shareable, and
-- twenty of them is twenty sets of meshes and textures the renderer cannot
-- batch. REPORTED as "fps is 8 when even on the event with a lot of builds and
-- REAL players the fps was higer" -- which is the right comparison and the right
-- conclusion: the harness had become the load.
--
-- Vanilla says it twice. overrideRenderableList is called in exactly ONE script
-- in the whole game, for ONE quest NPC. And vanilla's ten different-looking
-- mechanics are ten CHARACTERSET ENTRIES, each with a fixed list. Ours are
-- eleven, generated from those same lists by dev/gen_characterset.py.
--
-- What is left here is the name tag, which is a string and costs nothing.

local W = {}

W.FIRST = {
	"Rust", "Bolt", "Cog", "Sprocket", "Girder", "Piston", "Weld", "Rivet",
	"Scrap", "Tin", "Gear", "Crank", "Flange", "Gasket", "Torque", "Axle",
	"Hex", "Grommet", "Ratchet", "Spanner", "Anvil", "Forge", "Drift", "Chuck",
	"Wedge", "Shim", "Lathe", "Auger", "Ballast", "Camber", "Dowel", "Ferrule",
	"Jig", "Kerf", "Mandrel", "Nubbin", "Plumb", "Quill", "Reamer", "Swarf",
}

W.LAST = {
	"bucket", "hammer", "wrench", "grinder", "press", "driver", "clamp",
	"jack", "vice", "punch", "file", "chisel", "mallet", "caliper", "gauge",
	"tap", "die", "bit", "saw", "brace", "awl", "rasp", "burr", "hone",
}

-- An LCG with a half-swap between rounds. The swap is not decoration: an LCG is
-- affine over 2^32, so adjacent seeds move in lockstep and a small-n choice off
-- one bit comes out strictly alternating. That is how a 50/50 male/female split
-- came out MfMfMfMf -- see the run-counting check in dev/test_logic.py. Lua 5.1
-- has no bitwise operators, so exchanging the 16-bit halves is the cheapest step
-- that is not affine over the integers.
local function step( x )
	x = ( x * 1664525 + 1013904223 ) % 4294967296
	return ( x % 65536 ) * 65536 + math.floor( x / 65536 )
end

-- Closures, not a metatable class: setmetatable does not exist in a character
-- script's CALLBACK environment. Measured -- it is available while the chunk
-- runs and gone by the time client_onCreate is called, and zero of vanilla's
-- character scripts use it.
function W.Rng( seed )
	local s = ( seed or 0 ) % 4294967296
	for _ = 1, 3 do s = step( s ) end

	local r = {}

	function r.next( n )
		s = step( s )
		if n == nil or n <= 0 then return 0 end
		return math.floor( s / 65536 ) % n
	end

	function r.pick( list )
		if list == nil or #list == 0 then return nil end
		return list[ r.next( #list ) + 1 ]
	end

	return r
end

-- 960 combinations off 64 words. Handles rather than first names on purpose: a
-- bot must never be mistaken for somebody who actually joined, and
-- "Rustbucket_77" is unmistakable in a way that "Dave" is not.
function W.Name( seed )
	local rng = W.Rng( ( seed or 0 ) + 7777 )
	local first = rng.pick( W.FIRST )
	local last = rng.pick( W.LAST )
	return first .. last .. "_" .. tostring( rng.next( 90 ) + 10 )
end

-- Published for dev/test_logic.py, which can only reach globals. Nothing in this
-- file ever READS this name -- every reference is to the local W, because a
-- global in a character script is shared across instances that do not run on the
-- same thread.
Wardrobe = W

local warnedOnce = false

BotCharacter = class( nil )

function BotCharacter.client_onCreate( self )
	self.cl = {}

	local id = self.character and self.character.id
	if id == nil then return end

	self.cl.name = W.Name( id )

	-- The one cosmetic call left, and it is a string. setNameTag has exactly one
	-- vanilla caller (MechanicCharacter.lua:138) and it is guarded by
	-- `if sm.exists( player )` -- which reads as "name tags are a player feature".
	-- It is not: that guard is there because MechanicCharacter is the PLAYER's
	-- class and wants the player's own name. The call itself is on the character.
	local ok, err = pcall( function()
		self.character:setNameTag( self.cl.name )
	 end )
	if not ok and not warnedOnce then
		warnedOnce = true
		sm.log.warning( "[ServerWorks] crowd bot name tag failed: " .. tostring( err ) )
	end
end

-- A name tag does not survive a graphics reload, and re-applying one is a string
-- assignment. What is NOT done here any more is rebuilding a renderable list --
-- see the note at the top of this file for what that cost.
function BotCharacter.client_onGraphicsLoaded( self )
	if self.cl == nil or self.cl.name == nil then return end
	pcall( function() self.character:setNameTag( self.cl.name ) end )
end
