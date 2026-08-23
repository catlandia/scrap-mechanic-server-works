dofile( "$GAME_DATA/Scripts/game/CreativeGame.lua" )
dofile( "$CONTENT_DATA/Scripts/Settings.lua" )
dofile( "$CONTENT_DATA/Scripts/Identity.lua" )
dofile( "$CONTENT_DATA/Scripts/SettingsGui.lua" )
-- IndexWidgets and friends. BasePlayer pulls this in too, but relying on load
-- order for a global is how you get a nil at the worst moment.
dofile( "$SURVIVAL_DATA/Scripts/util.lua" )

-- The Game script. Chat, identity, settings, players.
--
-- What is NOT here, and must never come back: anything that touches a body. A
-- Game script has no world, and sm.body.* is world-dependent. The first run of
-- this mod died on exactly that:
--
--   [C]: in function 'getAllBodies'
--   ERROR: Calling world dependent functions in a no world script!
--
-- All of it lives in World.lua now and is reached with sm.event.sendToWorld.
-- Game and World share one Lua global environment (this is how vanilla's
-- g_unitManager, created in CreativeGame, is reachable from CreativeBaseWorld),
-- so Settings and Identity are visible from both without any plumbing.

Game = class( CreativeGame )

-- Our own World subclass. Flat because a build event wants flat ground, and flat
-- terrain is cheaper to load and render than generated terrain.
Game.worldScriptFilename = "$CONTENT_DATA/Scripts/World.lua"
Game.worldScriptClass = "World"

local TICKS_PER_SECOND = 40
local TOOL_CHECK_TICKS = 10

-- Commands that need a world. Forwarded rather than handled here.
local WORLD_COMMANDS = {
	["/lockdown"] = true, ["/unlock"] = true, ["/protection"] = true,
	["/buildtime"] = true, ["/snapshot"] = true, ["/snapshots"] = true,
	["/restore"] = true, ["/purge"] = true, ["/plot"] = true,
	["/plots"] = true, ["/plotgrid"] = true, ["/home"] = true,
	["/plotbuild"] = true, ["/plotclear"] = true,
}

-- Commands a guest may use. Everything else is host-only.
local PLAYER_COMMANDS = {
	["/sw"] = true, ["/swhelp"] = true, ["/plot"] = true, ["/players"] = true,
	["/rules"] = true, ["/home"] = true,
}

-- How many words a player name may contain. bindChatCommand splits arguments on
-- spaces and the parser has no quoting, so a name like "June Carya" arrives as
-- separate arguments and vanilla's own /kick simply cannot target it. Declaring
-- spare trailing optional parameters and rejoining them is the fix.
local NAME_WORDS = 6

local function nameParams()
	local spec = { { "string", "name-or-id", false } }
	for i = 2, NAME_WORDS do
		spec[#spec + 1] = { "string", "w" .. i, true }
	end
	return spec
end

local function joinName( params, from )
	local parts = {}
	for i = from, #params do
		local v = params[i]
		if type( v ) == "string" and v ~= "" then
			parts[#parts + 1] = v
		end
	end
	return table.concat( parts, " " )
end

-- Accepts a display name, a perma id (SW-0007) or a session id from /players.
local function resolveTarget( token )
	local byId = tonumber( token )
	if byId then
		for _, p in ipairs( sm.player.getAllPlayers() ) do
			if p.id == byId then return p, p.name end
		end
	end
	local key = string.lower( tostring( token ) )
	for _, p in ipairs( sm.player.getAllPlayers() ) do
		if string.lower( p.name ) == key then return p, p.name end
	end
	return nil, Identity.Sv_NameOf( token ) or token
end


--[[ server ]]

function Game.server_onCreate( self )
	-- Settings and identity load BEFORE the base call, because the base call is
	-- what creates the world and World.server_onCreate reads settings the moment
	-- it runs. Values only: applying them needs a world, so the World does that.
	Settings.Sv_Load( false )
	Identity.Sv_Load()

	-- Must not be skipped. CreativeGame.server_onCreate creates g_unitManager,
	-- g_kinematicManager and g_beaconManager; a Custom Game that overrides this
	-- without calling up leaves them nil and then every collision throws with a
	-- full traceback. That is what produced a 1.79 GB log and 11 Hz.
	CreativeGame.server_onCreate( self )

	if g_unitManager == nil then
		sm.log.warning( "[ServerWorks] g_unitManager is nil after base create -- collisions will error" )
	end

	self.sv.kickQueue = {}
	self.sv.nextToolCheck = 0
	self.sv.nextBanReload = 0
	self.sv.blockedTools = Settings.Sv_BlockedTools()
	self.sv.pendingRestore = nil
end

function Game.sv_world( self )
	return self.sv.saved and self.sv.saved.world or nil
end

function Game.sv_toWorld( self, cmd, args, player, extra )
	local world = self:sv_world()
	if world == nil or not sm.exists( world ) then
		self.network:sendToClient( player, "client_showMessage", "world not ready yet" )
		return
	end
	local payload = { cmd = cmd, args = args, player = player }
	if extra then
		for k, v in pairs( extra ) do payload[k] = v end
	end
	sm.event.sendToWorld( world, "sv_e_swCommand", payload )
end

-- Replies come back from the world as events: a world script has no network of
-- its own to talk to a client with.
function Game.sv_e_swReply( self, params )
	if params.player and sm.exists( params.player ) then
		self.network:sendToClient( params.player, "client_showMessage", params.text )
	end
end

function Game.sv_e_swBroadcast( self, params )
	self.network:sendToClients( "client_showMessage", params.text )
end

function Game.sv_broadcast( self, text )
	self.network:sendToClients( "client_showMessage", text )
end

function Game.server_onFixedUpdate( self, dt )
	CreativeGame.server_onFixedUpdate( self, dt )

	local tick = sm.game.getCurrentTick()
	self:sv_checkToolGuard( tick )
	self:sv_flushKicks()

	-- Re-read the ban file so a tool outside the game can push a ban mid-event.
	if tick >= self.sv.nextBanReload then
		self.sv.nextBanReload = tick + Identity.RELOAD_SECONDS * TICKS_PER_SECOND
		pcall( Identity.Sv_Reload )
		local host = sm.player.getHostPlayer()
		for _, player in ipairs( sm.player.getAllPlayers() ) do
			if player ~= host and Identity.Sv_IsBanned( player ) then
				table.insert( self.sv.kickQueue, player )
			end
		end
	end
end

-- Forbidden tools are pulled out of the player's hands as soon as they equip one.
-- The item is still listed in the creative menu -- nothing in Lua can edit that
-- list -- but it can never be held long enough to be used.
function Game.sv_checkToolGuard( self, tick )
	if tick < self.sv.nextToolCheck then return end
	self.sv.nextToolCheck = tick + TOOL_CHECK_TICKS

	local blocked = self.sv.blockedTools
	if next( blocked ) == nil then return end

	-- The host runs the event and needs every tool, including the banned ones.
	local host = sm.player.getHostPlayer()
	local guests = {}
	for _, p in ipairs( sm.player.getAllPlayers() ) do
		if p ~= host then guests[#guests + 1] = p end
	end

	Settings.Sv_CheckTools( guests, blocked, function( player, name )
		self.network:sendToClient( player, "client_dropTool", name )
	end )
end

function Game.sv_flushKicks( self )
	if #self.sv.kickQueue == 0 then return end
	local pending = self.sv.kickQueue
	self.sv.kickQueue = {}
	for _, player in ipairs( pending ) do
		if sm.exists( player ) then
			sm.log.info( "[ServerWorks] kicking " .. tostring( player.name ) )
			sm.game.kickPlayer( player )
		end
	end
end

function Game.server_onPlayerJoined( self, player, newPlayer )
	CreativeGame.server_onPlayerJoined( self, player, newPlayer )

	local rec = Identity.Sv_Touch( player )
	local host = sm.player.getHostPlayer()

	-- Allow list first: it is the stronger check. A ban names the person who must
	-- stay out and loses to a rename; an allow list names everyone who may come
	-- in, and a rename just produces another name that is not on it.
	if Settings.Get( "allowlist" ) and player ~= host and not Identity.Sv_IsAllowed( player ) then
		sm.log.info( "[ServerWorks] not on allow list: " .. tostring( player.name ) )
		table.insert( self.sv.kickQueue, player )
		return
	end

	if Identity.Sv_IsBanned( player ) then
		-- Not kicked inline: the player is still being constructed here and the
		-- base class has spawn work queued behind us. One tick later is safe.
		table.insert( self.sv.kickQueue, player )
		return
	end

	self.network:sendToClient( player, "client_welcome", {
		perma = rec.perma,
		plots = Settings.Get( "plots" ) == true,
	} )
end


--[[ client ]]

function Game.client_welcome( self, data )
	local lines = {
		"------------------------------------------",
		"  Welcome. This server runs SERVER WORKS.",
		string.format( "  Your permanent id is %s.", tostring( data.perma ) ),
		"",
	}
	if data.plots then
		lines[#lines + 1] = "  This is a PLOT event:"
		lines[#lines + 1] = "   1. Stand on an empty plot and type  /plot claim"
		lines[#lines + 1] = "   2. You can only build on your own plot."
		lines[#lines + 1] = "   3. Walk onto someone else's plot and you get pushed off."
		lines[#lines + 1] = "   4. To build with a neighbour, both type  /plot team <them>"
		lines[#lines + 1] = "      Then the gap between your plots becomes shared ground."
	else
		lines[#lines + 1] = "  Free build. The host may lock builds at any time."
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = "  /sw for commands, /rules for the server rules."
	lines[#lines + 1] = "------------------------------------------"

	for _, line in ipairs( lines ) do
		sm.gui.chatMessage( line )
	end
end

function Game.client_showMessage( self, text )
	sm.gui.chatMessage( text )
end

function Game.client_dropTool( self, name )
	-- forceTool is client-side only: the server can see what you hold, but only
	-- your own client can put it away.
	pcall( sm.tool.forceTool, nil )
	sm.gui.chatMessage( string.format( "The %s is disabled on this server.", tostring( name ) ) )
end

function Game.client_onCreate( self )
	CreativeGame.client_onCreate( self )

	-- NOT "/help". The engine reserves it -- measured, first run:
	--   ERROR: Command name '/help' is reserved
	-- NOT "/help". The engine reserves that name and bindChatCommand refuses it --
	-- measured, first run: "Command name '/help' is reserved". /swhelp is the
	-- mod's own help, kept separate from the game's so neither shadows the other.
	sm.game.bindChatCommand( "/sw", {}, "cl_onAdminCommand",
		"Server Works: how this server works and what you can type" )
	sm.game.bindChatCommand( "/swhelp", {}, "cl_onAdminCommand",
		"Server Works help -- same as /sw" )
	sm.game.bindChatCommand( "/rules", {}, "cl_onAdminCommand",
		"The server rules and the numbers currently in force" )
	sm.game.bindChatCommand( "/home", {}, "cl_onAdminCommand",
		"Teleport back to your own plot" )
	sm.game.bindChatCommand( "/plot",
		{ { "string", "action", false, { "claim", "info", "team", "leave", "list" } },
		  { "string", "who", true } },
		"cl_onAdminCommand", "claim | info | team <player> | leave | list" )
	sm.game.bindChatCommand( "/players", {}, "cl_onAdminCommand",
		"Who is here, with session id and permanent id" )

	sm.game.bindChatCommand( "/settings", {}, "cl_onAdminCommand",
		"Host: open the settings panel" )
	sm.game.bindChatCommand( "/settingslist", {}, "cl_onAdminCommand",
		"Host: print settings to chat instead of opening the panel" )
	sm.game.bindChatCommand( "/set",
		{ { "string", "setting", false }, { "string", "value", false } },
		"cl_onAdminCommand", "Host: change a setting, e.g. /set fire off" )
	sm.game.bindChatCommand( "/plots", { { "string", "onoff", true, { "on", "off" } } },
		"cl_onAdminCommand", "Host: shortcut for /set plots on|off" )
	sm.game.bindChatCommand( "/plotbuild", {}, "cl_onAdminCommand",
		"Host: build the visible city floor -- concrete plots, metal 2 lines" )
	sm.game.bindChatCommand( "/plotclear", {}, "cl_onAdminCommand",
		"Host: remove the city floor" )
	sm.game.bindChatCommand( "/plotgrid",
		{ { "number", "plotBlocks", false }, { "number", "gapBlocks", false },
		  { "number", "cols", false }, { "number", "rows", false } },
		"cl_onAdminCommand", "Host: reshape the city grid (wipes claims)" )

	sm.game.bindChatCommand( "/lockdown", { { "string", "mode", true, { "strict", "display" } } },
		"cl_onAdminCommand", "Host: lock every build. strict also blocks seats and controllers" )
	sm.game.bindChatCommand( "/unlock", {}, "cl_onAdminCommand", "Host: reopen building" )
	sm.game.bindChatCommand( "/protection", {}, "cl_onAdminCommand",
		"Host: protection state, shape count, running jobs" )
	sm.game.bindChatCommand( "/buildtime", { { "number", "minutes", false } }, "cl_onAdminCommand",
		"Host: lock builds in N minutes and snapshot then. 0 cancels" )
	sm.game.bindChatCommand( "/autosave", { { "number", "minutes", false } }, "cl_onAdminCommand",
		"Host: snapshot every N minutes. 0 turns it off" )

	sm.game.bindChatCommand( "/snapshot", { { "string", "name", true } }, "cl_onAdminCommand",
		"Host: save every build so it can be restored" )
	sm.game.bindChatCommand( "/snapshots", {}, "cl_onAdminCommand", "Host: list snapshots" )
	sm.game.bindChatCommand( "/restore",
		{ { "string", "name", false }, { "number", "plot", true } }, "cl_onAdminCommand",
		"Host: rebuild from a snapshot. Add a plot number to repair one plot. Run twice to confirm" )
	sm.game.bindChatCommand( "/purge",
		{ { "string", "what", false, { "here", "plot", "walkways" } }, { "number", "n", true } },
		"cl_onAdminCommand", "Host: delete junk. here <radius> | plot <n> | walkways" )

	sm.game.bindChatCommand( "/known", {}, "cl_onAdminCommand", "Host: everyone who has ever joined" )
	sm.game.bindChatCommand( "/ban", nameParams(), "cl_onAdminCommand",
		"Host: permanently ban by name, session id or perma id" )
	sm.game.bindChatCommand( "/unban", nameParams(), "cl_onAdminCommand", "Host: lift a ban" )
	sm.game.bindChatCommand( "/banlist", {}, "cl_onAdminCommand", "Host: show the ban list" )
	sm.game.bindChatCommand( "/kick", nameParams(), "cl_onAdminCommand",
		"Host: kick for this session only" )
	sm.game.bindChatCommand( "/allow", nameParams(), "cl_onAdminCommand",
		"Host: let someone in when allowlist is on. Works before they ever join" )
	sm.game.bindChatCommand( "/unallow", nameParams(), "cl_onAdminCommand",
		"Host: take someone off the allow list" )
	sm.game.bindChatCommand( "/allowlist", {}, "cl_onAdminCommand", "Host: show who is allowed in" )
end

function Game.cl_onAdminCommand( self, params )
	self.network:sendToServer( "sv_n_adminCommand", params )
end


--[[ settings panel ]]

-- The panel is client side, but settings live on the server, so the values are
-- shipped over rather than read locally. Every click round-trips: the client
-- asks, the server decides and saves, the server sends the new values back and
-- the panel re-renders. That keeps a guest's client from ever being the
-- authority on what the server allows.
function Game.sv_openSettingsGui( self, player, page )
	local values = {}
	for _, row in ipairs( Settings.SCHEMA ) do
		values[row.key] = Settings.Get( row.key )
	end
	self.network:sendToClient( player, "client_openSettingsGui",
		{ values = values, page = page } )
end

function Game.sv_n_settingsGuiClick( self, data, player )
	if player ~= sm.player.getHostPlayer() then
		return
	end

	if data.action == "cycle" then
		local row
		for _, r in ipairs( Settings.SCHEMA ) do
			if r.key == data.key then row = r end
		end
		if row then
			local current = Settings.Get( row.key )
			local nextValue = SettingsGui.NextValue( row, current )
			if nextValue ~= current then
				local raw = ( row.kind == "bool" ) and ( nextValue and "on" or "off" )
					or tostring( nextValue )
				local ok, detail = Settings.Sv_Set( row.key, raw )
				if ok then
					self.sv.blockedTools = Settings.Sv_BlockedTools()
					self:sv_toWorld( "/settingschanged", {}, player )
					self:sv_broadcast( "Server setting changed: " .. detail )
				end
			end
		end
	end

	self:sv_openSettingsGui( player, data.page or 1 )
end

function Game.client_openSettingsGui( self, data )
	if self.cl == nil then self.cl = {} end
	self.cl.settingsValues = data.values
	self.cl.settingsPage = data.page or 1

	if self.cl.settingsGui and sm.exists( self.cl.settingsGui ) then
		self.cl.settingsGui:close()
		self.cl.settingsGui:destroy()
	end

	local root = SettingsGui.Build( data.values, self.cl.settingsPage )
	self.cl.settingsGui = sm.jsonGui.createGui( { isInteractive = true, needsCursor = true } )
	self.cl.settingsGui:render( root )
	self.cl.settingsGui:open()
end

function Game.cl_onSettingsGuiClick( self, data )
	if data.action == "close" then
		self:cl_closeSettingsGui()
		return
	end

	if data.action == "page" then
		local pages = SettingsGui.PageCount()
		local page = data.page
		if page < 1 then page = pages elseif page > pages then page = 1 end
		self.cl.settingsPage = page
		local root = SettingsGui.Build( self.cl.settingsValues, page )
		self.cl.settingsGui:render( root )
		return
	end

	-- A value change has to go to the server; the client does not decide.
	self.network:sendToServer( "sv_n_settingsGuiClick",
		{ action = data.action, key = data.key, page = self.cl.settingsPage } )
end

function Game.cl_onSettingsGuiClose( self )
	self:cl_closeSettingsGui()
end

function Game.cl_closeSettingsGui( self )
	if self.cl and self.cl.settingsGui and sm.exists( self.cl.settingsGui ) then
		self.cl.settingsGui:close()
		self.cl.settingsGui:destroy()
		self.cl.settingsGui = nil
	end
end


--[[ command dispatch ]]

function Game.sv_n_adminCommand( self, params, player )
	local function reply( text )
		self.network:sendToClient( player, "client_showMessage", text )
	end

	local cmd = params[1]
	local isHost = ( player == sm.player.getHostPlayer() )

	if not isHost and not PLAYER_COMMANDS[cmd] then
		reply( "Host only." )
		return
	end

	-- Anything that touches a body goes to the world.
	if WORLD_COMMANDS[cmd] then
		if cmd == "/restore" then
			local name, plot = params[2], tonumber( params[3] )
			local token = tostring( name ) .. "/" .. tostring( plot )
			-- Two-step on purpose. This deletes before it rebuilds; a fat-fingered
			-- /restore mid-event would do more damage than the griefer did.
			if self.sv.pendingRestore ~= token then
				self.sv.pendingRestore = token
				reply( plot
					and string.format( "/restore %s %d will DELETE everything on plot %d and rebuild it.",
						tostring( name ), plot, plot )
					or string.format( "/restore %s will DELETE THE WHOLE WORLD and rebuild from it.",
						tostring( name ) ) )
				reply( "Run the same command again to confirm." )
				return
			end
			self.sv.pendingRestore = nil
			self:sv_toWorld( cmd, params, player, { plot = plot } )
			return
		end
		self:sv_toWorld( cmd, params, player )
		return
	end

	if cmd == "/sw" or cmd == "/swhelp" then
		reply( "SERVER WORKS" )
		reply( "  /plot claim         claim the plot you are stood on" )
		reply( "  /plot info          who owns this ground" )
		reply( "  /plot team <name>   ask a neighbour to team up (they type it back)" )
		reply( "  /plot leave         give up your plot" )
		reply( "  /home               teleport back to your own plot" )
		reply( "  /players            who is here     /rules  the server rules" )
		if isHost then
			reply( "HOST" )
			reply( "  /settings           open the settings panel" )
			reply( "  /settingslist  /set <name> <value>" )
			reply( "  /plots on|off  /plotbuild  /plotclear" )
			reply( "  /plotgrid <plot> <gap> <cols> <rows>" )
			reply( "  /lockdown [display]  /unlock  /protection  /buildtime N  /autosave N" )
			reply( "  /snapshot [name]  /snapshots  /restore <name> [plot]" )
			reply( "  /purge here <m> | /purge plot <n> | /purge walkways" )
			reply( "  /ban <who>  /unban <who>  /banlist  /known  /kick <who>" )
			reply( "  /allow <who>  /unallow <who>  /allowlist" )
		end

	elseif cmd == "/rules" then
		-- Read from live settings, so the board can never drift from what the
		-- server actually enforces.
		local function num( k ) return tostring( Settings.Get( k ) ) end
		local function onoff( k ) return Settings.Get( k ) and "allowed" or "BANNED" end
		reply( "SERVER RULES" )
		reply( "  1. No basements -- nothing below z " .. num( "minbuildheight" ) )
		reply( "  2. One plot per player" )
		reply( "  3. No building before build time starts" )
		reply( "  4. Don't spam lights -- max " .. num( "maxlights" ) .. " per plot" )
		reply( "  5. Don't leave radios on -- radios are " .. onoff( "radios" ) )
		reply( "  6. Max " .. num( "maxbots" ) .. " cook/dress/craft bot per plot" )
		reply( "  7. No noise pollution -- horns are " .. onoff( "horns" ) )
		reply( "  8. Multiple people can share plots if they agree (/plot team)" )
		reply( "  9. No griefing or trolling. Bans are permanent." )
		reply( "  10. Max " .. num( "maxjoints" ) .. " combined bearings/pistons/suspensions per plot" )
		reply( "  11. Fireworks " .. onoff( "fireworks" ) .. ", plasma drills " .. onoff( "plasmadrills" ) )
		reply( "  12. Beacons " .. onoff( "beacons" ) )
		reply( "Go over a limit and your plot locks until you trim it. Nothing is taken away." )

	elseif cmd == "/settings" then
		self:sv_openSettingsGui( player, 1 )

	elseif cmd == "/settingslist" then
		reply( "settings -- /set <name> <value>" )
		for _, line in ipairs( Settings.Sv_Lines() ) do reply( line ) end

	elseif cmd == "/set" then
		local ok, detail = Settings.Sv_Set( params[2], params[3] )
		reply( detail )
		if ok then
			self.sv.blockedTools = Settings.Sv_BlockedTools()
			self:sv_toWorld( "/settingschanged", params, player )
			self:sv_broadcast( "Server setting changed: " .. detail )
		end

	elseif cmd == "/autosave" then
		local ok, detail = Settings.Sv_Set( "autosave", params[2] )
		reply( detail )
		if ok then self:sv_toWorld( "/settingschanged", params, player ) end

	elseif cmd == "/players" then
		local players = sm.player.getAllPlayers()
		reply( string.format( "%d player(s) here:", #players ) )
		for _, p in ipairs( players ) do
			reply( string.format( "  id %-3d %-10s %s", p.id, Identity.Sv_PermaOf( p ) or "?", p.name ) )
		end

	elseif cmd == "/known" then
		for _, line in ipairs( Identity.Sv_KnownLines( 25 ) ) do reply( line ) end

	elseif cmd == "/ban" then
		local token = joinName( params, 2 )
		local target, name = resolveTarget( token )
		if target == sm.player.getHostPlayer() then
			reply( "You cannot ban the host." )
			return
		end
		local ok, detail = Identity.Sv_Ban( name, "" )
		reply( detail )
		if ok then
			sm.log.info( "[ServerWorks] banned " .. tostring( name ) )
			if target and sm.exists( target ) then
				sm.game.banPlayer( target )
				self:sv_broadcast( name .. " was banned." )
			else
				reply( "(not online -- they will be kicked if they ever join)" )
			end
		end

	elseif cmd == "/unban" then
		local _, detail = Identity.Sv_Unban( joinName( params, 2 ) )
		reply( detail )

	elseif cmd == "/banlist" then
		for _, line in ipairs( Identity.Sv_BanLines() ) do reply( line ) end

	elseif cmd == "/allow" or cmd == "/unallow" then
		local token = joinName( params, 2 )
		local _, name = resolveTarget( token )
		local ok, detail = Identity.Sv_SetAllowed( name or token, cmd == "/allow" )
		reply( detail )
		if ok and cmd == "/unallow" and Settings.Get( "allowlist" ) then
			local target = resolveTarget( token )
			if target and sm.exists( target ) and target ~= sm.player.getHostPlayer() then
				table.insert( self.sv.kickQueue, target )
			end
		end

	elseif cmd == "/allowlist" then
		reply( string.format( "allowlist is %s -- /set allowlist on|off",
			Settings.Get( "allowlist" ) and "ON" or "off" ) )
		for _, line in ipairs( Identity.Sv_AllowLines() ) do reply( line ) end

	elseif cmd == "/kick" then
		local token = joinName( params, 2 )
		local target, name = resolveTarget( token )
		if target == nil then
			reply( string.format( "'%s' is not here -- try /players", token ) )
		elseif target == sm.player.getHostPlayer() then
			reply( "You cannot kick the host." )
		else
			sm.log.info( "[ServerWorks] kicking " .. tostring( name ) )
			sm.game.kickPlayer( target )
			self:sv_broadcast( name .. " was kicked." )
		end
	end
end
