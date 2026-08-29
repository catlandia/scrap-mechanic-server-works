"""Drive a running Server Works world from out here.

The mod half is mod/Scripts/Bridge.lua and the whole argument is in its header.
In short: the sandbox has no network and no filesystem outside $CONTENT_*, but
BOTH SIDES can reach the installed mod's own folder -- so a file is the channel.

    this script   writes  Cmd-7.json
    the mod, 2 Hz  reads it, runs it as the host, listens for replies
                   writes  Out-7.json
    this script    reads that

A NEW FILE EVERY TIME. The engine caches data files it reads, and a rewritten
file might well come back stale; a path that has never been read cannot. That is
why the sequence number is in the filename rather than in the file.

In the game, once, per world:

    /bridge on

Then from here:

    python dev/bridge.py /protection
    python dev/bridge.py "/set plots on" "/plot claim" "/why"
    python dev/bridge.py --wait 30 /plotbuild      # a slow one: keep listening
    python dev/bridge.py --status                  # is it even on
    python dev/bridge.py --clean                   # tidy old Cmd/Out files

Every command runs AS THE HOST through the same dispatch a typed command goes
through, so this can reach nothing the host could not type themselves.
"""
import json
import os
import pathlib
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
MODS = pathlib.Path(os.path.expandvars(
    r"%APPDATA%\Axolot Games\Scrap Mechanic\User"
))

POLL_SECONDS = 0.25
DEFAULT_TIMEOUT = 25


def mod_dir():
    name = json.loads(
        (ROOT / "mod" / "description.json").read_text(encoding="utf-8-sig"))["name"]
    users = [d for d in MODS.glob("User_*") if d.is_dir()]
    if not users:
        sys.exit(f"no User_* directory under {MODS}")
    newest = max(users, key=lambda d: d.stat().st_mtime)
    return newest / "Mods" / name


def read_json(path):
    try:
        return json.loads(pathlib.Path(path).read_text(encoding="utf-8-sig"))
    except Exception:                                    # noqa: BLE001
        return None


def state(d):
    """What the mod says about itself: is it listening, and for which file."""
    return read_json(d / "Bridge.json")


def show_state(d):
    st = state(d)
    print(f"mod folder   {d}")
    if st is None:
        print()
        print("  Bridge.json is not there, so the bridge has never been switched")
        print("  on in this install. In the game, as host:   /bridge on")
        return 1
    print(f"  bridge       {'ON' if st.get('on') else 'off'}")
    print(f"  waiting for  {st.get('waitingFor')}")
    print(f"  commands run {st.get('ran', 0)}")
    if not st.get("on"):
        print()
        print("  Switch it on in the game with:   /bridge on")
        return 1
    return 0


def send(d, commands, wait, timeout, note=None):
    # GIT BASH REWRITES A LEADING SLASH. MSYS path conversion turns /plot into
    # C:/Program Files/Git/plot before python ever sees it, so the batch arrives
    # full of things that are not commands, runs nothing, and comes back empty.
    # Caught here because the symptom -- a silent empty transcript -- looks
    # exactly like the bridge not working.
    mangled = [c for c in commands if "Program Files" in c or c.startswith("C:/")]
    if mangled:
        print("  these arrived as Windows paths, not commands:")
        for c in mangled:
            print(f"    {c}")
        print("  A leading / is rewritten by Git Bash. Use PowerShell, or put")
        print("  MSYS_NO_PATHCONV=1 in front of the command, or use --file.")
        return 1

    st = state(d)
    if st is None or not st.get("on"):
        return show_state(d)

    seq = int(st.get("seq", 1))
    cmd_path = d / f"Cmd-{seq}.json"
    out_path = d / f"Out-{seq}.json"

    # A leftover result under this number would be read as the answer to a
    # command that has not run yet. It cannot normally happen -- the mod only
    # ever moves the number forward -- but a half-finished session can leave one.
    if out_path.exists():
        out_path.unlink()

    payload = {"commands": commands, "wait": wait}
    if note:
        payload["note"] = note
    cmd_path.write_text(json.dumps(payload, indent=1), encoding="utf-8")

    for line in commands:
        print(f"  -> {line}")

    deadline = time.time() + timeout + wait
    while time.time() < deadline:
        if out_path.exists():
            time.sleep(0.15)          # let the write finish
            result = read_json(out_path)
            if result is not None:
                return report(result)
        time.sleep(POLL_SECONDS)

    print()
    print(f"  no answer within {timeout + wait:.0f}s.")
    print("  Is the game running, with a world loaded, and /bridge on?")
    print(f"  It should be reading {cmd_path.name} -- if that file is still")
    print("  there, nothing is polling for it.")
    return 1


def report(result):
    failed = 0
    # `or []` rather than a default: an empty Lua table is not written as [], it
    # is left out, so the key comes back None rather than missing. Reading that
    # as a list crashed this the first time a batch ran zero commands.
    for entry in (result.get("results") or []):
        if entry.get("ok"):
            continue
        failed += 1
        print(f"  !! {entry.get('command')}  ->  {entry.get('error')}")

    said = result.get("said") or []
    if said:
        print()
        for line in said:
            print(f"     {line}")
    else:
        print()
        print("     (it said nothing)")
    return 1 if failed else 0


def clean(d):
    n = 0
    for f in list(d.glob("Cmd-*.json")) + list(d.glob("Out-*.json")):
        f.unlink()
        n += 1
    print(f"removed {n} file(s)")
    return 0


def main():
    args = sys.argv[1:]
    d = mod_dir()
    if not d.is_dir():
        sys.exit(f"the mod is not installed at {d} -- run dev/sync_mod.py")

    if "--status" in args:
        return show_state(d)
    if "--clean" in args:
        return clean(d)

    wait = 1.5
    timeout = DEFAULT_TIMEOUT
    note = None
    commands = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--wait" and i + 1 < len(args):
            wait = float(args[i + 1]); i += 2; continue
        if a == "--timeout" and i + 1 < len(args):
            timeout = float(args[i + 1]); i += 2; continue
        if a == "--note" and i + 1 < len(args):
            note = args[i + 1]; i += 2; continue
        if a == "--file" and i + 1 < len(args):
            for line in pathlib.Path(args[i + 1]).read_text(encoding="utf-8").splitlines():
                line = line.strip()
                if line and not line.startswith("#"):
                    commands.append(line)
            i += 2
            continue
        commands.append(a)
        i += 1

    if not commands:
        print(__doc__)
        return show_state(d)
    return send(d, commands, wait, timeout, note)


if __name__ == "__main__":
    sys.exit(main())
