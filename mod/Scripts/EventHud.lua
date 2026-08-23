-- EventHud -- the clock in the top right, and the handover to the warehouse timer.
--
-- Asked for as: "the time needs to be show at all times in top right corner.
-- also. when theres five minutes left. we can change the calm timer and use the
-- warehouse explosion timer."
--
-- Both halves are the engine's, not ours.
--
--
-- THE CALM TIMER
--
-- A json GUI created with isHud = true draws over the game and takes no input.
-- Vanilla's own event timer does exactly this
-- (Data/Scripts/game/managers/NotificationManager.lua, cl_createEventTimer):
--
--     sm.jsonGui.createGui{ layer = "Wallpaper", isInteractive = false,
--                           needsCursor = false, isHud = true }
--
-- so those four flags are copied rather than guessed. Anchor = "TopRight" is
-- the one thing here that is NOT copied from vanilla -- "TopRight", "TopLeft",
-- "BottomRight", "HCenter" and friends are all in the executable's string table
-- next to "Center", which our other panels already anchor by, so it is a strong
-- inference. If it comes out in the wrong corner, that is why, and the fix is
-- one string.
--
--
-- THE WAREHOUSE TIMER
--
-- This is the real find. Vanilla's warehouse self destruct is:
--
--     NotificationManager.Cl_CreateEventTimer( priority, "explosion" )
--     timer:update( visible, secondsRemaining )
--     timer:destroy()
--
-- (Survival/Scripts/game/scriptableObjects/WarehouseDestruction.lua:122.)
-- NotificationManager lives in $GAME_DATA and is registered `"singleton": true`
-- in Data/ScriptableObjects/.../sob_managers.sobset, so the engine creates it in
-- our game too -- nothing to build, only something to point at.
--
-- FIVE MINUTES IS THE RIGHT NUMBER FOR A REASON. survival_constants.lua:186 sets
-- WAREHOUSE_DESTRUCTION_TICKS = 40 * 60 * 5, and NotificationManager splits
-- exactly that into three escalating alarms -- one from 5:00, the next from
-- 3:20, the last from 1:40. Hand over at five minutes and those land where the
-- sound designer put them. Hand over anywhere else and the alarms are out of
-- step with the number on screen.
--
--
-- SMOOTHNESS. The server sends the remaining time about once a second, which is
-- all a MM:SS clock needs but is visibly jerky on the warehouse timer, which
-- renders tenths and hundredths. So the client remembers which tick each update
-- arrived on and subtracts elapsed ticks since -- the display is interpolated,
-- the truth is still the server's.

EventHud = {}

EventHud.W = 210
EventHud.H = 78
EventHud.MARGIN = 18

local BG = "0.055 0.062 0.078 1"
local PANEL = "1 1 1 1"
local DIM = "0.62 0.65 0.72 1"
local LABEL = "0.90 0.92 0.96 1"

-- One colour per phase, so the corner is readable without reading it.
EventHud.COLOURS = {
	off = "0.62 0.65 0.72 1",
	prep = "1 0.74 0.35 1",       -- amber: get ready
	build = "0.30 0.86 0.42 1",   -- green: go
	ended = "0.95 0.35 0.35 1",   -- red: stop
	panic = "0.98 0.30 0.24 1",   -- the last five minutes
}

local function widget( t )
	t.Childs = t.Childs or {}
	t.NeedKey = false
	t.NeedMouse = false
	return t
end

local function fill( name, x, y, w, h, colour, alpha )
	return widget{ Name = name, Type = "Widget", Skin = "WhiteSkin",
		Colour = colour, Alpha = alpha, x = x, y = y, width = w, height = h }
end

local function text( name, caption, x, y, w, h, font, colour, align )
	return widget{ Name = name, Type = "TextBox", Skin = "TextBox",
		Caption = caption, FontName = font or "SM_Text", Colour = colour or LABEL,
		TextAlign = align or "Left", x = x, y = y, width = w, height = h }
end

-- state is Event.sv_clientState plus the locally interpolated `remaining`.
function EventHud.Build( state )
	state = state or {}
	local phase = state.phase or "off"
	local colour = state.panic and EventHud.COLOURS.panic
		or ( EventHud.COLOURS[phase] or EventHud.COLOURS.off )

	local root = widget{ Name = "EventHud", Type = "Widget", Skin = "PanelEmpty",
		Anchor = "TopRight", InheritsPick = false,
		x = -EventHud.MARGIN - EventHud.W, y = EventHud.MARGIN,
		width = EventHud.W, height = EventHud.H }
	local kids = root.Childs

	kids[#kids + 1] = fill( "HudBG", 0, 0, EventHud.W, EventHud.H, BG, 0.78 )
	-- A bar down the left edge in the phase colour. Cheaper to read at a glance
	-- than coloured text, and it survives being looked at out of the corner of
	-- an eye while you are building.
	kids[#kids + 1] = fill( "HudBar", 0, 0, 4, EventHud.H, colour, 1 )

	kids[#kids + 1] = text( "HudPhase",
		Event.LABELS[phase] or phase, 16, 8, EventHud.W - 28, 16,
		"SM_LabelTiny", colour, "Left" )

	local clock = Event.Clock( state.remaining )
	if phase == "off" or phase == "ended" then
		clock = phase == "ended" and "TIME" or "--:--"
	end
	kids[#kids + 1] = text( "HudClock", clock, 16, 24, EventHud.W - 28, 34,
		"SM_HeaderSmall_Medium", LABEL, "Left" )

	local hint = Event.HINTS[phase] or ""
	if state.paused then hint = "PAUSED by the host" end
	kids[#kids + 1] = text( "HudHint", hint, 16, 56, EventHud.W - 28, 16,
		"SM_TextTiny", DIM, "Left" )

	return root
end
