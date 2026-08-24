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
import pathlib
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
    },
    uuid = {
        new = function( s ) return { s = s, __uuid = true } end,
        getNil = function() return { s = "00000000-0000-0000-0000-000000000000" } end,
    },
    vec3 = {
        new = function( x, y, z ) return { x = x, y = y, z = z } end,
        zero = function() return { x = 0, y = 0, z = 0 } end,
    },
    game = {
        setEnableAggro = function() end,
        getCurrentTick = function() return _tick or 0 end,
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
    body = { getAllBodies = function() return {} end },
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
    seen = {}
    for name in profiles:
        p = profiles[name]
        key = (p["buildable"], p["destructable"], p["usable"], p["erasable"])
        assert key not in seen, (
            f"profiles {seen[key]!r} and {name!r} are indistinguishable to the "
            f"sentinel {key} -- switching between them would silently do nothing")
        seen[key] = name
    assert len(seen) >= 5, f"expected five profiles, found {len(seen)}"


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


def an_unclaimed_empty_plot_stays_open():
    lua, plots = plots_lua({"cols": 10, "rows": 10, "plazacells": 2})
    P = lua.globals().Plots
    L = lua.globals().Layout
    bx, by = L.plotCentre(plots["layout"], 1)
    body = lua.table_from({"worldPosition": lua.table_from(
        {"x": bx * 0.25, "y": by * 0.25, "z": 1.3})})
    assert P.sv_bodyIsOpen(plots, body) is True, (
        "an unclaimed plot with nobody on it should not be locked")


def shared_ground_never_becomes_erasable_scenery():
    lua, plots = plots_lua({"cols": 10, "rows": 10, "plazacells": 2})
    P = lua.globals().Plots
    body = lua.table_from({"worldPosition": lua.table_from({"x": 0.0, "y": 0.0, "z": 1.2})})
    assert P.sv_bodyIsOpen(plots, body) == "locked", (
        "the plaza resolved to something other than locked -- if it is ever "
        "'sweep' a guest can delete spawn")


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


def no_gui_callback_closes_its_own_panel():
    """A click handler must never call close() -- directly or via a helper.

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
    assert not offenders, (
        "a GUI callback closes a panel directly; everything after the close is "
        "dead code. Use cl_closeLater. " + "; ".join(offenders))

    assert "self:cl_drainCloses()" in game, (
        "nothing drains the deferred close queue, so panels queued for closing "
        "would stay open forever")
    tick = game[game.index("function Game.client_onFixedUpdate"):]
    assert "cl_drainCloses" in tick[:600], (
        "cl_drainCloses is not called early in client_onFixedUpdate")


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


def every_button_reaches_a_branch():
    """Every action a panel can emit is named in the script that handles clicks."""
    import re
    game = read("Game.lua")
    panels = ["MenuGui.lua", "PlotsGui.lua", "SettingsGui.lua",
              "EventGui.lua", "MyPlotGui.lua", "ConfirmGui.lua"]
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
    collect("menu(host)", lua.globals().MenuGui.Build(True))
    collect("menu(guest)", lua.globals().MenuGui.Build(False))

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


def gui_lua():
    lua = fresh("Layout.lua", "Settings.lua", "Event.lua", "EventHud.lua",
                "EventGui.lua", "ConfirmGui.lua",
                "SettingsGui.lua", "PlotsGui.lua", "MenuGui.lua", "MyPlotGui.lua")
    lua.globals().Settings.Sv_Load(False)
    return lua


def the_menu_panel_fits():
    lua = gui_lua()
    for host in (True, False):
        root = lua.globals().MenuGui.Build(host)
        label = f"menu ({'host' if host else 'guest'})"
        items = panel_fits(label, root, lua.globals().MenuGui.W, lua.globals().MenuGui.H)
        no_button_is_buried(label, items, lua.globals().MenuGui.H)


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


def main():
    check("settings: schema is internally consistent", settings_schema_is_sane)
    check("settings: presets only name real keys", settings_presets_only_name_real_keys)
    check("settings: values round-trip and bad input is refused", settings_round_trip)
    check("settings: survive a restart", settings_persist_across_a_reload)
    check("settings: presets differ the way they claim", presets_differ_in_the_direction_they_claim)
    check("tools: hazards bind the host too", hazard_tools_bind_the_host_too)
    check("tools: the lift is never treated as a hazard", the_lift_is_never_a_hazard)

    check("identity: bans survive a restart", bans_survive_a_restart)
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
    check("plots: the plaza can never be swept away",
          shared_ground_never_becomes_erasable_scenery)
    check("plots: junk outside the city stays clearable", outside_the_city_is_sweepable)
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
    check("event: pausing stops the clock", pausing_stops_the_clock)
    check("event: time can be added and taken away", time_can_be_added_and_taken_away)
    check("event: the five minute handover is exact", the_five_minute_handover_is_exact)
    check("event: each time call happens once", each_time_call_happens_once)
    check("event: the clock reads the way a clock should", the_clock_reads_the_way_a_clock_should)
    check("event: the per-second broadcast stays small", the_client_state_is_small_and_complete)

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
    check("plumbing: no gui callback closes its own panel",
          no_gui_callback_closes_its_own_panel)
    check("plumbing: the panels share one interactive gui",
          only_one_interactive_gui_exists)

    check("gui: the menu fits, for host and guest", the_menu_panel_fits)
    check("gui: every settings page fits and nothing is buried",
          the_settings_panel_fits_on_every_page)
    check("gui: the city panel fits at every value it can be stepped to",
          the_city_panel_fits_at_every_setting)
    check("gui: the city map stays inside its box", the_city_map_never_leaves_its_box)
    check("gui: the my-plot panel fits in every state",
          the_my_plot_panel_fits_in_every_state)

    width = max(len(n) for n in PASS + [n for n, _ in FAIL])
    for name in PASS:
        print(f"  ok    {name}")
    for name, why in FAIL:
        print(f"  FAIL  {name:<{width}}  {why}")
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
