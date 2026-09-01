"""Check every uuid the mod names against the installed game's own databases.

A wrong uuid in Scrap Mechanic does not throw. A block uuid the shape database
has never heard of makes an import produce nothing; a tool uuid nothing owns
makes a ban that silently protects no one. Both look exactly like working code.

Two of this project's bugs were of that family:

  * uuid a2a2bb33 has the script class "PotatoLauncher" but is called the FIRE
    LAUNCHER in game and shoots fire, so grouping it with the spud guns by class
    name left a flamethrower switched on by default.
  * uuid 8f190ce2 is the lift, and survival owns it -- which was true, and was
    still the wrong explanation for the lift not working. The creative lift is
    5cc12f03, a completely different item, and baseGameContent "Survival" does
    not load the toolset that declares it.

That last one is why this script cares about baseGameContent. A Custom Game's
toolset can ADD a tool but cannot OVERRIDE one the base content already
declares -- first declaration wins, and the mod's is loaded last. So whether one
of our entries is a working addition or a silently ignored override depends
entirely on which base toolsets are loaded, and that is what config.json picks.

So this resolves each uuid to the file that declares it and prints the name the
game actually shows for it. Names come from the English inventoryDescriptions,
which is the only place the in-game title lives.

Re-run after any game update.

Usage: python dev/check_uuids.py
"""
import io
import json
import pathlib
import re
import struct
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
GAME = pathlib.Path(r"D:\SteamLibrary\steamapps\common\Scrap Mechanic")

UUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")


def strip_comments(text):
    """Make one of the game's own data files readable by a strict JSON parser.

    The engine's parser is not strict, and its own content relies on that in
    three ways. All three are in files this script has to read:

      // velocity 0-1        Survival/.../claygun.effectset:176
      /* ... */              Data/.../crystal.effectset:2 -- a whole block
      },                     Data/.../tools.effectset:500 -- a trailing comma
      }

    Five of the game's own effectsets use one of the three. Refusing them would
    mean reporting an effect that plainly exists as missing, so this reads them
    the way the engine does rather than the way json.load would like to.

    Block comments go first: one of them has a trailing comma inside it, and
    stripping commas first would leave the comment behind to be parsed.
    """
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    return re.sub(r",(\s*[}\]])", r"\1", text)


def load_json(path):
    try:
        return json.loads(strip_comments(io.open(path, encoding="utf-8-sig").read()))
    except Exception:                                  # noqa: BLE001
        return None


# Which toolset index each baseGameContent actually loads. Everything else under
# Data/ and Survival/ is still searched for shapes -- only TOOLS are gated this
# way, and only tools have the add-versus-override distinction that matters.
TOOL_INDEX = {
    "Survival": "Survival/Tools/toolsets.json",
    "Creative": "Data/Tools/toolsets.json",
    "None": "Data/Tools/toolsets.json",
}


def resolve(path_expr):
    """$GAME_DATA/... -> Data/...,  $SURVIVAL_DATA/... -> Survival/..."""
    return (path_expr.replace("$GAME_DATA", "Data")
                     .replace("$SURVIVAL_DATA", "Survival")
                     .replace("$CHALLENGE_DATA", "ChallengeData"))


def loaded_toolsets(base_content):
    """The toolset files this game will actually load, in load order."""
    index = GAME / TOOL_INDEX.get(base_content, TOOL_INDEX["Survival"])
    data = load_json(index) or {}
    out = []
    for entry in data.get("toolSetList", []):
        path = GAME / resolve(entry)
        if path.is_file():
            out.append(path)
    return out


def index_game(base_content):
    """uuid -> (kind, declaring file). Everything the game can spawn or hand you.

    Tools come only from the toolsets this baseGameContent loads, because a uuid
    declared in a file the game never reads is not a conflict.
    """
    out = {}
    for path in loaded_toolsets(base_content):
        text = strip_comments(io.open(path, encoding="utf-8-sig",
                                      errors="replace").read())
        for u in UUID_RE.findall(text.lower()):
            out.setdefault(u, ("tool", path.relative_to(GAME).as_posix()))

    for r in ("Data", "Survival", "ChallengeData"):
        base = GAME / r
        if not base.is_dir():
            continue
        for pattern, kind in (("**/*.shapeset", "shape"),
                              ("**/*.harvestableset", "harvestable")):
            for path in base.glob(pattern):
                text = strip_comments(io.open(path, encoding="utf-8-sig",
                                              errors="replace").read())
                for u in UUID_RE.findall(text.lower()):
                    out.setdefault(u, (kind, path.relative_to(GAME).as_posix()))

    # PROJECTILES, and this scanner was blind to them until V62.
    #
    # Same shape of gap as effects before V56 and scriptable objects before the
    # baseGameContent disaster: a whole class of uuid the game knows about and
    # this file did not look for, so a real uuid read as MISSING and a dead one
    # would have read as fine.
    #
    # They live in Lua rather than in a database -- `projectile_clay =
    # sm.uuid.new( "0ab670bb-..." )` -- because a projectile is not something a
    # player can be handed. World.lua names the clay one to decline it before it
    # lands, since clay is voxel terrain and nothing removes it afterwards.
    for name in ("survival_projectiles.lua", "projectiles.lua"):
        for path in GAME.glob(f"*/Scripts/game/{name}"):
            text = io.open(path, encoding="utf-8-sig", errors="replace").read()
            for u in UUID_RE.findall(text.lower()):
                out.setdefault(u, ("projectile", path.relative_to(GAME).as_posix()))
    return out


def index_names():
    """uuid -> the title the game shows, from the English inventory descriptions."""
    names = {}
    for path in GAME.glob("*/Gui/Language/English/inventoryDescriptions.json"):
        data = load_json(path)
        if not isinstance(data, dict):
            continue
        for u, entry in data.items():
            if isinstance(entry, dict) and entry.get("title"):
                names.setdefault(u.lower(), entry["title"])
    return names


# Not every uuid in this mod names a game item. A BLUEPRINT uuid is a folder in
# the player's own Blueprints directory; a STORAGE CHANNEL uuid is invented by
# whoever wrote the script. Neither will ever resolve against the install, and
# neither is a bug -- but this scanner cannot tell them apart from a tool uuid
# that has silently stopped existing, which is the mistake it is here to catch.
#
# So they are marked, in the source, on the line that names them. Marking is
# deliberately noisy and deliberately per-line: a blanket "ignore this file"
# would have hidden the survival sledgehammer going missing.
NOT_GAME_CONTENT = "not game content"


def mod_uuids():
    """Every uuid the mod names, with the constant or table it appears under.

    Lines carrying the NOT_GAME_CONTENT marker are skipped -- see above.
    """
    found = []
    for path in sorted((ROOT / "mod").rglob("*")):
        if path.suffix.lower() not in (".lua", ".toolset", ".json") or not path.is_file():
            continue
        for n, line in enumerate(io.open(path, encoding="utf-8", errors="replace"), 1):
            if NOT_GAME_CONTENT in line.lower():
                continue
            for u in UUID_RE.findall(line.lower()):
                found.append((u, path.relative_to(ROOT).as_posix(), n, line.strip()))
    return found


# WHICH SCRIPTABLE OBJECT INDEX EACH baseGameContent LOADS.
#
# This costs a broken build to learn, so it is written down rather than inferred.
#
# MEASURED, 2026-08-25. config.json went to "Creative" and the game came up stuck
# at 100% on the loading screen:
#
#   ERROR: ScriptableObjectManager.cpp:252
#          ScriptableObject type {46e23051-...(<Unnamed>)} not found!
#   [Lua] ERROR: $GAME_DATA/Scripts/game/CreativeGame.lua:47:
#          createScriptableObject failed due to invalid uuid
#
# 46e23051 is the WeatherManager, and it IS listed in
# Data/ScriptableObjects/scriptableObjectSets.sobdb -- the index you would expect
# "Creative" to load. It was still not found. So **"Creative" loads no scriptable
# object index at all**, and only "Survival" does. That is the measurement; the
# reason is engine-side and not visible from the content files.
#
# Why it is fatal rather than cosmetic: line 47 is the FIRST thing in
# CreativeGame.server_onCreate that can throw, and everything after it --
# including self.sv.saved.world = sm.world.createWorld( ... ) -- never runs. No
# world is ever created. The loading screen finishes, the game state starts, and
# there is nothing to enter. server_onFixedUpdate then throws on self.sv.time
# every tick.
SOBDB = {
    "Survival": "Survival/ScriptableObjects/scriptableObjectSets.sobdb",
    # measured above: not Data/ScriptableObjects/scriptableObjectSets.sobdb,
    # and not nothing-because-nobody-looked. Nothing.
    "Creative": None,
    "None": None,
}


def scriptable_object_uuids(base_content):
    """Every scriptable object type registered under this baseGameContent.

    The mod's own .sobdb files count too -- that is how a Custom Game is meant to
    add its own (Data/ExampleMods/Templates/*/ScriptableObjects/).
    """
    sets, registered = [], {}
    index = SOBDB.get(base_content)
    if index:
        data = load_json(GAME / index) or {}
        for entry in data.get("scriptableObjectSetList", []):
            sets.append((GAME / resolve(entry.get("scriptableObjectSet", "")), index))
    for own in sorted((ROOT / "mod").rglob("*.sobdb")):
        data = load_json(own) or {}
        for entry in data.get("scriptableObjectSetList", []):
            raw = entry.get("scriptableObjectSet", "")
            path = (ROOT / "mod" / raw.replace("$CONTENT_DATA/", "")
                    if raw.startswith("$CONTENT_DATA/") else GAME / resolve(raw))
            sets.append((path, own.relative_to(ROOT).as_posix()))
    for path, where in sets:
        if path is None or not pathlib.Path(path).is_file():
            continue
        data = load_json(path) or {}
        for entry in data.get("scriptableObjectList", []):
            u = str(entry.get("uuid", "")).lower()
            if u:
                registered[u] = (entry.get("classname", "?"), where)
    return registered


def scriptable_objects_our_game_needs():
    """Every createScriptableObject uuid on our game script's inheritance path.

    Our Game.lua's first line is dofile( "$GAME_DATA/Scripts/game/CreativeGame.lua" ),
    and it is CreativeGame.server_onCreate that makes the call that broke. So the
    scan follows one level of dofile out of the mod and into the install, which is
    exactly far enough to reach the parent class.
    """
    files, seen = [], set()
    for name in ("Game.lua", "World.lua", "Player.lua"):
        f = ROOT / "mod" / "Scripts" / name
        if f.is_file():
            files.append(f)
    for f in list(files):
        text = io.open(f, encoding="utf-8", errors="replace").read()
        for raw in re.findall(r'dofile\(\s*"([^"]+)"', text):
            if raw.startswith("$CONTENT_DATA/"):
                continue
            target = GAME / resolve(raw)
            if str(target) not in seen and target.is_file():
                seen.add(str(target))
                files.append(target)
    wanted = []
    for f in files:
        text = io.open(f, encoding="utf-8", errors="replace").read()
        for n, line in enumerate(text.splitlines(), 1):
            if "createScriptableObject" not in line:
                continue
            for u in UUID_RE.findall(line.lower()):
                try:
                    where = f.relative_to(ROOT).as_posix()
                except ValueError:
                    where = f.name
                wanted.append((u, f"{where}:{n}"))
    return wanted


# ---------------------------------------------------------------------------
# CHARACTERS.
#
# A Custom Game may ship its own character database -- the template does, at
# Data/ExampleMods/Templates/Survival Custom Game/Characters/Database/ -- and
# ours does, for the /crowd bot. Nothing else in the 1205-item Workshop corpus
# does, so there is no prior art at all and every failure mode here is one this
# project will hit first.
#
# All three of these are silent in game, which is the whole reason for the check:
#
#   1. a renderable path that does not exist         -> the piece does not draw
#   2. a scriptPath that does not exist              -> the character has no script
#   3. a uuid the base content already declares      -> first declaration wins,
#                                                       exactly as with toolsets
#
# (1) is checked against the WARDROBE as well as against the characterset,
# because the characterset only lists the fallback outfit -- the ninety-odd paths
# a bot can actually end up wearing live in mod/Scripts/Wardrobe.lua, and those
# are the ones that will be wrong after a game update.
CHARACTER_INDEX = {
    "Survival": "Survival/Character/charactersets.json",
    "Creative": "Data/Character/charactersets.json",
    "None": "Data/Character/charactersets.json",
}


def game_character_uuids(base_content):
    """uuid -> declaring file, for every character the loaded content registers."""
    out = {}
    index = GAME / CHARACTER_INDEX.get(base_content, CHARACTER_INDEX["Survival"])
    data = load_json(index) or {}
    for entry in data.get("characterSetList", []):
        path = GAME / resolve(entry)
        if not path.is_file():
            continue
        text = strip_comments(io.open(path, encoding="utf-8-sig",
                                      errors="replace").read())
        for u in UUID_RE.findall(text.lower()):
            out.setdefault(u, path.relative_to(GAME).as_posix())
    return out


def mod_charactersets():
    """The characterset files our own characterdb points at, in load order."""
    out = []
    for db in sorted((ROOT / "mod").rglob("*.characterdb")):
        data = load_json(db)
        if not isinstance(data, dict):
            print(f"  {db.relative_to(ROOT).as_posix()} will not parse")
            continue
        for entry in data.get("characterSetList", []):
            rel = entry.replace("$CONTENT_DATA/", "")
            path = ROOT / "mod" / rel
            out.append((db, entry, path))
    return out


def wardrobe_renderables():
    """Kept as a guard, and it should now find nothing.

    The looks used to be assembled in Lua and applied with
    overrideRenderableList -- 60 fps empty, 8 fps at twenty bots. They live in
    the characterset now, one fixed list per entry, which is how vanilla does it
    and is checked entry by entry above. A .rend path reappearing in a script
    means somebody has started rebuilding the runtime costume system.
    """
    src = ROOT / "mod" / "Scripts" / "BotCharacter.lua"
    if not src.is_file():
        return []
    text = io.open(src, encoding="utf-8").read()
    # The table is built by concatenating a directory prefix onto each entry, so
    # the literal paths are not in the file -- rebuild the prefixes the same way
    # the Lua does rather than trying to match whole paths.
    prefixes = dict(re.findall(r'^local ([A-Z]) = "([^"]+)"', text, re.M))
    out = []
    for n, line in enumerate(text.splitlines(), 1):
        m = re.search(r'^\s*([A-Z]) \.\. "([^"]+\.rend)"', line)
        if m and m.group(1) in prefixes:
            out.append((prefixes[m.group(1)] + m.group(2), n))
            continue
        for m in re.finditer(r'"(\$[A-Z_]+/[^"]+\.rend)"', line):
            out.append((m.group(1), n))
    return out


def report_characters(base_content):
    """0 if every character we ship is complete and reachable, else 1."""
    sets = mod_charactersets()
    if not sets:
        return 0, set()

    print()
    print(f"  characters: {len(sets)} characterset(s) from our characterdb")
    bad = 0
    ours = set()
    declared_here = game_character_uuids(base_content)

    for db, expr, path in sets:
        if not path.is_file():
            print(f"  MISSING CHARACTERSET  {expr}")
            print(f"        named by {db.relative_to(ROOT).as_posix()}")
            bad += 1
            continue
        data = load_json(path)
        if not isinstance(data, dict):
            print(f"  WILL NOT PARSE  {path.relative_to(ROOT).as_posix()}")
            bad += 1
            continue
        for entry in data.get("characters", []):
            u = str(entry.get("uuid", "")).lower()
            name = entry.get("name", "?")
            ours.add(u)
            if u in declared_here:
                print(f"  DEAD CHARACTER  {name}  {u}")
                print(f"        {declared_here[u]} declares it first and keeps it")
                bad += 1
                continue
            print(f"  ok    character   {name:<16} {u}")

            for key in ("character", "unit"):
                sp = (entry.get(key) or {}).get("scriptPath")
                if sp is None:
                    continue
                target = (ROOT / "mod" / sp.replace("$CONTENT_DATA/", "")
                          if sp.startswith("$CONTENT_DATA")
                          else GAME / resolve(sp))
                if not target.is_file():
                    print(f"        MISSING {key} script: {sp}")
                    bad += 1

            for r in entry.get("renderables", []):
                if not (GAME / resolve(r)).is_file():
                    print(f"        MISSING renderable: {r}")
                    bad += 1
            for key in ("ragdoll",):
                v = entry.get(key)
                if v and not (GAME / resolve(v)).is_file():
                    print(f"        MISSING {key}: {v}")
                    bad += 1

    # THE WARDROBE. The characterset lists one fallback outfit; these are the
    # paths a bot actually wears, and a game update is what breaks them.
    wr = wardrobe_renderables()
    if wr:
        gone = [(r, n) for r, n in wr if not (GAME / resolve(r)).is_file()]
        print(f"  ok    wardrobe    {len(wr)} renderable path(s), "
              f"{len(wr) - len(gone)} present")
        for r, n in gone:
            print(f"        MISSING  BotCharacter.lua:{n}  {r}")
        bad += len(gone)

    return (1 if bad else 0), ours


def report_scriptable_objects(base_content):
    """Returns the number of unresolvable scriptable object types."""
    registered = scriptable_object_uuids(base_content)
    wanted = scriptable_objects_our_game_needs()
    print()
    print(f"  scriptable objects: {len(registered)} type(s) registered under "
          f"baseGameContent {base_content!r}")
    if not wanted:
        print("  (nothing on our game script's path calls createScriptableObject)")
        return 0
    bad = []
    for u, site in wanted:
        if u in registered:
            cls, where = registered[u]
            print(f"  ok    scriptable  {cls:<20} {u}")
            print(f"        registered by {where}")
        else:
            bad.append((u, site))
    for u, site in bad:
        print(f"  MISSING SCRIPTABLE OBJECT  {u}")
        print(f"        needed at {site}")
    if bad:
        print()
        print("  This is FATAL, not cosmetic. createScriptableObject raises, so the")
        print("  server_onCreate that called it stops there -- and in CreativeGame")
        print("  that is BEFORE sm.world.createWorld. The world is never made, the")
        print("  loading screen reaches 100% with nothing to enter, and every")
        print("  later tick throws. Ship a .sobdb under mod/ that registers these,")
        print("  or put baseGameContent back to one that already does.")
    return len(bad)


# CUSTOM ITEM ICONS.
#
# A tool we add draws its menu icon from a rendered preview of its
# previewRenderable unless the mod ships an icon for it -- and NOTlift's
# previewRenderable is the LIFT's, so without an icon it looks exactly like the
# thing it exists to replace.
#
# Three separate things have to line up, and getting any one wrong is silent:
#
#   1. "custom_icons": true in description.json, or the xml is never read
#   2. an <Index name="<uuid>"> whose uuid is a tool we actually add
#   3. a <Frame point="x y"/> that lands inside the png
#
# This is the same failure shape as a tool with no inventoryDescriptions entry:
# everything works, nothing errors, and the item is just wrong in the menu.
def png_size(path):
    """Width and height straight out of the IHDR -- no image library needed."""
    data = io.open(path, "rb").read(24)
    if data[:8] != bytes([137, 80, 78, 71, 13, 10, 26, 10]):
        return None
    return struct.unpack(">II", data[16:24])


def report_icons(declared):
    """Returns the number of icon problems found."""
    import xml.etree.ElementTree as ET

    desc = load_json(ROOT / "mod" / "description.json") or {}
    xml = ROOT / "mod" / "Gui" / "IconMap.xml"
    png = ROOT / "mod" / "Gui" / "IconMap.png"
    custom = desc.get("custom_icons") is True

    print()
    if not xml.is_file() and not png.is_file():
        if custom:
            print('  ICONS: description.json says "custom_icons": true but there is')
            print("         no mod/Gui/IconMap.xml -- the flag does nothing")
            return 1
        print("  icons: none shipped (tools fall back to their preview renderable)")
        return 0

    bad = 0
    if not custom:
        print('  ICONS: mod/Gui/IconMap.xml exists but description.json does not set')
        print('         "custom_icons": true, so the game never reads it')
        bad += 1
    if not png.is_file():
        print("  ICONS: IconMap.xml names IconMap.png and it is not there")
        return bad + 1

    size = png_size(png)
    if size is None:
        print(f"  ICONS: {png.name} is not a png")
        return bad + 1
    pw, ph = size

    try:
        root = ET.parse(xml).getroot()
    except Exception as exc:
        print(f"  ICONS: IconMap.xml will not parse: {exc}")
        return bad + 1

    ours = {u for u, _, _ in declared}
    found = set()
    for group in root.iter("Group"):
        tw, th = (int(n) for n in group.get("size", "96 96").split())
        for index in group.findall("Index"):
            name = (index.get("name") or "").lower()
            frame = index.find("Frame")
            x, y = (int(n) for n in (frame.get("point", "0 0").split() if frame is not None
                                     else ("0", "0")))
            if x + tw > pw or y + th > ph:
                print(f"  ICONS: {name} points at {x},{y} and the tile runs off "
                      f"{png.name} ({pw}x{ph})")
                bad += 1
                continue
            if name == "empty":
                continue
            if not UUID_RE.fullmatch(name):
                print(f"  ICONS: index {name!r} is not a uuid")
                bad += 1
                continue
            if name not in ours:
                print(f"  ICONS: {name} has an icon but our toolset does not add "
                      "that tool -- the icon will never be shown")
                bad += 1
                continue
            found.add(name)
            print(f"  ok    icon        {name}  at {x},{y}")

    for u, cls, _ in sorted(declared):
        if u not in found:
            print(f"  note  no icon for {u} ({cls}) -- it will draw a render of "
                  "its previewRenderable")
    return bad


def loaded_effectsets(base_content):
    """Every .effectset the game will read, ours included, in load order.

    Effects are named by STRING, not by uuid -- sm.effect.createEffect takes
    "QuestMarker_Far" -- so they are invisible to the uuid scan above and would
    otherwise be the one kind of content this script cannot see. And a name the
    engine does not know does not return nil: it THROWS, which is why Focus.lua
    treats the pcall as the existence test.

    Data/Effects/Database/effectsets.json is always read. Survival's is read
    when baseGameContent is "Survival", which is the only value that works here
    -- see the config.json note in CLAUDE.md.
    """
    indexes = [GAME / "Data" / "Effects" / "Database" / "effectsets.json"]
    if base_content == "Survival":
        indexes.append(GAME / "Survival" / "Effects" / "Database" / "effectsets.json")

    out = []
    for index in indexes:
        data = load_json(index) or {}
        for entry in data.get("effectSetList", []):
            path = GAME / resolve(entry.get("path", ""))
            if path.is_file():
                out.append(path)

    # Ours last, the same order the game loads mod content in.
    ours = ROOT / "mod" / "Effects" / "Database" / "effectsets.effectdb"
    if ours.is_file():
        data = load_json(ours) or {}
        for entry in data.get("effectSetList", []):
            rel = entry.get("path", "").replace("$CONTENT_DATA/", "")
            path = ROOT / "mod" / rel
            out.append(path)          # may not exist -- that is the point
    return out


def report_effects(base_content):
    """The focus marker's effects, and every asset they name.

    Returns the number of problems found.

    This is the first effectset this mod has ever shipped. 87 Workshop items
    ship one and the Empty Custom Game template includes the folder, so the
    mechanism is real -- but nothing here has run one, and an effect that fails
    to create is a marker that never appears with no error anybody would notice.
    """
    print()
    wanted = {}
    focus = ROOT / "mod" / "Scripts" / "Focus.lua"
    if not focus.is_file():
        print("  effects: no Focus.lua, nothing to check")
        return 0

    text = io.open(focus, encoding="utf-8").read()
    for match in re.finditer(r'Focus\.(MARKER_EFFECTS|NAME_EFFECT)\s*=\s*(.+)', text):
        for name in re.findall(r'"([^"]+)"', match.group(2)):
            wanted[name] = match.group(1)

    declared, bad = {}, 0
    for path in loaded_effectsets(base_content):
        if not path.is_file():
            print(f"  EFFECTS: {path} is named by an effectdb and is not there")
            bad += 1
            continue
        data = load_json(path)
        if data is None:
            print(f"  EFFECTS: {path.name} will not parse")
            bad += 1
            continue
        for name in data:
            declared.setdefault(name, path)

    if not wanted:
        print("  effects: Focus.lua names none")
        return bad

    for name, field in sorted(wanted.items()):
        where = declared.get(name)
        if where is None:
            print(f"  EFFECTS: {name!r} ({field}) is declared by no effectset "
                  f"the game loads -- createEffect on it THROWS")
            bad += 1
            continue
        try:
            rel = where.relative_to(GAME).as_posix()
        except ValueError:
            rel = "OURS: " + where.relative_to(ROOT).as_posix()
        print(f"  ok    effect      {name:<26}  {rel}")

    # Every texture and renderable OUR effectset names has to exist, because a
    # billboard pointing at a missing png is an effect that creates cleanly and
    # draws nothing -- the worst failure mode there is, since the pcall fallback
    # never fires.
    for path in loaded_effectsets(base_content):
        if GAME in path.parents or not path.is_file():
            continue
        data = load_json(path) or {}
        for name, effect in data.items():
            for element in effect.get("effectList", []):
                assets = element.get("billboardTexture", [])
                if isinstance(assets, str):
                    assets = [assets]
                if element.get("name"):
                    assets = list(assets) + [element["name"]]
                for asset in assets:
                    target = GAME / resolve(asset)
                    if target.is_file():
                        print(f"  ok    asset       {pathlib.Path(asset).name:<26}"
                              f"  {name}")
                    else:
                        print(f"  EFFECTS: {name} names {asset}, which is not in "
                              "the install")
                        bad += 1

    # The compass icon, which is a plain file lookup and has bitten this project
    # before -- PlotMarker's icon had to be found in the Compass folder rather
    # than guessed.
    icon = re.search(r'Focus\.COMPASS_ICON\s*=\s*"([^"]+)"', text)
    if icon:
        found = list((GAME / "Data" / "Gui" / "Resolutions").glob(
            "*/Compass/" + icon.group(1)))
        if found:
            print(f"  ok    compass     {icon.group(1):<26}  "
                  f"{len(found)} resolution(s)")
        else:
            print(f"  EFFECTS: compass icon {icon.group(1)!r} is in no "
                  "Data/Gui/Resolutions/*/Compass/ folder")
            bad += 1

    return bad


def main():
    declared = []
    if not GAME.is_dir():
        sys.exit(f"game not found at {GAME} -- edit GAME at the top of this file")

    # Uuids the mod DECLARES are ours, not the game's, and are not supposed to
    # resolve against the install: the mod's own localId, and anything our
    # toolset introduces (the nugdupS test item exists only here).
    desc = load_json(ROOT / "mod" / "description.json") or {}
    ours = {str(desc.get("localId", "")).lower()}
    for path in (ROOT / "mod").rglob("*.toolset"):
        data = load_json(path) or {}
        for entry in data.get("toolList", []):
            u = str(entry.get("uuid", "")).lower()
            if u:
                declared.append((u, entry.get("script", {}).get("class", "?"),
                                 path.relative_to(ROOT).as_posix()))

    cfg = load_json(ROOT / "mod" / "config.json") or {}
    base_content = cfg.get("baseGameContent", "Survival")
    print(f"  baseGameContent: {base_content}")
    loaded = loaded_toolsets(base_content)
    print(f"  tool databases this loads: "
          f"{', '.join(p.relative_to(GAME).as_posix() for p in loaded)}")
    print()

    game = index_game(base_content)
    names = index_names()
    rows = mod_uuids()

    # Characters we declare ourselves resolve the same way tools we add do: they
    # are not in the base content, and that is the point of them.
    bad_characters, our_characters = report_characters(base_content)
    ours.update(our_characters)
    print()

    missing, ok = [], []
    redeclared = [(u, cls, where) for u, cls, where in declared if u in game]
    invented = [(u, cls, where) for u, cls, where in declared if u not in game]
    ours.update(u for u, _, _ in declared)
    seen = set()
    for u, path, line, text in rows:
        if u in ours or u in seen:
            continue
        seen.add(u)
        if u in game:
            kind, where = game[u]
            ok.append((u, kind, names.get(u, "?"), where, f"{path}:{line}"))
        else:
            missing.append((u, path, line, text[:70]))

    width = max((len(r[2]) for r in ok), default=10)
    for u, kind, name, where, site in sorted(ok, key=lambda r: (r[1], r[2])):
        print(f"  ok    {kind:<11} {name:<{width}}  {u}")
        print(f"        declared by {where}")
    for u, path, line, text in missing:
        print(f"  MISSING  {u}   {path}:{line}")
        print(f"           {text}")

    if redeclared:
        print()
        print("  DEAD ENTRIES -- our toolset re-declares a uuid the loaded base")
        print("  content already owns, and the first declaration wins:")
        for u, cls, where in sorted(redeclared):
            kind, gwhere = game[u]
            print(f"        {names.get(u, '?'):<16} {u}  ->  {cls}   IGNORED")
            print(f"        {gwhere} declares it first and keeps it")
    unnamed = []
    if invented:
        # A tool we add gets its menu name from our OWN inventoryDescriptions,
        # not from the toolset -- the toolset has no name field at all. Without
        # an entry the tool is still there and still works, it just has nothing
        # to call itself, which is exactly why "I dont see my deleting thing
        # appear" was reported about a tool the logs proved was in the game.
        ours = {}
        desc = ROOT / "mod" / "Gui" / "Language" / "English" / "inventoryDescriptions.json"
        if desc.is_file():
            try:
                ours = json.load(io.open(desc, encoding="utf-8"))
            except Exception as exc:
                print(f"  inventoryDescriptions.json will not parse: {exc}")
        print()
        print("  tools our toolset ADDS (nothing in the loaded base content")
        print("  declares these, so they take effect):")
        for u, cls, where in sorted(invented):
            title = ours.get(u, {}).get("title") or names.get(u, "?")
            named = u in ours
            print(f"        {title:<16} {u}  ->  {cls}"
                  f"{'' if named else '   <-- NO NAME IN THE MENU'}")
            if not named:
                unnamed.append((title, u))

    # SCRIPTABLE OBJECTS, not just tools. The tool scan above would have said
    # "89 resolve, 0 do not" on the build that could not create a world at all,
    # because the uuid that was missing was a scriptable object type and nothing
    # here had ever looked at those.
    bad_sobs = report_scriptable_objects(base_content)
    # EFFECTS ARE NAMED BY STRING, so nothing above can see them. See
    # report_effects: this is the first effectset the mod has ever shipped.
    bad_effects = report_effects(base_content)
    bad_icons = report_icons(declared)

    print()
    print(f"{len(ok)} uuids resolve, {len(missing)} do not "
          f"(out of {len(seen)} named by the mod)")
    if unnamed:
        print()
        print(f"  {len(unnamed)} tool(s) we add have no entry in")
        print("  mod/Gui/Language/English/inventoryDescriptions.json, so they")
        print("  appear in the creative menu with no name and no description.")
        for _, u in unnamed:
            print(f"        {u}")
    if bad_sobs or bad_icons or bad_characters or bad_effects:
        return 1
    if missing:
        print("a uuid the game does not know is a silent no-op, not an error")
        return 1
    if redeclared:
        print(f"{len(redeclared)} toolset entr"
              f"{'y is' if len(redeclared) == 1 else 'ies are'} dead -- see above")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
