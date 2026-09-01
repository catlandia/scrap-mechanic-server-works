"""Run the mod's decision-making in a real Lua interpreter and check what it decides.

check_lua.py proves the files parse. test_layout.py proves the city geometry is a
partition. This proves the RULES: who may build where, which profile a zone
resolves to, whether a setting takes the value you gave it, whether a ban
survives a reload, whether two plots may team up.

None of that needs a world, a body or a player, so none of it needs the game --
it needs a Lua interpreter and honest stubs for the handful of sm.* calls these
files make. lupa provides the first; STUB below is the second, and it is
deliberately small: the moment a stub has to get clever, the thing being tested
belongs in an in-game test instead.

WHAT THIS CANNOT TELL YOU. Everything that touches a body, a tool, a GUI or the
network. sm.body, sm.tool, sm.jsonGui and sm.player's real behaviour are the
engine's, and a stub that pretends otherwise would be a test that lies. Those are
the things that still have to be exercised in game.

Usage: python dev/test_logic.py
"""
import io
import json
import pathlib
import re
import sys

try:
    import lupa
except ImportError:
    sys.exit("lupa not installed:  pip install lupa")

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "mod" / "Scripts"

# Everything the modules under test reach for. Enough to run, not enough to lie.
STUB = r"""
function class( base )
    local c = {}
    c.__index = c
    if base then setmetatable( c, { __index = base } ) end
    setmetatable( c, { __index = base, __call = function( cls, ... )
        local o = setmetatable( {}, c )
        return o
    end } )
    return c
end
function dofile( _ ) end

FIRE_INSTANCE_LIMIT = 128

-- A tiny in-memory filesystem, so persistence is exercised for real rather than
-- mocked away: save then open must return what was saved.
_files = {}
local function deepcopy( v )
    if type( v ) ~= "table" then return v end
    local o = {}
    for k, x in pairs( v ) do o[k] = deepcopy( x ) end
    return o
end

_log = {}
_events = {}
sm = {
    exists = function( x ) return x ~= nil end,
    log = {
        info = function( m ) _log[#_log+1] = { "info", m } end,
        warning = function( m ) _log[#_log+1] = { "warning", m } end,
        error = function( m ) _log[#_log+1] = { "error", m } end,
    },
    json = {
        fileExists = function( p ) return _files[p] ~= nil end,
        open = function( p )
            if _files[p] == nil then error( "no such file: " .. p ) end
            return deepcopy( _files[p] )
        end,
        save = function( t, p ) _files[p] = deepcopy( t ) end,
        writeJsonString = function( t ) return "<json>" end,
        -- Snapshots parses the exported string back into a table so the file
        -- is real nested JSON rather than one giant escaped string. Without
        -- this every capture produced ZERO entries and said nothing about it --
        -- which is how the existing round-trip check passed while never once
        -- holding a snapshot with anything in it.
        parseJsonString = function( str ) return { bodies = {} } end,
    },
    uuid = {
        new = function( s ) return { s = s, __uuid = true } end,
        getNil = function() return { s = "00000000-0000-0000-0000-000000000000" } end,
    },
    vec3 = {
        new = function( x, y, z ) return { x = x, y = y, z = z } end,
        zero = function() return { x = 0, y = 0, z = 0 } end,
    },
    -- importFromString takes a rotation. Nothing here inspects it; it only has
    -- to exist, because restore passes one.
    quat = { identity = function() return { w = 1, x = 0, y = 0, z = 0 } end },
    game = {
        setEnableAggro = function() end,
        getCurrentTick = function() return _tick or 0 end,
    },
    -- Cross-script events are recorded rather than dispatched: a world script
    -- has no network, so "did it ask Game to do X" is the only observable, and
    -- swallowing them would let a broken hop pass.
    event = {
        sendToGame = function( name, params )
            _events[#_events+1] = { name = name, params = params }
        end,
        sendToWorld = function( _, name, params )
            _events[#_events+1] = { name = name, params = params }
        end,
    },
    fire = { setFireLimit = function() end },
    tool = { forceTool = function() end },
    container = {
        beginTransaction = function() end,
        endTransaction = function() end,
        abortTransaction = function() end,
        setItem = function() end,
    },
    player = {
        getAllPlayers = function() return _players or {} end,
        getHostPlayer = function() return _host end,
    },
    -- Bodies are the engine's, so the stub is deliberately inert -- but the
    -- snapshot round trip needs to be able to see SOME creations, so a test can
    -- put them in swTestBodies and they come back here.
    -- exportToString / importFromString are the engine's own round trip and a
    -- stub cannot honestly imitate them. These return something SHAPED right so
    -- the job machinery can be exercised; what they do not prove is the round
    -- trip itself, which only the game can.
    creation = {
        exportToString = function( body, a, b ) return "{\"bodies\":[]}" end,
        importFromString = function( ... ) return {} end,
    },
    body = {
        getAllBodies = function() return swTestBodies or {} end,
        getCreationsFromBodies = function( bodies )
            local out = {}
            for _, b in ipairs( bodies or {} ) do out[#out + 1] = { b } end
            return out
        end,
        getCreationBodies = function( body ) return { body } end,
    },
}
setmetatable( sm.uuid.new( "x" ), { __tostring = function( t ) return t.s end } )
-- tostring( uuid ) is used to key the tool tables, so it has to be stable
local uuid_mt = { __tostring = function( t ) return t.s end }
sm.uuid.new = function( s ) return setmetatable( { s = s }, uuid_mt ) end
"""

PASS, FAIL = [], []


def check(name, fn):
    try:
        fn()
    except AssertionError as e:
        FAIL.append((name, str(e)))
    except Exception as e:                       # noqa: BLE001
        FAIL.append((name, f"{type(e).__name__}: {e}"))
    else:
        PASS.append(name)


def fresh(*files):
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(STUB)
    for f in files:
        src = io.open(SCRIPTS / f, encoding="utf-8").read()
        lua.execute(src)
    return lua


# ---------------------------------------------------------------- settings ---

def settings_schema_is_sane():
    lua = fresh("Settings.lua")
    S = lua.globals().Settings
    seen, rows = set(), 0
    for row in S.SCHEMA.values():
        rows += 1
        key, kind, default = row["key"], row["kind"], row["default"]
        assert key not in seen, f"duplicate setting key {key!r}"
        seen.add(key)
        assert kind in ("bool", "number", "string"), f"{key}: unknown kind {kind!r}"
        if kind == "bool":
            assert isinstance(default, bool), f"{key}: bool default is {default!r}"
        elif kind == "number":
            assert isinstance(default, (int, float)), f"{key}: number default is {default!r}"
        else:
            assert isinstance(default, str), f"{key}: string default is {default!r}"
        assert row["help"] and len(row["help"]) > 4, f"{key}: no usable help text"
    assert rows >= 30, f"only {rows} settings, expected the full schema"
    return seen


def settings_presets_only_name_real_keys():
    lua = fresh("Settings.lua")
    S = lua.globals().Settings
    keys = {row["key"] for row in S.SCHEMA.values()}
    order = [n for n in S.PRESET_ORDER.values()]
    for name in order:
        preset = S.PRESETS[name]
        assert preset is not None, f"PRESET_ORDER names {name!r} but PRESETS has no such entry"
        assert preset["label"], f"preset {name!r} has no label for the panel"
        for k in preset["values"]:
            assert k in keys, f"preset {name!r} sets unknown setting {k!r}"
    for name in S.PRESETS:
        assert name in order, f"preset {name!r} exists but is not in PRESET_ORDER"


def settings_round_trip():
    lua = fresh("Settings.lua")
    S = lua.globals().Settings
    S.Sv_Load(False)
    assert S.Get("fire") is False, "fire should default off"
    ok, _ = S.Sv_Set("fire", "true"), None
    assert S.Get("fire") is True, "setting fire true did not stick"
    S.Sv_Set("fire", "false")
    assert S.Get("fire") is False, "setting fire false did not stick"
    S.Sv_Set("maxjoints", "42")
    assert S.Get("maxjoints") == 42, f"maxjoints is {S.Get('maxjoints')}"
    before = S.Get("maxjoints")
    S.Sv_Set("maxjoints", "banana")
    assert S.Get("maxjoints") == before, "a non-number was accepted for a number setting"
    okk, _msg = S.Sv_Set("noSuchSetting", "1"), None
    assert S.Get("noSuchSetting") is None, "an unknown key was stored"


def to_python(v):
    """Deep-copy a Lua table out to plain Python, so it can cross runtimes."""
    if lupa.lua_type(v) != "table":
        return v
    return {k: to_python(x) for k, x in v.items()}


def to_lua(lua, v):
    if not isinstance(v, dict):
        return v
    return lua.table_from({k: to_lua(lua, x) for k, x in v.items()})


def restart(lua, *files):
    """Shut the server down and start it again, keeping only what was on disk.

    This is the check that matters for anything persistent: not "was it written"
    but "does the next event see it".
    """
    saved = {k: to_python(v) for k, v in lua.globals()._files.items()}
    lua2 = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua2.execute(STUB)
    for f in files:
        lua2.execute(io.open(SCRIPTS / f, encoding="utf-8").read())
    for k, v in saved.items():
        lua2.globals()._files[k] = to_lua(lua2, v)
    return lua2


def settings_persist_across_a_reload():
    lua = fresh("Settings.lua")
    S = lua.globals().Settings
    S.Sv_Load(False)
    S.Sv_Set("maxbots", "7")
    S.Sv_Save()
    lua2 = restart(lua, "Settings.lua")
    S2 = lua2.globals().Settings
    S2.Sv_Load(False)
    assert S2.Get("maxbots") == 7, f"maxbots came back as {S2.Get('maxbots')} after a reload"


def presets_differ_in_the_direction_they_claim():
    lua = fresh("Settings.lua")
    S = lua.globals().Settings
    S.Sv_Load(False)
    S.Sv_ApplyPreset("sandbox")
    sandbox_fire = S.Get("fire")
    S.Sv_ApplyPreset("build")
    build_fire, build_plots = S.Get("fire"), S.Get("plots")
    S.Sv_ApplyPreset("lockdown")
    lock_build = S.Get("buildopen")
    assert sandbox_fire is True, "the sandbox preset should let fire exist"
    assert build_fire is False, "the build preset should not"
    assert build_plots is True, "the build preset should turn plots on"
    assert lock_build is False, "lockdown should close building"


def hazard_tools_bind_the_host_too():
    lua = fresh("Settings.lua")
    S = lua.globals().Settings
    S.Sv_Load(False)
    S.Sv_Set("claygun", "false")
    hazard = dict(S.Sv_HazardTools())
    assert any(v == "claygun" for v in hazard.values()), (
        "the clay gun is off but is not in the host-binding hazard list -- this is "
        "the bug reported as 'the clay gun still works' from the host")
    S.Sv_Set("claygun", "true")
    assert not any(v == "claygun" for v in dict(S.Sv_HazardTools()).values()), (
        "the clay gun is on but still listed as blocked")


def a_locked_world_takes_every_tool_off_a_guest_and_none_off_the_host():
    """REPORTED: "the lockdown shall block EVERYTHING" -- and, 2026-08-31, "I
    should be able to build and delete stuff anywhere. and place lift."

    Two halves that pull in opposite directions, and the split between them is
    the guest list and the host list.

    A GUEST loses everything. The original fault was that /lockdown wrote four
    settings false -- claygun, firelauncher, cornades, extinguisher -- and the
    LIFT was never among them, so a locked world still had creations being
    carried around in it. Deriving the set from the MODE fixed that and this
    still holds it.

    THE HOST LOSES NOTHING. V53 folded the lockdown into the hazard list too,
    which is the only list guarding the host (Game.sv_toolPayload sends
    `host = hazardTools`), so /lockdown disarmed the person who typed it. It
    broke the lift in particular, in exactly the way the_lift_is_never_a_hazard
    warns about: a hazard-listed tool is force-unequipped on your own client
    every tick.
    """
    lua = fresh("Settings.lua")
    S = lua.globals().Settings
    S.Sv_Load(False)

    def names(fn):
        got = getattr(S, fn)()
        return {str(v) for v in got.values()}

    # A tool that is switched ON and is nobody's hazard: the lift.
    S.Sv_SetQuiet("lift", True)
    S.Sv_SetQuiet("sledgehammer", True)
    S.Sv_SetQuiet("painttool", True)
    # ON, deliberately. The clay gun is a HAZARD, and a hazard the host switched
    # off still binds the host -- see hazard_tools_bind_the_host_too. Leaving it
    # at its default here would make this check pass for that reason instead of
    # the one it is about.
    S.Sv_SetQuiet("claygun", True)
    S.Sv_SetQuiet("protection", "open")
    assert "lift" not in names("Sv_BlockedTools"), (
        "the lift is blocked in an open world, which is not the point")
    assert "lift" not in names("Sv_HazardTools")

    for mode in ("locked", "display"):
        S.Sv_SetQuiet("protection", mode)
        guest, host = names("Sv_BlockedTools"), names("Sv_HazardTools")
        for tool in ("lift", "claygun", "sledgehammer", "painttool", "notlift"):
            assert tool in guest, f"{mode}: a guest can still hold the {tool}"
            assert tool not in host, (
                f"{mode}: the lockdown took the {tool} off THE HOST. The host is "
                "guarded by the hazard list alone, so anything a lockdown adds "
                "to it disarms the person running the event -- and for the lift "
                "it also kills the blueprint menu, because a tool being "
                "force-unequipped every tick cannot be handed a creation.")


def a_locked_world_still_lets_you_clear_litter():
    """The two tools that survive, and both are load-bearing.

    The cleaner is the only thing in the game that can remove a dropped
    craftbot -- a permission flag does not reach a carryable prop -- and the
    world stays locked BETWEEN events, so taking it away would make every piece
    of dropped rubbish permanent. That rule already cost three separate fixes.

    The focus marker survives because it changes nothing in the world; it draws
    on screens.
    """
    lua = fresh("Settings.lua")
    S = lua.globals().Settings
    S.Sv_Load(False)
    S.Sv_SetQuiet("protection", "locked")
    S.Sv_SetQuiet("cleaner", True)
    S.Sv_SetQuiet("focus", True)

    lockdown = {str(v) for v in S.Sv_LockdownTools().values()}
    assert lockdown, "a locked world blocks nothing at all"
    assert "cleaner" not in lockdown, (
        "a locked world takes the cleaner away, so dropped litter can never be "
        "removed -- and the world stays locked between events")
    assert "focus" not in lockdown, "a locked world takes the focus marker away"


def unlocking_gives_the_host_back_the_tools_they_chose():
    """The second half of the same bug, and the worse one.

    /lockdown used to write four settings false and /unlock never put them back,
    so a single lockdown disabled four tools permanently and the only way to
    notice was to find them missing later. Deriving the set from the mode means
    nothing is remembered, so nothing has to be restored.
    """
    lua = fresh("Settings.lua")
    S = lua.globals().Settings
    S.Sv_Load(False)
    S.Sv_SetQuiet("claygun", True)          # the host wants it on
    S.Sv_SetQuiet("lift", True)

    S.Sv_SetQuiet("protection", "locked")
    assert "claygun" in {str(v) for v in S.Sv_BlockedTools().values()}

    S.Sv_SetQuiet("protection", "open")
    assert S.Get("claygun") is True, (
        "locking the world changed the host's own claygun setting -- unlocking "
        "cannot put back what it does not know was changed")
    assert S.Get("lift") is True
    assert "claygun" not in {str(v) for v in S.Sv_BlockedTools().values()}, (
        "the world is open again and the clay gun is still blocked")


def the_host_can_build_where_they_stand_in_a_locked_world():
    """"I should be able to build and delete stuff anywhere. and place lift."
    -- the owner, 2026-08-31.

    Body flags are per-BODY. dev/dump_api.py lists 39 Body bindings and not one
    of them takes a player, so a lockdown that leaves the host able to build
    cannot be written as a flag -- the only lever is PRESENCE, which is what the
    plot system has always run on.

    Five things have to hold at once or the bubble is either useless or a hole:
    it follows the host, it stops well short of the city, another player
    standing in it shuts it, a player far away does not, and the switch works.
    """
    lua = fresh("Settings.lua", "Layout.lua", "Palette.lua", "Plots.lua")
    S, P = lua.globals().Settings, lua.globals().Plots
    S.Sv_Load(False)
    plots = lua.eval("Plots()")
    P.sv_onCreate(plots, lua.table_from({"grid": lua.table_from({}), "enabled": True}))

    person = lua.execute("""
        return function( x, y, z )
            local c = { worldPosition = { x = x, y = y, z = z } }
            function c:getCharacter() return c end
            function c:getName() return "somebody" end
            return c
        end
    """)
    body_at = lua.execute("""
        return function( x, y, z )
            local b = {}
            function b:getWorldAabb()
                return { x = x, y = y, z = z },
                       { x = x + 0.25, y = y + 0.25, z = z + 0.25 }
            end
            return b
        end
    """)
    host = person(0.0, 0.0, 0.0)
    lua.globals()._host = host

    near = body_at(1.0, 0.0, 0.0)
    far = body_at(50.0, 0.0, 0.0)

    lua.globals()._players = lua.table_from([host])
    P.sv_updateHostBubble(plots)

    # OFF BY DEFAULT, and this assertion is the one that matters most.
    #
    # V60 shipped it on, and REPORTED: "even on lock down. I still can build
    # everything and delete everything. and I mean the lockdown feature." Both
    # halves are true and they are the same fact -- the bubble follows the host,
    # so on a server with nobody else on it a lockdown is indistinguishable from
    # a lockdown that did nothing. The exemption has to be a deliberate press.
    # BOTH HALVES, because either alone passes while the other is broken.
    #
    # Sv_Load runs the migrations, and hostbuild_off_by_default_v62 writes false
    # -- so Get() would report false even with the SCHEMA default flipped back
    # to true. MEASURED: flipping the default and running this check passed,
    # which is the check proving the migration rather than the decision.
    #
    # The default is what a new host gets. The migration is what this owner
    # gets, because a changed default never reaches a key already in the file.
    row = next(r for r in S.SCHEMA.values() if r["key"] == "hostbuild")
    assert row["default"] is False, (
        "the host's bubble is on by DEFAULT again, so a host who has never "
        "played gets a lockdown they cannot tell from a broken one")
    assert any(str(m["key"]) == "hostbuild_off_by_default_v62"
               for m in S.MIGRATIONS.values()), (
        "the migration is gone, so the fix reaches a new host and not the one "
        "whose Settings.json already says true")
    assert S.Get("hostbuild") is False, (
        "the host's bubble is on after a load, so /lockdown cannot be told "
        "apart from a broken /lockdown from the only screen there is")
    assert P.sv_hostReaches(plots, near) is False, (
        "the bubble is open before anybody switched it on")

    S.Sv_SetQuiet("hostbuild", True)
    assert P.sv_hostReaches(plots, near) is True, (
        "the host cannot reach a body one metre away, so a lockdown leaves them "
        "unable to fix anything at all")
    assert P.sv_hostReaches(plots, far) is False, (
        "the bubble reaches 50 metres, which is not a bubble -- it unlocks the "
        "city and the lockdown stops meaning anything")

    # A guest inside it shuts it. Body flags are global: while the bubble is
    # open, its bodies are open to whoever else can reach them.
    lua.globals()._players = lua.table_from([host, person(1.0, 0.0, 0.0)])
    P.sv_updateHostBubble(plots)
    assert P.sv_hostReaches(plots, near) is False, (
        "somebody is standing inside the bubble and it is still open, which "
        "hands them the host's exemption")
    assert "standing in it" in str(P.sv_bubbleStatus(plots)), (
        "/protection does not say WHY the bubble is shut, so a host cannot tell "
        "it from a broken one")

    lua.globals()._players = lua.table_from([host, person(30.0, 0.0, 0.0)])
    P.sv_updateHostBubble(plots)
    assert P.sv_hostReaches(plots, near) is True, (
        "a player 30 metres away shuts the bubble, so at a real event the host "
        "would never have one")

    S.Sv_SetQuiet("hostbuild", False)
    assert P.sv_hostReaches(plots, near) is False, "hostbuild off, bubble still open"
    assert str(P.sv_bubbleStatus(plots)) == "off"
    S.Sv_SetQuiet("hostbuild", True)

    lua.globals()._host = None
    lua.globals()._players = lua.table_from([])
    P.sv_updateHostBubble(plots)
    assert P.sv_hostReaches(plots, near) is False, "a bubble with nobody in it"


def a_strict_lockdown_leaves_nothing_a_guest_can_touch():
    """"if the lock down is a proper lock down. like you cant interact like at
    all. then its good to go for testing" -- the owner, 2026-08-31.

    The last thing that was not: `sweep` is erasable = true, and it escaped a
    locked world on purpose. So litter on a road, on the plaza or anywhere
    outside the city stayed deletable by anybody's bare hands during a lockdown
    -- and bare hands are exactly what the tool guard cannot reach, because
    placing and removing are the build HAND rather than a uuid.

    The escape answers a real reported bug ("you need to fix the unremovable
    craft bots"): prep, the buffer, the end of an event and the gap between
    events all close building, and freezing the rubbish along with the builds is
    how spawn spam wins. So it survives `display`, and it does NOT survive
    `locked`. Both halves are asserted here, because keeping only the first
    would silently reintroduce the bug it was written for.
    """
    lua = fresh("Settings.lua", "Layout.lua", "Palette.lua", "Plots.lua",
                "Protection.lua")
    S, P, Prot = lua.globals().Settings, lua.globals().Plots, lua.globals().Protection
    S.Sv_Load(False)

    plots = lua.eval("Plots()")
    P.sv_onCreate(plots, lua.table_from({"grid": lua.table_from({}), "enabled": True}))
    plots["enabled"] = True
    lua.globals().g_swPlots = plots
    prot = lua.eval("Protection()")
    Prot.sv_onCreate(prot, "open")
    lua.globals().g_swProtection = prot
    Prot.sv_setResolver(prot, lua.execute("""
        return function( body )
            if g_swPlots:sv_isScenery( body ) and not Settings.CityIsOpen() then
                return "locked"
            end
            local zone = g_swPlots:sv_bodyIsOpen( body )
            if zone == "sweep" then return "sweep" end
            if Settings.Get( "buildopen" ) == false
                and not g_swProtection:sv_modeClosesBuilding() then
                return false
            end
            return zone
        end
    """))

    # A dropped craftbot far outside the city: Layout.locate finds no zone, so
    # the resolver calls it litter. Not on the plaza -- the plaza is scenery in
    # its own right and would have made this pass for the wrong reason.
    litter = lua.execute("""
        return function()
            local b = { worldPosition = { x = 900.0, y = 900.0, z = 1.5 } }
            function b:getShapes() return { { shapeUuid = "not-ours" } } end
            function b:getWorldAabb()
                return { x = 900.0, y = 900.0, z = 1.5 },
                       { x = 900.25, y = 900.25, z = 1.75 }
            end
            return b
        end
    """)()

    def profile(mode):
        Prot.sv_setMode(prot, mode)
        got = Prot.sv_profileForTest(prot, litter)
        return got[0] if isinstance(got, tuple) else got

    assert profile("open")["erasable"] is True, (
        "the fixture is not being seen as litter, so neither half below means "
        "anything")

    strict = profile("locked")
    for flag in ("buildable", "erasable", "connectable", "paintable",
                 "liftable", "usable", "destructable", "convertibleToDynamic"):
        assert strict[flag] is False, (
            f"/lockdown leaves litter {flag} -- a guest with no tools at all can "
            "still delete it by hand, because placing and removing are the build "
            "hand and not a uuid the tool guard can yank")

    show = profile("display")
    assert show["erasable"] is True, (
        "/lockdown display froze the rubbish with the builds, which is the "
        "unremovable-craftbot bug back again -- prep, the buffer and the gap "
        "between events all run through here")


def the_bubble_is_the_first_thing_the_resolver_asks():
    """Ahead of sv_isScenery, and that ordering is the feature.

    The plaza IS scenery and it is where everyone spawns, so a bubble that lost
    to the decking would do nothing at the first place anybody tried it -- and
    "nothing happens where I am standing" cannot be told apart from "this is
    broken". Same class as the panel that closed on every click.
    """
    world = read("World.lua")
    start = world.index("g_swProtection:sv_setResolver(")
    body = world[start:world.index("g_swRules = Rules()", start)]
    # COMMENTS OUT FIRST. The prose above each branch names the branch below it
    # and the branch it beats, so an index into the raw text finds the sentence
    # rather than the call -- which made this check fail on a correct resolver
    # the first time it ran. The rule is the same one that has bitten twice
    # already: ask what is in the corpus before searching it.
    body = chr(10).join(
        line for line in body.split(chr(10)) if not line.strip().startswith("--"))
    reaches = body.index("sv_hostReaches")
    assert reaches < body.index("sv_isScenery"), (
        "the resolver asks about the decking before it asks about the host, so "
        "the host cannot build on the plaza -- which is where they spawn")
    assert reaches < body.index("sv_bodyIsOpen"), (
        "the resolver asks the plot system first, so a locked plot beats the host")
    assert "WorldIsShut()" in body[:reaches], (
        "the bubble is consulted in an OPEN world too, which spends a "
        "getWorldAabb per body per patrol slice on an answer that cannot matter")


FIRE_LIMIT = 128        # FIRE_INSTANCE_LIMIT, as the STUB declares it


def a_shut_world_forces_the_hazards_off_without_writing_them():
    """"LOCK down EVERYTHING."

    Fire, explosion cratering and unit aggro are engine switches rather than
    permissions, so no body flag reaches them: a host who had fire on for an
    event still had a burning world after typing /lockdown.

    Derived from the MODE, which is the rule the tool guard learned the
    expensive way. V52's lockdown WROTE four settings false and /unlock could
    not put them back, so one lockdown disabled four tools for good. Nothing is
    remembered here, so nothing has to be restored.

    THIS CHECK RUNS THE APPLY FUNCTIONS, not Sv_HazardOff. The first version of
    it asserted Sv_HazardOff( Get( key ) ) and passed with the helper removed
    from every apply in the file -- proving only that the helper said what the
    helper said. That is the V34 polish-profile mistake exactly, and it was
    caught the way it always is: by putting the bug back and watching nothing
    fail.
    """
    lua = fresh("Settings.lua")
    S = lua.globals().Settings
    S.Sv_Load(False)

    # Aggro reaches the engine rather than a global, so catch the call.
    lua.execute("""
        _aggro = nil
        sm.game.setEnableAggro = function( v ) _aggro = v end
        _fireLimit = nil
        sm.fire.setFireLimit = function( n ) _fireLimit = n end
    """)

    def applied():
        S.Sv_ApplyHazards()
        g = lua.globals()
        return {
            "fire": g.g_swFireEnabled,
            "terraindamage": not g.g_swProtectTerrain,
            "aggro": g._aggro,
            "firelimit": g._fireLimit,
        }

    for key in ("fire", "terraindamage", "aggro"):
        S.Sv_SetQuiet(key, True)

    got = applied()
    for key in ("fire", "terraindamage", "aggro"):
        assert got[key] is True, f"{key} is off in an open world the host opened"
    assert got["firelimit"] == FIRE_LIMIT, "fire is on and the limit is still zero"

    S.Sv_SetQuiet("protection", "locked")
    got = applied()
    for key in ("fire", "terraindamage", "aggro"):
        assert got[key] is False, (
            f"the world is shut and {key} is still on -- a lockdown that only "
            "walks bodies never reaches it, because it is not a permission")
        assert S.Get(key) is True, (
            f"locking the world WROTE {key} false. That is the V52 bug: /unlock "
            "cannot put back what it does not know was changed, so a single "
            "lockdown would disable it for good.")
    assert got["firelimit"] == 0, "the world is shut and fire still has a budget"

    S.Sv_SetQuiet("protection", "open")
    got = applied()
    for key in ("fire", "terraindamage", "aggro"):
        assert got[key] is True, f"unlocking did not give {key} back"


def every_protection_write_re_applies_the_derived_hazards():
    """A derived value that nothing re-applies is a value that never changed.

    Six places write the protection mode -- /lockdown, /unlock, the grief alarm
    twice, the event clock and the new-world reset. Hooking the write itself is
    the only version of this that cannot be forgotten at a seventh.
    """
    src = read("Settings.lua")
    setter = src[src.index("function Settings.Sv_SetQuiet"):]
    setter = setter[:setter.index(chr(10) + "end")]
    assert "Sv_ApplyHazards" in setter, (
        "Sv_SetQuiet no longer re-applies the derived hazards, so /lockdown "
        "leaves fire and aggro exactly as they were")

    writes = read("World.lua").count('Sv_SetQuiet( "protection"')
    writes += read("Game.lua").count('Sv_SetQuiet( "protection"')
    assert writes >= 4, (
        f"only {writes} places write the protection mode -- if that really "
        "dropped, check the hook is still what carries all of them")


def both_files_agree_on_what_locked_means():
    """Protection short-circuits its resolver on a locked mode, and the tool
    guard blocks nearly everything on one. Two files, one question -- and they
    used to answer it separately, which is exactly how a mode gets added to one
    and not the other."""
    src = read("Protection.lua")
    body = src[src.index("local function isLockedMode"):]
    body = body[:body.index(chr(10) + "end")]
    assert "Settings.LOCKED_MODES" in body, (
        "Protection decides on its own what a locked mode is, so the tool guard "
        "and the resolver can disagree")

    lua = fresh("Settings.lua")
    modes = {str(k) for k in lua.globals().Settings.LOCKED_MODES.keys()}
    assert modes == {"locked", "display"}, modes


def every_mode_change_tells_the_clients():
    """The guard is client side -- only your own client can put a tool away --
    so a client holding a stale list is a lockdown that did not happen.

    The announcement used to be skipped for mode == "open", which meant
    UNLOCKING left every client still holding the locked list.
    """
    world = read("World.lua")
    start = world.index('if cmd == "/lockdown" or cmd == "/unlock" then')
    body = world[start:start + 3000]
    assert "sv_e_swToolsChanged" in body, "a mode change tells nobody"
    announce = body.index("sv_e_swToolsChanged")
    guard = body.find('if mode ~= "open" then')
    assert guard == -1 or guard > announce, (
        "the tools-changed announcement is still behind an `if mode ~= open`, "
        "so unlocking leaves every client holding the locked list")


def the_lift_is_never_a_hazard():
    # The lift is HOST_ONLY, not HAZARD. If it ever lands in the hazard list the
    # host's own client force-unequips it every tick and the creations menu
    # cannot hand it a blueprint -- which is exactly the shape of the reported
    # "I cant use the lift to spawn creations".
    lua = fresh("Settings.lua")
    S = lua.globals().Settings
    S.Sv_Load(False)
    for value in ("true", "false"):
        S.Sv_Set("lift", value)
        S.Sv_Set("hostlift", value)
        assert not any(v == "lift" for v in dict(S.Sv_HazardTools()).values()), (
            f"the lift is in the hazard list with lift={value} hostlift={value}")


# ---------------------------------------------------------------- identity ---

def banned(I, player):
    """Sv_IsBanned returns ( bool, entry ) -- only the verdict matters here."""
    r = I.Sv_IsBanned(player)
    return (r[0] if isinstance(r, tuple) else r) is True


def a_backup_captures_everything_and_can_be_put_back():
    """A snapshot round trip: capture the world, list it, restore it.

    "and also backups. the whole save backups. we need to make sure they work
    too." They are the other half of the anti-grief -- if damage cannot be
    prevented, it has to be reversible.

    This exercises the real Snapshots object: the capture job, the index, the
    file it writes, and the restore reading it back. What it cannot prove is
    sm.creation.exportToString / importFromString, which are the engine's.
    """
    # Protection.lua for isGhostBody -- Snapshots leans on it to keep a
    # blueprint somebody is holding on a lift out of the saved world.
    lua = fresh("Layout.lua", "Settings.lua", "Protection.lua", "Snapshots.lua")
    S = lua.globals().Snapshots
    snaps = lua.eval("Snapshots()")
    S.sv_onCreate(snaps)

    # three creations, two of them on plots
    world = lua.table_from({})
    # `function t[i]:m()` is not Lua -- the name after `function` may not be an
    # index expression. Assign the field instead.
    lua.execute("""
        swTestBodies = {}
        madeBodies = swTestBodies
        for i = 1, 3 do
            madeBodies[i] = { id = i }
            madeBodies[i].getShapeCount = function( self ) return 10 end
        end
        zoneOfBody = function( body ) return body.id <= 2 and body.id or nil end
    """)
    zone_of = lua.globals().zoneOfBody

    stamped = S.Name("manual")
    assert stamped and "manual-" in str(stamped), (
        f"a snapshot name is not stamped with a date: {stamped!r}")

    ok, detail = S.sv_beginCapture(snaps, "unittest", world, zone_of)
    assert ok, f"the capture would not start: {detail}"

    # drive the job to completion the way the world tick does
    for _ in range(2000):
        done = S.sv_onFixedUpdate(snaps)
        if done:
            break
    assert snaps["job"] is None, "the capture job never finished"

    names = S.sv_names(snaps)
    listed = [str(n) for n in names.values()]
    assert any("unittest" in n for n in listed), (
        f"the snapshot is not in the list afterwards: {listed}")


def a_restore_waits_for_the_old_world_to_be_torn_down():
    """MEASURED IN GAME, 2026-08-29, and this is the check written from it.

    A restore of a 96-plot city reported "195 creations, 0 failed" and came back
    with a hole where the plaza had been. REPORTED, with a screenshot: "the load
    back in WORKS! the issue is the middle doesnt".

    The middle is the plaza, and the plaza is the FIRST entry in the snapshot.
    sv_beginRestore cleared the world and the driver stepped on the very next
    tick, four creations at a time -- so the first four were handed to the
    importer while the old shapes were still standing in that space.
    shape:destroyShape() does not take effect until the end of a tick, and
    importFromString reports success either way, which is why "0 failed" and a
    hole in the ground were not a contradiction.

    The city builder already knew this -- World.CITY_SETTLE_TICKS, with a
    comment describing the same symptom. The fix had never travelled to the
    other place that clears and rebuilds, because restore had never been run.
    """
    lua = fresh("Layout.lua", "Settings.lua", "Protection.lua", "Snapshots.lua")
    S = lua.globals().Snapshots
    snaps = lua.eval("Snapshots()")
    S.sv_onCreate(snaps)

    lua.execute("""
        _tick = 1000
        _imports = 0
        sm.creation.importFromString = function( ... )
            _imports = _imports + 1
            return {}
        end
        _cleared = 0
        clearWorld = function() _cleared = _cleared + 1 end
        swTestBodies = {}
        for i = 1, 6 do
            swTestBodies[i] = { id = i }
            swTestBodies[i].getShapeCount = function( self ) return 10 end
        end
        zoneOfBody = function( body ) return nil end
    """)
    world = lua.table_from({})

    ok, detail = S.sv_beginCapture(snaps, "settletest", world, lua.globals().zoneOfBody)
    assert ok, f"the capture would not start: {detail}"
    for _ in range(2000):
        if S.sv_onFixedUpdate(snaps):
            break
    assert snaps["job"] is None, "the capture never finished"

    ok, detail = S.sv_beginRestore(snaps, "settletest", world,
                                   lua.table_from({"clear": lua.globals().clearWorld}))
    assert ok, f"the restore would not start: {detail}"
    assert int(lua.globals()._cleared) == 1, "the restore did not clear first"

    # The old shapes are still standing. Nothing may be imported yet, however
    # many times the world ticks -- this is the whole fix.
    for _ in range(10):
        S.sv_onFixedUpdate(snaps)
    assert int(lua.globals()._imports) == 0, (
        f"{int(lua.globals()._imports)} creation(s) were imported into space the "
        "old world still occupies. The first ones in are lost silently, which is "
        "the plaza-shaped hole of 2026-08-29.")

    settle = int(S.SETTLE_TICKS)
    assert settle >= 20, f"the settle is only {settle} ticks"

    # ...and once the engine has had its tick, everything goes back.
    lua.execute(f"_tick = _tick + {settle + 1}")
    for _ in range(2000):
        if S.sv_onFixedUpdate(snaps):
            break
    assert snaps["job"] is None, "the restore never finished"
    assert int(lua.globals()._imports) == 6, (
        f"restored {int(lua.globals()._imports)} of 6 creations")

    # The same hazard, the same number, in the other file that clears and
    # rebuilds. They were allowed to drift once and it cost the plaza.
    world_src = read("World.lua")
    m = re.search(r"World\.CITY_SETTLE_TICKS = (\d+)", world_src)
    assert m, "World.CITY_SETTLE_TICKS is gone -- the city builder lost its wait"
    assert settle >= int(m.group(1)), (
        f"restore waits {settle} ticks and the city builder waits {m.group(1)}. "
        "They are the same hazard; the shorter one is the bug.")


def a_ban_reaches_the_engine_not_just_our_list():
    """Every ban path calls sm.game.banPlayer, not just kickPlayer.

    Banning is now load-bearing: "we need to make sure banning works. cause its
    the only way." It is the only way because build permission is per-BODY and
    cannot be aimed at a person -- so removing the person IS the enforcement.

    And our own list is keyed on the DISPLAY NAME, because Lua is handed no
    stable player id at all. The Player binding list has `id` -- a session slot
    that shifts -- and `name`, and nothing else. A rename walks straight around
    a name-keyed ban.

    sm.game.banPlayer is the engine's own ban and is the one part a rename
    cannot dodge, so every route that decides somebody is banned has to reach
    it. Ours is the record and the offline check; the engine's is the teeth.
    """
    game = io.open(SCRIPTS / "Game.lua", encoding="utf-8").read()
    assert "sm.game.banPlayer" in game, "nothing ever calls the engine's ban"

    # the queue that enforces a ban at join time must be able to ban, not only kick
    flush = game[game.index("function Game.sv_flushKicks"):]
    flush = flush[:flush.index(chr(10) + "end")]
    assert "sm.game.banPlayer" in flush and "sm.game.kickPlayer" in flush, (
        "sv_flushKicks can only kick -- somebody banned while offline would be "
        "removed by us on every join instead of by the engine once")

    # every queue insert says which it is
    import re
    inserts = re.findall(r"insert\( self\.sv\.kickQueue, ([^)]*)\)", game)
    assert inserts, "the kick queue is never filled"
    for site in inserts:
        assert "ban =" in site, (
            f"a kick-queue entry does not say whether it is a ban: {site.strip()!r}")

    # and the host can never be removed by our own code
    assert "getHostPlayer()" in game, "nothing guards the host"

def bans_survive_a_restart():
    lua = fresh("Identity.lua")
    I = lua.globals().Identity
    I.Sv_Load()
    p = lua.eval('{ name = "June Carya", id = 3 }')
    rec = I.Sv_Touch(p)
    perma = rec["perma"]
    assert perma, "no permanent id was assigned"
    I.Sv_Ban(perma, "griefing")
    assert banned(I, p), "a banned player is not reported as banned"

    lua2 = restart(lua, "Identity.lua")
    I2 = lua2.globals().Identity
    I2.Sv_Load()
    p2 = lua2.eval('{ name = "June Carya", id = 9 }')
    assert banned(I2, p2), (
        "the ban did not survive a reload -- the whole point of the ban list is "
        "that it carries between events")


def a_rename_keeps_the_permanent_id():
    lua = fresh("Identity.lua")
    I = lua.globals().Identity
    I.Sv_Load()
    a = I.Sv_Touch(lua.eval('{ name = "Someone", id = 1 }'))
    perma = a["perma"]
    b = I.Sv_Touch(lua.eval('{ name = "Someone", id = 1 }'))
    assert b["perma"] == perma, "the same name got two different permanent ids"


def unban_actually_unbans():
    lua = fresh("Identity.lua")
    I = lua.globals().Identity
    I.Sv_Load()
    p = lua.eval('{ name = "Tester", id = 1 }')
    rec = I.Sv_Touch(p)
    I.Sv_Ban(rec["perma"], "test")
    assert banned(I, p), "the ban did not take"
    I.Sv_Unban(rec["perma"])
    assert not banned(I, p), "unban did not lift the ban"


# ------------------------------------------------------------- protection ---

def the_sentinel_tells_every_profile_apart():
    # V15: the sentinel compared only buildable and destructable, which locked,
    # display and sweep all share -- so switching between them found every body
    # "already correct" and applied nothing. Reported as "I can still press
    # buttons on lockdown". This enumerates the table rather than trusting it.
    lua = fresh("Settings.lua", "Protection.lua")
    src = io.open(SCRIPTS / "Protection.lua", encoding="utf-8").read()
    # PROFILES is a local, so read the four sentinel fields straight out of the
    # source table by re-declaring it in Lua exactly as written.
    body = src[src.index("local PROFILES = {"):src.index("Protection.MODES")]
    lua.execute(body.replace("local PROFILES", "PROFILES", 1))
    profiles = lua.globals().PROFILES

    # Read the sentinel's OWN field list out of matchesProfile rather than
    # restating it here. A test that keeps its own copy of the list is a test
    # that stops matching the code -- which is how the polish profile came
    # within one commit of being silently inert.
    import re
    fn = src[src.index("local function matchesProfile"):]
    fn = fn[:fn.index("\nend")]
    fields = re.findall(r"== p\.(\w+)", fn)
    assert len(fields) >= 4, f"could not read the sentinel's fields: {fields}"

    # THE RULE IS PAIRWISE, NOT "every name is unique", and the difference
    # arrived with the host bubble.
    #
    # `hostopen` carries `open`'s flags exactly. It is a deliberate alias: the
    # only thing it changes is that it stays OUT of GROUND_FREE, so a plot slab
    # inside the bubble gets the pinned twin and cannot be carried away during a
    # lockdown. Two names with identical flags are not a bug -- there is nothing
    # to switch. Two names that differ in a flag the sentinel cannot see is the
    # bug, and it is the V15 one.
    #
    # So this compares the profiles a body can actually RECEIVE, which means the
    # pinned twins as well, and demands the sentinel separate any two of them
    # that are not the same profile.
    apply_fn = src[src.index("local function applyProfile"):]
    apply_fn = apply_fn[:apply_fn.index(chr(10) + "end")]
    all_flags = list(dict.fromkeys(re.findall(r"p\.(\w+)", apply_fn)))
    assert len(all_flags) == 8, f"applyProfile sets {all_flags}, expected all eight"

    ground_free = set(re.findall(
        r"(\w+) = true",
        src[src.index("local GROUND_FREE = {"):src.index("-- Which trim profile")]))
    assert "open" in ground_free and "hostopen" not in ground_free, (
        "the host bubble is in GROUND_FREE, so a plot slab is liftable during a "
        "lockdown -- which is the one thing pinning exists to stop")

    effective = {}
    for name in profiles:
        flags = {f: profiles[name][f] for f in all_flags}
        effective[name] = flags
        # The pin only reaches a profile the ground test is allowed to twin.
        if name not in ground_free:
            twin = dict(flags)
            twin["liftable"] = False
            twin["convertibleToDynamic"] = False
            effective[name + " on city floor"] = twin

    names = sorted(effective)
    for i, a in enumerate(names):
        for b in names[i + 1:]:
            if effective[a] == effective[b]:
                continue        # same profile under two names: nothing to switch
            key_a = tuple(effective[a][f] for f in fields)
            key_b = tuple(effective[b][f] for f in fields)
            assert key_a != key_b, (
                f"profiles {a!r} and {b!r} differ, but are indistinguishable to "
                f"the sentinel {dict(zip(fields, key_a))} -- switching between "
                "them would silently do nothing, because matchesProfile would "
                "find every body already correct")
    assert len(effective) >= 14, (
        f"only {len(effective)} profiles a body can receive -- ten in the table "
        "plus a pinned twin for each of the six the ground test can reach")


def the_city_is_many_separate_bodies():
    """Nothing in the city spans the footprint, and no piece welds to another.

    THE correction that undoes V32:

      "the things NEED to be separated from the main city! in the original event
       they were separated with wedges so updating one block wont update whole
       city. but just the block! the block between the panels NEEDS to be
       detached. and each panel shall have its own stand!"

    A body is the unit the engine rebuilds. Weld the city into one and every
    block anybody places anywhere costs a rebuild of all of it -- at an event
    with twenty people building at once, which is goal 1 of this project.

    So: one creation per street, one for the plaza, one per plot, and nothing
    that covers the whole city.
    """
    lua, plots = plots_lua({"cols": 6, "rows": 6, "plazacells": 2})
    P = lua.globals().Plots
    grid = plots["layout"]

    pieces = P.sv_deckBlueprints(plots)
    assert pieces is not None, "sv_deckBlueprints returned nothing"
    pieces = list(pieces.values())
    assert len(pieces) > 1, (
        f"the shared ground came back as {len(pieces)} creation(s) -- the streets "
        "must be separate bodies, not one welded deck")

    labels = [str(p["label"]) for p in pieces]
    assert labels[0] == "plaza", (
        f"the plaza should be built first, got {labels[0]!r}")

    width, height = int(grid["width"]), int(grid["height"])
    for piece in pieces:
        bodies = list(piece["bp"]["bodies"].values())
        assert len(bodies) == 1, "a shared-ground piece is more than one body"
        for c in bodies[0]["childs"].values():
            b = c["bounds"]
            assert not (int(b["x"]) >= width and int(b["y"]) >= height), (
                f"a {piece['label']} piece spans the whole {width}x{height} city "
                "-- that is the base slab back again, and it welds everything "
                "into one rebuild unit")

    # the plaza carries its own stand, like every panel does
    plaza = list(pieces[0]["bp"]["bodies"].values())[0]["childs"].values()
    assert any(int(c["pos"]["z"]) == 0 for c in plaza), (
        "the plaza has no stand reaching the ground")


def a_plot_is_one_welded_body_with_its_own_stand():
    """A plot is one body: metal ring, concrete pad, and a stand under it.

    MEASURED from a reference creation the owner built and saved in game --
    "concrete panel with metal all around it", Blueprints/038852d7 -- which came
    back as ONE body whose childs array holds concrete and metal 2 side by side.
    One body's childs array IS the weld group.

    And the stand is there because separation is the DESIGN, not a defect:

      "the things NEED to be separated from the main city! in the original event
       they were separated with wedges so updating one block wont update whole
       city... each panel shall have its own stand!"

    A body is the unit the engine rebuilds, so a panel standing on its own column
    means one person placing a block never reprocesses anybody else's plot.

    This rasterises in THREE dimensions. The first version of this check worked
    in 2D and reported the stand as an overlap with the pad above it.
    """
    lua, plots = plots_lua()
    P = lua.globals().Plots
    CONCRETE, METAL2, METAL3 = str(P.CONCRETE), str(P.METAL2), str(P.METAL3)
    DECK_Z, border = int(P.DECK_Z), int(P.BORDER)
    L = lua.globals().Layout

    for col, row in [(0, 0), (3, 7), (9, 9), (2, 4)]:
        r = L.plotRect(plots["layout"], col, row)
        if r is None:
            continue
        bp = P.sv_plotBlueprint(plots, col, row)
        assert bp is not None, f"plot {col},{row} produced no blueprint"

        bodies = list(bp["bodies"].values())
        assert len(bodies) == 1, (
            f"plot {col},{row} is {len(bodies)} bodies. Separate bodies do not "
            "weld, however perfectly they line up")
        childs = list(bodies[0]["childs"].values())

        cells = {}
        for c in childs:
            b, pos = c["bounds"], c["pos"]
            for dx in range(int(b["x"])):
                for dy in range(int(b["y"])):
                    for dz in range(int(b["z"])):
                        k = (int(pos["x"]) + dx, int(pos["y"]) + dy,
                             int(pos["z"]) + dz)
                        assert k not in cells, (
                            f"plot {col},{row}: block {k} is claimed twice -- two "
                            "shapes in one block is how an import loses one")
                        cells[k] = str(c["shapeId"])

        x0, y0 = int(r["x"]), int(r["y"])
        w, h = int(r["w"]), int(r["h"])

        # the top layer is the panel: a metal ring round a concrete pad
        top = {(x, y): m for (x, y, z), m in cells.items() if z == DECK_Z}
        assert len(top) == w * h, (
            f"plot {col},{row}: the deck layer covers {len(top)} blocks of {w*h}")
        for (bx, by), mat in top.items():
            edge = (bx < x0 + border or bx >= x0 + w - border
                    or by < y0 + border or by >= y0 + h - border)
            want = METAL2 if edge else CONCRETE
            assert mat == want, (
                f"plot {col},{row}: block ({bx},{by}) on the deck layer is the "
                "wrong material")

        # and there is a stand under it, reaching the ground
        below = {(x, y, z): m for (x, y, z), m in cells.items() if z < DECK_Z}
        assert below, f"plot {col},{row} has no stand -- it would be floating"
        assert all(m == METAL3 for m in below.values()), (
            f"plot {col},{row}: the stand is not metal 3")
        assert min(z for (_, _, z) in below) == 0, (
            f"plot {col},{row}: the stand does not reach the ground")
        assert max(z for (_, _, z) in below) == DECK_Z - 1, (
            f"plot {col},{row}: the stand does not reach the underside of the pad")
        # centred, and inside the plot
        sxs = [x for (x, _, _) in below]
        sys_ = [y for (_, y, _) in below]
        assert min(sxs) >= x0 and max(sxs) < x0 + w, "the stand pokes out sideways"
        assert min(sys_) >= y0 and max(sys_) < y0 + h, "the stand pokes out sideways"


def the_lift_is_host_only_and_notlift_is_not():
    """Both the lift and NOTlift are gated to the host.

    THIS CHECK REPLACES ITS OWN OPPOSITE, and the reason is worth keeping.

    V51 asserted that NO lift uuid was in the tool gate. That was right at the
    time: the lift had been reported broken for a dozen versions, the gate was
    the one suspect we owned, and taking it out settled the question instead of
    arguing it. It settled it -- the gate was never the cause. The cause was
    engine-side content (see NotLift.lua).

    The ask then changed, once importing existed somewhere else:

        "make a NOT lift and make the menu of it opened via it and limit the
         lift to the host"

    So the invariant flips. The first version of THIS check then had NOTlift
    deliberately ungated, on the reasoning that guests needed some route to
    importing. The owner overruled it -- "the NOT lift shall only be host only.
    its too powerful" -- and that is the right call: importing is the only action
    in the mod that creates a whole build out of nothing, which is a bigger lever
    than deleting what you point at or moving what already exists.

    So both halves are now host-gated, and the check asserts both, because a gate
    that exists in the TOOLS table but not in HOST_ONLY silently does nothing.
    """
    src = io.open(SCRIPTS / "Settings.lua", encoding="utf-8").read()
    gate = src[src.index("local TOOLS = {"):src.index("Settings.SCHEMA = {")]

    # ONE lift. The creative lift and the Import Lift were both added by this mod
    # and both removed once NOTlift took over importing: 5cc12f03 was a second,
    # identical copy of a tool survival content already provides, and 4c893da9
    # was a workaround for a menu that no lift in this game opens. What is left
    # is survival's, which is base content and cannot be removed.
    assert "8f190ce2-3a59-423e-8483-a7aa67bd5bc0" in gate, (
        "the lift is not in the tool gate, so `hostlift` cannot reach it and the "
        "lift is open to every guest")
    for gone, why in (
            ("5cc12f03-275e-4c8e-b013-79fc0f913e1b", "the creative lift"),
            ("4c893da9-484d-495b-a013-87beed81c148", "the Import Lift")):
        assert gone not in gate, (
            f"{why} is back in the tool gate. It is not in the toolset any more, "
            "so gating it does nothing except make check_uuids fail")

    hostonly = src[src.index("local HOST_ONLY"):src.index("local TOOLS")]
    assert 'lift    = "hostlift"' in hostonly or 'lift = "hostlift"' in hostonly, (
        "the lift is not under HOST_ONLY, so nothing makes it host only")
    for live in ('key = "lift"', 'key = "hostlift"'):
        assert live in src, f'the {live} setting is missing, so the gate has no switch'

    # NOTLIFT IS HOST ONLY TOO. "the NOT lift shall only be host only. its too
    # powerful." It is the one action in the mod that creates a whole build from
    # nothing, which is a bigger single lever than deleting what you point at or
    # moving what already exists.
    assert 'notlift = "hostnotlift"' in hostonly, (
        "NOTlift is not under HOST_ONLY, so any guest can spawn whole creations")
    assert 'key = "hostnotlift"' in src, "hostnotlift has no switch"

    # A CHANGED DEFAULT REACHES NOBODY WHO HAS ALREADY PLAYED. `hostlift = false`
    # is written into every existing Settings.json by lift_free_v34, and a
    # default only applies to a key that is absent -- so without a migration this
    # whole change would do nothing on the one machine that matters.
    assert "lift_host_only_v55" in src, (
        "no migration flips the saved hostlift value, so lift_free_v34's "
        "`hostlift = false` still wins on any server that has been run once")
    mig = src[src.index("Settings.MIGRATIONS = {"):]
    v55 = mig[mig.index("lift_host_only_v55"):]
    v55 = v55[:v55.index("end }")]
    assert "values.hostlift = true" in v55, (
        "the migration does not actually set hostlift")

    # the cleaner, which DOES delete things, stays gated
    assert 'key = "hostcleaner"' in src, "the cleaner lost its host gate"


def the_notlift_import_chain_is_wired_end_to_end():
    """Every hop from a NOTlift click to an imported creation has a receiver.

    The chain is five hops long, and it is long ON PURPOSE: the browser callback
    is only PROVEN to land on a Game script (measured, /bptest2), so the tool
    routes through the Game script rather than opening the browser itself.

        NotLift.client_onEquippedUpdate  -> sv_n_swOpenImport   (NotLift)
        NotLift.sv_n_swOpenImport        -> sv_e_swOpenImport   (Game)
        Game.sv_e_swOpenImport           -> client_openImport   (Game)
        Game.cl_onNotLiftPick            -> sv_n_swImport       (Game)
        Game.sv_n_swImport               -> sv_e_swImportCreation (World)

    A name that exists on one side of a hop and nowhere on the other is always a
    bug, and it is exactly the bug that made CLEAR CITY a dead button for three
    versions -- the panel sent /citycensus and World.lua had no branch for it.
    """
    tool = io.open(SCRIPTS / "NotLift.lua", encoding="utf-8").read()
    game = io.open(SCRIPTS / "Game.lua", encoding="utf-8").read()
    world = io.open(SCRIPTS / "World.lua", encoding="utf-8").read()

    # THE "( self" IS LOad-BEARING. Without it these are prefix matches, and
    # renaming sv_e_swOpenImport to sv_e_swOpenImportRENAMED still contains
    # "function Game.sv_e_swOpenImport" -- so the check passed a deliberately
    # broken chain when it was first written. Caught by breaking it on purpose,
    # which is the only way to find out whether a check can fail at all.
    hops = [
        (tool, 'sendToServer( "sv_n_swOpenImport"', tool, "function NotLift.sv_n_swOpenImport( self"),
        (tool, '"sv_e_swOpenImport"', game, "function Game.sv_e_swOpenImport( self"),
        (game, '"client_openImport"', game, "function Game.client_openImport( self"),
        (game, '"cl_onNotLiftPick"', game, "function Game.cl_onNotLiftPick( self"),
        (game, 'sendToServer( "sv_n_swImport"', game, "function Game.sv_n_swImport( self"),
        (game, '"sv_e_swImportCreation"', world, "function World.sv_e_swImportCreation( self"),
    ]
    for src, sends, dst, receiver in hops:
        assert sends in src, f"nothing sends {sends}"
        assert receiver in dst, (
            f"{sends} is sent but {receiver} does not exist -- that hop goes nowhere")

    # The error callback too: setGarageErrorCallback names a handler and a name
    # the engine cannot resolve is a silent dead end.
    assert '"cl_onNotLiftError"' in game and "function Game.cl_onNotLiftError( self" in game

    # THE PICK HANDLER MUST NOT TOUCH A GUI. The browser widget is alive and this
    # callback is on its stack. Closing or redrawing from inside a callback is
    # the single bug that accounted for every "the buttons dont work" report in
    # this project, and with a focused widget it crashed the game outright.
    pick = game[game.index("function Game.cl_onNotLiftPick"):]
    pick = pick[:pick.index(chr(10) + "function ")]
    for forbidden in ("cl_showPanel", "cl_closeMenu", ":close()", "openGarageImportGui",
                      "cl_renderLater", ":render("):
        assert forbidden not in pick, (
            f"cl_onNotLiftPick calls {forbidden} from inside a live GUI callback")


def importing_a_creation_enforces_the_rules():
    """NOTlift places onto your OWN plot, only while building is open, capped.

    Without all three this is a griefing tool, and a better one than anything the
    mod already defends against: drop a 40,000-part creation onto somebody else's
    plot in a locked world. The browser in the probe was showing exactly such a
    blueprint, so the number is not hypothetical.
    """
    world = io.open(SCRIPTS / "World.lua", encoding="utf-8").read()
    body = world[world.index("function World.sv_e_swImportCreation"):]
    body = body[:body.index(chr(10) + "function ")]

    # 0. HOST ONLY, ON THE SERVER. The tool gate pulls it out of a guest's hands
    #    in a couple of ticks; that is fast, not impossible, and this is the only
    #    action in the mod that creates a build from nothing.
    assert '"hostnotlift"' in body and "getHostPlayer()" in body, (
        "importing is not host-checked server-side -- the tool gate alone is a "
        "race, not a rule")
    assert "local hostOnly = true" in body, (
        "the host check does not fail safe: if the setting cannot be read it must "
        "stay host only, not fall open")

    # 1. building has to be open -- the same test the client's canBuild uses, so
    #    the HUD and the import cannot disagree
    assert 'Settings.Get( "buildopen" )' in body and "sv_getMode()" in body, (
        "importing does not check that building is open, so a locked world would "
        "still accept whole creations -- the biggest hole the freeze could have")

    # 2. onto the plot you are standing on, tidily centred, rather than wherever
    #    the character happens to be. (Own-plot was the GUEST rule; with the host
    #    gate it would have blocked the host, who owns no plot.)
    assert "sv_locate" in body and "sv_plotWorldCentre" in body, (
        "importing does not centre onto the plot the caller is standing on")

    # 3. a size cap
    assert 'Settings.Get( "maximportparts" )' in body, (
        "importing has no part cap, so one blueprint can sink the server")
    assert "destroyCreation" in body, (
        "there is no fallback that removes an over-cap creation the server could "
        "not measure before importing")

    settings = io.open(SCRIPTS / "Settings.lua", encoding="utf-8").read()
    assert 'key = "maximportparts"' in settings, "maximportparts is not a setting"


def lua_code(text):
    """Lua with comments removed, for checks that must match CODE not prose.

    These scripts are far more comment than code, and every string-matching
    check here is one well-meaning paragraph away from passing for the wrong
    reason. That is not hypothetical: the check below asserted a fallback call
    existed, the fallback was deleted, and the check kept passing because the
    comment explaining WHY it was deleted still contained the function name.
    """
    out, i, n = [], 0, len(text)
    while i < n:
        if text.startswith("--[[", i):
            end = text.find("]]", i)
            i = n if end < 0 else end + 2
        elif text.startswith("--", i):
            end = text.find(chr(10), i)
            i = n if end < 0 else end
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def an_imported_creation_lands_on_a_lift():
    """Import makes STATIC bodies; a lift is what lets one become a build again.

    REPORTED: "the lift spawns the creation welded to air. so I have to unweld
    every block by breaking it which you know doesnt work."

    That is not a bug in the import, it is a missing step. The engine's own
    assert behind placeLift says what an imported body is:

        "The body needs to be static, aligned and not already on a lift."

    Static, with nothing under it, IS a creation welded to air -- and nothing in
    wrap_Body.cpp converts one. There is setConvertibleToDynamic (a permission)
    and isDynamic (a question), and no verb. What actually converts a creation is
    coming OFF a lift, which is exactly what vanilla's own import does and what
    ours was skipping.

    Three things have to hold, and each was a way to arrive back at a static
    creation by a different route:
    """
    world = io.open(SCRIPTS / "World.lua", encoding="utf-8").read()
    body = world[world.index("function World.sv_e_swImportCreation"):]
    body = body[:body.index(chr(10) + "function ")]
    code = lua_code(body)

    # 1. it is actually put on a lift
    assert "sm.lift.createNonPlayerLift" in code, (
        "nothing puts the imported creation on a lift, so it stays static -- "
        "welded to air, with no Lua binding that can free it")

    # 2. the position is SNAPPED. placeLift refuses a misaligned body, and the
    #    non-plot branch imports at character.worldPosition, an arbitrary float.
    assert "pos = liftPos * 0.25" in code, (
        "the import position is not snapped to the lift grid, so placeLift will "
        "refuse a body imported at a character's raw world position")

    # 3. a failure is REPORTED. Silently falling back to the old behaviour is
    #    how this went unnoticed the first time.
    assert "liftOk" in body and "WARNING" in body, (
        "a failed placeLift is not reported, so the broken case looks identical "
        "to the working one")

    # 4. THE RESULT IS ASKED FOR, NOT ASSUMED. The first fix logged lift=true and
    #    the creation was still static, because sm.player.placeLift returns
    #    nothing -- the pcall only ever proved no Lua error was raised. The body
    #    itself is the only thing that can settle it.
    # ...but NOT by branching on it in the same tick. Lift placement is deferred
    # through RequestManager, so isOnLift() is still false when placeLift
    # returns. MEASURED: "after lift (...): onLift=false" on a placement that
    # had in fact worked. Branching on that false negative ran a fallback and
    # produced a SECOND lift -- reported as "the lift cant be removed and there
    # are two".
    # sm.player.placeLift DOES NOT WORK ON A REAL BODY -- MEASURED, a 25 second
    # trace in which onLift never once became true. Vanilla only ever passes it
    # GHOST bodies from the engine's own import. createNonPlayerLift is the call
    # that takes a real one (BuilderGuideLiftPlatform:160).
    assert "createNonPlayerLift" in code, (
        "the import is back on sm.player.placeLift, which measurably does "
        "nothing to a body already standing in the world")
    assert "sm.player.placeLift" not in code, (
        "placeLift is being called on a real body again -- 25 seconds of trace "
        "say it never takes")

    lifts = code.count("createNonPlayerLift")
    assert lifts == 1, (
        f"{lifts} lift placements in one import; there must be exactly one or "
        "the host gets a pile of them")

    # A non-player lift belongs to nobody, so the HANDLE is the only way to be
    # rid of it. Keeping it is what makes this safe to use at all.
    assert "lift = lift" in code, (
        "the lift handle is not kept, so nothing can ever destroy it -- that is "
        "what left two unremovable lifts standing last time")

    # 4b. EVERY IMPORT VARIANT IS TRIED, AND A DYNAMIC RESULT WINS.
    #
    # A blueprint file carries no static flag -- MEASURED across 400 of the
    # owner's own, the only keys are bodies/joints/version/dependencies -- so
    # staticness is decided by the CALL. importFromString takes two undocumented
    # booleans that nothing in the game names, and vanilla's own 4-argument
    # importFromFile demonstrably CAN produce a body that moves (a chopped tree
    # becomes a log that falls, WoodHarvestable.lua:127).
    #
    # Four fixes were shipped on reasoning about this and none landed. So the
    # code tries the calls and asks the body which one worked.
    # ONE import call. The sweep answered its question -- all six call shapes
    # produce a static body, twice over -- so keeping it meant importing SIX
    # copies of every creation and destroying five. Six times the cost on a 3 MB
    # blueprint, and a duplicate left standing whenever a destroy did not take.
    # Reported as "it spawns two and only one is not frozen".
    assert code.count("importFromFile") == 1, (
        f"{code.count('importFromFile')} import calls. There must be exactly one "
        "-- the variant sweep is finished and each extra call spawns another "
        "copy of the creation that has to be cleaned up again")
    assert "isDynamic()" in code, (
        "nothing asks whether the imported body is actually dynamic")
    assert "not alreadyDynamic" in code, (
        "the lift is placed even when the import already came out dynamic, "
        "which puts a finished build back onto a lift for no reason")

    # 4c. THE LIFT IS TAKEN BACK OFF AGAIN.
    #
    # MEASURED, all six variants, twice: dynamic=false every time. An import is
    # ALWAYS static and coming off a lift is the only thing that converts one --
    # so putting it on a lift is half a fix. Leaving the other half to the host
    # meant lifts accumulated one per import (two in the screenshot, two imports
    # in the log) and the creation stayed stuck until somebody acted.
    #
    # It has to be DEFERRED: placement goes through RequestManager, so removing
    # the lift in the same tick removes it before the creation is on it.
    world_all = lua_code(world)
    assert "liftRelease" in code, (
        "nothing schedules the lift to be removed again, so every import leaves "
        "a lift standing and the creation static until the host intervenes")
    assert "function World.sv_releaseImportedLift( self" in world_all, (
        "the release is scheduled but nothing performs it")
    assert "sv_releaseImportedLift" in lua_code(
        world[world.index("function World.server_onFixedUpdate"):]
        [:world[world.index("function World.server_onFixedUpdate"):].index(chr(10) + "end")]), (
        "the release is never driven from the tick loop, so it never runs")
    rel = world_all[world_all.index("function World.sv_releaseImportedLift"):]
    rel = rel[:rel.index(chr(10) + "function ")]
    assert "atTick" in rel and "destroy()" in rel, (
        "the release does not wait, or does not destroy the lift handle")

    # A QUEUE, NOT A SLOT. Three imports inside a minute each wrote their
    # release into the same field and overwrote the one before, so only the last
    # creation was ever let off its lift -- "it spawns two and only one is not
    # frozen".
    assert "liftReleases" in code and "liftReleases" in rel, (
        "pending releases are held in a single slot again, so a second import "
        "cancels the first one's release and leaves that creation frozen")
    assert "for _, job in ipairs( queue )" in rel, (
        "the release does not drain a queue, so only one can ever be pending")

    # 5. THE LIFT GOES ON THE FLOOR. character.worldPosition is the character's
    #    CENTRE, about a metre up; a lift placed there hangs in mid air. Vanilla's
    #    own server-side spawn derives its position from a shape, not a character
    #    (BuilderGuideLiftPlatform.sv_spawnLift).
    assert "CITY_FLOOR" in code and "sm.physics.raycast" in code, (
        "the lift height comes from the character again, which puts it a metre "
        "above the floor -- MEASURED as liftPos z=3, world 0.75, on open terrain")


def a_body_on_a_lift_is_never_the_ground():
    """The ground pin must not reach a creation being placed.

    PROFILES pin the ground with convertibleToDynamic = false, and a creation
    that cannot convert can never come off a lift. Plots.sv_isGround is a pure
    height test -- right for every piece of the city, because none of it is ever
    on a lift, and wrong for an import.

    It only bites low down. NOTlift puts the lift at slab top, world z 1.25,
    against a 1.10 threshold, so on a plot there is margin. Import while standing
    on the terrain outside the city and there is none -- the creation would be
    pinned onto the lift and never come off, which is the same symptom this whole
    change exists to fix.
    """
    src = io.open(SCRIPTS / "Plots.lua", encoding="utf-8").read()
    fn = src[src.index("function Plots.sv_isGround"):]
    fn = fn[:fn.index(chr(10) + "end")]
    assert "isOnLift" in fn, (
        "sv_isGround is a bare height test again, so a creation imported low "
        "down gets pinned onto its own lift and can never be released")

    # and it must come BEFORE the height test, or the height test wins
    assert fn.index("isOnLift") < fn.index("getWorldAabb"), (
        "the lift test runs after the height test, so it cannot save a body the "
        "height test already claimed")

    # AND HEIGHT ALONE IS NOT THE CITY FLOOR.
    #
    # The pin protects the deck and the plot slabs, all of which are inside the
    # footprint. Terrain OUTSIDE the city is LOWER than our deck, so a pure
    # height test claims anything resting on it -- the same shape as the bug
    # that made a metal 2 block outside the city undeletable.
    #
    # It bites imports hardest: a creation released from a lift onto open
    # terrain settles around z 0.75, under the 1.10 threshold, and the pinned
    # twin sets convertibleToDynamic = false. It would freeze the instant it came
    # off the lift -- "still static", by a fourth route.
    assert "sv_locate" in lua_code(fn), (
        "sv_isGround does not check the city footprint, so anything resting on "
        "terrain outside the city is pinned as though it were the city floor")


def every_step_works_with_items_alone():
    """Import, place and release need no typing at all.

    "make sure it works just with the items and without commands since the
    glitch is still there."

    A chat command is fine as an escape hatch and useless as a workflow: at an
    event the host has both hands full. Every step has to be on a tool.

        NOTlift left click    open the creations browser, import
        NOTlift right click   release the lift, so the creation becomes a build
        Cleaner               delete a lift you point at, including the kind no
                              lift tool can pick up

    The last one matters most. sm.lift.createNonPlayerLift makes a lift that
    belongs to no player, and nothing but Lift:destroy() removes one. Two are
    standing in the owner's world right now because an earlier build made them.
    """
    tool = lua_code(io.open(SCRIPTS / "NotLift.lua", encoding="utf-8").read())
    cleaner = lua_code(io.open(SCRIPTS / "CleanerTool.lua", encoding="utf-8").read())

    # NOTlift: both buttons do something, and the release is wired end to end
    assert "pressed( primaryState )" in tool, "NOTlift has no import button"
    assert "pressed( secondaryState )" in tool, (
        "NOTlift has no release button, so dropping a creation off its lift "
        "still needs a chat command")
    assert 'sendToServer( "sv_n_swDropLift"' in tool and         "function NotLift.sv_n_swDropLift( self" in tool, (
        "the release button sends somewhere nothing receives")
    for verb in ("removeLift", "destroy()"):
        assert verb in tool, f"the release never calls {verb}"

    # ...and it is host-gated on the SERVER, like every other NOTlift action
    drop = tool[tool.index("function NotLift.sv_n_swDropLift"):]
    assert "hostnotlift" in drop and "getHostPlayer()" in drop, (
        "the release is not host-checked server-side")
    assert "local hostOnly = true" in drop, (
        "the release host check does not fail safe")

    # Cleaner: a lift is a thing you can point at, so it must be deletable
    assert 'result.type == "lift"' in cleaner, (
        "the cleaner cannot target a lift, so a non-player lift is permanent "
        "without a chat command")
    assert "getLiftData()" in cleaner, (
        "the cleaner does not read the lift out of the raycast")
    assert "params.lift" in cleaner, (
        "the cleaner's server half never receives a lift to destroy")


def anything_liftable_can_also_be_set_down():
    """If a profile lets you lift a body, it must let that body become dynamic.

    THIS IS THE CHECK THAT WOULD HAVE SAVED THREE VERSIONS.

    `sweep` was liftable = true with convertibleToDynamic = false. Read as a
    sentence that is "you may put this on a lift, and it may never come off" --
    a contradiction, not a rule. Nothing enforced the pairing, so it sat there.

    What it cost: every creation NOTlift imported outside a plot got `sweep` from
    the patrol within a second of landing, and was pinned static forever. Three
    separate fixes went into the lift -- placing one, verifying placement,
    releasing it with a right click -- and not one of them could have worked,
    because this undid all of them. MEASURED against the real resolver:

        open terrain  zone=sweep  profile=sweep  convertibleToDynamic=False
        on a plot     zone=true   profile=open   convertibleToDynamic=True

    Reported three times as "welded to air", "still is statick", "still doesnt
    work" -- and each report was answered by looking at the lift, because the
    lift was the thing that had just changed.

    The PINNED twins are exempt and that is the point of them: they are
    liftable = false AND convertible = false together, which is consistent.
    """
    lua = fresh("Palette.lua", "Protection.lua")
    profiles = lua.eval("PROFILES_FOR_TEST")
    if profiles is None:
        # PROFILES is a file-local table; reach it through the resolver's own
        # accessor rather than re-declaring it here, so the two cannot drift.
        lua.execute("PROFILES_FOR_TEST = Protection.Sv_ProfilesForTest()")
        profiles = lua.eval("PROFILES_FOR_TEST")

    bad = []
    for name in profiles:
        p = profiles[name]
        if p["liftable"] and not p["convertibleToDynamic"]:
            bad.append(name)
    assert not bad, (
        f"{', '.join(sorted(bad))}: liftable but not convertibleToDynamic. A body "
        "you can put on a lift and never take off is stuck there -- and anything "
        "given that profile can never become a normal build again")


def the_lift_trace_is_bounded():
    """A per-tick logger that cannot run away.

    "make a detailed log about the lift that works real time so you can get info
    why tis wrong."

    Right -- every measurement so far was one sample at one instant chosen by me,
    and each was taken at the wrong instant: isOnLift() before placement had been
    processed, isDynamic() before the release, "lift=true" which only ever meant
    "no Lua error was raised". A creation passes through imported, on-a-lift,
    released and settled, and the interesting thing is which TRANSITION fails.

    But a per-tick log is also exactly the shape of the worst performance bug
    this project has measured -- 1.79 GB and 1.88 M lines in one session, from a
    print() running every tick. So the trace must be bounded three ways, and this
    check is what keeps it that way.
    """
    world = io.open(SCRIPTS / "World.lua", encoding="utf-8").read()
    code = lua_code(world)

    assert "function World.sv_traceStep( self" in code, "no trace stepper"
    assert "sv_traceStep" in lua_code(
        world[world.index("function World.server_onFixedUpdate"):]
        [:world[world.index("function World.server_onFixedUpdate"):].index(chr(10) + "end")]), (
        "the trace is never driven from the tick loop, so it never runs")

    step = code[code.index("function World.sv_traceStep"):]
    step = step[:step.index(chr(10) + "function ")]

    # 1. only on change, or on a heartbeat -- never unconditionally per tick
    assert "changed or tick >= t.nextBeat" in step, (
        "the trace logs every tick regardless of whether anything changed, which "
        "is 40 lines a second of identical text")
    # 2. the heartbeat is at most one line a second
    assert "TRACE_HEARTBEAT" in step and "World.TRACE_HEARTBEAT = 40" in code, (
        "the heartbeat is not one line a second")
    # 3. it stops on its own
    assert "untilTick" in step and "self.sw.trace = nil" in step, (
        "the trace never ends, so one import logs for the rest of the session")

    # and it must record the two things that look identical from outside: what
    # the BODY says and what the RESOLVER would give it
    line = code[code.index("function World.sv_traceLine"):]
    line = line[:line.index(chr(10) + "function ")]
    for probe in ("isConvertibleToDynamic", "sv_profileForTest", "isOnLift", "isDynamic"):
        assert probe in line, (
            f"the trace does not record {probe}, so 'the patrol pinned it again' "
            "and 'the engine never converted it' stay indistinguishable")


def a_new_world_does_not_inherit_the_last_ones_state():
    """Fresh world, fresh protection, fresh plots, fresh clock.

    REPORTED: "every time I create a new world. and fix something you havent
    updated yet in a long time."

    Every state file this mod writes lives in $CONTENT_DATA -- one folder for the
    whole MOD, shared by every world made from it. Nothing here uses per-world
    storage at all. So a new world inherited the previous world's protection
    mode, buildopen flag, plot claims and event phase: it came up LOCKED, with
    claims on plots that did not exist, and an event that had already ended.

    Every time. This is also what was misread this morning as "one test event
    left it locked" -- it was never a leftover, it was structural, and /unlock
    was a fix for the symptom.

    Runs the real reset rather than reading the table, for the reason the buffer
    bug taught: a correct table that nothing reaches is not a feature.
    """
    lua = fresh("Layout.lua", "Palette.lua", "Settings.lua", "Event.lua", "Plots.lua")
    S, E = lua.globals().Settings, lua.globals().Event
    S.Sv_Load(False)

    # the state a previous world leaves behind
    S.Sv_SetQuiet("protection", "locked")
    S.Sv_SetQuiet("buildopen", False)
    S.Sv_SetQuiet("worldstamp", "the-old-world")
    # ...and a host preference, which must SURVIVE
    S.Sv_SetQuiet("maxjoints", 3)

    S.Sv_ResetWorldState("the-new-world")

    assert S.Get("protection") == "open", (
        "a new world still starts on the previous world's protection mode -- "
        "which is how a fresh world came up locked")
    assert S.Get("buildopen") is True, "a new world still starts with building shut"
    assert S.Get("worldstamp") == "the-new-world", "the stamp was not updated"
    assert S.Get("maxjoints") == 3, (
        "the reset wiped a HOST preference. Only the two settings that describe "
        "a particular world may be cleared; losing the tool and rule settings on "
        "every new world would be its own bug")

    ev = E.Sv_ResetFile()
    assert ev["phase"] == "off", (
        "the event clock is not reset, so a new world inherits `ended` -- the one "
        "phase that locks everything")

    # and the reset must be REACHED, after the base call that creates the world
    game = io.open(SCRIPTS / "Game.lua", encoding="utf-8").read()
    code = lua_code(game)
    assert "self:sv_newWorldReset()" in code, "nothing calls the reset"
    assert "function Game.sv_newWorldReset( self" in code, "the reset does not exist"
    assert code.index("CreativeGame.server_onCreate( self )") <         code.index("self:sv_newWorldReset()"), (
        "the reset runs BEFORE the base create. Writing to self.storage first "
        "makes CreativeGame's `if self.sv.saved == nil` see a non-empty table and "
        "skip creating the world -- no world at all, which is exactly what the "
        "baseGameContent experiment produced")

    reset = code[code.index("function Game.sv_newWorldReset"):]
    reset = reset[:reset.index(chr(10) + "function ")]
    for part in ("Settings.Sv_ResetWorldState", "Plots.Sv_ResetFile", "Event.Sv_ResetFile"):
        assert part in reset, f"the reset does not clear {part}"
    # bans and snapshots are NOT world state and must survive
    assert "Identity" not in reset and "Sv_ResetBans" not in reset, (
        "the reset touches the ban list -- bans are the one thing that is "
        "deliberately global, and a persistent ban list is the point of it")


def deleting_a_whole_creation_crosses_joints():
    """"The whole creation" means every body in it, not one weld group.

    REPORTED: "the cleaner even with F wont delete the whole thing", about a
    build of 72 blocks and 20 BEARINGS.

    The bearing count is the tell. Only a shared `childs` array is a weld -- see
    the reference creation in CLAUDE.md -- and a bearing joins two SEPARATE
    bodies. So that build is roughly 21 bodies, and body:getShapes() returns the
    shapes of exactly one of them. F deleted the chunk under the crosshair and
    left twenty standing, which reads as "the delete is broken" rather than "the
    delete did a twenty-first of the job".

    The same mistake was sitting in /purge look <n>, which announced "removed the
    whole creation" while removing one body. Two independent places, same
    misreading -- hence a check.

    getCreationShapes() is the one that crosses joints.
    """
    for path, fn_marker in (
        (SCRIPTS / "CleanerTool.lua", "function CleanerTool.sv_n_swDelete"),
        (SCRIPTS / "World.lua", 'cmd == "/purge"'),
    ):
        src = lua_code(io.open(path, encoding="utf-8").read())
        assert "getCreationShapes()" in src, (
            f"{path.name} deletes a 'whole creation' with getShapes(), which is "
            "one weld group -- anything joined by a bearing survives")

    # ...and reaching further makes the per-SHAPE city guard load-bearing: a
    # build bolted to a plot slab now brings the slab into range.
    world = lua_code(io.open(SCRIPTS / "World.lua", encoding="utf-8").read())
    purge = world[world.index('cmd == "/purge"'):]
    purge = purge[:purge.index("elseif cmd ==")]
    assert "sv_isCityShape" in purge, (
        "/purge can now reach across joints but has no per-shape city guard, so "
        "one bearing bolted to a plot puts the city floor in range")

    cleaner = lua_code(io.open(SCRIPTS / "CleanerTool.lua", encoding="utf-8").read())
    assert "isCity(" in cleaner, "the cleaner lost its per-shape city guard"


def the_cleaner_is_wired_to_the_same_uuid_everywhere():
    """The cleaner's uuid, its class and its gate all agree.

    A tool is named in three places that cannot see each other -- the toolset
    (which uuid exists and what class it runs), Settings.TOOLS (which uuid the
    tool guard yanks) and HOST_ONLY (which setting gates it). A uuid that matches
    in two of the three is a tool that either cannot be blocked or blocks
    something else.
    """
    import re
    toolset = io.open(SCRIPTS.parent / "Tools" / "Database" / "ToolSets"
                      / "serverworks.toolset", encoding="utf-8").read()
    settings = io.open(SCRIPTS / "Settings.lua", encoding="utf-8").read()

    # Parse it, do not scan near a string. The first version of this check looked
    # in a 400-character window around the class name and broke the moment a
    # comment was added above it -- a check that depends on how the file is
    # commented is a check that will lie.
    import json
    stripped = re.sub(r"//[^" + chr(10) + r"]*", "", toolset)
    entries = json.loads(stripped)["toolList"]
    ours = [e for e in entries if e.get("script", {}).get("class") == "CleanerTool"]
    assert len(ours) == 1, f"expected one CleanerTool entry, found {len(ours)}"
    entry = ours[0]
    uuid = entry["uuid"]

    assert entry["script"]["file"] == "$CONTENT_DATA/Scripts/CleanerTool.lua", (
        f"the toolset points at {entry['script']['file']}, not our script")
    assert (SCRIPTS / "CleanerTool.lua").is_file(), "CleanerTool.lua is missing"
    assert "previewRenderable" in entry, (
        "no previewRenderable -- the tool would have nothing to draw in the menu")

    assert uuid in settings, (
        f"the toolset declares the cleaner as {uuid} and Settings.lua never "
        "names it, so the tool guard cannot block it for guests")
    assert 'cleaner = "hostcleaner"' in settings, (
        "the cleaner is not in HOST_ONLY -- a delete-anything tool would be "
        "handed to every guest in the lobby")
    for key in ("cleaner", "hostcleaner"):
        assert f'key = "{key}"' in settings, f"no {key} row in the settings schema"

    # and it really is the F key it reads
    tool = io.open(SCRIPTS / "CleanerTool.lua", encoding="utf-8").read()
    assert "forceBuild" in tool, (
        "the cleaner does not read forceBuild -- that is the F key, and the "
        "third argument of client_onEquippedUpdate is the only place Lua sees it")


def the_city_floor_is_pinned_except_while_people_are_building():
    """The ground is free during BUILD, and pinned in every other mode.

    Two requirements that pull against each other, and both are real.

    V38: `open` sets liftable and convertibleToDynamic true, and a plot slab is
    not scenery -- so anyone with a lift could carry off somebody's plot, and a
    slab that goes dynamic is a floating object with nothing holding it.

    And then: "the stand the plot is on. and the plot it self shall be
    destructuble and placable. aka not protected when build time."

    Both hold if the pin is about WHEN. While the clock is running the ground
    belongs to whoever is building on it, and presence enforcement is what keeps
    that to their own plot. Every other mode pins it -- prep, the buffer, after
    the event ends, under a lockdown -- which is when it earns its keep.

    This runs the real resolver rather than reading the table, because a profile
    that exists is not a profile any body receives. See
    buffer_time_actually_reaches_the_polish_profile for what that cost last time.
    """
    lua = fresh("Layout.lua", "Settings.lua", "Protection.lua", "Plots.lua", "Event.lua")
    lua.globals().Settings.Sv_Load(False)
    P, Prot = lua.globals().Plots, lua.globals().Protection

    plots = lua.eval("Plots()")
    P.sv_onCreate(plots, lua.table_from({"grid": lua.table_from({}), "enabled": True}))
    plots["enabled"] = True
    lua.globals().g_swPlots = plots
    prot = lua.eval("Protection()")
    Prot.sv_onCreate(prot, "open")
    lua.globals().g_swProtection = prot
    Prot.sv_setGroundTest(prot, lua.eval("function( b ) return g_swPlots:sv_isGround( b ) end"))
    Prot.sv_setResolver(prot, lua.execute("""
        return function( body )
            if g_swPlots:sv_isScenery( body ) and not Settings.CityIsOpen() then
                return "locked"
            end
            local zone = g_swPlots:sv_bodyIsOpen( body )
            if zone == "sweep" then return "sweep" end
            if Settings.Get( "buildopen" ) == false
                and not g_swProtection:sv_modeClosesBuilding() then
                return false
            end
            return zone
        end
    """))

    B = float(P.BLOCK)
    bx, by = lua.globals().Layout.plotCentre(plots["layout"], 1)
    # a plot body: its stand reaches the ground, which is what makes it ground
    ground = lua.execute("""
        return function( x, y )
            local b = { worldPosition = { x = x, y = y, z = 1.1 } }
            function b:getShapes() return { { shapeUuid = "concrete-ish" } } end
            function b:getWorldAabb()
                return { x = x, y = y, z = 0.0 }, { x = x, y = y, z = 1.25 }
            end
            return b
        end
    """)(float(bx) * B, float(by) * B)
    assert P.sv_isGround(plots, ground) is True, "the fixture is not ground"
    # hold the plot open so the resolver says buildable
    P.sv_holdTeam(plots, lua.table_from({"kind": "plot", "index": 1}))

    def flags(mode, buildopen):
        Prot.sv_setMode(prot, mode)
        lua.globals().Settings.Sv_SetQuiet("buildopen", buildopen)
        got = Prot.sv_profileForTest(prot, ground)
        return got[0] if isinstance(got, tuple) else got

    build = flags("open", True)
    assert build["buildable"] is True, "you cannot build on your own plot in BUILD"
    assert build["erasable"] is True, "you cannot remove a block you placed"
    assert build["liftable"] is True, (
        "the plot is pinned during build time -- 'not protected when build time'")
    assert build["convertibleToDynamic"] is True, (
        "the plot cannot convert during build time")

    for mode, why in [("polish", "the buffer"), ("display", "prep"),
                      ("locked", "after the event has ended")]:
        p = flags(mode, False)
        assert p["liftable"] is False, (
            f"during {why} somebody could lift a whole plot away")
        assert p["convertibleToDynamic"] is False, (
            f"during {why} a plot floor could come loose")

    # and the pinned twins really are the profile in every other respect
    src = io.open(SCRIPTS / "Protection.lua", encoding="utf-8").read()
    body = src[src.index("local PROFILES = {"):src.index("Protection.MODES")]
    lua.execute(body.replace("local PROFILES", "PROFILES", 1)
                    .replace("local PINNED", "PINNED", 1))
    PROFILES, PINNED = lua.globals().PROFILES, lua.globals().PINNED
    for name in PROFILES:
        assert PINNED[name] is not None, f"no pinned twin for {name!r}"
        for flag in ("buildable", "erasable", "paintable", "connectable",
                     "usable", "destructable"):
            assert PINNED[name][flag] == PROFILES[name][flag], (
                f"pinned {name!r} changed {flag}; it may only pin the two")

    fn = src[src.index("local function profileFor"):]
    fn = fn[:fn.index(chr(10) + "end")]
    returns = [ln.strip() for ln in fn.splitlines()
               if ln.strip().startswith("return") or "then return" in ln]
    for line in returns:
        assert "forBody(" in line, f"profileFor returns without the pin: {line!r}"


def buffer_time_actually_reaches_the_polish_profile():
    """Having the right profile is not the same as a body ever getting it.

    REPORTED: "please make as I said to the buffer time. because it doesnt work
    this way yet."

    V34 added the polish profile and pointed the buffer phase at it, and the
    check for that passed -- because it only checked the TABLE. What actually
    happened in game: sv_applyEventPhase sets buildopen = false for every phase
    that is not build, and the resolver's blanket

        if Settings.Get( "buildopen" ) == false then return false end

    fired FIRST and returned `locked`. Buffer was identical to prep. The polish
    profile was correct and unreachable.

    So this runs the resolver itself, which is the only thing that could have
    caught it.
    """
    lua = fresh("Layout.lua", "Settings.lua", "Protection.lua", "Plots.lua", "Event.lua")
    lua.globals().Settings.Sv_Load(False)
    P, Prot = lua.globals().Plots, lua.globals().Protection

    plots = lua.eval("Plots()")
    P.sv_onCreate(plots, lua.table_from({"grid": lua.table_from({}), "enabled": True}))
    plots["enabled"] = True
    lua.globals().g_swPlots = plots

    prot = lua.eval("Protection()")
    Prot.sv_onCreate(prot, "open")
    lua.globals().g_swProtection = prot

    # the resolver, transcribed from World.server_onCreate. If World's copy and
    # this one ever disagree the check below is worthless, so it is asserted
    # against the real source afterwards.
    resolver = lua.execute("""
        return function( body )
            if g_swPlots:sv_isScenery( body ) and not Settings.CityIsOpen() then
                return "locked"
            end
            local zone = g_swPlots:sv_bodyIsOpen( body )
            if zone == "sweep" then return "sweep" end
            if Settings.Get( "buildopen" ) == false
                and not g_swProtection:sv_modeClosesBuilding() then
                return false
            end
            return zone
        end
    """)
    world_src = io.open(SCRIPTS / "World.lua", encoding="utf-8").read()
    assert "sv_modeClosesBuilding()" in world_src, (
        "World.lua's resolver no longer consults sv_modeClosesBuilding, so buffer "
        "time is blanket-locked again")

    Prot.sv_setResolver(prot, resolver)

    # A body standing on a PLOT, made of a player's own blocks.
    #
    # Not at the origin: the origin is the plaza, which resolves to "sweep" and
    # would have made this check pass for entirely the wrong reason. Ask Layout
    # where a real plot is.
    bx, by = lua.globals().Layout.plotCentre(plots["layout"], 1)
    assert bx is not None, "plot 1 does not exist -- the fixture is wrong"
    block = float(P.BLOCK)
    make_body = lua.execute("""
        return function( x, y, z )
            local b = { worldPosition = { x = x, y = y, z = z } }
            function b:getShapes() return { { shapeUuid = "not-ours" } } end
            function b:getWorldAabb()
                return { x = x, y = y, z = z }, { x = x, y = y, z = z + 1 }
            end
            return b
        end
    """)
    body = make_body(float(bx) * block, float(by) * block, 1.5)

    zone = P.sv_bodyIsOpen(plots, body)
    assert zone is True, (
        f"the fixture is not standing on a buildable plot -- sv_bodyIsOpen says "
        f"{zone!r}, so this check would pass for the wrong reason")

    def flags(mode, buildopen):
        Prot.sv_setMode(prot, mode)
        lua.globals().Settings.Sv_SetQuiet("buildopen", buildopen)
        # profileFor returns ( profile, name ), so lupa hands back a tuple
        got = Prot.sv_profileForTest(prot, body)
        return got[0] if isinstance(got, tuple) else got

    # buffer: buildopen is false, and the mode must still decide
    got = flags("polish", False)
    assert got is not None, "no profile came back at all"
    assert got["buildable"] is False, "buffer let somebody place a block"
    assert got["erasable"] is False, "buffer let somebody break a block"
    assert got["paintable"] is True, (
        "buffer is not paintable -- the buildopen blanket is locking it again, "
        "which is the exact bug this check exists for")
    assert got["connectable"] is True, "buffer cannot rewire a controller"
    assert got["usable"] is True, "buffer cannot sit in a seat or press a button"

    # and the blanket still works where it should: open mode, host closes building
    shut = flags("open", False)
    assert shut["buildable"] is False and shut["paintable"] is False, (
        "closing building in OPEN mode no longer locks anything")


def unlock_actually_reopens_building():
    """The lift bug, and the one command that was supposed to undo it.

    REPORTED, over and over: "I cant use lift in custom game."

    The world shuts with TWO persisted switches, not one:

        protection  (hidden setting, Event.PROTECTION[phase])
        buildopen   (visible setting, sv_applyEventPhase)

    The end of an event writes both -- protection "locked", buildopen false --
    and `ended` is terminal, so both survive every restart. /unlock wrote only
    the first. And `buildopen == false` fires in World's resolver BEFORE the
    zone verdict, so every plot came back on the LOCKED profile anyway:

        liftable false, convertibleToDynamic false

    Vanilla's Lift.lua:127 needs targetBody:isLiftable() before it will hover,
    select or carry anything, so a locked world is a lift that silently does
    nothing. /unlock said "Building reopened" and reopened nothing.

    This runs the real resolver, not the table -- the same reason
    buffer_time_actually_reaches_the_polish_profile exists.
    """
    lua = fresh("Layout.lua", "Settings.lua", "Protection.lua", "Plots.lua", "Event.lua")
    lua.globals().Settings.Sv_Load(False)
    P, Prot = lua.globals().Plots, lua.globals().Protection

    plots = lua.eval("Plots()")
    P.sv_onCreate(plots, lua.table_from({"grid": lua.table_from({}), "enabled": True}))
    plots["enabled"] = True
    lua.globals().g_swPlots = plots

    prot = lua.eval("Protection()")
    Prot.sv_onCreate(prot, "open")
    lua.globals().g_swProtection = prot
    Prot.sv_setResolver(prot, lua.execute("""
        return function( body )
            if g_swPlots:sv_isScenery( body ) and not Settings.CityIsOpen() then
                return "locked"
            end
            local zone = g_swPlots:sv_bodyIsOpen( body )
            if zone == "sweep" then return "sweep" end
            if Settings.Get( "buildopen" ) == false
                and not g_swProtection:sv_modeClosesBuilding() then
                return false
            end
            return zone
        end
    """))

    bx, by = lua.globals().Layout.plotCentre(plots["layout"], 1)
    block = float(P.BLOCK)
    body = lua.execute("""
        return function( x, y, z )
            local b = { worldPosition = { x = x, y = y, z = z } }
            function b:getShapes() return { { shapeUuid = "not-ours" } } end
            function b:getWorldAabb()
                return { x = x, y = y, z = z }, { x = x, y = y, z = z + 1 }
            end
            return b
        end
    """)(float(bx) * block, float(by) * block, 1.5)
    assert P.sv_bodyIsOpen(plots, body) is True, "the fixture is not on a buildable plot"

    def profile(mode, buildopen):
        Prot.sv_setMode(prot, mode)
        lua.globals().Settings.Sv_SetQuiet("buildopen", buildopen)
        got = Prot.sv_profileForTest(prot, body)
        return got[0] if isinstance(got, tuple) else got

    # the state one finished event leaves behind, forever
    ended = profile("locked", False)
    assert ended["liftable"] is False, (
        "an ended event no longer locks the world -- this check is testing nothing")

    # what /unlock used to do: the mode only. STILL DEAD.
    half = profile("open", False)
    assert half["liftable"] is False and half["buildable"] is False, (
        "the buildopen blanket no longer overrides an open mode, so the bug this "
        "check exists for cannot happen -- confirm before deleting the check")

    # what /unlock must do: both.
    whole = profile("open", True)
    assert whole["liftable"] is True, (
        "reopening the world does not make a plot liftable, so the lift still "
        "cannot pick anything up")
    assert whole["convertibleToDynamic"] is True, (
        "a creation placed by the lift cannot convert to dynamic")
    assert whole["buildable"] is True and whole["erasable"] is True

    # ...and /unlock must ACTUALLY write both. String-matching, but a command
    # that sets one flag and announces the other is exactly this bug.
    world_src = io.open(SCRIPTS / "World.lua", encoding="utf-8").read()
    game_src = io.open(SCRIPTS / "Game.lua", encoding="utf-8").read()
    assert "sv_e_swOpenBuilding" in world_src, (
        "/unlock no longer asks Game to reopen building, so it sets the "
        "protection mode and leaves buildopen false -- the original bug")
    assert "function Game.sv_e_swOpenBuilding" in game_src, (
        "World.lua sends sv_e_swOpenBuilding and Game.lua has no handler for it")
    handler = game_src.split("function Game.sv_e_swOpenBuilding", 1)[1]
    handler = handler.split(chr(10) + "function ", 1)[0]
    assert 'Sv_SetQuiet( "buildopen", true )' in handler, (
        "sv_e_swOpenBuilding does not open building, which is its whole job")
    assert "sv_stop" in handler, (
        "sv_e_swOpenBuilding leaves a stale `ended` clock in Event.json, so the "
        "HUD keeps saying builds are locked over a world that is open")


def buffer_time_lets_you_polish_but_not_place_or_break():
    """The buffer phase resolves to a profile that adjusts, never builds.

    Asked for as: "in bufer time you can paint. edit settings. use controllers.
    and other stuff like that. but not place or brake blocks. so you can polish
    some mechanic stuff if you messed it up a bit."
    """
    lua = fresh("Settings.lua", "Protection.lua", "Layout.lua", "Event.lua")
    src = io.open(SCRIPTS / "Protection.lua", encoding="utf-8").read()
    body = src[src.index("local PROFILES = {"):src.index("Protection.MODES")]
    lua.execute(body.replace("local PROFILES", "PROFILES", 1))

    mode = lua.globals().Event.PROTECTION["buffer"]
    assert mode == "polish", (
        f"buffer resolves to {mode!r}; it must be a profile that allows "
        "adjusting a build without placing or breaking blocks")

    p = lua.globals().PROFILES[mode]
    for flag, want, why in [
        ("buildable", False, "buffer time is not extra build time"),
        ("erasable", False, "no breaking blocks once the clock has run out"),
        ("destructable", False, "nor with a sledgehammer or an explosive"),
        ("paintable", True, "repainting is the point of a polish window"),
        ("connectable", True, "so a controller can be rewired"),
        ("usable", True, "seats, buttons and switches so you can test it"),
        ("convertibleToDynamic", True, "'use controllers' means it has to move"),
    ]:
        assert p[flag] is want, f"buffer: {flag} should be {want} -- {why}"


def nothing_is_destructible_while_locked():
    lua = fresh("Settings.lua", "Protection.lua")
    src = io.open(SCRIPTS / "Protection.lua", encoding="utf-8").read()
    body = src[src.index("local PROFILES = {"):src.index("Protection.MODES")]
    lua.execute(body.replace("local PROFILES", "PROFILES", 1))
    P = lua.globals().PROFILES
    for name in ("locked", "display", "sweep"):
        assert P[name]["destructable"] is False, f"{name} allows destruction"
        assert P[name]["buildable"] is False, f"{name} allows building"
    assert P["locked"]["usable"] is False, "lockdown leaves buttons pressable"
    assert P["display"]["usable"] is True, "show mode has nothing to interact with"
    assert P["sweep"]["erasable"] is True, (
        "sweep must stay erasable or litter dumped on shared ground becomes "
        "permanent the moment the world locks")


# ------------------------------------------------------------------ plots ---

def plots_lua(cfg=None, owners=None):
    lua = fresh("Layout.lua", "Plots.lua")
    P = lua.globals().Plots
    inst = lua.eval("Plots()")
    P.sv_onCreate(inst, lua.table_from({"grid": lua.table_from(cfg or {}),
                                        "enabled": True}))
    inst["enabled"] = True
    if owners:
        for k, v in owners.items():
            inst["owners"][k] = v
    return lua, inst


def one_plot_each():
    lua, plots = plots_lua()
    ok, msg = lua.globals().Plots.sv_claim(plots, 5, "P1"), None
    assert plots["owners"][5] == "P1"
    ok2 = lua.globals().Plots.sv_claim(plots, 6, "P1")
    assert plots["owners"][6] is None, "one player claimed two plots"
    ok3 = lua.globals().Plots.sv_claim(plots, 5, "P2")
    assert plots["owners"][5] == "P1", "a claimed plot was taken from under its owner"


def teaming_needs_a_shared_filler():
    # 10x10 with a 2-cell plaza: the plaza takes cells 4 and 5 on both axes, so
    # in row 0 that is plot indices 5 and 6 -- and those plots DO NOT EXIST.
    lua, plots = plots_lua({"cols": 10, "rows": 10, "plazacells": 2, "roadevery": 0})
    P = lua.globals().Plots
    L = lua.globals().Layout
    assert P.sv_adjacent(plots, 3, 4) is True, "3 and 4 share a filler and should be neighbours"
    assert P.sv_adjacent(plots, 7, 8) is True, "7 and 8 share a filler and should be neighbours"
    assert P.sv_adjacent(plots, 1, 11) is True, "1 and 11 are neighbours down the rows"
    assert P.sv_adjacent(plots, 3, 5) is False, "3 and 5 are not neighbours at all"
    # The plaza is a 2x2 BLOCK of cells at (4,4)-(5,5), so the plots it swallows
    # are 45, 46, 55 and 56 -- not a stripe through row 0. Nothing can be next to
    # a plot that does not exist.
    for gone in (45, 46, 55, 56):
        assert L.plotExists(plots["layout"], gone) is False, (
            f"plot {gone} should be under the plaza")
    assert P.sv_adjacent(plots, 35, 45) is False, (
        "a plot under the plaza was treated as a neighbour")
    assert P.sv_adjacent(plots, 45, 46) is False, (
        "two plots under the plaza were allowed to team up")
    # the plots that ring the plaza are still ordinary neighbours of each other
    assert P.sv_adjacent(plots, 44, 34) is True, "44 and 34 are neighbours down the rows"


def the_plaza_cannot_be_claimed():
    lua, plots = plots_lua({"cols": 10, "rows": 10, "plazacells": 2})
    P = lua.globals().Plots
    ok, msg = P.sv_claim(plots, 45, "A")
    assert plots["owners"][45] is None, "somebody claimed a plot under the plaza"
    assert "plaza" in str(msg).lower(), f"the refusal should say why, got {msg!r}"
    # and an ordinary plot still works
    P.sv_claim(plots, 1, "A")
    assert plots["owners"][1] == "A"


def teaming_is_refused_across_a_road():
    lua, plots = plots_lua({"cols": 8, "rows": 8, "spawn": 0,
                            "roadevery": 2, "roadwidth": 6})
    P = lua.globals().Plots
    cols = plots["layout"]["cols"]
    L = lua.globals().Layout
    roads = [s["index"] for s in cols.values()
             if s["kind"] == "road" and s["index"] is not None]
    assert roads, "this configuration was supposed to produce roads"
    for i in roads:
        assert P.sv_adjacent(plots, i + 1, i + 2) is False, (
            f"plots {i+1} and {i+2} sit either side of a road and were allowed to team")


def the_filler_becomes_shared_only_after_teaming():
    lua, plots = plots_lua({"cols": 10, "rows": 10, "plazacells": 2},
                           owners={7: "A", 8: "B"})
    P = lua.globals().Plots
    # plots 7 and 8 are columns 6 and 7 of row 0, with a filler between them
    zone = lua.table_from({"kind": "fillerX", "col": 6, "row": 0})
    before = dict(P.sv_authorised(plots, zone))
    assert before == {}, f"the filler was shared before anyone teamed up: {before}"
    P.sv_request(plots, "A", "B")
    P.sv_request(plots, "B", "A")
    after = dict(P.sv_authorised(plots, zone))
    assert set(after) == {"A", "B"}, (
        f"after teaming the filler should belong to both, got {set(after)}")


def public_ground_belongs_to_nobody():
    lua, plots = plots_lua({"cols": 10, "rows": 10, "plazacells": 2}, owners={1: "A"})
    P = lua.globals().Plots
    for kind in ("plaza", "road", "corner"):
        z = lua.table_from({"kind": kind, "col": 0, "row": 0})
        assert dict(P.sv_authorised(plots, z)) == {}, f"{kind} is buildable by someone"


def spawn_is_the_middle_of_the_map():
    lua, plots = plots_lua({"cols": 10, "rows": 10, "plazacells": 2})
    P = lua.globals().Plots
    z = P.sv_locate(plots, lua.table_from({"x": 0.0, "y": 0.0, "z": 1.0}))
    assert z is not None and z["kind"] == "plaza", (
        f"the world origin is {z['kind'] if z else 'off the map'}, not the plaza")


def a_body_is_located_by_where_it_is_not_by_its_origin():
    """A plot body must resolve to its own plot, not to nothing.

    REPORTED: "I cant place blocks on the concrete but I can delete it. I can
    delete others plots."

    buildable = false with erasable = true is exactly ONE profile out of six:
    `sweep`. And sweep is what sv_bodyIsOpen returns when it cannot place a body
    in the city at all -- so every plot was being located somewhere it was not
    and treated as litter on open ground.

    body.worldPosition is a body's own ORIGIN. Every piece of this city is
    imported at sm.vec3.zero() because the blueprint carries absolute block
    coordinates, so an origin can report a point nowhere near the thing you are
    looking at. The AABB centre is the middle of where the body actually is.
    """
    lua, plots = plots_lua()
    P = lua.globals().Plots
    L = lua.globals().Layout
    B = float(P.BLOCK)

    # a body whose ORIGIN is the world origin -- the plaza -- but whose actual
    # extent is out on plot 34. This is the shape of the bug.
    bx, by = L.plotCentre(plots["layout"], 34)
    make = lua.execute("""
        return function( cx, cy, half )
            local b = { worldPosition = { x = 0, y = 0, z = 0 } }
            function b:getWorldAabb()
                return { x = cx - half, y = cy - half, z = 1.0 },
                       { x = cx + half, y = cy + half, z = 1.25 }
            end
            return b
        end
    """)
    body = make(float(bx) * B, float(by) * B, 2.0)

    z = P.sv_bodyZone(plots, body)
    assert z is not None, "the body located to nothing at all"
    assert str(z["kind"]) == "plot", (
        f"a body sitting on plot 34 located as {z['kind']!r}. If it locates by "
        "origin every city body lands on the plaza and every plot becomes sweep")
    assert int(z["index"]) == 34, f"located to plot {z['index']}, not 34"

    # and it must not be open to everybody once claimed
    P.sv_claim(plots, 34, "OWNER")
    plots["zoneOpen"] = lua.table_from({})
    plots["zoneHeld"] = lua.table_from({})
    assert P.sv_bodyIsOpen(plots, body) is False, (
        "a claimed plot with nobody on it must be locked, not sweepable")

    # nothing in the mod may go back to locating a body by its origin
    for name in ("Plots.lua", "World.lua", "Rules.lua"):
        src = io.open(SCRIPTS / name, encoding="utf-8").read()
        assert "sv_locate( body.worldPosition )" not in src, (
            f"{name} locates a body by its origin again -- use sv_bodyZone")


def standing_near_your_own_plot_keeps_it_open():
    """You may stand off your plot and it stays yours to build on.

    REPORTED: "I cant build while standing on protected blocks which sucks."

    V42 locked a claimed plot with nobody standing IN it -- which is what stops
    somebody on the road reaching over your work -- but the only thing that
    reopened it was standing inside the plot or on one of its own seams. Step
    onto a ROAD or onto the plaza and your own plot locked behind you while you
    were looking at it.

    It is a distance now, not a zone. A road being protected ground has nothing
    to do with whether the plot next to it is yours.
    """
    lua, plots = plots_lua({"cols": 10, "rows": 10, "roadevery": 3, "roadwidth": 6})
    P = lua.globals().Plots
    L = lua.globals().Layout
    B, RANGE = float(P.BLOCK), float(P.HOLD_RANGE)

    MINE = 1
    P.sv_claim(plots, MINE, "OWNER")
    bx, by = L.plotCentre(plots["layout"], MINE)
    r = L.plotRect(plots["layout"], 0, 0)
    assert r is not None

    def body_on_my_plot():
        return lua.table_from({"worldPosition": lua.table_from(
            {"x": float(bx) * B, "y": float(by) * B, "z": 1.5})})

    def held_from(block_x, block_y):
        plots["zoneOpen"] = lua.table_from({})
        plots["zoneHeld"] = lua.table_from({})
        P.sv_holdNearby(plots, "OWNER", lua.table_from(
            {"x": block_x * B, "y": block_y * B, "z": 1.5}))
        return P.sv_bodyIsOpen(plots, body_on_my_plot())

    # standing on it
    assert held_from(float(bx), float(by)) is True, "standing on your own plot locked it"

    # standing just off the edge -- the road, the seam, wherever
    edge = float(r["x"]) - 2
    assert held_from(edge, float(by)) is True, (
        "standing two blocks off the edge of your own plot locked it -- that is "
        "the report, and a road being protected has nothing to do with it")

    # still open right out to the limit
    assert held_from(float(r["x"]) - RANGE, float(by)) is True, (
        f"standing {RANGE} blocks away should still hold it")

    # but not from the far side of the city
    assert held_from(float(r["x"]) - RANGE - 20, float(by)) is False, (
        "a claimed plot stayed open with its owner nowhere near it -- anybody "
        "could reach over it")

    # and somebody else standing next to it holds nothing
    plots["zoneOpen"] = lua.table_from({})
    plots["zoneHeld"] = lua.table_from({})
    P.sv_holdNearby(plots, "SOMEBODY-ELSE", lua.table_from(
        {"x": float(bx) * B, "y": float(by) * B, "z": 1.5}))
    assert P.sv_bodyIsOpen(plots, body_on_my_plot()) is False, (
        "a stranger standing on somebody's plot held it OPEN")


def you_can_only_build_on_ground_that_is_yours():
    """A claimed plot with nobody on it is LOCKED, not open.

    "the function that only build on your tiles. and only when time started."

    Body permission flags are GLOBAL -- if a plot is buildable it is buildable by
    everybody, from anywhere within reach. So the old rule, "an unoccupied zone
    stays open", meant standing on the road beside somebody's work and reaching
    over it, and the owner did not even have to be online.

    Claimed and empty is locked now. Unclaimed and empty stays open: nothing
    there to protect, and the host needs to be able to place things.
    """
    lua, plots = plots_lua()
    P = lua.globals().Plots
    L = lua.globals().Layout
    B = float(P.BLOCK)

    def body_on(index):
        bx, by = L.plotCentre(plots["layout"], index)
        return lua.table_from({"worldPosition": lua.table_from(
            {"x": float(bx) * B, "y": float(by) * B, "z": 1.5})})

    MINE, YOURS = 1, 2

    # nobody has claimed anything: an empty plot is open
    assert P.sv_bodyIsOpen(plots, body_on(MINE)) is True, (
        "an unclaimed empty plot should stay open")

    # now somebody owns it and is not standing on it
    P.sv_claim(plots, MINE, "OWNER")
    plots["zoneOpen"] = lua.table_from({})
    plots["zoneHeld"] = lua.table_from({})
    assert P.sv_bodyIsOpen(plots, body_on(MINE)) is False, (
        "a CLAIMED plot with nobody on it was open -- anyone could stand on the "
        "road and build over somebody else's work")
    assert P.sv_bodyIsOpen(plots, body_on(YOURS)) is True, (
        "an unclaimed plot next door should be unaffected")

    # the owner standing on their own land holds it open
    P.sv_holdTeam(plots, lua.table_from({"kind": "plot", "index": MINE}))
    assert P.sv_bodyIsOpen(plots, body_on(MINE)) is True, (
        "the owner is standing on their own plot and it is still locked")

    # and holding your plot must not hold anybody else's
    assert plots["zoneHeld"][f"p{YOURS}"] is None, (
        "standing on your own plot held somebody else's open too")


def an_unclaimed_empty_plot_stays_open():
    lua, plots = plots_lua({"cols": 10, "rows": 10, "plazacells": 2})
    P = lua.globals().Plots
    L = lua.globals().Layout
    bx, by = L.plotCentre(plots["layout"], 1)
    body = lua.table_from({"worldPosition": lua.table_from(
        {"x": bx * 0.25, "y": by * 0.25, "z": 1.3})})
    assert P.sv_bodyIsOpen(plots, body) is True, (
        "an unclaimed plot with nobody on it should not be locked")


def a_players_block_of_our_materials_is_not_the_city():
    """Metal 2 and concrete are ordinary building blocks. Height decides.

    REPORTED: "whatever the block is metal 2 or concrete it counts as part of the
    city whatever of it actualy being so."

    The city's top layer is block z = DECK_Z, world z 1.00 to 1.25. A player
    builds ON it, so their first block is 1.25 to 1.50. The old test allowed
    anything up to 1.30 -- so if shape.worldPosition means the MINIMUM CORNER
    rather than the centre, a player's first block sat at exactly 1.25 and was
    classed as city floor: the cleaner refused to delete it and CLEAR CITY would
    have taken it.

    Both readings are checked, because which one the engine means is a guess and
    the threshold is set where the guess stops mattering.
    """
    lua, plots = plots_lua()
    P = lua.globals().Plots
    B, DECK_Z = float(P.BLOCK), int(P.DECK_Z)

    def shape_at(uuid, z):
        return lua.table_from({"shapeUuid": uuid,
                               "worldPosition": lua.table_from({"x": 0.0, "y": 0.0,
                                                                "z": z})})

    ours = [str(P.CONCRETE), str(P.METAL2), str(P.METAL3)]
    deck_readings = {"min corner": DECK_Z * B, "centre": (DECK_Z + 0.5) * B}
    build_readings = {"min corner": (DECK_Z + 1) * B, "centre": (DECK_Z + 1.5) * B}

    for uuid in ours:
        for how, z in deck_readings.items():
            assert P.sv_isCityShape(plots, shape_at(uuid, z)) is True, (
                f"our own deck at z={z} ({how}) was not recognised as city -- "
                "CLEAR CITY would leave it behind")
        for how, z in build_readings.items():
            assert P.sv_isCityShape(plots, shape_at(uuid, z)) is False, (
                f"a PLAYER's block at z={z} ({how}) was called city floor. It is "
                "the layer directly above ours and it is theirs to delete.")

    # and a block that is not one of our materials is never city, at any height
    other = "b63c6440-dfc2-4da7-acdb-3c385080b2e4"
    for z in list(deck_readings.values()) + list(build_readings.values()):
        assert P.sv_isCityShape(plots, shape_at(other, z)) is False

    # OFF THE PLATFORM ENTIRELY. "I still cant remove metal 2 via the tool. even
    # if its not on the platform" -- a block dropped on the terrain outside the
    # city is LOWER than our deck, so a pure height test called it city floor.
    def shape_out_there(uuid, z):
        return lua.table_from({"shapeUuid": uuid,
                               "worldPosition": lua.table_from(
                                   {"x": 500.0, "y": 500.0, "z": z})})

    for uuid in ours:
        for z in (0.125, 0.5, 1.0, 1.125, 5.0):
            assert P.sv_isCityShape(plots, shape_out_there(uuid, z)) is False, (
                f"a {uuid[:8]} block at z={z}, five hundred metres from the city, "
                "was called city floor")

    # and under the platform, away from a stand, is somebody else's business
    bx, by = lua.globals().Layout.plotCentre(plots["layout"], 1)
    edge = lua.table_from({"shapeUuid": ours[1], "worldPosition": lua.table_from(
        {"x": (float(bx) + 8) * B, "y": (float(by) + 8) * B, "z": 0.25})})
    assert P.sv_isCityShape(plots, edge) is False, (
        "a block under the platform but nowhere near a stand was called ours")

    # the cleaner restates the threshold because a tool script may not share the
    # Game/World environment -- the two numbers must not drift apart
    tool = io.open(SCRIPTS / "CleanerTool.lua", encoding="utf-8").read()
    ceiling = float(P.CITY_CEILING)
    assert f"{ceiling:g}" in tool, (
        f"CleanerTool does not use the same ceiling ({ceiling:g}) as "
        "Plots.CITY_CEILING, so the tool and the city would disagree about "
        "which blocks are deletable")


def the_decking_is_safe_but_litter_on_it_is_not():
    """The city's own decking is permanent. Anything standing on it is litter.

    REPORTED: "you need to fix the unremovable craft bots, gems and others."

    The plaza used to resolve to "locked" as a way of stopping a guest deleting
    spawn. That defended the right thing in the wrong place: the plaza is where
    everyone arrives, so it is exactly where dropped craftbots and gems land, and
    locking the ground locked them too -- permanently, because the world stays
    locked between events.

    The decking is defended by sv_isScenery instead, which is a much better test:
    our plaza is metal at deck height, and a craftbot standing on top of it is
    not. So this asserts both halves.
    """
    lua, plots = plots_lua({"cols": 10, "rows": 10, "plazacells": 2})
    P = lua.globals().Plots

    # Built in Lua, not Python: these are called as body:getShapes(), so they
    # need a real self parameter and real multiple returns.
    at = lua.execute("""
        return function( x, y, z, uuids )
            local shapes = {}
            for _, u in ipairs( uuids ) do
                shapes[#shapes + 1] = { shapeUuid = u }
            end
            local body = { worldPosition = { x = x, y = y, z = z } }
            function body:getShapes() return shapes end
            function body:getWorldAabb()
                return { x = x, y = y, z = z - 0.2 }, { x = x, y = y, z = z + 0.05 }
            end
            return body
        end
    """)

    def make(x, y, z, uuids):
        return at(x, y, z, lua.table_from(uuids))

    METAL2, METAL3 = str(P.METAL2), str(P.METAL3)
    CONCRETE = str(P.CONCRETE)

    # our own plaza decking -- metal, at deck height
    deck = make(0.0, 0.0, 1.1, [METAL3, METAL2])
    assert P.sv_isScenery(plots, deck) is True, (
        "the decking is not recognised as scenery, so nothing is protecting "
        "spawn from being erased")

    # a craftbot standing on the plaza is not decking, whatever else it is
    litter = make(0.0, 0.0, 1.1, ["b63c6440-dfc2-4da7-acdb-3c385080b2e4"])
    assert P.sv_isScenery(plots, litter) is False, (
        "a craftbot on the plaza was classed as city scenery and would be "
        "locked forever")
    assert P.sv_bodyIsOpen(plots, litter) == "sweep", (
        "litter on the plaza must stay clearable by anyone -- the plaza is "
        "where everyone spawns, so it is where the spam lands")

    # and a build made of concrete at deck height is never scenery either
    build = make(0.0, 0.0, 1.1, [CONCRETE, METAL2])
    assert P.sv_isScenery(plots, build) is False


def a_bulk_purge_never_touches_the_city():
    """Every bulk purge skips anything holding a piece of the city.

    /purge walkways removed every body not standing on a plot -- which is the
    deck, the streets, the plaza and the pillar. That branch is gone now, removed
    on the owner's instruction because "not on a plot" is not a test for litter
    at all -- but /purge here <radius> is the same shape and still needs the
    guard.

    The guard is per SHAPE, not per body, because a build welded to a plot slab
    is one body with our concrete in it -- so the same test protects player work.
    """
    src = io.open(SCRIPTS / "World.lua", encoding="utf-8").read()
    assert "local function holdsCity(" in src, (
        "World.lua has no holdsCity guard at all")

    # every bulk loop over getAllBodies that destroys shapes must consult it
    import re
    for name in ("here",):
        start = src.index('what == "%s"' % name)
        chunk = src[start:start + 1200]
        assert "destroyShape" in chunk, f"/purge {name} no longer destroys anything"
        assert "holdsCity( body )" in chunk, (
            f"/purge {name} destroys bodies without checking holdsCity -- it "
            "would take the city floor with the litter")

    # and the shape test it leans on actually recognises our own materials
    lua, plots = plots_lua()
    P = lua.globals().Plots
    for uuid, is_city in [(str(P.METAL2), True), (str(P.METAL3), True),
                          (str(P.CONCRETE), True),
                          ("b63c6440-dfc2-4da7-acdb-3c385080b2e4", False)]:
        shape = lua.table_from({
            "shapeUuid": uuid,
            "worldPosition": lua.table_from({"x": 0.0, "y": 0.0, "z": 1.1}),
        })
        got = P.sv_isCityShape(plots, shape)
        assert bool(got) is is_city, (
            f"sv_isCityShape said {got} for {uuid}, expected {is_city}")


def outside_the_city_is_sweepable():
    lua, plots = plots_lua({"cols": 4, "rows": 4, "plazacells": 1})
    P = lua.globals().Plots
    body = lua.table_from({"worldPosition": lua.table_from(
        {"x": 500.0, "y": 500.0, "z": 1.0})})
    assert P.sv_bodyIsOpen(plots, body) == "sweep", (
        "junk dumped outside the city must stay clearable by anyone")


def grid_survives_a_save_and_load():
    lua, plots = plots_lua({"cols": 6, "rows": 4, "plot": 16, "plazacells": 2,
                            "roadevery": 2, "roadwidth": 8})
    P = lua.globals().Plots
    P.sv_claim(plots, 3, "A")
    P.Sv_SaveFile(plots)
    saved = P.Sv_LoadFile()
    assert saved is not None, "the plot file did not come back"
    fresh_plots = lua.eval("Plots()")
    P.sv_onCreate(fresh_plots, saved)
    assert fresh_plots["grid"]["cols"] == 6
    assert fresh_plots["grid"]["plot"] == 16
    assert fresh_plots["grid"]["plazacells"] == 2, (
        "the plaza size was lost on reload -- it used to live in a module global "
        "instead of the grid, so a restart rebuilt a different city")
    assert fresh_plots["owners"][3] == "A", "plot ownership was lost on reload"


# ------------------------------------------------------------------ teams ---
#
# The owner's rule, verbatim: "the teams shall only be able to team if the plot
# is either behind, front, left, right. nothing in between. unless another
# teammate connects."
#
# Two halves. A LINK may only be made orthogonally. A TEAM is whatever those
# links join up into, so a diagonal plot is a teammate exactly when somebody
# links you both -- and not otherwise.
#
# The grid used below is 6x6 with no plaza and no roads, so every plot has a
# filler on all four sides and nothing but the rule under test is in the way.
#
#     row 1:   7   8   9  10  11  12
#     row 0:   1   2   3   4   5   6

def team_grid(**over):
    cfg = {"cols": 6, "rows": 6, "plot": 20, "gap": 1,
           "roadevery": 0, "plazacells": 0}
    cfg.update(over)
    lua, plots = plots_lua(cfg)
    P = lua.globals().Plots
    for i in range(1, 37):
        plots["owners"][i] = f"P{i}"
    return lua, plots, P


def link(P, plots, a, b):
    """Both sides run the same command, which is how a team is agreed."""
    P.sv_request(plots, f"P{a}", f"P{b}")
    ok, msg = P.sv_request(plots, f"P{b}", f"P{a}")
    return ok, msg


def teamed(P, plots, a, b):
    r = P.sv_teamed(plots, a, b)
    return (r[0] if isinstance(r, tuple) else r) is True


def a_link_must_be_orthogonal():
    lua, plots, P = team_grid()
    for a, b, what in ((1, 2, "left/right"), (1, 7, "front/behind"),
                       (8, 7, "left/right"), (8, 2, "front/behind")):
        ok, msg = link(P, plots, a, b)
        assert teamed(P, plots, a, b), f"{what} plots {a} and {b} refused to team: {msg}"


def a_link_may_not_be_diagonal():
    lua, plots, P = team_grid()
    ok, msg = link(P, plots, 1, 8)          # corner to corner
    assert not teamed(P, plots, 1, 8), (
        "plots 1 and 8 are diagonal and were allowed to link directly")
    assert "corner" in str(msg).lower(), (
        f"the refusal should say why it is refused, got {msg!r}")


def a_link_may_not_skip_a_plot():
    lua, plots, P = team_grid()
    link(P, plots, 1, 3)
    assert not teamed(P, plots, 1, 3), "plots two apart were allowed to link"


def a_teammate_can_connect_you_to_a_diagonal():
    # 1 - 2
    #     |      1 and 8 are diagonal. They become teammates through 2.
    #     8
    lua, plots, P = team_grid()
    link(P, plots, 1, 2)
    link(P, plots, 2, 8)
    assert teamed(P, plots, 1, 8), (
        "1 and 8 are joined through 2 and should be on the same team -- "
        "'unless another teammate connects'")
    assert teamed(P, plots, 1, 2) and teamed(P, plots, 2, 8)


def a_plot_that_merely_touches_the_team_is_not_on_it():
    lua, plots, P = team_grid()
    link(P, plots, 1, 2)
    link(P, plots, 2, 8)
    # 9 is orthogonally next to 8, but 8 never agreed to it.
    assert not teamed(P, plots, 9, 8), "an unlinked neighbour was treated as a teammate"
    assert not teamed(P, plots, 9, 1), "an unlinked neighbour joined the whole team"


def the_whole_team_may_build_on_every_plot_in_it():
    lua, plots, P = team_grid()
    link(P, plots, 1, 2)
    link(P, plots, 2, 8)
    for index in (1, 2, 8):
        z = lua.table_from({"kind": "plot", "index": index})
        who = set(dict(P.sv_authorised(plots, z)))
        assert who == {"P1", "P2", "P8"}, (
            f"plot {index} is buildable by {sorted(who)}, expected the whole team")
    z = lua.table_from({"kind": "plot", "index": 3})
    assert set(dict(P.sv_authorised(plots, z))) == {"P3"}, (
        "a plot outside the team became buildable by the team")


def a_ring_shares_the_block_in_the_middle_of_it():
    # 1 - 2      Four plots teamed in a ring. Nobody ever ran the command
    # |   |      between 1 and 7, but they are on the same team and the block
    # 7 - 8      between them is inside the team's own land.
    lua, plots, P = team_grid()
    link(P, plots, 1, 2)
    link(P, plots, 2, 8)
    link(P, plots, 8, 7)
    assert teamed(P, plots, 1, 7), "the ring did not close into one team"
    # the filler between plot 1 (col 0,row 0) and plot 7 (col 0,row 1)
    z = lua.table_from({"kind": "fillerY", "col": 0, "row": 0})
    who = set(dict(P.sv_authorised(plots, z)))
    assert who == {"P1", "P2", "P7", "P8"}, (
        f"the block between two teammates is held by {sorted(who)} -- a locked "
        f"strip through the middle of a team's own land")


def leaving_cuts_everyone_who_was_only_reachable_through_you():
    # 1 - 2 - 3, then 2 leaves. 1 and 3 were only ever joined by 2.
    lua, plots, P = team_grid()
    link(P, plots, 1, 2)
    link(P, plots, 2, 3)
    assert teamed(P, plots, 1, 3)
    P.sv_unteam(plots, "P2")
    assert not teamed(P, plots, 1, 3), (
        "1 and 3 stayed teamed after the only plot joining them left")
    assert not teamed(P, plots, 1, 2) and not teamed(P, plots, 2, 3)
    z = lua.table_from({"kind": "plot", "index": 1})
    assert set(dict(P.sv_authorised(plots, z))) == {"P1"}, (
        "an old teammate still has build rights after the team broke up")


def giving_up_a_plot_removes_it_from_its_team():
    lua, plots, P = team_grid()
    link(P, plots, 1, 2)
    link(P, plots, 2, 3)
    P.sv_release(plots, "P2")
    assert not teamed(P, plots, 1, 3), "the team survived one of its plots being released"
    z = lua.table_from({"kind": "plot", "index": 1})
    assert set(dict(P.sv_authorised(plots, z))) == {"P1"}


def teams_survive_a_restart():
    lua, plots, P = team_grid()
    link(P, plots, 1, 2)
    link(P, plots, 2, 8)
    P.Sv_SaveFile(plots)
    saved = P.Sv_LoadFile()
    again = lua.eval("Plots()")
    P.sv_onCreate(again, saved)
    assert teamed(P, again, 1, 8), (
        "the team did not survive a reload -- a chain rebuilt as separate pairs")


def a_team_never_crosses_the_plaza():
    # A 2-cell plaza on a 6x6 grid takes cells 2 and 3 on both axes, so in row 0
    # that is plot indices 3 and 4 -- and neither exists.
    # 6x6 with a 2-cell plaza takes cells 2 and 3 on both axes, so the plots it
    # swallows are 15, 16, 21 and 22.
    lua, plots, P = team_grid(plazacells=2)
    L = lua.globals().Layout
    for gone in (15, 16, 21, 22):
        assert L.plotExists(plots["layout"], gone) is False, f"plot {gone} is plaza"
    link(P, plots, 14, 15)
    assert not teamed(P, plots, 14, 15), "a team formed with a plot under the plaza"
    link(P, plots, 15, 16)
    assert not teamed(P, plots, 15, 16), "two plaza cells were allowed to team"
    # and the plots around the edge of it still team normally
    link(P, plots, 13, 14)
    assert teamed(P, plots, 13, 14), "two ordinary neighbours could not team"


# ------------------------------------------------------------------ event ---
#
# The event clock takes `now` as an argument everywhere it needs the time, so a
# whole event can be run forwards here in milliseconds instead of an hour. That
# is the entire reason it is written that way.

def event_lua():
    lua = fresh("Event.lua")
    E = lua.globals().Event
    ev = lua.eval("Event()")
    E.sv_onCreate(ev, None)
    return lua, E, ev


def an_event_runs_prep_then_build_then_ends():
    lua, E, ev = event_lua()
    T = 1_000_000
    E.sv_start(ev, 10, 60, T)
    assert ev["phase"] == "prep"
    assert E.sv_buildAllowed(ev) is False, "building was open during prep"

    # nothing happens before the deadline
    assert E.sv_advance(ev, T + 9 * 60) is None
    assert ev["phase"] == "prep"

    assert E.sv_advance(ev, T + 10 * 60) == "build"
    assert E.sv_buildAllowed(ev) is True, "building did not open when build time started"
    assert abs(E.sv_remaining(ev, T + 10 * 60) - 60 * 60) < 1

    assert E.sv_advance(ev, T + 69 * 60) is None, "the event ended early"
    assert E.sv_advance(ev, T + 70 * 60) == "ended"
    assert E.sv_buildAllowed(ev) is False, "building stayed open after time"
    assert E.sv_advance(ev, T + 99 * 60) is None, "ended is not a stable state"


def a_zero_minute_prep_starts_building_at_once():
    # This is how /buildtime keeps working on top of the event clock.
    lua, E, ev = event_lua()
    E.sv_start(ev, 0, 30, 5000)
    assert ev["phase"] == "build"
    assert E.sv_buildAllowed(ev) is True


def the_world_says_what_may_be_built_on():
    """All four enableBuildOn* flags are set explicitly on the World class.

    "fun fact. in survival lift is disabled by default. which means. just remove
    that thing that disables lifts."

    The proof is in the base game: DungeonWorld turns enableBuildOnAssets,
    enableBuildOnLift and enableBuildOnBodies ON by hand, and WarehouseWorld
    turns one OFF. A world only writes a flag down when the default is the other
    way -- so in survival content these default to FALSE.

    This game is baseGameContent "Survival" and its world inherits
    CreativeFlatWorld, which never sets any of them, because a creative game has
    no reason to. So it inherited survival's defaults: a world where the lift
    places nothing and blocks will not attach to the city floor.

    They are class fields read when the world is created, not settings, so
    naming all four costs nothing and leaves no default to inherit by accident.
    """
    src = io.open(SCRIPTS / "World.lua", encoding="utf-8").read()
    for flag in ("enableBuildOnLift", "enableBuildOnBodies",
                 "enableBuildOnSurface", "enableBuildOnAssets"):
        assert f"World.{flag} = true" in src, (
            f"World.{flag} is not set. In a survival-content game the default is "
            "off, and an unset flag is one the engine decides for us.")

    # they must be class fields, set before any function -- the engine reads them
    # when the world is created and never again
    first_fn = src.index("function World.")
    for flag in ("enableBuildOnLift", "enableBuildOnBodies"):
        assert src.index(f"World.{flag} = true") < first_fn, (
            f"World.{flag} is set inside a function; it is read once when the "
            "world is created and would never take effect")


def the_alarm_shouts_but_does_not_lock_by_default():
    """alarmlock is OFF by default, on the owner's call.

    "by default the auto lockdown shall be off."

    Right call. A false alarm that shouts is a nuisance; a false alarm that
    freezes twenty people mid-build in front of a stream is worse than the
    griefing it was guarding against -- and the alarm cannot tell somebody
    clearing their own work from somebody wrecking yours.
    """
    lua = fresh("Settings.lua")
    lua.globals().Settings.Sv_Load(False)
    S = lua.globals().Settings

    assert S.Get("alarmlock") is False, (
        "the grief alarm still locks the world by itself")
    assert S.Get("alarmdrop") is not None, "the alarm has no threshold at all"

    # it must still ANNOUNCE -- turning off the lock is not turning off the alarm
    world = io.open(SCRIPTS / "World.lua", encoding="utf-8").read()
    fn = world[world.index("function World.sv_checkGriefAlarm"):]
    fn = fn[:fn.index(chr(10) + "end" + chr(10))]
    assert "sv_broadcast" in fn and "GRIEF ALARM" in fn, (
        "the alarm no longer says anything, which is not what off-by-default means")
    assert 'Settings.Get( "alarmlock" )' in fn, (
        "the lock is not behind the setting")

    # and a host who wants it can still have it -- at least one preset arms it.
    # Searched over the whole file rather than a window after the word
    # "lockdown", which matches the help text long before it matches the preset.
    src = io.open(SCRIPTS / "Settings.lua", encoding="utf-8").read()
    assert "alarmlock = true" in src, (
        "no preset arms the automatic lock any more, so a host who wants an "
        "unattended server has to set it by hand")


def every_phase_boundary_takes_a_snapshot():
    """prep start, build start, build end, buffer end -- each one saves.

    "the save shall happen on those times: prep time start, build time start,
    build time end, buffer end. all those shall happen besides the auto saving."

    Better than a timer alone: an autosave lands wherever the clock happens to
    be, but these land on the moments you would actually want to roll back TO --
    before anyone built, the starting line, the builds exactly as the clock
    stopped them, and the finished event.
    """
    import re
    world = io.open(SCRIPTS / "World.lua", encoding="utf-8").read()
    table = world[world.index("local PHASE_SNAPSHOT = {"):]
    table = table[:table.index("}")]

    for phase, label in [("prep", "prepstart"), ("build", "buildstart"),
                         ("buffer", "buildend"), ("ended", "eventend")]:
        assert re.search(phase + r'\s*=\s*"' + label + '"', table), (
            f"the {phase} phase does not take a {label} snapshot")

    # and it must fire before the protection change, or the buffer snapshot
    # records a world that has already been shut rather than the builds as they
    # stood when the clock stopped
    fn = world[world.index("function World.sv_e_swEventPhase"):]
    fn = fn[:fn.index(chr(10) + "end")]
    take = fn.index("sv_beginCapture")
    lock = fn.index("sv_setMode")
    assert take < lock, (
        "the phase snapshot is taken after the protection change -- it would "
        "record the locked world, not the one that just finished")

    # exactly one capture per phase change: the old hard-coded eventend one had
    # to go or `ended` would start two on top of each other
    assert fn.count("sv_beginCapture") == 1, (
        f"{fn.count('sv_beginCapture')} captures in one phase change")


def a_dead_event_does_not_resurrect_itself_on_every_load():
    """An event that expired while the game was shut lands on `ended`, once.

    MEASURED from the log at load:

        event resumed: build, 00:00 left
        event buffer -> protection polish

    sv_advance set the next deadline from `now` instead of from the previous
    deadline, so an event that had been over for hours resumed, saw build was
    finished, and started a FRESH five minute buffer counted from the moment the
    world loaded. Buffer is the polish profile -- no placing, no breaking -- so
    every load dropped the world into a window where the remove tool showed no
    red preview and nothing could be built.

    Reported as "still broken red colour". It was the event clock.
    """
    lua = fresh("Event.lua")
    E = lua.globals().Event
    ev = lua.eval("Event()")
    E.sv_onCreate(ev, None)

    T0 = 1000000.0
    E.sv_start(ev, 2, 5, T0, 5)          # 2 prep, 5 build, 5 buffer = 12 minutes
    assert str(ev["phase"]) == "prep"

    # come back a whole day later
    later = T0 + 24 * 60 * 60
    landed = E.sv_advance(ev, later)
    assert str(ev["phase"]) == "ended", (
        f"a day-old event resumed into {ev['phase']!r} -- it should be over. "
        "If it lands in buffer it starts a fresh polish window on every load, "
        "and nothing can be built or removed until it expires again.")
    assert str(landed) == "ended", f"sv_advance reported {landed!r}"
    assert ev["deadline"] is None, "an ended event still holds a deadline"

    # and it must not do it again next load
    again = E.sv_advance(ev, later + 60)
    assert again is None, "an ended event advanced a second time"

    # the ordinary case still works: each phase runs its own length, in order
    ev2 = lua.eval("Event()")
    E.sv_onCreate(ev2, None)
    E.sv_start(ev2, 2, 5, T0, 5)
    assert str(E.sv_advance(ev2, T0 + 2 * 60)) == "build", "prep did not end on time"
    assert str(E.sv_advance(ev2, T0 + 7 * 60)) == "buffer", (
        "build should end 7 minutes in -- 2 prep plus 5 build -- and the buffer "
        "must be measured from THAT moment, not from when the tick happened")
    assert str(E.sv_advance(ev2, T0 + 12 * 60)) == "ended", "buffer did not end on time"


def the_clock_survives_a_restart():
    lua, E, ev = event_lua()
    T = 2_000_000
    E.sv_start(ev, 10, 60, T)
    E.sv_advance(ev, T + 10 * 60)               # into build
    E.Sv_SaveFile(ev)

    lua2 = restart(lua, "Event.lua")
    E2 = lua2.globals().Event
    again = lua2.eval("Event()")
    E2.sv_onCreate(again, E2.Sv_LoadFile())
    assert again["phase"] == "build", "the phase was lost on reload"
    left = E2.sv_remaining(again, T + 20 * 60)
    assert abs(left - 50 * 60) < 1, (
        f"after a restart 50 minutes should be left, got {left} -- a deadline "
        f"stored in ticks would read as garbage here")


def pausing_stops_the_clock():
    lua, E, ev = event_lua()
    T = 3_000_000
    E.sv_start(ev, 0, 60, T)
    E.sv_pause(ev, T + 10 * 60)
    assert E.sv_paused(ev) is True
    left = E.sv_remaining(ev, T + 10 * 60)
    # an hour of wall clock passes while paused and nothing moves
    assert E.sv_remaining(ev, T + 70 * 60) == left, "the clock ran while paused"
    assert E.sv_advance(ev, T + 70 * 60) is None, "a paused event ended anyway"
    E.sv_resume(ev, T + 70 * 60)
    assert E.sv_paused(ev) is False
    assert abs(E.sv_remaining(ev, T + 70 * 60) - left) < 1


def time_can_be_added_and_taken_away():
    lua, E, ev = event_lua()
    T = 4_000_000
    E.sv_start(ev, 0, 60, T)
    E.sv_addMinutes(ev, 15, T)
    assert abs(E.sv_remaining(ev, T) - 75 * 60) < 1
    E.sv_addMinutes(ev, -30, T)
    assert abs(E.sv_remaining(ev, T) - 45 * 60) < 1
    # never past zero
    E.sv_addMinutes(ev, -999, T)
    assert E.sv_remaining(ev, T) >= 0


def the_five_minute_handover_is_exact():
    # The warehouse timer's own span is WAREHOUSE_DESTRUCTION_TICKS = 40*60*5,
    # and NotificationManager splits exactly that into three alarms. Hand over at
    # any other number and the alarms are out of step with the clock on screen.
    lua, E, ev = event_lua()
    T = 5_000_000
    assert E.PANIC_SECONDS == 300, f"panic window is {E.PANIC_SECONDS}, not five minutes"
    E.sv_start(ev, 0, 60, T)
    assert E.sv_panicking(ev, T) is False
    assert E.sv_panicking(ev, T + 54 * 60 + 59) is False, "panicked at 5:01 left"
    assert E.sv_panicking(ev, T + 55 * 60) is True, "did not panic at exactly 5:00 left"
    assert E.sv_panicking(ev, T + 59 * 60) is True
    # and never during prep, however little of it is left
    E.sv_start(ev, 10, 60, T)
    assert E.sv_panicking(ev, T + 9 * 60 + 59) is False, "panicked during prep"


def each_time_call_happens_once():
    lua, E, ev = event_lua()
    T = 6_000_000
    E.sv_start(ev, 0, 60, T)
    calls = []
    # walk the whole hour a second at a time, exactly as the server does
    for sec in range(0, 60 * 60 + 5):
        c = E.sv_dueCall(ev, T + sec)
        if c:
            calls.append((int(c), sec))
    got = [c for c, _ in calls]
    assert got == [30, 15, 10, 5, 2, 1], f"calls were {got}"
    assert len(set(got)) == len(got), "a call was made twice"


def the_clock_reads_the_way_a_clock_should():
    lua, E, ev = event_lua()
    for seconds, want in ((0, "00:00"), (5, "00:05"), (59, "00:59"), (60, "01:00"),
                          (3599, "59:59"), (3600, "1:00:00"), (3661, "1:01:01")):
        got = E.Clock(seconds)
        assert got == want, f"{seconds}s read as {got!r}, expected {want!r}"
    assert E.Clock(None) == "--:--"


def the_client_state_is_small_and_complete():
    lua, E, ev = event_lua()
    T = 7_000_000
    E.sv_start(ev, 0, 60, T)
    st = dict(E.sv_clientState(ev, T + 56 * 60))
    assert set(st) == {"phase", "remaining", "paused", "panic"}, (
        f"the per-second broadcast carries {sorted(st)} -- keep it small")
    assert st["phase"] == "build" and st["panic"] is True


# --------------------------------------------------------------- plumbing ---
#
# A button that does nothing looks exactly like a button that works, because the
# panel used to shut either way.
#
# REPORTED: "you should fix the buttons. since they sadly dont work. like I mean
# I press them and menu closes." There was exactly one dead button in the build
# and it was CLEAR CITY: the panel sent "/citycensus" to the world and nothing in
# World.sv_e_swCommand answered it, so the panel closed and the world did
# nothing. The command was written on one side of the bridge only.
#
# These two checks walk the bridge from both ends. They are string matching, not
# execution -- the network and the world are the engine's -- but a name that
# appears on one side and nowhere on the other is always a bug, and it is the
# exact bug that shipped.

def read(name):
    return io.open(SCRIPTS / name, encoding="utf-8").read()


def only_one_interactive_gui_exists():
    """All the panels share a single jsonGui object.

    A json GUI has no destroy(). close() hides it and the object stays, so one
    per panel meant six live interactive GUIs on one client script -- something
    no vanilla script does. Vanilla creates ONE and re-renders it when the
    content changes (HideoutTrader.lua:1242).

    REPORTED with a screenshot of the menu: "these buttons dont work for no
    reason. I am the host." The three host entries all try to open a SECOND
    panel; the four guest entries above them answer in chat. The ones that
    worked were exactly the ones that never needed a second GUI.
    """
    import re
    game = read("Game.lua")
    made = re.findall(r"(\w+)\s*=\s*sm\.jsonGui\.createGui\(([^)]*)\)", game)
    interactive = [f for f, opts in made if "isInteractive = true" in opts]
    assert interactive, "no interactive GUI is created at all"
    # probeGui is /guitest, a diagnostic that is only ever up on its own.
    allowed = {"panelGui", "probeGui"}
    extra = sorted(set(interactive) - allowed)
    assert not extra, (
        "more than one interactive jsonGui object: " + ", ".join(extra) +
        ". They share self.cl.panelGui -- see Game.cl_showPanel.")


def no_gui_callback_touches_its_own_panel():
    """A widget callback must never close OR redraw its own panel.

    THE bug behind three versions of "the buttons dont work", and it is one line
    of ordering:

        function Game.cl_onMenuClick( self, widgetName, data )
            self:cl_closeMenu()                                 -- destroys
            self.network:sendToServer( "sv_n_menuOpen", ... )   -- never runs

    close() destroys the widget whose onClick is currently on the Lua stack and
    the engine tears the callback down with it, so every statement after the
    close is dead. The log signs it:

        ERROR: ASSERT: 'itrStackWalk != m_vecLastMethodStack.rend()' : LuaVM.cpp:716

    Vanilla always sends first and closes last (CreativePlayer.lua:48). We now do
    better than remembering to: closes are QUEUED and drained on the next tick,
    so a widget cannot be destroyed while its own callback is running.

    This asserts the queue is the only route, because the ordering rule is the
    kind that gets forgotten the next time a handler is added.
    """
    import re
    game = read("Game.lua")
    # A function body runs to the first "end" at column 0; every nested block in
    # this file is indented with tabs, so that terminator is unambiguous.
    bodies = re.findall(r"\nfunction Game\.(cl_on\w+)\([^\n]*\n(.*?)\nend\n",
                        game, re.S)
    assert bodies, "no cl_on* handlers found -- the parse is wrong, not the code"
    offenders = []
    for name, body in bodies:
        for call in re.findall(r"cl_close\w+", body):
            if call != "cl_closeLater":
                offenders.append(f"{name} calls {call}")
        # A REDRAW is the same hazard. Building a new tree destroys every widget
        # the old one had, including the one whose callback is running. For a
        # click that silently killed the handler; for an EditBox, which also
        # holds the keyboard focus, it crashed the game outright --
        # "game crashed when I tried to change the number of build time",
        # and the log ends mid-line with no error and no shutdown.
        if "cl_showPanel(" in body:
            offenders.append(f"{name} renders directly -- use cl_renderLater")
    assert not offenders, (
        "a GUI callback touches its own panel; the widget running the callback "
        "is destroyed underneath it. Use cl_closeLater / cl_renderLater. "
        + "; ".join(offenders))

    assert "self:cl_drainRenders()" in game, (
        "nothing drains the deferred render queue, so a queued redraw would "
        "never happen")

    assert "self:cl_drainCloses()" in game, (
        "nothing drains the deferred close queue, so panels queued for closing "
        "would stay open forever")
    tick = game[game.index("function Game.client_onFixedUpdate"):]
    assert "cl_drainCloses" in tick[:600], (
        "cl_drainCloses is not called early in client_onFixedUpdate")
    assert "cl_drainRenders" in tick[:600], (
        "cl_drainRenders is not called early in client_onFixedUpdate")


def every_command_a_panel_sends_is_answered():
    import re
    game, world = read("Game.lua"), read("World.lua")
    sent = set(re.findall(r'sv_toWorld\(\s*"([^"]+)"', game))
    assert sent, "no sv_toWorld calls found -- the parse is wrong, not the code"
    handled = set(re.findall(r'cmd == "([^"]+)"', world))
    dead = sorted(sent - handled)
    assert not dead, (
        f"Game.lua sends {dead} to the world and World.sv_e_swCommand has no "
        "branch for it. The panel will close and nothing will happen.")


# WHICH PANEL REACHES EACH CHAT COMMAND. The ledger for
# every_command_is_on_the_menu below.
#
# REPORTED: "you have a bit too many commands that are not on menu? you know.
# the point of menu was so theres no need to use the command line besides the
# stuff you know /menu . I want the MENU to be the menu."
#
# Fair, and it had drifted a long way: 49 bound commands against 9 menu entries,
# with /lockdown -- the panic button -- among the ones with no button at all.
MENU_PATH = {
    "/menu": "the front door itself",
    "/myplot": "MY PLOT",
    "/plotmenu": "CITY LAYOUT",      # NOT an alias of /myplot -- see Game.lua
    "/plot": "MY PLOT -- CLAIM and GIVE IT UP",
    "/home": "MY PLOT -- FIND MY PLOT",
    "/why": "MY PLOT -- WHY CANNOT I BUILD",
    "/budget": "MY PLOT -- MY LIMITS",
    "/rules": "SERVER RULES",
    "/players": "WHO IS HERE",
    "/kick": "WHO IS HERE -- KICK",
    "/ban": "BANS -- the BAN button on a row",
    "/unban": "BANS -- the UNBAN button on a row",
    "/banlist": "BANS -- the BANNED view",
    "/known": "BANS -- the EVERYONE SEEN view, which is what it opens on",
    "/allow": "WHO IS HERE -- ALLOW",
    "/unallow": "WHO IS HERE -- REMOVE",
    "/allowlist": "SERVER SETTINGS -- the allowlist toggle",
    "/event": "EVENT CLOCK",
    "/buildtime": "EVENT CLOCK",
    "/protection": "PROTECTION -- the readout is the panel",
    "/lockdown": "PROTECTION -- LOCK DOWN",
    "/unlock": "PROTECTION -- UNLOCK",
    "/nolift": "PROTECTION -- CLEAR STRANDED LIFTS",
    "/clearclay": "PROTECTION -- CLEAR CLAY AROUND ME",
    "/snapshot": "BACKUPS -- SAVE NOW",
    "/snapshots": "BACKUPS -- the list is the panel",
    "/restore": "BACKUPS -- RESTORE",
    "/autosave": "SERVER SETTINGS -- the autosave row",
    "/plots": "CITY LAYOUT",
    "/plotgrid": "CITY LAYOUT",
    "/plotbuild": "CITY LAYOUT -- BUILD CITY",
    "/plotclear": "CITY LAYOUT -- CLEAR CITY",
    "/citystyle": "CITY STYLE",
    "/set": "SERVER SETTINGS",
    "/settings": "SERVER SETTINGS",
    "/settingslist": "SERVER SETTINGS",
    "/preset": "SERVER SETTINGS -- the presets",
    "/focus": "FOCUS PLAYER",
    "/unfocus": "FOCUS PLAYER -- STOP",
    "/check": "TESTING CHECKLIST",
    "/developer": "SERVER SETTINGS -- the developer row, under OTHER",
    "/crowd": "DEV TOOLS -- FAKE CROWD",
    "/bench": "DEV TOOLS -- BENCHMARK",
    "/bridge": "DEV TOOLS -- OUTSIDE CONTROL",
}

# The ones that stay typed, each with the reason. Short on purpose: this is the
# list somebody has to justify adding to.
CHAT_ONLY = {
    # COMMANDS was a menu entry until V65 and lost its place to BANS. The column
    # has a hard ceiling -- the canvas is 720 units tall -- so something had to
    # go, and of everything on that panel this was the only entry whose entire
    # content is obtainable by typing the thing it describes. Guests cannot type
    # it at all any more, so it was a host reading a list of host commands.
    "/sw": "a list of chat commands, for the one person who may type them. "
           "Every control it names has a button of its own; this is the index, "
           "and an index you can only reach by typing is no worse than the "
           "commands it indexes",
    "/swhelp": "the same list under a second name, for whichever one you "
               "reach for first",
    "/guitest": "a probe, not a feature -- five client-side experiments that "
                "re-establish whether json GUI buttons work at all after a game "
                "update. A button for it would be circular",
    "/bptest": "a probe: can Lua read a blueprint file. Reads only",
    "/bptest2": "a probe: will the engine blueprint browser open. May crash, "
                "which is exactly why it is not one press away",
    "/tool": "a diagnostic -- what is in your hand and what gates it. Its "
             "answer is a chat log to paste, not a control",
    "/purge": "the typed side of the Cleaner tool, and deliberately typed. "
              "Both ignore every permission flag, which is what makes them the "
              "only things that can remove stuck litter -- but the Cleaner "
              "needs something to point AT, and /purge covers what it cannot "
              "reach: a whole plot, a radius, or whatever you are carrying. "
              "The SWEEP LITTER button was taken off the city panel on the "
              "owner's instruction -- 'it just doesnt work as intended and "
              "just deletes stuff' -- and putting the same shape back behind a "
              "different label would undo that decision",
}


def every_command_is_on_the_menu():
    """"I want the MENU to be the menu."

    Every chat command is either reachable from a panel or explicitly listed as
    chat-only WITH a reason. A new command that is neither fails this, which is
    the point: the drift that produced the report was nine menu entries against
    forty-nine commands, and nothing anywhere said that was wrong.

    This is a ledger rather than a reachability proof -- it cannot follow a
    button through the network to a world branch. What it does do is force a
    decision, and the decision is the thing that was missing.
    """
    import re
    bound = set()
    for name in ("Game.lua", "World.lua"):
        bound |= set(re.findall(r'bindChatCommand\(\s*"([^"]+)"', read(name)))
    assert len(bound) > 30, f"only found {len(bound)} commands -- the scan is wrong"

    classified = set(MENU_PATH) | set(CHAT_ONLY)

    missing = sorted(bound - classified)
    assert not missing, (
        "these commands are neither on a panel nor listed as deliberately "
        f"chat-only: {missing}. Put them on a panel, or add them to CHAT_ONLY "
        "with the reason -- 'the point of menu was so theres no need to use the "
        "command line'")

    stale = sorted(classified - bound)
    assert not stale, (
        f"the ledger names commands that no longer exist: {stale}")

    overlap = sorted(set(MENU_PATH) & set(CHAT_ONLY))
    assert not overlap, f"listed as both on a panel and chat-only: {overlap}"

    for cmd, why in CHAT_ONLY.items():
        assert len(why) > 20, f"{cmd} is chat-only with no real reason given"

    # And the panels it names have to be entries the menu actually offers, or
    # the ledger is describing a menu that does not exist.
    lua = gui_lua()
    labels = {str(e["label"]) for e in lua.globals().MenuGui.ENTRIES.values()}
    for cmd, where in MENU_PATH.items():
        head = where.split(" -- ")[0]
        if head in ("the front door itself", "CITY STYLE"):
            continue          # the hub itself, and a panel reached from another
        assert head in labels, (
            f"{cmd} claims to be on {head!r}, which is not a menu entry. "
            f"The menu offers {sorted(labels)}")


def every_button_reaches_a_branch():
    """Every action a panel can emit is named in the script that handles clicks."""
    import re
    game = read("Game.lua")
    panels = ["MenuGui.lua", "PlotsGui.lua", "SettingsGui.lua",
              "EventGui.lua", "MyPlotGui.lua", "ConfirmGui.lua", "StyleGui.lua",
              "FocusGui.lua", "ChecklistGui.lua", "ProtectionGui.lua",
              "BackupsGui.lua", "PeopleGui.lua", "DevGui.lua", "DevGui.lua"]
    orphans = []
    for name in panels:
        for action in sorted(set(re.findall(r'action = "([^"]+)"', read(name)))):
            # Handled means the literal is tested or forwarded somewhere in the
            # game script -- as data.action == "x", or in a lookup table.
            if f'"{action}"' not in game:
                orphans.append(f"{name}:{action}")
    assert not orphans, (
        f"{len(orphans)} button action(s) are never named in Game.lua, so "
        f"pressing them does nothing: {orphans}")


# ------------------------------------------------------------------ fonts ---
#
# Scrap Mechanic does not ship whole fonts. It ships a GLYPH ATLAS per font,
# built from the strings the game itself renders, and anything outside that set
# draws as a hollow box. A mod writes strings the game has never seen, so this is
# a trap laid specifically for mods.
#
# MEASURED, from a screenshot of the menu:
#
#     we wrote            it drew
#     HOST                (X)OST
#     YOU OWN             (X)O(X) OW(X)
#     TOP DOWN            TO(X) DOW(X)
#     YOUR TEAM           (X)O(X)R TEA(X)
#
# All four in SM_LabelMini, whose atlas is exactly:  0123456789ACDEILORSTVW
# Every missing letter is a letter outside that set. Five strings, five exact
# matches, no exceptions -- so the atlas is authoritative for a font that is
# real and limited.
#
# A font name that does not exist is NOT safe, and an earlier version of this
# file said it was. MyGUI does fall back to a complete font, so the text draws --
# but the engine writes an error AND A FULL LUA TRACEBACK every single time it
# renders that widget. MEASURED, from the 24 Aug log:
#
#   [Gui] ERROR: MyGUI_FontManager.cpp:101 | Font 'SM_HeaderSmall_Medium' not
#                found. Replaced with default font.
#   [Lua] ----- Lua Error Traceback -----
#         Game.lua:620: in function 'cl_updateEventHud'
#
# once a second, for the whole session, because the event HUD redraws once a
# second. Log spam is this project's largest measured performance bug (see the
# 1.79 GB single-player log in CLAUDE.md), so "it renders" is not the bar. The
# bar is that the font EXISTS.
#
# Two files together are the font registry, and neither is complete on its own:
# ManualFontDataInput.xml declares most of them, and LimitedFontData.xml names
# eleven more (SM_Label, SM_NumberSmall, SM_LabelSmall, SM_Tab ...) that are real
# and glyph-limited. A font absent from BOTH is the one that spams.

GAME = pathlib.Path(r"D:\SteamLibrary\steamapps\common\Scrap Mechanic")
ATLAS = GAME / "Cache" / "Fonts" / "English" / "LimitedFontData.xml"
FONTDEF = GAME / "Gui" / "Fonts" / "ManualFontDataInput.xml"


def font_tables():
    """(limited: name -> set of codepoints, real: set of names). Empty if no install."""
    import re
    if not ATLAS.is_file():
        return None, None
    limited = {}
    text = io.open(ATLAS, encoding="utf-8", errors="replace").read()
    # Split on ResourceWrapper: a font with no <Codes> must not swallow the
    # next one's ranges, which is exactly the bug a lazy regex makes here.
    for block in text.split("<ResourceWrapper>"):
        m = re.search(r'name="([^"]+)"', block)
        if not m:
            continue
        ranges = re.findall(r'range="(\d+) (\d+)"', block)
        if not ranges:
            continue                      # not glyph-limited
        chars = set()
        for a, b in ranges:
            chars.update(range(int(a), int(b) + 1))
        limited[m.group(1)] = chars

    # Known = declared anywhere the engine reads. LimitedFontData names every
    # font the engine built an atlas for, including the eleven that never appear
    # in ManualFontDataInput; the union is the registry.
    known = set(re.findall(r'<Resource type="[^"]*" name="([^"]+)"', text))
    defs = GAME / "Data" / "Gui" / "Fonts" / "ManualFontDataInput.xml"
    if defs.is_file():
        known |= set(re.findall(r'name="([A-Za-z_0-9]+)"',
                                io.open(defs, encoding="utf-8", errors="replace").read()))
    return limited, known


def every_caption_can_be_drawn():
    limited, real = font_tables()
    if limited is None:
        raise AssertionError(f"no game install at {GAME} -- cannot check fonts")

    lua = gui_lua()
    captions = []          # (where, font, caption)

    def collect(where, root):
        for it in walk_full(root):
            cap, font = it.get("caption"), it.get("font")
            if cap and font:
                captions.append((where, font, cap))

    # Every panel, in the states that change what they say.
    for host in (True, False):
        for dev in (True, False):
            collect("menu(%s,dev=%s)" % (host, dev),
                    lua.globals().MenuGui.Build(host, dev))

    # The four panels V61 added. A font that is not real draws via fallback AND
    # writes a Lua traceback on every render -- 3,600 an hour for a panel that
    # redraws once a second -- so a new panel that skips this sweep is the
    # largest performance bug this project has measured, waiting to happen.
    for mode in ("open", "locked", "display"):
        collect(f"protection/{mode}", lua.globals().ProtectionGui.Build(
            lua.table_from({"mode": mode, "buildopen": mode == "open",
                            "bubble": "open, 4.0m around the host",
                            "guest": "lift claygun", "host": "nothing",
                            "physics": "9", "status": "locked the world"})))
    collect("protection/clock", lua.globals().ProtectionGui.Build(
        lua.table_from({"mode": "display", "buildopen": False,
                        "bubble": "shut -- somebody is standing in it",
                        "clock": "build", "status": ""})))

    for saves in ([], [{"name": "buildend-2026-08-24_2222", "count": 195},
                       {"name": "manual-2026-08-31_1200", "count": 12}]):
        collect(f"backups/{len(saves)}", lua.globals().BackupsGui.Build(
            lua.table_from({
                "saves": lua.table_from([lua.table_from(r) for r in saves]),
                "autosave": 10, "status": "saved"})))
    collect("backups/busy", lua.globals().BackupsGui.Build(lua.table_from({
        "saves": lua.table_from([]), "autosave": 0,
        "busy": "restoring: 40 of 195", "status": ""})))

    people = [{"id": 1, "name": "CyberSlime2077", "perma": "p1", "host": True},
              {"id": 2, "name": "A Guest", "perma": "p2", "plot": 7,
               "allowed": True},
              {"id": 3, "name": "Someone Else", "perma": "p3", "bot": True}]
    bans = [{"perma": "p9", "name": "A Griefer", "reason": "wrecked the plaza"}]
    known = [{"perma": "SW-0001", "name": "CyberSlime2077", "aliases": 0},
             {"perma": "SW-0009", "name": "A Griefer", "aliases": 3,
              "banned": True}]
    for host in (True, False):
        for view in ("here", "bans", "known"):
            for allowlist in (True, False):
                collect(f"people/{host}/{view}/{allowlist}",
                        lua.globals().PeopleGui.Build(lua.table_from({
                            "host": host, "view": view, "allowlist": allowlist,
                            "players": lua.table_from(
                                [lua.table_from(r) for r in people]),
                            "bans": lua.table_from(
                                [lua.table_from(r) for r in bans]),
                            "known": lua.table_from(
                                [lua.table_from(r) for r in known]),
                            "status": "kicked somebody"})))
    for view in ("here", "bans", "known"):
        collect(f"people/empty/{view}", lua.globals().PeopleGui.Build(lua.table_from({
            "host": True, "view": view, "players": lua.table_from([]),
            "known": lua.table_from([]), "bans": lua.table_from([])})))
    # ...and the emptiness that is a filter miss rather than an empty server,
    # which is a different sentence and therefore a different set of glyphs.
    collect("people/nomatch", lua.globals().PeopleGui.Build(lua.table_from({
        "host": True, "view": "known", "query": "qqq",
        "known": lua.table_from([lua.table_from(known[0])])})))

    for mode in ("build", "churn", "off"):
        for bridge in (True, False):
            collect(f"dev/{mode}/{bridge}", lua.globals().DevGui.Build(
                lua.table_from({"bots": 40, "mode": mode, "bridge": bridge,
                                "bench": "running: stage 4 of 14",
                                "status": "crowd set to 40"})))
    collect("dev/empty", lua.globals().DevGui.Build(lua.table_from({})))

    G = lua.globals().SettingsGui
    values = lua.table_from({row["key"]: row["default"]
                             for row in lua.globals().Settings.SCHEMA.values()})
    for g in [x["key"] for x in G.GROUPS.values()]:
        for page in range(1, int(G.PageCount(g)) + 1):
            collect(f"settings/{g}", G.Build(values, g, page))

    cfg = {"plot": 20, "gap": 1, "cols": 10, "rows": 10, "roadevery": 0,
           "roadwidth": 6, "plazacells": 2, "claimed": {}}
    collect("city", lua.globals().PlotsGui.Build(lua.table_from(
        {k: (lua.table_from(v) if isinstance(v, dict) else v) for k, v in cfg.items()})))

    for piece in ("pad", "border", "road", "plaza", "stand"):
        collect(f"style/{piece}", lua.globals().StyleGui.Build(style_state(lua, piece)))
    # and the state a host reaches with /set padcolour ff00ff -- a colour with no
    # swatch on the grid, whose name is the hex itself
    collect("style/rawhex", lua.globals().StyleGui.Build(
        style_state(lua, "pad", padcolour="ff00ff")))

    st = lua.table_from({"plotsOn": True, "mine": 34,
                         "standing": lua.table_from({"kind": "plot", "index": 34,
                                                     "free": False, "mine": True}),
                         "cfg": lua.table_from(
                             {k: (lua.table_from(v) if isinstance(v, dict) else v)
                              for k, v in cfg.items()})})
    collect("myplot", lua.globals().MyPlotGui.Build(st))

    for phase in ("off", "prep", "build", "buffer", "ended"):
        collect(f"event/{phase}", lua.globals().EventGui.Build(lua.table_from(
            {"phase": phase, "remaining": 754.0, "prep": 10, "build": 60, "buffer": 5})))
    for step in (1, 2):
        collect(f"confirm/{step}", lua.globals().ConfirmGui.Build(lua.table_from(
            {"step": step, "title": "DELETE THE WHOLE CITY?",
             "lines": lua.table_from(["96 plots in the city, 41 claimed",
                                      "12406 blocks built on them",
                                      "by 9 different players"])})))
    for phase in ("off", "prep", "build", "buffer", "ended"):
        collect(f"eventhud/{phase}", lua.globals().EventHud.Build(
            lua.table_from({"phase": phase, "remaining": 754.0, "panic": phase == "build"}),
            1920, 1080))

    # The top-left roster. Two states, because a four digit resident count is
    # a different string from a one digit one and a glyph-limited font can
    # fail on one and not the other.
    for state in ({"online": 0, "residents": 0},
                  {"online": 12, "residents": 3407},
                  # and with the FOCUS strip up, which is a third row of
                  # captions that only exists while somebody is marked
                  {"online": 12, "residents": 3407, "focus": "JuneCarya"}):
        collect("rosterhud", lua.globals().RosterHud.Build(
            lua.table_from(state), 1920, 1080))

    # The focus panel, in the four states it has: nobody online, a list, a
    # search that matched nothing, and somebody focused.
    FOCUS_ROSTER = [{"id": 1, "name": "JuneCarya", "perma": "SW-0001", "plot": 14},
                    {"id": 2, "name": "Quintuple X", "perma": "SW-0002"},
                    {"id": 3, "name": "zeb", "perma": "SW-0003", "plot": 2}]
    for label, state in (
            ("empty", {}),
            ("list", {"players": FOCUS_ROSTER, "bots": 40}),
            ("nomatch", {"players": FOCUS_ROSTER, "query": "qqq"}),
            ("focused", {"players": FOCUS_ROSTER,
                         "focus": {"id": 1, "name": "JuneCarya"},
                         "status": "focusing JuneCarya"})):
        state = dict(state)
        if "players" in state:
            state["players"] = lua.table_from(
                [lua.table_from(r) for r in state["players"]])
        if "focus" in state:
            state["focus"] = lua.table_from(state["focus"])
        collect(f"focusgui/{label}",
                lua.globals().FocusGui.Build(lua.table_from(state)))

    assert captions, "no captions collected -- the panels built nothing"

    bad, ghosts = [], set()
    for where, font, cap in captions:
        if font not in real:
            # Draws, via fallback -- and logs an error with a traceback on every
            # single render while it does. See the note above this function.
            ghosts.add(f"{where} [{font}]")
            continue
        allowed = limited.get(font)
        if allowed is None:
            continue                       # real and not glyph-limited: safe
        missing = sorted({c for c in str(cap) if ord(c) not in allowed})
        if missing:
            bad.append((where, font, str(cap)[:44], "".join(missing)))

    if ghosts:
        raise AssertionError(
            f"{len(ghosts)} widget(s) name a font the game does not have. It "
            "renders via fallback and logs a MyGUI error plus a Lua traceback "
            "on EVERY redraw: " + ", ".join(sorted(ghosts)[:6]))
    if bad:
        lines = [f"{w} [{f}] {c!r} cannot draw: {m}" for w, f, c, m in bad[:6]]
        raise AssertionError(
            f"{len(bad)} caption(s) use glyphs their font does not have. "
            + " | ".join(lines))


# -------------------------------------------------------------------- gui ---
#
# A json GUI is a plain nested table of rectangles, so its layout can be checked
# without rendering anything. This is worth doing because it is a bug this
# project keeps having: a panel is widened, a row count changes, and something
# ends up under the footer or off the edge where nobody can click it. Three
# times so far, each found by hand.
#
# What is NOT checked: whether a skin exists, whether a font is real, whether the
# thing looks any good. Only geometry -- which is the part that has actually gone
# wrong.

FOOTER_H = 44          # the strip along the bottom the close/confirm row lives in


def walk(node, out, depth=0):
    """Flatten a widget tree to (name, x, y, w, h, type, depth, clickable)."""
    name = node["Name"] if "Name" in node else "?"
    x, y = node["x"] or 0, node["y"] or 0
    w, h = node["width"] or 0, node["height"] or 0
    out.append(dict(name=name, x=x, y=y, w=w, h=h,
                    type=node["Type"], depth=depth,
                    click=node["onClick"] is not None))
    kids = node["Childs"]
    if kids is not None:
        for k in kids.values():
            walk(k, out, depth + 1)
    return out


def walk_full(node, out=None):
    """Like walk(), but keeps Caption and FontName so fonts can be checked."""
    if out is None:
        out = []
    out.append(dict(name=node["Name"] if "Name" in node else "?",
                    caption=node["Caption"], font=node["FontName"]))
    kids = node["Childs"]
    if kids is not None:
        for k in kids.values():
            walk_full(k, out)
    return out


def panel_fits(label, root, W, H):
    items = walk(root, [])
    assert len(items) > 3, f"{label}: only {len(items)} widgets, the panel is empty"
    for it in items[1:]:                        # [0] is the root itself
        assert it["x"] >= 0 and it["y"] >= 0, (
            f"{label}: {it['name']} starts off the panel at ({it['x']},{it['y']})")
        assert it["x"] + it["w"] <= W, (
            f"{label}: {it['name']} runs {it['x'] + it['w'] - W}px past the right edge")
        assert it["y"] + it["h"] <= H, (
            f"{label}: {it['name']} runs {it['y'] + it['h'] - H}px past the bottom")
    return items


def no_button_is_buried(label, items, H):
    """Every clickable thing must be reachable: on the panel, and not overlapping
    another clickable thing. A button under another button cannot be pressed."""
    buttons = [i for i in items if i["click"]]
    assert buttons, f"{label}: no clickable widget at all"
    for a, b in ((a, b) for i, a in enumerate(buttons) for b in buttons[i + 1:]):
        overlap = (a["x"] < b["x"] + b["w"] and a["x"] + a["w"] > b["x"]
                   and a["y"] < b["y"] + b["h"] and a["y"] + a["h"] > b["y"])
        assert not overlap, (
            f"{label}: buttons {a['name']!r} and {b['name']!r} overlap -- one of "
            f"them cannot be pressed")


def walk_raw(node, out=None):
    """Every widget in the tree, as its raw property table.

    walk() flattens to geometry and walk_full() keeps captions; neither can see
    a property like Static, which is the whole difference between a box you can
    type in and one you cannot.
    """
    out = [] if out is None else out
    if node is None:
        return out
    out.append(node)
    childs = node["Childs"]
    if childs is not None:
        for child in childs.values():
            walk_raw(child, out)
    return out


def gui_lua():
    lua = fresh("Layout.lua", "Palette.lua", "Settings.lua", "Event.lua", "EventHud.lua",
                "RosterHud.lua", "EventGui.lua", "ConfirmGui.lua",
                "SettingsGui.lua", "PlotsGui.lua", "MenuGui.lua", "MyPlotGui.lua",
                "StyleGui.lua", "FocusGui.lua", "ProtectionGui.lua", "BackupsGui.lua", "PeopleGui.lua", "DevGui.lua",
                "Checklist.lua", "ChecklistGui.lua")
    lua.globals().Settings.Sv_Load(False)
    return lua


def the_menu_panel_fits():
    lua = gui_lua()
    # Developer mode adds two host entries, so the tallest column this panel can
    # ever draw is the one nobody sees by default. Checking only the default is
    # how a panel overflows in the one state it is hardest to notice.
    for host in (True, False):
        for developer in (False, True):
            root = lua.globals().MenuGui.Build(host, developer)
            label = ("menu (%s%s)"
                     % ("host" if host else "guest",
                        ", developer" if developer else ""))
            items = panel_fits(label, root, lua.globals().MenuGui.W,
                               lua.globals().MenuGui.H)
            no_button_is_buried(label, items, lua.globals().MenuGui.H)


def the_new_panels_fit():
    """Every panel V61 added, in the states that change its height.

    The canvas is 1720x720 -- sm.jsonGui.getViewSize(), MEASURED, and half the
    window it is drawn in -- so a panel taller than about 690 hangs off the
    bottom of the screen with no error anywhere. This is the check that has
    caught that on every panel so far, including the my-plot row the moment two
    more buttons were put on it.
    """
    lua = gui_lua()

    def fits(label, root, W, H):
        items = panel_fits(label, root, W, H)
        no_button_is_buried(label, items, H)

    P = lua.globals().ProtectionGui
    for mode in ("open", "locked", "display"):
        fits(f"protection/{mode}", P.Build(lua.table_from({
            "mode": mode, "buildopen": False, "clock": "build",
            "bubble": "open", "guest": "lift", "host": "nothing",
            "physics": "9", "status": "x"})), P.W, P.H)

    B = lua.globals().BackupsGui
    for n in (0, 3, 20):
        saves = [{"name": f"save-{i}", "count": i} for i in range(n)]
        for page in (1, 2, 99):
            fits(f"backups/{n}/{page}", B.Build(lua.table_from({
                "saves": lua.table_from([lua.table_from(r) for r in saves]),
                "page": page, "autosave": 10})), B.W, B.H)

    PG = lua.globals().PeopleGui
    rows = [{"id": i, "name": f"Player {i}", "perma": f"p{i}"} for i in range(20)]
    bans = [{"perma": f"b{i}", "name": f"Banned {i}"} for i in range(20)]
    known = [{"perma": f"SW-{i:04d}", "name": f"Seen {i}", "aliases": i % 3,
              "banned": i % 4 == 0} for i in range(40)]
    for host in (True, False):
        for view in ("here", "bans", "known"):
            for page in (1, 3, 99):
                fits(f"people/{host}/{view}/{page}", PG.Build(lua.table_from({
                    "host": host, "view": view, "page": page, "allowlist": True,
                    "players": lua.table_from([lua.table_from(r) for r in rows]),
                    "known": lua.table_from([lua.table_from(r) for r in known]),
                    "bans": lua.table_from([lua.table_from(r) for r in bans])})),
                    PG.W, PG.H)

    D = lua.globals().DevGui
    for mode in ("build", "churn", "off"):
        fits(f"dev/{mode}", D.Build(lua.table_from({
            "bots": 128, "mode": mode, "bridge": True,
            "bench": "running", "status": "x"})), D.W, D.H)


def the_settings_panel_fits_on_every_page():
    lua = gui_lua()
    G = lua.globals().SettingsGui
    values = lua.table_from({row["key"]: row["default"]
                             for row in lua.globals().Settings.SCHEMA.values()})
    groups = [g["key"] for g in G.GROUPS.values()] if G.GROUPS is not None else []
    assert groups, "SettingsGui has no groups"
    for group in groups:
        pages = int(G.PageCount(group))
        assert pages >= 1, f"group {group!r} reports {pages} pages"
        for page in range(1, pages + 1):
            root = G.Build(values, group, page)
            label = f"settings {group} p{page}/{pages}"
            items = panel_fits(label, root, G.W, G.H)
            no_button_is_buried(label, items, G.H)


def the_city_panel_fits_at_every_setting():
    # Every value the panel can be stepped to, not just the default -- the map
    # and the summary are both sized from the numbers.
    lua = gui_lua()
    G = lua.globals().PlotsGui
    base = {"plot": 20, "gap": 1, "cols": 10, "rows": 10,
            "roadevery": 0, "roadwidth": 6, "spawn": 50}
    tried = 0
    for field in G.FIELDS.values():
        key = field["key"]
        for step in field["steps"].values():
            cfg = dict(base)
            cfg[key] = step
            cfg["claimed"] = {}
            root = G.Build(lua.table_from({k: (lua.table_from(v) if isinstance(v, dict) else v)
                                           for k, v in cfg.items()}))
            label = f"city panel {key}={step}"
            items = panel_fits(label, root, G.W, G.H)
            no_button_is_buried(label, items, G.H)
            tried += 1
    assert tried >= 30, f"only exercised {tried} combinations"


ACCENT_RGB = "1 0.74 0.35 1"        # the map key's "taken" colour


def the_top_down_map_tiles_exactly():
    """No seams in the map, at any scale.

    REPORTED: "the road is crosed by frame that it shoudlnt be."

    The layout was never wrong -- dev/test_layout.py proves it is an exact
    partition and no deck piece overlaps the plaza. The DRAWING was: it floored
    the position and the size independently, so a piece ending at 149.7 was drawn
    to 149 while its neighbour starting at 149.7 was drawn from 149. Some seams
    gained a pixel, some lost one, and a partition with no holes acquired holes.

    Rounding both EDGES instead makes adjacent pieces resolve to the same
    boundary pixel by construction. MEASURED across a row: 10 seam breaks before,
    0 after, on a 10x10 grid.

    This walks a scanline through the drawn rectangles and demands they are
    contiguous from the left edge of the map to the right.
    """
    lua = fresh("Layout.lua")
    L = lua.globals().Layout
    import math

    # THE PLAZA MUST NOT WEAR THE "TAKEN" COLOUR.
    #
    # It was ACCENT orange, which the key underneath calls "taken", and it is
    # deliberately BIGGER than a plot -- with plazacells 2 it is 41 blocks across
    # against a plot's 20, because it swallows the seam between the cells it
    # covers. MEASURED: 74 px wide beside a 36 px plot. So the spawn plaza read
    # as somebody's claimed tile, of the wrong size, sitting off the grid.
    # Reported as "see? they are offset."
    src = io.open(SCRIPTS / "PlotsGui.lua", encoding="utf-8").read()
    shade = src[src.index("local SHADE = {"):]
    shade = shade[:shade.index("}")]
    plaza = shade[shade.index("plaza"):shade.index(chr(10), shade.index("plaza"))]
    assert ACCENT_RGB not in plaza, (
        "the plaza is drawn in the same colour the map key calls 'taken', so the "
        "spawn plaza reads as an oversized claimed plot sitting off the grid")
    assert "spawn plaza" in src, (
        "the map key does not name the plaza colour, so it is an unexplained "
        "block on the map")

    for cfg in ({"cols": 10, "rows": 10, "plot": 20, "roadwidth": 6, "plazacells": 2},
                {"cols": 5, "rows": 5, "plot": 20, "roadwidth": 6, "plazacells": 1},
                {"cols": 12, "rows": 8, "plot": 16, "roadwidth": 4, "plazacells": 2},
                {"cols": 3, "rows": 3, "plot": 24, "roadwidth": 0, "plazacells": 0}):
        grid = L.grid(lua.table_from(cfg))
        size = 380.0
        span = max(grid["width"], grid["height"], 1)
        scale = size / span
        ox = (size - grid["width"] * scale) * 0.5 - grid["x0"] * scale
        oy = (size - grid["height"] * scale) * 0.5 - grid["y0"] * scale

        def draw(cx, cy, cw, ch):
            x0 = math.floor(ox + cx * scale + 0.5)
            y0 = math.floor(oy + cy * scale + 0.5)
            x1 = math.floor(ox + (cx + cw) * scale + 0.5)
            y1 = math.floor(oy + (cy + ch) * scale + 0.5)
            return x0, y0, max(1, x1 - x0), max(1, y1 - y0)

        rects = []
        pieces = L.deckPieces(grid)
        for i in range(1, len(pieces) + 1):
            pc = pieces[i]
            rects.append((pc["x"], pc["y"], pc["w"], pc["h"]))
        for row in range(grid["cfg"]["rows"]):
            for col in range(grid["cfg"]["cols"]):
                r = L.plotRect(grid, col, row)
                if r:
                    rects.append((r["x"], r["y"], r["w"], r["h"]))

        # a scanline through the middle of each plot row must be covered edge to
        # edge with no gap and no overlap
        for row in range(grid["cfg"]["rows"]):
            probe = L.plotRect(grid, 0, row)
            if not probe:
                continue
            yb = probe["y"] + probe["h"] * 0.5
            spans = []
            for bx, by, bw, bh in rects:
                if by <= yb < by + bh:
                    x, _, w, _ = draw(bx, by, bw, bh)
                    spans.append((x, x + w))
            spans.sort()
            assert spans, f"cols={cfg['cols']} row {row}: nothing drawn at all"
            for (a0, a1), (b0, b1) in zip(spans, spans[1:]):
                assert a1 == b0, (
                    f"cols={cfg['cols']} plot={cfg['plot']} row {row}: the map has "
                    f"a seam -- one piece ends at px {a1} and the next starts at "
                    f"px {b0}. Layout is an exact partition, so this is the "
                    "drawing rounding position and size separately instead of "
                    "rounding both edges")


def the_city_map_never_leaves_its_box():
    # The map is drawn from real geometry scaled into a fixed square. A wide,
    # shallow city (few rows, many columns) is the case that used to push cells
    # outside the box.
    lua = gui_lua()
    G = lua.globals().PlotsGui
    MAP = 380
    x0, y0 = G.W - 28 - MAP, 108
    for cfg in ({"cols": 20, "rows": 2}, {"cols": 2, "rows": 20},
                {"cols": 1, "rows": 1}, {"cols": 20, "rows": 20, "plazacells": 3}):
        full = {"plot": 20, "gap": 1, "cols": 10, "rows": 10, "roadevery": 0,
                "roadwidth": 6, "plazacells": 2, "claimed": {}}
        full.update(cfg)
        kids = lua.eval("{}")
        G.AddMap(kids, lua.table_from({k: (lua.table_from(v) if isinstance(v, dict) else v)
                                       for k, v in full.items()}), x0, y0, MAP)
        for w in kids.values():
            if not str(w["Name"]).startswith(("md", "mp")):
                continue        # background and key text sit outside on purpose
            assert w["x"] >= x0 - 1 and w["y"] >= y0 - 1, (
                f"map cell {w['Name']} at ({w['x']},{w['y']}) is above/left of the box "
                f"({x0},{y0}) for {cfg}")
            assert w["x"] + w["width"] <= x0 + MAP + 1, (
                f"map cell {w['Name']} runs past the right of the box for {cfg}")
            assert w["y"] + w["height"] <= y0 + MAP + 1, (
                f"map cell {w['Name']} runs past the bottom of the box for {cfg}")


def the_my_plot_panel_fits_in_every_state():
    # The panel changes shape with what the player owns and what they are stood
    # on, and the hint line under the buttons changes with it. Every branch.
    lua = gui_lua()
    G = lua.globals().MyPlotGui
    cfg = {"plot": 20, "gap": 1, "cols": 10, "rows": 10, "roadevery": 0,
           "roadwidth": 6, "plazacells": 2, "claimed": {}}

    states = [
        ("plots off", {"plotsOn": False}),
        ("owns nothing, off the map", {"plotsOn": True}),
        ("owns nothing, on a free plot", {
            "plotsOn": True,
            "standing": {"kind": "plot", "index": 12, "free": True}}),
        ("owns nothing, on a taken plot", {
            "plotsOn": True,
            "standing": {"kind": "plot", "index": 12, "free": False,
                         "owner": "Somebody With A Long Name"}}),
        ("owns nothing, on the plaza", {
            "plotsOn": True, "standing": {"kind": "plaza"}}),
        ("owns one, standing on it", {
            "plotsOn": True, "mine": 34,
            "standing": {"kind": "plot", "index": 34, "free": False, "mine": True}}),
        ("owns one, big team", {
            "plotsOn": True, "mine": 34,
            "standing": {"kind": "road"},
            "team": [f"plot {i} (Player {i})" for i in range(35, 41)]}),
    ]
    for label, extra in states:
        state = dict(extra)
        state["cfg"] = cfg
        table = lua.table_from({
            k: (lua.table_from(v) if isinstance(v, dict)
                else (lua.table_from(list(v)) if isinstance(v, list) else v))
            for k, v in state.items()})
        # cfg has a nested dict of its own
        if "cfg" in state:
            table["cfg"] = lua.table_from({
                k: (lua.table_from(v) if isinstance(v, dict) else v)
                for k, v in cfg.items()})
        root = G.Build(table)
        items = panel_fits(f"my plot ({label})", root, G.W, G.H)
        no_button_is_buried(f"my plot ({label})", items, G.H)

        # The map has to actually be there. panel_fits would happily pass a
        # panel whose map drew nothing at all, and a blank square where the
        # city should be is the exact bug this panel exists to avoid.
        if extra.get("plotsOn"):
            cells = [i for i in items if str(i["name"]).startswith(("md", "mp"))]
            assert len(cells) > 50, (
                f"my plot ({label}): the map drew {len(cells)} cells -- "
                f"PlotsGui.AddMap is not being reached")


def the_event_hud_sits_in_the_top_right_at_any_resolution():
    """The clock is fully on screen, in the top right, at every canvas size.

    Asked for exactly: "take the screen resolution of the game. take the top
    right corner. take the pixels of the timer UI. make so that it is fully on
    screen. and add couple of bufer pixels."

    Two measured facts drive the arithmetic and both are easy to get wrong:

      * Anchor = "TopRight" is not a value this accepts. It is in the exe's
        string table but the widget is simply centred instead.
      * A ROOT widget's x,y is its CENTRE, from the centre of the canvas, +y
        down. Derived from SurvivalPlayer.lua:424.

    And the reason "I dont see timer": the previous version made the root the
    size of the SCREEN (sm.gui.getScreenSize) when widget units are in the
    CANVAS (sm.jsonGui.getViewSize), which is one of four fixed reference
    resolutions. On a 3440x1440 monitor the root hung far off the right of a
    narrower canvas and everything in its corner was off screen.
    """
    lua = gui_lua()
    G = lua.globals().EventHud
    W, H, margin = int(G.W), int(G.H), int(G.MARGIN)

    CANVASES = [
        (1280, 720,  "the smallest skin set the game ships"),
        (1920, 1080, "16:9"),
        (2560, 1440, "the likely canvas on the owner's 3440x1440"),
        (3840, 2160, "4K"),
        (2560, 1080, "ultrawide"),
        (1693, 693,  "the canvas implied by an old screenshot"),
    ]
    for cw, ch, label in CANVASES:
        root = G.Build(lua.table_from({"phase": "build", "remaining": 754.0}), cw, ch)

        assert root["Anchor"] == "Center", (
            f"{label}: anchored {root['Anchor']!r}; only Center is known to work")
        assert int(root["width"]) == W and int(root["height"]) == H, (
            f"{label}: the root is {int(root['width'])}x{int(root['height'])}, not "
            f"the panel's own {W}x{H}. A root sized to the screen is the bug that "
            "put the clock off the edge of the canvas.")

        # x,y is the CENTRE from the centre of the canvas, +y down. Turn that
        # back into an on-screen rectangle and check it lands where it should.
        cx, cy = float(root["x"]), float(root["y"])
        left = cw / 2 + cx - W / 2
        top = ch / 2 + cy - H / 2
        right, bottom = left + W, top + H

        assert left >= 0 and top >= 0, (
            f"{label}: the clock starts off screen at ({left:.0f},{top:.0f})")
        assert right <= cw and bottom <= ch, (
            f"{label}: the clock runs {max(right - cw, bottom - ch):.0f}px past "
            "the edge -- it would not be visible")

        # the buffer pixels, when the canvas is big enough to honour them
        if cw >= W + margin * 2 and ch >= H + margin * 2:
            assert abs((cw - right) - margin) <= 1, (
                f"{label}: {cw - right:.0f}px from the right edge, expected {margin}")
            assert abs(top - margin) <= 1, (
                f"{label}: {top:.0f}px from the top, expected {margin}")

    # And the clamp: a canvas smaller than the panel must still keep it on screen
    # rather than letting it hang off an edge.
    for cw, ch in [(W - 40, H - 10), (100, 60)]:
        x, y = G.TopRight(cw, ch)
        left = cw / 2 + float(x) - W / 2
        top = ch / 2 + float(y) - H / 2
        assert abs(left) <= 1 and abs(top) <= 1, (
            f"canvas {cw}x{ch} is smaller than the {W}x{H} panel and it was not "
            f"pinned to the corner: landed at ({left:.0f},{top:.0f})")


def the_event_hud_reads_correctly_in_every_phase():
    lua = gui_lua()
    G = lua.globals().EventHud
    for phase, want in (("off", "--:--"), ("prep", "09:14"),
                        ("build", "09:14"), ("ended", "TIME")):
        root = G.Build(lua.table_from({"phase": phase, "remaining": 554.0}), 1920, 1080)
        caps = [i["caption"] for i in walk_full(root) if i["caption"]]
        assert want in caps, f"{phase}: clock reads {caps}, expected {want!r} among them"
    # paused says so, in place of the hint
    root = G.Build(lua.table_from({"phase": "build", "remaining": 60.0, "paused": True}),
                   1920, 1080)
    caps = " ".join(str(i["caption"]) for i in walk_full(root) if i["caption"])
    assert "PAUSED" in caps, f"a paused clock does not say so: {caps!r}"


def any_number_can_be_typed_into_the_event_clock():
    """The durations accept typed numbers, not just the stepper presets.

    "allow for custom numbers from the keyboard so I can set my own time."

    A json GUI takes typed text through an EditBox with Static = false and an
    onTextEnter callback -- DigitalSign.gui's EnterTextBox is the base game's
    only example, and DigitalSign.lua:157 gives the signature
    ( self, widgetName, text ). A text event carries no onClickData, so the
    WIDGET NAME is the only thing that says which field was typed into.
    """
    lua = gui_lua()
    G = lua.globals().EventGui
    state = lua.table_from({"phase": "off", "prep": 10, "build": 60, "buffer": 5})
    root = G.Build(state)

    boxes = {}
    for node in walk_raw(root):
        # node["Type"], not node.get(...) -- a lupa table has no .get, and
        # asking for one silently resolves to the Lua key "get", which is nil.
        if node["Type"] == "EditBox":
            boxes[node["Name"]] = node
    fields = [f for f in G.FIELDS.values()]
    assert len(boxes) == len(fields), (
        f"{len(boxes)} typed boxes for {len(fields)} durations -- every duration "
        "must be typeable")

    for f in fields:
        name = str(f["box"])
        assert name in boxes, f"{f['label']} has no typed box called {name!r}"
        box = boxes[name]
        assert box["Static"] is False, (
            f"{name} is Static -- it would display the number and never accept one")
        assert box["NeedKey"] is True, f"{name} cannot take the keyboard"
        assert box["onTextEnter"] is not None, f"{name} has no onTextEnter"
        assert G.FieldForBox(name) is not None, (
            f"{name} does not map back to a field, so a typed value has nowhere "
            "to go")

    # NOTHING in the typed-time handler may touch the GUI -- not even a
    # deferred render. Two crashes came out of trying: the second was AFTER the
    # redraw was already deferred by a tick, which says the hazard is the focus
    # transfer between two EditBoxes and not the timing of our redraw.
    game = io.open(SCRIPTS / "Game.lua", encoding="utf-8").read()
    handler = game[game.index("function Game.cl_onEventTimeTyped"):]
    handler = handler[:handler.index(chr(10) + "end")]
    for banned in ("cl_showPanel", "cl_renderLater", "cl_closeLater", ":render("):
        assert banned not in handler, (
            f"cl_onEventTimeTyped calls {banned} -- typing into one box while "
            "another has focus crashed the game twice, and deferring was not "
            "enough. It must touch nothing.")

    # and what it does with what you type.
    #
    # ParseTime returns ( minutes ) when the value is taken as typed, and
    # ( minutes, reason ) when it had to clamp -- so lupa hands back a tuple for
    # the clamped cases and a bare number otherwise. Both are the same answer.
    def parsed(box, typed):
        got = G.ParseTime(box, typed)
        return got[0] if isinstance(got, tuple) else got

    prep = str(fields[0]["box"])
    build = str(fields[1]["box"])
    lo, hi = int(fields[1]["min"]), int(fields[0]["max"])

    assert parsed(prep, "37") == 37, "a plain number was not accepted"
    assert parsed(prep, " 12 min ") == 12, "a number with noise round it failed"
    assert parsed(prep, "2.6") == 3, "fractions should round to whole minutes"
    assert parsed(prep, "0") == 0, "zero prep is legal and must stay legal"
    assert parsed(build, "0") == lo, (
        "a build of zero must clamp up, not start an event with no build time")
    assert parsed(prep, "99999") == hi, "a huge number did not cap"
    assert parsed(prep, "banana") is None, "nonsense was accepted as a time"
    assert parsed("NotAField", "10") is None, "an unknown widget was accepted"

    # a clamp must SAY it clamped; a value taken as typed must stay quiet
    assert isinstance(G.ParseTime(build, "0"), tuple), (
        "clamping to the minimum happens silently -- the host would not know")
    assert not isinstance(G.ParseTime(prep, "37"), tuple), (
        "a perfectly good number produced a complaint")


def the_event_panel_fits_running_and_stopped():
    lua = gui_lua()
    G = lua.globals().EventGui
    for phase in ("off", "prep", "build", "buffer", "ended"):
        for paused in (False, True):
            st = lua.table_from({"phase": phase, "remaining": 3754.0, "paused": paused,
                                 "prep": 10, "build": 60, "buffer": 5})
            label = f"event({phase}{',paused' if paused else ''})"
            items = panel_fits(label, G.Build(st), G.W, G.H)
            no_button_is_buried(label, items, G.H)


def the_confirm_panel_puts_the_dangerous_button_somewhere_else():
    # The whole point of asking twice is that the second ask cannot be answered
    # by muscle memory, so YES on step two must NOT be where YES was on step one.
    lua = gui_lua()
    G = lua.globals().ConfirmGui
    where = {}
    for step in (1, 2):
        st = lua.table_from({"step": step, "title": "DELETE THE WHOLE CITY?",
                             "lines": lua.table_from(["96 plots", "12406 blocks"])})
        items = panel_fits(f"confirm({step})", G.Build(st), G.W, G.H)
        no_button_is_buried(f"confirm({step})", items, G.H)
        yes = [i for i in items if i["name"] == "Yes"]
        no = [i for i in items if i["name"] == "No"]
        assert yes and no, f"confirm step {step} is missing a button"
        where[step] = (yes[0]["x"], no[0]["x"])
    assert where[1][0] != where[2][0], (
        "YES is in the same place on both steps -- a double click gets through "
        "both doors, which defeats asking twice")
    assert where[2][0] == where[1][1], (
        "on the second step YES should sit where CANCEL was, so reflex lands on "
        "cancel")



# --------------------------------------------------------- the trim profile ---

def _plot_fixture(lua):
    """A real Plots, a real Protection, the real World resolver, and a body
    standing on plot 1.

    Shared by the over-budget checks below. Deliberately NOT at the origin: the
    origin is the plaza, which resolves to "sweep", and a check written there
    would pass for entirely the wrong reason.
    """
    lua.globals().Settings.Sv_Load(False)
    P, Prot = lua.globals().Plots, lua.globals().Protection

    plots = lua.eval("Plots()")
    P.sv_onCreate(plots, lua.table_from({"grid": lua.table_from({}), "enabled": True}))
    plots["enabled"] = True
    lua.globals().g_swPlots = plots

    prot = lua.eval("Protection()")
    Prot.sv_onCreate(prot, "open")
    lua.globals().g_swProtection = prot

    resolver = lua.execute("""
        return function( body )
            if g_swPlots:sv_isScenery( body ) and not Settings.CityIsOpen() then
                return "locked"
            end
            local zone = g_swPlots:sv_bodyIsOpen( body )
            if zone == "sweep" then return "sweep" end
            if Settings.Get( "buildopen" ) == false
                and not g_swProtection:sv_modeClosesBuilding() then
                return false
            end
            return zone
        end
    """)
    Prot.sv_setResolver(prot, resolver)

    bx, by = lua.globals().Layout.plotCentre(plots["layout"], 1)
    assert bx is not None, "plot 1 does not exist -- the fixture is wrong"
    block = float(P.BLOCK)
    make_body = lua.execute("""
        return function( x, y, z )
            local b = { worldPosition = { x = x, y = y, z = z } }
            function b:getShapes() return { { shapeUuid = "not-ours" } } end
            function b:getWorldAabb()
                return { x = x, y = y, z = z }, { x = x, y = y, z = z + 1 }
            end
            return b
        end
    """)
    body = make_body(float(bx) * block, float(by) * block, 1.5)

    zone = P.sv_bodyIsOpen(plots, body)
    assert zone is True, (
        f"the fixture is not standing on a buildable plot -- sv_bodyIsOpen says "
        f"{zone!r}, so every check built on it would pass for the wrong reason")
    return plots, prot, body


def over_budget_still_lets_you_trim():
    """Going over the part limit must not lock the way OUT of going over it.

    REPORTED: "I cant break the block if I hit the limit. so like I am stuck in a
    loop I cant remove the bearing that prevents from building."

    The old code returned `false` -- the LOCKED profile, erasable = false -- from
    the top of sv_bodyIsOpen. So the only action that could satisfy the limit was
    the one the limit forbade.

    This runs the real resolver rather than reading the PROFILES table, because
    reading the table is exactly what would have passed while the feature was
    unreachable. See buffer_time_actually_reaches_the_polish_profile for the
    version of this mistake that shipped.
    """
    lua = fresh("Layout.lua", "Palette.lua", "Settings.lua", "Protection.lua",
                "Plots.lua", "Event.lua")
    P, Prot = lua.globals().Plots, lua.globals().Protection
    plots, prot, body = _plot_fixture(lua)

    def profile():
        got = Prot.sv_profileForTest(prot, body)
        return got[0] if isinstance(got, tuple) else got

    before = profile()
    assert before["buildable"] is True, "the fixture plot is not buildable to start with"

    # over budget, exactly the way World.sv_checkRules sets it
    plots["overBudget"] = lua.table_from({1: True})

    got = profile()
    assert got["buildable"] is False, (
        "a plot over its part budget still accepts new parts -- the limit does nothing")
    assert got["erasable"] is True, (
        "OVER BUDGET LOCKED ERASING. This is the reported deadlock: the owner "
        "cannot remove the part that put them over the limit, so there is no way "
        "back under it without the host.")
    assert got["paintable"] is True, "trimming a plot should not cost you painting"
    assert got["connectable"] is True, "trimming a plot should not cost you wiring"
    assert got["usable"] is True, "trimming a plot should not cost you the seats"

    # and it clears again
    plots["overBudget"] = lua.table_from({})
    assert profile()["buildable"] is True, "trimming the plot did not reopen it"


def over_budget_never_opens_somebody_elses_plot():
    """The downgrade only ever takes away. It must never grant.

    Body permission flags are per-BODY, so "erasable" means erasable BY EVERYONE.
    If the over-budget verdict were applied before the ownership rules -- which
    is where it used to live -- then a plot that was locked to a passer-by would
    become erasable to them the moment its owner went one bearing over. That
    turns the part limit into a griefing tool.
    """
    lua = fresh("Layout.lua", "Palette.lua", "Settings.lua", "Protection.lua",
                "Plots.lua", "Event.lua")
    P, Prot = lua.globals().Plots, lua.globals().Protection
    plots, prot, body = _plot_fixture(lua)

    # claimed by somebody who is not here, which is the LOCKED case
    ok, why = P.sv_claim(plots, 1, "SW-0001")
    assert ok, f"could not claim plot 1: {why}"
    assert P.sv_bodyIsOpen(plots, body) is False, (
        "an empty claimed plot is not locked -- the fixture cannot test this")

    plots["overBudget"] = lua.table_from({1: True})
    verdict = P.sv_bodyIsOpen(plots, body)
    assert verdict is False, (
        f"an over-budget plot that was LOCKED to you came back {verdict!r}. The "
        f"downgrade must only ever take building away from a plot that was open, "
        f"never hand erasing to somebody who had none.")


def over_budget_during_buffer_stays_polish():
    """Buffer time is "no placing and no breaking". Over budget must not add breaking.

    trim is derived from whichever open profile is in force, and during the
    buffer that is `polish`, which is erasable = false on purpose. Mapping trim
    to the plain trim profile there would quietly put erasing back into the one
    window that exists to have neither verb.
    """
    lua = fresh("Layout.lua", "Palette.lua", "Settings.lua", "Protection.lua",
                "Plots.lua", "Event.lua")
    Prot = lua.globals().Protection
    plots, prot, body = _plot_fixture(lua)

    plots["overBudget"] = lua.table_from({1: True})
    Prot.sv_setMode(prot, "polish")
    got = Prot.sv_profileForTest(prot, body)
    got = got[0] if isinstance(got, tuple) else got

    assert got["buildable"] is False, "buffer time let somebody place a block"
    assert got["erasable"] is False, (
        "an over-budget plot became ERASABLE during buffer time. Buffer is the "
        "one window with neither verb; trim must map to polish there.")
    assert got["paintable"] is True, "buffer time stopped being paintable"


# ------------------------------------------------------- the scoped audit ---

def _rules_fixture(lua, active):
    """A Rules, a fake Plots that reports `active` as its occupied plots, and a
    joint-heavy body sitting on plot 1."""
    R = lua.globals().Rules
    rules = lua.eval("Rules()")
    R.sv_onCreate(rules)
    plots = lua.execute("""
        return function( active )
            local p = { active = active }
            function p:sv_activePlots() return self.active end
            function p:sv_bodyZone( body ) return { kind = "plot", index = body.plot } end
            return p
        end
    """)(lua.table_from(active))
    return rules, plots


def the_fast_audit_only_looks_at_plots_people_are_on():
    """The scoped pass must skip the per-shape work for everything else.

    Asked for as: "item detection is a bit too slow. you can run it faster if you
    only check ocupied places with players curently on the server ocupied."

    A body on a plot nobody is standing on must not have getShapes() called on it
    during a fast pass -- that walk is the entire cost of the audit, and skipping
    it is the whole optimisation. Counted rather than assumed.
    """
    lua = fresh("Rules.lua")
    lua.execute("function isGhostBody( body ) return false end")
    rules, plots = _rules_fixture(lua, {1: True})

    lua.execute("""
        swShapeCalls = 0
        local function body( plot, joints )
            local b = { plot = plot }
            function b:getShapes()
                swShapeCalls = swShapeCalls + 1
                return {}
            end
            function b:getCreationId() return "c" .. plot end
            function b:getCreationJoints()
                local out = {}
                for i = 1, joints do out[i] = i end
                return out
            end
            return b
        end
        swTestBodies = { body( 1, 3 ), body( 2, 99 ), body( 3, 99 ) }
    """)
    get = lua.execute("""
        return function( key )
            if key == "maxjoints" then return 10 end
            return 0
        end
    """)

    # tick 0 is the FULL pass -- nextFull starts at 0
    report = lua.globals().Rules.sv_audit(rules, 0, plots, get)
    assert report is not None, "the first audit did not run at all"
    assert report["full"] is True, "the first audit should be a full pass"
    full_calls = int(lua.globals().swShapeCalls)
    assert full_calls == 3, f"a full pass looked at {full_calls} bodies, expected 3"
    assert rules["violations"][2] is not None, "the full pass missed a 99-joint plot"

    # one second later: a FAST pass, scoped to plot 1
    lua.globals().swShapeCalls = 0
    report = lua.globals().Rules.sv_audit(rules, 40, plots, get)
    assert report is not None, "the fast pass did not run"
    assert report["full"] is False, "tick 40 should not have been a full pass"
    fast_calls = int(lua.globals().swShapeCalls)
    assert fast_calls == 1, (
        f"the fast pass walked the shapes of {fast_calls} bodies. It is supposed "
        f"to look only at plots somebody is standing on, which is 1 of 3 here -- "
        f"if it walks all of them the optimisation does not exist.")

    # ...and it must not have forgotten what the full pass knew about plot 2
    assert rules["violations"][2] is not None, (
        "a scoped pass wiped the violation on a plot it never looked at. A plot "
        "nobody is standing on must keep the last full pass's verdict.")


def trimming_a_plot_reopens_it_on_the_fast_pass():
    """Removing the offending part must clear the violation within a second.

    The trap: a scoped pass only writes buckets for bodies it FINDS. Delete the
    last body on a plot -- or every joint on it -- and the plot would never
    appear in perPlot, so its stale violation would survive until the next full
    pass five seconds later. Seeding an empty bucket for every scoped plot is
    what makes "trim it and it reopens" mean one second rather than five.
    """
    lua = fresh("Rules.lua")
    lua.execute("function isGhostBody( body ) return false end")
    rules, plots = _rules_fixture(lua, {1: True})
    get = lua.execute("""
        return function( key )
            if key == "maxjoints" then return 10 end
            return 0
        end
    """)
    lua.execute("""
        local function body( plot, joints )
            local b = { plot = plot }
            function b:getShapes() return {} end
            function b:getCreationId() return "c" .. plot end
            function b:getCreationJoints()
                local out = {}
                for i = 1, joints do out[i] = i end
                return out
            end
            return b
        end
        swMakeBody = body
        swTestBodies = { body( 1, 40 ) }
    """)

    lua.globals().Rules.sv_audit(rules, 0, plots, get)
    assert rules["violations"][1] is not None, "40 joints did not trip a limit of 10"

    # the owner trims it right down
    lua.execute("swTestBodies = { swMakeBody( 1, 2 ) }")
    lua.globals().Rules.sv_audit(rules, 40, plots, get)
    assert rules["violations"][1] is None, (
        "the plot is still locked one fast pass after being trimmed")

    # and the same again with the body removed outright
    lua.execute("swTestBodies = { swMakeBody( 1, 40 ) }")
    lua.globals().Rules.sv_audit(rules, 80, plots, get)
    assert rules["violations"][1] is not None, "the fixture did not go back over"
    lua.execute("swTestBodies = {}")
    lua.globals().Rules.sv_audit(rules, 120, plots, get)
    assert rules["violations"][1] is None, (
        "deleting the whole build left the plot locked. A scoped plot has to be "
        "recomputed even when nothing is found standing on it.")


def the_occupancy_pass_is_what_names_the_active_plots():
    """activePlots must come from the per-tick presence pass, not a second walk.

    The point of scoping the audit is that the answer is already known:
    sv_updateOccupancy runs every tick and is the only thing in the mod that
    looks at where players stand. If activePlots were computed separately the
    optimisation would be paying for itself twice.
    """
    src = io.open(SCRIPTS / "Plots.lua", encoding="utf-8").read()
    assert "self.activePlots = {}" in src, (
        "sv_updateOccupancy no longer resets activePlots, so it accumulates "
        "forever and every plot becomes permanently 'active'")
    body = src[src.index("function Plots.sv_updateOccupancy"):]
    body = body[:body.index("\nfunction Plots.sv_holdNearby")]
    assert "activePlots[z.index] = true" in body, (
        "standing on a plot no longer marks it active")
    rules = io.open(SCRIPTS / "Rules.lua", encoding="utf-8").read()
    assert "plots:sv_activePlots()" in rules, (
        "Rules no longer asks Plots which plots are occupied")
    assert "sm.player.getAllPlayers" not in rules, (
        "Rules walks the player list itself. That is the occupancy pass's job "
        "and it already runs every tick -- see Plots.sv_updateOccupancy.")


# ------------------------------------------------------------ city style ---

def the_palette_is_the_paint_tools_own():
    """Forty swatches, four rows of ten, every name distinct."""
    lua = fresh("Palette.lua")
    Pal = lua.globals().Palette

    rows = list(Pal.ROWS.values())
    assert len(rows) == 4, f"{len(rows)} rows, the paint tool has 4"
    for i, row in enumerate(rows, 1):
        cols = list(row.values())
        assert len(cols) == 10, f"row {i} has {len(cols)} swatches, the tool has 10"
        for hexv in cols:
            assert len(hexv) == 6 and all(c in "0123456789abcdef" for c in hexv), \
                f"{hexv!r} is not a six digit hex colour"

    order = list(Pal.COLOUR_ORDER.values())
    assert len(order) == 40, f"{len(order)} colour names for 40 swatches"
    assert len(set(order)) == 40, (
        "two swatches share a name, so one of them can never be selected: "
        f"{sorted(n for n in order if order.count(n) > 1)}")

    # the anchors that identify the run in the executable
    assert Pal.COLOURS["orange"] == "df7f00", (
        "the default orange every new block is painted is not in the palette -- "
        "the run read out of the executable is probably not the palette")
    assert Pal.COLOURS["darkgrey"] == "4a4a4a"
    assert Pal.Hex("green") == "19e753"
    assert Pal.Hex("beef42") == "beef42", "a raw hex should be accepted"
    assert Pal.Hex("chartreuse") is None, "an invented colour name was accepted"


def every_style_preset_names_real_blocks_and_colours():
    """A style preset with a typo in it builds a city out of nothing.

    Sv_Set validates, so a bad name is REFUSED rather than stored -- which means
    a typo shows up as a piece of the city silently keeping its old material,
    not as an error. Checked here instead.
    """
    lua = fresh("Palette.lua", "Settings.lua")
    Pal, S = lua.globals().Palette, lua.globals().Settings
    keys = {row["key"] for row in S.SCHEMA.values()}

    pieces = ["pad", "border", "road", "plaza", "stand"]
    wanted = {p + s for p in pieces for s in ("block", "colour")}
    missing = wanted - keys
    assert not missing, f"the schema has no setting for {sorted(missing)}"

    order = list(Pal.STYLE_ORDER.values())
    for name in order:
        style = Pal.STYLES[name]
        assert style is not None, f"STYLE_ORDER names {name!r} but STYLES has no such style"
        got = set()
        for key in style:
            got.add(key)
            assert key in keys, f"style {name!r} sets unknown setting {key!r}"
            value = style[key]
            if key.endswith("block"):
                assert Pal.MaterialUuid(value) is not None, \
                    f"style {name!r}: {key} = {value!r} is not a block in Palette.MATERIALS"
            else:
                assert Pal.Hex(value) is not None, \
                    f"style {name!r}: {key} = {value!r} is not a palette colour"
        assert got == wanted, (
            f"style {name!r} does not set every piece -- missing {sorted(wanted - got)}. "
            f"A partial style leaves half the city looking like the last one.")
    for name in Pal.STYLES:
        assert name in order, f"style {name!r} exists but /citystyle will never list it"


def the_style_defaults_are_selectable_values():
    """Every default must be a value the panel can cycle back to.

    A default outside the choice list is a setting that can be changed once and
    never changed back, because SettingsGui.NextValue cycles the list and /set
    refuses anything not on it.
    """
    lua = fresh("Palette.lua", "Settings.lua")
    Pal, S = lua.globals().Palette, lua.globals().Settings
    for row in S.SCHEMA.values():
        key, default = row["key"], row["default"]
        if key.endswith("block"):
            assert Pal.MaterialUuid(default) is not None, \
                f"{key} defaults to {default!r}, which is not a block"
            assert default in list(Pal.MATERIAL_ORDER.values()), \
                f"{key} defaults to {default!r}, which the panel cannot cycle to"
        elif key.endswith("colour") and row["kind"] == "string":
            assert default in list(Pal.COLOUR_ORDER.values()), \
                f"{key} defaults to {default!r}, which the panel cannot cycle to"


def the_city_is_built_out_of_the_selected_blocks():
    """Change the setting, rebuild, and the blueprint changes with it.

    The failure this catches is the one that matters: a style setting that is
    stored, echoed back, listed on the panel, and never actually read by the
    thing that builds the city.
    """
    lua = fresh("Layout.lua", "Palette.lua", "Settings.lua", "Plots.lua")
    lua.globals().Settings.Sv_Load(False)
    P, Pal, S = lua.globals().Plots, lua.globals().Palette, lua.globals().Settings

    plots = lua.eval("Plots()")
    P.sv_onCreate(plots, lua.table_from({"grid": lua.table_from({}), "enabled": True}))

    def materials_of_plot():
        bp = P.sv_plotBlueprint(plots, 0, 0)
        assert bp is not None, "plot 0,0 does not exist -- the fixture is wrong"
        return {c["shapeId"]: c["color"] for c in bp["bodies"][1]["childs"].values()}

    S.Sv_Set("padblock", "carpet")
    S.Sv_Set("padcolour", "deepgreen")
    got = materials_of_plot()
    carpet = Pal.MaterialUuid("carpet")
    assert carpet in got, (
        "the pad is not made of the selected block. The style setting is stored "
        "and ignored, which is the exact shape of a feature that looks broken.")
    assert got[carpet] == Pal.Hex("deepgreen"), \
        f"the pad is {got[carpet]!r}, not the selected deepgreen"

    S.Sv_Set("padblock", "concrete")
    got = materials_of_plot()
    assert Pal.MaterialUuid("concrete") in got, "switching the pad block did nothing"
    assert carpet not in got, "the old pad block is still in the blueprint"

    # a raw hex, for a host who wants a colour the paint tool does not ship
    S.Sv_Set("padcolour", "ff00ff")
    got = materials_of_plot()
    assert got[Pal.MaterialUuid("concrete")] == "ff00ff", "a raw hex colour was ignored"


# ------------------------------------------------- the city style panel ---
#
# REPORTED: "city build settings. specialy the material and colour selection.
# make it not a slider like. but like a list so its easier to select. and use
# the color pallete selection of paint tool for the city part color selection."
#
# The ten style settings used to be ten stepper rows on the settings panel: one
# button per setting, click it and it moves to the next of twenty-five blocks or
# forty colours, wrapping at the end. Every click was a server round trip, and at
# no point could you see what you were choosing between.
#
# StyleGui puts all of it on one screen. These checks are about the two ways that
# can be wrong without looking wrong: an option that is not on the panel at all,
# and an option that is on the panel but sends a value the validator refuses.


def style_state(lua, piece="pad", **over):
    """Exactly what Game.sv_openStyleGui sends the client.

    Built from the schema rather than hand-written, so a new piece of the city
    is picked up here the same way the real thing picks it up.
    """
    S = lua.globals().Settings
    style = {}
    for p in lua.globals().Palette.PIECES.values():
        key = p["key"]
        style[key] = lua.table_from({
            "block": over.get(key + "block", S.Get(key + "block")),
            "colour": over.get(key + "colour", S.Get(key + "colour")),
        })
    return lua.table_from({"style": lua.table_from(style),
                           "piece": piece, "back": "city"})


def clickables(root):
    """(action, onClickData table, raw node) for everything on a panel."""
    out = []
    for node in walk_raw(root):
        data = node["onClickData"]
        if data is not None:
            out.append((data["action"], data, node))
    return out


def the_style_panel_fits_for_every_piece():
    lua = gui_lua()
    G = lua.globals().StyleGui
    for piece in ("pad", "border", "road", "plaza", "stand"):
        root = G.Build(style_state(lua, piece))
        label = f"style {piece}"
        items = panel_fits(label, root, G.W, G.H)
        no_button_is_buried(label, items, G.H)

    # The states that are NOT a clean selection. A raw hex has no swatch on the
    # grid, so the selection ring is not drawn at all -- and a panel that only
    # lays out correctly when something is selected is a panel that breaks the
    # first time a host uses /set.
    for extra in ({"padcolour": "ff00ff"}, {"padblock": "nonsense"},
                  {"padcolour": "", "padblock": ""}):
        root = G.Build(style_state(lua, "pad", **extra))
        label = f"style {extra}"
        items = panel_fits(label, root, G.W, G.H)
        no_button_is_buried(label, items, G.H)

    # ...and with no state at all, which is what a client has if it renders
    # before its first update arrives.
    panel_fits("style (no state)", G.Build(None), G.W, G.H)


def every_block_and_every_colour_is_one_click_away():
    """No stepping, and nothing left off the panel.

    A list that offers twenty of the twenty-five blocks is the same bug in a
    nicer shape. And the half that would fail silently: a button whose value the
    validator on the other side refuses, which shows up as a click that does
    nothing for one particular material.
    """
    lua = gui_lua()
    G, Pal, S = lua.globals().StyleGui, lua.globals().Palette, lua.globals().Settings
    offered = {"block": set(), "colour": set(), "piece": set(), "stylepreset": set()}
    for action, data, _ in clickables(G.Build(style_state(lua, "pad"))):
        if action in ("block", "colour"):
            offered[action].add(data["value"])
        elif action == "piece":
            offered["piece"].add(data["piece"])
        elif action == "stylepreset":
            offered["stylepreset"].add(data["preset"])

    blocks = set(Pal.MATERIAL_ORDER.values())
    colours = set(Pal.COLOUR_ORDER.values())
    assert offered["block"] == blocks, (
        "the block list is not the block list -- missing "
        f"{sorted(blocks - offered['block'])}, invented "
        f"{sorted(offered['block'] - blocks)}")
    assert offered["colour"] == colours, (
        "the swatch grid is not the palette -- missing "
        f"{sorted(colours - offered['colour'])}, invented "
        f"{sorted(offered['colour'] - colours)}")
    assert offered["piece"] == {p["key"] for p in Pal.PIECES.values()}, (
        f"the panel offers pieces {sorted(offered['piece'])}")
    assert offered["stylepreset"] == set(Pal.STYLE_ORDER.values()), (
        f"the panel offers styles {sorted(offered['stylepreset'])}")

    # Every value on the panel has to survive Settings.Sv_Set, which is what
    # actually receives it. A button and a validator that disagree by one entry
    # is a panel that works twenty-four times out of twenty-five.
    for name in sorted(blocks):
        got = S.Sv_Set("padblock", name)
        assert got[0], f"clicking block {name!r} would be refused: {got[1]}"
    for name in sorted(colours):
        got = S.Sv_Set("padcolour", name)
        assert got[0], f"clicking colour {name!r} would be refused: {got[1]}"


def the_swatch_grid_is_the_paint_tools_grid():
    """Four rows of ten, at the tool's colours, in the tool's order.

    "use the color pallete selection of paint tool" -- so a swatch drawn at the
    wrong colour is not a cosmetic complaint, it is the feature being wrong. The
    colour is read back off the widget and converted to hex again here, which
    also checks Palette.GuiColour in the only place it is used.
    """
    lua = gui_lua()
    G, Pal = lua.globals().StyleGui, lua.globals().Palette
    swatches = {}
    for action, data, node in clickables(G.Build(style_state(lua, "pad"))):
        if action == "colour":
            swatches[data["value"]] = node

    xs, ys = {}, {}
    rows = list(Pal.ROWS.values())
    assert len(rows) == 4
    for r, row in enumerate(rows):
        cols = list(row.values())
        assert len(cols) == 10
        for c, hexv in enumerate(cols):
            name = Pal.NameOfHex(hexv)
            node = swatches.get(name)
            assert node is not None, f"{name} ({hexv}) has no swatch on the grid"

            got = tuple(round(float(v) * 255) for v in str(node["Colour"]).split()[:3])
            want = tuple(int(hexv[i:i + 2], 16) for i in (0, 2, 4))
            assert got == want, (
                f"swatch {name} is drawn {got}, the paint tool's is {want}")

            w, h = node["width"], node["height"]
            assert w == h and w >= 20, f"swatch {name} is {w}x{h}"

            x, y = node["x"], node["y"]
            xs.setdefault(c, x)
            ys.setdefault(r, y)
            assert x == xs[c], f"{name} is not lined up with the rest of column {c + 1}"
            assert y == ys[r], f"{name} is not lined up with the rest of row {r + 1}"

    assert [xs[c] for c in range(10)] == sorted(xs.values()), \
        "the columns are not in the paint tool's left-to-right order"
    assert [ys[r] for r in range(4)] == sorted(ys.values()), \
        "the rows are not in the paint tool's top-to-bottom order"


def the_panel_agrees_with_itself_about_what_is_selected():
    """The block list, the selection ring and the preview are three separate
    reads of the same two values, and it is entirely possible to update one and
    not the others -- which reads as a panel that highlights the wrong thing."""
    lua = gui_lua()
    G, Pal, S = lua.globals().StyleGui, lua.globals().Palette, lua.globals().Settings
    for p in Pal.PIECES.values():
        key, label = p["key"], p["label"]
        block, colour = S.Get(key + "block"), S.Get(key + "colour")
        root = G.Build(style_state(lua, key))
        named = {n["Name"]: n for n in walk_raw(root) if n["Name"] is not None}

        lit = [(d["value"], n) for a, d, n in clickables(root)
               if a == "block" and n["Skin"] == "StyledButtonLarge"]
        assert len(lit) == 1, f"{key}: {len(lit)} blocks are highlighted, not 1"
        assert lit[0][0] == block, (
            f"{key}: the panel highlights {lit[0][0]!r} but the setting is {block!r}")

        ring, sw = named.get("SwRing"), named.get("Sw" + colour)
        assert sw is not None, f"{key}: {colour!r} has no swatch"
        assert ring is not None, f"{key}: nothing marks which swatch is selected"
        assert ring["x"] < sw["x"] and ring["y"] < sw["y"], (
            f"{key}: the selection ring is not behind the {colour} swatch")
        assert ring["x"] + ring["width"] > sw["x"] + sw["width"], (
            f"{key}: the selection ring does not surround the {colour} swatch")

        assert named["SelPiece"]["Caption"] == label, (
            f"the preview says {named['SelPiece']['Caption']!r}, not {label!r}")
        assert named["SelBlock"]["Caption"] == Pal.MaterialLabel(block)
        assert str(named["SelSw"]["Colour"]) == str(Pal.GuiColour(colour)), (
            f"{key}: the big preview swatch is not the selected colour")


def the_style_panel_and_the_builder_name_the_same_pieces():
    """Palette.PIECES and Plots.STYLE_PIECES are the same five, in order.

    Written out twice on purpose: Plots.lua is loaded WITHOUT Palette.lua in
    every plot check, so a load-time dependency between the two would break a
    dozen tests that have nothing to do with styling. Duplication plus a check is
    the trade, and this is the check. A piece on one list and not the other is
    either ground nobody can style or a button that changes nothing.
    """
    lua = fresh("Layout.lua", "Palette.lua", "Plots.lua")
    Pal, P = lua.globals().Palette, lua.globals().Plots
    gui = [p["key"] for p in Pal.PIECES.values()]
    builder = list(P.STYLE_PIECES.values())
    assert gui == builder, (
        f"the style panel offers {gui} and the builder styles {builder}")
    for p in Pal.PIECES.values():
        assert p["label"], f"piece {p['key']} has no name a host would recognise"
        assert p["help"], f"piece {p['key']} has no explanation"


def the_settings_panel_no_longer_steps_through_the_style():
    """The ten style settings must not be stepper rows anywhere any more.

    The trap is RowsFor("other"): it sweeps up every schema row that no group
    claims, so dropping the CITY STYLE group without leaving its keys claimed
    puts all ten straight back as steppers under OTHER -- the exact thing being
    replaced, wearing a different tab.
    """
    lua = gui_lua()
    G = lua.globals().SettingsGui
    for group in [g["key"] for g in G.GROUPS.values()] + ["other"]:
        rows = G.RowsFor(group)
        for row in (rows.values() if rows is not None else []):
            key = row["key"]
            assert not (key.endswith("block") or key.endswith("colour")), (
                f"{key} is still a stepper row under {group!r}")

    # ...and the nav still gets you to the panel that replaced them.
    values = lua.table_from({row["key"]: row["default"]
                             for row in lua.globals().Settings.SCHEMA.values()})
    actions = {a for a, _, _ in clickables(G.Build(values, "safety", 1))}
    assert "style" in actions, (
        "nothing on the settings panel opens the city style panel any more")


def a_plot_can_never_be_scenery_whatever_it_is_made_of():
    """Scenery is locked in every mode. A plot must never resolve to it.

    This used to be safe by accident: scenery meant "every shape is metal 2 or
    metal 3" and the pad was always concrete. The pad is a setting now, and
    nothing stops a host setting the pad and the roads to the same block -- at
    which point every plot in the city would be permanently locked and the only
    clue would be that nobody could build.
    """
    lua = fresh("Layout.lua", "Palette.lua", "Settings.lua", "Plots.lua")
    lua.globals().Settings.Sv_Load(False)
    P, Pal, S = lua.globals().Plots, lua.globals().Palette, lua.globals().Settings

    plots = lua.eval("Plots()")
    P.sv_onCreate(plots, lua.table_from({"grid": lua.table_from({}), "enabled": True}))

    for block in ("metal3", "carpet", "concrete"):
        S.Sv_Set("padblock", block)
        S.Sv_Set("roadblock", block)
        S.Sv_Set("plazablock", block)
        P.sv_restyle(plots)
        street = P.sv_streetUuids(plots)
        pad = Pal.MaterialUuid(block)
        assert street[pad] is None, (
            f"with everything set to {block!r} the plot pad counts as street, so "
            f"every plot slab in the city resolves to scenery and locks")


def a_style_change_never_unmakes_the_existing_city():
    """CITY_UUIDS has to cover every material, not the three in use.

    Restyle the city while one still stands and the old one is still city: the
    cleaner must not suddenly start treating the ground it has been protecting
    as somebody's build, or the reverse.
    """
    lua = fresh("Layout.lua", "Palette.lua", "Settings.lua", "Plots.lua")
    P, Pal = lua.globals().Plots, lua.globals().Palette
    city = P.CITY_UUIDS
    for name in Pal.MATERIAL_ORDER.values():
        uuid = Pal.MaterialUuid(name)
        assert city[uuid] is True, (
            f"{name} can be selected as a city material but is not in "
            f"CITY_UUIDS, so a city built out of it stops being recognised as "
            f"city the moment the style changes again")


# ------------------------------------------------------------ roster hud ---

def the_roster_hud_fits_in_the_top_left_corner():
    """Fully on screen, at every resolution the game ships a skin for.

    The event clock spent four versions off the edge of the screen because a
    root widget's x,y is its CENTRE and the canvas is not the window. Same
    arithmetic, same trap, so it gets the same check.
    """
    lua = fresh("Event.lua", "EventHud.lua", "RosterHud.lua")
    R = lua.globals().RosterHud
    for w, h in ((1280, 720), (1920, 1080), (2560, 1440), (3840, 2160), (1720, 720)):
        x, y = R.TopLeft(w, h)
        left, top = x - R.W / 2, y - R.H / 2
        right, bottom = x + R.W / 2, y + R.H / 2
        assert left >= -w / 2 - 0.5, f"{w}x{h}: the panel hangs off the left edge"
        assert top >= -h / 2 - 0.5, f"{w}x{h}: the panel hangs off the top edge"
        assert right <= w / 2 + 0.5, f"{w}x{h}: the panel is wider than the canvas"
        assert bottom <= h / 2 + 0.5, f"{w}x{h}: the panel is taller than the canvas"
        # and it is actually in the TOP LEFT, not merely on screen
        assert x < 0 and y < 0, (
            f"{w}x{h}: the panel centre is at {x},{y}, which is not the top left. "
            f"x,y is measured from the centre of the canvas with +y downwards.")


def the_roster_hud_says_what_it_was_given():
    lua = fresh("Event.lua", "EventHud.lua", "RosterHud.lua")
    R = lua.globals().RosterHud
    root = R.Build(lua.table_from({"online": 7, "residents": 23}), 1720, 720)
    captions = {}
    for kid in root["Childs"].values():
        if kid["Caption"] is not None:
            captions[kid["Name"]] = kid["Caption"]
    assert captions.get("OnlineValue") == "7", f"online reads {captions.get('OnlineValue')!r}"
    assert captions.get("ResidentValue") == "23", f"residents reads {captions.get('ResidentValue')!r}"
    assert "ONLINE" in captions.values() and "RESIDENTS" in captions.values(), \
        "the two numbers are unlabelled"

    # and it survives being handed nothing at all, which is what a client that
    # has not received an update yet has
    empty = R.Build(None, 1720, 720)
    assert empty is not None, "the roster HUD refuses to draw before its first update"



def clicking_a_style_row_cycles_it_all_the_way_round():
    """The panel path, end to end: NextValue -> Sv_Set -> the blueprint.

    Every other style check goes through /set. This one goes the way the host
    actually will: click the value, take whatever NextValue hands back, and feed
    it to Sv_Set -- which VALIDATES. A cycle list and a validator that disagreed
    by one entry would give a button that works nine times out of ten, which is
    the hardest kind of broken to report.

    All the way round, not one step, because the failure would be at whichever
    entry the two lists disagree on.
    """
    lua = fresh("Layout.lua", "Palette.lua", "Settings.lua", "SettingsGui.lua", "Plots.lua")
    S, G, Pal = lua.globals().Settings, lua.globals().SettingsGui, lua.globals().Palette
    S.Sv_Load(False)

    rows = {row["key"]: row for row in S.SCHEMA.values()}
    style_keys = [k for k in rows if k.endswith("block") or
                  (k.endswith("colour") and rows[k]["kind"] == "string")]
    assert len(style_keys) == 10, f"expected 10 style settings, found {len(style_keys)}"

    for key in style_keys:
        row = rows[key]
        choices = list(row["choices"]().values())
        seen = []
        for _ in range(len(choices) + 1):
            current = S.Get(key)
            nxt = G.NextValue(row, current)
            # Sv_Set returns ( ok, detail, row ), so lupa hands back a 3-tuple
            got = S.Sv_Set(key, str(nxt))
            ok, detail = got[0], got[1]
            assert ok, (
                f"the panel cycled {key} to {nxt!r} and Sv_Set refused it: {detail}. "
                f"SettingsGui.NextValue and the schema's choice list disagree.")
            assert S.Get(key) == nxt, f"{key} did not take the value {nxt!r}"
            seen.append(nxt)
        assert set(seen) == set(choices), (
            f"cycling {key} did not visit every option -- missed "
            f"{sorted(set(choices) - set(seen))}")

    # A NAME THAT IS NOT A BLOCK MUST BE REFUSED, not stored.
    #
    # This is the other half of the same pairing and it is the more dangerous
    # half: a stored typo does not error, it builds a plot out of a uuid the
    # engine has never heard of. Which imports as nothing -- a city with holes
    # in it and no message anywhere saying why.
    before = S.Get("padblock")
    got = S.Sv_Set("padblock", "banana")
    assert got[0] is False, "'banana' was accepted as a block name"
    assert S.Get("padblock") == before, "a refused value was stored anyway"
    got = S.Sv_Set("padcolour", "chartreuse")
    assert got[0] is False, "'chartreuse' was accepted as a colour"
    # ...but a raw hex still is, because the forty swatches are not a cage
    got = S.Sv_Set("padcolour", "FF00FF")
    assert got[0] is True, "a raw hex colour was refused"
    assert S.Get("padcolour") == "ff00ff", "a raw hex was not normalised to lower case"

    # and after all that clicking the city still builds out of real blocks
    P = lua.globals().Plots
    plots = lua.eval("Plots()")
    P.sv_onCreate(plots, lua.table_from({"grid": lua.table_from({}), "enabled": True}))
    bp = P.sv_plotBlueprint(plots, 0, 0)
    known = set(Pal.AllMaterialUuids().keys())
    for c in bp["bodies"][1]["childs"].values():
        assert c["shapeId"] in known, (
            f"the plot blueprint contains {c['shapeId']!r}, which is not a block "
            f"this mod can name -- the city would import as nothing")
        assert len(str(c["color"])) == 6, f"bad colour {c['color']!r} in the blueprint"


# --------------------------------------------------- the network surface ---

# Handlers a guest may reach, and why each is safe without a host test of its
# own. Anything NOT named here has to test the sender itself.
GUEST_REACHABLE = {
    "sv_n_openMenu":
        "opens the hub, and MenuGui.Build( isHost ) leaves the host entries "
        "out -- each of them is reached through sv_n_menuOpen, which gates",
    "sv_n_myPlotAction":
        "a player acting on their own plot: authority comes from where the "
        "sender is standing, never from the payload",
    "sv_n_swImport":
        "forwards to World.sv_e_swImportCreation, which is host-gated there "
        "deliberately -- see the HOST ONLY comment in that function",
}


def a_snapshot_is_the_whole_world_not_just_the_builds():
    """REPORTED twice: "the backups need to be the full world backups", and then
    "the world backups is a FULL SAVE BACKUP. and not build backup."

    The first time, only the timestamped naming got done. A snapshot stayed a
    list of creations, so /restore rebuilt every building and left the CLAIMS
    wherever they had drifted to: the city came back and nobody owned any of it.
    The grid matters just as much -- the creations in a snapshot were laid out
    on one, and restoring a 96-plot city onto a 384-plot grid puts every piece
    in the wrong place.

    THREE call sites capture, not one: /snapshot, the autosave rotation, and the
    event clock's per-phase saves. A save made by any of them has to be the same
    kind of save, or "restore the autosave" quietly means something weaker than
    "restore the one I made by hand".
    """
    import re
    world = read("World.lua")
    sites = [m.start() for m in re.finditer(r"sv_beginCapture\(", world)]
    assert len(sites) == 3, (
        f"expected three capture sites, found {len(sites)} -- if one was added, "
        "it has to carry the world state like the others")
    for at in sites:
        # BALANCE THE BRACKETS. Slicing to the first ")" stops inside
        # sv_autoName(), which made this check fail on a correct call site the
        # first time it ran -- the same shape of mistake as reading a file
        # without asking what is in it.
        j, depth = world.index("(", at), 0
        while j < len(world):
            if world[j] == "(":
                depth += 1
            elif world[j] == ")":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        call = world[at:j]
        assert "sv_serialise" in call, (
            "a snapshot is being captured without the plot state, so restoring "
            "it would rebuild the buildings and lose who owns them: "
            + " ".join(call.split())[:120])

    snaps = read("Snapshots.lua")
    assert "plots = job.worldState" in snaps, (
        "the capture no longer writes the world state into the payload")
    assert "opts.restoreState" in snaps, (
        "restore no longer puts the world state back, so a full save restores "
        "as a build-only one")

    # ...and a PER-PLOT repair must not rewrite everybody's claims. That is the
    # whole reason per-plot restore exists: "it was only a little bit that got
    # broken on my build".
    guard = snaps[snaps.index("opts.restoreState"):]
    guard = guard[:200]
    assert "opts.plot == nil" in snaps[max(0, snaps.index("opts.restoreState") - 200):
                                       snaps.index("opts.restoreState") + 200], (
        "restoring ONE plot also rewrites every claim in the world")


def clay_is_stopped_before_it_lands():
    """REPORTED: "the clay wont go away."

    It could not. MEASURED from vanilla's own source --
    Data/Scripts/game/worlds/CreativeBaseWorld.lua:159 -- a clay shot calls
    world:voxelDensityAddition, so clay is TERRAIN and not a body:

      * destroyShape cannot touch it, so the Cleaner cannot remove it
      * it carries no permission flags, so the whole protection system, every
        profile and /lockdown itself say nothing about it
      * the one call that removes terrain is sphereVoxelDensitySubtraction from
        an explosion, which this mod deliberately declines in order to stop
        cratering

    Three correct decisions that together make clay permanent. The tool guard
    does not help either: forceTool is client-side and "forced down" tier, so it
    empties a hand a couple of ticks after the gun is picked up, which is not
    the same as never firing.

    So the server declines the projectile. This is what makes `claygun` a real
    off switch rather than an inconvenience, and it is the only thing that makes
    a lockdown mean anything about clay.
    """
    import re
    world = read("World.lua")
    m = re.search(r"^function\s+World\.server_onProjectile\s*\(", world, re.M)
    assert m, (
        "World no longer overrides server_onProjectile, so CreativeBaseWorld "
        "makes clay unconditionally and nothing in this mod can remove it")
    end = world.find(chr(10) + "function ", m.end())
    body = world[m.end(): end if end != -1 else len(world)]

    # The uuid is a constant declared just above the function, not inside it --
    # so this asks the FILE for the uuid and the FUNCTION for the reference,
    # rather than failing on correct code because of where a local sits.
    assert "0ab670bb-5969-4ab4-87a3-435795392d5a" in world, (
        "the clay projectile uuid is gone from World.lua")
    assert "CLAY_PROJECTILE" in body, (
        "the projectile guard no longer tests for clay")
    assert 'Settings.Get( "claygun" )' in body, (
        "the clay guard ignores the claygun setting")
    assert "WorldIsShut()" in body, (
        "clay is still made during a lockdown -- and it is terrain, so nothing "
        "removes it afterwards")
    assert "CreativeFlatWorld.server_onProjectile" in body, (
        "the override never calls its parent, so flame, foam and cablebot "
        "projectiles all stopped working")

    # and there has to be a way out for clay already on the ground
    assert "sphereVoxelDensitySubtraction" in world, (
        "nothing in the mod can remove clay that is already down")


def the_command_gate_is_default_deny():
    """Everything is host-only unless it is named, and not the other way round.

    A gate written as "if HOST_COMMANDS[cmd] and not isHost" fails open: every
    command nobody classified becomes a guest command, and the day somebody adds
    one is the day a guest can run it. Written the other way round, the same
    forgetfulness produces a refusal on something harmless, which somebody
    reports and which costs nothing.

    V65 made the guest side much smaller -- "every command for players in the
    chat shall also be disabled appart for host" -- but the DIRECTION of the
    test is the part that matters and is unchanged.
    """
    game = read("Game.lua")
    assert "if not isHost then" in game, "the command gate is gone entirely"
    body = game[game.index("function Game.sv_n_adminCommand"):]
    body = body[:body.index(chr(10) + "end" + chr(10))]
    for needle in ("if not GUEST_TYPED[cmd] then",
                   "elseif not GUEST_PANEL[cmd] then"):
        assert needle in body, (
            f"the command gate no longer reads {needle!r}. Both lists must be "
            "'deny unless listed': anything nobody classified has to land on "
            "the HOST side, never the guest one")


def a_guest_types_nothing_but_the_way_in():
    """"every command for players in the chat shall also be disabled appart for
    host."

    One exception, and it is forced: /menu is the only way into the menu. A Game
    script is handed no key state at all -- F reaches Lua only through a tool's
    equipped update -- so a guest with no commands whatsoever could not claim a
    plot, read the rules or see who is here. Taking /menu away would not make
    the server stricter, it would make it unusable.
    """
    import re
    game = read("Game.lua")

    block = game[game.index("local GUEST_TYPED = {"):]
    block = block[:block.index("}")]
    typed = set(re.findall(r'\["(/[a-z0-9]+)"\]', block))
    assert typed == {"/menu"}, (
        f"a guest may type {sorted(typed)}. The only entry may be /menu, which "
        "is forced: it is the one way to reach the menu at all. Anything else "
        "is a second, typo-prone route to something that already has a button")

    # And the refusal has to point somewhere, or it is just a wall.
    body = game[game.index("function Game.sv_n_adminCommand"):]
    body = body[:body.index(chr(10) + "end" + chr(10))]
    refusal = body[body.index("if not GUEST_TYPED[cmd] then"):]
    refusal = refusal[:refusal.index("return")]
    assert "/menu" in refusal, (
        "the refusal a guest gets for typing a command does not name /menu, so "
        "it tells them what they cannot do and not what they can")


def guest_buttons_still_work_without_guest_commands():
    """A button a guest can press must still run, now that typing it does not.

    The agreement runs the opposite way from V61's, deliberately: sv_n_myPlotAction
    is guest-reachable on purpose -- authority comes from where the sender is
    standing -- so every command it forwards has to be classified as something a
    PANEL may cause, or the button answers with a refusal.

    And the panel flag has to be unforgeable, or the whole gate is decorative: a
    network callback is handed exactly ( self, data, player ), so a fourth
    parameter is something only this script can supply.
    """
    import re
    game = read("Game.lua")

    block = game[game.index("local GUEST_PANEL = {"):]
    block = block[:block.index("}")]
    allowed = set(re.findall(r'\["(/[a-z0-9]+)"\]', block))
    assert allowed, "could not read GUEST_PANEL"

    for handler in sorted(GUEST_REACHABLE):
        m = re.search(r"^function\s+\w+\." + handler + r"\s*\(", game, re.M)
        if not m:
            continue
        body = game[m.end(): game.find(chr(10) + "function ", m.end())]
        for cmd in sorted(set(re.findall(r'sv_toWorld\(\s*"(/[a-z0-9]+)"', body))):
            assert cmd in allowed, (
                f"{handler} is guest-reachable and forwards {cmd}, which is not "
                f"in GUEST_PANEL -- so the button answers a refusal while doing "
                "nothing at all")

    # Every sv_n_adminCommand call made on a guest's behalf must say so, or the
    # button hits the typed gate and refuses.
    router = game[game.index("function Game.sv_n_menuOpen"):]
    router = router[:router.index(chr(10) + "end" + chr(10))]
    for call in re.findall(r"sv_n_adminCommand\(([^\n]*)\)", router):
        assert "player, true" in call, (
            f"the menu router calls sv_n_adminCommand({call.strip()}) without "
            "the panel flag, so a guest pressing that entry is refused")

    # The flag itself: fourth parameter, which the network cannot reach.
    sig = next(l for l in game.splitlines()
               if l.startswith("function Game.sv_n_adminCommand("))
    assert sig.count(",") == 3, (
        f"sv_n_adminCommand's signature is {sig!r}. The panel flag has to be the "
        "FOURTH parameter -- a network callback is handed ( self, data, player ) "
        "and no more, which is the only reason a client cannot claim to be a panel")


def the_probe_commands_never_reach_the_server():
    """/guitest, /bptest and /bptest2 skip the gate, and may only do so while
    they change nothing but the screen of whoever typed them.

    They are bound to their own client callbacks rather than to
    cl_onAdminCommand, so the host check never runs for them. That is fine for
    an experiment that draws a widget tree on your own client and fine for one
    that reads a blueprint file -- and it would not be fine the moment one of
    them grew a sendToServer.
    """
    import re
    game = read("Game.lua")
    for name in ("cl_onBpTest", "cl_onBpTest2", "cl_onGuiTest"):
        m = re.search(r"^function\s+Game\." + name + r"\s*\(", game, re.M)
        assert m, f"{name} is gone -- is the command still bound?"
        end = game.find(chr(10) + "function ", m.end())
        body = game[m.end(): end if end != -1 else len(game)]
        assert "sendToServer" not in body, (
            f"{name} now talks to the server, but its command bypasses the "
            "host gate entirely -- either route it through cl_onAdminCommand "
            "or keep it client-only")
    probe = read("GuiProbe.lua")
    assert "sendToServer" not in probe, (
        "GuiProbe reaches the server, and /guitest is not host gated")


def guest_commands_match_the_guest_panels():
    """A button a guest can press and the command behind it must agree.

    sv_n_myPlotAction is in GUEST_REACHABLE on purpose -- a player acting on
    their own plot, with authority coming from where they are standing. So every
    command it forwards is a command a guest can cause to run, and if that
    command is not in PLAYER_COMMANDS then typing it answers "Host only." while
    pressing the button does the thing.

    MEASURED, V61, by auditing rather than by anyone hitting it: /why was
    host-only as a command while the new WHY CANNOT I BUILD button ran it for
    anybody, and /plotmenu was host-only while its own alias /myplot was not.
    Neither leaked anything -- the command was stricter than the button -- but
    both would read as the mod being broken.
    """
    import re
    game = read("Game.lua")

    block = game[game.index("local PLAYER_COMMANDS = {"):]
    block = block[:block.index("}")]
    allowed = set(re.findall(r'\["(/[a-z0-9]+)"\]', block))
    assert allowed, "could not read PLAYER_COMMANDS"

    for handler in sorted(GUEST_REACHABLE):
        m = re.search(r"^function\s+\w+\." + handler + r"\s*\(", game, re.M)
        if not m:
            continue
        end = game.find(chr(10) + "function ", m.end())
        body = game[m.end(): end if end != -1 else len(game)]
        for cmd in sorted(set(re.findall(r'sv_toWorld\(\s*"(/[a-z0-9]+)"', body))):
            assert cmd in allowed, (
                f"{handler} is guest-reachable and forwards {cmd}, which is not "
                f"in PLAYER_COMMANDS -- so the button runs it for a guest and "
                f"typing {cmd} answers 'Host only.'")


def every_network_handler_checks_the_sender():
    """The client half of this mod runs from the PLAYER'S disk.

    So every sendToServer in it is a message a modified client can send at
    will, with any payload it likes, at any time. A server handler therefore
    cannot treat "the panel only shows this button to the host" as a check --
    the panel is not what sent the message.

    The engine hands the real sender in as the third argument, and that is the
    only trustworthy answer to "who asked". This walks every sv_n_ handler and
    demands it either tests that argument or is named in GUEST_REACHABLE with a
    reason.

    Written after auditing T mod, whose whole host-takeover path is one
    unguarded RPC. See docs/MODS-AND-TRUST.md.
    """
    offenders, seen = [], 0
    for path in sorted(SCRIPTS.glob("*.lua")):
        src = io.open(path, encoding="utf-8").read()
        for m in re.finditer(r"^function\s+\w+\.(sv_n_\w+)\s*\(([^)]*)\)",
                             src, re.M):
            name, args = m.group(1), m.group(2)
            end = src.find('\nfunction ', m.end())
            body = src[m.end(): end if end != -1 else len(src)]
            seen += 1

            # A PLAYER SCRIPT'S HANDLER IS ALREADY SCOPED TO ITS OWNER, and it
            # is the one place in this engine where that is structural rather
            # than a convention. The engine instantiates one Player script per
            # player and routes a client's sendToServer to THAT client's own
            # instance -- so self.player is the sender, there is no third
            # argument to test, and vanilla's own CreativePlayer.sv_n_unstuck
            # takes ( self ) and nothing else.
            #
            # It holds only while the handler acts on self.player. The moment
            # one reads a player out of its payload the guarantee is gone and it
            # is an ordinary unguarded RPC again, so both halves are asserted.
            if path.name == "Player.lua":
                assert "self.player" in body, (
                    f"Player.lua: {name} does not act on self.player, so nothing "
                    "ties it to the client that sent it")
                for forged in ("params.player", "data.player", "args.player"):
                    assert forged not in body, (
                        f"Player.lua: {name} reads {forged} from its payload. A "
                        "player script's handler is safe only because it acts on "
                        "its OWN player -- take an identity from the wire and any "
                        "client can name anybody")
                continue

            assert "player" in args, (
                f"{path.name}: {name} does not take the sender as an argument, "
                f"so it cannot know who called it")

            if "getHostPlayer" in body or name in GUEST_REACHABLE:
                continue
            offenders.append(f"{path.name}:{name}")

    assert seen, "found no sv_n_ handlers at all -- the scan is broken"
    assert not offenders, (
        "these server handlers neither test the sender nor appear in "
        "GUEST_REACHABLE, so any modified client can call them: "
        + ", ".join(offenders))


def no_handler_trusts_an_identity_from_its_payload():
    """The caller is an argument. A player named in a message is a CLAIM.

    T mod's opCheck is the worked example of getting this wrong: it grants
    operator to data[3], a player id the client supplies, so whoever holds the
    key can op anybody rather than only themselves.
    """
    claim = re.compile(
        r"(?:data|params|args)\s*(?:\.\s*player\b|\[\s*['\"]player['\"]\s*\])")
    for path in sorted(SCRIPTS.glob("*.lua")):
        src = io.open(path, encoding="utf-8").read()
        for m in re.finditer(r"^function\s+\w+\.(sv_n_\w+)\s*\([^)]*\)",
                             src, re.M):
            end = src.find('\nfunction ', m.end())
            body = src[m.end(): end if end != -1 else len(src)]
            hit = claim.search(body)
            assert hit is None, (
                f"{path.name}: {m.group(1)} reads {hit.group(0)!r} out of its "
                f"payload. The sender is the third argument; a player named in "
                f"a message is only who the client SAYS it is.")


# ---------------------------------------------------------------- wardrobe ---
#
# The crowd bot's whole appearance is pure, which is the point of putting it in
# its own file: every one of these runs the real Lua and nothing is restated in
# Python. What they CANNOT prove is that the renderables draw -- for that,
# dev/check_uuids.py resolves all 84 paths against the install, and only the game
# can say whether a character wearing them looks right.

SEEDS = list(range(1, 201))


def _charset():
    """Every entry of the generated characterset, parsed the way the game does."""
    import glob
    out = []
    for path in glob.glob(str(ROOT / "mod" / "Characters" / "Database" /
                              "CharacterSets" / "*.characterset")):
        text = io.open(path, encoding="utf-8-sig").read()
        text = re.sub(r"//[^\n]*", "", text)
        text = re.sub(r",(\s*[}\]])", r"\1", text)
        out.extend(json.loads(text)["characters"])
    return out


def the_crowd_has_a_look_for_every_uuid_it_spawns():
    """The variety lives in the characterset, not in a runtime costume system.

    MEASURED cost of doing it the other way -- one entry, dressed per bot with
    overrideRenderableList:

        0 bots  60.0 fps     10 bots  15.0 fps     20 bots  8 fps

    against 30 fps for NINETY-FIVE bots in an earlier run where that code was
    throwing and every bot silently shared the fallback outfit. A fixed
    renderable list on an entry is loaded once and shared; a bespoke list per
    character cannot be batched. Vanilla agrees twice over:
    overrideRenderableList has exactly one caller in the whole game, and
    vanilla's ten different-looking mechanics are ten characterset entries.

    So: every uuid Crowd spawns must be an entry, and no entry may be orphaned.
    """
    lua = fresh("Crowd.lua")
    spawn = {str(u) for u in lua.globals().Crowd.BOT_UUIDS.values()}
    declared = {str(c["uuid"]).lower() for c in _charset()}

    assert spawn, "Crowd.BOT_UUIDS is empty"
    missing = spawn - declared
    assert not missing, (
        f"Crowd spawns {sorted(missing)}, which the characterset does not "
        f"declare -- those bots would fail to spawn at all")
    orphan = declared - spawn
    assert not orphan, (
        f"the characterset declares {sorted(orphan)} and nothing spawns them")
    assert len(spawn) >= 8, (
        f"only {len(spawn)} looks -- a crowd of twenty would be four of each")


def no_bot_wears_something_a_player_cannot():
    """'this cosmetic isnt even in the game. it is in the files yes. but not
    accesible.'

    The hand-built wardrobe pulled in every .rend on disk. Every path resolved,
    which proved the wrong thing -- a bot turned up in a backpack big enough to
    hide its torso. The renderables now come verbatim from characters that exist
    in the game, so this checks they still do rather than trusting the generator.
    """
    game_sets = []
    for rel in ("Survival/Character/CharacterSets/npc_mechanics.json",
                "Data/Character/CharacterSets/default.json"):
        text = io.open(GAME / rel, encoding="utf-8-sig").read()
        text = re.sub(r"//[^\n]*", "", text)
        text = re.sub(r",(\s*[}\]])", r"\1", text)
        game_sets.extend(json.loads(text)["characters"])
    allowed = {r for c in game_sets for r in c.get("renderables", [])}
    assert allowed, "found no vanilla renderables -- the scan is broken"

    for c in _charset():
        for r in c.get("renderables", []):
            assert r in allowed, (
                f"{c['name']} wears {r.rsplit('/', 1)[-1]}, which no in-game "
                f"character wears -- it may be on disk and unobtainable")


def every_look_is_complete_and_resolves():
    """A missing piece is not an error, it is a character with a hole in it."""
    entries = _charset()
    assert entries, "no characterset entries at all"

    for c in entries:
        rends = c.get("renderables", [])
        leaves = [r.rsplit("/", 1)[-1] for r in rends]

        for r in rends:
            p = str(r).replace("$GAME_DATA", "Data").replace("$SURVIVAL_DATA", "Survival")
            assert (GAME / p).is_file(), f"{c['name']}: missing {r}"

        assert any("_tp.rend" in l for l in leaves), f"{c['name']}: no animation rend"
        assert any("head" in l for l in leaves), f"{c['name']}: no head"
        # Either a modern outfit (jacket+legs) or the classic body (chest+legs).
        torso = any(("jacket" in l or "chest" in l) for l in leaves)
        legs = any(("pants" in l or "legs" in l) for l in leaves)
        assert torso, f"{c['name']}: nothing covering the torso"
        assert legs, f"{c['name']}: nothing covering the legs"

        for key in ("ragdoll",):
            v = str(c[key]).replace("$GAME_DATA", "Data").replace("$SURVIVAL_DATA", "Survival")
            assert (GAME / v).is_file(), f"{c['name']}: missing {key}"

        # A stand-in for a player has to move like one. Vanilla's NPC mechanics
        # sprint at 8.0, which is twice a player.
        assert abs(c["movement"]["sprintSpeed"] - 4.0) < 0.01, (
            f"{c['name']} sprints at {c['movement']['sprintSpeed']}, not a player's 4.0")


def a_crowd_shows_both_sexes():
    """Reported as "make sure gender is random too". With looks in the
    characterset it is a property of the LIST, not of a generator."""
    entries = {c["name"]: c for c in _charset()}
    female = [n for n in entries if "female" in n]
    male = [n for n in entries if "female" not in n]
    assert len(female) >= 3 and len(male) >= 3, (
        f"{len(male)} male and {len(female)} female looks -- a crowd would "
        f"read as one sex")

    # And the crowd must not hand them out so that a small crowd is all one sex.
    lua = fresh("Crowd.lua")
    order = [str(u) for u in lua.globals().Crowd.BOT_UUIDS.values()]
    by_uuid = {str(c["uuid"]).lower(): c["name"] for c in _charset()}
    first_six = [by_uuid[u] for u in order[:6]]
    assert any("female" in n for n in first_six), (
        f"the first six looks handed out are all male: {first_six}")


def bots_are_named_and_the_names_are_varied():
    lua = fresh("BotCharacter.lua")
    W = lua.globals().Wardrobe
    names = [W.Name(i) for i in SEEDS]
    for n in names:
        assert 3 <= len(n) <= 24, f"name {n!r} is {len(n)} chars"
        assert " " not in n, f"name {n!r} has a space"
    assert len(set(names)) >= len(names) * 0.9, (
        f"{len(set(names))} distinct names out of {len(names)}")
    # Same seed, same name, in a fresh state -- the name is derived on each
    # client independently and they have to agree.
    other = fresh("BotCharacter.lua")
    assert [other.globals().Wardrobe.Name(i) for i in SEEDS[:30]] == names[:30]


def a_character_script_never_reads_a_shared_global():
    """The bug that shipped twice, in two different disguises.

    A character or unit script is instantiated per character, and those
    instances do NOT share a thread -- the log showed the same error arriving
    from Logic Task 25332, 4764 and 22328. A bare `Wardrobe = {}` at the top of
    one instance's chunk therefore blanks the table another instance's callback
    is halfway through reading, and the symptom is
    "attempt to call field 'Name' (a nil value)" on a table that plainly has it.

    It survived being moved from its own file into this one, four hundred lines
    above its only caller, which is what finally ruled out every explanation
    except sharing.

    The invariant: **anything shared between the chunk and its callbacks must be
    an upvalue.** Assigning a global is allowed -- the test suite reaches the
    wardrobe that way, and the engine finds the class that way -- but READING one
    back is the bug.
    """
    # The scripts a characterset points at, which is what makes them character
    # scripts rather than ordinary ones.
    scripts = set()
    for path in (ROOT / "mod").rglob("*.characterset"):
        text = io.open(path, encoding="utf-8").read()
        for m in re.finditer(r'"scriptPath"\s*:\s*"[^"]*/([A-Za-z_]\w*)\.lua"', text):
            scripts.add(m.group(1) + ".lua")
    assert scripts, "no character scripts found -- the scan is broken"

    for name in sorted(scripts):
        src = io.open(SCRIPTS / name, encoding="utf-8").read()
        lines = [l for l in src.split("\n") if not l.lstrip().startswith("--")]

        # Globals this chunk assigns at top level (column 0, no `local`).
        assigned = set()
        for l in lines:
            m = re.match(r"^([A-Za-z_]\w*)\s*=\s*\S", l)
            if m:
                assigned.add(m.group(1))
        # The class name is assigned for the ENGINE to find; we never read it.
        klass = name[:-4]
        assigned.discard(klass)

        for g in sorted(assigned):
            readers = [
                l.strip() for l in lines
                if re.search(r"\b" + g + r"\s*[.\[]", l)
                or re.search(r"[(,=]\s*" + g + r"\s*[),]", l)
            ]
            assert not readers, (
                f"{name} reads the shared global {g!r}, which another instance "
                f"of this script can blank between chunk load and callback -- "
                f"make it a local and capture it as an upvalue. First: "
                f"{readers[0][:70]!r}")

        # And the class table is not a place to keep state either, for the same
        # reason -- it is one table shared by every instance.
        stashes = [l.strip() for l in lines
                   if re.match(r"^\s*" + klass + r"\.\w+\s*=", l)
                   and "function" not in l]
        assert not stashes, (
            f"{name} stores state on the shared class table: {stashes[0][:70]!r}")

        # THE CALLBACK SANDBOX IS SMALLER THAN THE CHUNK'S.
        #
        # MEASURED: setmetatable is available while the file is being executed
        # -- `class( nil )` on the next line works -- and GONE by the time a
        # callback runs:
        #
        #     ERROR: BotCharacter.lua:410: attempt to call global
        #            'setmetatable' (a nil value)
        #
        # It was reached from client_onCreate, so the chunk had long finished.
        # The tell, for the third time in this feature, was vanilla: ZERO of the
        # character scripts under Survival/Scripts/game/characters/ call
        # setmetatable. Closures do the same job and need nothing global.
        #
        # The others here are the same family and are NOT separately measured --
        # they are forbidden as a precaution, and if one is ever needed the way
        # to find out is a probe in game, not an assumption.
        for banned in ("setmetatable", "getmetatable", "rawset", "rawget",
                       "loadstring", "require"):
            used = [l.strip() for l in lines if re.search(r"\b" + banned + r"\s*\(", l)]
            assert not used, (
                f"{name} calls {banned}() -- the callback sandbox in a character "
                f"script does not have it (setmetatable is measured missing; the "
                f"rest are its family). Use a closure. First: {used[0][:60]!r}")


def naming_a_crowd_never_moves_math_random():
    """math.random is global and the city draws from it."""
    lua = fresh("BotCharacter.lua")
    lua.execute("math.randomseed( 12345 )")
    before = [lua.eval("math.random( 1, 1000000 )") for _ in range(5)]
    lua.execute("math.randomseed( 12345 )")
    for seed in range(1, 60):
        lua.globals().Wardrobe.Name(seed)
    after = [lua.eval("math.random( 1, 1000000 )") for _ in range(5)]
    assert before == after, "naming bots advanced math.random"


# --------------------------------------------------------------- crowd work ---
#
# Build mode is the owner's idea and the better of the two tests:
#
#   "we take the city. and the bots. the bots stand on their plots. and build up
#    with various blocks. this will make them build."
#
# It is better because accumulated content is what actually degraded in the one
# real event on record. It is also the mode that can do real damage if it is
# wrong -- a bot building outside its own plot is griefing the city with the
# host's own tool, and a bot whose blocks are not tracked leaves them standing
# after /crowd off.
#
# Crowd needs Plots and Layout for real (the pad geometry is the thing under
# test), so these build the actual grid rather than a stand-in.

CROWD_STUB = """
_imported = {}
_nextBody = 0
-- A body double that records what was imported and can be destroyed. Body flags
-- are the engine's; what matters here is the blueprint that was asked for.
function _import( bp )
    _nextBody = _nextBody + 1
    local child = bp.bodies[1].childs[1]
    local body = { id = _nextBody, dead = false, child = child,
                   destroyCreation = function( self ) self.dead = true end }
    _imported[#_imported+1] = body
    return { body }
end
"""


def _crowd(bots=4, mode="build"):
    lua = fresh("Layout.lua", "Palette.lua", "Settings.lua", "Plots.lua", "Crowd.lua")
    lua.execute(CROWD_STUB)
    g = lua.globals()

    plots = g.Plots()
    plots.sv_onCreate(plots, None)
    plots.enabled = True

    crowd = g.Crowd()
    crowd.sv_onCreate(crowd, plots)
    crowd.sv_setMode(crowd, mode)

    # The bot ROWS are built directly rather than through sv_spawnOne, because
    # sm.unit.createUnit is the engine's and there is nothing honest to fake
    # about it. What is under test here is the geometry -- which pad a plot
    # index maps to, and where a block lands inside it -- and that needs no unit.
    g._crowdRef = crowd
    indices = crowd.sv_plotIndices(crowd)
    # Styles are assigned round-robin rather than at random, so every one of them
    # is exercised on every run. A style that only builds outside its own plot
    # one time in four is not something to discover by luck.
    styles = [crowd.STYLES[i + 1] for i in range(len(crowd.STYLES))]
    for n in range(1, bots + 1):
        idx = indices[((n - 1) % len(indices)) + 1]
        lua.execute(
            "local c = _crowdRef\n"
            "c.bots[#c.bots+1] = { n = %d, unit = nil, perma = 'crowdbot:%d',\n"
            "    plot = %d, nextBuild = 0, blocks = {}, height = {}, pad = nil,\n"
            "    style = '%s' }"
            % (n, n, idx, styles[(n - 1) % len(styles)])
        )
    return lua, crowd, plots


def _place(lua, crowd, times):
    g = lua.globals()
    for i in range(len(crowd.bots)):
        bot = crowd.bots[i + 1]
        for _ in range(times):
            crowd.sv_placeBlock(crowd, bot, g._import)


def a_bot_only_ever_builds_on_its_own_plot():
    """A bot building outside its plot is the host griefing the city.

    The pad is the plot rectangle inset by the metal ring, and every block has to
    land inside it -- not on the ring, not on the road, not on a neighbour.
    """
    lua, crowd, plots = _crowd(bots=6)
    g = lua.globals()
    L, P = g.Layout, g.Plots
    _place(lua, crowd, 30)

    assert len(g._imported) > 0, "no blocks were placed at all"
    for i in range(len(crowd.bots)):
        bot = crowd.bots[i + 1]
        pad = crowd.sv_padFor(crowd, bot)
        col, row = L.plotColRow(plots.layout, bot["plot"])
        rect = L.plotRect(plots.layout, col, row)
        border = P.BORDER
        assert pad["x"] >= rect["x"] + border, "pad starts inside the metal ring"
        assert pad["x"] + pad["w"] <= rect["x"] + rect["w"] - border, \
            "pad runs past the ring"

        for k in range(len(bot["blocks"])):
            child = bot["blocks"][k + 1]["child"]
            x, y, z = child["pos"]["x"], child["pos"]["y"], child["pos"]["z"]
            assert pad["x"] <= x < pad["x"] + pad["w"], (
                f"bot on plot {bot['plot']} placed a block at x={x}, "
                f"pad is {pad['x']}..{pad['x'] + pad['w'] - 1}")
            assert pad["y"] <= y < pad["y"] + pad["h"], (
                f"bot on plot {bot['plot']} placed a block at y={y}, outside its pad")
            assert z >= P.DECK_Z + 1, f"a block was placed at z={z}, inside the deck"


def a_growing_world_never_reports_a_shrinking_census():
    """The false grief alarm the crowd found, and the reason /crowd exists.

    MEASURED in game with 95 bots building on 95 plots:

        GRIEF ALARM: 2101 shapes lost in 20s
        GRIEF ALARM: 4334 shapes lost in 20s

    Nothing was deleted. The world was growing the whole time.

    The patrol walks the body list a slice at a time and publishes a census when
    it reaches the end. It used to leave the cursor at n+1 and rely on the wrap
    at the top of the next tick -- but that guard is `cursor > n`, so once the
    world had grown by even one body the wrap never happened, the pass resumed
    near the end, and it published the shapes of those last few bodies as the
    whole-world total.

    The alarm compares the census against the peak in its window, so the small
    one read as the entire world vanishing -- and the alarm ARMS /lockdown. A
    real event with twenty people building fast is exactly that condition.

    Driven here against the real Protection, one tick at a time, with the world
    growing the way a crowd grows it.
    """
    lua = fresh("Settings.lua", "Protection.lua")
    lua.execute("""
        function isGhostBody( body ) return false end
        swTestBodies = {}
        function swAddBodies( howMany, shapesEach )
            for _ = 1, howMany do
                -- The eight permission flags the patrol reads and writes. Real
                -- enough that applyProfile does its true work: the census is
                -- what is under test, but it is counted inside the same loop.
                local b = { shapes = shapesEach, f = {} }
                function b:getShapeCount() return self.shapes end
                function b:isGhost() return false end
                local names = { "Buildable", "Erasable", "Connectable",
                    "Paintable", "Liftable", "Usable", "Destructable",
                    "ConvertibleToDynamic" }
                for _, nm in ipairs( names ) do
                    b["set" .. nm] = function( self, v ) self.f[nm] = v end
                    b["is" .. nm] = function( self ) return self.f[nm] end
                end
                swTestBodies[#swTestBodies + 1] = b
            end
        end
    """)
    g = lua.globals()
    prot = g.Protection()
    prot.sv_onCreate(prot, "open")
    # No resolver and no ground test: the census is what is under test, and
    # profileFor falls back to the mode's own profile without them.
    lua.execute("swAddBodies( 400, 1 )")

    def run(ticks):
        seen = []
        for _ in range(ticks):
            prot.sv_onFixedUpdate(prot)
            c = prot.sv_census(prot)
            if c is not None:
                seen.append(int(c))
        return seen

    run(20)                                   # let the first full pass land
    baseline = int(prot.sv_census(prot))
    assert baseline == 400, f"first census is {baseline}, expected 400"

    # Now grow it the way a crowd does: a couple of bodies every tick, for long
    # enough to cross several full passes.
    #
    # Only DISTINCT successive values matter. The census holds its last value
    # between passes, so reading it every tick would count the same number over
    # and over and hide the shape of the sequence.
    published = []
    for _ in range(400):
        lua.execute("swAddBodies( 2, 1 )")
        prot.sv_onFixedUpdate(prot)
        c = prot.sv_census(prot)
        if c is not None and (not published or int(c) != published[-1]):
            published.append(int(c))

    total = int(lua.eval("#swTestBodies"))
    assert len(published) >= 4, (
        f"only {len(published)} censuses were published over 400 ticks -- "
        f"the patrol is not completing passes")

    # THE INVARIANT: on a world that only ever grew, one census may never come
    # back dramatically smaller than the one before it. That is exactly the
    # full/tiny alternation the bug produced, and exactly what the alarm reads
    # as mass deletion.
    for prev, now in zip(published, published[1:]):
        assert now >= prev * 0.75, (
            f"census fell from {prev} to {now} on a world that only grew "
            f"(sequence {published[:8]}, now {total} bodies) -- the patrol "
            f"published a partial pass, and the grief alarm calls that "
            f"{prev - now} shapes deleted")

    assert max(published) <= total, (
        f"census {max(published)} exceeds the {total} bodies that exist")
    assert published[-1] >= total * 0.75, (
        f"final census {published[-1]} of {total} bodies")


def a_shrinking_world_never_reports_more_than_exists():
    """The other direction: a cell unloading mid-pass.

    The partial count of a world that no longer exists must not be carried into
    the next pass, or the census comes out LARGER than the world -- which sets
    the alarm's peak too high and makes the next honest reading look like a loss.
    """
    lua = fresh("Settings.lua", "Protection.lua")
    lua.execute("""
        function isGhostBody( body ) return false end
        swTestBodies = {}
        function swAddBodies( howMany, shapesEach )
            for _ = 1, howMany do
                -- The eight permission flags the patrol reads and writes. Real
                -- enough that applyProfile does its true work: the census is
                -- what is under test, but it is counted inside the same loop.
                local b = { shapes = shapesEach, f = {} }
                function b:getShapeCount() return self.shapes end
                function b:isGhost() return false end
                local names = { "Buildable", "Erasable", "Connectable",
                    "Paintable", "Liftable", "Usable", "Destructable",
                    "ConvertibleToDynamic" }
                for _, nm in ipairs( names ) do
                    b["set" .. nm] = function( self, v ) self.f[nm] = v end
                    b["is" .. nm] = function( self ) return self.f[nm] end
                end
                swTestBodies[#swTestBodies + 1] = b
            end
        end
        function swDropTo( n )
            while #swTestBodies > n do
                table.remove( swTestBodies )
            end
        end
    """)
    g = lua.globals()
    prot = g.Protection()
    prot.sv_onCreate(prot, "open")
    lua.execute("swAddBodies( 1000, 1 )")

    for _ in range(4):                        # part way through a pass
        prot.sv_onFixedUpdate(prot)
    lua.execute("swDropTo( 200 )")            # a cell unloads

    for _ in range(40):
        prot.sv_onFixedUpdate(prot)
        c = prot.sv_census(prot)
        if c is not None:
            assert int(c) <= 200, (
                f"census says {int(c)} shapes in a world of 200 bodies -- a "
                f"voided pass was carried into the next one")


def a_crowd_spreads_over_the_whole_city():
    """'theyre evolving! just side ways...'

    Plot indices run row by row, so taking the first N in order put every bot on
    plots 1..N -- the first couple of rows, along one edge. The screenshot was
    the whole crowd strung out in a line to the horizon.

    It is not a cosmetic problem. Twenty builders in one corner concentrate
    every cost this exists to measure -- draw calls, cell streaming, contact
    pairs, the patrol's locality -- into one part of the map, while a real lobby
    spreads over all of it.

    Measured as the SPAN of the columns and rows the crowd occupies, against
    what the whole city offers.
    """
    lua, crowd, plots = _crowd(bots=20)
    g = lua.globals()
    L = g.Layout
    layout = plots.layout

    cols, rows = [], []
    for i in range(len(crowd.bots)):
        c, r = L.plotColRow(layout, crowd.bots[i + 1]["plot"])
        cols.append(c)
        rows.append(r)

    span_c = max(cols) - min(cols) + 1
    span_r = max(rows) - min(rows) + 1
    assert span_c >= layout.cfg.cols * 0.6 and span_r >= layout.cfg.rows * 0.6, (
        f"20 bots cover {span_c}x{span_r} of a {layout.cfg.cols}x{layout.cfg.rows} "
        f"city -- they are bunched into a corner, not spread over it")

    # And a bot must KEEP its plot as the crowd grows, or /bench renumbers
    # everyone at every stage and no two rows are comparable.
    first_five = [crowd.sv_placeFor(crowd, n)[1] for n in range(1, 6)]
    again = [crowd.sv_placeFor(crowd, n)[1] for n in range(1, 6)]
    assert first_five == again, "plot assignment is not stable across calls"


def bots_own_their_plots_through_the_real_system():
    """'make so that they count as players. they claim their plots via the
    system.'

    The point is not cosmetic. A bot that owns nothing skips the half of this mod
    that costs anything -- sv_authorised, the team walk, the per-plot part budget,
    the empty-but-claimed lock -- all of which run per body per patrol slice. A
    crowd that owns nothing measures the cheap path and reports a healthy server.
    """
    lua, crowd, plots = _crowd(bots=8)

    assert crowd.claim is True, "claiming is off by default -- bots own nothing"

    claimed = crowd.sv_applyClaims(crowd)
    assert claimed == len(crowd.bots), (
        f"only {claimed} of {len(crowd.bots)} bots claimed a plot")

    # Owned through Plots, by the bot's own perma, one plot each -- the same
    # invariant a person is held to.
    owners = dict(plots.owners)
    for i in range(len(crowd.bots)):
        bot = crowd.bots[i + 1]
        assert owners.get(bot["plot"]) == bot["perma"], (
            f"plot {bot['plot']} is owned by {owners.get(bot['plot'])!r}, "
            f"not by {bot['perma']!r}")
        assert plots.sv_plotOf(plots, bot["perma"]) == bot["plot"]

    # And a bot must never take a plot off a person.
    plots.owners[crowd.bots[1]["plot"]] = None
    plots.sv_claim(plots, crowd.bots[1]["plot"], "a-real-person")
    crowd.sv_applyClaims(crowd)
    assert dict(plots.owners).get(crowd.bots[1]["plot"]) == "a-real-person", (
        "a bot took a plot that a real player owned")


def a_cleared_crowd_leaves_no_claims_behind():
    """Claims persist to Plots.json. A crashed test must not leave plots owned
    by a perma nobody can ever log in as -- the plot would be unclaimable and
    locked to everyone, forever, with no way to find out why."""
    lua, crowd, plots = _crowd(bots=6)
    crowd.sv_applyClaims(crowd)
    assert len(dict(plots.owners)) == 6

    # A real owner in the middle of it, who must survive the sweep.
    free = [i for i in crowd.sv_plotIndices(crowd).values()
            if dict(plots.owners).get(i) is None]
    plots.sv_claim(plots, free[0], "a-real-person")

    crowd.sv_releaseClaims(crowd)
    left = dict(plots.owners)
    assert left == {free[0]: "a-real-person"}, (
        f"sweep left {left} -- it must remove every crowdbot: and nothing else")


def teamed_bots_are_teamed_through_the_request_path():
    """Teams are the most expensive thing in the plot system: sv_authorised
    walks the team group for every body on every patrol slice. A crowd with no
    teams measures the cheap path.

    Formed by two real sv_request calls -- ask, then accept -- not by writing
    self.teams directly, which would skip sv_adjacent and sv_dirtyTeams and
    could produce a team across a road that the real game cannot make.
    """
    lua, crowd, plots = _crowd(bots=12)
    crowd.sv_applyClaims(crowd)

    formed = crowd.sv_formTeams(crowd)
    assert formed > 0, "no teams were formed at all"
    assert crowd.sv_teamCount(crowd) > 0, "teams formed but the count says none"

    # Every team must be one the real rules allow: adjacent, and sharing a
    # filler seam. A team across a road is not something a player could make.
    teams = plots.teams
    for a in list(teams.keys()):
        for b in list(dict(teams[a]).keys()):
            assert plots.sv_adjacent(plots, a, b), (
                f"plots {a} and {b} are teamed but are not neighbours -- "
                f"the team was written directly instead of requested")
            assert plots.sv_teamed(plots, a, b), "team is not symmetric"

    # And releasing a bot's plot must take its team links with it, or the
    # neighbour keeps a link to a plot nobody owns.
    gone = crowd.bots[1]["plot"]
    crowd.sv_releaseClaims(crowd)
    for a in list(plots.teams.keys()):
        assert gone not in dict(plots.teams[a]), (
            f"plot {a} still links to {gone} after its owner was released")


def every_build_style_builds_something_different():
    """'so like a lot of random bots. make random stuff.'

    Twenty bots all picking a uniformly random cell build the same thing twenty
    times -- one shape, tested repeatedly. The four styles exist so the crowd
    produces towers, walls, floors and mess, which differ in the ways that
    matter here: a tower touches few cells and goes up, a platform touches all of
    them and stays down, and the two load cell streaming and culling quite
    differently at the same block count.

    Each style is checked against the property that defines it, not against a
    fixed layout -- the cells inside it stay random.
    """
    # One bot per style, whatever the list grows to -- a style added without a
    # bot to exercise it would silently go unchecked.
    lua, crowd, plots = _crowd(bots=0)
    g = lua.globals()
    lua, crowd, plots = _crowd(bots=len(g.Crowd.STYLES))
    g = lua.globals()
    by_style = {}
    for i in range(len(crowd.bots)):
        bot = crowd.bots[i + 1]
        for _ in range(g.Crowd.MAX_BLOCKS):
            crowd.sv_placeBlock(crowd, bot, g._import)
        cells = [(bot["blocks"][k + 1]["child"]["pos"]["x"],
                  bot["blocks"][k + 1]["child"]["pos"]["y"])
                 for k in range(len(bot["blocks"]))]
        by_style[bot["style"]] = (cells, crowd.sv_padFor(crowd, bot))

    assert set(by_style) == set(g.Crowd.STYLES.values()), (
        f"only {sorted(by_style)} were exercised")

    tower_cells = len(set(by_style["tower"][0]))
    scatter_cells = len(set(by_style["scatter"][0]))
    assert tower_cells < scatter_cells, (
        f"tower touched {tower_cells} cells, scatter {scatter_cells} -- "
        f"a tower is supposed to concentrate")

    xs = {c[0] for c in by_style["wall"][0]}
    ys = {c[1] for c in by_style["wall"][0]}
    assert len(xs) == 1 or len(ys) == 1, (
        f"a wall spread over {len(xs)}x{len(ys)} cells -- it is not a line")

    # A platform fills before it stacks, so its tallest column is short.
    pcells = by_style["platform"][0]
    tallest = max(pcells.count(c) for c in set(pcells))
    tcells = by_style["tower"][0]
    tower_tallest = max(tcells.count(c) for c in set(tcells))
    assert tallest < tower_tallest, (
        f"platform stacked {tallest} high and tower only {tower_tallest} -- "
        f"the two styles are the wrong way round")


def bots_build_up_and_stay_inside_the_height_cap():
    """'build up with various blocks' -- so it has to actually stack.

    A height map that never increments would place every block at deck level and
    the tower would be a floor, which looks fine in the results file and is a
    completely different render and physics shape.
    """
    lua, crowd, plots = _crowd(bots=3)
    g = lua.globals()
    _place(lua, crowd, 40)

    heights = set()
    for i in range(len(crowd.bots)):
        bot = crowd.bots[i + 1]
        for k in range(len(bot["blocks"])):
            heights.add(bot["blocks"][k + 1]["child"]["pos"]["z"])
    assert len(heights) > 1, "every block landed at the same height -- nothing stacked"

    base = g.Plots.DECK_Z + 1
    assert max(heights) <= base + g.Crowd.MAX_STACK - 1, (
        f"a column reached z={max(heights)}, past the MAX_STACK cap")

    for i in range(len(crowd.bots)):
        bot = crowd.bots[i + 1]
        assert len(bot["blocks"]) <= g.Crowd.MAX_BLOCKS, (
            f"a bot placed {len(bot['blocks'])} blocks, past MAX_BLOCKS")


def a_crowd_builds_out_of_various_blocks():
    """'various blocks' was the request, and one repeated block is a different
    render cost -- different materials mean different textures and draw batches."""
    lua, crowd, plots = _crowd(bots=6)
    g = lua.globals()
    _place(lua, crowd, 30)

    uuids, colours = set(), set()
    for b in range(len(g._imported)):
        child = g._imported[b + 1]["child"]
        uuids.add(child["shapeId"])
        colours.add(child["color"])

    assert len(uuids) >= 8, f"only {len(uuids)} distinct materials in {len(g._imported)} blocks"
    assert len(colours) >= 8, f"only {len(colours)} distinct colours"

    # Every one has to be a real block, or the import silently produces nothing.
    real = {g.Palette.MATERIALS[k]["uuid"] for k in g.Palette.MATERIAL_ORDER.values()}
    assert uuids <= real, f"a bot placed a uuid that is not in the palette: {uuids - real}"


def clearing_the_crowd_takes_the_buildings_with_it():
    """A test tool that leaves its rubbish standing is worse than no test tool.

    The blocks are separate bodies welded to nothing, so nothing else in the mod
    would ever collect them -- not the patrol, not /purge walkways, not the
    cleaner unless somebody clicks every one.
    """
    lua, crowd, plots = _crowd(bots=5)
    g = lua.globals()
    _place(lua, crowd, 20)

    placed = len(g._imported)
    assert placed > 0, "nothing was built, so the test proves nothing"
    assert crowd.sv_blockCount(crowd) == placed, "the crowd lost track of its blocks"

    for i in range(len(crowd.bots)):
        crowd.sv_dropBlocks(crowd, crowd.bots[i + 1])

    assert crowd.sv_blockCount(crowd) == 0, "blocks remained on the books"
    alive = [b + 1 for b in range(len(g._imported)) if not g._imported[b + 1]["dead"]]
    assert not alive, f"{len(alive)} of {placed} bodies were never destroyed"


def churn_mode_never_lets_the_world_grow():
    """Churn is the steady-state mode: it exists so a /bench run measures the
    same amount of world at every stage. If it accumulated, it would be build
    mode with extra steps and the per-bot number would drift stage by stage."""
    lua, crowd, plots = _crowd(bots=4, mode="churn")
    g = lua.globals()

    peak = 0
    for _ in range(30):
        crowd.sv_stepWork(crowd, 10 ** 9, g._import)   # every timer is due
        peak = max(peak, crowd.sv_blockCount(crowd))

    assert peak > 0, "churn never placed anything"
    assert peak <= len(crowd.bots), (
        f"churn accumulated {peak} blocks for {len(crowd.bots)} bots -- "
        f"it is supposed to put back exactly what it takes away")


def the_crowd_cannot_flood_the_server_with_imports():
    """Per-bot timers are randomised, but 'should never all land together' is not
    a guarantee -- and a burst of imports would show up as a spike the run blames
    on the bot count instead of on itself."""
    lua, crowd, plots = _crowd(bots=40)
    g = lua.globals()

    before = len(g._imported)
    crowd.sv_stepWork(crowd, 10 ** 9, g._import)       # every one of the 40 is due
    placed = len(g._imported) - before

    assert placed <= g.Crowd.PLACE_PER_TICK, (
        f"{placed} blocks imported in one tick, cap is {g.Crowd.PLACE_PER_TICK}")


# ------------------------------------------------------------------- bench ---
#
# The arithmetic in Bench.lua is the kind that fails QUIETLY: get the settle
# discard wrong and every row is 20% low, use ticks as the clock and every row
# reads exactly 40 Hz however bad it got. A benchmark that lies is worse than no
# benchmark, because it gets believed.
#
# These drive the real Bench against a fake crowd and fed samples, so the numbers
# below are the ones the game would produce from the same input.

BENCH_STUB = """
-- A crowd that costs nothing and always succeeds, so a bench test measures the
-- bench. Crowd itself is exercised in game; there is nothing to fake about it
-- here that would not just be restating it.
_crowdSize = 0
_fakeCrowd = {
    churn = false,
    sv_clear = function( self ) _crowdSize = 0 end,
    sv_set = function( self, n ) _crowdSize = math.min( n, _crowdCap or 1000 ); return _crowdSize end,
}
Crowd = { MAX = 128 }
g_swProtection = { sv_census = function( self ) return _censusShapes or 1000 end }
_replies = {}
function _reply( t ) _replies[#_replies+1] = t end
"""


def _bench(cap=1000):
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(STUB)
    lua.execute(BENCH_STUB)
    lua.execute(f"_crowdCap = {cap}")
    lua.execute(io.open(SCRIPTS / "Bench.lua", encoding="utf-8").read())
    g = lua.globals()
    b = g.Bench()
    b.sv_onCreate(b, g._fakeCrowd)
    return lua, b


def _feed(lua, b, seconds, fps, tick_hz, start_tick=0):
    """One-second samples from the host, at a given frame and tick rate.

    The tick figure is a DELTA over the same second the frames cover, which is
    what the client actually sends -- see the note in Game.client_onUpdate.
    """
    for _ in range(seconds):
        b.sv_sample(b, "HOST", True, fps, 1.0, tick_hz)
    return start_tick + seconds * tick_hz


def the_bench_reports_the_frame_rate_it_was_given():
    lua, b = _bench()
    g = lua.globals()
    b.sv_start(b, 5, 10, 10, g._reply)

    # SETTLE first. Bench.SETTLE seconds of samples are meant to be DISCARDED --
    # they are the price of spawning, not of standing -- so they are fed at a
    # deliberately wrong frame rate. If any of it leaks into the row, the number
    # below moves.
    tick = _feed(lua, b, int(g.Bench.SETTLE), 5, 40)
    tick = _feed(lua, b, 10, 60, 40, tick)

    rows = b.rows
    assert len(rows) >= 1, "no row was recorded after a full window"
    r = rows[1]
    assert abs(r["fps"] - 60) < 0.01, (
        f"fed 60 fps, recorded {r['fps']:.2f} -- the settle samples leaked in")
    assert abs(r["tickRate"] - 40) < 0.01, f"fed 40 Hz, recorded {r['tickRate']:.2f}"
    assert r["bots"] == 0, "the first row must be the empty-city baseline"


def a_starved_server_does_not_report_forty_hertz():
    """The trap this whole design exists to avoid.

    sm.game.getCurrentTick() is the simulation counter. Time a stage in ticks and
    divide ticks by ticks and the answer is 40 Hz no matter how badly the server
    is doing -- a benchmark that reports perfect health under any load. The wall
    clock has to come from client_onUpdate's dt, and this proves it does.
    """
    lua, b = _bench()
    g = lua.globals()
    b.sv_start(b, 5, 10, 10, g._reply)
    tick = _feed(lua, b, int(g.Bench.SETTLE), 12, 18)
    _feed(lua, b, 10, 12, 18, tick)          # 18 ticks per REAL second

    r = b.rows[1]
    assert abs(r["tickRate"] - 18) < 0.01, (
        f"server ran at 18 Hz, bench says {r['tickRate']:.1f} -- it is timing "
        f"itself with the counter it is measuring")
    assert abs(r["fps"] - 12) < 0.01, f"fed 12 fps, recorded {r['fps']:.2f}"


def the_bench_walks_the_crowd_up_and_stops():
    lua, b = _bench()
    g = lua.globals()
    step, window, cap = 5, 10, 20
    b.sv_start(b, step, window, cap, g._reply)

    tick = 0
    for _ in range(400):
        tick = _feed(lua, b, 1, 60, 40, tick)
        if not b.sv_running(b):
            break

    assert not b.sv_running(b), "the bench never finished"
    got = [b.rows[i + 1]["bots"] for i in range(len(b.rows))]
    assert got == [0, 5, 10, 15, 20], f"stages were {got}, expected 0,5,10,15,20"

    # It must have disarmed the probe on the way out, or every client keeps
    # sending a message a second forever.
    arms = [e for e in [b and lua.globals()._events[i + 1]
                        for i in range(len(lua.globals()._events))]
            if e["name"] == "sv_e_swBenchArm"]
    assert arms, "the probe was never armed"
    assert arms[-1]["params"]["on"] is False, "the probe was left armed"


def the_bench_stops_early_if_the_crowd_will_not_grow():
    """A row labelled '40 bots' with 12 standing is a lie in the results file."""
    lua, b = _bench(cap=12)
    g = lua.globals()
    b.sv_start(b, 5, 10, 40, g._reply)

    tick = 0
    for _ in range(400):
        tick = _feed(lua, b, 1, 60, 40, tick)
        if not b.sv_running(b):
            break

    assert not b.sv_running(b), "the bench never finished against a capped crowd"
    for i in range(len(b.rows)):
        assert b.rows[i + 1]["bots"] <= 12, (
            f"a row claims {b.rows[i + 1]['bots']} bots but only 12 could spawn")


def a_wild_frame_sample_is_thrown_away():
    """One alt-tabbed client can hand over a single enormous dt.

    In a thirty-second mean that is enough to move the answer, and it looks
    entirely plausible in the results file afterwards.
    """
    lua, b = _bench()
    g = lua.globals()
    b.sv_start(b, 5, 10, 10, g._reply)
    tick = _feed(lua, b, int(g.Bench.SETTLE), 60, 40)

    for _ in range(5):
        b.sv_sample(b, "HOST", True, 60, 1.0, 40)
    # 90 seconds in one sample: an alt-tab, not a measurement.
    b.sv_sample(b, "HOST", True, 3, 90.0, 3600)
    for _ in range(5):
        b.sv_sample(b, "HOST", True, 60, 1.0, 40)

    r = b.rows[1]
    assert abs(r["fps"] - 60) < 0.01, (
        f"a 90-second sample was averaged in: {r['fps']:.2f} fps")


def the_results_survive_a_restart():
    lua, b = _bench()
    g = lua.globals()
    b.sv_start(b, 5, 10, 5, g._reply)
    tick = 0
    for _ in range(200):
        tick = _feed(lua, b, 1, 60, 40, tick)
        if not b.sv_running(b):
            break
    assert len(b.rows) >= 2, "not enough rows to be worth persisting"
    before = [b.rows[i + 1]["fps"] for i in range(len(b.rows))]

    fresh_bench = g.Bench()
    fresh_bench.sv_onCreate(fresh_bench, g._fakeCrowd)
    assert len(fresh_bench.rows) == 0, "a fresh Bench started with rows"
    fresh_bench.sv_load(fresh_bench)
    after = [fresh_bench.rows[i + 1]["fps"] for i in range(len(fresh_bench.rows))]
    assert before == after, f"results did not round-trip: {before} vs {after}"


def a_guest_cannot_drive_the_run():
    """The host's sample is the stage timer AND the whole tick-rate column.

    Game.sv_n_benchSample resolves host-ness from the engine's sender argument
    rather than from the payload, and this is the other half of that: a sample
    that did not come from the host must move nothing except that guest's own
    frame-rate row.
    """
    lua, b = _bench()
    g = lua.globals()
    b.sv_start(b, 5, 10, 10, g._reply)

    for _ in range(200):
        b.sv_sample(b, "GUEST", False, 5, 1.0, 5)
    assert b.state == "settle", (
        "guest samples advanced the run past settle -- a guest can drive it")
    assert len(b.rows) == 0, "guest samples recorded a row on their own"

    tick = _feed(lua, b, int(g.Bench.SETTLE), 60, 40)
    _feed(lua, b, 10, 60, 40, tick)
    r = b.rows[1]
    assert abs(r["fps"] - 60) < 0.01, (
        f"the guest's 5 fps leaked into the host column: {r['fps']:.2f}")
    names = {r["clients"][i + 1]["name"] for i in range(len(r["clients"]))}
    assert "HOST" in names, "the host is missing from the per-client rows"


def every_key_sent_across_the_bridge_is_read_on_the_far_side():
    """A world script has no network, so every client message hops
    client -> Game (sv_n_) -> sm.event.sendToWorld -> World (sv_e_).

    A key renamed on one side and not the other is silent: the far side reads
    nil, and nil falls through whatever type check is there and contributes
    nothing. MEASURED: Game sent `ticks` while World read `params.tick`, and the
    benchmark's whole tick-rate column reported 0.0 -- a server that does not
    tick at all -- with no error anywhere.

    Matches the keys of each sendToWorld table against what the handler it names
    actually reads out of params.
    """
    game = io.open(SCRIPTS / "Game.lua", encoding="utf-8").read()
    world = io.open(SCRIPTS / "World.lua", encoding="utf-8").read()

    # [^{}]* so the payload cannot run past its own closing brace into the next
    # table. The greedy version swept a one-line payload up into a later block
    # and reported keys that were never sent -- a check that cries wolf gets
    # switched off, which is worse than not having it.
    sends = re.findall(
        r'sendToWorld\(\s*\w+\s*,\s*"(sv_e_\w+)"\s*,\s*\{([^{}]*)\}\s*\)',
        game, re.S)
    assert sends, "no sendToWorld payloads found -- the scan is broken"

    checked = 0
    for handler, payload in sends:
        keys = set(re.findall(r"^\s*(\w+)\s*=", payload, re.M))
        # cmd/args/player are the generic command envelope, read via locals.
        keys -= {"cmd", "args", "player"}
        if not keys:
            continue
        m = re.search(r"function World\." + handler + r"\b.*?(?=\nfunction )",
                      world, re.S)
        if m is None:
            continue          # covered by every_world_command_has_a_branch
        body = m.group(0)
        read = set(re.findall(r"params\.(\w+)", body))
        # A handler may forward params wholesale rather than by key.
        if re.search(r"\bparams\s*\)", body) and not read:
            continue
        for k in sorted(keys):
            assert k in read, (
                f"Game sends {k!r} to {handler} and World never reads "
                f"params.{k} -- it reads {sorted(read)}. A renamed key is "
                f"silent: the far side just gets nil.")
        checked += 1

    assert checked, "matched no payloads to handlers -- the scan is broken"


def every_world_command_has_a_branch():
    """A chat command routed to the world with nothing to answer it is silent.

    Exactly how CLEAR CITY was dead for a version: Game forwarded /citycensus and
    World had no branch, so the panel closed and nothing happened.
    """
    game = io.open(SCRIPTS / "Game.lua", encoding="utf-8").read()
    world = io.open(SCRIPTS / "World.lua", encoding="utf-8").read()

    table = re.search(r"local WORLD_COMMANDS = \{(.*?)\n\}", game, re.S)
    assert table, "WORLD_COMMANDS table not found in Game.lua"
    routed = set(re.findall(r'\["(/\w+)"\]', table.group(1)))
    assert routed, "WORLD_COMMANDS parsed as empty -- the scan is broken"

    answered = set(re.findall(r'cmd == "(/\w+)"', world))
    orphans = sorted(routed - answered)
    assert not orphans, (
        "these commands are routed to the world and nothing there answers them, "
        "so they do nothing at all: " + ", ".join(orphans))


# ------------------------------------------------------------------ focus ---
#
# "an admin tool. with the tool you can search for nicknames that are curently
# on the server. and when selected it will highlight them. so people can see
# the focus person."
#
# Three pieces: FocusGui picks, Game.lua owns who it is, Focus.lua draws it on
# every client. Only the first is pure enough to run outside the game, so the
# checks below are honest about what they cover -- searching, paging, layout,
# and the two structural rules that have cost this project a crash each.


def focus_search_finds_a_name_by_any_part_of_it():
    """Substring, case insensitive, and safe against a name full of punctuation.

    The failure this guards is specific. string.find defaults to PATTERN
    matching, and a Steam name may legally contain "%", "(", "-" or "+", all of
    which are pattern syntax. Without plain = true, typing a "(" does not
    return no matches -- it throws, and takes the whole panel with it.
    """
    lua = fresh("FocusGui.lua")
    G = lua.globals().FocusGui
    roster = lua.table_from([lua.table_from(r) for r in (
        {"id": 1, "name": "JuneCarya"},
        {"id": 2, "name": "carl"},
        {"id": 3, "name": "100% Mechanic"},
        {"id": 4, "name": "[SW] zeb-o"},
    )])

    def names(query):
        return [str(p["name"]) for p in G.Filter(roster, query).values()]

    assert names("") == ["JuneCarya", "carl", "100% Mechanic", "[SW] zeb-o"], \
        "an empty search hides people"
    assert names("car") == ["JuneCarya", "carl"], f"'car' matched {names('car')}"
    assert names("CAR") == ["JuneCarya", "carl"], "the search is case sensitive"
    assert names("  car  ") == ["JuneCarya", "carl"], "surrounding spaces break it"
    assert names("nobody") == [], "a search that should match nothing matched something"

    # the punctuation cases, each of which is a pattern metacharacter
    for query, want in (("%", ["100% Mechanic"]),
                        ("[SW]", ["[SW] zeb-o"]),
                        ("zeb-o", ["[SW] zeb-o"]),
                        ("100%", ["100% Mechanic"])):
        assert names(query) == want, (
            f"searching {query!r} gave {names(query)}, expected {want} -- "
            "string.find needs plain = true or punctuation is read as a pattern")


def focus_paging_shows_every_name_exactly_once():
    """Page through a full lobby and get everybody back, in order, no repeats.

    /crowd can put 128 names in this list and a real event puts twenty, so the
    pager is the difference between a usable panel and one where half the lobby
    is unreachable. An off-by-one in the slice would drop or repeat a name per
    page, which is invisible on page 1 and infuriating on page 9.
    """
    lua = fresh("FocusGui.lua")
    G = lua.globals().FocusGui
    rows = int(G.ROWS)
    for total in (0, 1, rows - 1, rows, rows + 1, 128):
        roster = lua.table_from([lua.table_from({"id": i, "name": f"player{i:03d}"})
                                 for i in range(1, total + 1)])
        seen, pages_seen = [], None
        page = 1
        while True:
            slice_, got_page, pages = G.Page(roster, page)
            pages_seen = int(pages)
            assert int(got_page) == page, f"{total}: asked for page {page}, got {got_page}"
            seen += [str(p["name"]) for p in slice_.values()]
            if page >= pages_seen:
                break
            page += 1
        want = [f"player{i:03d}" for i in range(1, total + 1)]
        assert seen == want, (
            f"{total} names over {pages_seen} page(s) came back as {len(seen)}: "
            f"{'duplicated' if len(seen) > total else 'lost'} entries")

    # A stale page number lands on the last page, not on an empty panel. The
    # panel keeps its page across a search, so narrowing a list from nine pages
    # to one while sitting on page 9 is the ordinary case, not the odd one.
    roster = lua.table_from([lua.table_from({"id": 1, "name": "only"})])
    for asked in (0, -5, 99, None):
        slice_, page, pages = G.Page(roster, asked)
        assert int(page) == 1 and int(pages) == 1 and len(slice_) == 1, (
            f"page {asked!r} of a one-name list gave page {page}/{pages} "
            f"with {len(slice_)} row(s)")


def the_focus_panel_fits_in_every_state():
    lua = gui_lua()
    G = lua.globals().FocusGui
    full = [{"id": i, "name": f"a rather long player name {i}", "perma": f"SW-{i:04d}",
             "plot": i} for i in range(1, int(G.ROWS) + 4)]

    def build(state):
        state = dict(state)
        if "players" in state:
            state["players"] = lua.table_from(
                [lua.table_from(r) for r in state["players"]])
        if "focus" in state:
            state["focus"] = lua.table_from(state["focus"])
        return G.Build(lua.table_from(state))

    for label, state in (
            ("nobody online", {}),
            ("one page", {"players": full[:3], "bots": 0}),
            ("a full page and a pager", {"players": full, "bots": 128}),
            ("no match", {"players": full, "query": "zzzz"}),
            ("somebody focused", {"players": full,
                                  "focus": {"id": 1, "name": "a rather long player name 1"},
                                  "status": "focusing a rather long player name 1 -- "
                                            "everyone can see the marker"}),
            ("last page", {"players": full, "page": 99}),
    ):
        root = build(state)
        items = panel_fits(f"focus ({label})", root, G.W, G.H)
        no_button_is_buried(f"focus ({label})", items, G.H)


def nothing_on_the_focus_panel_sits_on_top_of_anything_else():
    """No two pieces of text or buttons share pixels, bar a header and its sub.

    panel_fits() proves every widget is INSIDE the panel and
    no_button_is_buried() proves no two buttons collide. Neither can see a
    status line drawn on top of a page counter, which is exactly what this
    panel did at 620 tall: the footer rule sat at H-78 while the pager row ran
    to 562, so the two shared five rows of pixels. Everything was inside the
    panel and every button was reachable, and it was still wrong.

    Same shape as the city-map bug in CLAUDE.md -- the partition was intact, it
    was the KIND of piece that was wrong, and a check that verifies coverage
    cannot see that.

    A header and the subtitle tucked under it DO overlap by design, in every
    panel this mod has. That one pair is allowed and nothing else is.
    """
    import itertools
    lua = gui_lua()
    G = lua.globals().FocusGui
    rows = [{"id": i, "name": f"a player called {i}", "perma": f"SW-{i:04d}",
             "plot": i} for i in range(1, int(G.ROWS) * 3)]

    def build(**extra):
        state = {"players": lua.table_from([lua.table_from(r) for r in rows])}
        state.update(extra)
        if "focus" in state:
            state["focus"] = lua.table_from(state["focus"])
        return G.Build(lua.table_from(state))

    for label, root in (
            ("empty", G.Build(lua.table_from({}))),
            ("paged", build(page=1, bots=128)),
            ("last page", build(page=99)),
            ("focused", build(focus={"id": 1, "name": "a player called 1"},
                              status="focusing a player called 1 -- everyone "
                                     "can see the marker")),
            ("no match", build(query="zzzz")),
    ):
        items = [i for i in walk(root, []) if i["name"] != "BackPanel"]
        for a, b in itertools.combinations(items, 2):
            # Widget is a background, a rule or a row fill -- those are MEANT to
            # sit under things. Only text and buttons are checked.
            if a["type"] == "Widget" or b["type"] == "Widget":
                continue
            if {a["name"], b["name"]} == {"Title", "Sub"}:
                continue
            clash = (a["x"] < b["x"] + b["w"] and a["x"] + a["w"] > b["x"]
                     and a["y"] < b["y"] + b["h"] and a["y"] + a["h"] > b["y"])
            assert not clash, (
                f"focus ({label}): {a['name']!r} and {b['name']!r} share pixels "
                f"-- {a['name']} is at ({a['x']},{a['y']}) {a['w']}x{a['h']}, "
                f"{b['name']} at ({b['x']},{b['y']}) {b['w']}x{b['h']}")


def the_focus_panel_has_exactly_one_typed_box():
    """One EditBox, and the handler behind it draws nothing at all.

    Both rules are paid for. The event clock crashed the game twice over typed
    input: once from rendering inside the text callback, and again AFTER that
    redraw had been deferred by a tick -- which says the hazard is the focus
    transfer between two EditBoxes and not the timing. The base game has exactly
    one editable box in one editable panel (DigitalSign.gui).

    So this panel gets one box, and cl_onFocusSearchTyped is allowed to send and
    nothing else. Sending is safe and is what vanilla does from inside a click
    callback (CreativePlayer.lua:48); it is destroying widgets that kills the
    callback that is running.
    """
    lua = gui_lua()
    G = lua.globals().FocusGui
    root = G.Build(lua.table_from({
        "players": lua.table_from([lua.table_from({"id": 1, "name": "somebody"})])}))

    boxes = [n for n in walk_raw(root) if n["Type"] == "EditBox"]
    assert len(boxes) == 1, (
        f"the focus panel has {len(boxes)} EditBoxes -- moving focus between two "
        "of them is what crashed the game twice")
    box = boxes[0]
    assert str(box["Name"]) == str(G.SEARCH_BOX), (
        f"the search box is called {box['Name']!r} but FocusGui.SEARCH_BOX says "
        f"{G.SEARCH_BOX!r}, so the handler cannot tell which box was typed into")
    assert box["Static"] is False, (
        "the search box is Static -- it would display text and never accept any")
    assert box["NeedKey"] is True, "the search box cannot take the keyboard"
    assert box["onTextEnter"] is not None, "the search box has no onTextEnter"

    game = read("Game.lua")
    handler = game[game.index("function Game.cl_onFocusSearchTyped"):]
    handler = handler[:handler.index(chr(10) + "end")]
    for banned in ("cl_showPanel", "cl_renderLater", "cl_closeLater", ":render("):
        assert banned not in handler, (
            f"cl_onFocusSearchTyped calls {banned} -- a text callback that "
            "touches the GUI crashed the game twice, and deferring was not "
            "enough. It may send and nothing else.")


def the_focus_marker_is_drawn_from_the_world_not_the_game():
    """The compass needs a world. A Game script has none, and this is measured.

    PlotMarker spent several versions never appearing because it was driven from
    Game.lua:

      WARNING: compass marker unavailable: PlotMarker.lua:72:
               Calling world dependent functions in a no world script!

    Going via the player script gave the same warning verbatim. The world's own
    client is the one context that certainly has a world, and it is where every
    vanilla caller of the compass lives -- so the focus marker goes the same way,
    and this check stops it drifting back.
    """
    game, world, focus = read("Game.lua"), read("World.lua"), read("Focus.lua")

    assert "g_compassHud" not in game, (
        "Game.lua touches g_compassHud -- a Game script has no world and every "
        "compass call from one fails with 'Calling world dependent functions in "
        "a no world script'")
    assert "sm.effect.createEffect" not in game, (
        "Game.lua creates an effect -- effects belong to a world; drive them "
        "from World.lua's client, the way Focus.lua is driven")

    # Comments stripped first. A commented-out call still contains the string,
    # and a check that a commented-out line satisfies is not a check.
    live = chr(10).join(l for l in world.splitlines()
                        if not l.strip().startswith("--"))
    tick = live[live.index("function World.client_onFixedUpdate"):]
    tick = tick[:tick.index(chr(10) + "end")]
    assert "Focus.Cl_Step()" in tick, (
        "World.client_onFixedUpdate never calls Focus.Cl_Step, so a marker whose "
        "target was still loading when it was set would never appear at all, and "
        "a respawn would leave it floating where the player died")
    assert "cl_n_swFocus" in live and "sendToClients" in live, (
        "the focus push does not reach every client -- the whole point is that "
        "EVERYBODY sees the marker, not just the host who set it")

    # The effectset is the one part of this feature with no precedent in the
    # mod, so there has to be a way for it to fail that is not an error per
    # frame. createEffect on a name the engine does not know THROWS, which
    # makes the pcall the existence test -- and the last name tried has to be
    # base content, or a failed effectset means no marker at all.
    lua = fresh("Focus.lua")
    F = lua.globals().Focus
    names = [str(n) for n in F.MARKER_EFFECTS.values()]
    assert len(names) >= 2, (
        f"Focus.MARKER_EFFECTS is {names} -- with no fallback, an effectset the "
        "engine does not load leaves the feature with nothing to draw")
    assert names[-1] == "QuestMarker_Far", (
        f"the last marker tried is {names[-1]!r}, which is not base content. "
        "The fallback has to be something the game certainly ships.")
    assert focus.count("pcall") >= focus.count("sm.effect.createEffect"), (
        "Focus.lua creates more effects than it has pcalls -- an unknown effect "
        "name throws, and an error per frame is the largest performance bug "
        "this project has measured")


def a_focus_never_outlives_the_player_it_marks():
    """The plumbing that clears a marker when its target leaves.

    There is no player-left callback on this class, so a marker over somebody
    who disconnected would hang in the air until a host noticed. It is checked
    on the same once-a-second beat as the roster.

    String matching, which proves the wiring exists rather than that it works --
    but a name on one side of a bridge and nowhere on the other has always been
    a real bug here, and it was exactly this one for the panel plumbing.
    """
    game = read("Game.lua")
    for needed, why in (
            ("sv_checkFocusAlive", "nothing notices the focused player leaving"),
            ("sv_pushFocus", "nothing tells the clients who is focused"),
            ("sv_setFocus", "there is no single place that changes the focus"),
            ("focusRepush", "a client that joins mid-focus is never told")):
        assert game.count(needed) >= 2, (
            f"{needed} is defined or called fewer than twice -- {why}")

    body = game[game.index("function Game.sv_checkFocusAlive"):]
    body = body[:body.index(chr(10) + "end")]
    assert "sm.exists" in body and "sv_pushFocus" in body, (
        "sv_checkFocusAlive does not test the player and re-push, so a marker "
        "would stay up over somebody who has gone")


def only_the_host_can_point_the_lobby_at_somebody():
    """Every door into the focus is host gated, and NO SETTING CAN OPEN ONE.

    There are five doors: the tool's client half, the tool's server half, the
    Game-script bridge the tool talks through, the panel action, and the chat
    command. A guest who could mark anybody they liked has a toy for annoying
    people, not an admin tool -- and the marker is drawn on every screen in the
    world, which is the one thing in this mod a guest cannot otherwise do.

    This is STRICTER than the other host tools on purpose. `hostcleaner`,
    `hostlift` and `hostnotlift` each let a host hand out a tool that changes
    the WORLD, where the server-side rules on that tool still apply. Focus
    changes what is drawn on everybody else's SCREEN, and there is no half of
    that to delegate -- so the gate is `sm.player.getHostPlayer()` everywhere
    with nothing in front of it. The check that matters most here is the one
    that no `hostfocus` exists to relax it.
    """
    game, tool = read("Game.lua"), read("FocusTool.lua")

    handler = game[game.index("function Game.sv_n_focusGuiAction"):]
    handler = handler[:handler.index(chr(10) + "end")]
    assert "getHostPlayer" in handler, "the panel action does not check the sender"

    bridge = game[game.index("function Game.sv_e_swFocus"):]
    bridge = bridge[:bridge.index(chr(10) + "end")]
    assert "getHostPlayer" in bridge, (
        "Game.sv_e_swFocus does not check the sender -- an event is reachable by "
        "anything sharing this Lua environment, so the class that owns the state "
        "has to be the class that decides")

    tool_sv = tool[tool.index("function FocusTool.sv_n_swFocus"):]
    assert "getHostPlayer" in tool_sv, (
        "FocusTool's server half does not check the sender")

    # NOTHING may soften any of those gates. A settings read in the path is how
    # "host only" quietly becomes "host only unless somebody typed /set".
    for where, src in (("Game.sv_e_swFocus", bridge),
                       ("FocusTool.sv_n_swFocus", tool_sv)):
        assert "Settings.Get" not in src and "hostfocus" not in src, (
            f"{where} consults a setting before refusing a guest. Focusing is "
            "host only with no switch -- see HOST_ONLY in Settings.lua")

    # the guest half of the tool refuses before it sends anything
    equipped = tool[tool.index("function FocusTool.client_onEquippedUpdate"):]
    equipped = equipped[:equipped.index(chr(10) + "end")]
    assert "looksLikeHost" in equipped, (
        "a guest holding the tool for the couple of ticks before the guard "
        "takes it gets no hint that it is not theirs")

    opener = game[game.index("function Game.sv_openFocusGui"):]
    opener = opener[:opener.index(chr(10) + "end")]
    assert "getHostPlayer" in opener, (
        "sv_openFocusGui does not check the sender, so a modified client could "
        "read the whole roster off the server")

    # and the tool is in the guard tables, so it is pulled out of a guest's
    # hands rather than merely refusing to work
    lua = fresh("Palette.lua", "Settings.lua")
    S = lua.globals().Settings
    S.Sv_Load(False)
    keys = {str(row["key"]) for row in S.SCHEMA.values()}
    for key in ("focus", "focusname"):
        assert key in keys, f"there is no {key!r} setting, so it cannot be switched"
    assert "hostfocus" not in keys, (
        "a `hostfocus` setting is back in the schema. Focusing is host only with "
        "no switch: a setting that opened the TOOL would give a guest a marker "
        "they could not place from the panel or /focus, which are gated outright")

    # and the gate survives a host switching everything off. HOST_ONLY maps
    # focus to `true` rather than to a settings key, so there is no value of
    # anything that takes the tool out of the guard.
    for row in S.SCHEMA.values():
        if str(row["kind"]) == "bool":
            S.Sv_Set(str(row["key"]), "off")
    # The gate names a uuid; the toolset declares one. If they ever drift, the
    # guard would be pulling a tool nobody has out of nobody's hands while the
    # real one stayed in a guest's.
    import re as _re
    toolset = io.open(ROOT / "mod" / "Tools" / "Database" / "ToolSets"
                      / "serverworks.toolset", encoding="utf-8").read()
    declared = _re.search(r'"uuid":\s*"([0-9a-f-]+)"[^}]*?"class":\s*"FocusTool"',
                          toolset, _re.S)
    assert declared, "the toolset does not declare a FocusTool entry at all"

    host_only = {str(k): str(v) for k, v in S.Sv_HostOnlyTools().items()}
    assert host_only.get(declared.group(1)) == "focus", (
        f"the focus tool's uuid {declared.group(1)} is not in the host-only "
        f"guard (it holds {sorted(host_only.values())}), so a guest keeps it in "
        "their hands instead of having it pulled out")


def the_roster_hud_grows_for_the_focus_line():
    """The corner panel gets a third row, and it is still on screen.

    A root widget's x,y is its CENTRE, so a panel that grows without telling the
    position arithmetic is placed as if it were still short and the new strip
    hangs below where it belongs. Same trap that put the event clock off the
    edge of the screen for four versions.
    """
    lua = fresh("Event.lua", "EventHud.lua", "RosterHud.lua")
    R = lua.globals().RosterHud

    short = R.Build(lua.table_from({"online": 3, "residents": 9}), 1720, 720)
    tall = R.Build(lua.table_from({"online": 3, "residents": 9, "focus": "zeb"}),
                   1720, 720)
    assert tall["height"] > short["height"], (
        "the roster HUD does not grow when somebody is focused, so the FOCUS "
        "strip is drawn outside the panel background")

    captions = {str(k["Name"]): k["Caption"] for k in tall["Childs"].values()
                if k["Caption"] is not None}
    assert captions.get("FocusValue") == "zeb", (
        f"the focus line reads {captions.get('FocusValue')!r}")
    assert "FocusValue" not in {str(k["Name"]) for k in short["Childs"].values()}, (
        "the focus line is drawn even when nobody is focused")

    # a long name is truncated rather than allowed to run off a 168-wide panel
    long_name = "a" * 40
    grown = R.Build(lua.table_from({"online": 1, "residents": 1, "focus": long_name}),
                    1720, 720)
    shown = None
    for k in grown["Childs"].values():
        if str(k["Name"]) == "FocusValue":
            shown = str(k["Caption"])
    assert shown is not None and len(shown) <= 22, (
        f"a 40 character name is drawn as {len(shown) if shown else 0} characters")
    assert "…" not in shown, (
        "the truncation uses a Unicode ellipsis -- the game builds a limited "
        "glyph atlas per font from the strings it renders itself, and a "
        "codepoint it has never drawn comes out as a hollow box")

    # and it is still inside the canvas at every resolution the game ships a
    # skin for, at the taller height
    for w, h in ((1280, 720), (1920, 1080), (2560, 1440), (3840, 2160), (1720, 720)):
        tallH = R.Height(lua.table_from({"focus": "zeb"}))
        x, y = R.TopLeft(w, h, tallH)
        assert x - R.W / 2 >= -w / 2 - 0.5 and y - tallH / 2 >= -h / 2 - 0.5, \
            f"{w}x{h}: the grown roster hangs off the top left"
        assert x + R.W / 2 <= w / 2 + 0.5 and y + tallH / 2 <= h / 2 + 0.5, \
            f"{w}x{h}: the grown roster runs off the canvas"


# -------------------------------------------------------------- checklist ---
#
# The in-game dev checklist. ASKED FOR: "you make an ingame check list. for
# devs. so I can test stuff ... because if I have to switch every time here. I
# waste my time if the feature is still broken on writing it again."
#
# What these checks can cover is the catalogue and the arithmetic -- that every
# item is complete, that a result survives a reload, that walking the list
# reaches every item exactly once, that the panel fits. What they cannot cover
# is the only thing that matters about it: whether pressing PASS in the game
# writes a file. That is the same honest limit as everywhere else here.
#
# One of these is worth more than the rest. every_log_line_the_checklist_cites
# EXCLUDES Checklist.lua from the source it searches, and the first version did
# not -- so it passed while four of the cited lines existed nowhere but in the
# catalogue quoting itself. A check that reads its own answer back is not a
# check, and this project has now written that mistake twice.


def checklist_lua():
    return fresh("Checklist.lua")


def checklist_gui_lua():
    return fresh("Checklist.lua", "ChecklistGui.lua")


def mod_source_without(*skip):
    """Every mod script concatenated, minus the ones named."""
    out = []
    for f in sorted(SCRIPTS.glob("*.lua")):
        if f.name in skip:
            continue
        out.append(io.open(f, encoding="utf-8").read())
    return "\n".join(out)


def the_checklist_says_which_build_it_is():
    """A result records the build it was given against, so the number has to be
    the real one. A stale Checklist.BUILD silently mislabels every result
    recorded after it, and nothing in the game would ever say so."""
    lua = checklist_lua()
    build = int(lua.globals().Checklist.BUILD)
    stamped = int(io.open(ROOT / "VERSION", encoding="utf-8").read().strip())
    assert build == stamped, (
        f"Checklist.BUILD is {build} and VERSION says {stamped}. Every result "
        "recorded from now on would be stamped with the wrong build.")


def every_checklist_item_is_complete_and_unique():
    """An item with no pass condition is a to-do, not a test.

    And an id is the key a result is stored under, so a duplicate silently makes
    two items share one answer -- pressing PASS on one would mark the other.
    """
    lua = checklist_lua()
    C = lua.globals().Checklist
    groups = {g["id"] for g in C.GROUPS.values()}
    seen, problems = set(), []
    for item in C.ITEMS.values():
        i = item["id"]
        if not i:
            problems.append("an item has no id")
            continue
        if i in seen:
            problems.append(f"{i}: duplicate id -- two items would share one result")
        seen.add(i)
        if item["group"] not in groups:
            problems.append(f"{i}: group {item['group']!r} is not in Checklist.GROUPS, "
                            "so the item is unreachable from the panel")
        if not item["title"]:
            problems.append(f"{i}: no title")
        if not item["pass"]:
            problems.append(f"{i}: no pass condition -- that is a to-do, not a test")
        steps = item["steps"]
        if steps is None or len(list(steps.values())) == 0:
            problems.append(f"{i}: no steps")
    assert not problems, "; ".join(problems[:6])
    assert len(seen) >= 40, (
        f"only {len(seen)} items -- STATUS.md section C is longer than that, so "
        "something has been dropped")

    # Every group must actually hold something, or the nav column offers a
    # button that opens an empty list.
    for g in C.GROUPS.values():
        n = len(list(C.ItemsIn(g["id"]).values()))
        assert n > 0, f"group {g['id']!r} has no items but has a nav button"


def every_command_the_checklist_can_run_exists():
    """The RUN button fires the item's own command through the ordinary admin
    path. A command that is not bound would do nothing at all, and the panel
    would say it had sent it -- which is precisely the failure mode the
    'a panel that closes on every click' note is about: a button that lies."""
    lua = checklist_lua()
    game = read("Game.lua")
    bound = set(re.findall(r'bindChatCommand\(\s*"(/\w+)"', game))
    assert bound, "no chat commands found -- the scan is broken, not the code"
    dead = []
    for item in lua.globals().Checklist.ITEMS.values():
        run = item["run"]
        if run is None:
            continue
        first = list(run.values())[0]
        if first not in bound:
            dead.append(f"{item['id']} runs {first}")
    assert not dead, (
        "the checklist offers to run a command that is not bound: " + ", ".join(dead))


def every_log_line_the_checklist_cites_is_one_the_mod_writes():
    """Each item may name the log line that settles it. If the mod does not
    write that line, the instruction sends somebody looking for something that
    was never there.

    Checklist.lua is EXCLUDED from the search on purpose. The first version of
    this check included it and passed -- four of the cited lines existed nowhere
    but in the catalogue quoting itself.
    """
    lua = checklist_lua()
    src = mod_source_without("Checklist.lua")
    missing = []
    for item in lua.globals().Checklist.ITEMS.values():
        line = item["log"]
        if line is None:
            continue
        line = str(line)
        # An item answered from the log may cite an ENGINE line -- a Lua
        # traceback, a NetworkServer budget warning. Those are not ours to
        # write and cannot be found in our source; they are checked only for
        # being there at all.
        if not line.startswith("[ServerWorks]"):
            assert item["who"] == "log", (
                f"{item['id']} cites {line!r}, which is not one of our lines, "
                "but is not a who = \"log\" item")
            assert len(line) > 8, f"{item['id']} cites an empty log line"
            continue
        if line not in src:
            missing.append(f"{item['id']} cites {line!r}")
    assert not missing, (
        "the checklist points at a log line the mod never writes: "
        + "; ".join(missing))


def everything_the_checklist_tells_you_to_type_still_exists():
    """The list must describe the mod as it is TODAY, not as it was.

    REPORTED: "some things are just olden. like not up to date like use clear
    city but we removed that. find all the outaded things and remove them. I
    want to have the list that is possible now."

    Three were stale on the first pass, and all three were the same shape -- an
    instruction inherited from a document rather than read out of the code:

      * `/set maxparts 105`, a setting that has NEVER existed. Rules.lua
        enforces maxjoints, maxbots and maxlights and nothing else, so there is
        no per-plot block limit to test -- and docs/NEXT.md was recommending the
        number to set it to.
      * `/purge walkways`, removed on the owner's instruction along with the
        SWEEP LITTER button that ran it. CHANGELOG: "Gone: the SWEEP LITTER
        button and the /purge walkways branch behind it."
      * `/citystyle brutalist`, which exists but which the owner had already
        said they disliked.

    A checklist that sends somebody to type a command that does not exist wastes
    the thing it was built to save. So every command, every subcommand, every
    setting name and every button caption it mentions is checked against the
    code that would run it.

    The valid values are READ OUT OF THE MOD, never listed here -- a hardcoded
    list would go stale in exactly the way this check exists to prevent, and it
    would go stale silently.
    """
    lua = fresh("Checklist.lua", "Settings.lua", "Palette.lua")
    C = lua.globals().Checklist
    game, world = read("Game.lua"), read("World.lua")

    def branch(src, marker, span=6000):
        """The literals a handler compares against, from its own source."""
        i = src.find(marker)
        assert i >= 0, f"cannot find {marker!r} -- the scan is broken, not the code"
        body = src[i:i + span]
        return set(re.findall(r'==\s*"([\w/]+)"', body))

    bound = set(re.findall(r'bindChatCommand\(\s*"(/\w+)"', game))
    assert bound, "no chat commands found -- the scan is broken"

    keys = {str(row["key"]) for row in lua.globals().Settings.SCHEMA.values()}
    assert len(keys) > 20, "the settings schema came back too small"

    styles = {str(v) for v in lua.globals().Palette.STYLE_ORDER.values()}
    assert styles, "no city styles found"

    subs = {
        "/set": keys,
        "/citystyle": styles,
        "/purge": branch(world, 'cmd == "/purge"'),
        "/plot": branch(world, "function World.sv_plotCommand"),
        "/event": branch(game, "function Game.sv_eventCommand"),
        "/crowd": branch(world, "function World.sv_crowdCommand"),
    }
    for cmd, valid in subs.items():
        assert valid, f"no valid arguments found for {cmd} -- the scan is broken"

    # Captions the panels really draw, so a button named in an instruction is a
    # button that is on the screen.
    captions = set()
    for f in sorted(SCRIPTS.glob("*Gui*.lua")):
        if f.name.startswith("Checklist"):
            continue
        src = io.open(f, encoding="utf-8").read()
        captions |= set(re.findall(r'"([A-Z][A-Z0-9 ]{2,})"', src))
        captions |= set(re.findall(r'label = "([^"]+)"', src))
    assert "BUILD CITY" in captions, "the caption scan missed a known button"

    # Words that are emphasis in a sentence, not the name of a button.
    PROSE = {"STOP", "AND", "TELL", "ME", "THIS", "IS", "THE", "MOST", "IMPORTANT",
             "ONE", "ON", "WHOLE", "LIST", "NOT", "A", "OR", "IT", "IF", "NO",
             "REMOVE", "TWO", "PEOPLE", "DO", "IN", "AT", "ALL", "HAS", "NEVER",
             "BEEN", "TRIED", "SAVING", "KNOWN", "TO", "WORK", "BUT", "PUTTING",
             "BACK", "ONCE", "OF", "WAY", "SAID", "THAT", "ONLY", "REAL",
             "DEFENCE", "SO", "MATTERS", "MORE", "THAN"}

    def check_typed(where, line):
        """A step that says `type /x y` is an instruction, so both halves of it
        have to be real. Prose that merely mentions a command is checked for the
        command only -- "/crowd puts fake players on the city" is a sentence,
        not an instruction, and `puts` is not an argument."""
        for cmd in sorted(set(re.findall(r"(/\w+)", line))):
            if cmd not in bound:
                problems.append(f"{where}: {cmd} is not a command any more")
        m = re.match(r"\s*type (/\w+)(?:\s+(\S+))?", line)
        if m is None:
            return
        cmd, arg = m.group(1), m.group(2)
        if arg is None or cmd not in subs:
            return
        if re.fullmatch(r"-?\d+", arg):
            return                       # /crowd 5, /plotgrid 20 -- a number
        if arg not in subs[cmd]:
            problems.append(
                f"{where}: `{cmd} {arg}` -- {cmd} does not take {arg!r} any more")

    problems = []
    for item in C.ITEMS.values():
        steps = [str(v) for v in item["steps"].values()] if item["steps"] else []
        # Each string on its own. Joining them let the first word of one step be
        # read as the argument of the command in the step before it, which is
        # how this check first accused /citystyle of not taking "look".
        for line in steps:
            check_typed(item["id"], line)
        for field in ("title", "pass"):
            for cmd in sorted(set(re.findall(r"(/\w+)", str(item[field])))):
                if cmd not in bound:
                    problems.append(f"{item['id']}: {cmd} is not a command any more")

        text = " ".join([str(item["title"]), " ".join(steps), str(item["pass"])])

        for phrase in sorted(set(re.findall(
                r"\b([A-Z][A-Z0-9]+(?: [A-Z][A-Z0-9]+)+)\b", text))):
            if phrase in captions or all(w in PROSE for w in phrase.split()):
                continue
            problems.append(f"{item['id']}: {phrase!r} is not a button on any panel")

        # and the RUN button, which types the command for you
        if item["run"] is not None:
            words = [str(v) for v in item["run"].values()]
            if words[0] not in bound:
                problems.append(f"{item['id']}: RUN would type {words[0]}, "
                                "which is not a command")
            elif (len(words) > 1 and words[0] in subs
                    and not re.fullmatch(r"-?\d+", words[1])
                    and words[1] not in subs[words[0]]):
                problems.append(f"{item['id']}: RUN would type "
                                f"{' '.join(words[:2])}, which is not valid")

    assert not problems, (
        f"{len(problems)} thing(s) in the checklist no longer exist in the mod:\n    "
        + "\n    ".join(problems[:10]))


def no_item_on_the_panel_sends_you_to_a_log():
    """REPORTED: "so that there are only things I can directly test in games
    since I dont want to go in logs to test something. since stuff like that you
    can basicaly do your self."

    Right, and it is not only a preference. Reading a log is done afterwards,
    from outside the game; an item that needs one cannot be answered by somebody
    standing in the world with the panel open, so it stalls the walk.

    Anything whose answer is only in a log is who = "log" and is off the panel.
    Everything else must be answerable from what is on screen or in chat -- and
    the mod gives it: /why prints the zone, the mode and all eight body flags
    straight to chat, which is what the most important item in the list
    (city-zones) now uses instead of a log line.
    """
    lua = checklist_lua()
    offenders = []
    for item in lua.globals().Checklist.ITEMS.values():
        if item["who"] == "log":
            continue
        steps = " ".join(str(v) for v in item["steps"].values()) if item["steps"] else ""
        blob = f'{item["title"]} {steps} {item["pass"]}'.lower()
        if "log" in blob:
            offenders.append(item["id"])
    assert not offenders, (
        "these are on the panel and mention a log: " + ", ".join(offenders)
        + '. Either say what is on SCREEN instead, or mark it who = "log" and'
        " answer it from this side.")


def a_log_item_is_off_the_panel_and_names_what_to_search_for():
    """The other half of the same rule. A who = "log" item must not reach the
    panel -- not in the list, not through NEXT, not in the counts -- and it has
    to name the line to search for, or it is a chore with no instructions."""
    lua = checklist_lua()
    C = lua.globals().Checklist
    logs = [i for i in C.ITEMS.values() if i["who"] == "log"]
    assert logs, 'no who = "log" items -- the field is not being used at all'

    for item in logs:
        assert item["log"], (
            f"{item['id']} is answered from the log and does not say which line")

    ids = {i["id"] for i in logs}
    shown = {i["id"] for i in C.ItemsIn("all").values()}
    assert not (ids & shown), (
        "a log item is on the panel: " + ", ".join(sorted(ids & shown)))
    for group in [g["id"] for g in C.GROUPS.values()]:
        shown = {i["id"] for i in C.ItemsIn(group).values()}
        assert not (ids & shown), (
            f"a log item is on the {group} page: " + ", ".join(sorted(ids & shown)))

    # and the counts, or the progress bar can never reach the end
    counts = C.Counts(lua.eval("{}"), None)
    assert int(counts["total"]) == len(list(C.ItemsIn("all").values())), (
        "the counts include items the panel does not show, so the bar would "
        "stop short of full however much work is done")
    assert len(list(C.AllItems("all").values())) == int(counts["total"]) + len(logs), (
        "AllItems and ItemsIn do not differ by exactly the log items")


def a_checklist_result_survives_a_reload():
    """Press PASS, and it must still be a PASS after the game is restarted.

    Exercised through the stub filesystem, so the save and the load are the real
    functions rather than a mock of them -- what is NOT proven is that sm.json
    can write this particular file, though the installed mod's own Settings.json
    says it can.
    """
    lua = checklist_lua()
    C = lua.globals().Checklist
    results = lua.eval("{}")
    C.Set(results, "boot-world", "pass", None, 56, 1000)
    C.Set(results, "backup-restore", "fail", "importFromString threw", 56, 1001)
    C.Sv_Save(results)

    back = C.Sv_Load()
    assert C.StateOf(back, "boot-world") == "pass"
    assert C.StateOf(back, "backup-restore") == "fail"
    assert back["backup-restore"]["note"] == "importFromString threw", (
        "the note did not survive the round trip -- the note is the only place "
        "the reason for a failure is written down")
    assert back["backup-restore"]["build"] == 56

    counts = C.Counts(back, None)
    assert int(counts["pass"]) == 1 and int(counts["fail"]) == 1, (
        "the counts do not agree with what came back off the disk")


def an_answer_the_panel_cannot_give_is_never_recorded():
    """Only the four states exist. A typo, or a payload from somewhere other
    than our panel, must not put a fifth one in the file where nothing can
    display it and nothing can clear it."""
    lua = checklist_lua()
    C = lua.globals().Checklist
    results = lua.eval("{}")
    C.Set(results, "boot-quiet", "probably", None, 56, None)
    assert C.StateOf(results, "boot-quiet") == "untested", (
        "a made-up state was recorded")
    C.Set(results, "no-such-item", "pass", None, 56, None)
    assert C.StateOf(results, "no-such-item") == "untested", (
        "a result was recorded against an item that does not exist")


def clearing_a_result_takes_it_out_of_the_file():
    """untested is the ABSENCE of a result, not a result.

    If clearing wrote "untested" instead, every count would depend on whether an
    item had ever been visited, and the file would fill up with non-answers.
    """
    lua = checklist_lua()
    C = lua.globals().Checklist
    results = lua.eval("{}")
    C.Set(results, "boot-quiet", "pass", None, 56, None)
    C.Set(results, "boot-quiet", None, None, 56, None)
    assert results["boot-quiet"] is None, "a cleared item is still in the table"
    C.Sv_Save(results)
    assert C.Sv_Load()["boot-quiet"] is None, "a cleared item came back from the file"


def a_note_outlives_the_answer_it_was_written_for():
    """Somebody types what went wrong, then presses FAIL. Losing the note at
    that moment would teach people not to write notes, which is the only part of
    this that a reader other than the person who ran the test can use."""
    lua = checklist_lua()
    C = lua.globals().Checklist
    results = lua.eval("{}")
    C.SetNote(results, "limit-trim", "the bearing would not break")
    assert C.StateOf(results, "limit-trim") == "untested", (
        "writing a note answered the item by itself")
    C.Set(results, "limit-trim", "fail", None, 56, None)
    assert results["limit-trim"]["note"] == "the bearing would not break", (
        "the note was lost when the answer was given")

    # And an empty note on an untested item leaves nothing behind at all.
    C.SetNote(results, "limit-locks", "typo")
    C.SetNote(results, "limit-locks", "")
    assert results["limit-locks"] is None, (
        "clearing the note left an empty record behind")


def the_checklist_walks_every_item_exactly_once():
    """NEXT UNANSWERED is how a session is actually run, so it has to reach
    everything and then stop. A cursor that wrapped without noticing would walk
    somebody round the same list forever."""
    lua = checklist_lua()
    C = lua.globals().Checklist
    results = lua.eval("{}")
    solo = [i["id"] for i in C.ITEMS.values()
            if i["needs"] != "guest" and i["who"] != "log"]

    seen, cursor = [], None
    for _ in range(len(solo) + 5):
        nxt = C.NextUntested(results, cursor, False)
        if nxt is None:
            break
        assert nxt not in seen, f"{nxt} was offered twice"
        seen.append(nxt)
        C.Set(results, nxt, "pass", None, 56, None)
        cursor = nxt
    assert C.NextUntested(results, cursor, False) is None, (
        "everything answerable is answered and it still offers another")
    assert seen == solo, (
        f"walked {len(seen)} items, there are {len(solo)} that one person can "
        "answer -- the walk is not in catalogue order or it skipped something")


def the_checklist_never_walks_a_solo_host_into_a_guest_item():
    """Eleven items cannot be answered without a second person. Offering one to
    somebody testing alone is how a session stalls on a question nobody can
    answer -- so they are skipped by default, and reachable on purpose."""
    lua = checklist_lua()
    C = lua.globals().Checklist
    results = lua.eval("{}")
    guests = {i["id"] for i in C.ITEMS.values() if i["needs"] == "guest"}
    assert guests, "no guest-only items -- the field is not being read"

    cursor = None
    for _ in range(200):
        nxt = C.NextUntested(results, cursor, False)
        if nxt is None:
            break
        assert nxt not in guests, f"{nxt} needs a guest and was offered anyway"
        C.Set(results, nxt, "pass", None, 56, None)
        cursor = nxt

    # ...and with includeGuest they are reachable, or they could never be answered
    nxt = C.NextUntested(results, None, True)
    assert nxt in guests, (
        "with a guest present there is no way to reach the guest-only items")


def the_summary_names_every_failure():
    """A count of failures is not actionable; a list of them is. This is the
    text that gets pasted into a conversation or read out of the log."""
    lua = checklist_lua()
    C = lua.globals().Checklist
    results = lua.eval("{}")
    C.Set(results, "backup-restore", "fail", "threw on the second call", 56, None)
    C.Set(results, "limit-trim", "fail", None, 56, None)
    C.Set(results, "boot-quiet", "pass", None, 56, None)
    lines = "\n".join(str(v) for v in C.Summary(results).values())
    assert "backup-restore" in lines and "limit-trim" in lines, (
        "the summary does not name the failing items")
    assert "threw on the second call" in lines, "the summary drops the note"
    assert "boot-quiet" not in lines, "the summary lists passes by name as well"


def a_new_world_never_clears_the_checklist():
    """Every other state file here describes a WORLD, and a new world must not
    inherit one: sv_newWorldReset exists for exactly that.

    The checklist is the opposite case. It records what the CODE did, and making
    a fresh world is the usual way to test something -- so wiping it on world
    create would throw away the session that was being recorded, every time.
    """
    game = read("Game.lua")
    body = game[game.index("function Game.sv_newWorldReset"):]
    body = body[:body.index(chr(10) + "end")]
    assert "Checklist" not in body, (
        "sv_newWorldReset touches the checklist. A new world is the usual way "
        "to test something; clearing the results there would delete the session "
        "that is being recorded.")


def wrapping_never_loses_a_word():
    """The panel wraps long text into one widget per line, because a TextBox
    does not wrap in any way this can rely on. Dropping a word would silently
    change what a pass condition says."""
    lua = checklist_gui_lua()
    G = lua.globals().ChecklistGui
    C = lua.globals().Checklist
    for item in C.ITEMS.values():
        text = str(item["pass"])
        lines = [str(v) for v in G.Wrap(text, 120, None).values()]
        assert " ".join(lines).split() == text.split(), (
            f"{item['id']}: wrapping changed the words of the pass condition")
        for line in lines:
            assert len(line) <= 120, f"{item['id']}: a wrapped line is {len(line)} long"

    # A word longer than the whole line must be broken rather than loop forever.
    long_word = "x" * 300
    lines = [str(v) for v in G.Wrap(long_word, 40, None).values()]
    assert "".join(lines) == long_word and len(lines) >= 7

    # And the cap ends with three ASCII dots -- a Unicode ellipsis is one
    # codepoint the game has probably never drawn, so it comes out hollow.
    capped = [str(v) for v in G.Wrap(" ".join(["word"] * 200), 40, 3).values()]
    assert len(capped) == 3 and capped[-1].endswith("...")
    assert all(ord(c) < 128 for c in "".join(capped)), "a non-ASCII character got in"


def the_checklist_panel_fits_for_every_item():
    """Every list page and EVERY item's detail view, at the panel's own size.

    Per item rather than per sample, because the detail view lays itself out
    from the item's own steps and pass text -- so a long one added later is
    exactly what would push the buttons off the bottom, and nothing else here
    would notice.
    """
    lua = checklist_gui_lua()
    G = lua.globals().ChecklistGui
    C = lua.globals().Checklist
    W, H = int(G.W), int(G.H)

    assert H <= 690, (
        f"the checklist panel is {H} tall. The canvas is about 720 and vanilla's "
        "own panels stop at 690; taller than that and the footer is off screen")

    results = lua.eval("{}")
    C.Set(results, "boot-quiet", "pass", None, 55, None)      # an older build
    C.Set(results, "boot-world", "fail", "a note that is quite long indeed, as "
          "the ones that matter usually are", 56, None)

    groups = ["all"] + [g["id"] for g in C.GROUPS.values()]
    for g in groups:
        for page in (1, 2, 99):
            state = lua.table_from({"group": g, "page": page, "results": results,
                                    "build": 56, "status": "something happened"})
            root = G.Build(state)
            label = f"checklist/{g}/p{page}"
            items = panel_fits(label, root, W, H)
            no_button_is_buried(label, items, H)

    for item in C.ITEMS.values():
        state = lua.table_from({"item": item["id"], "results": results,
                                "build": 56, "status": "x"})
        root = G.Build(state)
        label = f"checklist/item/{item['id']}"
        items = panel_fits(label, root, W, H)
        no_button_is_buried(label, items, H)


def the_checklist_draws_no_character_the_other_panels_have_not():
    """The game builds a limited glyph set per font out of the strings it draws
    itself, and a character outside it comes out as a hollow box. MEASURED:
    SM_LabelMini drew HOST as (X)OST.

    The fonts this panel uses have no declared limit, and CLAUDE.md records a
    measurement that such a font drew mixed case and digits correctly. What was
    never measured is PUNCTUATION -- so the checklist, which is eighty-three
    items of prose and by far the most text this mod has ever drawn, stays
    inside the characters the already-shipped panels draw.

    That set is computed from those panels rather than written down, so it grows
    on its own the day one of them draws something new.
    """
    lua = gui_lua()
    proven = set()

    def note(root):
        for w in walk_full(root):
            for ch in str(w["caption"] or ""):
                if not ch.isalnum():
                    proven.add(ch)

    for host in (True, False):
        for dev in (True, False):
            note(lua.globals().MenuGui.Build(host, dev))
    cfg = {"plot": 20, "gap": 1, "cols": 10, "rows": 10, "roadevery": 0,
           "roadwidth": 6, "plazacells": 2, "claimed": {}}
    note(lua.globals().PlotsGui.Build(lua.table_from(
        {k: (lua.table_from(v) if isinstance(v, dict) else v) for k, v in cfg.items()})))
    for phase in ("off", "prep", "build", "buffer", "ended"):
        note(lua.globals().EventGui.Build(lua.table_from(
            {"phase": phase, "remaining": 754.0, "prep": 10, "build": 60, "buffer": 5})))
    note(lua.globals().FocusGui.Build(lua.table_from(
        {"players": lua.table_from([lua.table_from({"id": 1, "name": "zeb"})])})))
    assert len(proven) > 5, "the proven set came out empty -- the scan is broken"

    G, C = lua.globals().ChecklistGui, lua.globals().Checklist
    results = lua.eval("{}")
    used = {}
    states = [{"group": g["id"], "page": p, "results": results, "build": 57}
              for g in C.GROUPS.values() for p in (1, 2)]
    states += [{"item": i["id"], "results": results, "build": 57}
               for i in C.ITEMS.values()]
    for st in states:
        for w in walk_full(G.Build(lua.table_from(st))):
            for ch in str(w["caption"] or ""):
                if not ch.isalnum() and ch not in proven:
                    used.setdefault(ch, str(w["caption"])[:50])
    assert not used, (
        "the checklist draws characters no other panel does, and nothing has "
        "ever confirmed the font has them: "
        + "; ".join(f"{ch!r} in {where!r}" for ch, where in list(used.items())[:5]))


def the_checklist_panel_has_exactly_one_typed_box():
    """One EditBox in a tree, and its handler draws nothing.

    Both rules were paid for by the event clock, which crashed the game twice
    over typed input -- once by rendering inside the text callback, and again
    after that redraw had been deferred by a tick.
    """
    lua = checklist_gui_lua()
    G = lua.globals().ChecklistGui
    results = lua.eval("{}")

    listing = G.Build(lua.table_from({"group": "all", "results": results}))
    assert not [n for n in walk_raw(listing) if n["Type"] == "EditBox"], (
        "the list view has an EditBox -- only the detail view may have one")

    detail = G.Build(lua.table_from({"item": "boot-quiet", "results": results}))
    boxes = [n for n in walk_raw(detail) if n["Type"] == "EditBox"]
    assert len(boxes) == 1, (
        f"the item view has {len(boxes)} EditBoxes -- moving focus between two "
        "of them is what crashed the game twice")
    box = boxes[0]
    assert str(box["Name"]) == str(G.NOTE_BOX), (
        "the note box's name does not match ChecklistGui.NOTE_BOX, so the "
        "handler cannot tell which box was typed into")
    assert box["Static"] is False, "the note box is Static -- it would never take text"
    assert box["NeedKey"] is True, "the note box cannot take the keyboard"
    assert box["onTextEnter"] is not None, "the note box has no onTextEnter"

    game = read("Game.lua")
    handler = game[game.index("function Game.cl_onChecklistNoteTyped"):]
    handler = handler[:handler.index(chr(10) + "end")]
    for banned in ("cl_showPanel", "cl_renderLater", "cl_closeLater", ":render("):
        assert banned not in handler, (
            f"cl_onChecklistNoteTyped calls {banned} -- a text callback that "
            "touches the GUI crashed the game twice, and deferring was not enough")


def answering_from_the_panel_writes_the_file_at_once():
    """A test session ends when the game crashes or somebody stops playing, and
    neither runs a shutdown hook. So the press has to write, not a later save.

    Source-level, because the write itself is sm.json's and cannot be reached
    from here -- but a recorder that only kept results in memory would lose
    exactly the session that was recording the crash.
    """
    game = read("Game.lua")
    body = game[game.index("function Game.sv_recordChecklist"):]
    body = body[:body.index(chr(10) + "end")]
    assert "Checklist.Sv_Save" in body, (
        "sv_recordChecklist does not save. A result held in memory is lost by "
        "the crash it was recording.")
    assert "sm.log.info" in body, (
        "a result is not written to the log. The log is where every other piece "
        "of evidence about a session already is -- a FAIL and the traceback "
        "that caused it should end up a few lines apart")

    handler = game[game.index("function Game.sv_n_checklistAction"):]
    handler = handler[:handler.index(chr(10) + "end")]
    assert "sm.player.getHostPlayer()" in handler, (
        "the checklist action handler does not check the sender")


# ----------------------------------------------------------------- bridge ---
#
# The outside-the-game control channel. ASKED FOR: "we can make you dirrectly
# connect to the game?" -- because the slow part of this project is the round
# trip, not the work.
#
# What these can cover: the sequence arithmetic, the parsing, the capture
# buffer, and the four structural rules that make it safe. What they cannot
# cover is the one thing that decides whether it works at all -- whether the
# engine hands back a file written from outside, or a cached copy. That is why
# the design never reads a path twice: a stale read cannot happen to a path that
# has never been read.


def bridge_lua():
    return fresh("Settings.lua", "Bridge.lua")


def the_bridge_is_shut_unless_somebody_opens_it():
    """It is a remote control for a game server, so the default has to be off,
    and off has to mean it does nothing at all -- not "nothing useful". While it
    is off there is no poll, no read and no write.

    allow_add_mods is false in this mod because the mod list is the trust
    boundary. This is the same argument pointed at a file.
    """
    lua = bridge_lua()
    lua.globals().Settings.Sv_Load(False)
    assert lua.globals().Settings.Get("bridge") is False, (
        "the bridge is ON by default -- a world would be drivable from outside "
        "the moment it loaded")

    game = read("Game.lua")
    body = game[game.index("function Game.sv_bridgeTick"):]
    body = body[:body.index(chr(10) + "end")]
    assert "Settings.BridgeOpen()" in body, (
        "sv_bridgeTick does not consult the setting, so switching it off would "
        "not switch it off")
    assert body.index("Settings.BridgeOpen()") < body.index("Bridge.sv_poll"), (
        "the bridge polls before it checks whether it is switched on")

    # BOTH switches, and neither may be written by the other. /developer off has
    # to shut this door -- it is the loudest thing behind that switch -- and it
    # has to shut it by DERIVING, so that /developer on gives the host back the
    # channel they actually chose. Writing `bridge = false` instead is exactly
    # the mistake V52's lockdown made with four tool settings and could not undo.
    S = lua.globals().Settings
    for bridge in (True, False):
        for dev in (True, False):
            S.Sv_SetQuiet("bridge", bridge)
            S.Sv_SetQuiet("developer", dev)
            assert bool(S.BridgeOpen()) is (bridge and dev), (
                f"bridge={bridge} developer={dev} -- BridgeOpen said "
                f"{S.BridgeOpen()}")
            assert bool(S.Get("bridge")) is bridge, (
                "asking whether the door is open changed the host's own switch")
    assert "sm.player.getHostPlayer()" in body, (
        "the bridge does not resolve a host, so it would run commands as nobody "
        "-- every host gate in the mod depends on that player being the host")


def the_bridge_never_reads_the_same_path_twice():
    """THE WHOLE DESIGN, and the reason this did not need an experiment first.

    The engine keeps compiled copies of the data files it reads (MEASURED: every
    .rco in the mod's Cache/ was stamped hours before the .lua it came from). If
    sm.json.open serves a cached copy then a channel built on rewriting one file
    would answer the first command forever and nothing would say why.

    So the sequence number is in the FILENAME. This walks several batches
    through the real poll and asserts every path is one nothing has read.
    """
    lua = bridge_lua()
    B = lua.globals().Bridge
    b = B.sv_new()

    seen = []
    for _ in range(5):
        path = str(B.CmdPath(b.seq))
        assert path not in seen, f"the bridge would read {path} a second time"
        seen.append(path)
        lua.execute(f'sm.json.save( {{ commands = {{ "/protection" }} }}, "{path}" )')
        assert B.sv_poll(b) is not None, f"the poll did not see {path}"
        B.sv_writeResult(b, b.seq, lua.eval("{}"), None, lua.eval("{}"))
        b.seq = b.seq + 1

    assert len(set(seen)) == 5
    assert "Cmd-1.json" in seen[0] and "Cmd-5.json" in seen[4], (
        f"the sequence did not advance one at a time: {seen}")


def a_file_the_bridge_cannot_use_does_not_wedge_it():
    """A half-written or hand-edited file must not be polled forever.

    Leaving the number where it is would re-read the same bad file twice a
    second for the rest of the session, and from outside that looks exactly like
    a bridge that is on, listening, and ignoring you. Found by writing this.
    """
    lua = bridge_lua()
    B = lua.globals().Bridge
    b = B.sv_new()
    start = int(b.seq)

    lua.execute(f'_files["{B.CmdPath(b.seq)}"] = "this is not a command file"')
    assert B.sv_poll(b) is None
    assert int(b.seq) == start + 1, (
        "the bridge stayed on a file it cannot use -- it would poll it forever")

    lua.execute(f'sm.json.save( {{ commands = {{ "/protection" }} }}, "{B.CmdPath(b.seq)}" )')
    assert B.sv_poll(b) is not None, "the bridge did not recover from a bad file"


def the_bridge_only_runs_things_that_look_like_commands():
    """It runs chat commands as the host and nothing else. A line that is not a
    command is dropped here rather than handed to a dispatch that would answer
    "Host only." and leave somebody reading a confusing transcript."""
    lua = bridge_lua()
    B = lua.globals().Bridge

    parsed = B.Parse(lua.table_from({"commands": lua.table_from([
        "/set plots on",
        lua.table_from(["/plot", "claim"]),
        "rm -rf /",
        "",
    ])}))
    got = [[str(w) for w in words.values()] for words in parsed.values()]
    assert got == [["/set", "plots", "on"], ["/plot", "claim"]], got

    many = B.Parse(lua.table_from({"commands": lua.table_from(
        ["/protection"] * (int(B.MAX_COMMANDS) + 25))}))
    assert len(list(many.values())) == int(B.MAX_COMMANDS)

    assert len(list(B.Parse(lua.eval("{}")).values())) == 0
    assert len(list(B.Parse(lua.eval('"nonsense"')).values())) == 0


def the_bridge_keeps_listening_after_the_command_returns():
    """A WORLD command does not answer while it runs. Game hands it to the world
    as an event, the world deals with it on its own tick, and the reply comes
    back later -- so a capture that closed when the call returned would catch
    every reply from Game.lua and almost none from World.lua, which is /plot,
    /why, /budget, /protection, /purge, /snapshot and the whole city.

    The buffer closes on a clock instead, and anything arriving while it is open
    belongs to the batch.
    """
    lua = bridge_lua()
    B = lua.globals().Bridge
    b = B.sv_new()

    assert B.sv_capture(b, "before") is False, (
        "the bridge captured a line while no batch was listening")

    b.capture = lua.eval("{}")
    B.sv_capture(b, "from Game, immediately")
    B.sv_capture(b, "from the World, two ticks later")
    assert [str(v) for v in b.capture.values()] == [
        "from Game, immediately", "from the World, two ticks later"]

    for i in range(int(B.MAX_LINES) + 50):
        B.sv_capture(b, f"line {i}")
    assert len(list(b.capture.values())) == int(B.MAX_LINES), (
        "a command that replies per body could write a file the size of the city")

    assert float(B.Wait(lua.eval("{}"))) == float(B.WAIT_DEFAULT)
    assert float(B.Wait(lua.table_from({"wait": -5}))) == 0
    assert float(B.Wait(lua.table_from({"wait": 99999}))) == float(B.WAIT_MAX)
    assert float(B.Wait(lua.table_from({"wait": 12}))) == 12


def every_reply_funnel_tells_the_bridge():
    """Everything the mod says goes to a chat box, and nothing outside the game
    can read a chat box. So each funnel hands its text to the bridge as well --
    asserted for all of them, because forgetting one gives a transcript that is
    quietly missing the answer somebody needed.
    """
    game = read("Game.lua")
    for name in ("sv_e_swReply", "sv_e_swBroadcast", "sv_broadcast",
                 "sv_n_adminCommand"):
        body = game[game.index(f"function Game.{name}("):]
        body = body[:body.index(chr(10) + "end")]
        assert "sv_bridgeSay" in body, (
            f"Game.{name} says something the bridge cannot hear, so a command "
            "run from outside would come back with an empty transcript")

    body = game[game.index("function Game.sv_bridgeSay"):]
    body = body[:body.index(chr(10) + "end")]
    assert "if b == nil then return end" in body, (
        "sv_bridgeSay does not tolerate there being no bridge, and it is called "
        "from every reply in the mod")


def the_bridge_runs_inside_its_own_pcall():
    """A control channel must never take the server down with it, and a fault
    anywhere else on the tick must never leave a batch half-run. Same separation
    /crowd and /bench already have, for the same reason: a test harness that can
    switch protection off is worse than no harness."""
    game = read("Game.lua")
    tick = game[game.index("function Game.server_onFixedUpdate"):]
    tick = tick[:tick.index(chr(10) + "end")]
    assert "sv_bridgeTick" in tick, "nothing drives the bridge"
    line = next(l for l in tick.splitlines() if "sv_bridgeTick" in l)
    assert "pcall" in line, f"the bridge is driven without a pcall: {line.strip()!r}"


# ------------------------------------------------------- developer mode ---
#
# ASKED FOR: "add a /developer on feature that adds the developer buttons to the
# menu. it is off by default", alongside "make sure there arent unecesary
# buttons in menu. buttons are good. but too many buttons is too much."
#
# The four things behind the switch are the four an event does not survive: a
# hundred and twenty-eight bots, a benchmark that walks that number up on its
# own for several minutes, a channel that runs host commands from outside the
# game, and a checklist whose items run whatever command they name.
#
# So the switch has to be more than tidying, and these checks are what says so:
# the entries are gone by default, the doors behind them are shut as well, and
# -- the part that is easy to get wrong -- every dev tool can still be TURNED
# OFF while the mode is off, or switching the mode off with a crowd standing
# would strand it.


def the_dev_tools_are_off_the_menu_until_somebody_asks_for_them():
    lua = gui_lua()
    M = lua.globals().MenuGui
    dev = {str(e["label"]) for e in M.ENTRIES.values() if e["dev"]}
    assert dev == {"DEV TOOLS", "TESTING CHECKLIST"}, (
        f"the menu marks {sorted(dev)} as developer entries -- expected the "
        "crowd/benchmark/bridge panel and the checklist")

    def labels(host, developer):
        left, right = M.Columns(host, developer)
        return ([str(e["label"]) for e in left.values()],
                [str(e["label"]) for e in right.values()])

    for developer in (False, None):
        _, right = labels(True, developer)
        assert not (set(right) & dev), (
            f"developer={developer!r} and the host is still offered "
            f"{sorted(set(right) & dev)}")
    _, right_on = labels(True, True)
    assert dev <= set(right_on), "/developer on does not put the dev entries back"

    # A guest never sees them either way -- they are host entries as well.
    for developer in (True, False):
        left, _ = labels(False, developer)
        assert not (set(left) & dev), "a guest is offered a developer entry"

    # AND THE COUNT IS THE POINT. "too many buttons is too much": the default
    # host menu is what somebody actually running an event looks at.
    left, right = labels(True, False)
    assert len(left) + len(right) <= 10, (
        f"the default host menu has {len(left) + len(right)} entries. Every one "
        "of them has to earn its place -- put new ones behind /developer, or on "
        "the panel they belong to")


def hiding_a_button_is_not_the_same_as_shutting_a_door():
    """The menu is drawn on the player's own machine, so hiding an entry hides
    nothing from a modified client. Every route to a dev panel asks the server.
    """
    game = read("Game.lua")
    for func, needles in (
            ("sv_n_menuOpen", ('what == "dev"', 'what == "checklist"')),
            ("sv_n_openPanel", ('data.panel == "dev"',)),
    ):
        body = game[game.index("function Game." + func):]
        body = body[:body.index(chr(10) + "end" + chr(10))]
        for needle in needles:
            line = next((l for l in body.splitlines() if needle in l), None)
            assert line, f"{func} no longer routes {needle}"
            assert "Settings.DeveloperOn()" in line, (
                f"{func} opens {needle} without asking whether developer mode "
                f"is on: {line.strip()!r}. Hiding the button is not enough")

    # And once more at the far end. A client that never opened the menu can send
    # sv_n_devGuiAction or sv_n_checklistAction straight at the server, so the
    # panel openers and the action handlers ask for themselves rather than
    # trusting that a panel was ever drawn.
    for func in ("sv_openDevGui", "sv_n_devGuiAction",
                 "sv_openChecklistGui", "sv_n_checklistAction"):
        body = game[game.index("function Game." + func):]
        body = body[:body.index(chr(10) + "end" + chr(10))]
        assert "Settings.DeveloperOn()" in body, (
            f"{func} never asks whether developer mode is on, so a client that "
            "skips the menu reaches the dev tools on an event server")


def a_dev_tool_can_always_be_switched_off():
    """"A rule must never forbid its own remedy."

    This project has paid for that once already: going over the per-plot part
    budget returned the LOCKED profile, so the one action that could satisfy the
    limit was the action the limit forbade. Turn developer mode off with a
    hundred bots on the city and it is the same shape -- unless every dev
    command keeps its OFF switch reachable, which is what this asserts.
    """
    lua = fresh("Settings.lua")
    S = lua.globals().Settings
    S.Sv_Load(False)
    assert S.Get("developer") is False, (
        "developer mode is ON in a fresh settings file -- an event server would "
        "come up with the crowd, the benchmark and the outside channel reachable")

    def allowed(*words):
        return bool(S.DevCommandAllowed(lua.table_from(list(words))))

    # OFF: the dev commands refuse, and their escapes do not.
    assert not allowed("/crowd", "40"), "/crowd started a crowd with developer off"
    assert not allowed("/bench", "start"), "/bench ran with developer off"
    assert not allowed("/bridge", "on"), "/bridge opened with developer off"
    assert not allowed("/check"), "the checklist opened with developer off"
    for escape in (("/crowd", "off"), ("/crowd", "0"), ("/bench", "stop"),
                   ("/bridge", "off")):
        assert allowed(*escape), (
            f"{' '.join(escape)} is refused while developer mode is off, so a "
            "crowd raised before the switch was flipped could never be cleared")

    # And an ordinary command is untouched in either mode.
    for cmd in ("/lockdown", "/menu", "/plot", "/snapshot"):
        assert allowed(cmd), f"{cmd} was caught by the developer gate"

    S.Sv_SetQuiet("developer", True)
    for words in (("/crowd", "40"), ("/bench", "start"), ("/bridge", "on"),
                  ("/check",)):
        assert allowed(*words), f"{words[0]} still refuses with developer mode ON"

    # The gate has to run BEFORE the world forward, or /crowd and /bench are
    # already gone: they are WORLD_COMMANDS and leave this script on the line
    # above the elseif chain.
    game = read("Game.lua")
    body = game[game.index("function Game.sv_n_adminCommand"):]
    assert body.index("Settings.DevCommandAllowed") < body.index("WORLD_COMMANDS[cmd]"), (
        "the developer gate runs after the world forward, so /crowd and /bench "
        "are handed off before anything checks the mode")


# ------------------------------------------------------------ the ban list ---


def banning_never_requires_typing_a_name():
    """REPORTED: "nicks in scrap mechanic to ban needs to be writen exactly.
    since names can be strange. this wont work."

    Exactly right, and worse than awkward: a Scrap Mechanic display name can
    hold characters that are not on the host's keyboard at all, so for some
    players there is no string a host could enter. The engine's own /kick has
    the same disease.

    So EVERY route to a ban on this panel carries a PERMA ID -- SW-0007, always
    ASCII, and the id the ban is filed under -- and the host picks a row rather
    than describing one. This is the check that stops a text box creeping back.
    """
    lua = gui_lua()
    PG = lua.globals().PeopleGui

    known = [{"perma": "SW-0007", "name": "\u2588\u2588 xX", "aliases": 2,
              "banned": False},
             {"perma": "SW-0002", "name": "A Griefer", "aliases": 0,
              "banned": True}]

    def build(**over):
        st = {"host": True, "view": "known",
              "known": lua.table_from([lua.table_from(r) for r in known]),
              "bans": lua.table_from([]), "players": lua.table_from([])}
        st.update(over)
        return PG.Build(lua.table_from(st))

    acts = [n["onClickData"] for n in walk_raw(build())
            if n["onClick"] is not None and n["onClickData"] is not None
            and str(n["onClickData"]["action"] or "") in ("ban", "unban")]
    assert len(acts) == len(known), (
        f"{len(acts)} ban/unban buttons for {len(known)} known players -- every "
        "row must carry one, or the only way to reach somebody is to type them")

    carried = {str(a["name"]) for a in acts}
    assert carried == {"SW-0007", "SW-0002"}, (
        f"the buttons carry {sorted(carried)}. They must carry perma ids: a "
        "display name is the one thing about a player a host may be unable to "
        "reproduce, and it is not what the ban is stored under")

    # Already banned shows the way back out on the SAME row, so a host never has
    # to work out which tab undoes what they just did.
    by_id = {str(a["name"]): str(a["action"]) for a in acts}
    assert by_id["SW-0002"] == "unban", "a banned player still offers BAN"
    assert by_id["SW-0007"] == "ban", "an unbanned player does not offer BAN"

    # And the roster view still bans the person in front of you.
    here = [n["onClickData"] for n in walk_raw(PG.Build(lua.table_from(
        {"host": True, "view": "here", "known": lua.table_from([]),
         "players": lua.table_from([lua.table_from(
             {"id": 3, "name": "A Guest", "perma": "SW-0009"})])})))
        if n["onClick"] is not None and n["onClickData"] is not None]
    assert any(str(a["action"] or "") == "ban" for a in here), (
        "the roster view lost its BAN button")


def the_people_box_filters_and_never_bans():
    """One EditBox per tree, its handler draws nothing, and -- this panel's own
    rule -- it is a FILTER rather than a target.

    The first two were paid for by the event clock, which crashed the game twice
    over typed input. The third is what makes the panel usable at all: if the
    box were the target, a name the host cannot type would be a player the host
    cannot ban, which is the bug this whole view exists to remove. Typing only
    ever narrows the list; the click is what acts.
    """
    lua = gui_lua()
    PG = lua.globals().PeopleGui

    def boxes(view):
        return [n for n in walk_raw(PG.Build(lua.table_from(
            {"host": True, "view": view, "known": lua.table_from([]),
             "bans": lua.table_from([]), "players": lua.table_from([])})))
            if n["Type"] == "EditBox"]

    assert len(boxes("known")) == 1, "EVERYONE SEEN has no single filter box"
    for view in ("here", "bans"):
        assert not boxes(view), (
            f"the {view} view has an EditBox too -- moving focus between two of "
            "them in one tree is what crashed the game")
    guest = [n for n in walk_raw(PG.Build(lua.table_from(
        {"host": False, "view": "known", "known": lua.table_from([])})))
        if n["Type"] == "EditBox"]
    assert not guest, "a guest is given the filter box"

    box = boxes("known")[0]
    assert str(box["Name"]) == str(PG.SEARCH_BOX), (
        "the box's name does not match PeopleGui.SEARCH_BOX, so the handler "
        "cannot tell which box was typed into")
    assert box["Static"] is False, "the filter box is Static -- it would never take text"
    assert box["NeedKey"] is True, "the filter box cannot take the keyboard"
    assert box["onTextEnter"] is not None, "the filter box has no onTextEnter"

    game = read("Game.lua")
    handler = game[game.index("function Game.cl_onPeopleSearchTyped"):]
    handler = handler[:handler.index(chr(10) + "end")]
    for banned in ("cl_showPanel", "cl_renderLater", "cl_closeLater", ":render("):
        assert banned not in handler, (
            f"cl_onPeopleSearchTyped calls {banned} -- a text callback that "
            "touches the GUI crashed the game twice, and deferring was not enough")
    assert '"search"' in handler and '"ban"' not in handler, (
        "the typed box reaches a ban. It may only ever filter")

    # The filter itself: any fragment of a name OR of the perma. The perma half
    # is the one that matters -- it is always ASCII, so it is the only handle on
    # a player whose display name the host cannot type a character of.
    rows = lua.table_from([lua.table_from(r) for r in (
        {"perma": "SW-0007", "name": "\u2588\u2588 xX"},
        {"perma": "SW-0011", "name": "June Carya"},
        {"perma": "SW-0012", "name": "zeb"})])

    def names(q):
        return sorted(str(r["perma"]) for r in PG.Filter(rows, q).values())

    assert names("") == ["SW-0007", "SW-0011", "SW-0012"], "an empty filter hides people"
    assert names("  ") == ["SW-0007", "SW-0011", "SW-0012"], "whitespace is not trimmed"
    assert names("sw-0007") == ["SW-0007"], "a perma id does not match, case-insensitively"
    assert names("SW-00") == ["SW-0007", "SW-0011", "SW-0012"], "a perma prefix does not match"
    assert names("carya") == ["SW-0011"], "part of a name does not match"
    assert names("CARYA") == ["SW-0011"], "the filter is case sensitive"
    assert names("qqq") == [], "a filter that matches nothing still returns rows"

    # And the geometry follows the box, or the bottom row sits under the footer.
    assert int(PG.RowsFor("known")) < int(PG.RowsFor("here")), (
        "EVERYONE SEEN shows as many rows as the roster, but it spends a row's "
        "height on the filter box")


def a_perma_id_finds_the_player_wearing_it():
    """The panel sends perma ids, so the ban path has to turn one back into a
    live player -- or banning somebody standing in front of you would file them
    correctly and never call sm.game.banPlayer, leaving them in the world.
    """
    game = read("Game.lua")
    body = game[game.index("local function resolveTarget("):]
    body = body[:body.index(chr(10) + "end")]
    assert "Identity.Sv_NameOf" in body, (
        "resolveTarget cannot turn a perma id into a name, so every button on "
        "the people panel misses anybody who is currently online")
    assert body.index("Identity.Sv_NameOf") < body.rindex("getAllPlayers"), (
        "resolveTarget resolves the perma but never looks for that player among "
        "the people who are here")


def the_allow_list_can_actually_be_filled_in():
    """REPORTED with a screenshot: the allow list was ON, one player was online
    (the host), and there was no way to put anybody on the list at all.

    That is the whole feature missing, not a rough edge. The allow list names
    everyone who MAY come in -- so unlike a ban, it has to be filled in BEFORE
    an event, and a control that only reaches people already standing in the
    world can never do that. It is also the strongest tool this mod has: a ban
    loses to a rename, an allow list cannot, because a new name is simply a name
    that is not on it.
    """
    lua = gui_lua()
    PG = lua.globals().PeopleGui
    known = [{"perma": "SW-0007", "name": "Somebody", "allowed": False},
             {"perma": "SW-0008", "name": "A Regular", "allowed": True}]

    def build(allowlist):
        return PG.Build(lua.table_from({
            "host": True, "view": "known", "allowlist": allowlist,
            "known": lua.table_from([lua.table_from(r) for r in known]),
            "bans": lua.table_from([]), "players": lua.table_from([])}))

    def actions(root):
        return [n["onClickData"] for n in walk_raw(root)
                if n["onClick"] is not None and n["onClickData"] is not None]

    on = actions(build(True))
    by = {}
    for a in on:
        act = str(a["action"] or "")
        if act in ("allow", "unallow"):
            by[str(a["name"])] = act
    assert by == {"SW-0007": "allow", "SW-0008": "unallow"}, (
        f"the picker offers {by} -- every row must be able to be added to the "
        "allow list and taken off it again, and by PERMA ID, because a display "
        "name is the thing a host may be unable to type")

    # ...and NOT while the list is switched off, or it is a button that appears
    # to do nothing -- the failure this project has already paid for three times.
    off = [str(a["action"]) for a in actions(build(False))]
    assert "allow" not in off and "unallow" not in off, (
        "the allow/remove buttons are drawn while the allow list is switched "
        "off, so pressing one changes a list nothing consults")

    # The switch itself has to be reachable from the same panel. Managing members
    # without being able to see or flip the switch is half a feature.
    toggles = [a for a in actions(build(False)) if str(a["action"] or "") == "allowlist"]
    assert toggles, "there is no way to turn the allow list on from the panel"
    assert toggles[0]["on"] is True, "the toggle does not offer the opposite state"
    assert [a for a in actions(build(True))
            if str(a["action"] or "") == "allowlist"][0]["on"] is False, (
        "the toggle does not offer to turn a live allow list off again")

    # And it must go through the ordinary Sv_Set, or two ways to write one
    # setting drift apart.
    game = read("Game.lua")
    body = game[game.index("function Game.sv_n_peopleGuiAction"):]
    body = body[:body.index(chr(10) + "end" + chr(10))]
    branch = body[body.index('data.action == "allowlist"'):]
    assert 'Settings.Sv_Set( "allowlist"' in branch, (
        "the panel writes the allowlist setting some other way than Sv_Set, so "
        "it will not broadcast, log, or reach the world the way /set does")


def the_host_is_never_shown_as_locked_out_of_their_own_server():
    """The host row read "HOST   NOT on the allow list" -- the server appearing
    to say it will throw its own owner out.

    It will not: server_onPlayerJoined tests `player ~= host` before it consults
    the list at all. The row was describing a fact that has no consequence, in
    words that suggested a serious one.
    """
    lua = gui_lua()
    PG = lua.globals().PeopleGui
    line = str(PG.Subtitle(lua.table_from(
        {"perma": "SW-0001", "host": True, "allowed": False}), True))
    assert "NOT on the allow list" not in line, (
        f"the host row still reads {line!r}")
    assert "always allowed" in line, (
        f"the host row does not say the host is exempt: {line!r}")

    # ...and the exemption it is describing has to be real.
    game = read("Game.lua")
    join = game[game.index("function Game.server_onPlayerJoined"):]
    join = join[:join.index(chr(10) + "end" + chr(10))]
    gate = next(l for l in join.splitlines() if 'Settings.Get( "allowlist" )' in l)
    assert "player ~= host" in gate, (
        f"the join check no longer exempts the host: {gate.strip()!r} -- the "
        "panel would be telling the truth about a server that locks its owner out")


def the_mod_adds_no_work_to_a_join():
    """A JOIN IS THE ONE MOMENT THIS ENGINE IS KNOWN TO BE FRAGILE.

    MEASURED by somebody else, on a 40-player survival stream: two people
    joining at the same time was enough for the network handshake to fail and
    for NEITHER to get in. The whole event had to move to invite-only with
    invites sent one at a time. That is engine-side and this mod cannot fix it.

    What it can do is not make it worse. server_onPlayerJoined used to broadcast
    the roster to every client on every join -- N x N messages during a burst,
    from a mod, on top of an engine already failing -- and write the whole
    players file to disk each time. Both are now on the once-a-second tick,
    which was already running and already sends nothing when nothing moved.

    This is a check about a cost, so it reads the join path rather than a value:
    what matters is that the expensive calls are NOT there.
    """
    game = read("Game.lua")
    join = game[game.index("function Game.server_onPlayerJoined"):]
    join = join[:join.index(chr(10) + "end" + chr(10))]
    code = chr(10).join(l for l in join.splitlines()
                        if l.strip() and not l.strip().startswith("--"))

    assert "sv_pushRoster( player )" in code, (
        "the joining player is no longer sent the roster, so their HUD is blank "
        "until the next tick")
    assert "sv_pushRoster()" not in code.replace("sv_pushRoster( player )", ""), (
        "server_onPlayerJoined broadcasts the roster to everybody. That is one "
        "message per client per join -- N x N during exactly the burst this "
        "engine cannot survive. The tick already pushes it once a second")
    assert "Sv_SavePlayers" not in code, (
        "the join path writes the whole players file synchronously. It grows "
        "with every player ever seen, and it is written at the worst instant")

    # ...and the deferred work has to actually be picked up, or it is not
    # deferred, it is dropped.
    tick = game[game.index("function Game.server_onFixedUpdate"):]
    tick = tick[:tick.index(chr(10) + "end" + chr(10))]
    assert "sv_pushRoster()" in tick, "nothing pushes the roster any more"
    assert "Sv_FlushPlayers" in tick, (
        "nothing flushes the players file, so a deferred write is a lost write")

    ident = read("Identity.lua")
    assert "function Identity.Sv_FlushPlayers" in ident, "the flush does not exist"
    touch = ident[ident.index("function Identity.Sv_Touch"):]
    touch = touch[:touch.index(chr(10) + "end")]
    assert "playersDirty = true" in touch, "Sv_Touch does not mark the file dirty"
    # A ban is not deferred. It is typed while something is going wrong.
    # The open paren matters: "Identity.Sv_Ban" is a prefix of "Sv_BanEntry",
    # which is defined earlier, so the loose name slices the wrong function and
    # the check fails against perfectly good code.
    ban = ident[ident.index("function Identity.Sv_Ban( "):]
    ban = ban[:ban.index(chr(10) + "end")]
    assert "Sv_SaveBans" in ban, (
        "banning no longer writes immediately -- a ban placed a second before a "
        "crash is exactly the ban that mattered")


def the_host_can_see_who_is_allowed_to_join():
    """"if server is set to public only up to 6 players can join."

    The cap itself is not ours to change -- see CLAUDE.md -- but a host who
    cannot see which mode the world is in cannot tell "nobody else can join"
    from "nobody else is trying", and only one of those is fixable by them.

    `Multiplayer` is a real key in the game's own settings table, measured
    sitting beside PhysicsQuality in the executable, so getSettingValue reads it
    the same way /protection already reads PhysicsQuality.
    """
    lua = fresh("Settings.lua")
    S = lua.globals().Settings
    modes = {int(k): str(v) for k, v in S.JOIN_MODES.items()}
    assert set(modes.values()) == {"Private", "Invite only", "Friends",
                                   "Friends of friends", "Public"}, (
        f"the join modes are {modes} -- the game ships exactly five, named by "
        "MENU_OPTIONS_GAMEPLAY_MULTIPLAYER_* in InterfaceTags.txt")

    # An unreadable setting must say so rather than inventing a mode.
    assert "unreadable" in str(S.JoinModeLine()), (
        "with no game to ask, the readout claims to know who can join")

    # ...and with the setting readable, it has to name the mode AND show the raw
    # number. The label ordering is a GUESS -- nothing in the string table fixes
    # it -- so a line that printed only the label could be confidently wrong
    # forever, with nothing in a session able to correct it.
    for raw, label in sorted(modes.items()):
        lua.execute(
            "sm.game = sm.game or {}; "
            f"sm.game.getSettingValue = function( k ) return {raw} end")
        line = str(S.JoinModeLine())
        assert "who can join" in line, f"the readout says nothing useful: {line!r}"
        assert label in line, f"value {raw} did not report as {label!r}: {line!r}"
        assert f"Multiplayer = {raw}" in line, (
            f"the readout hides the raw setting value: {line!r}. The label order "
            "is unverified, so the number has to be visible or nothing can "
            "correct it")
        # The one mode that has been reported to stall has to say so on the line
        # itself. A host reading "who can join: Public" and nothing else has been
        # told the fact and not the consequence.
        warned = "6" in line or "stall" in line
        assert warned == (label == "Public"), (
            f"{label} line reads {line!r} -- only Public has been reported to "
            "stop letting people in, and only Public should say so")

    for where, src in (("/protection", read("World.lua")),
                       ("the people panel", read("Game.lua"))):
        assert "JoinModeLine()" in src, (
            f"{where} does not report who can join")


def changing_who_can_join_is_never_silent():
    """MEASURED, from this owner's own logs rather than from reasoning --
    game-20260710-192923.log, one host, five players:

        19:52:45  user X   Connecting -> None        turned away
        ...seven attempts over fifty seconds, all refused...
        19:53:35  Multiplayer: Multiplayer(3)        the host widens it
        19:53:36  user X   Finding Route -> Connected

        20:22:39  Multiplayer: Multiplayer(0)        the host narrows it
        20:22:39  User A is not authenticated        ONE TICK LATER
        20:22:39  A, B: Connected -> None            both thrown out

    Two things nobody is told. Somebody who cannot join retries in silence --
    seven times, with no message on either end. And narrowing the setting while
    people are in the world REMOVES them, reported as an authentication failure
    rather than as anything to do with the setting that caused it.

    The mod cannot change the setting -- getSettingValue exists and no setter
    does -- so it says what happened. That is still the difference between "the
    server is broken" and "I pressed something".
    """
    game = read("Game.lua")
    assert "function Game.sv_checkJoinMode" in game, (
        "nothing watches the multiplayer setting, so a host who narrows it "
        "mid-event sees people vanish with no explanation anywhere")

    body = game[game.index("function Game.sv_checkJoinMode"):]
    body = body[:body.index(chr(10) + "end" + chr(10))]
    assert "Settings.JoinMode()" in body, "the watcher does not read the setting"
    assert "sm.log.info" in body, (
        "a change is not logged, and the log is where every other piece of "
        "evidence about a session already is")
    assert "getHostPlayer" in body, (
        "the warning is not aimed at the host -- a guest being told the rules "
        "moved as they are thrown out is noise at the worst moment")
    assert "getAllPlayers" in body, (
        "the warning does not say whether anybody is in the world to lose")

    # ...and it has to be driven, or it is a function nothing calls.
    tick = game[game.index("function Game.server_onFixedUpdate"):]
    tick = tick[:tick.index(chr(10) + "end" + chr(10))]
    assert "sv_checkJoinMode" in tick, "nothing drives the watcher"
    line = next(l for l in tick.splitlines() if "sv_checkJoinMode" in l)
    assert "pcall" in line, (
        f"the watcher runs without a pcall: {line.strip()!r} -- it reads an "
        "engine setting every second and must never take the tick down")

    # The first read must not announce itself as a change, or every world load
    # would warn about a setting nobody touched.
    assert "self.sv.joinMode == nil" in body, (
        "the watcher has no first-read case, so loading a world reports the "
        "setting as having just changed")


def free_build_reaches_every_square_that_is_not_a_plot():
    """"make sure you can place and break blocks on everything when the free
    build on the city is on."

    EVERYTHING. The first version of citybuild named plaza, road and corner and
    left the filler seams between plots to fall through to the teaming rule, so
    the strips between plots stayed shut with the city wide open -- which is the
    one part of "everything" you find by walking into it.

    So this does not check three zone kinds by name. It sweeps the whole grid,
    collects every kind Layout actually produces, and demands all of them open.
    A new zone kind is covered the day it is added rather than the day somebody
    reports it.
    """
    lua = fresh("Layout.lua", "Palette.lua", "Settings.lua", "Plots.lua")
    S, P, L = lua.globals().Settings, lua.globals().Plots, lua.globals().Layout
    S.Sv_Load(False)

    # A grid with ROADS in it. The default has roadevery = 0, so a sweep over it
    # finds only plaza and plot and would pass while proving nothing -- which is
    # exactly how the gap this check exists for got shipped.
    plots = lua.eval("Plots()")
    P.sv_onCreate(plots, lua.table_from({"grid": lua.table_from(
        {"plot": 8, "gap": 1, "cols": 8, "rows": 8, "roadevery": 3,
         "roadwidth": 4, "plazacells": 1}), "enabled": True}))
    plots["enabled"] = True
    block = float(P.BLOCK)

    make = lua.execute("""
        return function( x, y )
            return { worldPosition = { x = x, y = y, z = 1.5 },
                     getShapes = function() return { { shapeUuid = "x" } } end,
                     getWorldAabb = function()
                         return { x = x, y = y, z = 1.5 }, { x = x, y = y, z = 2.5 }
                     end }
        end
    """)

    # One probe per zone kind, found by walking the grid rather than guessed at.
    probes = {}
    g = plots["layout"]
    # Step 1: a filler seam is ONE block wide, so anything coarser walks over
    # the zone kind this check was written for.
    for bx in range(-90, 91):
        for by in range(-90, 91):
            z = L.locate(g, bx, by)
            if z is None:
                continue
            kind = str(z["kind"])
            probes.setdefault(kind, make(bx * block, by * block))
    assert len(probes) >= 4, (
        f"only found zone kinds {sorted(probes)} -- the sweep is too coarse to "
        "prove anything about 'everything'")
    assert "plot" in probes, "the sweep never landed on a plot"

    # OFF: the city is scenery. Nothing but a plot may be built on.
    S.Sv_SetQuiet("citybuild", False)
    for kind, body in sorted(probes.items()):
        v = P.sv_bodyIsOpen(plots, body)
        if kind == "plot":
            continue
        assert v != True, (  # noqa: E712 -- Lua true, not truthiness
            f"{kind} is buildable with citybuild OFF, so a plot event does not "
            "protect the ground between the plots")

    # ON: every square that is not a plot is ordinary buildable ground.
    S.Sv_SetQuiet("citybuild", True)
    shut = [k for k, b in sorted(probes.items())
            if k != "plot" and P.sv_bodyIsOpen(plots, b) != True]  # noqa: E712
    assert not shut, (
        f"free build is on and {shut} are still not buildable. 'Everything' has "
        f"to mean every zone kind the layout produces, which is {sorted(probes)}")

    # AND THE VERDICT HAS TO REACH A PROFILE THAT LETS YOU BOTH PLACE AND BREAK,
    # or "you can build on the plaza" is only half true.
    #
    # Through the real resolver rather than the table -- the lesson the polish
    # profile taught, where a correct profile that nothing could reach passed a
    # check which only ever proved the data said what the data said.
    lua2 = fresh("Layout.lua", "Palette.lua", "Settings.lua", "Plots.lua",
                 "Protection.lua")
    S2, P2, Prot = (lua2.globals().Settings, lua2.globals().Plots,
                    lua2.globals().Protection)
    S2.Sv_Load(False)
    S2.Sv_SetQuiet("citybuild", True)
    plots2 = lua2.eval("Plots()")
    P2.sv_onCreate(plots2, lua2.table_from({"grid": lua2.table_from(
        {"plot": 8, "gap": 1, "cols": 8, "rows": 8, "roadevery": 3,
         "roadwidth": 4, "plazacells": 1}), "enabled": True}))
    plots2["enabled"] = True
    lua2.globals().g_swPlots = plots2

    prot = lua2.eval("Protection()")
    Prot.sv_onCreate(prot, "open")
    lua2.globals().g_swProtection = prot
    Prot.sv_setResolver(prot, lua2.execute("""
        return function( body )
            if g_swPlots:sv_isScenery( body ) and not Settings.CityIsOpen() then
                return "locked"
            end
            local zone = g_swPlots:sv_bodyIsOpen( body )
            if zone == "sweep" then return "sweep" end
            if Settings.Get( "buildopen" ) == false
                and not g_swProtection:sv_modeClosesBuilding() then
                return false
            end
            return zone
        end
    """))

    make2 = lua2.execute("""
        return function( x, y )
            return { worldPosition = { x = x, y = y, z = 1.5 },
                     getShapes = function() return { { shapeUuid = "x" } } end,
                     getWorldAabb = function()
                         return { x = x, y = y, z = 1.5 }, { x = x, y = y, z = 2.5 }
                     end }
        end
    """)
    g2 = plots2["layout"]
    seen = {}
    for bx in range(-90, 91):
        for by in range(-90, 91):
            z = lua2.globals().Layout.locate(g2, bx, by)
            if z is None or str(z["kind"]) == "plot":
                continue
            seen.setdefault(str(z["kind"]), (bx, by))
    for kind, (bx, by) in sorted(seen.items()):
        # profileFor returns ( profile, name ), so lupa hands back a tuple
        got = Prot.sv_profileForTest(prot, make2(bx * block, by * block))
        prof = got[0] if isinstance(got, tuple) else got
        assert prof["buildable"] is True, (
            f"with free build ON, a {kind} resolves to a profile that cannot "
            "PLACE blocks")
        assert prof["erasable"] is True, (
            f"with free build ON, a {kind} resolves to a profile that cannot "
            "BREAK blocks -- half of 'place and break on everything'")


def no_diagnostic_runs_in_ordinary_play():
    """Scaffolding that outstayed its welcome is a performance bug waiting.

    MEASURED, from the owner's log on 2026-09-01: 140 `lift-trace` lines from
    one session of repeated NOTlift imports -- one 25-second, per-change trace
    started by EVERY import, in a session whose tick rate fell to about 0.6 Hz.
    The trace did not cause that (the content did), but log spam is the largest
    performance bug this project has ever measured -- the 1.79 GB single-player
    log -- and a diagnostic that fires hardest exactly when the server is
    already struggling is the wrong thing to leave switched on.

    The rule this encodes: anything that logs per ACTION rather than per event
    has to be behind /developer, which is off by default.
    """
    world = read("World.lua")
    body = world[world.index("function World.sv_traceStart"):]
    body = body[:body.index(chr(10) + "end" + chr(10))]
    assert "DeveloperOn" in body, (
        "the lift trace runs in ordinary play. Every import starts a 25-second "
        "per-change trace, on a server that may already be struggling")
    # ...and the gate has to come before the work, not after it.
    assert body.index("DeveloperOn") < body.index("sm.log.info"), (
        "the trace logs before it checks whether it should be running")


def the_alarm_never_cries_wolf_at_our_own_rollback():
    """MEASURED, 2026-09-01, through the bridge on a live world.

    A /restore of a 96-plot city reported `195 of 195 creations` and then:

        *** 274 blocks have disappeared ***
        BUILDS LOCKED automatically -- 195 bodies, 195 changed [locked 195]

    The alarm locked the world by itself, seconds after a rollback the host had
    just asked for. At an event that is the worst possible moment: you restore
    because something went wrong, and the mod's answer is to freeze everybody.

    Being quiet WHILE the job runs was already there and was never enough. The
    alarm compares the present against the PEAK inside a 20-second window, so
    the moment it starts listening again the window can still hold samples from
    before the clear -- a peak the rebuilt world will never match. The
    comparison straddles the job.

    So the fix is the TRANSITION, not a longer duration: when a wholesale job
    stops, throw the window away and count from what is actually there.
    """
    world = read("World.lua")
    fn = world[world.index("function World.sv_checkGriefAlarm"):]
    fn = fn[:fn.index(chr(10) + "end" + chr(10))]

    assert "alarmWasBusy" in fn, (
        "the alarm does not notice a wholesale job ENDING, so its window can "
        "still straddle the clear and fire at the rebuilt world")
    assert "sv_busy()" in fn, "the alarm no longer knows a snapshot job is running"
    assert "cityJob" in fn, (
        "building the city is a wholesale job too and the alarm does not know "
        "about it -- /plotbuild clears the old city first")

    # THE GUARD ITSELF, not just the assignment inside it. A break that turned
    # `if self.sw.alarmWasBusy then` into `if false then` left every string this
    # check looked for exactly where it was, and the check passed.
    assert "if self.sw.alarmWasBusy then" in fn, (
        "nothing tests the busy->idle transition, so the reset below it is dead "
        "code -- verified by breaking it exactly that way")

    # The baseline has to be thrown away on the transition, not merely delayed.
    tail = fn[fn.index("alarmWasBusy = false"):]
    assert "censusLog = {" in tail, (
        "the alarm resumes without resetting its window, so the peak from "
        "before the clear is still in it")
    # ...and the reset has to happen BEFORE the peak is computed, or it is
    # pointless.
    assert fn.index("alarmWasBusy = false") < fn.index("local peak"), (
        "the baseline is reset after the peak has already been taken")


def the_build_preset_leaves_nothing_dangerous_on():
    """BUILD is the one preset pressed with a lobby already in the world.

    ASKED FOR: "the building preset shall disable explosives. clay gun, fires.
    damage. and other stuff we talked about."

    A preset only writes the keys it names; everything else keeps whatever the
    host last set. "Whatever it was last time" is not a safety position, and it
    is how `destructible` -- the switch whose help reads "let explosives and the
    sledgehammer actually break builds" -- stayed ON through build events. It was
    on in this owner's live settings when this check was written.

    Runs the real Sv_ApplyPreset from a WORST CASE: every dangerous setting
    turned on first. Reading the preset table would only prove the table says
    what it says; this proves what a host is left holding.
    """
    lua = fresh("Settings.lua")
    S = lua.globals().Settings
    S.Sv_Load(False)

    # Everything that can hurt a build, a player, the ground, or an event.
    MUST_BE_OFF = {
        "fire": "fire spreads",
        "terraindamage": "explosions crater the ground",
        "aggro": "tapebots attack people",
        "destructible": "THE DAMAGE SWITCH -- explosives and the sledgehammer break builds",
        "claygun": "the clay gun, and clay is terrain nothing can remove",
        "firelauncher": "a flamethrower by another name",
        "extinguisher": "foam over everything",
        "cornades": "explosives",
        "beacons": "rule 12",
        "fireworks": "rule 11",
        "plasmadrills": "rule 11",
        "radios": "rule 5, and they cannot be muted",
        "horns": "rule 7, noise",
        "developer": "the crowd, the benchmark and the outside channel, one press away",
    }
    # ...and the three tools that do more in one press than a guest should hold.
    MUST_BE_HOST_ONLY = ("hostcleaner", "hostlift", "hostnotlift")

    # WORST CASE FIRST. A preset that simply agreed with the defaults would pass
    # a check that started from the defaults.
    for k in MUST_BE_OFF:
        S.Sv_SetQuiet(k, True)
    for k in MUST_BE_HOST_ONLY:
        S.Sv_SetQuiet(k, False)
    S.Sv_SetQuiet("maxjoints", 0)
    S.Sv_SetQuiet("maxbots", 0)
    S.Sv_SetQuiet("maxlights", 0)

    ok = S.Sv_ApplyPreset("build")
    assert ok, "the build preset did not apply"

    still_on = {k: why for k, why in MUST_BE_OFF.items() if S.Get(k) is not False}
    assert not still_on, (
        "the BUILD preset leaves these on, so an event inherits them from "
        "whatever the host last did: "
        + "; ".join(f"{k} ({why})" for k, why in still_on.items()))

    open_tools = [k for k in MUST_BE_HOST_ONLY if S.Get(k) is not True]
    assert not open_tools, (
        f"BUILD leaves {open_tools} open to guests. The cleaner ignores every "
        "permission flag, the lift carries whole creations and NOTlift spawns "
        "one out of nothing")

    # The rules board has to be true. /rules reads the live settings, so a limit
    # left at 0 makes the server announce a rule it is not enforcing.
    for k in ("maxjoints", "maxbots", "maxlights"):
        assert int(S.Get(k)) > 0, (
            f"BUILD leaves {k} at 0, so /rules announces a limit that is not "
            "being enforced")

    # And building has to be OPEN, or the preset named for building does not.
    assert S.Get("buildopen") is True, "BUILD does not open building"
    assert str(S.Get("protection")) == "open", "BUILD does not unlock the world"

    # THE BRIDGE MUST NOT BE WRITTEN. It is derived from `developer`, so turning
    # developer back on must give the host the channel they chose rather than
    # one this preset quietly took away -- the V52 lockdown mistake.
    import re
    src = read("Settings.lua")
    block = src[src.index("\tbuild = {"):]
    block = block[:block.index("\t},")]
    assert not re.search(r"^\s*bridge\s*=", block, re.M), (
        "the BUILD preset writes `bridge`. It is derived from `developer` -- "
        "writing it means /developer on cannot give it back")


def the_ban_ui_is_on_the_menu(): 
    """ASKED FOR TWICE. "make it accesible via menu", and then, with a
    screenshot of a menu that did not have it: "where is the ban? I want the ban
    UI to be in the menu."

    Both times the ban UI existed and was one tab inside WHO IS HERE, and both
    times the honest answer was that one tab in is not on the menu. Moderation
    is reached for while something is going wrong, which is the worst possible
    moment to be hunting through a panel for a view.

    So: a top-level entry, and it opens on the view that can actually ban
    somebody rather than on the list of people already banned.
    """
    lua = gui_lua()
    entries = {str(e["label"]): e for e in lua.globals().MenuGui.ENTRIES.values()}
    assert "BANS" in entries, (
        f"there is no BANS entry on the menu. It offers {sorted(entries)}")
    e = entries["BANS"]
    assert e["host"] is True, "BANS is offered to guests"
    assert e["panel"] is True, (
        "BANS is not marked as opening a panel, so the menu will queue a close "
        "that races the panel it just asked for")
    assert e["dev"] is None or e["dev"] is False, (
        "BANS is behind /developer, so it is invisible on a live event -- which "
        "is the one place moderation is needed")

    # ...and the entry has to land on the picker. The BANNED view cannot ban
    # anybody; landing there would put a click between the host and the only
    # action they opened it for.
    game = read("Game.lua")
    router = game[game.index("function Game.sv_n_menuOpen"):]
    router = router[:router.index(chr(10) + "end" + chr(10))]
    branch = router[router.index('what == "bans"'):]
    branch = branch[:branch.index("elseif")] if "elseif" in branch else branch
    assert "sv_openPeopleGui" in branch, "the BANS entry opens no panel"
    assert '"known"' in branch, (
        "BANS does not open on EVERYONE SEEN. That view is a superset of the "
        "ban list -- it shows who is banned AND is the only place one can be "
        "added -- so opening anywhere else costs a click for nothing")


# --------------------------------------------------------- work in progress ---


def the_mod_says_it_is_unfinished():
    """ASKED FOR: "add a disclaimer that the mod is a WORK IN PROGRESS."

    In both places somebody arrives: the join message, which everyone sees once
    and which scrolls away, and the front of the menu, which is what they are
    looking at when something behaves oddly. A guest who hits a rough edge and
    has not been told will report a broken server rather than an unfinished mod.
    """
    lua = gui_lua()
    captions = " ".join(
        str(w["caption"] or "")
        for host in (True, False)
        for w in walk_full(lua.globals().MenuGui.Build(host, False)))
    assert "WORK IN PROGRESS" in captions, (
        "the menu does not say the mod is a work in progress, in either audience")

    game = read("Game.lua")
    welcome = game[game.index("function Game.client_welcome"):]
    welcome = welcome[:welcome.index(chr(10) + "end")]
    assert "WORK IN PROGRESS" in welcome, (
        "the join message does not say the mod is a work in progress")
    assert "/menu" in welcome, (
        "the join message does not mention /menu -- 'I want the MENU to be the "
        "menu', and this is the one line a new arrival is guaranteed to read")


# ------------------------------------------------------------- the city ------


def the_city_can_be_opened_up_and_is_shut_by_default():
    """ASKED FOR: "add a settings that alows for the city to be modified too.
    because in the stream. the host allowed to modify the plaza. and the road."

    Off by default, because the default is a plot event and the whole reason a
    plot event works is that the ground between the plots belongs to nobody.

    Runs the real zone verdict rather than reading the table -- the lesson the
    polish profile taught, where a correct profile nothing could reach passed a
    check that only ever proved the data said what the data said.
    """
    lua = fresh("Layout.lua", "Palette.lua", "Settings.lua", "Plots.lua")
    S, P = lua.globals().Settings, lua.globals().Plots
    S.Sv_Load(False)
    assert S.Get("citybuild") is False, (
        "the city is modifiable by default -- a plot event would start with the "
        "roads and the plaza open to everybody")

    plots = lua.eval("Plots()")
    P.sv_onCreate(plots, lua.table_from({"grid": lua.table_from({}), "enabled": True}))
    plots["enabled"] = True

    # The ORIGIN is the plaza. That is what makes it the right probe here and
    # the wrong one for a plot check.
    body = lua.execute("""
        return { worldPosition = { x = 0, y = 0, z = 1.5 },
                 getShapes = function() return { { shapeUuid = "not-ours" } } end,
                 getWorldAabb = function()
                     return { x = 0, y = 0, z = 1.5 }, { x = 0, y = 0, z = 2.5 }
                 end }
    """)
    zone = P.sv_bodyZone(plots, body)
    assert zone is not None and str(zone["kind"]) == "plaza", (
        f"the probe is standing on {zone and zone['kind']!r}, not the plaza -- "
        "this check would prove nothing")

    assert P.sv_bodyIsOpen(plots, body) == "sweep", (
        "shared ground is not sweepable with citybuild off. Sweep is what makes "
        "a craftbot dropped on the plaza removable by anybody")

    S.Sv_SetQuiet("citybuild", True)
    assert P.sv_bodyIsOpen(plots, body) is True, (
        "the plaza is still only sweepable with citybuild ON, so nobody can "
        "build on it -- which is the whole request")

    # ...and the same for a road, so this is about shared ground rather than
    # about one square of it.
    for kind in ("road", "corner"):
        S.Sv_SetQuiet("citybuild", False)
        found = None
        for n in range(1, 400):
            probe = lua.execute("""
                return function( x, y )
                    return { worldPosition = { x = x, y = y, z = 1.5 },
                             getShapes = function() return { { shapeUuid = "x" } } end,
                             getWorldAabb = function()
                                 return { x = x, y = y, z = 1.5 },
                                        { x = x, y = y, z = 2.5 }
                             end }
                end
            """)(n * float(P.BLOCK), 0.0)
            z = P.sv_bodyZone(plots, probe)
            if z is not None and str(z["kind"]) == kind:
                found = probe
                break
        if found is None:
            continue                      # this grid has no such zone; fine
        assert P.sv_bodyIsOpen(plots, found) == "sweep", f"{kind} is not sweep by default"
        S.Sv_SetQuiet("citybuild", True)
        assert P.sv_bodyIsOpen(plots, found) is True, (
            f"a {kind} does not open up with citybuild on")


def opening_the_city_is_not_a_way_round_a_lockdown():
    """The decking is protected by exactly one thing -- sv_isScenery returning
    "locked" from the resolver -- so the switch has to be there, and WHERE it is
    decides whether it can be abused.

    After the host's bubble and before everything else: a lockdown still freezes
    the city, because a locked mode never consults the zone verdict at all.
    Opening the city is permission to build on it, never permission to ignore
    the protection mode.
    """
    world = read("World.lua")
    body = world[world.index("g_swProtection:sv_setResolver("):]
    body = body[:body.index("end )")]
    # ORDERING IS ABOUT CODE, and this resolver is four fifths prose -- the note
    # explaining why the bubble comes first mentions sv_isScenery two lines
    # ABOVE the bubble itself. Comparing raw offsets would compare comments.
    code = chr(10).join(l for l in body.splitlines()
                        if l.strip() and not l.strip().startswith("--"))

    # CODE, not comments. The resolver explains itself at length and the first
    # mention of sv_isScenery is a note about the host bubble -- a scan that
    # takes it is reading prose and reporting on the code.
    line = next((l for l in body.splitlines()
                 if "sv_isScenery" in l and not l.strip().startswith("--")), None)
    assert line and "CityIsOpen" in line, (
        "the resolver locks the decking without asking whether the city is "
        f"open, so citybuild cannot reach it: {line and line.strip()!r}")

    assert code.index("sv_hostReaches") < code.index("sv_isScenery"), (
        "the host bubble no longer comes first. The plaza IS scenery and it is "
        "where everyone spawns, so a bubble that lost to it would do nothing at "
        "the first place anybody tried")
    assert code.index("sv_isScenery") < code.index("sv_bodyIsOpen"), (
        "the scenery test moved after the zone verdict")

    # And a locked mode short-circuits before any of it. This is what makes the
    # ordering above sufficient rather than merely tidy.
    prot = read("Protection.lua")
    pf = prot[prot.index("local function profileFor("):]
    pf = pf[:pf.index(chr(10) + "end")]
    assert pf.index("isLockedMode( self.mode )") < pf.index("self.resolver"), (
        "a locked mode no longer short-circuits ahead of the resolver, so a "
        "verdict could reopen a world the host has shut")


# ------------------------------------------------------------------ bans -----


def the_ban_list_carries_across_worlds():
    """ASKED FOR: "perma ban list caries on accros worlds."

    It does, and for a reason that is a BUG everywhere else in this mod: every
    state file lives in $CONTENT_DATA, one folder shared by every world ever made
    from this mod. That sharing is what made a fresh world come up locked with
    claims on plots that did not exist -- and it is exactly what a ban list
    wants. A ban describes a PERSON, not a world.

    So this drives the real reset and asks the real ban list afterwards, rather
    than reading the source and trusting that a reset which does not mention
    Identity cannot reach it.
    """
    lua = fresh("Layout.lua", "Palette.lua", "Settings.lua", "Event.lua",
                "Plots.lua", "Identity.lua")
    S, I = lua.globals().Settings, lua.globals().Identity
    S.Sv_Load(False)
    I.Sv_Load()

    I.Sv_Touch(lua.table_from({"name": "A Griefer", "id": 4}))
    # Sv_Ban returns ok, detail, record -- three, and lupa unpacks all of them.
    banned = I.Sv_Ban("A Griefer", "wrecked the plaza")
    ok, detail = banned[0], banned[1]
    assert ok, f"the fixture could not ban anybody: {detail}"
    perma = str(I.Sv_KnownList()[1]["perma"])

    # A brand new world, through the real path.
    S.Sv_ResetWorldState("a-completely-different-world")
    lua.globals().Plots.Sv_ResetFile()
    lua.globals().Event.Sv_ResetFile()

    bans = I.Sv_BanList()
    assert len(bans) == 1, (
        f"{len(bans)} bans survived a new world. A ban list that resets with the "
        "world is not a ban list -- the person it names is still out there")
    assert str(bans[1]["perma"]) == perma, "the ban lost the id it was filed under"

    # Sv_IsBanned returns ok, entry -- two, so the truth is the first of them.
    assert I.Sv_IsBanned(lua.table_from({"name": "A Griefer"}))[0] is True, (
        "the banned player is no longer recognised after a new world")

    # The PERMA IDS have to survive too, or the ban survives and nothing can be
    # matched to it: a ban is filed under an id that only Players.json knows.
    assert str(I.Sv_NameOf(perma)) == "A Griefer", (
        "the player records were cleared by the world reset, so the surviving "
        "ban names an id nothing can resolve")

    # And the files have to be in the shared folder for any of that to hold.
    for path in (str(I.PLAYERS), str(I.BANS)):
        assert path.startswith("$CONTENT_DATA/"), (
            f"{path} is not in the mod-wide folder, so it would be per world")


# ------------------------------------------------------------ host only ------


def a_guest_can_open_no_host_panel():
    """"host only tools in menu work because for non host the buttons shall not
    be seen and not accesible."

    Two halves, and the menu only does the first. The panel tree is built on the
    player's own machine, so a modified client can draw itself any button it
    likes and send whatever the button would have sent. The opener is the single
    choke point every route ends at -- gating there cannot be forgotten by a new
    caller the way gating each route can.
    """
    game = read("Game.lua")
    GUEST_PANELS = {"sv_openPeopleGui"}      # roster: fair for a lobby to see
    openers = sorted(set(re.findall(r"^function\s+Game\.(sv_open\w+Gui)\s*\(",
                                    game, re.M)))
    assert len(openers) >= 8, f"only found {openers} -- the scan is wrong"
    for name in openers:
        if name in GUEST_PANELS:
            continue
        body = game[game.index("function Game." + name):]
        body = body[:body.index(chr(10) + "end" + chr(10))]
        head = body[:body.index(chr(10) + chr(10))] if chr(10) + chr(10) in body else body
        assert "getHostPlayer" in head, (
            f"{name} does not check the sender before it sends the panel. A "
            "guest cannot see the button, and that is not the same as not being "
            "able to press it")

    # MY PLOT is the one panel a guest is entitled to, and it is reached through
    # the world rather than an opener -- so the router's guest branch is checked
    # separately, and every other branch must name isHost.
    router = game[game.index("function Game.sv_n_menuOpen"):]
    router = router[:router.index(chr(10) + "end" + chr(10))]
    GUEST_ENTRIES = {"myplot", "rules", "players", "plot"}
    for m in re.finditer(r'what == "(\w+)"([^\n]*)', router):
        what, rest = m.group(1), m.group(2)
        if what in GUEST_ENTRIES:
            continue
        assert "isHost" in rest, (
            f"the menu router opens {what!r} without checking isHost: "
            f"{m.group(0).strip()!r}")


# --------------------------------------------------------------- unstuck -----


def the_unstuck_button_lands_in_the_middle_of_the_city():
    """REPORTED: "when I load into the world I spawn in the middle. but when I
    use the unstuck button I spawn not in the middle. but in the same spot every
    time."

    Both halves right, and the second explains the first. Vanilla's
    CreativePlayer.sv_n_unstuck is hard-coded to x = 16, y = 16 -- the corner of
    the first cell of a vanilla creative world -- while this mod centres its city
    on the origin and overrides the JOIN spawn only. Two spawn points, one of
    them moved.
    """
    player = read("Player.lua")
    assert "function Player.sv_n_unstuck" in player, (
        "the unstuck button is not overridden, so it still sends people to 16,16")
    body = player[player.index("function Player.sv_n_unstuck"):]
    body = body[:body.index(chr(10) + "end")]
    assert "sv_e_swUnstuck" in body, "the override does not reach the world"
    assert "16" not in body, "the override still names vanilla's fixed spot"

    world = read("World.lua")
    assert "function World.sv_e_swUnstuck" in world, "the world has no handler"
    handler = world[world.index("function World.sv_e_swUnstuck"):]
    handler = handler[:handler.index(chr(10) + "end" + chr(10))]
    assert "sv_unstuckPoint" in handler, "the handler picks its own destination"

    point = world[world.index("function World.sv_unstuckPoint"):]
    point = point[:point.index(chr(10) + "end" + chr(10))]
    assert "sv_spawnPoint" in point, (
        "the unstuck point is not derived from the same spawn point the join "
        "and /home use. Two spawn points that can disagree is the bug itself")
    assert "UNSTUCK_BLOCKS" in point, "no clearance above whatever is there"
    assert "spherecast" in point, (
        "a fixed height cannot promise you are above anything -- the middle of "
        "the city is the plaza, and by the end of an event it may have a good "
        "deal standing on it")

    n = int(re.search(r"World\.UNSTUCK_BLOCKS = (\d+)", world).group(1))
    assert n >= 20, f"the clearance is {n} blocks; the ask was 20"

    # And the destination really is the middle of the city, run rather than read.
    lua = fresh("Layout.lua", "Palette.lua", "Settings.lua", "Plots.lua")
    lua.globals().Settings.Sv_Load(False)
    plots = lua.eval("Plots()")
    lua.globals().Plots.sv_onCreate(
        plots, lua.table_from({"grid": lua.table_from({}), "enabled": True}))
    spawn = lua.globals().Plots.sv_spawnPoint(plots)
    assert abs(float(spawn.x)) < 1e-9 and abs(float(spawn.y)) < 1e-9, (
        f"the spawn point is ({spawn.x},{spawn.y}), not the middle of the city")

    game = read("Game.lua")
    join = game[game.index("function Game.sv_createNewPlayer"):]
    join = join[:join.index(chr(10) + "end")]
    assert "x = 0, y = 0" in join, (
        "the JOIN spawn is no longer the origin, so it and the unstuck spawn "
        "have drifted apart again")


# ---------------------------------------------------------------- canvas -----


def no_panel_is_taller_than_the_canvas():
    """sm.jsonGui.getViewSize() is 1720x720 -- MEASURED, and half the window it
    is drawn in. So a panel over about 690 tall hangs off the bottom of the
    screen with no error anywhere, and every fits check in this file measures a
    panel against ITSELF and would happily pass a panel of 900.

    That gap was real: the menu grew to 680 in this build and nothing in the
    suite would have noticed 780.
    """
    lua = gui_lua()
    CANVAS_W, CANVAS_H = 1720, 720
    MARGIN = 30                       # the panel is centred, so this is per edge
    for name in ("MenuGui", "PeopleGui", "SettingsGui", "PlotsGui", "EventGui",
                 "MyPlotGui", "StyleGui", "FocusGui", "ProtectionGui",
                 "BackupsGui", "DevGui", "ConfirmGui"):
        g = lua.globals()[name]
        if g is None or g.W is None or g.H is None:
            continue
        assert int(g.H) <= CANVAS_H - MARGIN, (
            f"{name} is {int(g.H)} tall against a {CANVAS_H} canvas -- the "
            "bottom of it, including its CLOSE button, is off the screen")
        assert int(g.W) <= CANVAS_W - MARGIN, (
            f"{name} is {int(g.W)} wide against a {CANVAS_W} canvas")


def main():
    check("rules: over budget still lets you trim", over_budget_still_lets_you_trim)
    check("rules: over budget never opens somebody else's plot",
          over_budget_never_opens_somebody_elses_plot)
    check("rules: over budget during buffer stays polish",
          over_budget_during_buffer_stays_polish)
    check("rules: the fast audit only looks at occupied plots",
          the_fast_audit_only_looks_at_plots_people_are_on)
    check("rules: trimming a plot reopens it on the next fast pass",
          trimming_a_plot_reopens_it_on_the_fast_pass)
    check("rules: the occupancy pass is what names the active plots",
          the_occupancy_pass_is_what_names_the_active_plots)

    check("style: the palette is the paint tool's own forty",
          the_palette_is_the_paint_tools_own)
    check("style: every preset names real blocks and colours",
          every_style_preset_names_real_blocks_and_colours)
    check("style: every default is a value the panel can cycle to",
          the_style_defaults_are_selectable_values)
    check("style: the city is built out of the selected blocks",
          the_city_is_built_out_of_the_selected_blocks)
    check("style: clicking a style row cycles all the way round",
          clicking_a_style_row_cycles_it_all_the_way_round)
    check("style: a plot can never be scenery whatever it is made of",
          a_plot_can_never_be_scenery_whatever_it_is_made_of)
    check("style: a restyle never unmakes the existing city",
          a_style_change_never_unmakes_the_existing_city)

    check("style: the panel fits for every piece and every odd value",
          the_style_panel_fits_for_every_piece)
    check("style: every block and every colour is one click away",
          every_block_and_every_colour_is_one_click_away)
    check("style: the swatch grid is the paint tool's grid",
          the_swatch_grid_is_the_paint_tools_grid)
    check("style: the panel agrees with itself about what is selected",
          the_panel_agrees_with_itself_about_what_is_selected)
    check("style: the panel and the builder name the same pieces",
          the_style_panel_and_the_builder_name_the_same_pieces)
    check("style: the settings panel no longer steps through the style",
          the_settings_panel_no_longer_steps_through_the_style)

    check("crowd: a look for every uuid the crowd spawns",
          the_crowd_has_a_look_for_every_uuid_it_spawns)
    check("crowd: no bot wears something a player cannot",
          no_bot_wears_something_a_player_cannot)
    check("crowd: every look is complete and resolves",
          every_look_is_complete_and_resolves)
    check("crowd: a crowd shows both sexes", a_crowd_shows_both_sexes)
    check("crowd: bots are named, and the names vary",
          bots_are_named_and_the_names_are_varied)
    check("crowd: naming a crowd never moves math.random",
          naming_a_crowd_never_moves_math_random)
    check("crowd: a character script never reads a shared global",
          a_character_script_never_reads_a_shared_global)

    check("bench: reports the frame rate it was given",
          the_bench_reports_the_frame_rate_it_was_given)
    check("bench: a starved server does not report 40 Hz",
          a_starved_server_does_not_report_forty_hertz)
    check("bench: walks the crowd up and stops", the_bench_walks_the_crowd_up_and_stops)
    check("bench: stops early if the crowd will not grow",
          the_bench_stops_early_if_the_crowd_will_not_grow)
    check("bench: a wild frame sample is thrown away", a_wild_frame_sample_is_thrown_away)
    check("bench: results survive a restart", the_results_survive_a_restart)
    check("bench: a guest cannot drive the run", a_guest_cannot_drive_the_run)
    check("backup: restore waits for the old world to be torn down",
          a_restore_waits_for_the_old_world_to_be_torn_down)
    check("plumbing: every world command has a branch", every_world_command_has_a_branch)
    check("plumbing: every key sent across the bridge is read",
          every_key_sent_across_the_bridge_is_read_on_the_far_side)

    check("crowd: a bot only ever builds on its own plot",
          a_bot_only_ever_builds_on_its_own_plot)
    check("alarm: a growing world never reports a shrinking census",
          a_growing_world_never_reports_a_shrinking_census)
    check("alarm: a shrinking world never reports more than exists",
          a_shrinking_world_never_reports_more_than_exists)
    check("crowd: a crowd spreads over the whole city",
          a_crowd_spreads_over_the_whole_city)
    check("crowd: bots own their plots through the real system",
          bots_own_their_plots_through_the_real_system)
    check("crowd: a cleared crowd leaves no claims behind",
          a_cleared_crowd_leaves_no_claims_behind)
    check("crowd: teams are formed through the request path",
          teamed_bots_are_teamed_through_the_request_path)
    check("crowd: every build style builds something different",
          every_build_style_builds_something_different)
    check("crowd: bots build up, inside the height cap",
          bots_build_up_and_stay_inside_the_height_cap)
    check("crowd: a crowd builds out of various blocks",
          a_crowd_builds_out_of_various_blocks)
    check("crowd: clearing takes the buildings with it",
          clearing_the_crowd_takes_the_buildings_with_it)
    check("crowd: churn never lets the world grow", churn_mode_never_lets_the_world_grow)
    check("crowd: imports cannot flood one tick",
          the_crowd_cannot_flood_the_server_with_imports)

    check("focus: the search finds a name by any part of it",
          focus_search_finds_a_name_by_any_part_of_it)
    check("focus: paging shows every name exactly once",
          focus_paging_shows_every_name_exactly_once)
    check("focus: the panel fits in every state", the_focus_panel_fits_in_every_state)
    check("focus: nothing on the panel sits on top of anything else",
          nothing_on_the_focus_panel_sits_on_top_of_anything_else)
    check("focus: the panel has exactly one typed box",
          the_focus_panel_has_exactly_one_typed_box)
    check("focus: the marker is drawn from the world, not the game",
          the_focus_marker_is_drawn_from_the_world_not_the_game)
    check("focus: a focus never outlives the player it marks",
          a_focus_never_outlives_the_player_it_marks)
    check("focus: only the host can point the lobby at somebody",
          only_the_host_can_point_the_lobby_at_somebody)
    check("hud: the roster grows for the focus line",
          the_roster_hud_grows_for_the_focus_line)

    check("hud: the roster fits in the top left corner",
          the_roster_hud_fits_in_the_top_left_corner)
    check("hud: the roster says what it was given", the_roster_hud_says_what_it_was_given)

    check("settings: schema is internally consistent", settings_schema_is_sane)
    check("settings: presets only name real keys", settings_presets_only_name_real_keys)
    check("settings: values round-trip and bad input is refused", settings_round_trip)
    check("settings: survive a restart", settings_persist_across_a_reload)
    check("settings: presets differ the way they claim", presets_differ_in_the_direction_they_claim)
    check("settings: the build preset leaves nothing dangerous on",
          the_build_preset_leaves_nothing_dangerous_on)
    check("tools: hazards bind the host too", hazard_tools_bind_the_host_too)
    check("tools: the lift is never treated as a hazard", the_lift_is_never_a_hazard)
    check("lockdown: every tool off a guest, none off the host",
          a_locked_world_takes_every_tool_off_a_guest_and_none_off_the_host)
    check("lockdown: you can still clear litter", a_locked_world_still_lets_you_clear_litter)
    check("lockdown: unlocking gives back the tools you chose",
          unlocking_gives_the_host_back_the_tools_they_chose)
    check("lockdown: the host can build where they stand",
          the_host_can_build_where_they_stand_in_a_locked_world)
    check("lockdown: strict leaves nothing a guest can touch",
          a_strict_lockdown_leaves_nothing_a_guest_can_touch)
    check("lockdown: the bubble is asked before the decking",
          the_bubble_is_the_first_thing_the_resolver_asks)
    check("lockdown: fire and aggro go off without being written",
          a_shut_world_forces_the_hazards_off_without_writing_them)
    check("lockdown: every protection write re-applies them",
          every_protection_write_re_applies_the_derived_hazards)
    check("lockdown: both files agree what locked means", both_files_agree_on_what_locked_means)
    check("lockdown: every mode change tells the clients",
          every_mode_change_tells_the_clients)

    check("identity: bans survive a restart", bans_survive_a_restart)
    check("backups: a capture completes and appears in the list",
          a_backup_captures_everything_and_can_be_put_back)
    check("identity: a ban reaches the engine, not just our list",
          a_ban_reaches_the_engine_not_just_our_list)
    check("identity: the same player keeps one permanent id", a_rename_keeps_the_permanent_id)
    check("identity: unban lifts the ban", unban_actually_unbans)

    check("protection: the sentinel tells all five profiles apart",
          the_sentinel_tells_every_profile_apart)
    check("protection: a locked world is really locked",
          nothing_is_destructible_while_locked)

    check("plots: one plot per player", one_plot_each)
    check("plots: teaming needs a shared filler", teaming_needs_a_shared_filler)
    check("plots: the plaza cannot be claimed", the_plaza_cannot_be_claimed)
    check("plots: no teaming across a road", teaming_is_refused_across_a_road)
    check("plots: the filler is shared only after teaming",
          the_filler_becomes_shared_only_after_teaming)
    check("plots: public ground belongs to nobody", public_ground_belongs_to_nobody)
    check("plots: spawn is the middle of the map", spawn_is_the_middle_of_the_map)
    check("plots: an empty unclaimed plot stays open", an_unclaimed_empty_plot_stays_open)
    check("plots: a player's block of our materials is not the city",
          a_players_block_of_our_materials_is_not_the_city)
    check("plots: the decking is safe but litter standing on it is not",
          the_decking_is_safe_but_litter_on_it_is_not)
    check("plots: the city is many separate bodies",
          the_city_is_many_separate_bodies)
    check("plots: a plot is one welded body with its own stand",
          a_plot_is_one_welded_body_with_its_own_stand)
    check("tools: the lift and NOTlift are both host only",
          the_lift_is_host_only_and_notlift_is_not)
    check("notlift: the import chain is wired end to end",
          the_notlift_import_chain_is_wired_end_to_end)
    check("notlift: importing enforces plot, open building and the cap",
          importing_a_creation_enforces_the_rules)
    check("notlift: an imported creation lands on a lift",
          an_imported_creation_lands_on_a_lift)
    check("notlift: a body on a lift is never the ground",
          a_body_on_a_lift_is_never_the_ground)
    check("notlift: every step works with items alone",
          every_step_works_with_items_alone)
    check("tools: deleting a whole creation crosses joints",
          deleting_a_whole_creation_crosses_joints)
    check("notlift: the lift trace is bounded",
          the_lift_trace_is_bounded)
    check("world: a new world does not inherit the last one's state",
          a_new_world_does_not_inherit_the_last_ones_state)
    check("protection: anything liftable can also be set down",
          anything_liftable_can_also_be_set_down)
    check("tools: the cleaner is wired to one uuid everywhere",
          the_cleaner_is_wired_to_the_same_uuid_everywhere)
    check("protection: the floor is free while building, pinned otherwise",
          the_city_floor_is_pinned_except_while_people_are_building)
    check("protection: /unlock actually reopens building (the lift bug)",
          unlock_actually_reopens_building)
    check("protection: buffer time actually reaches the polish profile",
          buffer_time_actually_reaches_the_polish_profile)
    check("protection: buffer time polishes but never places or breaks",
          buffer_time_lets_you_polish_but_not_place_or_break)
    check("plots: a body is located by where it is, not by its origin",
          a_body_is_located_by_where_it_is_not_by_its_origin)
    check("plots: standing near your own plot keeps it open",
          standing_near_your_own_plot_keeps_it_open)
    check("plots: you can only build on ground that is yours",
          you_can_only_build_on_ground_that_is_yours)
    check("plots: junk outside the city stays clearable", outside_the_city_is_sweepable)
    check("plots: a bulk purge never touches the city",
          a_bulk_purge_never_touches_the_city)
    check("plots: the grid and its claims survive a restart", grid_survives_a_save_and_load)

    check("teams: a link must be front, behind, left or right", a_link_must_be_orthogonal)
    check("teams: no diagonal links", a_link_may_not_be_diagonal)
    check("teams: no linking past a plot", a_link_may_not_skip_a_plot)
    check("teams: a teammate can connect you to a diagonal",
          a_teammate_can_connect_you_to_a_diagonal)
    check("teams: merely touching a team does not join it",
          a_plot_that_merely_touches_the_team_is_not_on_it)
    check("teams: the whole team may build on every plot in it",
          the_whole_team_may_build_on_every_plot_in_it)
    check("teams: a ring shares the block in the middle of it",
          a_ring_shares_the_block_in_the_middle_of_it)
    check("teams: leaving cuts whoever was only reachable through you",
          leaving_cuts_everyone_who_was_only_reachable_through_you)
    check("teams: giving up a plot removes it from its team",
          giving_up_a_plot_removes_it_from_its_team)
    check("teams: teams survive a restart", teams_survive_a_restart)
    check("teams: never across the plaza", a_team_never_crosses_the_plaza)

    check("event: prep then build then ended", an_event_runs_prep_then_build_then_ends)
    check("event: zero prep starts building at once", a_zero_minute_prep_starts_building_at_once)
    check("event: the clock survives a restart", the_clock_survives_a_restart)
    check("world: it says what may be built on, explicitly",
          the_world_says_what_may_be_built_on)
    check("protection: the alarm shouts but does not lock by default",
          the_alarm_shouts_but_does_not_lock_by_default)
    check("event: every phase boundary takes a snapshot",
          every_phase_boundary_takes_a_snapshot)
    check("event: a dead event does not resurrect itself on every load",
          a_dead_event_does_not_resurrect_itself_on_every_load)
    check("event: pausing stops the clock", pausing_stops_the_clock)
    check("event: time can be added and taken away", time_can_be_added_and_taken_away)
    check("event: the five minute handover is exact", the_five_minute_handover_is_exact)
    check("event: each time call happens once", each_time_call_happens_once)
    check("event: the clock reads the way a clock should", the_clock_reads_the_way_a_clock_should)
    check("event: the per-second broadcast stays small", the_client_state_is_small_and_complete)

    check("gui: any number can be typed into the event clock",
          any_number_can_be_typed_into_the_event_clock)
    check("gui: the event panel fits running and stopped",
          the_event_panel_fits_running_and_stopped)
    check("gui: the second confirm moves the dangerous button",
          the_confirm_panel_puts_the_dangerous_button_somewhere_else)

    check("hud: the clock sits in the top right at any resolution",
          the_event_hud_sits_in_the_top_right_at_any_resolution)
    check("hud: the clock reads correctly in every phase",
          the_event_hud_reads_correctly_in_every_phase)

    check("fonts: every caption can actually be drawn", every_caption_can_be_drawn)

    check("plumbing: every command a panel sends is answered",
          every_command_a_panel_sends_is_answered)
    check("plumbing: every button reaches a branch", every_button_reaches_a_branch)
    check("menu: every command is on the menu", every_command_is_on_the_menu)
    check("menu: the dev tools are off it until somebody asks",
          the_dev_tools_are_off_the_menu_until_somebody_asks_for_them)
    check("menu: hiding a button is not the same as shutting a door",
          hiding_a_button_is_not_the_same_as_shutting_a_door)
    check("menu: a dev tool can always be switched off",
          a_dev_tool_can_always_be_switched_off)
    check("menu: the mod says it is a work in progress",
          the_mod_says_it_is_unfinished)
    check("menu: a guest can open no host panel", a_guest_can_open_no_host_panel)
    check("gui: no panel is taller than the canvas", no_panel_is_taller_than_the_canvas)
    check("city: it can be opened up, and is shut by default",
          the_city_can_be_opened_up_and_is_shut_by_default)
    check("city: opening it is not a way round a lockdown",
          opening_the_city_is_not_a_way_round_a_lockdown)
    check("city: free build reaches every square that is not a plot",
          free_build_reaches_every_square_that_is_not_a_plot)
    check("spawn: unstuck lands in the middle of the city",
          the_unstuck_button_lands_in_the_middle_of_the_city)
    check("bans: banning never requires typing a name",
          banning_never_requires_typing_a_name)
    check("bans: the box filters and never bans",
          the_people_box_filters_and_never_bans)
    check("bans: a perma id finds the player wearing it",
          a_perma_id_finds_the_player_wearing_it)
    check("bans: the list carries across worlds", the_ban_list_carries_across_worlds)
    check("bans: the ban UI is on the menu", the_ban_ui_is_on_the_menu)
    check("bans: the allow list can actually be filled in",
          the_allow_list_can_actually_be_filled_in)
    check("bans: the host is never shown as locked out",
          the_host_is_never_shown_as_locked_out_of_their_own_server)
    check("joins: the mod adds no work to a join", the_mod_adds_no_work_to_a_join)
    check("joins: the host can see who is allowed to join",
          the_host_can_see_who_is_allowed_to_join)
    check("joins: changing who can join is never silent",
          changing_who_can_join_is_never_silent)
    check("polish: no diagnostic runs in ordinary play",
          no_diagnostic_runs_in_ordinary_play)
    check("alarm: it never cries wolf at our own rollback",
          the_alarm_never_cries_wolf_at_our_own_rollback)
    check("plumbing: no gui callback closes or redraws its own panel",
          no_gui_callback_touches_its_own_panel)
    check("plumbing: the panels share one interactive gui",
          only_one_interactive_gui_exists)

    check("backups: a save is the whole world, not just the builds",
          a_snapshot_is_the_whole_world_not_just_the_builds)
    check("clay: stopped before it lands, because it is terrain",
          clay_is_stopped_before_it_lands)
    check("access: the command gate is default deny", the_command_gate_is_default_deny)
    check("access: a guest types nothing but the way in",
          a_guest_types_nothing_but_the_way_in)
    check("access: the probes never reach the server",
          the_probe_commands_never_reach_the_server)
    check("access: guest buttons work without guest commands",
          guest_buttons_still_work_without_guest_commands)
    check("access: every server handler checks the sender",
          every_network_handler_checks_the_sender)
    check("access: no handler trusts an identity from its payload",
          no_handler_trusts_an_identity_from_its_payload)

    check("gui: the menu fits, for host and guest", the_menu_panel_fits)
    check("gui: every settings page fits and nothing is buried",
          the_settings_panel_fits_on_every_page)
    check("gui: the panels added for the menu fit", the_new_panels_fit)
    check("gui: the city panel fits at every value it can be stepped to",
          the_city_panel_fits_at_every_setting)
    check("gui: the city map stays inside its box", the_city_map_never_leaves_its_box)
    check("gui: the top-down map tiles exactly", the_top_down_map_tiles_exactly)
    check("gui: the my-plot panel fits in every state",
          the_my_plot_panel_fits_in_every_state)

    check("checklist: it knows which build it is", the_checklist_says_which_build_it_is)
    check("checklist: every item is complete and unique",
          every_checklist_item_is_complete_and_unique)
    check("checklist: every command it offers to run exists",
          every_command_the_checklist_can_run_exists)
    check("checklist: every log line it cites is one the mod writes",
          every_log_line_the_checklist_cites_is_one_the_mod_writes)
    check("checklist: a result survives a reload", a_checklist_result_survives_a_reload)
    check("checklist: everything it tells you to type still exists",
          everything_the_checklist_tells_you_to_type_still_exists)
    check("checklist: nothing on the panel sends you to a log",
          no_item_on_the_panel_sends_you_to_a_log)
    check("checklist: a log item is off the panel and names its line",
          a_log_item_is_off_the_panel_and_names_what_to_search_for)
    check("checklist: an answer the panel cannot give is never recorded",
          an_answer_the_panel_cannot_give_is_never_recorded)
    check("checklist: clearing takes it out of the file",
          clearing_a_result_takes_it_out_of_the_file)
    check("checklist: a note outlives the answer it was written for",
          a_note_outlives_the_answer_it_was_written_for)
    check("checklist: it walks every item exactly once",
          the_checklist_walks_every_item_exactly_once)
    check("checklist: it never walks a solo host into a guest item",
          the_checklist_never_walks_a_solo_host_into_a_guest_item)
    check("checklist: the summary names every failure", the_summary_names_every_failure)
    check("checklist: a new world never clears it", a_new_world_never_clears_the_checklist)
    check("checklist: wrapping never loses a word", wrapping_never_loses_a_word)
    check("checklist: the panel fits for every item and every page",
          the_checklist_panel_fits_for_every_item)
    check("checklist: the panel has exactly one typed box",
          the_checklist_panel_has_exactly_one_typed_box)
    check("checklist: it draws no character the other panels have not",
          the_checklist_draws_no_character_the_other_panels_have_not)
    check("checklist: answering writes the file at once",
          answering_from_the_panel_writes_the_file_at_once)

    check("bridge: shut unless somebody opens it",
          the_bridge_is_shut_unless_somebody_opens_it)
    check("bridge: never reads the same path twice",
          the_bridge_never_reads_the_same_path_twice)
    check("bridge: a file it cannot use does not wedge it",
          a_file_the_bridge_cannot_use_does_not_wedge_it)
    check("bridge: only runs things that look like commands",
          the_bridge_only_runs_things_that_look_like_commands)
    check("bridge: keeps listening after the command returns",
          the_bridge_keeps_listening_after_the_command_returns)
    check("bridge: every reply funnel tells it", every_reply_funnel_tells_the_bridge)
    check("bridge: runs inside its own pcall", the_bridge_runs_inside_its_own_pcall)

    # A FAILURE MESSAGE MUST NOT BE ABLE TO KILL THE REPORT.
    #
    # MEASURED, and it is the same bug the ban picker exists for: this console
    # is cp1251, an assertion that quoted a player name full of block-drawing
    # characters raised UnicodeEncodeError from print() itself, and the whole
    # run died with a traceback instead of naming the check that failed. A
    # suite that cannot report a failure involving a strange name is no use to
    # a mod whose hardest bug is strange names.
    def say(line):
        enc = getattr(sys.stdout, "encoding", None) or "ascii"
        print(line.encode(enc, "replace").decode(enc, "replace"))

    width = max(len(n) for n in PASS + [n for n, _ in FAIL])
    for name in PASS:
        say(f"  ok    {name}")
    for name, why in FAIL:
        say(f"  FAIL  {name:<{width}}  {why}")
    print()
    if FAIL:
        print(f"{len(FAIL)} of {len(PASS) + len(FAIL)} checks FAILED")
        return 1
    print("this covers the rules, not the engine -- bodies, tools, GUIs and the "
          "network still have to be exercised in game")
    print(f"all {len(PASS)} checks pass")
    return 0


if __name__ == "__main__":
    sys.exit(main())
