-- BotCharacter -- the client half of a crowd bot: its name and its clothes.
--
-- Both are cosmetic, and both are here rather than on the server because both
-- are client-side calls in the only vanilla code that makes them:
--
--   character:setNameTag( name )          MechanicCharacter.lua:138, client_onCreate
--   character:overrideRenderableList( l ) GenericBuilderQuestCharacter.lua, cl_updateScrapperRends
--
-- setNameTag has exactly one caller in the whole game and it is guarded by
-- `if sm.exists( player )`, which reads as "name tags are a player feature". It
-- is not -- the guard is there because MechanicCharacter is the PLAYER's
-- character class and it wants the player's own name. The call itself is on the
-- character.
--
-- overrideRenderableList is the reverse: it is refused for a player character,
-- and the engine says so in as many words ("Tried to override the renderable
-- list of a player character. This is not allowed." -- in the executable's
-- string table next to the character bindings). A crowd bot is a unit, not a
-- player, so it is allowed.
--
--
-- THE SEED IS THE CHARACTER ID, WHICH MEANS NOTHING HAS TO BE SENT
--
-- A bot's whole appearance is a pure function of one integer (see Wardrobe), and
-- self.character.id is already the same number on the server and on every
-- client -- that is what makes it usable as a network handle in the first place
-- (BaseEnemyCharacter.lua:24 keys its compass markers on it). So there is no
-- client data to set, no event to send, and no ordering problem: a client that
-- loads the character late still computes the identical outfit.
--
-- Twenty bots therefore cost twenty integers of appearance traffic, which is to
-- say none. That matters for what this thing is FOR -- a crowd whose costume
-- system showed up in the network budget would be measuring itself.

--------------------------------------------------------------------------------
-- THE WARDROBE LIVES IN THIS FILE, AND IT HAS TO
--------------------------------------------------------------------------------
--
-- It was its own Scripts/Wardrobe.lua, loaded with
-- dofile( "$CONTENT_DATA/Scripts/Wardrobe.lua" ). MEASURED, and it does not
-- work: every bot threw
--
--     ERROR: ...BotCharacter.lua:46: attempt to call field 'Name' (a nil value)
--
-- thirty times in one session, while the engine's own log showed Wardrobe.lua
-- being found and compiled one line after BotCharacter.lua ("Raw cache miss!
-- Path: .../Scripts/Wardrobe.lua"). So the file WAS read, and the `Wardrobe`
-- global was a table -- indexing it succeeded -- but the functions defined in
-- the back half of it were not on it. Reported as "BOTS WORK! just without the
-- skins stuff", which is exactly right: the unit half is server-side and never
-- touched this, so the bots walked around wearing the characterset's fallback.
--
-- The tell was in vanilla all along. Twelve character scripts under
-- Survival/Scripts/game/characters/ call dofile, and **every one of them loads a
-- $SURVIVAL_DATA path**. Not one loads mod content. A character script is not a
-- Game or World script, and $CONTENT_DATA/dofile from inside one is not
-- something the base game ever does -- which by this project's own rule ("verify
-- against the game, not against memory") made it a guess, and it was wrong.
--
-- So the data is inlined. It is only ever used from here, it is pure, and
-- dev/test_logic.py loads THIS file to check it -- the `Wardrobe` global below
-- is what those checks drive.
--------------------------------------------------------------------------------

-- The wardrobe: what a crowd bot is called and what it is wearing.
--
-- Asked for as: "if they have their own player models. please make every bot
-- have like a name and a random clothing from all clothes aviable. like tf2
-- bots and stuff."
--
-- Pure data and pure functions -- no sm.* calls at all -- so dev/test_logic.py
-- can assemble every outfit outside the game and check each path against the
-- install. That matters more here than anywhere else in the mod: a renderable
-- path that does not exist is not a Lua error, it is a character that draws
-- wrong or not at all, and nothing in the log says so.
--
--
-- WHERE THE LIST CAME FROM
--
-- Enumerated off the install, not from memory:
-- Survival/Character/Char_Male/{Outfit,Head,Hair,Facialfeatures,Body}. Note the
-- directory really is called Char_Male and the FEMALE garments live inside it
-- too -- there is no Char_Female tree. The male/female split is in the file
-- NAME (char_male_*, char_female_*, char_shared_*), which is why this table is
-- keyed by sex rather than by folder.
--
-- The recipe is vanilla's, copied off npc_mechanics.json's own entries. A
-- mechanic there is:
--
--     char_male_tp.rend + char_male_tp_swim.rend + char_male_tp_npc_emote.rend
--     head, hair, [facial hair], jacket, gloves, pants, shoes, [backpack]
--
-- and nothing else. In particular there is NO bare-body renderable underneath;
-- each garment slot supplies its own skin. Survival/Character/Char_Male/Body/
-- holds the *bare* version of a slot (char_male_body_shoes = bare feet), which
-- is how GenericBuilderQuestCharacter undresses the scrapper one quest at a
-- time. Female has no bare pants/jacket/shoes at all, so a female bot must be
-- fully clothed in those three slots. This table encodes that by simply not
-- offering a bare option to anyone.
--
--
-- A HAT DOES NOT CARRY A HEAD, BUT IT DOES CARRY HAIR
--
-- Worth writing down because the one vanilla example suggests the opposite.
-- GenericBuilderQuestCharacter swaps the hat OUT for head+hair+facialhair as
-- the quest progresses, which reads as "a hat replaces the head". It does not.
-- char_male_outfit_farmer_hat.rend declares exactly two submeshes, Hat_mat and
-- Hathair_mat -- no skin, no eyes, no mouth. So the head is always needed.
--
-- The hair, though, is inside the hat: Hathair_mat is a full hair texture set.
-- Wearing both draws hair through the hat. So HAT EXCLUDES HAIR, and that is
-- the one combination rule this file has.
--
--
-- THE LOOK IS DERIVED FROM A SEED, NOT STORED
--
-- Which means the server sends a client one integer per bot instead of a
-- ten-string renderable list, and a bot looks the same to everybody and stays
-- the same across a rejoin, for free. Twenty bots is twenty integers.
--
-- The generator is a local LCG rather than math.random on purpose. math.random
-- is global state that the city builder and the plot shuffler both draw from,
-- and dressing a crowd must not move that sequence -- a "random" city that
-- changes depending on how many bots were spawned first would be a genuinely
-- horrible bug to find.

--------------------------------------------------------------------------------
-- THE WARDROBE IS A LOCAL, AND THAT IS THE WHOLE FIX
--------------------------------------------------------------------------------
--
-- MEASURED, twice, and the second measurement is what settled it.
--
-- Round one: the wardrobe was its own Scripts/Wardrobe.lua, loaded by dofile.
-- Every bot threw "attempt to call field 'Name' (a nil value)". The obvious
-- reading -- a character script cannot dofile mod content -- was wrong.
--
-- Round two: the wardrobe was moved INTO this file, four hundred lines above the
-- function that reads it, and the identical error came back:
--
--     ERROR: ...BotCharacter.lua:525: attempt to call field 'Name' (a nil value)
--          [Logic Task:25332]  [Logic Task:4764]  [Logic Task:22328]
--
-- That is decisive. The chunk plainly ran past the definitions -- BotCharacter
-- itself is declared a hundred lines BELOW them and the engine found it -- and
-- `Wardrobe` was still a table when it was indexed, or the error would have been
-- "index a nil value". So the table existed and was EMPTY.
--
-- The thread ids are the tell. They differ between bursts, and the bursts land
-- on the same timestamp: the engine runs this script per character instance, on
-- its own logic task, and `Wardrobe = {}` at the top of one instance's chunk
-- resets the shared global out from under another instance's callback. Twenty
-- bots spawning at once is twenty chunks racing one assignment.
--
-- So: the table is a LOCAL, captured as an upvalue by every function below it.
-- An upvalue belongs to the chunk that closed over it and no other instance can
-- reach it, let alone blank it. Nothing in this file reads the global.
--
-- The rule that follows, and it is not just about this file: **in a character or
-- unit script, shared data must be an upvalue, never a global.** Globals in this
-- environment are shared across instances that do not run on the same thread.
--------------------------------------------------------------------------------

local W = {}

local MALE_ANIM = "$GAME_DATA/Character/Char_Male/Animations/char_male_tp.rend"
local SWIM_ANIM = "$GAME_DATA/Character/Char_Male/Animations/char_male_tp_swim.rend"
local EMOTE_ANIM = "$SURVIVAL_DATA/Character/Char_Male/Animations/char_male_tp_npc_emote.rend"

-- Every bot gets these three, exactly as every vanilla mechanic NPC does.
W.BASE = { MALE_ANIM, SWIM_ANIM, EMOTE_ANIM }

local O = "$SURVIVAL_DATA/Character/Char_Male/Outfit/"
local H = "$SURVIVAL_DATA/Character/Char_Male/Head/"
local R = "$SURVIVAL_DATA/Character/Char_Male/Hair/"
local F = "$SURVIVAL_DATA/Character/Char_Male/Facialfeatures/"

-- Slots are listed in the order vanilla lists them. The order does not matter to
-- the engine -- overrideRenderableList takes a set -- but keeping it makes a
-- diff against npc_mechanics.json readable.
W.SLOTS = { "head", "hair", "facial", "jacket", "gloves", "pants", "shoes", "backpack", "hat" }

-- optional = the slot may come back empty. Everything else must produce a piece.
W.OPTIONAL = { facial = true, backpack = true, hat = true }

W.PIECES = {
	head = {
		male = {
			H .. "Male/char_male_head02/char_male_head02.rend",
			H .. "Male/char_male_head04/char_male_head04.rend",
			H .. "Male/char_male_head05/char_male_head05.rend",
			H .. "Male/char_male_head06/char_male_head06.rend",
			H .. "Male/char_male_head09/char_male_head09.rend",
			H .. "Male/char_male_head010/char_male_head010.rend",
			H .. "Male/char_male_head011/char_male_head011.rend",
		},
		female = {
			H .. "Female/Female_head02/char_female_head02.rend",
			H .. "Female/Female_head03/char_female_head03.rend",
			H .. "Female/Female_head04/char_female_head04.rend",
			H .. "Female/Female_head07/char_female_head07.rend",
			H .. "Female/Female_head08/char_female_head08.rend",
			H .. "Female/Female_head09/char_female_head09.rend",
			H .. "Female/Female_head010/char_female_head010.rend",
			H .. "Female/Female_head011/char_female_head011.rend",
		},
	},

	-- Vanilla puts female hair on male heads (mechanicmale1 wears
	-- char_female_hair_07), so the two lists are pooled rather than split.
	hair = {
		male = {
			R .. "Male/char_male_hair_02/char_male_hair_02.rend",
			R .. "Male/char_male_hair_03/char_male_hair_03.rend",
			R .. "Male/char_male_hair_04/char_male_hair_04.rend",
			R .. "Male/char_male_hair_05/char_male_hair_05.rend",
			R .. "Female/char_female_hair_02/char_female_hair_02.rend",
			R .. "Female/char_female_hair_04/char_female_hair_04.rend",
			R .. "Female/char_female_hair_05/char_female_hair_05.rend",
			R .. "Female/char_female_hair_07/char_female_hair_07.rend",
		},
		female = {
			R .. "Female/char_female_hair_02/char_female_hair_02.rend",
			R .. "Female/char_female_hair_04/char_female_hair_04.rend",
			R .. "Female/char_female_hair_05/char_female_hair_05.rend",
			R .. "Female/char_female_hair_07/char_female_hair_07.rend",
		},
	},

	-- Facial hair ships in a male set only. A female bot never gets this slot,
	-- which is why it is optional rather than empty-listed: an empty list would
	-- read as "the file went missing".
	facial = {
		male = {
			F .. "char_male_facialhair_03/char_male_facialhair_03.rend",
			F .. "char_male_facialhair_05/char_male_facialhair_05.rend",
			F .. "char_male_facialhair_06/char_male_facialhair_06.rend",
			F .. "char_male_facialhair_07/char_male_facialhair_07.rend",
			F .. "char_male_facialhair_08/char_male_facialhair_08.rend",
			F .. "char_male_facialhair_09/char_male_facialhair_09.rend",
			F .. "char_male_facialhair_11/char_male_facialhair_11.rend",
			F .. "char_male_facialhair_12/char_male_facialhair_12.rend",
			F .. "char_male_facialhair_13/char_male_facialhair_13.rend",
			F .. "char_male_facialhair_14/char_male_facialhair_14.rend",
		},
		female = {},
	},

	jacket = {
		male = {
			O .. "Jacket/Outfit_default_jacket/char_male_outfit_default_jacket.rend",
			O .. "Jacket/Outfit_farmer_jacket/char_male_outfit_farmer_jacket.rend",
			O .. "Jacket/Outfit_scrapper_jacket/char_male_outfit_scrapper_jacket.rend",
		},
		female = {
			O .. "Jacket/Outfit_default_jacket/char_female_outfit_default_jacket.rend",
			O .. "Jacket/Outfit_defaultdamaged_jacket/char_female_outfit_defaultdamaged_jacket.rend",
			O .. "Jacket/Outfit_farmer_jacket/char_female_outfit_farmer_jacket.rend",
		},
	},

	gloves = {
		male = {
			O .. "Gloves/Outfit_default_gloves/char_shared_outfit_default_gloves.rend",
			O .. "Gloves/Outfit_farmer_gloves/char_shared_outfit_farmer_gloves.rend",
			O .. "Gloves/Outfit_scrapper_gloves/char_male_outfit_scrapper_gloves.rend",
		},
		female = {
			O .. "Gloves/Outfit_default_gloves/char_shared_outfit_default_gloves.rend",
			O .. "Gloves/Outfit_farmer_gloves/char_shared_outfit_farmer_gloves.rend",
			O .. "Gloves/Outfit_farmhand_gloves/char_female_outfit_farmhand_gloves.rend",
		},
	},

	pants = {
		male = {
			O .. "Pants/Outfit_default_pants/char_male_outfit_default_pants.rend",
			O .. "Pants/Outfit_defaultdamaged_pants/char_male_outfit_defaultdamaged_pants.rend",
			O .. "Pants/Outfit_farmer_pants/char_male_outfit_farmer_pants.rend",
			O .. "Pants/Outfit_scrapper_pants/char_male_outfit_scrapper_pants.rend",
		},
		female = {
			O .. "Pants/Outfit_default_pants/char_female_outfit_default_pants.rend",
			O .. "Pants/Outfit_defaultdamaged_pants/char_female_outfit_defaultdamaged_pants.rend",
			O .. "Pants/Outfit_farmer_pants/char_female_outfit_farmer_pants.rend",
		},
	},

	shoes = {
		male = {
			O .. "Shoes/Outfit_default_shoes/char_male_outfit_default_shoes.rend",
			O .. "Shoes/Outfit_defaultdamaged_shoes/char_male_outfit_defaultdamaged_shoes.rend",
			O .. "Shoes/Outfit_engineer_shoes/char_male_outfit_engineer_shoes.rend",
			O .. "Shoes/Outfit_farmer_shoes/char_male_outfit_farmer_shoes.rend",
			O .. "Shoes/Outfit_scrapper_shoes/char_shared_outfit_scrapper_shoes.rend",
		},
		female = {
			O .. "Shoes/Outfit_default_shoes/char_female_outfit_default_shoes.rend",
			O .. "Shoes/Outfit_defaultdamaged_shoes/char_female_outfit_defaultdamaged_shoes.rend",
			O .. "Shoes/Outfit_engineer_shoes/char_female_outfit_engineer_shoes.rend",
			O .. "Shoes/Outfit_farmer_shoes/char_female_outfit_farmer_shoes.rend",
			O .. "Shoes/Outfit_scrapper_shoes/char_shared_outfit_scrapper_shoes.rend",
		},
	},

	-- Every backpack is char_shared_, so both sexes get the same eight.
	backpack = {
		male = {
			O .. "Backpack/Outfit_default_backpack/char_shared_outfit_default_backpack.rend",
			O .. "Backpack/Outfit_defaultdamaged_backpack/char_shared_outfit_defaultdamaged_backpack.rend",
			O .. "Backpack/Outfit_dekotora_backpack/char_shared_outfit_dekotora_backpack.rend",
			O .. "Backpack/Outfit_farmer_backpack/char_shared_outfit_farmer_backpack.rend",
			O .. "Backpack/Outfit_farmhand_backpack/char_shared_outfit_farmhand_backpack.rend",
			O .. "Backpack/Outfit_jetpack_backpack/char_shared_outfit_jetpack_backpack.rend",
			O .. "Backpack/Outfit_lumberjack_backpack/char_shared_outfit_lumberjack_backpack.rend",
			O .. "Backpack/Outfit_scrapper_backpack/char_shared_outfit_scrapper_backpack.rend",
		},
	},

	hat = {
		male = {
			O .. "Hat/Outfit_demolition_hat/char_shared_outfit_demolition_hat.rend",
			O .. "Hat/Outfit_farmer_hat/char_male_outfit_farmer_hat.rend",
			O .. "Hat/Outfit_golf_hat/char_male_outfit_golf_hat.rend",
			O .. "Hat/Outfit_lumberjack_hat/char_male_outfit_lumberjack_hat.rend",
			O .. "Hat/Outfit_scrapper_hat/char_male_outfit_scrapper_hat.rend",
		},
		female = {
			O .. "Hat/Outfit_demolition_hat/char_shared_outfit_demolition_hat.rend",
			O .. "Hat/Outfit_farmer_hat/char_female_outfit_farmer_hat.rend",
		},
	},
}

W.PIECES.backpack.female = W.PIECES.backpack.male

-- How often an optional slot is filled, out of 100.
local CHANCE = { facial = 55, backpack = 70, hat = 35 }

--------------------------------------------------------------------------------
-- Names
--------------------------------------------------------------------------------
--
-- Two halves joined, which gives 40 x 24 = 960 combinations off 64 words -- more
-- than enough that a 384-plot city can be filled without a repeat, and short
-- enough that they fit a nametag. Handles rather than real first names on
-- purpose: a bot must never be mistaken for a person who actually joined, and
-- "Rustbucket_77" is unmistakable in a way that "Dave" is not.

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

--------------------------------------------------------------------------------
-- Deterministic per-bot randomness
--------------------------------------------------------------------------------
--
-- Numerical Recipes' LCG constants, kept in 32 bits by hand. Lua 5.1 numbers are
-- doubles, so the multiply has to stay under 2^53 to be exact: 2^32 x 1664525 is
-- about 2^52.7, which just fits. Anything larger would silently start rounding
-- and the "deterministic" part would quietly stop being true on some platforms.
-- A PLAIN LCG IS NOT ENOUGH HERE, AND THE WAY IT FAILED IS WORTH KEEPING.
--
-- The first version was two LCG rounds and then bit 16 of the result. Over 200
-- seeds it produced a flawless 50/50 male/female split and passed the ratio
-- check. The SEQUENCE was:
--
--     M f M f M f M f M f M f M f M f M f f M
--
-- Perfect alternation. Two bots side by side could never be the same sex, which
-- is not what anyone means by random and is exactly what you would notice in a
-- crowd of five. REPORTED as "make sure gender is random too" -- and the ratio
-- test that was already there could not see it, because the ratio was right.
--
-- The cause is structural, not a tuning problem. An LCG is affine over 2^32, so
-- for adjacent seeds the low bits of the state move in lockstep -- and asking
-- for n = 2 uses exactly one bit. Mixing more LCG rounds does not help: the
-- composition of affine maps is affine.
--
-- Breaking it needs one step that is NOT affine over 2^32, and with no bitwise
-- operators in Lua 5.1 the cheapest is exchanging the 16-bit halves: a bit
-- permutation, linear over GF(2) but not over the integers, so composed with
-- the LCG neither structure survives. MEASURED over the same 24 seeds: 11 runs
-- instead of 23, where a fair coin averages 12. Within one generator, 22 runs
-- in 40. Buckets stay flat for n = 2, 3, 5 and 10, and the chance() gates land
-- within 0.2 points of where they are set.
local function step( x )
	x = ( x * 1664525 + 1013904223 ) % 4294967296
	return ( x % 65536 ) * 65536 + math.floor( x / 65536 )
end

local Rng = {}
Rng.__index = Rng

function W.Rng( seed )
	-- Three rounds before first use. One is not enough: adjacent seeds differ
	-- only in their low bits, and this is the point where a whole crowd's worth
	-- of generators are created from consecutive character ids.
	local s = ( seed or 0 ) % 4294967296
	for _ = 1, 3 do s = step( s ) end
	return setmetatable( { s = s }, Rng )
end

-- Returns 0 .. n-1, off the high half. The low bits of an LCG are its worst and
-- the half-swap is what stops "the high half" meaning the same thing every time.
function Rng.next( self, n )
	self.s = step( self.s )
	if n == nil or n <= 0 then return 0 end
	return math.floor( self.s / 65536 ) % n
end

function Rng.pick( self, list )
	if list == nil or #list == 0 then return nil end
	return list[ self:next( #list ) + 1 ]
end

function Rng.chance( self, percent )
	return self:next( 100 ) < percent
end

--------------------------------------------------------------------------------
-- The two things a bot needs
--------------------------------------------------------------------------------

function W.Name( seed )
	local rng = W.Rng( ( seed or 0 ) + 7777 )   -- a different stream to the outfit
	local first = rng:pick( W.FIRST )
	local last = rng:pick( W.LAST )
	return first .. last .. "_" .. tostring( rng:next( 90 ) + 10 )
end

function W.Sex( seed )
	return W.Rng( ( seed or 0 ) + 31 ):next( 2 ) == 0 and "male" or "female"
end

--------------------------------------------------------------------------------
-- The CLASSIC mechanic -- a second art path, on purpose
--------------------------------------------------------------------------------
--
-- "the skin stuff is imporant to test the handling of extra assets."
--
-- Right, and the modern set alone does not really test that: every garment above
-- lives under one directory tree, sharing one skeleton and one texture
-- convention. Data/Character/Char_Classic is a DIFFERENT set -- the original
-- mechanic, seven renderables that replace the whole body at once rather than
-- filling slots (head, chest, hands, feet, legs, hair, backpack; no jacket, no
-- pants, no shoes, because the chest and legs already are those).
--
-- It is also what Data/Character/CharacterSets/default.json dresses the PLAYER
-- in, so a classic bot is wearing exactly what a real player's character is
-- built from -- which is the closest this can get to "is a bot as expensive to
-- draw as a person".
--
-- ON SKIN COLOUR, since it was asked for directly: there is no skin-colour
-- channel to randomise. A head renderable carries its own skin -- open
-- char_male_head02.rend and the `skin` submesh points at
-- char_male_head02_dif.tga, its own texture. So the head IS the skin tone, and
-- picking a head at random IS picking a skin at random. Fifteen modern heads
-- plus two classic ones is seventeen, and every bot rolls one. There is no
-- setSkinColour to add; the only tint binding on a character is setColor, which
-- is what makes a totebot red, and on a human it would tint the whole model.
local C = "$GAME_DATA/Character/Char_Classic/"

W.CLASSIC = {
	male = {
		C .. "Char_classic_male/char_classic_male_head.rend",
		C .. "Char_classic_male/char_classic_male_chest.rend",
		C .. "Char_classic_male/char_classic_male_hands.rend",
		C .. "Char_classic_male/char_classic_male_feet.rend",
		C .. "Char_classic_male/char_classic_male_legs.rend",
		C .. "Char_classic_male/char_classic_male_hair.rend",
		C .. "Char_classic_male/char_classic_male_backpack.rend",
	},
	female = {
		C .. "Char_classic_female/char_classic_female_head.rend",
		C .. "Char_classic_female/char_classic_female_chest.rend",
		C .. "Char_classic_female/char_classic_female_hands.rend",
		C .. "Char_classic_female/char_classic_female_feet.rend",
		C .. "Char_classic_female/char_classic_female_legs.rend",
		C .. "Char_classic_female/char_classic_female_hair.rend",
		C .. "Char_classic_female/char_classic_female_backpack.rend",
	},
}

-- Roughly one bot in four. Common enough to be visible in a crowd of five,
-- rare enough that the modern set is still what is mostly being exercised.
local CLASSIC_CHANCE = 25

-- The hat is decided BEFORE the hair, whatever order the slots are listed in,
-- because the hair decision depends on it and the reverse is never true. Listed
-- separately from SLOTS so that the output order stays the readable one.
local DECIDE_ORDER = { "hat", "head", "hair", "facial", "jacket", "gloves", "pants", "shoes", "backpack" }

-- The whole look, as the renderable list overrideRenderableList wants.
-- Returns list, sex, and the per-slot choice, so a test can assert about slots
-- rather than having to parse paths back out of the list.
function W.Look( seed )
	local sex = W.Sex( seed )
	local rng = W.Rng( seed )
	local chosen = {}

	-- Rolled off its own stream so that adding or reweighting the classic set
	-- cannot shuffle every modern bot's outfit as a side effect. A crowd whose
	-- appearance changes wholesale on an unrelated edit is a crowd you cannot
	-- compare two runs of.
	if W.Rng( ( seed or 0 ) + 4241 ):chance( CLASSIC_CHANCE ) then
		chosen.style = "classic"
		local list = {}
		for _, r in ipairs( W.BASE ) do list[#list + 1] = r end
		for _, r in ipairs( W.CLASSIC[sex] ) do list[#list + 1] = r end
		return list, sex, chosen
	end
	chosen.style = "modern"

	for _, slot in ipairs( DECIDE_ORDER ) do
		local want

		if slot == "hair" then
			-- THE ONE COMBINATION RULE: Hathair_mat inside a hat renderable is
			-- a full hair texture set, so a hat worn over hair draws the hair
			-- through the hat. A bare head always gets hair.
			want = ( chosen.hat == nil )
		elseif W.OPTIONAL[slot] then
			want = rng:chance( CHANCE[slot] or 50 )
		else
			want = true
		end

		if want then
			chosen[slot] = rng:pick( W.PIECES[slot][sex] )
		end
	end

	local list = {}
	for _, r in ipairs( W.BASE ) do list[#list + 1] = r end
	for _, slot in ipairs( W.SLOTS ) do
		if chosen[slot] then list[#list + 1] = chosen[slot] end
	end

	return list, sex, chosen
end

-- Published for dev/test_logic.py, which can only reach globals. Nothing in
-- this file ever READS this name -- every reference above and below is to the
-- local W, which is the entire point of the note at the top.
Wardrobe = W

-- Log-once flag for the appearance guard below. A local, for the same reason the
-- wardrobe is one: a field on the class table is shared across every instance of
-- this script, and those do not run on the same thread. The cost of getting this
-- one wrong is only a few duplicate log lines, which is exactly why it would
-- never have been noticed.
local warnedOnce = false

BotCharacter = class( nil )

function BotCharacter.client_onCreate( self )
	self.cl = {}

	local id = self.character and self.character.id
	if id == nil then return end

	self.cl.seed = id
	self.cl.name = W.Name( id )

	-- Guarded and logged once rather than per character: a fault dressing a bot
	-- must not take out a session that is mid-measurement, and twenty bots
	-- failing the same way should be one line, not twenty.
	local ok, err = pcall( function()
		self.character:overrideRenderableList( ( W.Look( id ) ) )
		self.character:setNameTag( self.cl.name )
	end )
	if not ok and not warnedOnce then
		warnedOnce = true
		sm.log.warning( "[ServerWorks] crowd bot appearance failed: " .. tostring( err ) )
	end
end

-- The engine calls this on every graphics reload (a settings change, an alt-tab
-- on some drivers). The renderable override does NOT survive one -- that is why
-- GenericBuilderQuestCharacter re-applies its scrapper rends here too, with a
-- comment saying so in as many words -- so a bot that was not re-dressed would
-- silently revert to the characterset's fallback outfit and the crowd would
-- turn into twenty identical mechanics.
function BotCharacter.client_onGraphicsLoaded( self )
	if self.cl == nil or self.cl.seed == nil then return end
	pcall( function()
		self.character:overrideRenderableList( ( W.Look( self.cl.seed ) ) )
		self.character:setNameTag( self.cl.name )
	end )
end
