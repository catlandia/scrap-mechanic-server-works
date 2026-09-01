"""Install mod/ into the game's local Mods folder so it appears in Custom Games.

The repo is the source of truth; the Mods folder is a build output. Run this
after editing anything under mod/, then restart the game (Scrap Mechanic reads
mod content at startup, not on world load).

The one thing NOT overwritten is BanList.json. That file is written by the
running game and is the live ban list -- clobbering it on every sync would throw
away bans the moment you edited a script.

MEASURED 2026-08-23: the game keeps a Cache/ directory INSIDE the mod folder
containing a compiled copy of every script (Cache/Raw/<name>_<hash>.rco) and of
data files it reads (Cache/Data/*.dco). On this machine every .rco was stamped
22:47:36 while every .lua had been rewritten at 23:18-23:26 -- the cache had not
been rebuilt across repeated script changes. That is the most likely explanation
for "the fixes did not apply", and --clean-cache is the lever to test it.

Usage:
    python dev/sync_mod.py                 # copy repo -> Mods, leave cache alone
    python dev/sync_mod.py --clean-cache   # also delete the game's mod cache
    python dev/sync_mod.py --status        # show what is installed, copy nothing
"""
import filecmp
import json
import os
import pathlib
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "mod"
MODS = pathlib.Path(os.path.expandvars(
    r"%APPDATA%\Axolot Games\Scrap Mechanic\User"
))

PRESERVE = {"BanList.json"}


def mod_desc():
    return json.loads((SRC / "description.json").read_text(encoding="utf-8-sig"))


def mod_name():
    return mod_desc()["name"]


# STATE THE GAME WROTE, WHICH THE REPO HAS NO COPY OF. Losing any of these is
# losing something that cannot be regenerated: the perma ids every ban is filed
# under, the ban list itself, every snapshot, and the checklist results.
GAME_STATE = ("Settings.json", "BanList.json", "Players.json", "Plots.json",
              "Event.json", "Bench.json", "Checklist.json", "Bridge.json",
              "Snapshots")


def find_by_local_id(mods_dir, local_id, exclude):
    """An installed copy of THIS mod under a different folder name.

    RENAMING THE MOD MOVES THE FOLDER. The install path is Mods/<name>, and the
    name is whatever description.json says -- so changing it makes the next sync
    build a brand new folder and quietly leave the old one behind, holding the
    ban list, the perma ids, 75 snapshots and every checklist answer.

    The mod's real identity is `localId`, which does not change when the name
    does. That is what this matches on. (The Steam Workshop identity is `fileId`
    and does not change either -- renaming a published item keeps its
    subscribers; see the changelog.)
    """
    if not local_id or not mods_dir.is_dir():
        return None
    for d in mods_dir.iterdir():
        if not d.is_dir() or d == exclude:
            continue
        f = d / "description.json"
        if not f.is_file():
            continue
        try:
            other = json.loads(f.read_text(encoding="utf-8-sig"))
        except Exception:
            continue
        if other.get("localId") == local_id:
            return d
    return None


def carry_state_over(old_dir, dest):
    """Move the game-written state from the old folder to the new one."""
    moved = []
    for name in GAME_STATE:
        src = old_dir / name
        if not src.exists():
            continue
        dst = dest / name
        if dst.exists():
            print(f"  keep  {name} already in the new folder, leaving the old copy alone")
            continue
        dest.mkdir(parents=True, exist_ok=True)
        shutil.move(str(src), str(dst))
        moved.append(name)
        print(f"  moved {name}")
    return moved


def user_dir():
    users = [d for d in MODS.glob("User_*") if d.is_dir()]
    if not users:
        sys.exit(f"no User_* directory under {MODS}")
    # newest wins if the machine has had more than one Steam account on it
    return max(users, key=lambda d: d.stat().st_mtime)


def main():
    if not SRC.is_dir():
        sys.exit(f"missing {SRC}")

    dest = user_dir() / "Mods" / mod_name()
    print(f"source  {SRC}")
    print(f"target  {dest}")

    # THE MOD HAS BEEN RENAMED. Refuse rather than silently split its state
    # across two folders -- see find_by_local_id.
    desc = mod_desc()
    old_dir = find_by_local_id(dest.parent, desc.get("localId"), dest)
    if old_dir is not None:
        at_risk = [n for n in GAME_STATE if (old_dir / n).exists()]
        print(f"\n  RENAMED: this mod is already installed as {old_dir.name!r}")
        print(f"           and description.json now says {mod_name()!r}.")
        if at_risk:
            print("  The old folder holds state the repo has no copy of:")
            for n in at_risk:
                thing = old_dir / n
                if thing.is_dir():
                    print(f"    {n}/  ({len(list(thing.glob('*')))} files)")
                else:
                    print(f"    {n}  ({thing.stat().st_size} bytes)")
        if "--rename" not in sys.argv:
            sys.exit(
                "\n  Refusing. Syncing now would build a new folder and leave that\n"
                "  behind -- the ban list, the perma ids every ban is filed under,\n"
                "  the snapshots and the checklist answers.\n\n"
                "  Re-run with --rename to move them across, or rename the folder\n"
                "  yourself first if you would rather do it by hand.")
        print("\n  --rename given: carrying the game's own state across.")
        dest.mkdir(parents=True, exist_ok=True)
        carry_state_over(old_dir, dest)
        left = [q for q in old_dir.rglob("*") if q.is_file()]
        print(f"  the old folder still has {len(left)} file(s) -- mod scripts and")
        print("  the game's Cache. Delete it once the game has loaded the new one.")

    if "--status" in sys.argv:
        if not dest.exists():
            print("\nnot installed")
            return
        for f in sorted(dest.rglob("*")):
            if f.is_file():
                print(f"  {f.relative_to(dest)}  ({f.stat().st_size} bytes)")
        return

    dest.mkdir(parents=True, exist_ok=True)

    if "--clean-cache" in sys.argv:
        cache = dest / "Cache"
        if cache.is_dir():
            n = sum(1 for f in cache.rglob("*") if f.is_file())
            shutil.rmtree(cache)
            print(f"  wiped Cache/ ({n} files) -- the game rebuilds it on next launch")
        else:
            print("  no Cache/ to wipe")

    copied = skipped = same = 0
    for f in sorted(SRC.rglob("*")):
        if not f.is_file():
            continue
        rel = f.relative_to(SRC)
        out = dest / rel
        if rel.name in PRESERVE and out.exists():
            skipped += 1
            print(f"  keep  {rel}  (live data, not overwritten)")
            continue
        out.parent.mkdir(parents=True, exist_ok=True)
        if out.exists() and filecmp.cmp(f, out, shallow=False):
            same += 1
            continue
        shutil.copy2(f, out)
        copied += 1
        print(f"  copy  {rel}")

    # PRUNE. A script deleted from the repo used to stay in the Mods folder
    # forever, and the engine compiles every .lua it finds there -- so a file
    # that no longer exists in this project was still being loaded by the game.
    # That is the same class of bug as the stale Cache: "the fixes did not
    # apply", with nothing in the log to say why.
    #
    # It bit exactly once, and visibly: Scripts/Wardrobe.lua was folded into
    # BotCharacter.lua because a character script cannot dofile mod content, and
    # the orphan sat in the installed mod afterwards.
    #
    # Only files under directories the repo also has, and never anything the
    # GAME writes -- Cache/, Snapshots/ and the live json alongside them are the
    # running world's, not build output.
    keep_dirs = {"Cache", "Snapshots", "Logs"}
    game_written = {".json"}
    pruned = 0
    for f in sorted(dest.rglob("*")):
        if not f.is_file():
            continue
        rel = f.relative_to(dest)
        if rel.parts[0] in keep_dirs or rel.name in PRESERVE:
            continue
        if (SRC / rel).exists():
            continue
        # A json at the root of the mod is state the game wrote (Settings.json,
        # Plots.json, Players.json, Event.json, Bench.json). Never ours to
        # delete, even though the repo has no copy.
        if len(rel.parts) == 1 and f.suffix.lower() in game_written:
            continue
        f.unlink()
        pruned += 1
        print(f"  prune {rel}  (deleted from the repo)")

    print(f"\n{copied} copied, {same} unchanged, {skipped} preserved, {pruned} pruned")
    if pruned:
        print("a pruned script may still have a compiled copy in Cache/ --")
        print("re-run with --clean-cache if the game still behaves as if it were there")
    print("Restart Scrap Mechanic, then: Play > Custom Game > " + mod_name())


if __name__ == "__main__":
    main()
