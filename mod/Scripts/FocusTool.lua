-- FocusTool -- point at somebody and the whole lobby can see who you mean.
--
-- Asked for as an "admin tool" for running events: pick a person, everybody
-- gets a marker over them. FocusGui is the searchable list for somebody you
-- cannot see; this is the two-second version for somebody you can.
--
--   aim at a player + LMB    focus them
--   aim at nothing  + LMB    open the search panel
--   hold F                   clear the focus
--
--
-- WHY IT IS A TOOL AT ALL
--
-- Two reasons, and only the second one is forced.
--
--   * F is `ForceBuild` -- MEASURED from the owner's own keybinds.json, key 70
--     -- and that action reaches Lua in exactly one place: the third argument
--     of client_onEquippedUpdate. No Game, World or player script is handed key
--     state at all. So "hold F to clear" can only live here.
--   * a raycast that reports what the CROSSHAIR is on needs sm.localPlayer,
--     which is a client thing, and a tool is the natural home for it.
--
-- A Custom Game's toolset can ADD a tool but cannot OVERRIDE one -- measured,
-- see mod/Tools/Database/ToolSets/serverworks.toolset -- so this is a brand new
-- uuid and therefore resolves to our class. NOTlift and the Cleaner are the two
-- standing proofs that adding works.
--
--
-- HOW A RAYCAST FINDS A PERSON
--
-- result.type == "character", then result:getCharacter(), then
-- character:isPlayer() and character:getPlayer(). Every step is vanilla:
-- Feeder.lua:218-220 does the first three on a tool's own crosshair, and
-- RayProjectileManager.lua:29-33 does isPlayer/getPlayer on a hit.
--
-- The cast itself is sm.physics.raycast( from, to, ignore ) rather than
-- sm.localPlayer.getRaycast, because the latter's range is the build range --
-- MechanicCharacter.lua:521 calls it with 7.5 -- and pointing at somebody
-- across a plaza is the entire use case. ClayTool.lua:206 is the precedent for
-- the long form, including passing your own character as the thing to ignore so
-- the ray does not stop on your own capsule.

dofile( "$SURVIVAL_DATA/Scripts/game/tools/Sledgehammer.lua" )

-- Subclassed for the same reason CleanerTool is: the renderables, the animations
-- and the equip handling come free. The swing never runs, because
-- client_onEquippedUpdate does not call its parent and swallows both buttons.
FocusTool = class( Sledgehammer )

-- Far enough to reach across a plot row. The city is 20-block plots, so 70 m is
-- roughly three plots plus the road -- past that, use the panel.
FocusTool.RANGE = 70

-- Amber, the mod's own accent colour, so it is not mistaken for the red Cleaner
-- or the grey sledgehammer in somebody's hand. setTpColor / setFpColor are the
-- pair Bucket.lua:268 and CarryTool.lua:564 use, and the isLocal() guard around
-- the first-person half is theirs: the third-person model is what everyone else
-- sees, the first-person one exists only on the holder's client.
FocusTool.HAND_COLOUR = sm.color.new( 1.0, 0.62, 0.18 )

-- One press is one action. Without this, holding the button re-sends the focus
-- every frame and the server pushes a fresh marker to every client 40 times a
-- second.
local function pressed( state )
	return state == sm.tool.interactState.start
end

-- NO vanilla tool calls sm.gui.chatMessage -- not one, in the whole base game --
-- so it is guarded here and used only for "you missed", which is worth nothing
-- if it costs an error. Everything that matters is said by the server through
-- Game.sv_e_swReply, which is proven.
local function say( text )
	pcall( sm.gui.chatMessage, text )
end

-- Is this client the host?
--
-- COSMETIC ONLY. The real gate is sv_n_swFocus below, which refuses outright,
-- and the tool guard that pulls this out of a guest's hands within a couple of
-- ticks. This exists so a guest who has it for those couple of ticks reads
-- "host only" on the crosshair instead of clicking at somebody and getting
-- nothing.
--
-- sm.isHost is what the mod already uses to tell the two apart client-side
-- (Game.client_setBlockedTools), and vanilla reads it in 81 places -- but never
-- from a TOOL script, and a tool's environment is not the same environment as a
-- Game script's. That is not a theory: a character script's callbacks have no
-- setmetatable at all (see CLAUDE.md). So an unreadable value means "carry on
-- as if host" -- the server still refuses, and failing this open costs a guest
-- one wasted click rather than a host a broken tool.
local function looksLikeHost()
	local ok, isHost = pcall( function() return sm.isHost end )
	if not ok or isHost == nil then return true end
	return isHost == true
end

function FocusTool.client_onEquip( self, animate )
	local ok = pcall( Sledgehammer.client_onEquip, self, animate )
	if not ok then
		sm.log.warning( "[ServerWorks] focus tool equip animation failed" )
	end
	-- After the parent, which is what sets the renderables the colour applies to.
	pcall( function()
		self.tool:setTpColor( FocusTool.HAND_COLOUR )
		if self.tool:isLocal() then
			self.tool:setFpColor( FocusTool.HAND_COLOUR )
		end
	end )
end

function FocusTool.client_onUpdate( self, dt )
	if self.swAnimationsFaulted then return end
	local ok, err = pcall( Sledgehammer.client_onUpdate, self, dt )
	if not ok then
		self.swAnimationsFaulted = true
		sm.log.warning( "[ServerWorks] focus tool animations disabled: " .. tostring( err ) )
	end
end

-- What the crosshair is on, as ( player, name ) or nil. Wrapped whole: a
-- raycast that throws must cost one warning and then behave like a miss, not an
-- error per frame -- the 1.79 GB log in CLAUDE.md is what per-frame costs.
function FocusTool.cl_aimedAt( self )
	local ok, player, name = pcall( function()
		local from = sm.localPlayer.getRaycastStart()
		local direction = sm.localPlayer.getDirection()
		local own = sm.localPlayer.getPlayer()
		own = own and own:getCharacter() or nil

		local hit, result = sm.physics.raycast( from,
			from + direction * FocusTool.RANGE, own )
		if not hit or result == nil or result.type ~= "character" then
			return nil, nil
		end
		local character = result:getCharacter()
		if character == nil or not sm.exists( character ) then return nil, nil end
		-- isPlayer() first: a /crowd bot is a character too, and so is every
		-- tapebot. getPlayer() on one returns nil, so without this the tool
		-- would send a nil target and look broken. Bots cannot be focused at
		-- all -- there is no Player to find their character through -- which is
		-- why FocusGui does not list them either.
		if character:isPlayer() ~= true then return nil, nil end
		local target = character:getPlayer()
		if target == nil or not sm.exists( target ) then return nil, nil end
		return target, target.name
	end )
	if not ok then
		if not self.swAimFaulted then
			self.swAimFaulted = true
			sm.log.warning( "[ServerWorks] focus tool raycast failed: " .. tostring( player ) )
		end
		return nil, nil
	end
	return player, name
end

function FocusTool.client_onEquippedUpdate( self, primaryState, secondaryState, forceBuild )
	if not looksLikeHost() then
		pcall( sm.gui.setInteractionText, "", "",
			"the focus tool is host only" )
		-- Both buttons swallowed, nothing sent. The inherited sledgehammer swing
		-- must not fire from this tool for a guest either.
		return true, true
	end

	local target, name = self:cl_aimedAt()

	-- A crosshair prompt, so the tool visibly IS the focus tool.
	-- sm.gui.setInteractionText is proven inside a tool script
	-- (Fertilizer.lua:242), unlike sm.gui.chatMessage which no vanilla tool
	-- calls at all -- that distinction is why "I dont see my deleting thing
	-- appear" happened to the Cleaner.
	pcall( sm.gui.setInteractionText, "",
		sm.gui.getKeyBinding( "Create", true ),
		target and ( "focus " .. tostring( name ) )
			or "open the player list   --   hold F to clear the focus" )

	-- F CLEARS, and it is checked before the buttons so it works whether or not
	-- anything is under the crosshair.
	if forceBuild == true then
		if not self.swClearHeld then
			self.swClearHeld = true
			self.network:sendToServer( "sv_n_swFocus", { clear = true } )
		end
		return true, true
	end
	self.swClearHeld = false

	if not pressed( primaryState ) and not pressed( secondaryState ) then
		-- Swallow both buttons whatever happens, so the inherited sledgehammer
		-- swing can never fire from this tool.
		return true, true
	end

	if target ~= nil then
		self.network:sendToServer( "sv_n_swFocus", { target = target } )
	else
		-- Aimed at nothing: the panel is the other half of the feature, and
		-- opening it from here means the host never has to find /menu mid-event.
		self.network:sendToServer( "sv_n_swFocus", { panel = true } )
		say( "Opening the player list." )
	end

	return true, true
end

-- The server half. It owns nothing: focus is Game state, so this forwards and
-- the Game script decides. sm.event.sendToGame is the same bridge CleanerTool
-- uses for its replies, and it is how a script with no route to the Game class
-- reaches one.
function FocusTool.sv_n_swFocus( self, params, player )
	if type( params ) ~= "table" then return end

	-- Most tool server callbacks are handed the player as a third argument
	-- (CarryTool, ClayRifle, ClayTool and Cornade all declare it) but some are
	-- written ( self, params ), and it is not worth betting a host check on
	-- which. self.tool:getOwner() is the owner of THIS tool and is what vanilla
	-- reaches for server-side (CarryTool.lua:376).
	if player == nil then
		local ok, owner = pcall( function() return self.tool:getOwner() end )
		player = ok and owner or nil
	end
	if player == nil then return end

	-- HOST ONLY, unconditionally, and checked HERE as well as in the Game
	-- script. The tool guard pulls this tool out of a guest's hands within a
	-- couple of ticks, which is fast but is not the same as impossible.
	--
	-- No Settings lookup, deliberately. The Cleaner reads `hostcleaner` here
	-- because a host may want to delegate a tool that changes the world; there
	-- is no equivalent for this one -- see HOST_ONLY in Settings.lua -- and a
	-- settings read that a tool script cannot resolve is one more way to be
	-- accidentally open. sm.player.getHostPlayer() is the same test the panel
	-- and /focus use.
	if player ~= sm.player.getHostPlayer() then
		pcall( sm.event.sendToGame, "sv_e_swReply",
			{ player = player, text = "The focus tool is host only." } )
		return
	end

	pcall( sm.event.sendToGame, "sv_e_swFocus", {
		player = player,
		target = params.target,
		clear = params.clear == true,
		panel = params.panel == true,
	} )
end
