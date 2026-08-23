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


# --- tools -------------------------------------------------------------------
# A tool in an inventory is not just a uuid: the slot's tool field holds a row id
# in the Tool table, and that row carries the actual item uuid. Writing a tool
# with 0xFFFFFFFF there gives an item the game cannot bind a script to.
#
# Tool.data, 27 bytes: header[0:7] = version 0x08, 0x0001, row id (4, big-endian)
#                      uuid[7:23]  = REVERSED, same as containers
#                      tail[23:27] = 0x00000001
#
# Game.uniqueIds is 18 big-endian uint32 allocators; index 8 is the next Tool id.
# It has to be bumped or the game will later hand out an id that already exists.
TOOL_LEN = 27
TOOL_ID_INDEX = 8


def tool_row(row_id, item_uuid):
    return (bytes([0x08, 0x00, 0x01]) + row_id.to_bytes(4, "big")
            + rev(item_uuid) + (1).to_bytes(4, "big"))


def read_allocators(con):
    blob = con.execute("SELECT uniqueIds FROM Game").fetchone()[0]
    return [int.from_bytes(blob[i:i + 4], "big") for i in range(0, len(blob), 4)]


def write_allocators(con, vals):
    con.execute("UPDATE Game SET uniqueIds=?",
                (b"".join(v.to_bytes(4, "big") for v in vals),))


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
    ap.add_argument("--manifest", help="json list of {uuid, count, tool}")
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

    if a.manifest:
        wanted = json.load(open(a.manifest, encoding="utf-8"))
        con = containers(a.save, writable=True) if a.apply else containers(a.save)
        rows2 = dict(list(con.execute("SELECT id, data FROM Container")))
        allocs = read_allocators(con)
        next_tool = allocs[TOOL_ID_INDEX]
        new_tools = []

        for cid, _ in holders:
            d = rows2[cid]
            _, real, slots = parse(d)
            for want in wanted:
                u, n = want["uuid"], int(want["count"])
                nm = names.get(u.lower(), u)
                tool_id = NO_TOOL
                if want.get("tool"):
                    tool_id = next_tool
                    new_tools.append((tool_id, u))
                    next_tool += 1

                idx = next((i for i, (su, _, _) in enumerate(slots)
                            if su.lower() == u.lower()), None)
                if idx is None:
                    idx = next((i for i, (su, _, q) in enumerate(slots)
                                if su == NIL and q == 0), None)
                if idx is None:
                    print(f"  !! no slot left for {nm}")
                    continue
                d = write_slot(d, idx, u, min(65535, n), tool_id)
                _, real, slots = parse(d)
                print(f"  slot {idx:2d}  x{n:<5d} {nm}"
                      + (f"  [new tool row {tool_id}]" if tool_id != NO_TOOL else ""))
            rows2[cid] = d

        if not a.apply:
            print("dry run -- re-run with --apply to write")
            con.close()
            return

        backup = a.save + ".bak2"
        if not os.path.exists(backup):
            shutil.copy2(a.save, backup)
            print(f"backed up -> {os.path.basename(backup)}")
        for tid, u in new_tools:
            con.execute("INSERT OR REPLACE INTO Tool (id, data) VALUES (?,?)",
                        (tid, tool_row(tid, u)))
        allocs[TOOL_ID_INDEX] = next_tool
        write_allocators(con, allocs)
        for cid, _ in holders:
            con.execute("UPDATE Container SET data=? WHERE id=?", (rows2[cid], cid))
        con.commit()
        con.close()
        print(f"wrote {len(holders)} container(s), {len(new_tools)} tool row(s), "
              f"next Tool id now {next_tool}")
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
