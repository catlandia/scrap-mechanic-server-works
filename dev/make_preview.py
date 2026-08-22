"""Render mod/preview.jpg with the current version stamped on it.

The mod's version has to live in its own file, NOT in description.json: the
"version" field there is the game *content* version and must stay 1 for a Custom
Game on this build (see CLAUDE.md). Bumping it to mark a mod release makes the
game show "one or more of the selected mods have not been updated".

So VERSION holds the mod revision, and it appears where a host can actually see
it -- on the thumbnail in the Custom Game list, so you can tell at a glance which
build a machine is running without opening a single file.

Usage:
    python dev/make_preview.py            # re-render at the current version
    python dev/make_preview.py --bump     # increment VERSION, then render
    python dev/make_preview.py --set 7    # set an explicit version, then render
"""
import pathlib
import sys

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    sys.exit("Pillow not installed:  pip install pillow")

ROOT = pathlib.Path(__file__).resolve().parent.parent
VERSION_FILE = ROOT / "VERSION"
OUT = ROOT / "mod" / "preview.jpg"

# Steam Workshop shows previews at 16:9; every workshop item checked was 1920x1080.
SIZE = (1920, 1080)

BG = (18, 20, 26)
ACCENT = (255, 138, 47)      # Scrap Mechanic orange
TEXT = (238, 240, 245)
MUTED = (128, 134, 148)

TITLE = "SERVER WORKS"
TAGLINE = "anti-grief custom game for building events"


def load_font(size, bold=True):
    candidates = [
        r"C:\Windows\Fonts\segoeuib.ttf" if bold else r"C:\Windows\Fonts\segoeui.ttf",
        r"C:\Windows\Fonts\arialbd.ttf" if bold else r"C:\Windows\Fonts\arial.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    ]
    for path in candidates:
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


def centred(draw, text, font, y, fill):
    left, top, right, bottom = draw.textbbox((0, 0), text, font=font)
    draw.text(((SIZE[0] - (right - left)) / 2 - left, y), text, font=font, fill=fill)
    return bottom - top


def main():
    version = read_version()
    if "--bump" in sys.argv:
        version += 1
    elif "--set" in sys.argv:
        version = int(sys.argv[sys.argv.index("--set") + 1])
    VERSION_FILE.write_text(f"{version}\n", encoding="utf-8")

    img = Image.new("RGB", SIZE, BG)
    d = ImageDraw.Draw(img)

    # A faint block grid, because the mod is about plots on a grid.
    step = 60
    for x in range(0, SIZE[0], step):
        d.line([(x, 0), (x, SIZE[1])], fill=(26, 29, 37), width=1)
    for y in range(0, SIZE[1], step):
        d.line([(0, y), (SIZE[0], y)], fill=(26, 29, 37), width=1)

    centred(d, TITLE, load_font(140), 250, TEXT)
    centred(d, TAGLINE, load_font(50, bold=False), 425, MUTED)

    # Version badge, centred.
    tag = f"V{version}"
    font = load_font(200)
    left, top, right, bottom = d.textbbox((0, 0), tag, font=font)
    w, h = right - left, bottom - top
    x = (SIZE[0] - w) / 2 - left
    y = 570 - top
    padx, pady = 60, 34
    d.rounded_rectangle(
        [x - padx, y + top - pady, x + w + padx, y + bottom + pady],
        radius=30, fill=ACCENT,
    )
    d.text((x, y), tag, font=font, fill=BG)

    # A row of plots along the bottom, one claimed. Reads as the grid the mod is
    # about without crowding the type above it.
    cells, cell, gap = 9, 96, 18
    total = cells * cell + (cells - 1) * gap
    ox = (SIZE[0] - total) / 2
    oy = 880
    for i in range(cells):
        box = [ox + i * (cell + gap), oy, ox + i * (cell + gap) + cell, oy + cell]
        if i == 4:
            d.rounded_rectangle(box, radius=8, fill=ACCENT)
        else:
            d.rounded_rectangle(box, radius=8, outline=(58, 63, 76), width=3)

    img.save(OUT, "JPEG", quality=92)
    print(f"VERSION = {version}")
    print(f"wrote {OUT}  ({OUT.stat().st_size // 1024} KB, {SIZE[0]}x{SIZE[1]})")


if __name__ == "__main__":
    main()
