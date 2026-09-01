"""Put Scrap Mechanic's LocalPrefabs folder back.

    python dev/restore_prefabs.py            put them back
    python dev/restore_prefabs.py --park     take them away again

WHY THEY WERE EVER MOVED. The Mod Tool cannot publish anything on this machine:
ContentCompiler.exe crashes with an access violation two seconds into

    -----------------------Generating Prefab Icons-----------------------
    FrameRenderTargets::createOrResize Main from: 0x0 to: 1280x720
    ERROR: BugSplatUtil.cpp:22 Bugsplat!

Ruled out by measurement, in this order: memory (crashed with 6.4 GB free),
this mod (a different, already-published Custom Game crashes identically, four
times), the GPU driver (dated months before the last working run), stale cache
bundles (rebuilt to byte-identical sizes), and corrupt game files (Steam
reacquired 28 and it still crashed).

What is left is the 2026-08-03 game update, which is the only thing that changed
between the tool working in June and failing now. ContentCompiler.exe ships with
the GAME, so there is no version of it to roll back to independently.

That step renders every base-game prefab to produce icons -- 1,635 of them, and
1,762 icons already exist on disk. None of it has anything to do with a Custom
Game that ships no prefabs of its own. So the workaround is to give it nothing
to render: move the folder out of the game tree, publish, move it back.

MOVED, NEVER DELETED, and parked OUTSIDE the Scrap Mechanic folder so nothing
scans it. If this script is ever lost, Steam's "Verify integrity of game files"
restores the folder too -- there is no way to end up permanently without it.

PUT THEM BACK WHEN YOU ARE DONE. Survival worlds are built out of these; the
game will not generate terrain properly without them.
"""
import argparse
import pathlib
import shutil
import sys

GAME = pathlib.Path(r"D:\SteamLibrary\steamapps\common\Scrap Mechanic")

# EVERY folder the icon generator renders from. Starving one phase just moves
# the crash to the next: parking LocalPrefabs got past "Generating Prefab
# Icons" and straight into "Generating Blueprint Icons", which dies on the
# identical line. So this is a list, and it grows as phases are discovered.
PARKED = [
    ("Survival/LocalPrefabs", "_SW-parked-LocalPrefabs"),
    ("Survival/LocalBlueprints", "_SW-parked/Survival_LocalBlueprints"),
    ("ChallengeData/Blueprints", "_SW-parked/ChallengeData_Blueprints"),
]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split(chr(10))[0])
    ap.add_argument("--park", action="store_true",
                    help="move them OUT again (for another publish attempt)")
    a = ap.parse_args()

    moved = 0
    for rel, parked in PARKED:
        live = GAME / rel
        park = GAME.parent / parked
        if a.park:
            if live.is_dir() and not park.is_dir():
                park.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(live), str(park))
                print(f"  parked   {rel}")
                moved += 1
        else:
            if park.is_dir() and not live.is_dir():
                live.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(park), str(live))
                print(f"  restored {rel}")
                moved += 1
            elif live.is_dir():
                print(f"  already in place: {rel}")

    if a.park:
        print(f"{moved} folder(s) parked. PUT THEM BACK when you are done:")
        print("  python dev/restore_prefabs.py")
    else:
        print(f"{moved} folder(s) restored.")
        missing = [rel for rel, _ in PARKED if not (GAME / rel).is_dir()]
        if missing:
            print("STILL MISSING -- run Steam's Verify integrity of game files:")
            for rel in missing:
                print("  " + rel)


if __name__ == "__main__":
    main()
