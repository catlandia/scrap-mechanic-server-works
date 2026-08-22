dofile( "$GAME_DATA/Scripts/game/worlds/CreativeFlatWorld.lua" )

-- Our own world, for two reasons: explosions, and fire spread.
--
-- EXPLOSIONS. Stream chat from the 2026-08-22 event reports a cornade going off
-- and someone "trying to use explosives". Bodies are already safe -- Protection
-- pins destructable false -- but the ground is not. CreativeBaseWorld's
-- server_onExplosion calls world:sphereVoxelDensitySubtraction(), which digs a
-- crater, and no body flag covers that. server_onExplosion is a notification,
-- not a veto: it returns nothing and the explosion has already happened. So the
-- explosion cannot be cancelled, but its terrain damage simply is not applied.
--
-- FIRE. Turning fire off takes two switches, because the engine has two
-- mechanisms. sm.fire.setFireLimit( 0 ) caps how many fire instances may exist
-- (Settings handles that). AttachedFireManager is the separate system that walks
-- burning shapes each tick and lights their neighbours -- that is the *spread*.
-- Capping the instance budget without stopping the manager leaves spread logic
-- running every tick against a budget of zero, which is wasted work at best.

World = class( CreativeFlatWorld )

-- Set from Settings. Globals rather than instance state because the world object
-- is not reachable from a settings apply function.
g_swProtectTerrain = true
g_swFireEnabled = false

function World.server_onExplosion( self, center, destructionLevel, radius )
	if g_swProtectTerrain then
		-- Deliberately skipping the base call. CablebotManager.Sv_Explosion goes
		-- with it; there are no cablebots in a flat creative build world, and
		-- letting an explosion cut cables would be griefing by another name.
		return
	end
	CreativeFlatWorld.server_onExplosion( self, center, destructionLevel, radius )
end

-- The parent's body is three calls and there is no way to skip just one of them,
-- so it is restated here rather than delegated. If CreativeBaseWorld gains a
-- fourth call in a game update, this must gain it too -- check
-- Data/Scripts/game/worlds/CreativeBaseWorld.lua after any patch.
function World.server_onFixedUpdate( self )
	if g_swFireEnabled then
		AttachedFireManager.Sv_OnWorldFixedUpdate( self.world )
	end
	CablebotManager.Sv_OnWorldFixedUpdate( self.world )
	self.waterManager:sv_onFixedUpdate()
end

function World.client_onFixedUpdate( self )
	if g_swFireEnabled then
		AttachedFireManager.Cl_OnWorldFixedUpdate( self.world )
	end
	CablebotManager.Cl_OnWorldFixedUpdate( self.world )
	self.waterManager:cl_onFixedUpdate()
end
