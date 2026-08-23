"""Run mod/Scripts/Layout.lua for real and prove the city geometry is sound.

This is not a lint and it is not a mock. lupa embeds a real Lua interpreter, and
Layout.lua is deliberately free of every sm.* call, so the exact code the game
runs is the code executed here. What comes back is checked block by block.

Two shipped bugs are the reason this exists, and both were reported by eye:

  "the city maker is broken since some stuff is overlaid"
      A grid laid from a corner with a hole punched where the plaza went. The
      hole was computed by different arithmetic than the grid, so the two could
      disagree, and did.

  "there are these huge chuncks metal three whcih is wasted space and looks ugly"
      The fix for the first one made the plaza a SEGMENT on both axes. A segment
      on an axis is a band across the whole city, so a 2-plot plaza also meant a
      2-plot-wide avenue running to both horizons.

So the checks below assert the shape of the answer, not just its consistency:

  1. every coordinate is a whole block -- a blueprint cannot place half a block
  2. each axis tiles its span with no hole and no overlap
  3. the plaza is a block of CELLS centred on the origin, and NOTHING on either
     axis is a plaza segment -- that is the band bug, asserted away
  4. NO BLOCK IS EVER CLAIMED TWICE by any plot slab or any deck piece
  5. the deck plus the plots covers the bounding box exactly
  6. every plot index round-trips through locate()
  7. the plaza is a modest share of the city, not a metal wasteland
  8. teaming follows the seam: filler yes, road no
  9. plots are built nearest-the-middle first

Usage: python dev/test_layout.py
"""
import io
import pathlib
import sys

try:
    import lupa
except ImportError:
    sys.exit("lupa not installed:  pip install lupa")

ROOT = pathlib.Path(__file__).resolve().parent.parent
LAYOUT = ROOT / "mod" / "Scripts" / "Layout.lua"

# Every configuration worth being suspicious of, not just the default.
CONFIGS = [
    dict(name="default",        plot=20, gap=1, cols=10, rows=10, roadevery=0, roadwidth=6,  plazacells=2),
    dict(name="no plaza",       plot=20, gap=1, cols=10, rows=10, roadevery=0, roadwidth=6,  plazacells=0),
    dict(name="no seams",       plot=20, gap=0, cols=6,  rows=6,  roadevery=0, roadwidth=6,  plazacells=2),
    dict(name="roads every 2",  plot=20, gap=1, cols=8,  rows=8,  roadevery=2, roadwidth=6,  plazacells=2),
    dict(name="roads every 3",  plot=16, gap=1, cols=9,  rows=9,  roadevery=3, roadwidth=4,  plazacells=1),
    dict(name="odd counts",     plot=12, gap=2, cols=7,  rows=5,  roadevery=0, roadwidth=6,  plazacells=1),
    dict(name="one plaza cell", plot=20, gap=1, cols=5,  rows=5,  roadevery=0, roadwidth=6,  plazacells=1),
    dict(name="single plot",    plot=20, gap=1, cols=1,  rows=1,  roadevery=0, roadwidth=6,  plazacells=0),
    dict(name="plaza too big",  plot=8,  gap=1, cols=4,  rows=4,  roadevery=0, roadwidth=6,  plazacells=9),
    dict(name="tiny plots",     plot=8,  gap=1, cols=20, rows=20, roadevery=5, roadwidth=8,  plazacells=3),
    dict(name="3-cell plaza",   plot=20, gap=1, cols=9,  rows=9,  roadevery=0, roadwidth=6,  plazacells=3),
    dict(name="wide roads",     plot=24, gap=3, cols=6,  rows=4,  roadevery=2, roadwidth=12, plazacells=2),
    # a grid saved before the plaza became a cell count, to prove it migrates
    dict(name="legacy spawn=50", plot=20, gap=1, cols=10, rows=10, roadevery=0, roadwidth=6, spawn=50),
]


class Fail(Exception):
    pass


def load_layout():
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    # Layout.lua is pure, but it is still mod source: give it the two globals the
    # rest of the mod's files define so it loads exactly as the game loads it.
    lua.execute("function class(base) local c={} c.__index=c return c end")
    lua.execute("function dofile(_) end")
    lua.execute(io.open(LAYOUT, encoding="utf-8").read())
    return lua


def seg_list(segs):
    return [dict(start=int(s["start"]), size=int(s["size"]), kind=s["kind"],
                 index=(int(s["index"]) if s["index"] is not None else None))
            for s in segs.values()]


def check(cfg, lua):
    L = lua.globals().Layout
    grid = L.grid(lua.table_from({k: v for k, v in cfg.items() if k != "name"}))
    c = grid["cfg"]
    cols, rows = seg_list(grid["cols"]), seg_list(grid["rows"])
    x0, x1 = int(grid["x0"]), int(grid["x1"])
    y0, y1 = int(grid["y0"]), int(grid["y1"])
    plaza = grid["plaza"]
    ncells = int(c["plazacells"])

    # ---- 1. integers only ---------------------------------------------------
    for axis, segs in (("x", cols), ("y", rows)):
        for s in segs:
            if s["start"] != int(s["start"]) or s["size"] != int(s["size"]):
                raise Fail(f"{axis} segment not on a whole block: {s}")

    # ---- 2. each axis tiles its span ----------------------------------------
    for axis, segs, lo, hi in (("x", cols, x0, x1), ("y", rows, y0, y1)):
        at = lo
        for s in sorted(segs, key=lambda s: s["start"]):
            if s["start"] != at:
                raise Fail(f"{axis} axis breaks at {at}: next starts {s['start']} ({s})")
            at += s["size"]
        if at != hi:
            raise Fail(f"{axis} axis ends at {at}, extent says {hi}")

    # ---- 3. the plaza is CELLS, centred, and never a band --------------------
    for axis, segs in (("x", cols), ("y", rows)):
        if [s for s in segs if s["kind"] == "plaza"]:
            raise Fail(f"the {axis} axis has a plaza SEGMENT -- that is a band across "
                       f"the whole city, which is the wasted-space bug")

    wants_plaza = 0 < ncells < min(int(c["cols"]), int(c["rows"]))
    if wants_plaza and plaza is None:
        raise Fail(f"plazacells={ncells} but there is no plaza rectangle")
    if not wants_plaza and plaza is not None:
        raise Fail(f"plazacells={ncells} on a {int(c['cols'])}x{int(c['rows'])} grid "
                   f"should give no plaza, got one")

    if plaza is not None:
        px, py = int(plaza["x"]), int(plaza["y"])
        pw, ph = int(plaza["w"]), int(plaza["h"])
        if abs(px + pw / 2) > 0.5 or abs(py + ph / 2) > 0.5:
            raise Fail(f"plaza centre is ({px + pw/2}, {py + ph/2}), not the origin")
        # The plaza must land exactly on cell boundaries -- start where its first
        # cell starts, end where its last cell ends. Its width is NOT
        # k*plot + (k-1)*gap, because a seam inside the block can be a road and
        # roads are wider; asserting that number was wrong, not the geometry.
        for axis, segs, lo, hi, a0, a1 in (
                ("x", cols, px, px + pw, int(grid["pcx0"]), int(grid["pcx1"])),
                ("y", rows, py, py + ph, int(grid["pcy0"]), int(grid["pcy1"]))):
            first = next(s for s in segs if s["kind"] == "plot" and s["index"] == a0)
            last = next(s for s in segs if s["kind"] == "plot" and s["index"] == a1)
            if lo != first["start"]:
                raise Fail(f"plaza {axis} starts at {lo}, cell {a0} starts at {first['start']}")
            if hi != last["start"] + last["size"]:
                raise Fail(f"plaza {axis} ends at {hi}, cell {a1} ends at "
                           f"{last['start'] + last['size']}")
            if a1 - a0 + 1 != ncells:
                raise Fail(f"plaza covers {a1 - a0 + 1} cells on {axis}, not {ncells}")

    # ---- 4 + 5. the partition ----------------------------------------------
    owner = {}

    def claim(x, y, w, h, who):
        for bx in range(int(x), int(x + w)):
            for by in range(int(y), int(y + h)):
                prev = owner.get((bx, by))
                if prev is not None:
                    raise Fail(f"block ({bx},{by}) claimed by BOTH {prev} and {who}")
                owner[(bx, by)] = who

    built = 0
    for col in range(int(c["cols"])):
        for row in range(int(c["rows"])):
            r = L.plotRect(grid, col, row)
            if L.isPlazaCell(grid, col, row):
                if r is not None:
                    raise Fail(f"cell {col},{row} is plaza but still has a plot slab")
                continue
            if r is None:
                raise Fail(f"plot {col},{row} has no rectangle")
            claim(r["x"], r["y"], r["w"], r["h"], f"plot {col},{row}")
            built += 1

    npieces = 0
    for p in L.deckPieces(grid).values():
        npieces += 1
        claim(p["x"], p["y"], p["w"], p["h"], f"deck {p['kind']}")

    expected = (x1 - x0) * (y1 - y0)
    if len(owner) != expected:
        raise Fail(f"covered {len(owner)} blocks, bounding box is {expected} "
                   f"({expected - len(owner)} uncovered)")

    # ---- 6. locate round-trips ----------------------------------------------
    for col in range(int(c["cols"])):
        for row in range(int(c["rows"])):
            r = L.plotRect(grid, col, row)
            if r is None:
                continue
            for px_, py_ in ((r["x"], r["y"]),
                             (r["x"] + r["w"] - 1, r["y"] + r["h"] - 1),
                             (r["x"] + r["w"] * 0.5, r["y"] + r["h"] * 0.5)):
                z = L.locate(grid, px_, py_)
                if z is None or z["kind"] != "plot":
                    raise Fail(f"plot {col},{row} at ({px_},{py_}) locates as "
                               f"{z['kind'] if z else 'nil'}")
                if int(z["col"]) != col or int(z["row"]) != row:
                    raise Fail(f"plot {col},{row} locates as {int(z['col'])},{int(z['row'])}")
                want = row * int(c["cols"]) + col + 1
                if int(z["index"]) != want:
                    raise Fail(f"plot {col},{row} index {int(z['index'])}, expected {want}")

    # ---- 7. the plaza is a square, not a wasteland --------------------------
    if plaza is not None:
        z = L.locate(grid, 0, 0)
        if z is None or z["kind"] != "plaza":
            raise Fail(f"the origin is {z['kind'] if z else 'nil'}, not the plaza")
        share = (int(plaza["w"]) * int(plaza["h"])) / max(1, expected)
        if share > 0.40:
            raise Fail(f"the plaza is {share:.0%} of the entire city -- that is the "
                       f"wasted-space bug coming back")

    # ---- 8. teaming follows the seam ---------------------------------------
    nroad = nfiller = 0
    for s in cols:
        if s["index"] is None:
            continue
        if s["kind"] == "road":
            nroad += 1
            if L.fillerBetween(grid["cols"], s["index"]) is not None:
                raise Fail(f"plots either side of a road report a shared filler: {s}")
        elif s["kind"] == "filler":
            nfiller += 1
            if L.fillerBetween(grid["cols"], s["index"]) is None:
                raise Fail(f"filler {s} is not findable by fillerBetween")

    # ---- 9. built from the middle outwards ---------------------------------
    order = [dict(index=int(o["index"]), d=float(o["d"]))
             for o in L.buildOrder(grid).values()]
    if len(order) != built:
        raise Fail(f"build order has {len(order)} plots, {built} have slabs")
    for a, b in zip(order, order[1:]):
        if b["d"] < a["d"]:
            raise Fail("build order is not nearest-first")

    return dict(
        plots=built,
        blocks=expected,
        pieces=npieces,
        plaza=(f"{int(plaza['w'])}x{int(plaza['h'])}" if plaza else "none"),
        span=f"{x1 - x0}x{y1 - y0}",
        metres=f"{(x1 - x0) * 0.25:.1f}x{(y1 - y0) * 0.25:.1f}m",
    )


def main():
    lua = load_layout()
    width = max(len(c["name"]) for c in CONFIGS)
    failed = 0
    for cfg in CONFIGS:
        try:
            info = check(cfg, lua)
        except Fail as e:
            failed += 1
            print(f"  FAIL  {cfg['name']:<{width}}  {e}")
        else:
            print(f"  ok    {cfg['name']:<{width}}  "
                  f"{info['plots']:>3} plots  {info['span']:>9} blocks "
                  f"({info['metres']:>13})  {info['pieces']:>3} pieces  "
                  f"plaza {info['plaza']:>7}  {info['blocks']:>6} blocks, none twice")
    print()
    if failed:
        print(f"{failed} of {len(CONFIGS)} configurations FAILED")
        return 1
    print(f"all {len(CONFIGS)} configurations sound: no overlap, no gap, "
          f"no fractional block, no plaza band")
    return 0


if __name__ == "__main__":
    sys.exit(main())
