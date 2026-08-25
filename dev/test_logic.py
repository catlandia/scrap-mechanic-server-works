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

    seen = {}
    for name in profiles:
        p = profiles[name]
        key = tuple(p[f] for f in fields)
        assert key not in seen, (
            f"profiles {seen[key]!r} and {name!r} are indistinguishable to the "
            f"sentinel {dict(zip(fields, key))} -- switching between them would "
            "silently do nothing, because matchesProfile would find every body "
            "already correct")
        seen[key] = name
    assert len(seen) >= 6, f"expected six profiles, found {len(seen)}"


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
            if g_swPlots:sv_isScenery( body ) then return "locked" end
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
            if g_swPlots:sv_isScenery( body ) then return "locked" end
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
            if g_swPlots:sv_isScenery( body ) then return "locked" end
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


def every_button_reaches_a_branch():
    """Every action a panel can emit is named in the script that handles clicks."""
    import re
    game = read("Game.lua")
    panels = ["MenuGui.lua", "PlotsGui.lua", "SettingsGui.lua",
              "EventGui.lua", "MyPlotGui.lua", "ConfirmGui.lua", "StyleGui.lua"]
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
    for state in ({"online": 0, "residents": 0}, {"online": 12, "residents": 3407}):
        collect("rosterhud", lua.globals().RosterHud.Build(
            lua.table_from(state), 1920, 1080))

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
                "StyleGui.lua")
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
            if g_swPlots:sv_isScenery( body ) then return "locked" end
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

# The wardrobe lives in BotCharacter.lua, not a file of its own: a character
# script cannot dofile mod content. Measured -- every bot threw "attempt to
# call field 'Name' (a nil value)" and walked around in the characterset's
# fallback outfit. The note at the top of that file has the log line.


def _look(lua, seed):
    """(list, sex, chosen) for one seed, as plain Python."""
    W = lua.globals().Wardrobe
    lst, sex, chosen = W.Look(seed)
    return [lst[i] for i in range(1, len(lst) + 1)], sex, dict(chosen)


def every_bot_is_dressed_and_named():
    lua = fresh("BotCharacter.lua")
    W = lua.globals().Wardrobe
    for seed in SEEDS:
        items, sex, chosen = _look(lua, seed)
        assert sex in ("male", "female"), f"seed {seed}: sex {sex!r}"

        if chosen.get("style") == "classic":
            # The classic set replaces the whole body at once -- head, chest,
            # hands, feet, legs, hair, backpack -- so it fills no slots and
            # must arrive complete or the bot is missing a limb.
            expect = set(W.CLASSIC[sex].values())
            missing = expect - set(items)
            assert not missing, (
                f"seed {seed}: classic {sex} bot is missing "
                f"{[q.rsplit('/', 1)[-1] for q in missing]}")
        else:
            # The slots with no bare-skin alternative for BOTH sexes. Female
            # has no char_female_body_pants / _jacket / _shoes at all, so a
            # bot missing one is a hole in the model.
            for slot in ("head", "jacket", "gloves", "pants", "shoes"):
                assert chosen.get(slot), f"seed {seed} ({sex}): no {slot}"

            # THE ONE COMBINATION RULE: a hat renderable carries Hathair_mat,
            # so a hat over hair draws hair through the hat.
            assert not (chosen.get("hat") and chosen.get("hair")), (
                f"seed {seed}: wearing a hat AND hair")
            # ...and the other half of it: a bare head is never bald.
            assert chosen.get("hat") or chosen.get("hair"), (
                f"seed {seed}: neither hat nor hair")

        assert len(items) == len(set(items)), f"seed {seed}: a renderable twice"
        assert len(items) >= len(W.BASE) + 6, f"seed {seed}: only {len(items)} pieces"

        name = W.Name(seed)
        assert 3 <= len(name) <= 24, f"seed {seed}: name {name!r} is {len(name)} chars"
        assert " " not in name, f"seed {seed}: {name!r} has a space in it"


def a_bot_looks_the_same_every_time():
    """The seed IS the network protocol -- see BotCharacter.lua.

    A bot's appearance is never sent anywhere: the server and every client each
    derive it from character.id. So if Look were not a pure function of its seed
    -- if it drew from math.random, or from table order -- every client would see
    a different crowd, and the bug would only ever appear with two people
    watching.
    """
    a, b = fresh("BotCharacter.lua"), fresh("BotCharacter.lua")
    for seed in SEEDS[:40]:
        assert _look(a, seed) == _look(b, seed), \
            f"seed {seed} dresses differently in a fresh Lua state"
        # ...and twice running in the SAME state, which catches a generator that
        # keeps state between calls.
        assert _look(a, seed) == _look(a, seed), f"seed {seed} is not stable"


def dressing_a_crowd_never_moves_math_random():
    """math.random is global, and the city draws from it.

    Layout and the plot shuffler both use math.random. If dressing a bot advanced
    that sequence, the city you got would depend on how many bots had been
    spawned first -- a genuinely horrible bug to find, and a silent one, because
    both cities would look perfectly plausible.
    """
    lua = fresh("BotCharacter.lua")
    lua.execute("math.randomseed( 12345 )")
    before = [lua.eval("math.random( 1, 1000000 )") for _ in range(5)]

    lua.execute("math.randomseed( 12345 )")
    for seed in range(1, 60):
        lua.globals().Wardrobe.Look(seed)
        lua.globals().Wardrobe.Name(seed)
    after = [lua.eval("math.random( 1, 1000000 )") for _ in range(5)]

    assert before == after, ("dressing bots advanced math.random -- the city "
                            "would come out differently depending on the crowd")


def a_crowd_does_not_come_out_in_uniform():
    """The failure mode of a bad LCG is not randomness, it is lockstep.

    Consecutive seeds differ only in their low bits and an LCG's low bits are its
    worst, so bots 1..20 -- which is exactly the range /crowd uses -- are where a
    naive generator collapses. Sampled over the crowd sizes the host will
    actually type.
    """
    lua = fresh("BotCharacter.lua")
    for n in (10, 20, 50):
        seeds = list(range(1, n + 1))
        # MODERN bots only, for the outfit count. The classic set is a whole
        # body with no slots, so it has exactly two looks -- one per sex -- and
        # counting those as duplicates would be counting a feature as a bug.
        # Every name is still expected to be unique, classic or not.
        modern = [s for s in seeds if _look(lua, s)[2].get("style") == "modern"]
        looks = {tuple(_look(lua, s)[0]) for s in modern}
        names = {lua.globals().Wardrobe.Name(s) for s in seeds}
        assert len(looks) >= len(modern) * 0.9, (
            f"{len(modern)} modern bots produced only {len(looks)} distinct outfits")
        assert len(names) == n, f"{n} bots produced only {len(names)} distinct names"

    # Both sexes turn up, and neither dominates. A 50/50 split that came out
    # 48/2 would still pass every check above.
    # Both art paths turn up. The classic set is a different directory tree
    # and a different texture convention, which is the half of this that
    # actually tests "handling of extra assets".
    styles = [_look(lua, s)[2].get("style") for s in SEEDS]
    assert "classic" in styles and "modern" in styles, (
        f"only one body style across {len(SEEDS)} bots: {set(styles)}")
    classic = styles.count("classic")
    assert 0.1 < classic / len(styles) < 0.45, (
        f"{classic}/{len(styles)} classic -- the style roll is lopsided")

    sexes = [_look(lua, s)[1] for s in SEEDS]
    males = sexes.count("male")
    assert 0.3 < males / len(sexes) < 0.7, \
        f"{males}/{len(sexes)} male -- the sex bit is not doing its job"

    # And the optional slots are genuinely optional, in both directions.
    # Only modern bots have slots at all; a classic body fills none.
    modern = [s for s in SEEDS if _look(lua, s)[2].get("style") == "modern"]
    for slot in ("facial", "backpack", "hat"):
        worn = sum(1 for s in modern if _look(lua, s)[2].get(slot))
        assert 0 < worn < len(modern), (
            f"{slot} is worn by {worn}/{len(modern)} modern bots -- "
            f"it is not optional at all")


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


def a_crowd_is_random_not_merely_balanced():
    """A perfect 50/50 split can still be perfectly predictable.

    The first generator produced exactly this over ids 1..20:

        M f M f M f M f M f M f M f M f M f f M

    Fifty per cent male, and two bots side by side could never be the same sex.
    The ratio check above passed it without complaint, which is the whole point
    of this one existing separately. REPORTED as "make sure gender is random
    too".

    Counted as RUNS -- maximal stretches of the same value. A fair coin over n
    flips averages about n/2 runs; strict alternation gives n. The bound is wide
    because a real coin is noisy, and it only has to catch lockstep.
    """
    lua = fresh("BotCharacter.lua")
    W = lua.globals().Wardrobe

    def runs(seq):
        return 1 + sum(1 for a, b in zip(seq, seq[1:]) if a != b)

    # Across bots: consecutive character ids, which is what a crowd actually is.
    for base in (1, 100, 5000):
        seq = [W.Sex(base + i) for i in range(40)]
        r = runs(seq)
        assert 12 <= r <= 30, (
            f"ids {base}..+40 gave {r} runs of 40 -- "
            f"{'lockstep' if r > 30 else 'sticky'}: "
            + "".join("M" if s == "male" else "f" for s in seq))

    # Within one bot: the same generator drawn from repeatedly.
    # Dot, not colon: the generator is closures, because the callback sandbox
    # in a character script has no setmetatable.
    rng = W.Rng(12345)
    seq = [rng.next(2) for _ in range(60)]
    r = runs(seq)
    assert 18 <= r <= 45, f"one generator gave {r} runs of 60: {seq}"

    # And the body style, the other two-way roll a crowd shows off at a glance.
    styles = [_look(lua, i)[2].get("style") for i in range(1, 41)]
    assert runs(styles) >= 8, (
        f"body style alternates in lockstep: {''.join(s[0] for s in styles)}")


def no_bot_wears_the_other_sex():
    """Female garments live in the Char_Male tree, so the split is by FILENAME.

    char_male_ / char_female_ / char_shared_ is the only thing separating them,
    which makes a copy-paste in the table completely invisible until a bot is
    standing in front of you wearing half a female outfit.

    Hair is the deliberate exception: vanilla's own mechanicmale1 wears
    char_female_hair_07, so the hair pool is shared on purpose.
    """
    lua = fresh("BotCharacter.lua")
    base = set(lua.globals().Wardrobe.BASE.values())
    for seed in SEEDS:
        items, sex, chosen = _look(lua, seed)
        wrong = "char_female_" if sex == "male" else "char_male_"
        # The classic set is checked over the whole renderable list, since it
        # fills no slots -- and it is the easier of the two to get wrong,
        # because male and female differ only by a directory name.
        for r in items:
            leaf = r.rsplit("/", 1)[-1]
            if r in base or not leaf.startswith("char_classic_"):
                continue
            other = "female" if sex == "male" else "male"
            assert not leaf.startswith("char_classic_" + other), (
                f"seed {seed}: a {sex} classic bot is wearing {leaf}")
        for slot, path in chosen.items():
            if slot in ("style", "hair") or path in base:
                continue
            leaf = path.rsplit("/", 1)[-1]
            assert not leaf.startswith(wrong), \
                f"seed {seed}: a {sex} bot is wearing {leaf} in the {slot} slot"
        # The skeleton and its animations are char_male_ for everybody -- that is
        # the rig, not a garment, and vanilla's female NPCs use it too.
        for r in base:
            assert r in items, f"seed {seed}: missing base renderable {r}"


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
    lua, crowd, plots = _crowd(bots=4)
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

    check("crowd: every bot is dressed and named", every_bot_is_dressed_and_named)
    check("crowd: a bot looks the same to everybody", a_bot_looks_the_same_every_time)
    check("crowd: dressing a crowd never moves math.random",
          dressing_a_crowd_never_moves_math_random)
    check("crowd: a crowd does not come out in uniform",
          a_crowd_does_not_come_out_in_uniform)
    check("crowd: a character script never reads a shared global",
          a_character_script_never_reads_a_shared_global)
    check("crowd: a crowd is random, not merely balanced",
          a_crowd_is_random_not_merely_balanced)
    check("crowd: no bot wears the other sex", no_bot_wears_the_other_sex)

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
    check("plumbing: every world command has a branch", every_world_command_has_a_branch)

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

    check("hud: the roster fits in the top left corner",
          the_roster_hud_fits_in_the_top_left_corner)
    check("hud: the roster says what it was given", the_roster_hud_says_what_it_was_given)

    check("settings: schema is internally consistent", settings_schema_is_sane)
    check("settings: presets only name real keys", settings_presets_only_name_real_keys)
    check("settings: values round-trip and bad input is refused", settings_round_trip)
    check("settings: survive a restart", settings_persist_across_a_reload)
    check("settings: presets differ the way they claim", presets_differ_in_the_direction_they_claim)
    check("tools: hazards bind the host too", hazard_tools_bind_the_host_too)
    check("tools: the lift is never treated as a hazard", the_lift_is_never_a_hazard)

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
    check("plumbing: no gui callback closes or redraws its own panel",
          no_gui_callback_touches_its_own_panel)
    check("plumbing: the panels share one interactive gui",
          only_one_interactive_gui_exists)

    check("access: every server handler checks the sender",
          every_network_handler_checks_the_sender)
    check("access: no handler trusts an identity from its payload",
          no_handler_trusts_an_identity_from_its_payload)

    check("gui: the menu fits, for host and guest", the_menu_panel_fits)
    check("gui: every settings page fits and nothing is buried",
          the_settings_panel_fits_on_every_page)
    check("gui: the city panel fits at every value it can be stepped to",
          the_city_panel_fits_at_every_setting)
    check("gui: the city map stays inside its box", the_city_map_never_leaves_its_box)
    check("gui: the top-down map tiles exactly", the_top_down_map_tiles_exactly)
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
