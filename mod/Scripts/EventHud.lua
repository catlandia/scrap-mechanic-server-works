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
-- WHERE THE PANEL GOES, AND WHY IT TOOK THREE TRIES
--
-- Asked for, in the end, as precisely the right instruction: "take the screen
-- resolution of the game. take the top right corner. take the pixels of the
-- timer UI. make so that it is fully on screen. and add couple of bufer pixels."
-- That is what the code below does. Getting there needed two facts that are not
-- written down anywhere.
--
-- 1. Anchor = "TopRight" IS NOT A VALUE THIS ACCEPTS. It is in the executable's
--    string table, which is what made it look plausible, and the widget is just
--    centred instead. MEASURED from a screenshot: on 2560x1080 the panel landed
--    middle-left, and working back from where it landed said it had been
--    centred and then offset by our own numbers.
--
-- 2. A ROOT WIDGET'S x,y IS ITS CENTRE, MEASURED FROM THE CENTRE OF THE CANVAS,
--    with +y downwards. Not a top-left offset. Derived from vanilla's own status
--    panel (Survival/Scripts/game/SurvivalPlayer.lua:424), which puts itself
--    bottom-left with
--
--        root.x = math.floor( -screenWidth  / 2 + root.width  * 0.5 )
--        root.y = math.floor(  screenHeight / 2 - root.height * 0.5 )
--
--    Solve those and the meaning falls out: left edge at -W/2, bottom edge at
--    +H/2. So x,y is the centre.
--
-- The version before this one made the ROOT the size of the whole screen and put
-- the content in its corner. That is sound arithmetic and it still did not draw,
-- because of the third fact:
--
-- 3. sm.gui.getScreenSize IS THE WINDOW. sm.jsonGui.getViewSize IS THE CANVAS
--    WIDGET UNITS ARE IN. They are different numbers -- the game ships GUI skins
--    for 1280x720, 1920x1080, 2560x1440 and 3840x2160 and picks one, so a
--    3440x1440 monitor is not a 3440x1440 canvas. A root declared 3440 wide in a
--    canvas narrower than that hangs off the edge, and everything in its top
--    right corner is off screen entirely. Which is exactly what "I dont see
--    timer" was.
--
--    sm.jsonGui.getViewSize is the function vanilla uses for this, in all three
--    places it positions a HUD: SurvivalPlayer.lua:424,
--    ChallengePlayer.lua:180, MechanicCharacter.lua:194.
--
-- So: the root is the size of the PANEL, and it is placed by its centre, at the
-- top right of the canvas, inset by MARGIN. Then it is clamped, so that even if
-- getViewSize ever returns something smaller than the panel the panel stays on
-- screen rather than disappearing off it.

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
-- The buffer pixels. 18 canvas units clears the compass and the corner of the
-- screen on every reference resolution the game ships, and EventHud.TopRight
-- clamps rather than honours it if a canvas is ever too small to fit both the
-- panel and the margin.
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

-- The CANVAS, not the window. sm.jsonGui.getViewSize is what vanilla positions
-- its own HUDs against; sm.gui.getScreenSize is the second choice and only
-- because a HUD in slightly the wrong place beats no HUD at all.
function EventHud.ScreenSize()
	local ok, a, b = pcall( sm.jsonGui.getViewSize )
	if not ok or type( a ) ~= "number" then
		ok, a, b = pcall( sm.gui.getScreenSize )
	end
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

-- The centre of the panel, measured from the centre of the canvas, so that the
-- panel sits in the top right corner with MARGIN of clear space around it.
--
-- Clamped, which is the "make so that it is fully on screen" half: if the canvas
-- ever comes back smaller than the panel, the panel is pinned inside it rather
-- than allowed to hang off an edge where it cannot be seen.
function EventHud.TopRight( canvasW, canvasH )
	local m = EventHud.MARGIN
	local x = canvasW * 0.5 - EventHud.W * 0.5 - m
	local y = -canvasH * 0.5 + EventHud.H * 0.5 + m

	-- Never further right than the right edge, never left of the left edge.
	local maxX = canvasW * 0.5 - EventHud.W * 0.5
	local maxY = canvasH * 0.5 - EventHud.H * 0.5
	if x > maxX then x = maxX end
	if x < -maxX then x = -maxX end
	if y > maxY then y = maxY end
	if y < -maxY then y = -maxY end

	return math.floor( x ), math.floor( y )
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
-- WHAT THE HUD SAYS UNDER THE CLOCK, and it has to know about the lockdown.
--
-- MEASURED, from a screenshot: the host typed /lockdown, chat said "BUILDS
-- LOCKED (strict)", and the top-right corner of the same frame said **build
-- freely**. The hint was Event.HINTS[phase] and nothing else, so with no event
-- running it read "off" and printed the one thing that was not true.
--
-- The payload already carried the answer. Game.sv_pushEvent has sent `mode` and
-- `canBuild` since V28, precisely because "the client has no way to know: it can
-- see the phase, but /lockdown and a host toggle are invisible to it" -- and
-- then the HUD went on ignoring both. A field that is sent and never read is
-- worse than one that was never sent: it looks like the case is handled.
--
-- PROTECTION OUTRANKS THE PHASE, because /lockdown outranks the clock in the
-- resolver too (Protection.profileFor short-circuits on a locked mode before it
-- consults anything else). Saying it in the other order would put "build on
-- your own plot" on screen during a lockdown.
--
-- Pure, so dev/test_logic.py can read every combination back without a game.
function EventHud.Hint( state )
	state = state or {}
	if state.paused then return "PAUSED by the host" end

	local mode = tostring( state.mode or "" )
	if mode == "locked" then
		return "LOCKED -- nothing can be touched"
	end
	if mode == "display" then
		return "LOCKED -- buttons still work"
	end
	-- Not a locked mode, but building is shut anyway: the host's own buildopen
	-- toggle, or a phase that closes it. The phase hint is the better wording
	-- when there IS a phase, because it says which part of the event you are in.
	local phase = tostring( state.phase or "off" )
	if state.canBuild == false and phase == "off" then
		return "building is closed"
	end
	return Event.HINTS[phase] or ""
end

function EventHud.Build( state, screenW, screenH )
	state = state or {}
	screenW = screenW or EventHud.FALLBACK_W
	screenH = screenH or EventHud.FALLBACK_H

	local phase = state.phase or "off"
	local colour = state.panic and EventHud.COLOURS.panic
		or ( EventHud.COLOURS[phase] or EventHud.COLOURS.off )

	-- The root is the PANEL, placed by its centre at the top right of the canvas.
	-- See the note at the top of this file for why it is not the whole screen and
	-- why x,y is a centre rather than a corner.
	local x, y = EventHud.TopRight( screenW, screenH )
	local root = widget{ Name = "EventHud", Type = "Widget", Skin = "PanelEmpty",
		Anchor = "Center", InheritsPick = false,
		x = x, y = y, width = EventHud.W, height = EventHud.H }
	local kids = root.Childs

	-- Children are ordinary top-left offsets inside the root.
	local ox, oy = 0, 0

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

	local hint = EventHud.Hint( state )
	kids[#kids + 1] = text( "HudHint", hint, ox + 16, oy + 56, EventHud.W - 28, 16,
		"SM_TextTiny", DIM, "Left" )

	return root
end
