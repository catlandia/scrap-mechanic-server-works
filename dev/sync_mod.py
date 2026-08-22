"""Install mod/ into the game's local Mods folder so it appears in Custom Games.

The repo is the source of truth; the Mods folder is a build output. Run this
after editing anything under mod/, then restart the game (Scrap Mechanic reads
mod content at startup, not on world load).

The one thing NOT overwritten is BanList.json. That file is written by the
running game and is the live ban list -- clobbering it on every sync would throw
away bans the moment you edited a script.

Usage:
    python dev/sync_mod.py            # copy repo -> Mods
    python dev/sync_mod.py --status   # show what is installed, copy nothing
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


def mod_name():
    return json.loads((SRC / "description.json").read_text(encoding="utf-8-sig"))["name"]


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

    if "--status" in sys.argv:
        if not dest.exists():
            print("\nnot installed")
            return
        for f in sorted(dest.rglob("*")):
            if f.is_file():
                print(f"  {f.relative_to(dest)}  ({f.stat().st_size} bytes)")
        return

    dest.mkdir(parents=True, exist_ok=True)

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

    print(f"\n{copied} copied, {same} unchanged, {skipped} preserved")
    print("Restart Scrap Mechanic, then: Play > Custom Game > " + mod_name())


if __name__ == "__main__":
    main()
