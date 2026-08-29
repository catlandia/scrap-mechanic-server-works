"""What the in-game dev checklist recorded, read back out of the game's own file.

The checklist is Checklist.lua (the catalogue), ChecklistGui.lua (the panel) and
Game.lua (the state). Pressing PASS or FAIL in the game writes
$CONTENT_DATA/Checklist.json inside the INSTALLED mod, which is a real folder on
this disk -- so a play session leaves a file behind rather than a conversation
somebody has to remember to have.

This reads that file, joins it against the catalogue in the repo, and prints:

  * the count, per group and overall
  * every FAILURE with its note -- the actionable part, and the reason the panel
    has a note box at all
  * everything still unanswered, in the order the catalogue says to run it
  * anything answered against an OLDER BUILD, which is a pass that may no longer
    mean anything

The catalogue is read by executing the mod's own Lua through lupa, exactly as
dev/test_logic.py does, so this can never drift from what the panel shows.

Usage:
    python dev/checklist_report.py              # the installed mod's results
    python dev/checklist_report.py --todo       # just what is left to do
    python dev/checklist_report.py --fails      # just the failures
    python dev/checklist_report.py --mine       # the ones answered from the log
    python dev/checklist_report.py --set <id> <pass|fail|blocked|skip> [note]
    python dev/checklist_report.py <file.json>  # a results file from anywhere

THE TWO HALVES OF THE LEDGER. Items marked who = "log" are deliberately NOT on
the in-game panel:

    "so that there are only things I can directly test in games since I dont
     want to go in logs to test something. since stuff like that you can
     basicaly do your self."

Exactly so. Those are answered from here with --set, into the same file, so one
ledger holds both halves and the panel stays a list of things a person standing
in the world can actually do.
"""
import io
import json
import os
import pathlib
import sys

try:
    import lupa
except ImportError:
    sys.exit("lupa not installed:  pip install lupa")

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "mod" / "Scripts"
MODS = pathlib.Path(os.path.expandvars(
    r"%APPDATA%\Axolot Games\Scrap Mechanic\User"
))


def installed_results_path():
    """$CONTENT_DATA is the installed mod's own folder, so the file the game
    writes lands beside Settings.json and Bench.json."""
    name = json.loads(
        (ROOT / "mod" / "description.json").read_text(encoding="utf-8-sig"))["name"]
    users = [d for d in MODS.glob("User_*") if d.is_dir()]
    if not users:
        return None
    newest = max(users, key=lambda d: d.stat().st_mtime)
    return newest / "Mods" / name / "Checklist.json"


def catalogue():
    """The real Checklist.ITEMS, by running the mod's Lua.

    Reproducing the catalogue in Python instead would be a second copy that
    could disagree with the panel -- which is exactly the class of bug this
    whole file exists to help find.
    """
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    # Checklist.lua touches sm.json only inside Sv_Load / Sv_Save, which are not
    # called here; the stub is what lets the file be executed at all.
    lua.execute("sm = { json = {}, log = { info = function() end,"
                " warning = function() end } }")
    lua.execute(io.open(SCRIPTS / "Checklist.lua", encoding="utf-8").read())
    C = lua.globals().Checklist

    items = []
    for item in C.ITEMS.values():
        items.append({
            "id": str(item["id"]),
            "group": str(item["group"]),
            "title": str(item["title"]),
            "needs": str(item["needs"]) if item["needs"] is not None else None,
            "who": str(item["who"]) if item["who"] is not None else "player",
            "log": str(item["log"]) if item["log"] is not None else None,
        })
    groups = [(str(g["id"]), str(g["label"])) for g in C.GROUPS.values()]
    return items, groups, int(C.BUILD)


def load(path):
    if not path or not pathlib.Path(path).is_file():
        return None
    data = json.loads(pathlib.Path(path).read_text(encoding="utf-8-sig"))
    return data.get("results", {}) if isinstance(data, dict) else {}


MARK = {"pass": "PASS", "fail": "FAIL", "blocked": "BLOCK", "skip": "SKIP"}


def record(path, item_id, state, note, build):
    """Answer one item from this side, into the file the game reads and writes.

    Same shape the mod writes, because the mod loads this file on world create
    and a key it does not recognise would be dropped on the next save.
    """
    if state not in MARK:
        sys.exit(f"state must be one of {', '.join(MARK)}")
    data = {}
    if pathlib.Path(path).is_file():
        data = json.loads(pathlib.Path(path).read_text(encoding="utf-8-sig"))
    if not isinstance(data, dict):
        data = {}
    results = data.get("results") or {}
    entry = {"state": state, "build": build}
    if note:
        entry["note"] = note
    elif isinstance(results.get(item_id), dict) and results[item_id].get("note"):
        entry["note"] = results[item_id]["note"]
    results[item_id] = entry
    data["results"] = results
    data["build"] = build
    pathlib.Path(path).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(path).write_text(json.dumps(data, indent=1), encoding="utf-8")
    print(f"{MARK[state]}  {item_id}" + (f"   {note}" if note else ""))


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    flags = {a for a in sys.argv[1:] if a.startswith("--")}

    items, groups, build = catalogue()

    #  --set <id> <state> [note...] answers one item from this side. It writes
    #  the file the game reads, so an item answered here shows up in the panel
    #  the next time the world is created.
    if "--set" in sys.argv:
        at = sys.argv.index("--set")
        rest = sys.argv[at + 1:]
        if len(rest) < 2:
            sys.exit("usage: --set <id> <pass|fail|blocked|skip> [note]")
        item_id, state = rest[0], rest[1]
        note = " ".join(rest[2:]) if len(rest) > 2 else None
        if item_id not in {i["id"] for i in items}:
            sys.exit(f"no checklist item called {item_id!r}")
        return record(installed_results_path(), item_id, state, note, build)

    path = pathlib.Path(args[0]) if args else installed_results_path()
    results = load(path)

    print(f"catalogue  {len(items)} items, build V{build}")
    print(f"results    {path}")
    if results is None:
        print()
        print("  no results file yet -- nothing has been answered in game.")
        print("  Open the panel with /check, or the DEV CHECKLIST entry on /menu.")
        return 0
    print()

    def state(i):
        r = results.get(i["id"])
        if not isinstance(r, dict):
            return "untested"
        s = r.get("state", "untested")
        return s if s in MARK else "untested"

    #  per group, and overall
    if not flags & {"--todo", "--fails"}:
        print(f"  {'GROUP':<10} {'DONE':>7}  {'PASS':>4} {'FAIL':>4} {'BLOCK':>5} {'SKIP':>4}")
        #  The panel's own arithmetic: log items are counted in their own
        #  section below, not here, so these numbers match what the game shows.
        for gid, label in groups:
            rows = [i for i in items if i["group"] == gid and i["who"] != "log"]
            st = [state(i) for i in rows]
            done = sum(1 for s in st if s != "untested")
            print(f"  {label:<10} {done:>3}/{len(rows):<3}  "
                  f"{st.count('pass'):>4} {st.count('fail'):>4} "
                  f"{st.count('blocked'):>5} {st.count('skip'):>4}")
        st = [state(i) for i in items if i["who"] != "log"]
        done = sum(1 for s in st if s != "untested")
        print(f"  {'TOTAL':<10} {done:>3}/{len(st):<3}  "
              f"{st.count('pass'):>4} {st.count('fail'):>4} "
              f"{st.count('blocked'):>5} {st.count('skip'):>4}")
        print()

    #  the failures, with their notes. This is the part worth reading.
    fails = [i for i in items if state(i) == "fail"]
    if fails and not flags & {"--todo"}:
        print(f"FAILING -- {len(fails)}")
        for i in fails:
            r = results.get(i["id"], {})
            tag = "  [from the log]" if i["who"] == "log" else ""
            print(f"  {i['id']:<22} {i['title']}{tag}")
            if r.get("note"):
                print(f"  {'':<22} note: {r['note']}")
            if i["log"]:
                print(f"  {'':<22} log:  {i['log']}")
            if r.get("build") not in (None, build):
                print(f"  {'':<22} (recorded against V{r['build']})")
        print()

    blocked = [i for i in items if state(i) == "blocked"]
    if blocked and not flags & {"--todo", "--fails"}:
        print(f"BLOCKED -- {len(blocked)}")
        for i in blocked:
            r = results.get(i["id"], {})
            note = f"   {r['note']}" if r.get("note") else ""
            print(f"  {i['id']:<22} {i['title']}{note}")
        print()

    #  a pass from an older build is still a pass, and saying which build it came
    #  from is the difference between a ledger and a guess.
    stale = [i for i in items
             if state(i) != "untested"
             and results.get(i["id"], {}).get("build") not in (None, build)]
    if stale and not flags & {"--todo", "--fails"}:
        print(f"ANSWERED AGAINST AN OLDER BUILD -- {len(stale)}")
        for i in stale:
            r = results[i["id"]]
            print(f"  V{r.get('build')}  {MARK.get(r.get('state'), '?'):<5} "
                  f"{i['id']:<22} {i['title']}")
        print()

    #  MY HALF. These are off the panel on purpose -- their answer is in
    #  Logs/game-*.log and nowhere else, so they are answered from here with
    #  --set rather than by somebody standing in the world.
    mine = [i for i in items if i["who"] == "log"]
    if mine and not flags & {"--fails"}:
        print(f"FROM THE LOG -- {len(mine)}, not on the panel, mine to answer")
        for i in mine:
            st = state(i)
            print(f"  {MARK.get(st, '-   '):<5} {i['id']:<22} {i['title']}")
            if st == "untested":
                print(f"  {'':<5} {'':<22} search for: {i['log']}")
                print(f"  {'':<5} {'':<22} then: --set {i['id']} pass|fail")
        print()

    if flags & {"--mine"}:
        return 0

    if not flags & {"--fails"}:
        todo = [i for i in items if state(i) == "untested" and i["who"] != "log"]
        solo = [i for i in todo if i["needs"] != "guest"]
        guest = [i for i in todo if i["needs"] == "guest"]
        print(f"STILL UNANSWERED IN GAME -- {len(solo)} alone, "
              f"{len(guest)} need a second person")
        for i in solo:
            print(f"  {i['group']:<8} {i['id']:<22} {i['title']}")
        for i in guest:
            print(f"  {i['group']:<8} {i['id']:<22} {i['title']}   [GUEST]")
    return 0


if __name__ == "__main__":
    sys.exit(main())
