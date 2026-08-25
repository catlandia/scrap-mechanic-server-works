-- Crowd -- a lobby full of builders, when there is no lobby.
--
-- Asked for as: "we need to start testing the mod optimitsation for players. the
-- issue is... we dont have real players. how can we have many players. without
-- actual people?"
--
-- The honest answer is that you cannot have many PLAYERS. What you can have is
-- most of what a player costs the server, and the value of this file depends
-- entirely on being clear about which parts those are. docs/CROWD.md has the
-- long version; the short version is the table it opens with:
--
--   a human capsule stepped by the physics every tick      -- YES, this file
--   a character replicated to every client every tick      -- YES, this file
--   bodies appearing and disappearing while people build   -- YES, this file
--   our own per-player Lua: occupancy, resolver, budgets   -- YES, this file
--   a real client connection with its own network budget   -- NO. Needs a guest.
--   a second machine's render load                         -- NO. Ever.
--
-- The last two are why /crowd is not a substitute for one real guest joining
-- once. The engine's own per-client send budget -- the thing that writes
-- "NetworkServer.cpp:231 Skip sending unreliable network data to client <id>
-- Budget is currently: -280930" into the log -- is only ever computed for a
-- REMOTE client. It never fires for the host's own loopback, in any of the 150
-- logs in this install. So no amount of crowd measures it, and because the
-- budget is per-client and independent, ONE guest measures it as well as twenty
-- would.
--
--
-- WHY BOTS AND NOT FAKE PLAYER RECORDS
--
-- The per-player work in this mod is not a loop over a player list, it is a loop
-- over where people are STANDING -- sv_locate, sv_zoneKey, sv_holdNearby,
-- sv_authorised, and the push-out. Feeding that fake records at fake positions
-- would exercise the arithmetic and none of the geometry, and the geometry is
-- where every plot bug this project has had actually lived.
--
-- So the crowd hands Plots real characters at real positions
-- (sv_occupants below, consumed by Plots.sv_updateOccupancy) and the pass does
-- its true work. The only fabricated part is the identity string.

Crowd = class( nil )

-- The character we ship. Declared in
-- mod/Characters/Database/CharacterSets/serverworks.characterset; see that file
-- for why it is our own rather than one of vanilla's human NPCs.
Crowd.BOT_UUID = "d465d7f2-c705-481d-8010-d3455839beed"

-- A ceiling that is not a taste call: 384 plots is the largest city this mod can
-- lay out, and a bot per plot past that would be measuring the crowd rather than
-- the city. It is also a guard against a typo -- "/crowd 500" should be refused,
-- not attempted.
Crowd.MAX = 128

-- Perma ids are prefixed so that a leftover claim from a crashed session can be
-- recognised and swept at world create. Nothing else in the mod produces a perma
-- containing a colon.
Crowd.PERMA = "crowdbot:"

-- Ticks between one bot's build actions, at 40 Hz -- three to eight seconds.
-- Randomised per bot for the same reason BotUnit randomises its turns, and wide
-- because the whole crowd shares one rate: 128 bots on a 1.5s timer would be 85
-- imports a second, which is four times what twenty real builders manage.
Crowd.BUILD_MIN, Crowd.BUILD_MAX = 120, 320

function Crowd.sv_onCreate( self, plots )
	self.plots = plots
	self.bots = {}
	-- BUILD BY DEFAULT.
	--
	-- It used to default to "off", and the first real run of it was reported as
	-- "not building" -- correctly, because nobody had typed /crowd mode build and
	-- nothing said they had to. A crowd of bots standing still is not what this
	-- exists for; "the bots build stuff on their plot and only on it on random"
	-- is. Standing still is the special case, so it is the one you ask for.
	self.mode = "build"
	self.claim = false
	self.spawned = 0
	self.failed = 0

	-- Sweep claims left behind by a session that did not get to clear its own.
	-- Cheap, runs once, and without it a crashed stress test would leave plots
	-- owned by nobody who can ever log in to release them.
	self:sv_releaseClaims()
end

function Crowd.sv_permaFor( self, n )
	return Crowd.PERMA .. tostring( n )
end

function Crowd.sv_releaseClaims( self )
	if self.plots == nil or self.plots.owners == nil then return 0 end
	local freed = 0
	-- Collected first: sv_release mutates self.owners, which is the table being
	-- walked, and Lua 5.1's next() is undefined across a modification.
	local stale = {}
	for _, perma in pairs( self.plots.owners ) do
		if type( perma ) == "string" and perma:sub( 1, #Crowd.PERMA ) == Crowd.PERMA then
			stale[#stale + 1] = perma
		end
	end
	for _, perma in ipairs( stale ) do
		if pcall( function() self.plots:sv_release( perma ) end ) then
			freed = freed + 1
		end
	end
	return freed
end

-- Claim a plot for every bot already standing on one.
--
-- Needed because /crowd claim on can be typed AFTER the bots are out, and
-- without this the status line would say "claim ON" over a city where nothing
-- was claimed -- which is exactly the kind of quietly-wrong readout that makes a
-- measurement worthless.
function Crowd.sv_applyClaims( self )
	local claimed = 0
	for _, bot in ipairs( self.bots ) do
		if bot.plot and self.plots.owners[bot.plot] == nil then
			-- Allowed to fail: a real player may own it, and taking a plot off
			-- somebody is the worst thing a test tool could do.
			if pcall( function() self.plots:sv_claim( bot.plot, bot.perma ) end ) then
				claimed = claimed + 1
			end
		end
	end
	return claimed
end

-- Every index that is actually a plot, in order. sv_counts' total counts GRID
-- CELLS, and the plaza cells among them are not plots -- placing a bot on one
-- would put it on public ground and quietly stop the crowd testing plot
-- ownership at all. Cached: the layout only changes on a rebuild.
function Crowd.sv_plotIndices( self )
	if self.indices and self.indicesFor == self.plots.layout then
		return self.indices
	end
	local out = {}
	local layout = self.plots.layout
	-- layout.cols and layout.rows are the SEGMENT LISTS, not counts -- they hold
	-- roads and fillers as well as plots. The cell counts are on layout.cfg.
	for i = 1, layout.cfg.cols * layout.cfg.rows do
		if Layout.plotExists( layout, i ) then out[#out + 1] = i end
	end
	self.indices, self.indicesFor = out, layout
	return out
end

--------------------------------------------------------------------------------
-- Spawning
--------------------------------------------------------------------------------

-- Where bot n stands. One per plot, in plot order, so the crowd spreads over the
-- city instead of piling onto the spawn -- twenty capsules in one place is a
-- physics contact problem and nothing like twenty people on twenty plots.
function Crowd.sv_placeFor( self, n )
	if self.plots == nil or self.plots.layout == nil then return nil, nil end

	local indices = self:sv_plotIndices()
	local total = #indices
	if total <= 0 then return nil, nil end

	local index = indices[ ( ( n - 1 ) % total ) + 1 ]
	local at = self.plots:sv_plotWorldCentre( index )
	if at == nil then return nil, nil end

	-- More than one bot per plot once the crowd is larger than the city: nudge
	-- them apart so they are not spawned inside each other.
	local ring = math.floor( ( n - 1 ) / total )
	if ring > 0 then
		local angle = ( n * 2.399963 )        -- golden angle, so rings do not line up
		at = at + sm.vec3.new( math.cos( angle ) * ring * 0.6,
			math.sin( angle ) * ring * 0.6, 0 )
	end

	return at, index
end

function Crowd.sv_spawnOne( self, n )
	local at, index = self:sv_placeFor( n )
	if at == nil then return nil end

	local ok, unit = pcall( sm.unit.createUnit,
		sm.uuid.new( Crowd.BOT_UUID ), at, 0,
		{ home = at, roam = 2.5 } )

	if not ok or unit == nil then
		self.failed = self.failed + 1
		if self.failed == 1 then
			-- Once, not per bot. The most likely cause by a distance is the
			-- character set not being loaded at all, in which case every one of
			-- them fails identically and twenty lines say nothing extra.
			sm.log.warning( "[ServerWorks] crowd spawn failed (character "
				.. Crowd.BOT_UUID .. "): " .. tostring( unit ) )
		end
		return nil
	end

	local perma = self:sv_permaFor( n )
	local bot = {
		n = n, unit = unit, perma = perma, plot = index, home = at,
		-- blocks is a LIST: build mode accumulates, and every one of them has to
		-- be findable again at /crowd off or the city keeps what a test left.
		nextBuild = 0, blocks = {}, height = {}, pad = nil,
		-- What this one builds. Fixed for its lifetime, so a tower stays a
		-- tower -- a bot that re-rolled every block would just be scatter with
		-- extra steps.
		style = Crowd.STYLES[ math.random( 1, #Crowd.STYLES ) ],
	}

	if self.claim and index then
		-- Deliberately allowed to fail: the plot may already be claimed by a
		-- real player, and taking it off them would be the worst possible
		-- behaviour for a test tool.
		pcall( function() self.plots:sv_claim( index, perma ) end )
	end

	return bot
end

-- Grow or shrink the crowd to exactly n.
function Crowd.sv_set( self, n, opts )
	opts = opts or {}
	if opts.mode ~= nil then self:sv_setMode( opts.mode ) end
	if opts.claim ~= nil then self.claim = opts.claim end

	n = math.max( 0, math.min( Crowd.MAX, math.floor( n or 0 ) ) )
	self.failed = 0

	while #self.bots > n do
		self:sv_despawnOne( #self.bots )
	end

	while #self.bots < n do
		local bot = self:sv_spawnOne( #self.bots + 1 )
		if bot == nil then break end       -- stop at the first failure, do not spin
		self.bots[#self.bots + 1] = bot
	end

	self.spawned = #self.bots
	return self.spawned, self.failed
end

function Crowd.sv_despawnOne( self, i )
	local bot = self.bots[i]
	if bot == nil then return end

	self:sv_dropBlocks( bot )

	if bot.unit and sm.exists( bot.unit ) then
		pcall( function() bot.unit:destroy() end )
	end
	if self.claim then
		pcall( function() self.plots:sv_release( bot.perma ) end )
	end

	table.remove( self.bots, i )
end

function Crowd.sv_clear( self )
	local had = #self.bots
	while #self.bots > 0 do
		self:sv_despawnOne( #self.bots )
	end
	-- Belt and braces: sv_despawnOne only releases when self.claim is set, and
	-- the flag may have been turned off between spawning and clearing.
	self:sv_releaseClaims()
	self.spawned = 0
	return had
end

--------------------------------------------------------------------------------
-- What Plots needs
--------------------------------------------------------------------------------
--
-- Real characters at real positions, which is the whole point -- see the header.
-- Returned as a plain list rebuilt each tick rather than kept live, because a
-- unit can be destroyed by anything at any time and a stale character handle in
-- the occupancy pass would fault the patrol.

function Crowd.sv_occupants( self )
	if #self.bots == 0 then return nil end
	local out = {}
	for _, bot in ipairs( self.bots ) do
		if bot.unit and sm.exists( bot.unit ) then
			local character = bot.unit.character
			if character and sm.exists( character ) then
				out[#out + 1] = { character = character, perma = bot.perma }
			end
		end
	end
	return out
end

--------------------------------------------------------------------------------
-- Work -- the part that makes it a BUILDING event rather than a crowd
--------------------------------------------------------------------------------
--
-- Two modes, because they answer two different questions and mixing them answers
-- neither.
--
-- CHURN: put one block down, take it away again, repeat. Steady state -- the
-- world never grows. What it isolates is the PER-CHANGE cost: a body created, the
-- protection patrol classifying it, the rules audit counting it, the part budget
-- re-totalled, every client told. Use it when you want a clean "what does one
-- more builder cost", because every stage of a /bench run is measured against
-- the same amount of world.
--
-- BUILD: stack blocks up on your own plot and LEAVE THEM. The owner's idea, and
-- the better test of the two:
--
--     "we take the city. and the bots. the bots stand on their plots. and build
--      up with various blocks. this will make them build."
--
-- It is better because accumulated content is the thing that actually degraded
-- in the one real event on record -- client frame rate slid for a hundred
-- minutes while the player count sat flat at 19. Churn can never reproduce that,
-- by construction: it puts back exactly what it takes away. A city that grows
-- for twenty minutes is the only shape of test that can.
--
-- The cost is that a build-mode /bench row confounds two variables -- stage 4
-- has more bots AND more world than stage 3. That is exactly what an event looks
-- like, and exactly what you cannot attribute. Run both.
--
--
-- WHAT A BOT BUILDS IS NOT WELDED, AND THAT MATTERS
--
-- Every block a bot places is its OWN BODY. There is no way around it: blocks
-- weld only when the engine's own build tool places them next to something, and
-- Lua cannot reach that -- the Body binding list has no createPart and no
-- createBlock, only sm.body.createBody. sm.creation.importFromString, which is
-- what this uses, always makes a fresh creation.
--
-- So a bot's tower is N bodies where a player's tower is one, and the two load
-- the server in OPPOSITE directions:
--
--   a player's welded tower   1 body, N shapes    -- cheap to patrol,
--                                                    expensive to REBUILD:
--                                                    change one block and the
--                                                    whole body is reprocessed
--   a bot's stack             N bodies, N shapes  -- no rebuild cost at all,
--                                                    but the protection patrol
--                                                    walks every body, every
--                                                    cycle, forever
--
-- Neither is wrong; they are different halves of the same problem, and the
-- bot's half is the one this mod's own code pays for. Do not read a build-mode
-- run as "this is what twenty players building would do" -- read it as "this is
-- what the patrol and the renderer do against this much content".

Crowd.MODES = { off = true, churn = true, build = true }

-- Per bot, so a long run cannot fill the world without end. 40 blocks x 128 bots
-- is over five thousand bodies, which is already well past anything this project
-- has measured.
Crowd.MAX_BLOCKS = 40

-- How high one column may go. Without it the random walk eventually produces a
-- needle, which is neither what a build looks like nor what it costs.
Crowd.MAX_STACK = 8

-- Placements per tick across the WHOLE crowd. Per-bot timers are randomised so
-- they should never all land together, but "should never" is not a guarantee and
-- a thundering herd of imports would show up as a spike the run would blame on
-- the bot count.
Crowd.PLACE_PER_TICK = 2

function Crowd.sv_setMode( self, mode )
	if not Crowd.MODES[mode] then return false end
	self.mode = mode
	return true
end

function Crowd.sv_stepWork( self, tick, importBlueprint )
	if self.mode == "off" or importBlueprint == nil then return end

	local budget = Crowd.PLACE_PER_TICK
	for _, bot in ipairs( self.bots ) do
		if budget <= 0 then break end
		if tick >= bot.nextBuild then
			bot.nextBuild = tick + math.random( Crowd.BUILD_MIN, Crowd.BUILD_MAX )
			if self.mode == "churn" and #bot.blocks > 0 then
				self:sv_dropBlocks( bot )
			elseif #bot.blocks < Crowd.MAX_BLOCKS then
				if self:sv_placeBlock( bot, importBlueprint ) then
					budget = budget - 1
				end
			end
		end
	end
end

-- The buildable square of a bot's own plot, in blocks, inset by the metal ring.
-- Cached per bot: it cannot change without the city being rebuilt, and that
-- clears the crowd anyway.
function Crowd.sv_padFor( self, bot )
	if bot.pad ~= nil then return bot.pad end
	if bot.plot == nil then return nil end

	local layout = self.plots.layout
	local col, row = Layout.plotColRow( layout, bot.plot )
	if col == nil then return nil end
	local r = Layout.plotRect( layout, col, row )
	if r == nil then return nil end

	local b = Plots.BORDER
	if r.w <= b * 2 or r.h <= b * 2 then
		bot.pad = { x = r.x, y = r.y, w = r.w, h = r.h }
	else
		bot.pad = { x = r.x + b, y = r.y + b, w = r.w - b * 2, h = r.h - b * 2 }
	end
	return bot.pad
end

-- WHAT a bot builds, not just where.
--
-- "so like a lot of random bots. make random stuff."
--
-- Every bot picking a uniformly random cell produces the same thing twenty
-- times: an even lumpy blob the size of the plot. That is one shape, tested
-- twenty times over. A real lobby produces towers, walls, floors and mess, and
-- those differ in the ways that matter here -- a tower is tall and thin and
-- touches few cells, a platform is wide and flat and touches all of them, and
-- the two load cell streaming and frustum culling quite differently even at the
-- same block count.
--
-- The style only chooses the CELL. Height, material and colour stay random
-- underneath it, so no two bots of the same style build the same thing either.
Crowd.STYLES = { "scatter", "tower", "wall", "platform" }

-- Where this bot's next block goes, in blocks. Returns nil if the style has
-- nowhere left to put one.
function Crowd.sv_cellFor( self, bot, pad )
	local style = bot.style

	if style == "tower" then
		-- A quarter of the pad, in the middle, so it goes up rather than out.
		local w = math.max( 1, math.floor( pad.w / 4 ) )
		local h = math.max( 1, math.floor( pad.h / 4 ) )
		local x0 = pad.x + math.floor( ( pad.w - w ) / 2 )
		local y0 = pad.y + math.floor( ( pad.h - h ) / 2 )
		return x0 + math.random( 0, w - 1 ), y0 + math.random( 0, h - 1 )
	end

	if style == "wall" then
		-- One line, fixed for this bot's lifetime, so the wall stays a wall.
		-- The offset is drawn against the axis it actually indexes -- an earlier
		-- version rolled a second, unrelated coin to pick which dimension bounded
		-- it and then leaned on a clamp to stay inside. Harmless while plots are
		-- square, which they are by construction, and a trap the day one is not.
		if bot.wall == nil then
			local axis = math.random( 0, 1 )
			local span = ( axis == 0 ) and pad.w or pad.h
			bot.wall = { axis = axis, at = math.random( 0, span - 1 ) }
		end
		if bot.wall.axis == 0 then
			return pad.x + bot.wall.at, pad.y + math.random( 0, pad.h - 1 )
		end
		return pad.x + math.random( 0, pad.w - 1 ), pad.y + bot.wall.at
	end

	if style == "platform" then
		-- Best of three: the lowest of a few candidates, which fills a floor
		-- before it starts a second storey without needing to scan the pad.
		local bx, by, best
		for _ = 1, 3 do
			local cx = pad.x + math.random( 0, pad.w - 1 )
			local cy = pad.y + math.random( 0, pad.h - 1 )
			local stack = bot.height[cx .. "," .. cy] or 0
			if best == nil or stack < best then
				bx, by, best = cx, cy, stack
			end
		end
		return bx, by
	end

	-- scatter: anywhere on the pad. The uneven default.
	return pad.x + math.random( 0, pad.w - 1 ),
		pad.y + math.random( 0, pad.h - 1 )
end

function Crowd.sv_placeBlock( self, bot, importBlueprint )
	local pad = self:sv_padFor( bot )
	if pad == nil then return false end

	-- Stacked on whatever is already at that cell. A height map rather than a
	-- fixed pattern because a real build is uneven, and an even slab is a
	-- different render and physics shape from a lumpy one.
	local bx, by = self:sv_cellFor( bot, pad )
	if bx == nil then return false end
	local key = bx .. "," .. by

	local stack = bot.height[key] or 0
	if stack >= Crowd.MAX_STACK then return false end

	local bz = Plots.DECK_Z + 1 + stack

	-- VARIOUS BLOCKS, which was the point of the request. All 25 materials and
	-- all 40 paint-tool colours are in play, so the run exercises the whole
	-- shapeset and the whole palette rather than one repeated block -- different
	-- materials mean different textures and different draw batches, which is the
	-- half of this that lands on the renderer.
	local mat = Palette.MATERIAL_ORDER[math.random( 1, #Palette.MATERIAL_ORDER )]
	local hue = Palette.COLOUR_ORDER[math.random( 1, #Palette.COLOUR_ORDER )]
	local uuid = Palette.MaterialUuid( mat )
	local colour = Palette.Hex( hue )
	if uuid == nil or colour == nil then return false end

	local bp = Plots.Blueprint{ Plots.Child( uuid, colour, bx, by, bz, 1, 1, 1 ) }
	local bodies = importBlueprint( bp )
	if not ( bodies and bodies[1] ) then return false end

	bot.height[key] = stack + 1
	bot.blocks[#bot.blocks + 1] = bodies[1]
	return true
end

-- Everything this bot built. Called on despawn, on /crowd off, and by churn
-- mode every other action.
function Crowd.sv_dropBlocks( self, bot )
	for _, body in ipairs( bot.blocks ) do
		if sm.exists( body ) then
			-- destroyCreation rather than a permission flag: script-side
			-- destruction ignores every flag, which is what lets this work while
			-- the world is locked. Same reason /purge and the Cleaner can remove
			-- a carryable prop.
			pcall( function() body:destroyCreation() end )
		end
	end
	bot.blocks = {}
	bot.height = {}
end

function Crowd.sv_blockCount( self )
	local n = 0
	for _, bot in ipairs( self.bots ) do n = n + #bot.blocks end
	return n
end

--------------------------------------------------------------------------------

function Crowd.sv_onFixedUpdate( self, tick, importBlueprint )
	if #self.bots == 0 then return end

	-- Forget bots the engine has taken away underneath us -- a cell unload, a
	-- /restore, anything. Walked backwards so the removal is safe.
	for i = #self.bots, 1, -1 do
		local bot = self.bots[i]
		if bot.unit == nil or not sm.exists( bot.unit ) then
			bot.unit = nil
			self:sv_despawnOne( i )
		end
	end

	self:sv_stepWork( tick, importBlueprint )
	self.spawned = #self.bots
end

function Crowd.sv_status( self )
	local styles = {}
	for _, bot in ipairs( self.bots ) do
		styles[bot.style] = ( styles[bot.style] or 0 ) + 1
	end
	return {
		count = #self.bots,
		mode = self.mode,
		styles = styles,
		claim = self.claim,
		blocks = self:sv_blockCount(),
		failed = self.failed,
	}
end
