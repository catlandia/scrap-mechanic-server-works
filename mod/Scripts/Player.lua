dofile( "$GAME_DATA/Scripts/game/CreativePlayer.lua" )
dofile( "$CONTENT_DATA/Scripts/PlotMarker.lua" )

Player = class( CreativePlayer )

-- The compass marker lives HERE, not in Game.lua, and the reason is the same one
-- that moved every sm.body.* call into World.lua: a Game script has no world.
--
--   WARNING: [ServerWorks] compass marker unavailable: PlotMarker.lua:72:
--            Calling world dependent functions in a no world script!
--
-- Every vanilla caller of compassSetIconWorldPosition is world-attached -- a
-- character, an interactable, RaidManager. A player script is attached to a
-- character in a world, so it is the right home for it, and Game.lua reaches it
-- the way CreativeGame reaches CreativePlayer for the unstuck popup:
-- sm.event.sendToPlayer( sm.localPlayer.getPlayer(), "cl_e_..." ).
function Player.cl_e_swPlotMarker( self, data )
	if type( data ) ~= "table" or data.position == nil then
		PlotMarker.Cl_Hide()
		return
	end
	PlotMarker.Cl_Show( data.position )
	if data.ping then PlotMarker.Cl_Ping() end
end

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
