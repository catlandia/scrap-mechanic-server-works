-- PlotMarker -- "find my plot", on the compass the game already draws.
--
-- Asked for as: "use find my plot also when you own a plot so it will show your
-- plot with a marker. because there is a compasss feature."
--
-- There is, and it is reachable. CreativeGame.client_onCreate does
--
--     g_compassHud = sm.gui.createCompassHudGui()
--
-- (Data/Scripts/game/CreativeGame.lua:181) and we call that parent, so the
-- compass HUD exists in our game already and g_compassHud is a global on every
-- client. Nothing had to be built; it only had to be pointed at something.
--
-- The call shapes below are copied from vanilla's own use of it rather than
-- guessed:
--
--   compassAddIcon( name, icon, stacking, w, h )
--       Survival/.../managers/RaidManager.lua:1174   ( name, icon, true, 32 )
--       Survival/.../characters/BaseEnemyCharacter.lua:24  ( name, icon, false, 8, 12 )
--   compassSetIconWorldPosition( name, position )    RaidManager.lua:1175
--   compassSetIconStacking( name, false )            RaidManager.lua:1176
--   compassPingMarker( name, effect )                RaidManager.lua:1228
--   setVisible( name, bool )                         BaseEnemyCharacter.lua:26
--   compassRemoveIcon( name )                        BaseEnemyCharacter.lua:43
--
-- CLIENT ONLY, and per-player by construction: g_compassHud is that client's own
-- HUD, so a marker one player is shown is invisible to everybody else. That is
-- the property the owner wanted -- "only they can see it so it doesnt interfier"
-- -- and here it costs nothing, because there is no way to leak it even by
-- accident.
--
-- Every call is wrapped. The compass is a nicety; if a binding turns out to have
-- a different shape on some future build, the worst outcome must be "no marker",
-- never a client-side error every frame.

PlotMarker = {}

PlotMarker.NAME = "serverworks_plot"

-- icon_compass_main_quest.png is the "this is where you are going" arrow, which
-- is exactly what this is. Every icon in Data/Gui/Resolutions/*/Compass/ is
-- available; this one reads clearly at a glance and is not already used for
-- anything in a creative world.
PlotMarker.ICON = "icon_compass_main_quest.png"

local added = false
local faulted = false

local function guard( fn )
	if faulted or g_compassHud == nil then return false end
	local ok, err = pcall( fn )
	if not ok then
		-- Once, never per frame. The 1.79 GB log is why.
		faulted = true
		sm.log.warning( "[ServerWorks] compass marker unavailable: " .. tostring( err ) )
		return false
	end
	return true
end

-- Point the marker at a world position. Creates the icon the first time.
function PlotMarker.Cl_Show( position )
	if position == nil then return end
	guard( function()
		if not added then
			g_compassHud:compassAddIcon( PlotMarker.NAME, PlotMarker.ICON, true, 32 )
			-- Stacking off: this is the only marker we ever add, and stacking is
			-- for collapsing a crowd of them into one.
			g_compassHud:compassSetIconStacking( PlotMarker.NAME, false )
			added = true
		end
		g_compassHud:compassSetIconWorldPosition( PlotMarker.NAME, position )
		g_compassHud:setVisible( PlotMarker.NAME, true )
	end )
end

function PlotMarker.Cl_Hide()
	if not added then return end
	guard( function() g_compassHud:setVisible( PlotMarker.NAME, false ) end )
end

-- A one-off flash, so pressing "find my plot" does something visible even when
-- the marker was already on screen.
function PlotMarker.Cl_Ping()
	if not added then return end
	guard( function()
		g_compassHud:compassPingMarker( PlotMarker.NAME, "Gui - Pingnavigation" )
	end )
end
