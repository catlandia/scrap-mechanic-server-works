"""Extract per-module Lua binding names from ScrapMechanic.exe.

The engine keeps each Lua wrapper's binding-name literals contiguous in the
string table, immediately AFTER that wrapper's own source-path literal
(Z:\Build\sm_steam\...\wrap_<Module>.cpp). Slicing forward from each marker
until the identifier run breaks yields that module's real binding list for THIS
build, which is why this beats any wiki.

Usage: python dev/dump_api.py [Module ...]   (no args = every module)
"""
import re, sys, pathlib

EXE = pathlib.Path(r"D:\SteamLibrary\steamapps\common\Scrap Mechanic\Release\ScrapMechanic.exe")
blob = EXE.read_bytes()

items = [m.group().decode("ascii") for m in re.finditer(rb"[\x20-\x7e]{3,}", blob)]

MARKER = re.compile(r"wrap_([A-Za-z]+)\.cpp$")
IDENT = re.compile(r"[a-zA-Z_][a-zA-Z0-9_]*")

want = set(sys.argv[1:])
for i, s in enumerate(items):
    m = MARKER.search(s)
    if not m or (want and m.group(1) not in want):
        continue
    names, j = [], i + 1
    # a handful of non-identifier assert/log literals are interleaved; tolerate
    # a short gap rather than truncating the run at the first one.
    gap = 0
    while j < len(items) and gap < 3:
        if IDENT.fullmatch(items[j]):
            names.append(items[j]); gap = 0
        else:
            gap += 1
        j += 1
    print(f"=== {m.group(1)} ({len(names)}) ===")
    print(" ".join(sorted(set(names))))
    print()
