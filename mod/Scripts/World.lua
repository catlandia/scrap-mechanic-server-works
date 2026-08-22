dofile( "$GAME_DATA/Scripts/game/worlds/CreativeFlatWorld.lua" )

-- Our own world, for one reason: explosions.
--
-- Stream chat from the 2026-08-22 event repeatedly reports a cornade going off
-- and someone "trying to use explosives". Bodies are already safe -- Protection
-- pins destructable false -- but the ground is not. CreativeBaseWorld's
-- server_onExplosion calls world:sphereVoxelDensitySubtraction(), which digs a
-- crater in the terrain, and that is not covered by any body flag.
--
-- server_onExplosion is a notification, not a veto: it returns nothing and the
-- explosion has already happened by the time it runs. So an explosion cannot be
-- cancelled -- but the terrain damage it would cause can simply not be applied.

World = class( CreativeFlatWorld )

-- Set from Game. When true, explosions leave the ground alone.
g_swProtectTerrain = true

function World.server_onExplosion( self, center, destructionLevel, radius )
	if g_swProtectTerrain then
		-- Deliberately skipping the base call. CablebotManager.Sv_Explosion is
		-- skipped with it; there are no cablebots in a flat creative build world,
		-- and letting an explosion cut cables would be griefing by another name.
		return
	end
	CreativeFlatWorld.server_onExplosion( self, center, destructionLevel, radius )
end
