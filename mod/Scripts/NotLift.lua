-- NotLift -- the blueprint importer, and the way round a gate we cannot open.
--
-- ASKED FOR AS: "every creation you have in blue prints. will be aviable to
-- import. via the new tool called NOTlift. NOTlift will be clasified as ANYTHING
-- but a lift."
--
-- That instinct is exactly right, and here is why it had to be a new tool.
--
--
-- WHY THE REAL LIFT CANNOT DO THIS
--
-- Pressing E on a placed lift opens the engine's LOAD CREATION browser
-- (ImportGui.cpp / LiftGui.cpp, title #{LIFT_IMPORT_BLUEPRINTS}). Nothing in
-- Lua opens it and no binding exists to. It is keyed on the loaded CONTENT, not
-- on the tool -- both lift classes end at the same sm.player.placeLift
-- (Data/Scripts/game/Lift.lua:388), so the PLACED lift is identical whichever
-- tool placed it, and adding uuid 5cc12f03 to our toolset changed nothing.
--
-- The content that would enable it is baseGameContent "Creative", and that
-- CANNOT BE USED: it registers no scriptable objects, so
-- CreativeGame.server_onCreate throws on line 47 before it ever reaches
-- sm.world.createWorld, and the game comes up with no world at all. See the
-- baseGameContent section in CLAUDE.md. dev/check_uuids.py now fails the build
-- if anyone tries it again.
--
--
-- SO THE BROWSER IS BORROWED INSTEAD, AND IT WORKS
--
-- The survival garage picks a creation with sm.gui.openGarageImportGui() plus
-- sm.gui.setGarageButtonCallback( name ) (GarageConsole.lua:468-470). That is
-- the same widget -- GarageImportGui.cpp draws
-- Data/Gui/Layouts/Lift/Lift_Import.layout, the lift's own layout.
--
-- MEASURED in game, 2026-08-25, five consecutive presses, /bptest2:
--
--   [ServerWorks] bptest Q2: openGarageImportGui did not raise
--   [ServerWorks] bptest PICK name=if this house get 40000 like im build is
--                 house in real life
--                 path=$CONTENT_1bce3586-...4fd8/blueprint.json   <- not game
--                 content: a blueprint's own content id, which is the finding
--   [ServerWorks] bptest PICK read: READABLE, it has bodies
--
-- Three things settled by that, none of which was safe to assume:
--
--   1. openGarageImportGui() opens with NO storage set. GarageConsole always
--      calls setGarageImportGuiStorage first and returns early without it, so
--      this could have been a native crash. It is not.
--   2. setGarageButtonCallback dispatches to a GAME script. No vanilla code
--      does that -- every caller is an interactable -- and a Game script is
--      already special enough (it has no world) that it could easily have been
--      excluded.
--   3. A blueprint's path is $CONTENT_<uuid>/blueprint.json. EVERY BLUEPRINT IS
--      ITS OWN CONTENT ID. That is the whole reason the obvious approach fails.
--
--
-- WHY THERE IS NO CUSTOM LIST, THOUGH ONE WAS ASKED FOR
--
-- "NOTlift will use custom UI and other custom stuff to work this time."
--
-- A custom list would have to know which blueprints exist, and it cannot.
--
--   MEASURED over the executable's whole string table:
--     listFiles 0   getFiles 0   readDirectory 0   directoryExists 0
--
-- There is no directory listing binding at all. And every way of naming the
-- Blueprints folder is refused by the file sandbox -- MEASURED, /bptest, all
-- five forms, against a control that came back READABLE so the probe itself is
-- known good:
--
--   CONTROL our own file    READABLE
--   absolute, forward /     'C:/Users/...' is not located in a valid directory
--   absolute, back \        ... is not located in a valid directory
--   $BLUEPRINT_DATA         ... is not located in a valid directory
--   $USER_DATA              ... is not located in a valid directory
--   $CONTENT_DATA/../..     ... is not located in a valid directory
--
-- So Lua can open a blueprint only when the engine has already handed it the
-- path -- which is precisely what the browser's callback does. The browser is
-- not a shortcut here; it is the only door. Everything AFTER the pick is ours.

dofile( "$SURVIVAL_DATA/Scripts/game/tools/Sledgehammer.lua" )

-- "clasified as ANYTHING but a lift" -- taken literally, and it costs nothing.
-- This is a Sledgehammer subclass: it inherits renderables, animations and
-- equip handling that are proven to work in this game (CleanerTool does the
-- same), and it touches no lift binding anywhere. sm.player.placeLift is never
-- called, no ghost body is ever made, and body:isOnLift() is never consulted.
NotLift = class( Sledgehammer )

local function pressed( state )
	return state == sm.tool.interactState.start
end

-- Nothing here calls sm.gui.chatMessage, deliberately. No vanilla tool does,
-- so whether it is even reachable from a tool's client environment is unproven
-- -- and every message this feature needs to send comes from the SERVER, which
-- is the only side that knows whether the import was allowed. That reply goes
-- through Game.sv_e_swReply, the bridge CleanerTool already uses.

-- The parent reads clientPublicData.perks while a swing animation plays. We
-- never start a swing, so that should never run -- but a tool that throws once
-- per frame is the 1.79 GB log in CLAUDE.md, so it gives up after the first
-- failure rather than per frame.
function NotLift.client_onUpdate( self, dt )
	if self.swAnimationsFaulted then return end
	local ok, err = pcall( Sledgehammer.client_onUpdate, self, dt )
	if not ok then
		self.swAnimationsFaulted = true
		sm.log.warning( "[ServerWorks] NOTlift animations disabled: " .. tostring( err ) )
	end
end

function NotLift.client_onEquippedUpdate( self, primaryState, secondaryState, forceBuild )
	-- setInteractionText IS proven inside a tool script (Fertilizer.lua:242),
	-- unlike chatMessage. Reported once already as "I dont see my deleting thing
	-- appear" about a tool that was in the game the whole time.
	pcall( sm.gui.setInteractionText, "", sm.gui.getKeyBinding( "Create", true ),
		"open your creations   --   right click to drop it off the lift" )

	if pressed( secondaryState ) then
		-- RIGHT CLICK RELEASES THE LIFT, so the whole job is one tool and no
		-- typing. "make sure it works just with the items and without commands".
		--
		-- An import lands STATIC and goes onto a lift; coming OFF the lift is
		-- what converts it to a normal dynamic build, and there is no binding
		-- that converts one directly. So the release has to be an action, and
		-- this is it.
		--
		-- Point at a lift to drop that one. Point at nothing in particular and
		-- it drops YOUR lift, which is the one NOTlift just made -- so the
		-- ordinary flow is left click, position, right click, without ever
		-- having to aim at the lift itself.
		local from = sm.localPlayer.getRaycastStart()
		local hit, result = sm.localPlayer.getRaycast( 14, from, sm.localPlayer.getDirection() )
		local lift = nil
		if hit and result and result.type == "lift" then
			local okData, got = pcall( function() return result:getLiftData() end )
			lift = okData and got or nil
		end
		self.network:sendToServer( "sv_n_swDropLift", { lift = lift } )
		return true, true
	end

	if pressed( primaryState ) then
		-- THE LONG WAY ROUND, ON PURPOSE.
		--
		-- The browser callback is only PROVEN to reach a Game script -- that is
		-- what /bptest2 measured. Whether it would reach a TOOL script is an
		-- inference from GarageConsole being an interactable, and this project
		-- has already lost two versions to inferences about which script the
		-- engine talks to.
		--
		-- So the tool does not open the browser itself. It asks the server, the
		-- server asks the Game script, and the Game script opens it -- every hop
		-- being one this mod already does elsewhere. Two network hops is nothing
		-- against a browser that silently never calls back.
		self.network:sendToServer( "sv_n_swOpenImport", {} )
	end

	-- Swallow both buttons so the inherited sledgehammer swing can never fire.
	return true, true
end

function NotLift.sv_n_swOpenImport( self, params, player )
	-- Most tool server callbacks are handed the player as a third argument, but
	-- some are written ( self, params ). Not worth betting on which; getOwner()
	-- is what vanilla reaches for server-side (CarryTool.lua:376).
	if player == nil then
		local ok, owner = pcall( function() return self.tool:getOwner() end )
		player = ok and owner or nil
	end
	if player == nil then return end

	-- HOST ONLY, and checked HERE rather than left to the tool gate -- same
	-- reasoning as sv_n_swDropLift below and as World.sv_e_swImportCreation.
	-- The gate pulls the tool out of a guest's hands in a couple of ticks, but a
	-- modified client can send this message without ever holding the tool. The
	-- import itself is refused downstream either way; what this stops is the
	-- host's blueprint browser opening on a guest's screen at all.
	local hostOnly = true
	if Settings and Settings.Get then
		local okS, value = pcall( Settings.Get, "hostnotlift" )
		if okS then hostOnly = ( value ~= false ) end
	end
	if hostOnly and player ~= sm.player.getHostPlayer() then return end

	-- A tool's network has sendToServer and sendToClients, and no vanilla tool
	-- ever calls sendToClient( player, ... ). So the reply goes back through the
	-- Game script, which is the bridge CleanerTool already uses.
	pcall( sm.event.sendToGame, "sv_e_swOpenImport", { player = player } )
end


-- The release. Server side because destroying a lift is a world action, and
-- because the host check has to happen somewhere the client cannot skip.
function NotLift.sv_n_swDropLift( self, params, player )
	if player == nil then
		local ok, owner = pcall( function() return self.tool:getOwner() end )
		player = ok and owner or nil
	end
	if player == nil then return end

	-- Host only, same fail-safe direction as everything else on this tool: if
	-- the settings cannot be read from a tool script, stay host only.
	local hostOnly = true
	if Settings and Settings.Get then
		local okS, value = pcall( Settings.Get, "hostnotlift" )
		if okS then hostOnly = ( value ~= false ) end
	end
	if hostOnly and player ~= sm.player.getHostPlayer() then return end

	local said = nil
	if params and params.lift and sm.exists( params.lift ) then
		-- A lift you pointed at. This is the only thing that removes one made by
		-- sm.lift.createNonPlayerLift, which no lift tool will pick up.
		said = pcall( function() params.lift:destroy() end )
			and "Lift removed -- the creation is loose now."
			or "That lift refused to go."
	else
		-- Yours, which is the one an import just made.
		said = pcall( sm.player.removeLift, player )
			and "Your lift is gone -- the creation is loose now."
			or "You have no lift out."
	end
	pcall( sm.event.sendToGame, "sv_e_swReply", { player = player, text = said } )
end
