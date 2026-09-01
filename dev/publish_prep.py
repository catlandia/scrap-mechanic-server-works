"""Take the host's own state out of the mod folder before publishing it.

    python dev/publish_prep.py --list      what would move, and how big
    python dev/publish_prep.py             move it aside
    python dev/publish_prep.py --restore   put it back

WHY THIS EXISTS. Publishing a Custom Game uploads the WHOLE mod folder, and the
mod folder is also where this mod keeps its live state -- Settings.json,
Plots.json, Players.json, Checklist.json, Bench.json, the bridge's Cmd/Out
files, and Snapshots/. That is by design: the Lua sandbox has no filesystem
outside $CONTENT_*, so there is nowhere else to put any of it.

MEASURED before the first release: 22.8 MB across 177 files, against 1.5 MB of
actual mod. 90 of those files are the owner's own saved worlds. Publishing as-is
would have shipped every subscriber:

  - 23 MB of somebody else's cities, which then show up in their /snapshots list
  - the owner's settings instead of the defaults, including whatever switches
    happened to be on that day
  - the owner's /check results, presented as if they were the subscriber's
  - 80 leftover bridge command files

None of that is catastrophic and none of it is secret -- the mod's player
records use its own SW-0001 ids, not Steam ids, which was checked rather than
assumed. It is just wrong, and it is fifteen times the size of the thing people
are actually subscribing to.

IT MOVES, IT NEVER DELETES. The Snapshots folder is the owner's saved worlds and
the only whole-world backup this mod makes; a tool that cleaned up by deleting
those would be one mistyped flag away from being the worst bug in the project.
Everything goes to dev/modstate/ and --restore puts it back exactly.

THE ORDER MATTERS, because the game recreates this state as soon as it loads a
world:

  1. close Scrap Mechanic
  2. python dev/publish_prep.py
  3. start it, publish from the mod list WITHOUT entering a world
  4. python dev/publish_prep.py --restore
"""
import argparse
import pathlib
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MOD = ROOT / "mod"
STASH = ROOT / "dev" / "modstate"

APPDATA = pathlib.Path.home() / "AppData" / "Roaming" / "Axolot Games" / "Scrap Mechanic" / "User"


def installed():
    """The installed copy of this mod, found the same way sync_mod does."""
    for user in APPDATA.glob("User_*"):
        d = user / "Mods" / "Server Works"
        if d.is_dir():
            return d
    return None


def shipped_names():
    """Every path the repo actually contains, as a set of relative posix paths.

    The rule is not a list of things to remove -- it is "anything the repo does
    not have". A list would go stale the first time the mod writes a new kind of
    file, and going stale here means quietly shipping it.
    """
    return {p.relative_to(MOD).as_posix() for p in MOD.rglob("*") if p.is_file()}


def strays(target):
    keep = shipped_names()
    out = []
    for p in target.rglob("*"):
        if p.is_file():
            rel = p.relative_to(target).as_posix()
            if rel not in keep:
                out.append((rel, p.stat().st_size))
    return sorted(out)


def human(n):
    return f"{n / 1048576:.2f} MB" if n >= 1048576 else f"{n / 1024:.1f} KB"


def summarise(items):
    groups = {}
    for rel, size in items:
        top = rel.split("/")[0] if "/" in rel else (
            "Cmd/Out-*.json" if rel.startswith(("Cmd-", "Out-")) else rel)
        g = groups.setdefault(top, [0, 0])
        g[0] += 1
        g[1] += size
    for name, (n, size) in sorted(groups.items(), key=lambda kv: -kv[1][1]):
        print(f"   {n:4}  {human(size):>10}  {name}")
    print(f"   {len(items):4}  {human(sum(s for _, s in items)):>10}  TOTAL")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split(chr(10))[0])
    ap.add_argument("--list", action="store_true", help="show what would move")
    ap.add_argument("--restore", action="store_true", help="put it all back")
    a = ap.parse_args()

    target = installed()
    if target is None:
        sys.exit(f"the mod is not installed under {APPDATA} -- run dev/sync_mod.py first")

    if a.restore:
        if not STASH.is_dir():
            sys.exit(f"nothing stashed in {STASH}")
        moved = 0
        for p in sorted(STASH.rglob("*")):
            if p.is_file():
                dst = target / p.relative_to(STASH)
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(p), str(dst))
                moved += 1
        # Only the now-empty scaffolding, never a directory with anything in it.
        for d in sorted((p for p in STASH.rglob("*") if p.is_dir()), reverse=True):
            try:
                d.rmdir()
            except OSError:
                pass
        print(f"restored {moved} file(s) to {target}")
        return

    items = strays(target)
    if not items:
        print(f"{target}\n\nnothing to move -- the mod folder is already just the mod.")
        return

    print(f"{target}\n")
    summarise(items)

    if a.list:
        print("\n  python dev/publish_prep.py            move it aside")
        print("  python dev/publish_prep.py --restore   put it back afterwards")
        return

    print()
    moved = 0
    for rel, _ in items:
        src = target / rel
        dst = STASH / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(src), str(dst))
        moved += 1
    for d in sorted((p for p in target.rglob("*") if p.is_dir()), reverse=True):
        try:
            d.rmdir()          # only if empty
        except OSError:
            pass

    print(f"moved {moved} file(s) to {STASH}")
    print("NOTHING WAS DELETED. --restore puts every one of them back.\n")
    print("Now, with Scrap Mechanic CLOSED when you started:")
    print("  1. start the game")
    print("  2. publish from the mod list -- do NOT load a world first, or the")
    print("     game writes this state straight back into the folder")
    print("  3. python dev/publish_prep.py --restore")


if __name__ == "__main__":
    main()
