"""Check every uuid the mod names against the installed game's own databases.

A wrong uuid in Scrap Mechanic does not throw. A block uuid the shape database
has never heard of makes an import produce nothing; a tool uuid nothing owns
makes a ban that silently protects no one. Both look exactly like working code.

Two of this project's bugs were of that family:

  * uuid a2a2bb33 has the script class "PotatoLauncher" but is called the FIRE
    LAUNCHER in game and shoots fire, so grouping it with the spud guns by class
    name left a flamethrower switched on by default.
  * uuid 8f190ce2 is the lift, and survival owns it -- which was true, and was
    still the wrong explanation for the lift not working.

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


def index_game():
    """uuid -> (kind, declaring file). Everything the game can spawn or hand you."""
    out = {}
    roots = ["Data", "Survival", "ChallengeData"]
    for r in roots:
        base = GAME / r
        if not base.is_dir():
            continue
        for pattern, kind in (("**/*.shapeset", "shape"),
                              ("**/*.toolset", "tool"),
                              ("Tools/ToolSets/*.json", "tool"),
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

    game = index_game()
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
        print("  uuids our own toolset TAKES BACK from the base game:")
        for u, cls, where in sorted(redeclared):
            kind, gwhere = game[u]
            print(f"        {names.get(u, '?'):<16} {u}  ->  {cls}")
            print(f"        was {gwhere}, now {where}")
    if invented:
        print()
        print("  uuids that exist only in this mod:")
        for u, cls, where in sorted(invented):
            print(f"        {u}  ->  {cls}   ({where})")

    print()
    print(f"{len(ok)} uuids resolve, {len(missing)} do not "
          f"(out of {len(seen)} named by the mod)")
    if missing:
        print("a uuid the game does not know is a silent no-op, not an error")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
