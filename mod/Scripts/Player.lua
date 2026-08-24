dofile( "$GAME_DATA/Scripts/game/CreativePlayer.lua" )

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
