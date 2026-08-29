-- Bridge -- a file the mod watches, so a session can be driven from outside it.
--
-- ASKED FOR: "we can make you dirrectly connect to the game?" -- after
-- establishing that the slow part of this project is not the work, it is the
-- round trip: a change is written here, the owner loads a world, tries it,
-- comes back and describes what happened. Half a day of that is one afternoon
-- of tests.
--
-- This is that connection, and it is built out of the only thing the sandbox
-- offers: `sm.json` on the mod's own folder. There is no network, no sockets,
-- no filesystem outside $CONTENT_* (measured -- see MODS-AND-TRUST.md).
--
--     outside            writes  $CONTENT_DATA/Cmd-7.json
--     this file, 2 Hz    reads it, runs it as the HOST, captures every reply
--                        writes  $CONTENT_DATA/Out-7.json
--     outside            reads that, writes Cmd-8.json
--
--
-- A NEW FILENAME EVERY TIME, AND THAT IS THE WHOLE DESIGN
--
-- The one thing that could have killed this idea: the engine keeps a Cache/
-- folder inside the mod with compiled copies of the data files it reads
-- (MEASURED, 2026-08-23 -- every .rco was stamped hours before the .lua it came
-- from). If sm.json.open serves a cached copy, a file rewritten from outside
-- would come back stale forever and nothing here would work.
--
-- So no file is ever read twice. The sequence number goes up, the path changes,
-- and a path that has never been read cannot be a stale read. That turns an
-- unknown that needed an experiment into a property of the design.
--
-- What is left is fileExists on a path that did not exist a moment ago. If THAT
-- turns out to be cached, the fix is one line -- drop to pcall( sm.json.open )
-- as the existence test, which cannot be answered from a cache of nothing --
-- and Bridge.sv_poll is written so that is the only line to change.
--
--
-- WHY THIS IS SAFE, WHICH IT HAS TO BE
--
-- It is a remote control for a game server, so:
--
--   * OFF unless switched on. `bridge` is a setting, default false, and while
--     it is off this file does not read, write or poll anything at all.
--   * host only, both to switch on and to run.
--   * it runs CHAT COMMANDS, as the host, through the same dispatch a typed
--     command goes through. It cannot reach anything the host could not type,
--     and every host gate still applies.
--   * every command it runs is written to the log before it runs, so a session
--     driven from outside reads back exactly like one driven by hand.
--
-- allow_add_mods is false in this mod because the mod list is the trust
-- boundary (MODS-AND-TRUST.md). This file is the same argument pointed at a
-- file: it is a door, so it is shut by default and it is narrow when open.

Bridge = {}

-- Twice a second. The cost while switched on is one fileExists per 20 ticks;
-- while off it is one boolean test.
Bridge.POLL_TICKS = 20

-- Where the outside looks to find out where we are up to: the sequence number
-- it should write next, and whether the bridge is even on.
Bridge.STATE = "$CONTENT_DATA/Bridge.json"

-- How many replies one command may return. A runaway command that replies per
-- body could otherwise write a file the size of the city.
Bridge.MAX_LINES = 400

-- Commands per file. Small on purpose: a batch that half-runs is harder to
-- reason about than two batches.
Bridge.MAX_COMMANDS = 20


function Bridge.CmdPath( seq )
	return string.format( "$CONTENT_DATA/Cmd-%d.json", math.floor( seq or 1 ) )
end

function Bridge.OutPath( seq )
	return string.format( "$CONTENT_DATA/Out-%d.json", math.floor( seq or 1 ) )
end


-- HOW LONG TO KEEP LISTENING AFTER THE LAST COMMAND, in seconds.
--
-- This is the part that is not obvious, and getting it wrong would make the
-- bridge look broken for half the commands in the mod. A WORLD command does not
-- answer while it runs: Game hands it to the world as an event, the world deals
-- with it on its own tick, and the reply comes back through sv_e_swReply some
-- time later. A capture that closed when the call returned would catch every
-- reply from Game.lua and almost none from World.lua -- which is /plot, /why,
-- /budget, /protection, /purge, /snapshot and the whole city.
--
-- So the capture stays open on a CLOCK, not on a call. Anything that arrives
-- inside the window belongs to the batch.
Bridge.WAIT_DEFAULT = 1.5
Bridge.WAIT_MAX = 120

function Bridge.Wait( data )
	local w = tonumber( type( data ) == "table" and data.wait or nil )
	if w == nil then return Bridge.WAIT_DEFAULT end
	if w < 0 then return 0 end
	if w > Bridge.WAIT_MAX then return Bridge.WAIT_MAX end
	return w
end

function Bridge.sv_new()
	local self = {
		seq = 1,
		nextPoll = 0,
		ran = 0,
		-- Set while a command is running, so every reply funnel in Game.lua can
		-- drop its text in here instead of only sending it to a chat box nobody
		-- outside the game can read.
		capture = nil,
		-- { seq, entries, deadline } while a batch is still listening.
		pending = nil,
	}
	return self
end

-- Read where we got to last time. A world reload must not start writing over
-- results that are already on disk, and the outside reads this file to find out
-- which number to write next.
function Bridge.sv_load( self )
	local ok, exists = pcall( sm.json.fileExists, Bridge.STATE )
	if not ( ok and exists ) then return end
	local read, data = pcall( sm.json.open, Bridge.STATE )
	if not ( read and type( data ) == "table" ) then return end
	local seq = tonumber( data.seq )
	if seq and seq > self.seq then self.seq = math.floor( seq ) end
end

-- Written after every command AND whenever the switch is flipped, because it is
-- the only thing the outside can see: it says whether the bridge is listening,
-- which file it is listening for, and what it has done.
function Bridge.sv_save( self, on )
	local ok, err = pcall( sm.json.save, {
		on = on and true or false,
		seq = self.seq,
		waitingFor = Bridge.CmdPath( self.seq ),
		ran = self.ran,
		build = Checklist and Checklist.BUILD or nil,
	}, Bridge.STATE )
	if not ok then
		sm.log.warning( "[ServerWorks] bridge could not write its state: " .. tostring( err ) )
	end
end


-- THE POLL. Returns the decoded command table, or nil.
--
-- If the existence test ever turns out to be cached, this is the only function
-- that has to change: drop fileExists and let the pcall around open be the
-- test. It is written as two steps so that is a one-line edit.
function Bridge.sv_poll( self )
	local path = Bridge.CmdPath( self.seq )
	local ok, exists = pcall( sm.json.fileExists, path )
	if not ( ok and exists ) then return nil end
	local read, data = pcall( sm.json.open, path )
	if not read then
		sm.log.warning( "[ServerWorks] bridge could not read " .. path .. ": "
			.. tostring( data ) )
		-- Move past it rather than reading a broken file forever. The outside
		-- sees the sequence number move and no result, which says exactly this.
		self.seq = self.seq + 1
		return nil
	end
	if type( data ) ~= "table" then
		-- The file is there and is not a command file. Moving past it matters as
		-- much as reading a good one: leaving the number where it is would poll
		-- the same bad file twice a second forever, and the outside would see a
		-- bridge that is on, listening, and answering nothing.
		sm.log.warning( "[ServerWorks] bridge: " .. path .. " is not a command file" )
		self.seq = self.seq + 1
		return nil
	end
	return data
end


-- What to run out of one command file, as a list of word-lists -- because
-- bindChatCommand splits on spaces and so does the dispatch these end up in.
--
-- Accepts either shape, since both are natural to write from outside:
--   { commands = { "/set plots on", "/plot claim" } }
--   { commands = { { "/set", "plots", "on" } } }
function Bridge.Parse( data )
	local out = {}
	if type( data ) ~= "table" then return out end
	local list = data.commands
	if type( list ) ~= "table" then return out end
	for _, entry in ipairs( list ) do
		local words = {}
		if type( entry ) == "string" then
			for word in string.gmatch( entry, "%S+" ) do
				words[#words + 1] = word
			end
		elseif type( entry ) == "table" then
			for _, word in ipairs( entry ) do
				words[#words + 1] = tostring( word )
			end
		end
		-- A line that is not a command is refused here rather than being handed
		-- to a dispatch that would answer "Host only." and confuse the reader.
		if words[1] ~= nil and string.sub( words[1], 1, 1 ) == "/" then
			out[#out + 1] = words
			if #out >= Bridge.MAX_COMMANDS then break end
		end
	end
	return out
end


-- Reply capture. Game.lua's reply funnels call this; it returns true when the
-- text was taken, so the caller still knows whether to send it to chat as well.
-- It always sends as well, because a host watching the screen should see what
-- the bridge is doing to their world.
function Bridge.sv_capture( self, text )
	local buf = self.capture
	if buf == nil then return false end
	if #buf >= Bridge.MAX_LINES then return true end
	buf[#buf + 1] = tostring( text )
	return true
end


function Bridge.sv_writeResult( self, seq, entries, note, lines )
	local ok, err = pcall( sm.json.save, {
		seq = seq,
		note = note,
		tick = sm.game.getCurrentTick(),
		-- Everything anything said while the batch was listening, in order.
		-- This is the transcript; `results` is what each command was and
		-- whether the call itself threw.
		said = lines or {},
		results = entries,
	}, Bridge.OutPath( seq ) )
	if not ok then
		sm.log.warning( "[ServerWorks] bridge could not write a result: " .. tostring( err ) )
		return false
	end
	return true
end
