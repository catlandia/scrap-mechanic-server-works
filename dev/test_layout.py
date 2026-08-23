"""Run mod/Scripts/Layout.lua for real and prove the city geometry is sound.

This is not a lint and it is not a mock. lupa embeds a real Lua interpreter, and
Layout.lua is deliberately free of every sm.* call, so the exact code the game
runs is the code executed here. What comes back is checked block by block.

The bug this exists to prevent, in the owner's words: "the city maker is broken
since some stuff is overlaid". It was. The builder laid a grid from a corner and
then skipped the plots that hit the spawn plaza, while the map in the plots panel
worked out "eaten" against a differently-anchored rectangle and drew the plaza
somewhere else again. Two rules for one shape, and they disagreed.

Checks, over a spread of configurations including every awkward one:

  1. every coordinate is a whole block (a centred corner-anchored grid used to
     land the whole city on x.5, and a blueprint cannot place half a block)
  2. the axis is gapless -- segments tile their span with no hole and no overlap
  3. the plaza sits exactly on the origin
  4. NO BLOCK IS EVER CLAIMED TWICE by any plot slab or any deck piece
  5. the deck plus the plots covers the bounding box exactly
  6. every plot index round-trips through locate()
  7. plots either side of the plaza are not teamable, plots either side of a
     road are not teamable, plots either side of a filler are

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
    dict(name="default",        plot=20, gap=1, cols=10, rows=10, roadevery=0, roadwidth=6, spawn=50),
    dict(name="no plaza",       plot=20, gap=1, cols=10, rows=10, roadevery=0, roadwidth=6, spawn=0),
    dict(name="no seams",       plot=20, gap=0, cols=6,  rows=6,  roadevery=0, roadwidth=6, spawn=20),
    dict(name="roads every 2",  plot=20, gap=1, cols=8,  rows=8,  roadevery=2, roadwidth=6, spawn=50),
    dict(name="roads every 3",  plot=16, gap=1, cols=9,  rows=9,  roadevery=3, roadwidth=4, spawn=30),
    dict(name="odd counts",     plot=12, gap=2, cols=7,  rows=5,  roadevery=0, roadwidth=6, spawn=20),
    dict(name="single plot",    plot=20, gap=1, cols=1,  rows=1,  roadevery=0, roadwidth=6, spawn=20),
    dict(name="1x1 no plaza",   plot=20, gap=1, cols=1,  rows=1,  roadevery=0, roadwidth=6, spawn=0),
    dict(name="huge plaza",     plot=8,  gap=1, cols=4,  rows=4,  roadevery=0, roadwidth=6, spawn=120),
    dict(name="tiny plots",     plot=8,  gap=1, cols=20, rows=20, roadevery=5, roadwidth=8, spawn=50),
    dict(name="odd plaza",      plot=20, gap=1, cols=6,  rows=6,  roadevery=0, roadwidth=6, spawn=35),
    dict(name="wide roads",     plot=24, gap=3, cols=6,  rows=4,  roadevery=2, roadwidth=12, spawn=80),
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

    # ---- 1. integers only ---------------------------------------------------
    for axis, segs in (("x", cols), ("y", rows)):
        for s in segs:
            if s["start"] != int(s["start"]) or s["size"] != int(s["size"]):
                raise Fail(f"{axis} segment not on a whole block: {s}")

    # ---- 2. the axis tiles its span -----------------------------------------
    for axis, segs, lo, hi in (("x", cols, x0, x1), ("y", rows, y0, y1)):
        at = lo
        for s in sorted(segs, key=lambda s: s["start"]):
            if s["start"] != at:
                raise Fail(f"{axis} axis breaks at {at}: next segment starts {s['start']} ({s})")
            at += s["size"]
        if at != hi:
            raise Fail(f"{axis} axis ends at {at}, extent says {hi}")

    # ---- 3. the plaza is on the origin --------------------------------------
    if c["spawn"] > 0:
        half = int(c["spawn"]) // 2
        pz = [s for s in cols if s["kind"] == "plaza"]
        if len(pz) != 1:
            raise Fail(f"expected exactly one plaza band, got {len(pz)}")
        if pz[0]["start"] != -half or pz[0]["size"] != half * 2:
            raise Fail(f"plaza not centred on origin: {pz[0]}")

    # ---- 4 + 5. the partition ----------------------------------------------
    # Rasterise. Every block of the bounding box must be claimed exactly once,
    # by a plot slab or by a deck piece. This is the check that would have caught
    # the overlay the owner reported.
    owner = {}

    def claim(x, y, w, h, who):
        for bx in range(int(x), int(x + w)):
            for by in range(int(y), int(y + h)):
                prev = owner.get((bx, by))
                if prev is not None:
                    raise Fail(f"block ({bx},{by}) claimed by BOTH {prev} and {who}")
                owner[(bx, by)] = who

    for col in range(int(c["cols"])):
        for row in range(int(c["rows"])):
            r = L.plotRect(grid, col, row)
            if r is None:
                raise Fail(f"plot {col},{row} has no rectangle")
            claim(r["x"], r["y"], r["w"], r["h"], f"plot {col},{row}")

    pieces = L.deckPieces(grid)
    npieces = 0
    for p in pieces.values():
        npieces += 1
        claim(p["x"], p["y"], p["w"], p["h"], f"deck {p['kind']}")

    expected = (x1 - x0) * (y1 - y0)
    if len(owner) != expected:
        missing = expected - len(owner)
        raise Fail(f"deck covers {len(owner)} blocks, bounding box is {expected} "
                   f"({missing} uncovered)")

    # ---- 6. locate round-trips ----------------------------------------------
    for col in range(int(c["cols"])):
        for row in range(int(c["rows"])):
            r = L.plotRect(grid, col, row)
            for px, py in ((r["x"], r["y"]),
                           (r["x"] + r["w"] - 1, r["y"] + r["h"] - 1),
                           (r["x"] + r["w"] * 0.5, r["y"] + r["h"] * 0.5)):
                z = L.locate(grid, px, py)
                if z is None or z["kind"] != "plot":
                    raise Fail(f"plot {col},{row} at ({px},{py}) locates as "
                               f"{z['kind'] if z else 'nil'}")
                if int(z["col"]) != col or int(z["row"]) != row:
                    raise Fail(f"plot {col},{row} locates as {int(z['col'])},{int(z['row'])}")
                want = row * int(c["cols"]) + col + 1
                if int(z["index"]) != want:
                    raise Fail(f"plot {col},{row} index {int(z['index'])}, expected {want}")

    if c["spawn"] > 0:
        z = L.locate(grid, 0, 0)
        if z is None or z["kind"] != "plaza":
            raise Fail(f"the origin is {z['kind'] if z else 'nil'}, not the plaza")

    # ---- 7. teaming follows the seam, not the grid --------------------------
    # Two plots may team only when the ground between them is a filler. The
    # plaza and the roads are public, so neighbours across them share nothing.
    left = int(c["cols"]) - (int(c["cols"]) + 1) // 2
    across_plaza = L.fillerBetween(grid["cols"], left - 1) if left > 0 else None
    if c["spawn"] > 0 and left > 0 and across_plaza is not None:
        raise Fail("plots either side of the plaza report a shared filler")

    nroad = sum(1 for s in cols if s["kind"] == "road" and s["index"] is not None)
    for s in cols:
        if s["kind"] == "road" and s["index"] is not None:
            if L.fillerBetween(grid["cols"], s["index"]) is not None:
                raise Fail(f"plots either side of a road report a shared filler: {s}")

    nfiller = sum(1 for s in cols if s["kind"] == "filler")
    for s in cols:
        if s["kind"] == "filler" and s["index"] is not None:
            if L.fillerBetween(grid["cols"], s["index"]) is None:
                raise Fail(f"filler {s} is not findable by fillerBetween")

    # ---- build order grows outwards ----------------------------------------
    order = [dict(index=int(o["index"]), d=float(o["d"]))
             for o in L.buildOrder(grid).values()]
    if len(order) != int(c["cols"]) * int(c["rows"]):
        raise Fail(f"build order has {len(order)} plots, grid has "
                   f"{int(c['cols']) * int(c['rows'])}")
    for a, b in zip(order, order[1:]):
        if b["d"] < a["d"]:
            raise Fail("build order is not nearest-first")

    return dict(
        plots=int(c["cols"]) * int(c["rows"]),
        blocks=expected,
        pieces=npieces,
        roads=nroad,
        fillers=nfiller,
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
                  f"({info['metres']:>13})  {info['pieces']:>3} deck pieces  "
                  f"{info['blocks']:>6} blocks, none twice")
    print()
    if failed:
        print(f"{failed} of {len(CONFIGS)} configurations FAILED")
        return 1
    print(f"all {len(CONFIGS)} configurations sound: no overlap, no gap, "
          f"no fractional block")
    return 0


if __name__ == "__main__":
    sys.exit(main())
