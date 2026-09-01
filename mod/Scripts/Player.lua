dofile( "$GAME_DATA/Scripts/game/CreativePlayer.lua" )
dofile( "$CONTENT_DATA/Scripts/GuiProbe.lua" )

Player = class( CreativePlayer )

-- MEASURED, first run, 2026-08-22 23:16:55:
--
--   ERROR: $SURVIVAL_DATA/Scripts/game/tools/Sledgehammer.lua:193:
--          attempt to index field 'perks' (a nil value)
--
-- This is the cost of baseGameContent "Survival" with a Creative player. The
-- survival tool scripts come along with the survival parts, and they read
-- ownerPlayer.clientPublicData.perks -- which SurvivalPlayer populates
-- (SurvivalPlayer.lua:223) and CreativePlayer never does. Every swing of a
-- sledgehammer threw, once per client frame, with a full traceback.
--
-- An empty table satisfies them: no perk is ever true, so every survival tool
-- behaves as if the player has no upgrades, which is exactly right for creative.
-- Cheaper than dropping to baseGameContent "Creative", which would take the
-- survival parts with it.
--
-- The compass marker used to live here too, on the theory that a player script
-- has a world. It does not: the same "Calling world dependent functions in a no
-- world script" warning came back verbatim. It is in World.lua now, which is
-- where every vanilla caller of the compass lives.
function Player.client_onCreate( self )
	CreativePlayer.client_onCreate( self )

	local player = self.player
	if player then
		if player.clientPublicData == nil then
			player.clientPublicData = {}
		end
		if player.clientPublicData.perks == nil then
			player.clientPublicData.perks = {}
		end
	end
end

function Player.server_onCreate( self )
	CreativePlayer.server_onCreate( self )

	local player = self.player
	if player then
		if player.publicData == nil then
			player.publicData = {}
		end
		if player.publicData.perks == nil then
			player.publicData.perks = {}
		end
	end
end

--[[ unstuck ]]

-- VANILLA SENDS YOU TO 16,16. This city is centred on the origin, so the button
-- whose entire job is "put me somewhere sensible" put you in a field outside it,
-- at the same wrong spot every time. See World.sv_e_swUnstuck for the whole
-- report and why the destination is computed rather than fixed.
--
-- The override is the whole of the fix: CreativePlayer.sv_n_unstuck is a plain
-- method on a plain Lua class, so replacing it here replaces it everywhere,
-- including for the popup the engine itself puts on screen.
function Player.sv_n_unstuck( self )
	local character = self.player:getCharacter()
	if not character then
		-- No character to move and nothing to be stuck in. Fall back to the base
		-- class rather than doing nothing: it is the path that can create one.
		return CreativePlayer.sv_n_unstuck( self )
	end
	sm.event.sendToWorld( character:getWorld(), "sv_e_swUnstuck",
		{ player = self.player } )
end


--[[ the button probe, player half ]]

-- The other side of /guitest. Every jsonGui callback in the base game belongs to
-- a script like this one -- a player, an interactable, a character -- and not
-- one belongs to a Game script. If the buttons work here and not there, that is
-- the answer, and every panel in the mod moves.
function Player.cl_e_swGuiProbe( self, params )
	self.cl = self.cl or {}
	-- No mode means "put yours away, the game script is taking this one".
	if type( params ) ~= "table" or params.mode == nil then
		local gui = self.cl.probeGui
		self.cl.probeGui = nil
		if gui and sm.exists( gui ) then pcall( function() gui:close() end ) end
		return
	end
	self.cl.probeMode = params.mode
	self.cl.probeHits = nil
	self.cl.probeLast = nil
	self:cl_renderProbe()
end

function Player.cl_renderProbe( self )
	local mode = self.cl.probeMode or 1
	local m = GuiProbe.MODES[mode]
	local state = { mode = mode, hits = self.cl.probeHits, last = self.cl.probeLast,
		canvas = GuiProbe.CanvasLine() }

	local root, err
	if m.tree == "file" then
		root, err = GuiProbe.BuildFromFile( state, "cl_onProbeClick", "cl_onProbeClose" )
	else
		root = GuiProbe.BuildLua( state, "cl_onProbeClick", "cl_onProbeClose" )
	end
	if root == nil then
		sm.gui.chatMessage( "  could not build the probe: " .. tostring( err ) )
		return
	end

	if self.cl.probeGui == nil or not sm.exists( self.cl.probeGui ) then
		self.cl.probeGui = sm.jsonGui.createGui( { isInteractive = true, needsCursor = true } )
	end
	self.cl.probeGui:render( root )
end

function Player.cl_onProbeClick( self, widgetName, data )
	self.cl.probeHits = ( self.cl.probeHits or 0 ) + 1
	self.cl.probeLast = tostring( widgetName )
	local kind = ( type( data ) == "table" ) and "with data" or ( "no data (" .. type( data ) .. ")" )
	sm.gui.chatMessage( string.format( "CLICK RECEIVED on the PLAYER script: %s, %s",
		tostring( widgetName ), kind ) )
	sm.log.info( string.format( "[ServerWorks] guitest: PLAYER script click %s %s",
		tostring( widgetName ), kind ) )
	self:cl_renderProbe()
end

function Player.cl_onProbeClose( self )
	if self.cl then self.cl.probeGui = nil end
end
