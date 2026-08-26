-- Focus -- one person, marked so the whole lobby can find them.
--
-- Asked for as: "with the tool you can search for nicknames that are curently
-- on the server. and when selected it will highlight them. so people can see
-- the focus person. usefull for event stuff."
--
-- This file is the HIGHLIGHT half and nothing else. Who is focused is server
-- state (Game.sv.focus); the panel and the tool that choose them are FocusGui
-- and FocusTool. Everything here runs on a client and draws.
--
--
-- WHY THIS IS DRIVEN FROM World.lua AND NOT FROM Game.lua
--
-- Same reason PlotMarker is, and it is measured. The compass turns a world
-- position into a bearing, so it needs a world, and a Game script has none:
--
--   WARNING: compass marker unavailable: PlotMarker.lua:72:
--            Calling world dependent functions in a no world script!
--
-- Going via the player script did not help either -- the same warning came back
-- verbatim. The world's own client is the one context that certainly has a
-- world, and it is where every vanilla caller of the compass lives. See
-- World.sv_setFocusFor / World.cl_n_swFocus.
--
--
-- THE THREE THINGS A MARKED PLAYER GETS, AND WHERE EACH ONE CAME FROM
--
--   1. A BILLBOARD OVER THEIR HEAD, drawn THROUGH walls at any distance.
--      Vanilla's own marker over a marked enemy is
--
--        sm.effect.createEffect( "EnemyMarker", self.character, nil, sm.effect.axis.all )
--        markEffect:setOffsetPosition( sm.vec3.new( 0, 0, self.character:getHeight() ) )
--
--      (Survival/.../characters/BaseEnemyCharacter.lua:16-18) -- host given at
--      creation, axis.all so the icon does not spin when the character turns,
--      and the offset lifted by the character's own height. That is copied
--      exactly. What is NOT copied is EnemyMarker itself: its
--      maxRenderDistance is 26 metres, which is useless across an event city.
--      Ours is in mod/Effects/Database/EffectSets/serverworks.effectset with
--      maxRenderDistance 1000000 and behindFadeAlpha 0.6, the numbers vanilla
--      uses for QuestMarker_Far -- the marker that points at a quest from
--      across the map.
--
--   2. THEIR NAME, in world text beside it. The one vanilla precedent for
--      runtime text in an effect is RaidMarkerNear, whose `text` element takes
--      setParameter( "TextContent", str ) (RaidManager.lua:1539). Our effectset
--      declares the same parameter the same way.
--
--   3. A COMPASS ICON, so somebody facing the wrong way knows which way to
--      turn. compassSetIconHost( name, character ) makes the icon follow a
--      character with no per-frame work at all -- BaseEnemyCharacter.lua:25 and
--      WorldMarkerManager.lua:285 both do exactly this.
--
--
-- FALLBACK, BECAUSE THE EFFECTSET IS THE ONE UNPROVEN PART
--
-- No effectset has ever shipped in this mod before. 87 Workshop mods ship one
-- and the Empty Custom Game template includes the folder, so the mechanism is
-- real -- but "real" is not "seen working here". So every create is pcall'd and
-- there is a fallback to QuestMarker_Far, which is base content and certainly
-- exists. Worst case the marker is a vanilla quest diamond with no name under
-- it; there is no case where this errors per frame.

Focus = {}

-- Ours first, vanilla second. QuestMarker_Far is Survival content -- see
-- Survival/Effects/Database/EffectSets/billboard.effectset -- and
-- baseGameContent is "Survival", so it is loaded.
Focus.MARKER_EFFECTS = { "ServerWorks - Focus", "QuestMarker_Far" }
Focus.NAME_EFFECT = "ServerWorks - FocusName"

Focus.COMPASS = "serverworks_focus"
-- NOT icon_compass_main_quest.png. That one is already the player's own plot
-- marker (PlotMarker.ICON), and two identical arrows on one compass would be
-- worse than no second arrow at all.
Focus.COMPASS_ICON = "icon_compass_side_quest.png"

-- How far above the character's own height each piece floats, in metres. The
-- icon sits clear of the head; the name sits just under the icon so the two
-- read as one label.
Focus.ICON_LIFT = 0.55
Focus.NAME_LIFT = 0.18

-- Retry cadence when a target is known but their character is not there yet --
-- a player who is still loading has player.character == nil for a second or
-- two. Half a second, so a marker that cannot be placed yet costs 2 attempts a
-- second rather than 40.
Focus.RETRY_TICKS = 20

local cl = {
	player = nil,        -- who we were told to mark
	name = nil,
	showName = true,     -- the host's `focusname`, sent with the target
	character = nil,     -- the character the live effects are bound to
	marker = nil,
	nameTag = nil,
	compass = false,
	nextTry = 0,
	tries = 0,           -- consecutive binds that produced nothing at all
	faulted = false,
	warnedNoEffect = false,
	warnedNoName = false,
}

-- How many binds that draw NOTHING before giving up. Cl_Step otherwise retries
-- for as long as somebody is focused, which on a client where neither effects
-- nor the compass are reachable is a pointless two calls a second forever.
Focus.MAX_TRIES = 5

-- Once, never per frame. The 1.79 GB single player log in CLAUDE.md is what a
-- client-side error per frame costs, and it is the largest performance bug this
-- project has measured.
local function guard( what, fn )
	if cl.faulted then return false end
	local ok, err = pcall( fn )
	if not ok then
		cl.faulted = true
		sm.log.warning( "[ServerWorks] focus marker unavailable (" .. what .. "): "
			.. tostring( err ) )
		return false
	end
	return true
end

local function destroyEffect( effect )
	if effect == nil then return end
	pcall( function()
		if sm.exists( effect ) then
			if effect:isPlaying() then effect:stop() end
			effect:destroy()
		end
	end )
end

-- Every effect this file has ever made, gone, and the compass icon with it.
-- Called on clear, on retarget, and on a character changing under us.
local function tearDown()
	destroyEffect( cl.marker )
	destroyEffect( cl.nameTag )
	cl.marker = nil
	cl.nameTag = nil
	cl.character = nil
	if cl.compass then
		cl.compass = false
		pcall( function()
			if g_compassHud then g_compassHud:compassRemoveIcon( Focus.COMPASS ) end
		end )
	end
end

-- Try each effect name in turn. createEffect on a name the engine does not know
-- throws rather than returning nil, so the pcall IS the existence test -- there
-- is no binding that asks "is this effect declared".
local function createFirst( names, character, lift )
	for _, effectName in ipairs( names ) do
		local ok, effect = pcall( function()
			-- ( name, host, joint, axisIgnore ) -- BaseEnemyCharacter.lua:16.
			-- axis.all stops the billboard rotating with the character, which
			-- is what makes it readable from any angle.
			local e = sm.effect.createEffect( effectName, character, nil, sm.effect.axis.all )
			e:setOffsetPosition( sm.vec3.new( 0, 0, lift ) )
			e:start()
			return e
		end )
		if ok and effect then return effect, effectName end
	end
	return nil, nil
end

-- Bind the marker to a character. Returns true once something is standing.
local function bind( character, name, showName )
	local marker, which = createFirst( Focus.MARKER_EFFECTS, character,
		character:getHeight() + Focus.ICON_LIFT )
	if marker == nil then
		-- Both names failed, which means effects are not reachable from here at
		-- all. ONCE. Cl_Step retries twice a second while somebody is focused,
		-- and a warning on every retry is the log spam this project has already
		-- measured as its largest performance bug.
		if not cl.warnedNoEffect then
			cl.warnedNoEffect = true
			sm.log.warning( "[ServerWorks] focus: no marker effect could be created "
				.. "-- the compass icon is carrying this on its own" )
		end
	end
	cl.marker = marker

	-- The name only exists in OUR effectset, so if the fallback was used there
	-- is nothing to write the name into and it is skipped rather than retried.
	if which == Focus.MARKER_EFFECTS[1] and showName then
		local ok, tag = pcall( function()
			local e = sm.effect.createEffect( Focus.NAME_EFFECT, character, nil,
				sm.effect.axis.all )
			e:setOffsetPosition( sm.vec3.new( 0, 0, character:getHeight() + Focus.NAME_LIFT ) )
			-- setParameter on a declared parameter -- RaidManager.lua:1539 sets
			-- TextContent on RaidMarkerNear exactly this way.
			e:setParameter( "TextContent", tostring( name or "" ) )
			e:start()
			return e
		end )
		cl.nameTag = ok and tag or nil
		if not ok and not cl.warnedNoName then
			-- Cosmetic, and once. The marker itself is up, so this is not worth
			-- faulting the whole module for -- and Cl_Step will come back here
			-- twice a second for as long as somebody is focused.
			cl.warnedNoName = true
			sm.log.warning( "[ServerWorks] focus: name tag unavailable: " .. tostring( tag ) )
		end
	end

	-- compassSetIconHost binds the icon to the character, so it tracks them with
	-- no per-frame work: BaseEnemyCharacter.lua:25, RaidManager.lua:981 and
	-- WorldMarkerManager.lua:285 all do this rather than pushing a position.
	--
	-- NO WIDTH OR HEIGHT. icon_compass_side_quest.png is square, and the one
	-- vanilla call that passes a width is for a 48x30 icon; passing one here
	-- squashes it. LostItems.lua:91 is the precedent to follow.
	pcall( function()
		if g_compassHud == nil then return end
		g_compassHud:compassAddIcon( Focus.COMPASS, Focus.COMPASS_ICON )
		g_compassHud:compassSetIconStacking( Focus.COMPASS, false )
		g_compassHud:compassSetIconHost( Focus.COMPASS, character )
		g_compassHud:setVisible( Focus.COMPASS, true )
		cl.compass = true
	end )

	cl.character = character
	return cl.marker ~= nil or cl.compass
end

-- Called from World.cl_n_swFocus when the server names a new target, or nil.
-- showName is the HOST's `focusname`, decided server-side and sent with the
-- target. It is not read here: Settings is a server-side table, and a client
-- asking it would get the default whatever the host had chosen -- so turning
-- the in-world name off would have changed nothing for anybody but the host.
function Focus.Cl_Set( player, name, showName )
	if player == nil or not sm.exists( player ) then
		Focus.Cl_Clear()
		return
	end
	if cl.player == player and cl.name == name and cl.character ~= nil then
		return
	end
	tearDown()
	cl.player = player
	cl.name = name
	cl.showName = ( showName ~= false )
	cl.nextTry = 0
	cl.tries = 0
	Focus.Cl_Step()
end

function Focus.Cl_Clear()
	tearDown()
	cl.player = nil
	cl.name = nil
	cl.nextTry = 0
	cl.tries = 0
end

-- Called every fixed update from World.client_onFixedUpdate. Cheap: it returns
-- on the first line unless somebody is actually focused, and once the marker is
-- standing it does two comparisons and nothing else.
--
-- It exists because a target's character is not guaranteed to be there when the
-- server names them -- a player still loading has player.character == nil -- and
-- because a character is REPLACED on respawn, which would otherwise leave the
-- marker floating where they died.
function Focus.Cl_Step()
	if cl.player == nil or cl.faulted then return end

	local ok, character = pcall( function()
		return sm.exists( cl.player ) and cl.player.character or nil
	end )
	if not ok then character = nil end

	if character ~= nil and character == cl.character then
		if cl.marker == nil and not cl.compass then
			-- bound to a character but nothing was ever drawn: fall through to
			-- a rebuild rather than sitting there marking nobody.
			cl.character = nil
		else
			return
		end
	end

	if character == nil or not sm.exists( character ) then
		-- They are gone or not here yet. Take the marker down; Cl_Step will put
		-- it back the moment a character appears.
		if cl.character ~= nil then tearDown() end
		return
	end

	local tick = sm.game.getCurrentTick()
	if tick < cl.nextTry then return end
	cl.nextTry = tick + Focus.RETRY_TICKS

	if cl.tries >= Focus.MAX_TRIES then return end
	cl.tries = cl.tries + 1

	tearDown()
	local drew = false
	guard( "bind", function()
		drew = bind( character, cl.name, cl.showName )
	end )
	-- A bind that actually drew something resets the counter, so a marker that
	-- had to wait for a character to spawn does not spend its budget doing it.
	if drew then cl.tries = 0 end
end

-- For the checks, and for anything that wants to know whether a marker is up
-- without reaching into the local table.
function Focus.Cl_Target()
	return cl.player, cl.name
end
