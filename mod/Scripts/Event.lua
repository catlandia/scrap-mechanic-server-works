-- Event -- the clock the whole event runs on.
--
-- An event has a shape, and until now the mod had no idea what it was. There was
-- /buildtime N, which locked builds when a number of minutes ran out, and that
-- was the whole of it: no before, no after, and nothing anybody could look at to
-- find out how long was left.
--
--     off  ->  prep  ->  build  ->  buffer  ->  ended
--
--   prep    people arrive and CLAIM a plot. Nobody can build yet, and that is
--           the ONLY thing prep changes -- every other rule the server enforces
--           still applies, seats and buttons still work, nothing is frozen.
--   build   the event. Building open, on your own plot.
--   buffer  optional, and off by default. Building has closed but the world is
--           not sealed yet: time to walk round, take pictures, judge, and stop
--           panicking before anything becomes permanent.
--   ended   the world locks and everything is snapshotted, which is what
--           /buildtime always did and is kept because it is right.
--
-- Claiming during prep rather than at the whistle is the point of having a prep
-- phase at all: twenty people racing to claim ground at the same moment as they
-- start building is how you get a scramble, and the plot you end up with is
-- decided by who loaded the world fastest.
--
--
-- WHY WALL CLOCK AND NOT TICKS
--
-- Deadlines are stored as epoch seconds from os.time(), which Identity.lua
-- already proves works here (the ban list stamps every entry with it). Ticks
-- would have been the obvious choice -- sm.game.getCurrentTick() is right there
-- -- but the tick counter starts again at zero every time the server does, so a
-- deadline written in ticks is meaningless the moment anybody reloads. An event
-- that forgets how long is left because the host restarted is exactly the
-- failure this is supposed to prevent.
--
-- The clients still count down in ticks between updates, for smoothness; see
-- EventHud. That is presentation. This is the truth.
--
--
-- This file is PURE apart from os.time and sm.json: no bodies, no players, no
-- GUI. `now` is passed in to every function that needs it, so the whole state
-- machine can be run forwards through a whole event in dev/test_logic.py without
-- waiting an hour.

Event = class( nil )

Event.FILE = "$CONTENT_DATA/Event.json"

-- The point where the calm timer hands over to the warehouse explosion timer.
-- FIVE MINUTES IS NOT AN ARBITRARY CHOICE: survival_constants.lua:186 sets
-- WAREHOUSE_DESTRUCTION_TICKS = 40 * 60 * 5, and NotificationManager divides
-- exactly that span into the three escalating alarms. Hand over at any other
-- number and the alarm levels no longer line up with what is on screen.
Event.PANIC_SECONDS = 5 * 60

Event.DEFAULT_PREP = 10
Event.DEFAULT_BUILD = 60
Event.DEFAULT_BUFFER = 0

local function clockNow()
	local ok, t = pcall( os.time )
	return ok and t or 0
end

function Event.sv_onCreate( self, saved )
	self.phase = "off"
	self.deadline = nil          -- epoch seconds, or nil
	self.pausedLeft = nil        -- seconds remaining, while paused
	self.prepMinutes = Event.DEFAULT_PREP
	self.buildMinutes = Event.DEFAULT_BUILD
	self.bufferMinutes = Event.DEFAULT_BUFFER
	self.announced = {}          -- which "N minutes left" calls have gone out

	if type( saved ) == "table" then
		self.phase = saved.phase or "off"
		self.deadline = saved.deadline
		self.pausedLeft = saved.pausedLeft
		self.prepMinutes = saved.prepMinutes or Event.DEFAULT_PREP
		self.buildMinutes = saved.buildMinutes or Event.DEFAULT_BUILD
		self.bufferMinutes = saved.bufferMinutes or Event.DEFAULT_BUFFER
		self.announced = saved.announced or {}
	end
end

function Event.sv_serialise( self )
	return {
		phase = self.phase, deadline = self.deadline, pausedLeft = self.pausedLeft,
		prepMinutes = self.prepMinutes, buildMinutes = self.buildMinutes,
		bufferMinutes = self.bufferMinutes,
		announced = self.announced,
	}
end

function Event.Sv_LoadFile()
	local ok, exists = pcall( sm.json.fileExists, Event.FILE )
	if not ok or not exists then return nil end
	local read, loaded = pcall( sm.json.open, Event.FILE )
	return ( read and type( loaded ) == "table" ) and loaded or nil
end

function Event.Sv_SaveFile( event )
	local ok, err = pcall( sm.json.save, event:sv_serialise(), Event.FILE )
	if not ok then
		sm.log.warning( "[ServerWorks] could not write event: " .. tostring( err ) )
	end
end


--[[ state ]]

function Event.sv_running( self )
	return self.phase == "prep" or self.phase == "build" or self.phase == "buffer"
end

function Event.sv_paused( self )
	return self.pausedLeft ~= nil
end

-- Seconds left in the current phase, or nil when there is no clock running.
function Event.sv_remaining( self, now )
	if self.pausedLeft then return self.pausedLeft end
	if self.deadline == nil then return nil end
	return math.max( 0, self.deadline - ( now or clockNow() ) )
end

-- Is building allowed right now? The one question the rest of the mod asks.
function Event.sv_buildAllowed( self )
	if self.phase == "off" then return nil end     -- no event: not our decision
	return self.phase == "build"
end

-- Are we inside the window where the warehouse timer takes over?
function Event.sv_panicking( self, now )
	if self.phase ~= "build" or self:sv_paused() then return false end
	local left = self:sv_remaining( now )
	return left ~= nil and left <= Event.PANIC_SECONDS
end


--[[ transitions ]]

function Event.sv_start( self, prepMinutes, buildMinutes, now, bufferMinutes )
	now = now or clockNow()
	prepMinutes = math.max( 0, tonumber( prepMinutes ) or self.prepMinutes )
	buildMinutes = math.max( 1, tonumber( buildMinutes ) or self.buildMinutes )
	self.prepMinutes = prepMinutes
	self.buildMinutes = buildMinutes
	if bufferMinutes ~= nil then
		self.bufferMinutes = math.max( 0, tonumber( bufferMinutes ) or 0 )
	end
	self.pausedLeft = nil
	self.announced = {}

	-- A zero-minute prep is legitimate and means "start now" -- it is how
	-- /buildtime keeps working on top of this.
	if prepMinutes > 0 then
		self.phase = "prep"
		self.deadline = now + prepMinutes * 60
	else
		self.phase = "build"
		self.deadline = now + buildMinutes * 60
	end
	return true, self.phase
end

function Event.sv_stop( self )
	self.phase = "off"
	self.deadline = nil
	self.pausedLeft = nil
	self.announced = {}
	return true
end

function Event.sv_pause( self, now )
	if not self:sv_running() then return false, "no event is running" end
	if self:sv_paused() then return false, "already paused" end
	self.pausedLeft = self:sv_remaining( now )
	self.deadline = nil
	return true, string.format( "paused with %s left", Event.Clock( self.pausedLeft ) )
end

function Event.sv_resume( self, now )
	if not self:sv_running() then return false, "no event is running" end
	if not self:sv_paused() then return false, "not paused" end
	self.deadline = ( now or clockNow() ) + self.pausedLeft
	self.pausedLeft = nil
	return true, "resumed"
end

-- Add or remove time from whatever phase is running. Negative shortens it, which
-- is how a host who is running late gets everybody back on schedule.
function Event.sv_addMinutes( self, minutes, now )
	minutes = tonumber( minutes ) or 0
	if not self:sv_running() then return false, "no event is running" end
	if self:sv_paused() then
		self.pausedLeft = math.max( 0, self.pausedLeft + minutes * 60 )
	else
		self.deadline = math.max( now or clockNow(), self.deadline + minutes * 60 )
	end
	-- Adding time can put us back above a threshold we already called out; let
	-- those announcements happen again rather than going quiet.
	if minutes > 0 then self.announced = {} end
	return true, string.format( "%s -- %s left",
		minutes >= 0 and string.format( "added %g min", minutes )
			or string.format( "removed %g min", -minutes ),
		Event.Clock( self:sv_remaining( now ) ) )
end

-- Skip straight to the next phase. The host is running the event; if they say
-- building starts now, it starts now.
function Event.sv_skip( self, now )
	now = now or clockNow()
	if self.phase == "prep" then
		self.phase = "build"
		self.deadline = now + self.buildMinutes * 60
		self.pausedLeft = nil
		self.announced = {}
		return true, "build"
	elseif self.phase == "build" and self.bufferMinutes > 0 then
		self.phase = "buffer"
		self.deadline = now + self.bufferMinutes * 60
		self.pausedLeft = nil
		return true, "buffer"
	elseif self.phase == "build" or self.phase == "buffer" then
		self.phase = "ended"
		self.deadline = nil
		self.pausedLeft = nil
		return true, "ended"
	end
	return false, "nothing to skip"
end

-- Called every tick. Returns the phase we just moved INTO, or nil.
--
-- Deliberately advances at most one phase per call: the caller has real work to
-- do on each transition -- opening building, locking the world, starting a
-- snapshot -- and doing two of those in one tick because the server was frozen
-- for a while would be worse than taking two ticks over it.
-- Advance as far as the clock says, not one phase per call.
--
-- THE NEXT DEADLINE COMES FROM THE LAST ONE, never from `now`. That is the whole
-- fix, and getting it wrong had a symptom nobody would connect to a clock:
--
-- MEASURED, from the log at load:
--     event resumed: build, 00:00 left
--     event buffer -> protection polish
--
-- An event that had expired hours earlier resumed, saw build was over, and
-- started a FRESH FIVE MINUTE BUFFER counted from the moment the world loaded.
-- Buffer is the `polish` profile -- no placing, no breaking -- so every single
-- load dropped the world into a window where the remove tool showed no red
-- preview and nothing could be built. Reported as "still broken red colour",
-- and it was the event clock the whole time.
--
-- Deadlines are absolute epoch seconds by design (see the note at the top of
-- this file). Scheduling the next one from `now` threw that away and let a dead
-- event resurrect itself on every load, forever.
--
-- The loop matters too: a stale event has to land where it actually belongs in
-- one go, rather than passing through -- and announcing -- phases that finished
-- while the game was shut.
function Event.sv_advance( self, now )
	if not self:sv_running() or self:sv_paused() then return nil end
	now = now or clockNow()
	if self.deadline == nil or now < self.deadline then return nil end

	local landed = nil
	-- Four phases at most, so this cannot spin.
	for _ = 1, 4 do
		local from = self.deadline
		if self.phase == "prep" then
			self.phase = "build"
			self.deadline = from + self.buildMinutes * 60
			self.announced = {}
		elseif self.phase == "build" and self.bufferMinutes > 0 then
			self.phase = "buffer"
			self.deadline = from + self.bufferMinutes * 60
		else
			self.phase = "ended"
			self.deadline = nil
		end
		landed = self.phase
		if self.deadline == nil or now < self.deadline then break end
	end
	return landed
end

-- Which "N minutes left" call is due, once each. Returns the number or nil.
Event.CALLS = { 30, 15, 10, 5, 2, 1 }

function Event.sv_dueCall( self, now )
	if self.phase ~= "build" or self:sv_paused() then return nil end
	local left = self:sv_remaining( now )
	if left == nil then return nil end
	for _, minutes in ipairs( Event.CALLS ) do
		local key = tostring( minutes )
		if not self.announced[key] and left <= minutes * 60 and left > ( minutes * 60 ) - 60 then
			self.announced[key] = true
			return minutes
		end
	end
	return nil
end


--[[ presentation ]]

-- MM:SS, or H:MM:SS once there is an hour to show. sm.gui.ticksToTimeString
-- exists and would do this, but it takes ticks and our clock is in seconds, and
-- converting seconds to ticks to hand to a formatter to get seconds back is a
-- round trip that can only introduce error.
function Event.Clock( seconds )
	if seconds == nil then return "--:--" end
	seconds = math.max( 0, math.floor( seconds + 0.5 ) )
	local h = math.floor( seconds / 3600 )
	local m = math.floor( ( seconds % 3600 ) / 60 )
	local s = seconds % 60
	if h > 0 then
		return string.format( "%d:%02d:%02d", h, m, s )
	end
	return string.format( "%02d:%02d", m, s )
end

Event.LABELS = {
	off = "NO EVENT",
	prep = "PREP",
	build = "BUILD",
	buffer = "TIME UP",
	ended = "ENDED",
}

-- Which protection mode each phase puts the world in. This table is the fix for
-- a real bug: the phases used to only set `buildopen` and then re-apply whatever
-- protection mode happened to be current. But profileFor() short-circuits --
--
--     if isLockedMode( self.mode ) then return PROFILES[self.mode] end
--
-- -- so once an event ENDED and set the mode to "locked", starting a new one
-- left it locked and buildopen was never consulted again. REPORTED as "I cant
-- build when prep time is out". The event owns the mode now, explicitly.
--
--   prep    display: buildable false, but usable TRUE. "the prep time just
--           doesnt allow you to build. it maintains other rules."
--   build   open, and buildopen true
--   buffer  polish: paint, rewire and drive what you built, but no placing
--           and no breaking
--   ended   locked, and snapshotted
--   off     open, and the host has the controls back
Event.PROTECTION = {
	off = "open",
	prep = "display",
	build = "open",
	-- Not "display". REPORTED as an idea and it is a good one: "in bufer time you
	-- can paint. edit settings. use controllers. and other stuff like that. but
	-- not place or brake blocks. so you can polish some mechanic stuff if you
	-- messed it up a bit." That is Protection's `polish` profile.
	buffer = "polish",
	ended = "locked",
}

-- What the top-right HUD says under the clock. Short, because it is read at a
-- glance while somebody is holding a weld tool.
Event.HINTS = {
	off = "build freely",
	prep = "claim your plot -- no building yet",
	build = "build on your own plot",
	buffer = "building closed -- look around",
	ended = "builds are locked",
}

-- Everything a client needs to draw the HUD. Small enough to send every second.
function Event.sv_clientState( self, now )
	return {
		phase = self.phase,
		remaining = self:sv_remaining( now ),
		paused = self:sv_paused(),
		panic = self:sv_panicking( now ),
	}
end


-- A clock from a previous world means nothing here, and `ended` is the phase
-- that locks everything -- so inheriting it is what made a new world unusable.
function Event.Sv_ResetFile()
	local fresh = Event()
	fresh:sv_onCreate( nil )
	fresh:sv_stop()
	Event.Sv_SaveFile( fresh )
	return fresh
end
