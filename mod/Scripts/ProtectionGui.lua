-- ProtectionGui -- the panic button, on a button.
--
-- REPORTED: "you have a bit too many commands that are not on menu... I want
-- the MENU to be the menu."
--
-- /lockdown was the worst example of that. It is the one thing a host reaches
-- for when something is going wrong mid-event, and reaching for it meant
-- knowing the word, spelling it, and knowing that `strict` and `display` are
-- the two arguments. This panel is three buttons and a readout.
--
-- WHAT THE READOUT IS FOR. The tool guard runs on the CLIENT -- sm.tool.forceTool
-- is client side and there is no server-authoritative version of it -- so "is
-- the lockdown on" has two halves that can disagree: what the server decided,
-- and what a given client was last told. /protection printed the server's half
-- so the two could be compared instead of argued about, and that half belongs
-- here now.
--
-- The host bubble is on it for a sharper reason. It has three states and two of
-- them look identical from inside the game: a host who cannot build cannot tell
-- "somebody is standing next to me" from "this feature is broken". Same class
-- as the panel that closed on every click whether or not the button worked.
--
-- Same widget vocabulary as every other panel here; see SettingsGui.lua for
-- where it came from.

ProtectionGui = {}

ProtectionGui.W = 680
-- Header, the state strip, five detail rows, three big buttons, the lift
-- button, a status line and the footer. The layout check computes whether that
-- fits rather than trusting the eye -- it has caught this exact class of
-- overflow on three panels now.
ProtectionGui.H = 660

local PAD = 26

local BG = "0.055 0.062 0.078 1"
local PANEL = "1 1 1 1"
local ACCENT = "1 0.54 0.18 1"
local GREEN = "0.30 0.86 0.42 1"
local RED = "0.92 0.34 0.30 1"
local DIM = "0.62 0.65 0.72 1"
local LABEL = "0.90 0.92 0.96 1"

local function widget( t )
	t.Childs = t.Childs or {}
	if t.NeedKey == nil then t.NeedKey = true end
	if t.NeedMouse == nil then t.NeedMouse = true end
	return t
end

local function fill( name, x, y, w, h, colour, alpha )
	return widget{ Name = name, Type = "Widget", Skin = "WhiteSkin",
		Colour = colour, Alpha = alpha, x = x, y = y, width = w, height = h,
		NeedKey = false, NeedMouse = false }
end

local function text( name, caption, x, y, w, h, font, colour, align )
	return widget{ Name = name, Type = "TextBox", Skin = "TextBox",
		Caption = caption, FontName = font or "SM_Text", Colour = colour or LABEL,
		TextAlign = align or "Left", x = x, y = y, width = w, height = h,
		NeedKey = false, NeedMouse = false }
end

local function button( name, caption, x, y, w, h, skin, data )
	local b = widget{ Name = name, Type = "Button", Skin = skin or "SecondaryButton",
		Caption = caption, FontName = "SM_ButtonLarge", TextAlign = "Center",
		x = x, y = y, width = w, height = h }
	b.onClick = "cl_onProtectionGuiClick"
	b.onClickData = data
	return b
end


--[[ the pure half ]]

-- What each mode means in one line, in the words a host would use rather than
-- the words the code uses. Pure, so dev/test_logic.py can read it back.
--
-- The three are deliberately not symmetrical. `locked` is the panic button and
-- says so; `display` is the one people forget exists, so its line names the
-- thing that separates it from strict.
ProtectionGui.STATES = {
	open = { label = "OPEN", colour = GREEN,
	         meaning = "people can build" },
	locked = { label = "LOCKED", colour = RED,
	           meaning = "nothing works at all -- no placing, breaking, painting, "
	               .. "lifting, seats or buttons" },
	display = { label = "LOCKED, SHOW MODE", colour = ACCENT,
	            meaning = "builds are frozen, but seats and buttons still work" },
}

function ProtectionGui.StateFor( mode )
	return ProtectionGui.STATES[tostring( mode )] or ProtectionGui.STATES.open
end

-- Which button is the one NOT to offer, because pressing it would change
-- nothing. A panel that offers you the state you are already in reads as a
-- panel that did not work when you press it.
function ProtectionGui.IsCurrent( mode, action )
	if action == "unlock" then return tostring( mode ) == "open" end
	if action == "lockdown" then return tostring( mode ) == "locked" end
	if action == "lockdownshow" then return tostring( mode ) == "display" end
	return false
end


--[[ the panel ]]

-- state: {
--   mode      "open" | "locked" | "display"
--   buildopen whether the host toggle allows building at all
--   bubble    what Plots.sv_bubbleStatus said
--   guest     tools blocked for a guest, already joined into a string
--   host      tools blocked for the host, likewise
--   physics   PhysicsQuality, the one simulation number this engine exposes
--   clock     the event phase if the clock owns building, else nil
--   status    what the last press did
-- }
function ProtectionGui.Build( state )
	state = state or {}
	local st = ProtectionGui.StateFor( state.mode )

	local root = widget{ Name = "BackPanel", Type = "Widget", Skin = "PanelEmpty",
		Anchor = "Center", InheritsPick = true, NeedKey = false, NeedMouse = false,
		x = 0, y = 0, width = ProtectionGui.W, height = ProtectionGui.H }
	root.onClose = "cl_onProtectionGuiClose"
	local kids = root.Childs

	kids[#kids + 1] = fill( "BG", 0, 0, ProtectionGui.W, ProtectionGui.H, BG, 0.96 )
	kids[#kids + 1] = fill( "Band", 0, 0, ProtectionGui.W, 64, PANEL, 0.05 )
	kids[#kids + 1] = fill( "Rule", 0, 64, ProtectionGui.W, 2, ACCENT, 1 )
	kids[#kids + 1] = text( "Title", "PROTECTION", PAD, 16, 400, 30,
		"SM_Header", LABEL, "Left" )
	kids[#kids + 1] = text( "Sub", "freeze the world, or let people build again",
		PAD, 42, 460, 18, "SM_TextTiny", DIM, "Left" )

	--[[ what the world is doing right now ]]

	local W = ProtectionGui.W - PAD * 2
	kids[#kids + 1] = fill( "StateStrip", PAD, 78, W, 52, PANEL, 0.10 )
	kids[#kids + 1] = fill( "StateBar", PAD, 78, 6, 52, st.colour, 1 )
	kids[#kids + 1] = text( "StateLabel", st.label, PAD + 18, 84, W - 36, 22,
		"SM_TextLarge", st.colour, "Left" )
	kids[#kids + 1] = text( "StateMeaning", st.meaning, PAD + 18, 108, W - 36, 18,
		"SM_TextTiny", DIM, "Left" )

	--[[ the detail nobody could see without typing /protection ]]

	local y = 144
	local function row( name, label, value, colour )
		kids[#kids + 1] = text( name .. "L", label, PAD, y, 200, 18,
			"SM_TextTiny", DIM, "Left" )
		kids[#kids + 1] = text( name .. "V", value, PAD + 200, y, W - 200, 18,
			"SM_TextTiny", colour or LABEL, "Left" )
		y = y + 24
	end

	row( "Build", "building", state.buildopen == false and "closed" or "open",
		state.buildopen == false and ACCENT or GREEN )
	-- The event clock outranks both buttons below while it is running, and
	-- saying so beats a button that appears to do nothing.
	if state.clock then
		row( "Clock", "the event clock owns it", tostring( state.clock ), ACCENT )
	end
	row( "Bubble", "you can build where you stand", tostring( state.bubble or "unknown" ) )
	row( "Guest", "blocked for a guest", tostring( state.guest or "nothing" ) )
	row( "Host", "blocked for you", tostring( state.host or "nothing" ) )
	if state.physics ~= nil then
		row( "Phys", "physics quality", tostring( state.physics ) )
	end

	--[[ the three doors ]]

	-- FIXED, not measured back from the bottom. The first version started the
	-- doors at H - 210 and the last one landed on top of BACK -- the fits check
	-- said "buttons 'NoLift' and 'Back' overlap, one of them cannot be pressed".
	-- The detail block above is at most six rows from y 144, so it ends by 288.
	local by = 300
	local function door( name, caption, help, action, colour )
		local current = ProtectionGui.IsCurrent( state.mode, action )
		kids[#kids + 1] = button( name, caption, PAD, by, W, 34,
			current and "SecondaryButton" or "StyledButtonLarge",
			{ action = action } )
		kids[#kids + 1] = text( name .. "H",
			current and ( help .. "   (this is what the world is doing now)" ) or help,
			PAD + 2, by + 36, W - 4, 16, "SM_TextTiny",
			current and DIM or ( colour or DIM ), "Left" )
		by = by + 56
	end

	door( "Lock", "LOCK DOWN", "nothing works at all. This is the panic button",
		"lockdown", RED )
	door( "Show", "LOCK DOWN -- SHOW MODE",
		"builds frozen, seats and buttons still work", "lockdownshow", ACCENT )
	door( "Unlock", "UNLOCK", "let people build again", "unlock", GREEN )

	--[[ the one cleanup that cannot eat anything ]]

	kids[#kids + 1] = button( "NoLift", "CLEAR STRANDED LIFTS",
		PAD, by + 8, 240, 28, "SecondaryButton", { action = "nolift" } )
	kids[#kids + 1] = text( "NoLiftH",
		"a lift nobody owns cannot be picked up by any lift tool",
		PAD + 250, by + 14, W - 250, 16, "SM_TextTiny", DIM, "Left" )
	-- THE EXEMPTION, ON A SWITCH YOU CAN SEE. It used to be on always, which
	-- made /lockdown indistinguishable from a broken /lockdown on a server with
	-- nobody else on it -- "even on lock down. I still can build everything and
	-- delete everything."
	kids[#kids + 1] = button( "Bubble",
		state.hostbuild and "MY BUBBLE: ON" or "MY BUBBLE: OFF",
		PAD, by + 42, 240, 28,
		state.hostbuild and "StyledButtonLarge" or "SecondaryButton",
		{ action = "hostbuild", on = not state.hostbuild } )
	kids[#kids + 1] = text( "BubbleH",
		state.hostbuild
			and "the ground within a few metres of you is unlocked. Everyone else is still locked out"
			or "the lockdown binds you too. Turn this on when you need to fix something",
		PAD + 250, by + 48, W - 250, 16, "SM_TextTiny",
		state.hostbuild and ACCENT or DIM, "Left" )

	kids[#kids + 1] = button( "Clay", "CLEAR CLAY AROUND ME",
		PAD, by + 76, 240, 28, "SecondaryButton", { action = "clearclay" } )
	kids[#kids + 1] = text( "ClayH",
		"clay is TERRAIN, not blocks -- this levels the ground with it",
		PAD + 250, by + 82, W - 250, 16, "SM_TextTiny", DIM, "Left" )

	--[[ what the last press did ]]

	kids[#kids + 1] = text( "Status", tostring( state.status or "" ),
		PAD, by + 116, W, 18, "SM_TextTiny", ACCENT, "Left" )

	kids[#kids + 1] = button( "Back", "BACK", PAD, ProtectionGui.H - 50, 124, 32,
		"StyledButtonLarge", { action = "back" } )
	kids[#kids + 1] = button( "Close", "CLOSE", ProtectionGui.W - 148,
		ProtectionGui.H - 50, 124, 32, "StyledButtonLarge", { action = "close" } )
	return root
end
