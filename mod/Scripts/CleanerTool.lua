-- CleanerTool -- point at it, press F, it is gone.
--
-- Asked for as: "look. the problem is I cant remove them. remove like delete
-- then. I want to be able to DELETE them when pressing F while removing."
--
--
-- WHY THIS IS A TOOL AND NOT A CHANGE TO THE REMOVE TOOL
--
-- A Custom Game's toolset can ADD a tool. It cannot OVERRIDE one -- first
-- declaration wins, and ours loads last. That is measured, twice, and it is
-- written up in mod/Tools/Database/ToolSets/serverworks.toolset. So the vanilla
-- remove behaviour cannot be altered from here at all; a new tool is the only
-- door that is actually open, and adding is the case that provably works.
--
--
-- F IS `ForceBuild`, AND A TOOL SCRIPT IS THE ONE PLACE THAT CAN SEE IT
--
-- MEASURED, from the owner's own key bindings
-- (User_<id>/keybinds.json): `"ForceBuild": [ { "K": 70 } ]`, and 70 is F.
--
-- That action reaches Lua in exactly one place -- the third argument of a tool's
-- equipped update:
--
--     client_onEquippedUpdate( self, primaryState, secondaryState, forceBuild )
--
-- (Survival/Scripts/game/tools/Bucket.lua:429 and ClayRifle.lua:570 both declare
-- it.) No Game script, World script or player script is given key state at all,
-- so this callback is the whole reason the feature is possible.
--
--
-- WHY IT DELETES THINGS NOTHING ELSE CAN
--
-- Carryable props -- craftbots, gems, crates, harvestables -- are PICKED UP by
-- the remove tool rather than erased. Making them erasable does not make them
-- removable, which is why "unremovable craftbots" survived being given the sweep
-- profile. Script-side `destroyShape()` ignores every permission flag; vanilla's
-- own `sv_e_clear` relies on that. So this is the only mechanism that actually
-- deletes one.
--
-- It is host-gated for the obvious reason: a tool that deletes anything it is
-- pointed at is a griefing tool in a lobby. Settings key `hostcleaner`.

dofile( "$SURVIVAL_DATA/Scripts/game/tools/Sledgehammer.lua" )

-- Subclassed rather than written from scratch so the renderables, the animations
-- and the equip/unequip handling all come for free. Every behaviour that matters
-- is replaced below; the swing never runs because client_onEquippedUpdate does
-- not call its parent.
CleanerTool = class( Sledgehammer )

CleanerTool.RANGE = 14

-- One press is one delete. Without this, holding the button deletes a shape per
-- frame and a plot disappears before the finger comes off.
local function pressed( state )
	return state == sm.tool.interactState.start
end

-- NO vanilla tool calls sm.gui.chatMessage -- not one, in the whole base game --
-- so whether it is reachable from a tool's client environment is unproven. It is
-- only ever used here for "you missed", which is worth nothing if it costs an
-- error, hence the pcall. Everything that matters is said by the server through
-- Game.sv_e_swReply, which is proven.
local function say( text )
	pcall( sm.gui.chatMessage, text )
end

-- The parent draws the swing animations and reads clientPublicData.perks while
-- one is playing. Our tool never starts a swing so that line should never run,
-- but a tool that throws once per frame is exactly the 1.79 GB log in CLAUDE.md,
-- so it is guarded and gives up after the first failure rather than per frame.
function CleanerTool.client_onUpdate( self, dt )
	if self.swAnimationsFaulted then return end
	local ok, err = pcall( Sledgehammer.client_onUpdate, self, dt )
	if not ok then
		self.swAnimationsFaulted = true
		sm.log.warning( "[ServerWorks] cleaner animations disabled: " .. tostring( err ) )
	end
end

function CleanerTool.client_onEquippedUpdate( self, primaryState, secondaryState, forceBuild )
	if not pressed( primaryState ) and not pressed( secondaryState ) then
		-- Swallow both buttons whatever happens, so the inherited sledgehammer
		-- swing can never fire from this tool.
		return true, true
	end

	local from = sm.localPlayer.getRaycastStart()
	local direction = sm.localPlayer.getDirection()
	local hit, result = sm.localPlayer.getRaycast( CleanerTool.RANGE, from, direction )
	if not hit or result == nil then
		say( "Nothing within " .. CleanerTool.RANGE .. " m." )
		return true, true
	end

	-- F, or the right mouse button, takes the WHOLE creation. A plain left click
	-- takes the single block or prop you are pointing at.
	local whole = ( forceBuild == true ) or pressed( secondaryState )

	if result.type == "body" then
		local shape = result:getShape()
		local body = result:getBody()
		if shape == nil or not sm.exists( shape ) then
			return true, true
		end
		self.network:sendToServer( "sv_n_swDelete",
			{ shape = shape, body = body, whole = whole } )

	elseif result.type == "harvestable" then
		local harvestable = result:getHarvestable()
		if harvestable and sm.exists( harvestable ) then
			self.network:sendToServer( "sv_n_swDelete", { harvestable = harvestable } )
		end

	else
		say( "Cannot delete that (" .. tostring( result.type ) .. ")." )
	end

	return true, true
end

-- The delete itself is the server's, because destroyShape is. The client only
-- ever says what was pointed at.
--
-- Replies go out through Game.sv_e_swReply. A tool script's network only has
-- sendToServer and sendToClients in vanilla -- sendToClient( player, ... ) is
-- never used by one -- and this mod already owns a proven bridge for exactly
-- this: the World script has no network either and talks to a client the same
-- way.
local function reply( player, text )
	pcall( sm.event.sendToGame, "sv_e_swReply", { player = player, text = text } )
end

-- Is this one of ours? g_swPlots lives in the Game/World environment and a tool
-- script may not share it, so the uuids are restated here rather than trusted to
-- be reachable. Failing to see the city would mean a misaimed click could punch
-- a hole in the deck, and that is not a thing to leave to load order.
local CITY = {
	["a6c6ce30-dd47-4587-b475-085d55c6a3b4"] = true,   -- blk_concrete1
	["1016cafc-9f6b-40c9-8713-9019d399783f"] = true,   -- blk_metal2
	["c0dfdea5-a39d-433a-b94a-299345a5df46"] = true,   -- blk_metal3
}

local function isCity( shape )
	if g_swPlots and g_swPlots.sv_isCityShape then
		local ok, verdict = pcall( g_swPlots.sv_isCityShape, g_swPlots, shape )
		if ok then return verdict == true end
	end
	local got, uuid = pcall( function() return tostring( shape.shapeUuid ) end )
	if not got then return true end                    -- unreadable: keep it
	if not CITY[uuid] then return false end
	-- Our decking is one block layer, world z 1.00 to 1.25. Somebody's build made
	-- of the same materials starts on TOP of it, at 1.25. 1.1875 is three
	-- quarters of the way up our own layer, which separates the two whether
	-- worldPosition means the minimum corner or the centre -- the same number and
	-- the same reason as Plots.CITY_CEILING, restated because a tool script may
	-- not share that environment.
	--
	-- It used to be 1.35, which swallowed the whole first layer of everybody's
	-- build: "whatever the block is metal 2 or concrete it counts as part of the
	-- city whatever of it actualy being so."
	local ok, pos = pcall( function() return shape.worldPosition end )
	return ok and pos ~= nil and pos.z < 1.1875
end

function CleanerTool.sv_n_swDelete( self, params, player )
	if type( params ) ~= "table" then return end

	-- Most tool server callbacks are handed the player as a third argument
	-- (CarryTool, ClayRifle, ClayTool and Cornade all declare it) but some are
	-- written ( self, params ) and it is not worth betting the host check on
	-- which. self.tool:getOwner() is the owner of THIS tool and is what vanilla
	-- reaches for server-side (CarryTool.lua:376).
	if player == nil then
		local ok, owner = pcall( function() return self.tool:getOwner() end )
		player = ok and owner or nil
	end
	if player == nil then return end

	-- Host only, checked HERE and not just by the tool guard. The guard pulls the
	-- tool out of a guest's hands within a couple of ticks, which is fast but is
	-- not the same as impossible -- and this is a delete-anything tool. If the
	-- settings table is not reachable from a tool script, it stays host only,
	-- because that is the safe way to be wrong.
	local hostOnly = true
	if Settings and Settings.Get then
		local ok, value = pcall( Settings.Get, "hostcleaner" )
		if ok then hostOnly = ( value ~= false ) end
	end
	if hostOnly and player ~= sm.player.getHostPlayer() then
		reply( player, "The cleaner is host only on this server." )
		return
	end

	if params.harvestable then
		if sm.exists( params.harvestable ) then
			local ok = pcall( function() params.harvestable:destroy() end )
			reply( player, ok and "Deleted." or "That one refused to go." )
		end
		return
	end

	local shape, body = params.shape, params.body
	if shape == nil or not sm.exists( shape ) then return end

	-- Never the city itself. CLEAR CITY on the layout panel exists for that, asks
	-- twice and takes a snapshot first; punching a hole in the deck with a
	-- misaimed click is not something that should be possible.
	if isCity( shape ) then
		reply( player, "That is the city floor -- use CITY LAYOUT then CLEAR CITY." )
		return
	end

	local removed, spared = 0, 0
	if params.whole and body and sm.exists( body ) then
		local got, shapes = pcall( function() return body:getShapes() end )
		if got and shapes then
			for _, s in ipairs( shapes ) do
				if sm.exists( s ) then
					if isCity( s ) then
						-- A build welded to a plot slab is ONE body with our
						-- concrete in it, so "the whole creation" stops at our
						-- ground rather than taking the plot with it.
						spared = spared + 1
					else
						s:destroyShape()
						removed = removed + 1
					end
				end
			end
		end
	else
		shape:destroyShape()
		removed = 1
	end

	reply( player, string.format( "Deleted %d block%s%s", removed,
		removed == 1 and "" or "s",
		spared > 0 and " -- left the plot floor alone" or "" ) )
	sm.log.info( string.format( "[ServerWorks] cleaner: %d removed, %d spared", removed, spared ) )

	-- Our own cleanup must not read as mass deletion to the grief alarm --
	-- deleting a big creation with F would otherwise trip it and arm a lockdown
	-- in the middle of an event.
	--
	-- Through the CHARACTER, not body:getWorld(). character:getWorld() is what
	-- vanilla uses (CreativePlayer.lua:19, CreativeGame.lua:259) and no base-game
	-- script ever calls getWorld on a body, so its existence is a guess and this
	-- one is not.
	local ok, world = pcall( function() return player:getCharacter():getWorld() end )
	if ok and world and sm.exists( world ) then
		pcall( sm.event.sendToWorld, world, "sv_e_swQuietAlarm", { seconds = 20 } )
	end
end
