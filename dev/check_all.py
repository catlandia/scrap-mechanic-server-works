"""Everything that can be checked without launching the game. Run before playing.

    python dev/check_all.py           # the four checks
    python dev/check_all.py --sync    # ...then install into the Mods folder

The four together answer "is anything obviously broken?" in about ten seconds:

    check_lua.py     does every file parse
    check_uuids.py   does every uuid the mod names exist in the installed game
    test_layout.py   is the city a partition -- no overlap, no gap, no half block
    test_logic.py    do the rules decide what they are supposed to, and do the
                     panels fit on screen

What they cannot tell you is anything about bodies, tools, GUIs actually
rendering, or the network. A pass means the parts that can be reasoned about are
sound; it does not mean the mod works. TOMORROW.md lists what still has to be
tried in game.
"""
import subprocess
import sys
import pathlib

DEV = pathlib.Path(__file__).resolve().parent

CHECKS = [
    ("syntax", "check_lua.py", "every script parses"),
    ("uuids", "check_uuids.py", "every uuid resolves against the install"),
    ("layout", "test_layout.py", "the city is a partition"),
    ("logic", "test_logic.py", "the rules and the panels"),
]


def main():
    failed = []
    for name, script, what in CHECKS:
        print(f"=== {name}  --  {what}")
        r = subprocess.run([sys.executable, str(DEV / script)],
                           capture_output=True, text=True)
        tail = [ln for ln in r.stdout.splitlines() if ln.strip()]
        # the last line of each is its verdict; show failures in full
        if r.returncode != 0:
            failed.append(name)
            print("\n".join(tail[-25:]))
            if r.stderr.strip():
                print(r.stderr.strip()[-2000:])
        else:
            print("    " + (tail[-1] if tail else "(no output)"))
        print()

    if failed:
        print(f"FAILED: {', '.join(failed)}")
        return 1
    print("all four checks pass")
    if "--sync" in sys.argv:
        print()
        return subprocess.run([sys.executable, str(DEV / "sync_mod.py"),
                               "--clean-cache"]).returncode
    print("run with --sync to install into the game's Mods folder")
    return 0


if __name__ == "__main__":
    sys.exit(main())
