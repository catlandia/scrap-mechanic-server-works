-- MenuGui -- the front door.
--
-- Eight slash commands is not a user interface. This is one panel that opens
-- everything else, and it only shows a guest what a guest may actually use, so
-- nobody is offered a button whose only answer is "Host only."
--
-- Same widget vocabulary as the other panels; see SettingsGui.lua for where it
-- came from.

MenuGui = {}

MenuGui.W = 460
-- Tall enough for six entries plus the host header; the layout check in the
-- build script computes this rather than trusting the eye.
-- Seven entries plus the HOST header. The layout check computes whether this is
-- enough rather than trusting the eye -- it caught this exact panel overflowing
-- the moment the EVENT CLOCK entry was added.
-- Nine entries plus the HOST header, at a 54 pitch rather than 58 -- which is
-- what the DEV CHECKLIST entry cost. The layout check computes whether this is
-- enough rather than trusting the eye; it caught this exact panel overflowing
-- the moment the EVENT CLOCK entry was added, and it would have caught the
-- ninth entry landing on top of the CLOSE button.
MenuGui.H = 660

local BG = "0.055 0.062 0.078 1"
local PANEL = "1 1 1 1"
local ACCENT = "1 0.54 0.18 1"
local DIM = "0.62 0.65 0.72 1"
local LABEL = "0.90 0.92 0.96 1"

local function widget( t )
	t.Childs = t.Childs or {}
	if t.NeedKey == nil then t.NeedKey = true end
	if t.NeedMouse == nil then t.NeedMouse = true end
	return t
end

local function fill( name, x, y, w, h, colour, alpha )
	return widget{ Name = name, Type = "Widget", Skin = "WhiteSkin", Colour = colour,
		Alpha = alpha, x = x, y = y, width = w, height = h,
		NeedKey = false, NeedMouse = false }
end

local function text( name, caption, x, y, w, h, font, colour, align )
	return widget{ Name = name, Type = "TextBox", Skin = "TextBox", Caption = caption,
		FontName = font or "SM_Text", Colour = colour or LABEL,
		TextAlign = align or "Left", x = x, y = y, width = w, height = h,
		NeedKey = false, NeedMouse = false }
end

local function button( name, caption, x, y, w, h, skin, data, font )
	local b = widget{ Name = name, Type = "Button", Skin = skin or "SecondaryButton",
		Caption = caption, FontName = font or "SM_ButtonLarge", TextAlign = "Center",
		x = x, y = y, width = w, height = h }
	b.onClick = "cl_onMenuClick"
	b.onClickData = data
	return b
end

-- `panel` means this entry REPLACES the menu with another panel, rather than
-- answering in the chat log. It decides whether the click queues a close, and
-- getting that wrong is a race: queue a close on an entry that is about to open
-- something and the close can land on the panel that just arrived.
--
-- It is also the line the reported bug falls on. "these buttons dont work for no
-- reason. I am the host" came with a screenshot of the three host entries -- and
-- those three are exactly the ones with panel = true. The four above them answer
-- in chat and always worked.
MenuGui.ENTRIES = {
	{ action = "myplot", label = "MY PLOT", panel = true,
	  help = "claim ground, find it again, see your team", host = false },
	{ action = "rules", label = "SERVER RULES",
	  help = "the limits currently in force", host = false },
	{ action = "players", label = "WHO IS HERE",
	  help = "everyone online, with their ids", host = false },
	{ action = "help", label = "COMMANDS",
	  help = "everything you can type", host = false },
	{ action = "event", label = "EVENT CLOCK", panel = true,
	  help = "prep, build and buffer times -- start it here", host = true },
	{ action = "focus", label = "FOCUS PLAYER", panel = true,
	  help = "mark one person so the whole lobby can find them", host = true },
	{ action = "city", label = "CITY LAYOUT", panel = true,
	  help = "plots, roads and plaza, with a live map", host = true },
	{ action = "settings", label = "SERVER SETTINGS", panel = true,
	  help = "every toggle and limit", host = true },
	{ action = "checklist", label = "TESTING CHECKLIST", panel = true,
	  help = "things to try, one at a time. Say if each one worked", host = true },
}

function MenuGui.Build( isHost )
	local root = widget{ Name = "BackPanel", Type = "Widget", Skin = "PanelEmpty",
		Anchor = "Center", InheritsPick = true, NeedKey = false, NeedMouse = false,
		x = 0, y = 0, width = MenuGui.W, height = MenuGui.H }
	root.onClose = "cl_onMenuClose"
	local kids = root.Childs

	kids[#kids + 1] = fill( "BG", 0, 0, MenuGui.W, MenuGui.H, BG, 0.96 )
	kids[#kids + 1] = fill( "Band", 0, 0, MenuGui.W, 64, PANEL, 0.05 )
	kids[#kids + 1] = fill( "Rule", 0, 64, MenuGui.W, 2, ACCENT, 1 )
	kids[#kids + 1] = text( "Title", "SERVER WORKS", 24, 16, 320, 30,
		"SM_Header", LABEL, "Left" )
	kids[#kids + 1] = text( "Sub", isHost and "host" or "player", 24, 42, 320, 18,
		"SM_TextTiny", DIM, "Left" )

	local y = 88
	local hostHeader = false
	for i, e in ipairs( MenuGui.ENTRIES ) do
		if ( not e.host ) or isHost then
			if e.host and not hostHeader then
				hostHeader = true
				kids[#kids + 1] = text( "HostHead", "HOST", 24, y, 200, 16,
					"SM_LabelTiny", DIM, "Left" )
				y = y + 22
			end
			-- NOT "UpgradeButton". MEASURED, from a screenshot of the menu: that skin is a
			-- PROGRESS BAR, not a button. It drew as a gold-and-teal bar with NO CAPTION at
			-- all, which is why the host reported "I am the host why cant I access
			-- features" -- the two host entries were there and clickable, but unlabelled, so
			-- they read as broken widgets rather than buttons.
			--
			-- StyledButtonLarge is the skin CLOSE already uses on the same panel, so it is
			-- proven to draw its caption, and it stays visually distinct from the guest
			-- entries.
			kids[#kids + 1] = button( "B" .. i, e.label, 24, y, MenuGui.W - 48, 34,
				e.host and "StyledButtonLarge" or "SecondaryButton",
				{ action = e.action, panel = e.panel == true } )
			kids[#kids + 1] = text( "H" .. i, e.help, 26, y + 36, MenuGui.W - 52, 16,
				"SM_TextTiny", DIM, "Left" )
			y = y + 54
		end
	end

	kids[#kids + 1] = button( "Close", "CLOSE", MenuGui.W - 148, MenuGui.H - 50, 124, 32,
		"StyledButtonLarge", { action = "close" } )
	return root
end
