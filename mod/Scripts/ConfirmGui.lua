-- ConfirmGui -- the two doors in front of anything that destroys work.
--
-- Asked for as: "the remove city button shall have double confirmation needed.
-- first confirmation doesnt count so like its. press the delete button. it says
-- are you sure you want to delete the city? and lists what is on it. if you
-- click yes another pop up will happen and it will say LAST CHANCE TO CANCEL.
-- I know it makes auto backups but still"
--
-- Two things make this more than a nag:
--
-- 1. IT LISTS WHAT IS ON THE CITY. A confirmation that only says "are you sure"
--    is answered by reflex. One that says "96 plots, 41 claimed, 12,406 blocks
--    built by 9 people" is answered by reading. The count comes from the live
--    world, not from a guess.
--
-- 2. THE SECOND DOOR IS NOT IN THE SAME PLACE AS THE FIRST. The YES on step two
--    sits where CANCEL sat on step one, so the muscle memory of double-clicking
--    through a dialog lands on cancel rather than on delete.
--
-- The autosave exists and is good. It is not a reason to make the destructive
-- path easy: restoring is a minute of everyone's event, and the griefer this
-- whole project exists because of took two.

ConfirmGui = {}

ConfirmGui.W = 660
ConfirmGui.H = 380

local PAD = 30

local BG = "0.055 0.062 0.078 1"
local PANEL = "1 1 1 1"
local ACCENT = "1 0.54 0.18 1"
local DANGER = "0.95 0.30 0.26 1"
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
	b.onClick = "cl_onConfirmClick"
	b.onClickData = data
	return b
end

-- state: {
--   step       1 = "are you sure", 2 = "last chance"
--   action     what to run if they get through both doors
--   title      what is about to happen
--   lines      what is on the thing, one string per line
-- }
function ConfirmGui.Build( state )
	state = state or {}
	local last = ( state.step or 1 ) >= 2

	local root = widget{ Name = "BackPanel", Type = "Widget", Skin = "PanelEmpty",
		Anchor = "Center", InheritsPick = true, NeedKey = false, NeedMouse = false,
		x = 0, y = 0, width = ConfirmGui.W, height = ConfirmGui.H }
	root.onClose = "cl_onConfirmClose"
	local kids = root.Childs

	kids[#kids + 1] = fill( "BG", 0, 0, ConfirmGui.W, ConfirmGui.H, BG, 0.97 )
	kids[#kids + 1] = fill( "Band", 0, 0, ConfirmGui.W, 66, PANEL, 0.05 )
	kids[#kids + 1] = fill( "Rule", 0, 66, ConfirmGui.W, 3,
		last and DANGER or ACCENT, 1 )

	kids[#kids + 1] = text( "Title",
		last and "LAST CHANCE TO CANCEL" or ( state.title or "ARE YOU SURE?" ),
		PAD, 18, ConfirmGui.W - PAD * 2, 32,
		"SM_HeaderLarge_Medium", last and DANGER or LABEL, "Left" )

	local y = 90
	if last then
		kids[#kids + 1] = text( "Warn",
			"This cannot be undone from in here.",
			PAD, y, ConfirmGui.W - PAD * 2, 24, "SM_Text", LABEL, "Left" )
		y = y + 34
		kids[#kids + 1] = text( "Warn2",
			"The last automatic save can be put back with the snapshot list, but",
			PAD, y, ConfirmGui.W - PAD * 2, 20, "SM_TextTiny", DIM, "Left" )
		y = y + 22
		kids[#kids + 1] = text( "Warn3",
			"anything built since that save is gone.",
			PAD, y, ConfirmGui.W - PAD * 2, 20, "SM_TextTiny", DIM, "Left" )
		y = y + 34
	end

	kids[#kids + 1] = fill( "ListBG", PAD, y, ConfirmGui.W - PAD * 2,
		ConfirmGui.H - y - 96, PANEL, 0.035 )
	local ly = y + 12
	for i, line in ipairs( state.lines or {} ) do
		if ly + 20 <= ConfirmGui.H - 96 then
			kids[#kids + 1] = text( "Line" .. i, line, PAD + 16, ly,
				ConfirmGui.W - PAD * 2 - 32, 20, "SM_Text", LABEL, "Left" )
			ly = ly + 22
		end
	end

	--[[ the doors ]]
	--
	-- The buttons SWAP SIDES between the two steps. On step one the destructive
	-- answer is on the right; on step two it is on the left, where CANCEL was.
	-- Someone double-clicking through by reflex hits cancel the second time,
	-- which is the entire point of asking twice.
	local by = ConfirmGui.H - 66
	local half = ( ConfirmGui.W - PAD * 2 - 16 ) / 2
	local yesData = { action = "yes" }
	local noData = { action = "no" }

	if last then
		kids[#kids + 1] = button( "Yes", "DELETE IT ALL", PAD, by, half, 44,
			"SecondaryButton", yesData )
		kids[#kids + 1] = button( "No", "CANCEL", PAD + half + 16, by, half, 44,
			"StyledButtonLarge", noData )
	else
		kids[#kids + 1] = button( "No", "CANCEL", PAD, by, half, 44,
			"StyledButtonLarge", noData )
		kids[#kids + 1] = button( "Yes", "YES, DELETE", PAD + half + 16, by, half, 44,
			"SecondaryButton", yesData )
	end

	return root
end
