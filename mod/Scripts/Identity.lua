-- Identity -- who a player is, across events.
--
-- Two ids, because the engine only gives us one and it is the wrong one.
--
--   session id   player.id. Short, convenient, what /players prints. Assigned by
--                the engine. MEASURED as unstable across worlds: the same Steam
--                user came back as player.id 1, 2 and 20 in different sessions
--                (dev/session_stats.py over the log archive). Fine for typing a
--                command at someone right now; useless as a ban key.
--
--   perma id     SW-0001, SW-0002... Assigned here, never reused. This is what a
--                perma ban records.
--
-- The hard part is recognising a returning player so they get their old perma
-- id back. Lua cannot see a Steam ID -- wrap_Player.cpp exposes none, and there
-- is not one "steam" reference in any vanilla script -- so in-game matching is
-- by display name, which people can change.
--
-- The engine does write "Loaded player <id> (for user <steamid>)" into
-- Logs/game-*.log. dev/resolve_ids.py reads that, stamps the Steam ID onto these
-- records, merges any records that turn out to be the same human, and unions
-- their aliases. A perma ban then covers every name that person has ever used,
-- and if they appear under a brand new name the tool can push an updated ban
-- file that Sv_Reload picks up within seconds.
--
-- So: renaming does not defeat a ban, it delays it by one tool cycle. That is
-- the ceiling of what this engine allows, not a shortcut taken here.

Identity = {}

Identity.PLAYERS = "$CONTENT_DATA/Players.json"
Identity.BANS = "$CONTENT_DATA/BanList.json"
Identity.RELOAD_SECONDS = 5

Identity.players = { version = 2, nextPerma = 1, records = {} }
Identity.bans = { version = 2, bans = {} }

local function lower( s )
	return string.lower( tostring( s or "" ) )
end

local function now()
	local ok, t = pcall( os.time )
	return ok and t or 0
end

local function readJson( path, fallback )
	local ok, exists = pcall( sm.json.fileExists, path )
	if not ok or not exists then
		return fallback
	end
	local read, loaded = pcall( sm.json.open, path )
	if read and type( loaded ) == "table" then
		return loaded
	end
	sm.log.warning( "[ServerWorks] unreadable, ignoring: " .. path )
	return fallback
end

local function writeJson( path, data )
	local ok, err = pcall( sm.json.save, data, path )
	if not ok then
		-- Most likely a read-only content directory. Say it once, loudly, rather
		-- than letting bans and claims silently evaporate on restart.
		sm.log.warning( "[ServerWorks] COULD NOT WRITE " .. path .. ": " .. tostring( err ) )
		return false
	end
	return true
end


function Identity.Sv_Load()
	local p = readJson( Identity.PLAYERS, nil )
	if p and type( p.records ) == "table" then
		Identity.players = p
		Identity.players.nextPerma = p.nextPerma or ( #p.records + 1 )
	end

	Identity.Sv_Reload()

	sm.log.info( string.format( "[ServerWorks] identity: %d known players, %d bans",
		#Identity.players.records, #Identity.bans.bans ) )
end

-- Re-read only the ban file. Cheap, and it is what lets an out-of-game tool push
-- a new ban mid-event without a restart.
function Identity.Sv_Reload()
	local b = readJson( Identity.BANS, nil )
	if b and type( b.bans ) == "table" then
		Identity.bans = b
		Identity.bans.version = b.version or 2
	end
end

function Identity.Sv_SavePlayers()
	return writeJson( Identity.PLAYERS, Identity.players )
end

function Identity.Sv_SaveBans()
	return writeJson( Identity.BANS, Identity.bans )
end

function Identity.Sv_FindByName( name )
	local key = lower( name )
	for _, rec in ipairs( Identity.players.records ) do
		for _, alias in ipairs( rec.names or {} ) do
			if lower( alias ) == key then
				return rec
			end
		end
	end
	return nil
end

function Identity.Sv_FindByPerma( perma )
	local key = lower( perma )
	for _, rec in ipairs( Identity.players.records ) do
		if lower( rec.perma ) == key then
			return rec
		end
	end
	return nil
end

-- Called on every join. Returns the player's record, creating one if this is a
-- name we have never seen.
function Identity.Sv_Touch( player )
	local rec = Identity.Sv_FindByName( player.name )

	if rec == nil then
		rec = {
			perma = string.format( "SW-%04d", Identity.players.nextPerma ),
			names = { player.name },
			steamId = "",          -- filled in by dev/resolve_ids.py
			firstSeen = now(),
		}
		Identity.players.nextPerma = Identity.players.nextPerma + 1
		table.insert( Identity.players.records, rec )
		sm.log.info( string.format( "[ServerWorks] new player %s = %s", rec.perma, player.name ) )
	end

	rec.lastSeen = now()
	rec.lastPlayerId = player.id       -- the session id, for the tool to join on
	Identity.Sv_SavePlayers()
	return rec
end

function Identity.Sv_PermaOf( player )
	local rec = Identity.Sv_FindByName( player.name )
	return rec and rec.perma or nil
end

function Identity.Sv_NameOf( perma )
	local rec = Identity.Sv_FindByPerma( perma )
	if rec and rec.names and #rec.names > 0 then
		return rec.names[#rec.names]
	end
	return nil
end


--[[ bans ]]

--[[ allow list ]]

-- Stricter than a ban list and much harder to defeat: instead of naming the one
-- person who must stay out, name everyone who may come in. A griefer changing
-- their display name defeats a ban; it cannot defeat this, because a new name is
-- simply a name that is not on the list.
function Identity.Sv_IsAllowed( player )
	local rec = Identity.Sv_FindByName( player.name )
	return rec ~= nil and rec.allowed == true
end

function Identity.Sv_SetAllowed( target, allowed )
	local rec = Identity.Sv_FindByPerma( target ) or Identity.Sv_FindByName( target )
	if rec == nil then
		-- Allow someone who has never joined, so a host can seed the list before
		-- an event rather than during it.
		if not allowed then
			return false, string.format( "no player known as '%s'", tostring( target ) )
		end
		rec = {
			perma = string.format( "SW-%04d", Identity.players.nextPerma ),
			names = { target },
			steamId = "",
			firstSeen = now(),
		}
		Identity.players.nextPerma = Identity.players.nextPerma + 1
		table.insert( Identity.players.records, rec )
	end
	rec.allowed = allowed and true or nil
	Identity.Sv_SavePlayers()
	return true, string.format( "%s %s", rec.names[#rec.names],
		allowed and "is on the allow list" or "removed from the allow list" )
end

function Identity.Sv_AllowLines()
	local lines = {}
	for _, rec in ipairs( Identity.players.records ) do
		if rec.allowed then
			lines[#lines + 1] = string.format( "  %s  %s", rec.perma, rec.names[#rec.names] )
		end
	end
	if #lines == 0 then
		lines[1] = "allow list is empty -- turning allowlist on would lock everyone out"
	end
	return lines
end


function Identity.Sv_BanEntry( perma )
	local key = lower( perma )
	for i, entry in ipairs( Identity.bans.bans ) do
		if lower( entry.perma ) == key then
			return i, entry
		end
	end
	return nil
end

function Identity.Sv_IsBanned( player )
	local rec = Identity.Sv_FindByName( player.name )
	if rec then
		local _, entry = Identity.Sv_BanEntry( rec.perma )
		if entry then
			return true, entry
		end
	end
	-- Also match the raw name, so a ban written by the tool for a name we have
	-- no record of yet still bites on first sight.
	local key = lower( player.name )
	for _, entry in ipairs( Identity.bans.bans ) do
		for _, alias in ipairs( entry.names or {} ) do
			if lower( alias ) == key then
				return true, entry
			end
		end
	end
	return false, nil
end

-- target may be a perma id (SW-0007) or a display name.
function Identity.Sv_Ban( target, reason )
	local rec = Identity.Sv_FindByPerma( target ) or Identity.Sv_FindByName( target )
	if rec == nil then
		return false, string.format( "no player known as '%s' -- /players or /known", tostring( target ) )
	end
	if Identity.Sv_BanEntry( rec.perma ) then
		return false, string.format( "%s (%s) is already banned", rec.names[#rec.names], rec.perma )
	end

	table.insert( Identity.bans.bans, {
		perma = rec.perma,
		names = rec.names,           -- every alias, so a rename does not dodge it
		steamId = rec.steamId or "",
		reason = reason or "",
		at = now(),
	} )
	Identity.Sv_SaveBans()
	return true, string.format( "banned %s (%s)", rec.names[#rec.names], rec.perma ), rec
end

function Identity.Sv_Unban( target )
	local rec = Identity.Sv_FindByPerma( target ) or Identity.Sv_FindByName( target )
	local perma = rec and rec.perma or target
	local i, entry = Identity.Sv_BanEntry( perma )
	if not i then
		return false, string.format( "'%s' is not banned", tostring( target ) )
	end
	table.remove( Identity.bans.bans, i )
	Identity.Sv_SaveBans()
	return true, string.format( "unbanned %s", entry.names and entry.names[#entry.names] or perma )
end

function Identity.Sv_BanLines()
	if #Identity.bans.bans == 0 then
		return { "ban list is empty" }
	end
	local lines = {}
	for i, entry in ipairs( Identity.bans.bans ) do
		local id = ( entry.steamId ~= nil and entry.steamId ~= "" ) and entry.steamId or "steam id unresolved"
		lines[#lines + 1] = string.format( "%d. %s  %s  (%s)", i, entry.perma,
			entry.names and entry.names[#entry.names] or "?", id )
	end
	return lines
end

function Identity.Sv_KnownLines( limit )
	local lines = {}
	local records = Identity.players.records
	local from = math.max( 1, #records - ( limit or 20 ) + 1 )
	for i = from, #records do
		local rec = records[i]
		lines[#lines + 1] = string.format( "  %s  %s%s", rec.perma,
			rec.names[#rec.names],
			#rec.names > 1 and string.format( " (+%d alias)", #rec.names - 1 ) or "" )
	end
	if #lines == 0 then
		lines[1] = "nobody recorded yet"
	end
	return lines
end
