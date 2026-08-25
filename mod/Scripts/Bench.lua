-- Bench -- add players until something gives, and write down what did.
--
-- Asked for as: "can you add a command that tests for me? like a spawner that
-- spawns 1 player per something and it checks FPS. and records that."
--
-- /bench walks the crowd up in steps -- 0, 5, 10, 15, ... -- holds each size
-- still for a measured window, and records frame rate, tick rate and world size
-- at every step. What comes out is a table you can read down: the row where the
-- numbers turn is the answer to "how many people can this server hold", and it
-- is the first time this project has been able to ask that without a lobby.
--
--
-- THERE IS NO CLOCK IN THIS ENGINE'S LUA, SO THE CLIENT IS THE STOPWATCH
--
-- `os` does not exist in the sandbox (measured -- see CLAUDE.md), and
-- sm.game.getCurrentTick() is the simulation counter, which is the very thing a
-- benchmark is trying to measure. A counter cannot be its own reference: if the
-- server drops to 20 Hz, a stage timed in ticks silently takes twice as long and
-- every rate computed from it comes out at exactly 40.
--
-- The one real-time quantity Lua can see is the `dt` handed to
-- client_onUpdate. It is wall-clock seconds -- proven by what vanilla does with
-- it, `timeOfDay + dt / DAYCYCLE_TIME` (CreativeGame.lua:208), which would drift
-- against the sun if it were anything else.
--
-- So the HOST'S CLIENT is the metronome. It reports once a second: how many
-- frames it drew, how many real seconds passed, and how many simulation ticks
-- went by in that same interval. From those three the server gets frame rate AND
-- tick rate against a real clock, and the stage timer runs on real seconds
-- rather than on simulation steps.
--
-- All three are DELTAS over one interval, which is the detail that actually
-- matters. An earlier version sent the absolute tick and differenced the ends of
-- the window: N samples span N seconds but only N-1 gaps between timestamps, so
-- a clean 40 Hz server reported 36. Nothing about that number looks wrong.
-- dev/test_logic.py caught it and now guards it.
--
-- The host specifically, because on the host the client and the server are one
-- process and one tick counter. A GUEST's tick counter is its own simulation
-- loop, not the server's -- so guests are sampled for FRAME RATE ONLY, which is
-- the number that actually degraded in the one real event on record.
--
--
-- WHAT THIS MEASURES AND WHAT IT CANNOT
--
-- docs/CROWD.md has the full table. The two lines that matter here:
--
--   * bots have no client connection, so the per-client NETWORK BUDGET (the
--     thing that showed three starved clients in the 2026-07-10 log) stays at
--     zero however many are spawned. A guest is required for that, and one
--     guest is enough. /bench records the count anyway, from the same census
--     path, so a run WITH a guest fills that column in.
--   * the host's frame rate is one machine's. Twenty people each rendering the
--     city is twenty machines, and no binding reaches the renderer.

Bench = class( nil )

Bench.PATH = "$CONTENT_DATA/Bench.json"

Bench.STEP = 5          -- bots added per stage
Bench.SETTLE = 6        -- seconds discarded after a size change
Bench.WINDOW = 30       -- seconds measured per stage

-- If the host client stops reporting for this many ticks the run is abandoned
-- rather than left hanging. At 40 Hz that is fifteen seconds of silence, which
-- is far longer than a frame-rate dip and short enough to notice.
Bench.WATCHDOG = 600

function Bench.sv_onCreate( self, crowd )
	self.crowd = crowd
	self.state = "idle"
	self.rows = {}
	self:sv_resetStage()
end

function Bench.sv_running( self )
	return self.state ~= "idle"
end

function Bench.sv_resetStage( self )
	self.stage = {
		secs = 0, frames = 0, ticks = 0,
		fpsMin = nil,
		clients = {},          -- name -> { frames, secs }
	}
end

--------------------------------------------------------------------------------
-- Driving
--------------------------------------------------------------------------------

function Bench.sv_start( self, step, window, maxBots, reply )
	if self:sv_running() then
		reply( "a bench is already running -- /bench stop first" )
		return false
	end

	self.step = math.max( 1, math.floor( step or Bench.STEP ) )
	self.window = math.max( 5, math.floor( window or Bench.WINDOW ) )
	self.maxBots = math.max( self.step, math.min( Crowd.MAX, math.floor( maxBots or Crowd.MAX ) ) )

	self.rows = {}
	self.target = 0                 -- the first stage is the BASELINE, no bots
	self.lastSample = sm.game.getCurrentTick()
	self.state = "settle"
	self:sv_resetStage()

	-- Start from a clean city. A bench that began with somebody else's crowd
	-- still standing would put its baseline row at the wrong number and every
	-- later row would be measured against it.
	self.crowd:sv_clear()

	self.armed = true
	sm.event.sendToGame( "sv_e_swBenchArm", { on = true } )

	reply( string.format( "BENCH: +%d bots every %ds, up to %d.",
		self.step, self.window + Bench.SETTLE, self.maxBots ) )
	reply( string.format( "  about %d minutes. /bench stop to abandon it.",
		math.ceil( ( self.maxBots / self.step + 1 ) * ( self.window + Bench.SETTLE ) / 60 ) ) )
	reply( "  stand still and do not open a menu -- you are the frame-rate probe." )
	sm.log.info( string.format(
		"[ServerWorks] bench start: step %d, window %ds, max %d",
		self.step, self.window, self.maxBots ) )
	return true
end

function Bench.sv_stop( self, reply, why )
	if not self:sv_running() then
		if reply then reply( "no bench is running" ) end
		return
	end
	self.state = "idle"
	self.armed = false
	sm.event.sendToGame( "sv_e_swBenchArm", { on = false } )
	self.crowd:sv_clear()
	if reply then
		reply( "bench " .. ( why or "stopped" ) .. " -- crowd cleared" )
	end
	sm.log.info( "[ServerWorks] bench " .. ( why or "stopped" ) )
end

-- One second of one client's frames. THE HOST'S sample is the metronome; a
-- guest's counts only towards that guest's own frame rate.
--
-- Called from Game.sv_n_benchSample, which is guest-reachable on purpose -- a
-- guest reporting its own frame rate is the whole point. Nothing here trusts the
-- payload for anything but arithmetic: `name` is used as a label, never as an
-- identity, and a client that lies only spoils its own row.
function Bench.sv_sample( self, name, isHost, frames, secs, ticks )
	if not self:sv_running() then return end
	if type( frames ) ~= "number" or type( secs ) ~= "number" or secs <= 0 then
		return
	end
	-- A client reporting an implausible window is dropped rather than averaged
	-- in: a paused or alt-tabbed client can hand over one enormous dt, and one
	-- of those in a thirty-second mean is enough to move the answer.
	if secs > 5 or frames < 0 or frames > 10000 then return end

	local st = self.stage
	local c = st.clients[name]
	if c == nil then
		c = { frames = 0, secs = 0 }
		st.clients[name] = c
	end
	c.frames = c.frames + frames
	c.secs = c.secs + secs

	if not isHost then return end

	self.lastSample = sm.game.getCurrentTick()
	st.secs = st.secs + secs
	st.frames = st.frames + frames
	-- A DELTA sent by the client, covering exactly the interval its frames and
	-- seconds cover. Summing absolute ticks and differencing the ends instead
	-- loses one interval in N and reported 36 Hz on a clean 40.
	st.ticks = st.ticks + ( type( ticks ) == "number" and ticks >= 0 and ticks or 0 )

	local fps = frames / secs
	if st.fpsMin == nil or fps < st.fpsMin then st.fpsMin = fps end

	if self.state == "settle" then
		-- Everything so far is the cost of SPAWNING, not of standing. Thrown
		-- away, and the stage restarted, or the row would blame N bots for the
		-- one-off price of creating them.
		if st.secs >= Bench.SETTLE then
			self:sv_resetStage()
			self.state = "measure"
		end
		return
	end

	if st.secs >= self.window then
		self:sv_record()
	end
end

function Bench.sv_record( self )
	local st = self.stage
	local secs = st.secs
	local ticks = st.ticks

	local clients = {}
	for name, c in pairs( st.clients ) do
		if c.secs > 0 then
			clients[#clients + 1] = { name = name, fps = c.frames / c.secs }
		end
	end

	local row = {
		bots = self.target,
		secs = secs,
		fps = ( secs > 0 ) and ( st.frames / secs ) or 0,
		fpsMin = st.fpsMin or 0,
		tickRate = ( secs > 0 ) and ( ticks / secs ) or 0,
		shapes = g_swProtection and g_swProtection:sv_census() or nil,
		bodies = self:sv_bodyCount(),
		mode = self.crowd.mode or "off",
		clients = clients,
	}
	self.rows[#self.rows + 1] = row

	-- To the log as well as to chat, and in a shape dev/session_stats.py's
	-- reader can sit beside: this is the line that dates the stage.
	sm.log.info( string.format(
		"[ServerWorks] bench row: bots=%d fps=%.1f fpsmin=%.1f tick=%.1f "
		.. "shapes=%s bodies=%d over %.0fs",
		row.bots, row.fps, row.fpsMin, row.tickRate,
		tostring( row.shapes ), row.bodies, row.secs ) )

	sm.event.sendToGame( "sv_e_swBroadcast", { text = string.format(
		"BENCH  %3d bots   %5.1f fps (min %.0f)   %4.1f tick/s",
		row.bots, row.fps, row.fpsMin, row.tickRate ) } )

	self:sv_advance()
end

function Bench.sv_bodyCount( self )
	local ok, bodies = pcall( sm.body.getAllBodies )
	return ok and bodies and #bodies or 0
end

function Bench.sv_advance( self )
	if self.target >= self.maxBots then
		self:sv_finish()
		return
	end

	self.target = math.min( self.maxBots, self.target + self.step )
	local got = self.crowd:sv_set( self.target )
	if got < self.target then
		-- The crowd could not reach the size asked for. Recording the truth and
		-- stopping beats recording a row labelled with a number of bots that are
		-- not standing there.
		self.target = got
		self:sv_resetStage()
		self.state = "measure"
		sm.log.warning( string.format(
			"[ServerWorks] bench: crowd stalled at %d, finishing early", got ) )
		self:sv_finish()
		return
	end

	self:sv_resetStage()
	self.state = "settle"
end

function Bench.sv_finish( self )
	self.state = "idle"
	self.armed = false
	sm.event.sendToGame( "sv_e_swBenchArm", { on = false } )
	self:sv_save()
	sm.event.sendToGame( "sv_e_swBroadcast", { text = "BENCH complete -- /bench results" } )
	sm.log.info( string.format( "[ServerWorks] bench complete: %d rows", #self.rows ) )
	-- The crowd is deliberately LEFT STANDING. The run has just proved what the
	-- city does at this size, and clearing it would throw away the state a host
	-- most likely wants to look at. /crowd off when done.
end

-- The host client can stop reporting for reasons that are not a crash -- alt-tab
-- on some drivers, a load screen. Without this the run would sit in "measure"
-- forever with a crowd standing and no way to tell it had died.
function Bench.sv_onFixedUpdate( self, tick )
	if not self:sv_running() then return end
	if tick - ( self.lastSample or tick ) > Bench.WATCHDOG then
		self:sv_stop( nil, "abandoned: the host client stopped reporting" )
		sm.event.sendToGame( "sv_e_swBroadcast",
			{ text = "BENCH abandoned -- no frame reports from the host" } )
	end
end

--------------------------------------------------------------------------------
-- Reporting
--------------------------------------------------------------------------------

function Bench.sv_lines( self )
	if #self.rows == 0 then
		return { "no bench results yet -- /bench start" }
	end

	local out = { "BENCH RESULTS      fps    min   tick/s   shapes  bodies" }
	local base = self.rows[1]
	for _, r in ipairs( self.rows ) do
		-- Frame rate as a percentage of the empty-city baseline is the column a
		-- host actually reads: "40 fps" means nothing without knowing it started
		-- at 60.
		local pct = ( base.fps > 0 ) and ( r.fps / base.fps * 100 ) or 0
		out[#out + 1] = string.format(
			"  %3d bots      %5.1f  %5.1f    %4.1f   %6s  %6d   (%d%% of empty)",
			r.bots, r.fps, r.fpsMin, r.tickRate,
			tostring( r.shapes or "?" ), r.bodies, math.floor( pct + 0.5 ) )
	end

	-- Say where it turned, rather than leaving it to be eyeballed. Two
	-- thresholds, because the two failure modes are different and this project
	-- has already measured that they do not arrive together: tick rate is the
	-- simulation giving up, frame rate is the client.
	local firstTick, firstFps = nil, nil
	for _, r in ipairs( self.rows ) do
		if firstTick == nil and r.tickRate > 0 and r.tickRate < 36 then
			firstTick = r.bots
		end
		if firstFps == nil and base.fps > 0 and r.fps < base.fps * 0.5 then
			firstFps = r.bots
		end
	end
	out[#out + 1] = firstTick
		and string.format( "  tick fell below 36 Hz at %d bots", firstTick )
		or  "  tick rate never fell below 36 Hz"
	out[#out + 1] = firstFps
		and string.format( "  frame rate halved at %d bots", firstFps )
		or  "  frame rate never halved"

	local last = self.rows[#self.rows]
	if #last.clients > 1 then
		out[#out + 1] = "  per client, at the last size:"
		for _, c in ipairs( last.clients ) do
			out[#out + 1] = string.format( "    %-18s %5.1f fps", c.name, c.fps )
		end
	end
	out[#out + 1] = "  network budget: read it off the log with dev/session_stats.py"
	return out
end

function Bench.sv_save( self )
	local ok, err = pcall( sm.json.save, { rows = self.rows }, Bench.PATH )
	if not ok then
		sm.log.warning( "[ServerWorks] could not write bench results: " .. tostring( err ) )
	end
end

function Bench.sv_load( self )
	local ok, exists = pcall( sm.json.fileExists, Bench.PATH )
	if not ( ok and exists ) then return end
	local read, data = pcall( sm.json.open, Bench.PATH )
	if read and type( data ) == "table" and type( data.rows ) == "table" then
		self.rows = data.rows
	end
end

function Bench.sv_status( self )
	if not self:sv_running() then
		return string.format( "BENCH idle   %d row(s) recorded", #self.rows )
	end
	return string.format( "BENCH %s   %d bots   %.0f/%ds into this stage   %d row(s) done",
		self.state, self.target, self.stage.secs,
		self.state == "settle" and Bench.SETTLE or self.window, #self.rows )
end
