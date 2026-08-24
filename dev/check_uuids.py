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
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
GAME = pathlib.Path(r"D:\SteamLibrary\steamapps\common\Scrap Mechanic")

UUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")


def strip_comments(text):
    return re.sub(r"//[^\n]*", "", text)


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


def mod_uuids():
    """Every uuid the mod names, with the constant or table it appears under."""
    found = []
    for path in sorted((ROOT / "mod").rglob("*")):
        if path.suffix.lower() not in (".lua", ".toolset", ".json") or not path.is_file():
            continue
        for n, line in enumerate(io.open(path, encoding="utf-8", errors="replace"), 1):
            for u in UUID_RE.findall(line.lower()):
                found.append((u, path.relative_to(ROOT).as_posix(), n, line.strip()))
    return found


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
