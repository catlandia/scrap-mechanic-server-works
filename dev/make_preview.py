"""Render mod/preview.jpg -- an isometric picture of the city this mod builds.

THE PICTURE IS THE REAL CITY, not an illustration of one. It is drawn from
`Layout.deckPieces` and `Layout.plotRect` -- the same pure functions the builder
uses to place every block in game -- in the colours out of `Palette.lua`, which
were read out of the paint tool's own palette in the executable.

So the preview cannot drift from the product: change the layout and the picture
changes with it. It is also the only way to have a picture at all before the mod
has been played enough to screenshot. **A real in-game screenshot beats this the
day one exists** -- pass one with --photo and it is used as the background
instead.

The mod's version is stamped on it because that is where a host can actually see
which build a machine is running, without opening a file. VERSION holds it --
NOT description.json, whose "version" is the game content version and must stay
1 for a Custom Game on this build.

Usage:
    python dev/make_preview.py                 re-render at the current version
    python dev/make_preview.py --bump          increment VERSION, then render
    python dev/make_preview.py --set 7         set an explicit version
    python dev/make_preview.py --photo shot.png  use a screenshot as the backdrop
"""
import io
import math
import pathlib
import sys

try:
    from PIL import Image, ImageDraw, ImageFont, ImageFilter
except ImportError:
    sys.exit("Pillow not installed:  pip install pillow")

try:
    import lupa
except ImportError:
    lupa = None

ROOT = pathlib.Path(__file__).resolve().parent.parent
VERSION_FILE = ROOT / "VERSION"
SCRIPTS = ROOT / "mod" / "Scripts"
OUT = ROOT / "mod" / "preview.jpg"

# Steam Workshop shows previews at 16:9; every workshop item checked was 1920x1080.
SIZE = (1920, 1080)

BG = (13, 15, 20)
ACCENT = (255, 138, 47)          # Scrap Mechanic orange
TEXT = (240, 242, 247)
MUTED = (132, 138, 152)
WARN = (255, 196, 92)

TITLE = "SERVER WORKS"
TAGLINE = "a custom game for running building events"
POINTS = ["CLAIMABLE PLOTS", "EVENT CLOCK", "ANTI-GRIEF FREEZE", "PERMANENT BANS"]


# --------------------------------------------------------------- the city ---

def city_pieces():
    """(pieces, plots, bounds) straight out of the mod's own Layout.lua.

    Returns None if lupa is missing, so the picture still renders -- just
    without the thing that makes it worth having.
    """
    if lupa is None:
        return None
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua.execute("function class(base) local c={} c.__index=c return c end")
    lua.execute("function dofile(_) end")
    lua.execute(io.open(SCRIPTS / "Layout.lua", encoding="utf-8").read())
    L = lua.globals().Layout

    # The default city: 96 plots of 20 blocks, a 2-cell plaza at spawn. What
    # /plotbuild makes if you press it and change nothing.
    grid = L.grid(lua.table_from(
        {"plot": 20, "gap": 1, "cols": 10, "rows": 10,
         "roadevery": 0, "roadwidth": 6, "plazacells": 2}))

    pieces = [(p["x"], p["y"], p["w"], p["h"], str(p["kind"]))
              for p in L.deckPieces(grid).values()]
    plots = []
    # grid.cols is the SEGMENT list (plot/filler/road runs), not a count. The
    # count is on the config it was built from.
    cfg = grid["cfg"]
    for col in range(1, int(cfg["cols"]) + 1):
        for row in range(1, int(cfg["rows"]) + 1):
            r = L.plotRect(grid, col, row)
            if r is not None:
                plots.append((r["x"], r["y"], r["w"], r["h"]))
    xs = [p[0] for p in pieces] + [p[0] + p[2] for p in pieces]
    ys = [p[1] for p in pieces] + [p[1] + p[3] for p in pieces]
    return pieces, plots, (min(xs), min(ys), max(xs), max(ys))


# The city's own materials, from Palette.lua's defaults. Kept as literals rather
# than read back, because these are the picture's palette -- if somebody restyles
# their city the preview should still look like the mod, not like their world.
COL = {
    "plaza":  (86, 92, 104),
    "road":   (30, 33, 40),
    "corner": (30, 33, 40),
    "filler": (44, 48, 58),
    "plot":   (28, 92, 62),          # deepgreen carpet
    "border": (96, 104, 118),        # darkgrey metal2 frame
}
SIDE = 0.55                          # how much darker an extruded side face is


def iso(x, y, ox, oy, s):
    """Block coordinates -> screen. A 2:1 diamond, the classic city view."""
    return (ox + (x - y) * s, oy + (x + y) * s * 0.5)


def draw_city(img, cx, cy, target_w, alpha):
    """Draw the whole city, scaled to span `target_w` pixels.

    THE SCALE IS FITTED, NOT CHOSEN. A hand-picked number was wrong the moment
    the default grid changed size -- the first render used 15.5 and produced a
    close-up of four plots that read as wallpaper rather than as a city. The
    point of the picture is that it is 96 plots around a plaza, which only comes
    across if all 96 are in frame.
    """
    data = city_pieces()
    if data is None:
        return False
    pieces, plots, (x0, y0, x1, y1) = data
    mx, my = (x0 + x1) / 2.0, (y0 + y1) / 2.0
    # An iso diamond is (w + h) * s across, so solve for s.
    scale = target_w / float((x1 - x0) + (y1 - y0))

    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)

    def tile(bx, by, bw, bh, top, lift):
        """One flat slab, drawn as a top face plus two side faces."""
        pts = [iso(bx - mx, by - my, cx, cy, scale),
               iso(bx + bw - mx, by - my, cx, cy, scale),
               iso(bx + bw - mx, by + bh - my, cx, cy, scale),
               iso(bx - mx, by + bh - my, cx, cy, scale)]
        up = [(px, py - lift) for px, py in pts]
        dark = tuple(int(c * SIDE) for c in top)
        # south and east faces, so the light reads as coming from the north-west
        d.polygon([up[3], up[2], pts[2], pts[3]], fill=dark + (alpha,))
        d.polygon([up[1], up[2], pts[2], pts[1]], fill=dark + (alpha,))
        d.polygon(up, fill=top + (alpha,))

    # Ground first, then the plots on top of it -- same order the builder uses.
    # Extrusion scales with the tiles, or the "height" is a hairline at one
    # size and a cliff at another.
    deck = max(2.0, scale * 1.6)

    # ONE SLAB FOR THE WHOLE DECK, and the individual pieces laid FLAT on it.
    #
    # Extruding each deck piece separately drew a side face on every one -- and
    # a filler seam is one block wide, so seen edge-on its side face is a long
    # thin spike. The first render sprouted a row of them off the far corner
    # like antennae. The city really is one flat plate with the plots standing
    # on it, so drawing it that way is both truer and tidier.
    tile(x0, y0, x1 - x0, y1 - y0, COL["road"], deck)
    for bx, by, bw, bh, kind in pieces:
        tile(bx, by, bw, bh, COL.get(kind, COL["filler"]), 0)
    for bx, by, bw, bh in plots:
        tile(bx, by, bw, bh, COL["border"], deck * 1.5)
        inset = 1
        tile(bx + inset, by + inset, bw - inset * 2, bh - inset * 2,
             COL["plot"], deck * 1.9)

    img.alpha_composite(layer)
    return True


# -------------------------------------------------------------- the plate ---

def load_font(size, bold=True):
    for path in (r"C:\Windows\Fonts\segoeuib.ttf" if bold else r"C:\Windows\Fonts\segoeui.ttf",
                 r"C:\Windows\Fonts\arialbd.ttf" if bold else r"C:\Windows\Fonts\arial.ttf",
                 "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()


def read_version():
    if VERSION_FILE.exists():
        raw = VERSION_FILE.read_text(encoding="utf-8").strip()
        if raw.isdigit():
            return int(raw)
    return 1


def scrim(img, width):
    """Darken the left side so the title is readable over the city.

    A gradient rather than a box: a hard edge across a picture reads as a bug.
    """
    g = Image.new("L", (width, 1))
    for x in range(width):
        t = x / max(1, width - 1)
        g.putpixel((x, 0), int(238 * (1.0 - t) ** 1.6))
    g = g.resize((width, img.size[1]))
    black = Image.new("RGBA", (width, img.size[1]), BG + (255,))
    black.putalpha(g)
    img.alpha_composite(black, (0, 0))


def main():
    version = read_version()
    if "--bump" in sys.argv:
        version += 1
        VERSION_FILE.write_text(f"{version}\n", encoding="utf-8")
    if "--set" in sys.argv:
        version = int(sys.argv[sys.argv.index("--set") + 1])
        VERSION_FILE.write_text(f"{version}\n", encoding="utf-8")

    img = Image.new("RGBA", SIZE, BG + (255,))

    photo = None
    if "--photo" in sys.argv:
        photo = pathlib.Path(sys.argv[sys.argv.index("--photo") + 1])

    if photo and photo.is_file():
        # A REAL SCREENSHOT BEATS THE RENDER. Cover-fit, then dim it so the
        # text stays legible at thumbnail size.
        shot = Image.open(photo).convert("RGBA")
        sc = max(SIZE[0] / shot.width, SIZE[1] / shot.height)
        shot = shot.resize((int(shot.width * sc) + 1, int(shot.height * sc) + 1),
                           Image.LANCZOS)
        img.alpha_composite(shot, (-(shot.width - SIZE[0]) // 2,
                                   -(shot.height - SIZE[1]) // 2))
        img.alpha_composite(Image.new("RGBA", SIZE, BG + (90,)))
        drew = True
        print(f"  backdrop: {photo.name}")
    else:
        drew = draw_city(img, SIZE[0] * 0.70, SIZE[1] * 0.50,
                         SIZE[0] * 0.74, 255)
        print("  backdrop: " + ("the real city, from Layout.lua"
                                if drew else "flat (lupa missing)"))

    scrim(img, int(SIZE[0] * 0.62))

    d = ImageDraw.Draw(img)
    f_title = load_font(132)
    f_tag = load_font(40, bold=False)
    f_point = load_font(27)
    f_badge = load_font(46)
    f_wip = load_font(30)

    x = 96
    d.text((x, 300), TITLE, font=f_title, fill=TEXT)
    d.rectangle([x, 452, x + 190, 458], fill=ACCENT)
    d.text((x, 496), TAGLINE, font=f_tag, fill=MUTED)

    y = 606
    for p in POINTS:
        d.rectangle([x, y + 9, x + 10, y + 19], fill=ACCENT)
        d.text((x + 28, y), p, font=f_point, fill=(206, 211, 222))
        y += 46

    # The version badge, which is the whole reason this file is generated.
    bw, bh = 172, 74
    by = 826
    d.rounded_rectangle([x, by, x + bw, by + bh], 10, fill=ACCENT)
    label = f"V{version}"
    tb = d.textbbox((0, 0), label, font=f_badge)
    d.text((x + (bw - (tb[2] - tb[0])) / 2 - tb[0],
            by + (bh - (tb[3] - tb[1])) / 2 - tb[1]), label, font=f_badge,
           fill=(26, 18, 10))

    d.text((x + bw + 26, by + 6), "WORK IN PROGRESS", font=f_wip, fill=WARN)
    d.text((x + bw + 26, by + 42), "expect rough edges", font=f_wip, fill=MUTED)

    img.convert("RGB").save(OUT, "JPEG", quality=92, optimize=True)
    print(f"VERSION = {version}")
    print(f"wrote {OUT}  ({OUT.stat().st_size // 1024} KB, {SIZE[0]}x{SIZE[1]})")


if __name__ == "__main__":
    main()
