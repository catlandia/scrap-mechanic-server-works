-- BotUnit -- the server half of a crowd bot.
--
-- A crowd bot exists to cost the server what a player costs it: a human capsule
-- being stepped through the physics world every tick, and a character whose
-- position has to be replicated to every client. It is NOT trying to be a
-- convincing player. It does not build, it has no inventory, and it holds no
-- network connection -- see docs/CROWD.md for what that means the numbers do and
-- do not cover.
--
--
-- WHY THIS IS class( nil ) AND NOT class( BaseUnit )
--
-- Every vanilla unit inherits BaseUnit, which dofiles PatrolManager,
-- achievement_common and QuestActorManager and then guards most of its own body
-- with `if SurvivalGame then`. We are a CreativeGame, so those guards would all
-- take the false branch -- but the dofiles happen regardless, and the unit class
-- every human NPC actually uses, QuestActorUnit, calls
-- QuestManager.Sv_RegisterQuestUnit unconditionally in its server_onCreate.
-- QuestManager is not loaded by CreativeGame or CreativeBaseWorld -- checked,
-- neither dofiles it -- so inheriting the vanilla human unit would have thrown
-- on the very first spawn.
--
-- That is also why we ship our own character rather than spawning
-- unit_shipMechanic, which is the one human unit vanilla itself passes to
-- createUnit: its class is WarehouseLorenzoUnit, wired into the warehouse quest.
--
--
-- MOVEMENT IS DRIVEN, NOT PATHED
--
-- setMovementDirection / setMovementType / setFacingDirection are the three
-- calls every vanilla unit ends its update with (BabyWocUnit.lua:98-100), and
-- they take a DIRECTION rather than a destination -- the pathfinder is a
-- separate thing vanilla runs first to decide what direction to pass.
--
-- Driving them directly means no navmesh dependency and no Pathfinder cost,
-- which is the right trade here: the bot should cost what a PLAYER costs, and a
-- player is a direction and a movement type, not a path query. A bot that also
-- ran A* would make the crowd more expensive than the thing it stands in for,
-- which is the one way a load test can lie in the direction that matters.

BotUnit = class( nil )

-- How far a bot may drift from where it was put. A plot is 20 blocks at 0.25 m,
-- so 2.5 m keeps a bot on its own plot with room to move -- which is what makes
-- Plots.sv_updateOccupancy see it as somebody standing there.
local ROAM_RADIUS = 2.5

-- Ticks between heading changes, at 40 Hz.
local TURN_MIN, TURN_MAX = 20, 90

-- A PER-BOT GENERATOR, NOT math.random.
--
-- Same reason Wardrobe has one, and the reason is worth restating because this
-- is the copy that runs forty times a second. math.random is global state that
-- Layout and the plot shuffler both draw from. Whether a unit script shares a
-- Lua environment with the world script is not something this project has
-- established -- tool scripts demonstrably do not (see CLAUDE.md) -- and the
-- failure if they do is that the city you get depends on how many bots were
-- wandering while it was built. That is silent, and both cities look plausible.
--
-- Not worth finding out the hard way when the fix is six lines.
local function lcg( s )
	return ( s * 1664525 + 1013904223 ) % 4294967296
end

function BotUnit.server_onCreate( self )
	self.sv = {}
	self.saved = self.storage:load()
	if self.saved == nil then
		self.saved = {}
	end

	-- Where it was put. Params only arrive on the first spawn; after a cell
	-- reload the saved copy is the one still worth having.
	--
	-- Stored as three numbers rather than as a vec3: this goes through the
	-- engine's own serialiser, and sm types round-tripping through unit storage
	-- is not something this project has verified. Three numbers cannot be wrong.
	if self.params and self.params.home then
		local h = self.params.home
		self.saved.hx, self.saved.hy = h.x, h.y
	end
	self.saved.roam = ( self.params and self.params.roam ) or self.saved.roam or ROAM_RADIUS

	self.storage:save( self.saved )

	-- Seeded off the unit's own id so that twenty bots do not all turn on the
	-- same tick. A synchronised crowd is a measurably different network shape
	-- from a real one: the engine batches what changed this tick, so twenty bots
	-- moving in lockstep is one big packet where twenty people would be twenty
	-- small ones spread over half a second.
	self.sv.rng = lcg( lcg( ( self.unit.id or 1 ) % 4294967296 ) )
	self.sv.nextTurn = 0
	self.sv.dir = sm.vec3.new( 1, 0, 0 )
	self.sv.move = "stand"
end

-- 0 .. n-1, off the high bits (an LCG's low bits are its worst).
function BotUnit.sv_rand( self, n )
	self.sv.rng = lcg( self.sv.rng )
	return math.floor( self.sv.rng / 65536 ) % n
end

function BotUnit.server_onFixedUpdate( self )
	if not sm.exists( self.unit ) then return end
	local character = self.unit.character
	if not sm.exists( character ) then return end

	-- Re-issued every tick on purpose, turn or no turn. The engine treats these
	-- as the unit's intent for THIS tick rather than as a standing order --
	-- vanilla sets all three on every single update.
	-- HOME IS CAPTURED HERE, NOT AT CREATE, AND THAT IS THE FIX FOR "STILL
	-- FALLING OFF".
	--
	-- server_onCreate ran with self.unit.character not yet existing, and the
	-- spawn params either did not arrive or did not survive -- so hx stayed nil,
	-- the out-of-bounds branch below could never fire, and every bot wandered in
	-- a straight line until it walked off the edge of the city and onto the
	-- terrain. REPORTED with a screenshot of the whole crowd lined up along the
	-- horizon, which is exactly what an unbounded random walk looks like once
	-- the city runs out from under it.
	--
	-- The first tick on which the character exists is the earliest moment the
	-- bot's own position is knowable, and it is still the spawn point, so it is
	-- the right anchor. Belt and braces on top of the params, never instead of
	-- them: a bot restored after a cell reload keeps the saved value.
	if self.saved.hx == nil then
		local at = character.worldPosition
		self.saved.hx, self.saved.hy = at.x, at.y
		self.storage:save( self.saved )
	end

	local tick = sm.game.getCurrentTick()
	if tick >= self.sv.nextTurn then
		self:sv_pickHeading( character )
		self.sv.nextTurn = tick + TURN_MIN + self:sv_rand( TURN_MAX - TURN_MIN )
	end

	self.unit:setMovementDirection( self.sv.dir )
	self.unit:setMovementType( self.sv.move )
	self.unit:setFacingDirection( self.sv.dir )
end

function BotUnit.sv_pickHeading( self, character )
	local pos = character.worldPosition
	local hx, hy = self.saved.hx, self.saved.hy

	if hx then
		local away = sm.vec3.new( pos.x - hx, pos.y - hy, 0 )
		if away:length() > self.saved.roam then
			-- Out of bounds: walk back rather than pick freely. A bot that
			-- drifts once drifts forever, and the crowd ends up in a corner of
			-- the map measuring nothing.
			self.sv.dir = ( away * -1 ):safeNormalize( sm.vec3.new( 1, 0, 0 ) )
			self.sv.move = "walk"
			return
		end
	end

	local angle = self:sv_rand( 360 ) * math.pi / 180
	self.sv.dir = sm.vec3.new( math.cos( angle ), math.sin( angle ), 0 )

	-- A real builder stands still most of the time and moves in bursts. A crowd
	-- that walks constantly is both the wrong network shape and the wrong
	-- physics shape -- a standing capsule is not a moving one.
	local roll = self:sv_rand( 10 )
	self.sv.move = ( roll < 5 ) and "stand" or ( roll < 9 and "walk" or "sprint" )
end

-- Crowd.lua keeps the unit handles and destroys them itself, but a bot that has
-- somehow been orphaned still has to be removable -- and a unit is not a body,
-- so neither the Cleaner nor /purge reaches one.
function BotUnit.sv_e_swDespawn( self )
	if sm.exists( self.unit ) then
		self.unit:destroy()
	end
end
