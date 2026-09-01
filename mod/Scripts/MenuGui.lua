-- MenuGui -- the front door.
--
-- Eight slash commands is not a user interface. This is one panel that opens
-- everything else, and it only shows a guest what a guest may actually use, so
-- nobody is offered a button whose only answer is "Host only."
--
-- Same widget vocabulary as the other panels; see SettingsGui.lua for where it
-- came from.

MenuGui = {}

-- TWO COLUMNS, AND THE REASON IS THE CANVAS RATHER THAN TASTE.
--
-- sm.jsonGui.getViewSize() is 1720x720 on this owner's monitor -- half the
-- window, and the units every coordinate here is in. So a panel taller than
-- about 690 hangs off the bottom of the screen, and that is a hard ceiling
-- rather than a guideline: SettingsGui at 690 is already within 30 of it.
--
-- One column at a 54 pitch ran out at nine entries. "I want the MENU to be the
-- menu" needs twelve. Columns are the only direction left.
--
-- The split is by AUDIENCE, not by arithmetic: everything on the left is
-- something a guest may use, everything on the right is host only. A guest sees
-- one column and no empty space where the other would be.
MenuGui.COL_W = 400
MenuGui.PAD = 24
MenuGui.GAP = 28
MenuGui.PITCH = 54

MenuGui.W = MenuGui.PAD * 2 + MenuGui.COL_W * 2 + MenuGui.GAP
-- Header, the tallest column, and the footer. The layout check computes this
-- rather than trusting the eye -- it caught this exact panel overflowing the
-- moment the EVENT CLOCK entry was added, and again at the ninth entry, and a
-- third time when COMMANDS moved to the host column and made nine.
--
-- The ceiling is the CANVAS, not taste: sm.jsonGui.getViewSize() is 1720x720,
-- so anything over about 690 hangs off the bottom of the screen with no error
-- anywhere. A check asserts every panel in this mod stays under it.
MenuGui.H = 680

-- WHAT THIS MOD IS, SAID ON THE FRONT DOOR.
--
-- ASKED FOR: "add a disclaimer that the mod is a WORK IN PROGRESS". It belongs
-- here rather than only in the join message, because the join message scrolls
-- away in the first minute of a busy lobby and this panel is what somebody is
-- looking at when a button does something they did not expect.
--
-- Plain ASCII, and that is not an accident: the game builds a limited glyph
-- atlas per font out of the strings it draws itself, so anything clever here
-- comes out as a row of hollow boxes. See the font section in CLAUDE.md.
MenuGui.WIP = "WORK IN PROGRESS -- most of this has never run in a real event"

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
	{ action = "players", label = "WHO IS HERE", panel = true,
	  help = "everyone online, plus the ban list -- kick, ban and unban",
	  host = false },
	{ action = "rules", label = "SERVER RULES",
	  help = "the limits currently in force", host = false },
	-- COMMANDS WAS HERE AND IS NOT ANY MORE, and it was the right one to lose.
	-- The column has a hard ceiling -- the canvas is 720 units tall, so nine
	-- host entries is what fits -- and a BANS entry had to come from somewhere.
	--
	-- Of everything on this panel, a list of chat commands was the only entry
	-- whose whole content is available by typing the thing it describes. The
	-- host can still type /sw. Nobody can type a ban list into existence.

	{ action = "event", label = "EVENT CLOCK", panel = true,
	  help = "prep, build and buffer times -- start it here", host = true },
	{ action = "protection", label = "PROTECTION", panel = true,
	  help = "lock the world down, or open it again", host = true },
	{ action = "city", label = "CITY LAYOUT", panel = true,
	  help = "plots, roads and plaza, with a live map", host = true },
	{ action = "settings", label = "SERVER SETTINGS", panel = true,
	  help = "every toggle and limit", host = true },
	{ action = "backups", label = "BACKUPS", panel = true,
	  help = "save the world now, or put it back", host = true },
	{ action = "focus", label = "FOCUS PLAYER", panel = true,
	  help = "mark one person so the whole lobby can find them", host = true },
	-- BANS IS ITS OWN ENTRY. Asked for twice -- "make it accesible via menu",
	-- then "where is the ban? I want the ban UI to be in the menu" -- and both
	-- times the answer had been "it is, one tab inside WHO IS HERE". One tab in
	-- is not on the menu. Moderation is reached for while something is going
	-- wrong, which is the worst moment to be hunting through a panel.
	--
	-- It opens on EVERYONE SEEN rather than on the ban list, because that view
	-- is a superset: it shows who is already banned AND is the only place you
	-- can ban somebody. Landing on the list would put a click between the host
	-- and the only action they came for.
	{ action = "bans", label = "BANS", panel = true,
	  help = "ban or unban anybody the server has ever seen", host = true },

	-- BEHIND /developer on, AND OFF BY DEFAULT.
	--
	-- "buttons are good. but too many buttons is too much" -- and these two are
	-- the ones an event never wants. They are not merely noisy: DEV TOOLS is one
	-- click from a hundred and twenty-eight bots and from a channel that runs
	-- host commands from outside the game, and the checklist runs whatever
	-- command the item under the cursor names. Settings.DeveloperOn gates them
	-- here, in sv_n_menuOpen, in sv_n_openPanel and in the command gate, because
	-- a hidden button is not a closed door.
	{ action = "dev", label = "DEV TOOLS", panel = true, dev = true,
	  help = "fake crowd, benchmark, outside control. Not for a live event",
	  host = true },
	{ action = "checklist", label = "TESTING CHECKLIST", panel = true, dev = true,
	  help = "things to try, one at a time. Say if each one worked", host = true },
}

-- Which column an entry belongs in. Audience, not arithmetic -- see the note on
-- MenuGui.W. Pure, so dev/test_logic.py can check the split without a game.
--
-- `developer` decides whether the two dev entries exist at all. It is a
-- separate argument rather than folded into isHost because they are different
-- questions: one is who you are, the other is what mode the server is in.
function MenuGui.Columns( isHost, developer )
	local left, right = {}, {}
	for _, e in ipairs( MenuGui.ENTRIES ) do
		if e.dev and developer ~= true then
			-- not offered, in either column
		elseif e.host then
			if isHost then right[#right + 1] = e end
		else
			left[#left + 1] = e
		end
	end
	return left, right
end

function MenuGui.Build( isHost, developer )
	local root = widget{ Name = "BackPanel", Type = "Widget", Skin = "PanelEmpty",
		Anchor = "Center", InheritsPick = true, NeedKey = false, NeedMouse = false,
		x = 0, y = 0, width = MenuGui.W, height = MenuGui.H }
	root.onClose = "cl_onMenuClose"
	local kids = root.Childs

	kids[#kids + 1] = fill( "BG", 0, 0, MenuGui.W, MenuGui.H, BG, 0.96 )
	kids[#kids + 1] = fill( "Band", 0, 0, MenuGui.W, 64, PANEL, 0.05 )
	kids[#kids + 1] = fill( "Rule", 0, 64, MenuGui.W, 2, ACCENT, 1 )
	kids[#kids + 1] = text( "Title", "SERVER WORKS", MenuGui.PAD, 16, 320, 30,
		"SM_Header", LABEL, "Left" )
	kids[#kids + 1] = text( "Sub",
		( isHost and "host" or "player" )
			.. ( developer and "   --   developer mode" or "" ),
		MenuGui.PAD, 42, 320, 18, "SM_TextTiny",
		developer and ACCENT or DIM, "Left" )
	-- Right-aligned in the header band, out of the title's way. Everybody sees
	-- it, host and guest alike -- a guest hitting a rough edge is the person
	-- most likely to think the server is broken rather than unfinished.
	kids[#kids + 1] = text( "Wip", MenuGui.WIP,
		MenuGui.W - MenuGui.PAD - 460, 34, 460, 18, "SM_TextTiny", ACCENT, "Right" )

	local left, right = MenuGui.Columns( isHost, developer )

	local n = 0
	local function column( entries, x, header )
		if #entries == 0 then return end
		local y = 88
		kids[#kids + 1] = text( "Head" .. x, header, x, y, 240, 16,
			"SM_LabelTiny", DIM, "Left" )
		y = y + 22
		for _, e in ipairs( entries ) do
			n = n + 1
			-- NOT "UpgradeButton". MEASURED, from a screenshot of the menu: that
			-- skin is a PROGRESS BAR, not a button. It drew as a gold-and-teal
			-- bar with NO CAPTION at all, which is why the host reported "I am
			-- the host why cant I access features" -- the entries were there and
			-- clickable, but unlabelled, so they read as broken widgets.
			--
			-- StyledButtonLarge is the skin CLOSE already uses on the same
			-- panel, so it is proven to draw its caption.
			kids[#kids + 1] = button( "B" .. n, e.label, x, y, MenuGui.COL_W, 34,
				e.host and "StyledButtonLarge" or "SecondaryButton",
				{ action = e.action, panel = e.panel == true } )
			kids[#kids + 1] = text( "H" .. n, e.help, x + 2, y + 36,
				MenuGui.COL_W - 4, 16, "SM_TextTiny", DIM, "Left" )
			y = y + MenuGui.PITCH
		end
	end

	column( left, MenuGui.PAD, "EVERYONE" )
	column( right, MenuGui.PAD + MenuGui.COL_W + MenuGui.GAP, "HOST" )

	-- Where the two missing entries went. Without this the switch is a secret,
	-- and a secret switch is the same bug as a button with no caption: the
	-- feature is there and nothing on screen says so.
	if isHost then
		kids[#kids + 1] = text( "DevHint",
			developer
				and "developer mode is ON -- type  /developer off  to hide the test tools"
				or "type  /developer on  for the test tools: crowd, benchmark, checklist",
			MenuGui.PAD, MenuGui.H - 42, 600, 16, "SM_TextTiny", DIM, "Left" )
	end

	kids[#kids + 1] = button( "Close", "CLOSE", MenuGui.W - 148, MenuGui.H - 50,
		124, 32, "StyledButtonLarge", { action = "close" } )
	return root
end
