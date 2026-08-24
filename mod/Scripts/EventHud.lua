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
-- so those four flags are copied rather than guessed.
--
--
-- WHY THE ROOT IS THE WHOLE SCREEN
--
-- The first attempt anchored the panel with Anchor = "TopRight", on the grounds
-- that "TopRight" sits in the executable's string table right next to "Center",
-- which our other panels anchor by. It is NOT a valid value here. MEASURED, from
-- a screenshot: the panel landed in the middle-left of the screen, and working
-- backwards from where it landed says the anchor was ignored and the widget was
-- centred instead --
--
--   screen 2560x1080, panel declared 210x78, drawn 317x122 at (768, 503)
--   centre (1280, 540) + our offset (-228, 18) x 1.51  =  (938, 567)
--   the panel's actual centre was                          (927, 564)
--
-- -- which also says the GUI canvas is scaled about 1.5x away from the units we
-- declare widgets in, and that scale depends on the player's resolution.
--
-- So do not fight it. Make the ROOT the size of the screen and anchor that to
-- the centre, which is the one anchor known to work. The root then covers the
-- display exactly, and a child placed at (screenW - margin - width, margin)
-- lands in the true top right on any monitor -- 16:9, ultrawide, anything.
--
-- The scale factor never has to be known, only the canvas size, which is exactly
-- what sm.gui.getScreenSize is for.
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
	buffer = "1 0.62 0.25 1",     -- amber again: hands off, nothing frozen yet
	ended = "0.95 0.35 0.35 1",   -- red: stop
	panic = "0.98 0.30 0.24 1",   -- the last five minutes
}

-- The GUI canvas size in the same units widgets are declared in. Returned as two
-- numbers in the shape we expect, but pcall'd and shape-checked because this is
-- one of the bindings with no vanilla Lua caller to copy -- nothing in
-- Data/ or Survival/ calls getScreenSize, so its return shape is inferred.
--
-- The fallback is 1920x1080 rather than nothing: a HUD in slightly the wrong
-- place still tells you how long is left, and a HUD that refuses to draw does
-- not.
EventHud.FALLBACK_W = 1920
EventHud.FALLBACK_H = 1080

function EventHud.ScreenSize()
	local ok, a, b = pcall( sm.gui.getScreenSize )
	if ok and type( a ) == "number" and type( b ) == "number" and a > 0 and b > 0 then
		return a, b
	end
	-- vec2/vec3 userdata, or a plain table
	if ok and a ~= nil and type( a ) ~= "number" then
		local gotx, x = pcall( function() return a.x end )
		local goty, y = pcall( function() return a.y end )
		if gotx and goty and type( x ) == "number" and type( y ) == "number"
			and x > 0 and y > 0 then
			return x, y
		end
	end
	return EventHud.FALLBACK_W, EventHud.FALLBACK_H
end

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
-- screenW/screenH come from EventHud.ScreenSize(); they are arguments rather
-- than read here so the layout can be checked at any resolution outside the game.
function EventHud.Build( state, screenW, screenH )
	state = state or {}
	screenW = screenW or EventHud.FALLBACK_W
	screenH = screenH or EventHud.FALLBACK_H

	local phase = state.phase or "off"
	local colour = state.panic and EventHud.COLOURS.panic
		or ( EventHud.COLOURS[phase] or EventHud.COLOURS.off )

	-- The root is the whole display. Centre is the anchor that is known to work,
	-- and a screen-sized widget centred on the screen covers it exactly.
	local root = widget{ Name = "EventHud", Type = "Widget", Skin = "PanelEmpty",
		Anchor = "Center", InheritsPick = false,
		x = 0, y = 0, width = screenW, height = screenH }
	local kids = root.Childs

	-- Top right of the root, which is now top right of the screen.
	local ox = screenW - EventHud.MARGIN - EventHud.W
	local oy = EventHud.MARGIN

	kids[#kids + 1] = fill( "HudBG", ox, oy, EventHud.W, EventHud.H, BG, 0.78 )
	-- A bar down the left edge in the phase colour. Cheaper to read at a glance
	-- than coloured text, and it survives being looked at out of the corner of
	-- an eye while you are building.
	kids[#kids + 1] = fill( "HudBar", ox, oy, 4, EventHud.H, colour, 1 )

	kids[#kids + 1] = text( "HudPhase",
		Event.LABELS[phase] or phase, ox + 16, oy + 8, EventHud.W - 28, 16,
		"SM_LabelTiny", colour, "Left" )

	local clock = Event.Clock( state.remaining )
	if phase == "off" then
		clock = "--:--"
	elseif phase == "ended" then
		clock = "TIME"
	end
	kids[#kids + 1] = text( "HudClock", clock, ox + 16, oy + 24, EventHud.W - 28, 34,
		"SM_HeaderSmall", LABEL, "Left" )

	local hint = Event.HINTS[phase] or ""
	if state.paused then hint = "PAUSED by the host" end
	kids[#kids + 1] = text( "HudHint", hint, ox + 16, oy + 56, EventHud.W - 28, 16,
		"SM_TextTiny", DIM, "Left" )

	return root
end
