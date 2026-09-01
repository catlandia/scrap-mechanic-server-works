-- PeopleGui -- who is here, and what a host can do about it.
--
-- REPORTED: "I want the MENU to be the menu." WHO IS HERE was a chat dump, and
-- /kick /ban /unban /banlist /allow /unallow had no button between them -- six
-- commands, every one of which is reached for while something is going wrong
-- and none of which forgives a typo.
--
-- ONE PANEL FOR BOTH AUDIENCES. A guest sees the roster, which is what /players
-- always gave them and is a fair thing for a lobby to know. The host sees the
-- same rows with KICK and BAN on them, plus a second view for the ban list.
-- state.host decides, and the server decides state.host -- a client that lies
-- about it gets the buttons drawn and every action refused, because
-- sv_n_peopleGuiAction gates on sm.player.getHostPlayer() like everything else.
--
-- THE NAME-WITH-A-SPACE BUG IS WHY THE BUTTONS MATTER MORE THAN THE COMMANDS.
-- sm.game.bindChatCommand splits on spaces and has no quoting, so /kick June
-- Carya only ever saw "June". The commands work around it by rejoining trailing
-- params; a button carries the id and cannot get it wrong at all.
--
-- Same widget vocabulary as every other panel here; see SettingsGui.lua for
-- where it came from.

PeopleGui = {}

PeopleGui.W = 760
-- Header, the view switch, seven rows, a pager, a status line and the footer.
-- The layout check computes whether that fits rather than trusting the eye.
PeopleGui.H = 620

PeopleGui.ROWS = 7

-- BANNING IS A LIST YOU CLICK, NOT A NAME YOU TYPE.
--
-- Two things were wrong and the second one swallows the first.
--
-- The first: every ban button hung off a roster row, so the panel could ban
-- whoever was online and nobody else -- which is backwards for the case bans
-- exist for. A griefer leaves, and THEN you want them on the list.
--
-- The second, and it is why a text box was never the answer. REPORTED: "nicks
-- in scrap mechanic to ban needs to be writen exactly. since names can be
-- strange. this wont work." Exactly right. A Scrap Mechanic display name can
-- hold characters that are not on the host's keyboard at all, so for some
-- players there is NO string the host could enter -- and the engine's own
-- /kick has the same disease, plus a parser that splits on spaces with no
-- quoting.
--
-- So the third view is EVERYONE SEEN: every player Identity has ever recorded,
-- one row each, with the button carrying their PERMA ID (SW-0007). Nothing is
-- typed and nothing can be mistyped. That is also the id the ban is stored
-- under, so the thing clicked and the thing recorded are the same value all the
-- way down.
--
-- The search box is a FILTER over that list, never a target. Typing narrows
-- what is shown; the click is still what bans. A host who cannot type a name at
-- all can page to it, or filter on the perma id, which is always ASCII.
--
-- ONE EditBox in a tree, and it lives in the EVERYONE SEEN view only. The event
-- clock crashed the game twice over typed input and the surviving rules are:
-- one box per tree, and its handler may not touch the GUI. See
-- Game.cl_onEventTimeTyped.
PeopleGui.SEARCH_BOX = "PeopleSearch"

PeopleGui.VIEWS = { "here", "bans", "known" }

local PAD = 26
local ROW_H = 46
local ROW_TOP = 178

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
	b.onClick = "cl_onPeopleGuiClick"
	b.onClickData = data
	return b
end


--[[ the pure half ]]

-- EVERYONE SEEN spends a row's worth of height on the filter box, so it shows
-- one fewer. Derived rather than written down twice: a second constant would be
-- the thing that goes stale the day either number moves.
function PeopleGui.HasSearch( view )
	return view == "known"
end

function PeopleGui.RowsFor( view )
	return PeopleGui.HasSearch( view ) and ( PeopleGui.ROWS - 1 ) or PeopleGui.ROWS
end

function PeopleGui.TopFor( view )
	return PeopleGui.HasSearch( view ) and ( ROW_TOP + ROW_H ) or ROW_TOP
end

-- The filter over EVERYONE SEEN. A fragment of any alias, or of the perma id --
-- which matters more than it looks: the perma is always ASCII, so it is the one
-- handle on a player whose display name the host cannot type a single character
-- of. Pure, so dev/test_logic.py checks it without a game.
function PeopleGui.Filter( rows, query )
	local q = string.lower( tostring( query or "" ) )
	-- gsub returns two values; the parens keep only the string, or the count
	-- would ride along into the comparison below.
	q = ( q:gsub( "^%s+", "" ):gsub( "%s+$", "" ) )
	if q == "" then return rows or {} end
	local out = {}
	for _, r in ipairs( rows or {} ) do
		local name = string.lower( tostring( r.name or "" ) )
		local perma = string.lower( tostring( r.perma or "" ) )
		if string.find( name, q, 1, true ) or string.find( perma, q, 1, true ) then
			out[#out + 1] = r
		end
	end
	return out
end

function PeopleGui.Page( list, page, view )
	local rows = PeopleGui.RowsFor( view )
	local total = #list
	local pages = math.max( 1, math.ceil( total / rows ) )
	page = math.max( 1, math.min( pages, math.floor( tonumber( page ) or 1 ) ) )
	local from = ( page - 1 ) * rows + 1
	local slice = {}
	for i = from, math.min( total, from + rows - 1 ) do
		slice[#slice + 1] = list[i]
	end
	return slice, page, pages
end

-- The line under a row in EVERYONE SEEN. The perma comes FIRST, because it is
-- the value the button carries and the value the ban is filed under -- if a
-- host ever has to say out loud who they banned, that is the string to read.
function PeopleGui.KnownSubtitle( row, allowlist )
	local bits = { tostring( row.perma or "?" ) }
	local aliases = math.floor( tonumber( row.aliases ) or 0 )
	if aliases > 0 then
		bits[#bits + 1] = string.format( "%d other name%s", aliases,
			aliases == 1 and "" or "s" )
	end
	if row.banned then bits[#bits + 1] = "BANNED" end
	if allowlist then
		bits[#bits + 1] = row.allowed and "ALLOWED" or "not on the allow list"
	end
	return table.concat( bits, "   " )
end

-- One line under each name: what the server knows about them. Pure, so the
-- wording is checkable without a game.
function PeopleGui.Subtitle( row, allowlist )
	local bits = {}
	if row.perma then bits[#bits + 1] = tostring( row.perma ) end
	if row.plot then bits[#bits + 1] = string.format( "plot %d", row.plot ) end
	if row.host then bits[#bits + 1] = "HOST" end
	if row.bot then bits[#bits + 1] = "crowd bot" end
	if allowlist then
		-- THE HOST IS EXEMPT AND THE ROW HAS TO SAY SO. server_onPlayerJoined
		-- tests `player ~= host` before it consults the list at all, so a host
		-- who is not on it is never kept out -- but the row read "NOT on the
		-- allow list" underneath the word HOST, which is the server appearing
		-- to say it will throw its own owner out.
		if row.host then
			bits[#bits + 1] = "always allowed"
		else
			bits[#bits + 1] = row.allowed and "on the allow list" or "NOT on the allow list"
		end
	end
	return table.concat( bits, "   " )
end


--[[ the panel ]]

-- state: {
--   host      whether the viewer is the host, which is what draws the buttons
--   players   { { id, name, perma, plot, bot, host, allowed } ... }
--   bans      { { perma, name, reason } ... }
--   allowlist whether the allow list is switched on at all
--   known     { { perma, name, aliases, banned, seen } ... } everyone ever seen
--   view      "here" | "bans" | "known"
--   page      which page of the current view
--   query     the filter over EVERYONE SEEN. Narrows the list; never a target
--   status    what the last press did
-- }
function PeopleGui.Build( state )
	state = state or {}
	local isHost = state.host == true
	local view = "here"
	for _, v in ipairs( PeopleGui.VIEWS ) do
		if state.view == v then view = v end
	end

	local list
	if view == "bans" then
		list = state.bans or {}
	elseif view == "known" then
		list = PeopleGui.Filter( state.known or {}, state.query )
	else
		list = state.players or {}
	end
	local slice, page, pages = PeopleGui.Page( list, state.page, view )

	local root = widget{ Name = "BackPanel", Type = "Widget", Skin = "PanelEmpty",
		Anchor = "Center", InheritsPick = true, NeedKey = false, NeedMouse = false,
		x = 0, y = 0, width = PeopleGui.W, height = PeopleGui.H }
	root.onClose = "cl_onPeopleGuiClose"
	local kids = root.Childs
	local W = PeopleGui.W - PAD * 2

	kids[#kids + 1] = fill( "BG", 0, 0, PeopleGui.W, PeopleGui.H, BG, 0.96 )
	kids[#kids + 1] = fill( "Band", 0, 0, PeopleGui.W, 64, PANEL, 0.05 )
	kids[#kids + 1] = fill( "Rule", 0, 64, PeopleGui.W, 2, ACCENT, 1 )
	local TITLES = { here = "WHO IS HERE", bans = "BAN LIST",
		known = "EVERYONE SEEN" }
	local SUBS = {
		bans = "everyone kept out. Press EVERYONE SEEN to add somebody",
		known = "every player this server has ever recorded. Press BAN on a row",
	}
	kids[#kids + 1] = text( "Title", TITLES[view],
		PAD, 16, 400, 30, "SM_Header", LABEL, "Left" )
	kids[#kids + 1] = text( "Sub",
		SUBS[view] or ( isHost and "everyone online, and what you can do about them"
		or "everyone online right now" ),
		PAD, 42, 420, 18, "SM_TextTiny", DIM, "Left" )
	-- WHO CAN JOIN AT ALL, in the header, because it is the question underneath
	-- every other question on this panel. A host looking at a roster with one
	-- name on it needs to know whether that is who turned up or who was let in.
	if isHost and state.join then
		kids[#kids + 1] = text( "Join", tostring( state.join ),
			PeopleGui.W - PAD - 300, 42, 300, 18, "SM_TextTiny", ACCENT, "Right" )
	end

	--[[ the view switch -- host only, because a guest has one view ]]

	local top = 88
	if isHost then
		local TABS = { { "VHere", "HERE NOW", "here" },
			{ "VBans", "BANNED", "bans" },
			{ "VKnown", "EVERYONE SEEN", "known" } }
		local tx = PAD
		for _, tab in ipairs( TABS ) do
			kids[#kids + 1] = button( tab[1], tab[2], tx, top, 170, 30,
				( view == tab[3] ) and "StyledButtonLarge" or "SecondaryButton",
				{ action = "view", view = tab[3] } )
			tx = tx + 178
		end
		-- THE SWITCH LIVES WHERE THE MEMBERS ARE. It is also on the settings
		-- panel, and that is not a duplicate worth removing: being able to see
		-- who is on the list without being able to tell whether the list is in
		-- force -- or to turn it on once it is filled in -- is half a feature.
		--
		-- It is the strongest anti-grief tool this mod has. A ban names the one
		-- person who must stay out and loses to a rename; this names everyone
		-- who may come in, and a new name is simply a name that is not on it.
		kids[#kids + 1] = button( "AllowToggle",
			state.allowlist and "ALLOW LIST: ON" or "ALLOW LIST: OFF",
			tx, top, PeopleGui.W - PAD - tx, 30,
			state.allowlist and "StyledButtonLarge" or "SecondaryButton",
			{ action = "allowlist", on = not state.allowlist } )
	end

	--[[ the filter over EVERYONE SEEN ]]

	-- A FILTER, NOT A TARGET, and the distinction is the whole point of this
	-- panel. Typing narrows what is shown; the BAN button on a row is what
	-- bans, and it carries a perma id. So a host who cannot type one character
	-- of somebody's display name can still reach them -- by paging, or by
	-- filtering on the perma, which is always ASCII.
	--
	-- One EditBox per tree, and this is the only view that has one.
	if isHost and PeopleGui.HasSearch( view ) then
		kids[#kids + 1] = fill( "FindStrip", PAD, 124, W, 46, PANEL, 0.06 )
		kids[#kids + 1] = text( "FindLabel", "FIND", PAD + 14, 137, 60, 16,
			"SM_LabelTiny", DIM, "Left" )
		-- Static = false is the flag that makes an EditBox editable at all;
		-- every other TextBox in this mod is Static = true. NeedKey or it never
		-- takes the keyboard. CaptionDisableReplacing stops a name containing
		-- #{...} being read as a localisation key. Shape from DigitalSign.gui's
		-- EnterTextBox, signature from DigitalSign.lua:157.
		local box = widget{ Name = PeopleGui.SEARCH_BOX, Type = "EditBox",
			Skin = "EditBoxEmpty", Caption = tostring( state.query or "" ),
			CaptionDisableReplacing = true, FontName = "SM_Text",
			TextAlign = "Left", TextColour = ACCENT, Static = false,
			MultiLine = false, WordWrap = false, HeightFromText = false,
			MaxTextLength = 40,
			x = PAD + 80, y = 133, width = 280, height = 28 }
		box.onTextEnter = "cl_onPeopleSearchTyped"
		kids[#kids + 1] = box
		kids[#kids + 1] = text( "FindHint",
			"part of a name or an id like SW-0007, then Enter. Or just page down",
			PAD + 372, 138, W - 372, 16, "SM_TextTiny", DIM, "Left" )
	end

	-- The count names what it counted. "3 here" over a list of everyone the
	-- server has ever recorded is a different number wearing the right label,
	-- and a host reading it while deciding who to ban would be reading a lie.
	local head
	if view == "bans" then
		head = string.format( "%d banned", #list )
	elseif view == "known" then
		head = ( tostring( state.query or "" ) ~= "" )
			and string.format( "%d of %d recorded", #list, #( state.known or {} ) )
			or string.format( "%d recorded", #list )
	else
		head = string.format( "%d here", #list )
	end
	kids[#kids + 1] = text( "ListHead", head,
		PAD, PeopleGui.TopFor( view ) - 28, W, 18, "SM_LabelTiny", DIM, "Left" )

	--[[ the rows ]]

	local y = PeopleGui.TopFor( view )
	for i, row in ipairs( slice ) do
		kids[#kids + 1] = fill( "Row" .. i, PAD, y, W, ROW_H - 6, PANEL, 0.05 )
		local label, sub
		if view == "bans" then
			label = tostring( row.name or row.perma )
			sub = tostring( row.reason or "no reason given" )
		elseif view == "known" then
			label = tostring( row.name or row.perma )
			sub = PeopleGui.KnownSubtitle( row, state.allowlist )
		else
			label = string.format( "%s   id %s", tostring( row.name ),
				tostring( row.id ) )
			sub = PeopleGui.Subtitle( row, state.allowlist )
		end
		kids[#kids + 1] = text( "N" .. i, label, PAD + 14, y + 5, W - 340, 18,
			"SM_Text", LABEL, "Left" )
		kids[#kids + 1] = text( "S" .. i, sub,
			PAD + 14, y + 24, W - 340, 14, "SM_TextTiny", DIM, "Left" )

		if isHost then
			if view == "known" then
				-- THE WHOLE LIFECYCLE ON ONE ROW. Somebody already banned shows
				-- UNBAN rather than a greyed-out BAN, so a host never has to
				-- work out which tab undoes what they just did.
				--
				-- The button carries `perma`, never `name`. That is the id the
				-- ban is stored under, so the value clicked and the value
				-- recorded are the same all the way down -- and it is the only
				-- one of the two a host could have typed if they had to.
				kids[#kids + 1] = button( "U" .. i,
					row.banned and "UNBAN" or "BAN",
					PeopleGui.W - PAD - 150, y + 5, 150, 28,
					row.banned and "SecondaryButton" or "StyledButtonLarge",
					{ action = row.banned and "unban" or "ban",
					  name = row.perma } )
				-- Only while the list is in force. A toggle for a list nothing
				-- consults is a button that appears to do nothing, which is the
				-- failure this project has paid for three times.
				if state.allowlist then
					kids[#kids + 1] = button( "A" .. i,
						row.allowed and "REMOVE" or "ALLOW",
						PeopleGui.W - PAD - 268, y + 5, 110, 28,
						"SecondaryButton",
						{ action = row.allowed and "unallow" or "allow",
						  name = row.perma } )
				end
			elseif view == "bans" then
				kids[#kids + 1] = button( "U" .. i, "UNBAN",
					PeopleGui.W - PAD - 150, y + 5, 150, 28, "SecondaryButton",
					{ action = "unban", name = row.perma or row.name } )
			elseif row.host then
				-- No buttons on your own row. The engine refuses both anyway --
				-- "Unable to kick host" is in the executable -- so a button here
				-- could only ever be a button that does nothing.
				kids[#kids + 1] = text( "H" .. i, "this is you",
					PeopleGui.W - PAD - 150, y + 11, 150, 18, "SM_TextTiny",
					DIM, "Center" )
			elseif row.bot then
				kids[#kids + 1] = text( "H" .. i, "crowd bot",
					PeopleGui.W - PAD - 150, y + 11, 150, 18, "SM_TextTiny",
					DIM, "Center" )
			else
				if state.allowlist then
					kids[#kids + 1] = button( "A" .. i,
						row.allowed and "REMOVE" or "ALLOW",
						PeopleGui.W - PAD - 310, y + 5, 96, 28, "SecondaryButton",
						{ action = row.allowed and "unallow" or "allow",
						  name = row.name } )
				end
				kids[#kids + 1] = button( "K" .. i, "KICK",
					PeopleGui.W - PAD - 208, y + 5, 96, 28, "SecondaryButton",
					{ action = "kick", name = row.name } )
				kids[#kids + 1] = button( "B" .. i, "BAN",
					PeopleGui.W - PAD - 106, y + 5, 106, 28, "SecondaryButton",
					{ action = "ban", name = row.name } )
			end
		end
		y = y + ROW_H
	end

	if #slice == 0 then
		local EMPTY = {
			bans = "nobody is banned",
			-- Two different emptinesses, and telling them apart matters: a
			-- filter that matched nothing looks exactly like a server that has
			-- never seen anybody, and one of those is the host's typo.
			known = ( tostring( state.query or "" ) ~= "" )
				and "no name or id contains that. Clear the box to see everyone"
				or "nobody has ever joined this server",
		}
		kids[#kids + 1] = text( "Empty", EMPTY[view] or "nobody is here",
			PAD + 14, PeopleGui.TopFor( view ) + 8, W, 18, "SM_Text", DIM, "Left" )
	end

	--[[ the pager ]]

	if pages > 1 then
		local py = PeopleGui.TopFor( view )
			+ PeopleGui.RowsFor( view ) * ROW_H + 6
		kids[#kids + 1] = button( "Prev", "PREV", PAD, py, 90, 26,
			"SecondaryButton", { action = "page", page = page - 1 } )
		kids[#kids + 1] = text( "Pages",
			string.format( "page %d of %d", page, pages ),
			PAD + 100, py + 4, 200, 18, "SM_TextTiny", DIM, "Left" )
		kids[#kids + 1] = button( "Next", "NEXT", PAD + 240, py, 90, 26,
			"SecondaryButton", { action = "page", page = page + 1 } )
	end

	kids[#kids + 1] = text( "Status", tostring( state.status or "" ),
		PAD, PeopleGui.H - 86, W, 18, "SM_TextTiny", ACCENT, "Left" )

	kids[#kids + 1] = button( "Back", "BACK", PAD, PeopleGui.H - 50, 124, 32,
		"StyledButtonLarge", { action = "back" } )
	kids[#kids + 1] = button( "Close", "CLOSE", PeopleGui.W - 148,
		PeopleGui.H - 50, 124, 32, "StyledButtonLarge", { action = "close" } )
	return root
end
