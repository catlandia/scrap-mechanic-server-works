"""Read and edit player inventories in a Scrap Mechanic save.

Reverse-engineered from Save/Survival/Chapter 2.db, 2026-08-23. There is no
documentation for this format; everything below was derived by locating known
item uuids inside the blobs and measuring the stride between them.

FORMAT -- Container.data

  header, 11 bytes
    [0]      version (4 observed)
    [1:3]    0x0001, unknown
    [3:7]    container id, big-endian, matches the row's id column
    [7:9]    slot count, big-endian
    [9:11]   0xFFFF, unknown

  then `slot count` slots of 22 bytes each
    [0:16]   item uuid, stored with ALL SIXTEEN BYTES REVERSED
    [16:20]  tool instance id -- an id in the Tool table, or 0xFFFFFFFF for
             anything that is not a tool
    [20:22]  quantity

An empty slot is a nil uuid with quantity 0. The tool-instance field stays
0xFFFFFFFF in an empty slot, not zero.

The reversed uuid is the part worth remembering: neither the standard byte order
nor the usual GUID little-endian mixed-endian form matches. Take 16 bytes out of
the file, reverse them, and you get the uuid the game's own scripts use.

Usage:
    python dev/save_items.py "<save.db>" --list
    python dev/save_items.py "<save.db>" --find <uuid>
    python dev/save_items.py "<save.db>" --give <uuid> --count N --to-holders-of <uuid>
                                          [--apply]

Nothing is written without --apply, and --apply always makes a .bak first.
"""
import argparse
import json
import os
import shutil
import sqlite3
import sys
import uuid as _uuid

HEADER = 11
SLOT = 22
NO_TOOL = 0xFFFFFFFF
NIL = "00000000-0000-0000-0000-000000000000"

LANG = (r"D:\SteamLibrary\steamapps\common\Scrap Mechanic"
        r"\Survival\Gui\Language\English\inventoryDescriptions.json")


def item_names():
    try:
        text = open(LANG, encoding="utf-8-sig").read()
        text = text[text.index("{"):]          # file starts with a // comment
        return {k.lower(): v.get("title", "?") for k, v in json.loads(text).items()}
    except Exception:
        return {}


def rev(u):
    return _uuid.UUID(str(u)).bytes[::-1]


def parse(data):
    """-> (version, container_id, [ (uuid, tool_instance, quantity) ])"""
    if len(data) < HEADER:
        return None
    version = data[0]
    cid = int.from_bytes(data[3:7], "big")
    count = int.from_bytes(data[7:9], "big")
    slots = []
    for i in range(count):
        o = HEADER + i * SLOT
        if o + SLOT > len(data):
            break
        slots.append((
            str(_uuid.UUID(bytes=data[o:o + 16][::-1])),
            int.from_bytes(data[o + 16:o + 20], "big"),
            int.from_bytes(data[o + 20:o + 22], "big"),
        ))
    return version, cid, slots


def write_slot(data, index, item_uuid, quantity, tool_instance=NO_TOOL):
    o = HEADER + index * SLOT
    out = bytearray(data)
    out[o:o + 16] = rev(item_uuid)
    out[o + 16:o + 20] = tool_instance.to_bytes(4, "big")
    out[o + 20:o + 22] = quantity.to_bytes(2, "big")
    return bytes(out)


def containers(db, writable=False):
    mode = "" if writable else "?mode=ro"
    con = sqlite3.connect(f"file:{db}{mode}", uri=True)
    return con


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("save")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--find")
    ap.add_argument("--give")
    ap.add_argument("--count", type=int, default=1)
    ap.add_argument("--to-holders-of")
    ap.add_argument("--apply", action="store_true")
    a = ap.parse_args()

    if not os.path.isfile(a.save):
        sys.exit(f"no such save: {a.save}")
    names = item_names()

    con = containers(a.save)
    rows = list(con.execute("SELECT id, data FROM Container"))
    con.close()
    print(f"{os.path.basename(a.save)}  --  {len(rows)} containers")

    if a.find or a.to_holders_of:
        needle = rev(a.find or a.to_holders_of)
        holders = [(cid, d) for cid, d in rows if needle in d]
        label = names.get((a.find or a.to_holders_of).lower(), "?")
        print(f"\ncontainers holding {label}: {[c for c, _ in holders]}")
        if a.find:
            return
    else:
        holders = rows

    if a.list:
        for cid, d in rows[:5]:
            p = parse(d)
            if not p:
                continue
            _, real, slots = p
            used = sum(1 for u, _, q in slots if u != NIL)
            print(f"\n  container {real}: {len(slots)} slots, {used} used")
            for i, (u, tool, q) in enumerate(slots):
                if u != NIL:
                    print(f"    {i:2d} x{q:<4d} {names.get(u.lower(), u)}"
                          + (f"  [tool #{tool}]" if tool != NO_TOOL else ""))
        return

    if not a.give:
        return

    give_name = names.get(a.give.lower(), a.give)
    print(f"\ngiving {a.count} x {give_name} to {len(holders)} container(s)")

    edits = []
    for cid, d in holders:
        p = parse(d)
        if not p:
            print(f"  container {cid}: unparseable, skipped")
            continue
        _, real, slots = p

        existing = next((i for i, (u, _, q) in enumerate(slots)
                         if u.lower() == a.give.lower()), None)
        if existing is not None:
            newq = min(65535, slots[existing][2] + a.count)
            print(f"  container {real}: slot {existing} already has "
                  f"{slots[existing][2]} -> {newq}")
            edits.append((cid, write_slot(d, existing, a.give, newq)))
            continue

        empty = next((i for i, (u, _, q) in enumerate(slots)
                      if u == NIL and q == 0), None)
        if empty is None:
            print(f"  container {real}: no empty slot, skipped")
            continue
        print(f"  container {real}: slot {empty} <- {a.count} x {give_name}")
        edits.append((cid, write_slot(d, empty, a.give, a.count)))

    if not edits:
        print("\nnothing to do")
        return

    if not a.apply:
        print(f"\ndry run -- {len(edits)} container(s) would change. "
              f"Re-run with --apply to write.")
        return

    backup = a.save + ".bak"
    if not os.path.exists(backup):
        shutil.copy2(a.save, backup)
        print(f"\nbacked up -> {os.path.basename(backup)}")
    else:
        print(f"\nbackup already exists, keeping it: {os.path.basename(backup)}")

    con = containers(a.save, writable=True)
    for cid, data in edits:
        con.execute("UPDATE Container SET data=? WHERE id=?", (data, cid))
    con.commit()
    con.close()
    print(f"wrote {len(edits)} container(s)")


if __name__ == "__main__":
    main()
