-- GuardedTools -- tools that cannot fire, rather than tools we keep confiscating.
--
-- MEASURED: "took firelauncher from CyberSlime2077" twelve times in one second.
-- The strip was working perfectly and achieving nothing, because CreativeGame
-- sets enableLimitedInventory = false. A creative inventory is INFINITE -- there
-- is no slot to empty, so removal is meaningless and forceTool only unequips
-- something the player picks straight back up.
--
-- So stop fighting over the item and disable the tool itself. V19 proved a
-- Custom Game's toolset can re-declare a vanilla uuid and win (that is how the
-- creative lift came back), so the same trick points a banned tool at a subclass
-- of its real script with the trigger held shut.
--
-- Subclassing rather than replacing keeps the setting meaningful: when the tool
-- is allowed, every callback goes straight through to the real implementation
-- and it behaves exactly as vanilla. When it is not, the fire buttons are
-- swallowed and nothing else changes -- it still draws, still holds, still
-- animates, it just will not shoot.
--
-- g_swBlockedNames is set on each client by Game.client_setBlockedTools.

dofile( "$SURVIVAL_DATA/Scripts/game/tools/ClayRifle.lua" )
dofile( "$SURVIVAL_DATA/Scripts/game/tools/PotatoLauncher.lua" )

g_swBlockedNames = g_swBlockedNames or {}

local function blocked( name )
	return g_swBlockedNames[name] == true
end

-- One message per equip, not one per frame.
local function warnOnce( self, name )
	if self.swWarned then return end
	self.swWarned = true
	sm.gui.chatMessage( string.format( "The %s is disabled on this server.", name ) )
end


--[[ clay gun ]]

GuardedClayRifle = class( ClayRifle )

function GuardedClayRifle.client_onEquippedUpdate( self, primaryState, secondaryState, f )
	if blocked( "claygun" ) then
		warnOnce( self, "clay gun" )
		-- true, true means "handled" -- the buttons are consumed and the real
		-- fire path never runs.
		return true, true
	end
	self.swWarned = nil
	return ClayRifle.client_onEquippedUpdate( self, primaryState, secondaryState, f )
end


--[[ fire launcher ]]

GuardedPotatoLauncher = class( PotatoLauncher )

function GuardedPotatoLauncher.client_onEquippedUpdate( self, primaryState, secondaryState, f )
	if blocked( "firelauncher" ) then
		warnOnce( self, "fire launcher" )
		return true, true
	end
	self.swWarned = nil
	return PotatoLauncher.client_onEquippedUpdate( self, primaryState, secondaryState, f )
end
