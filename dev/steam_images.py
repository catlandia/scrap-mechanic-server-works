"""Turn Scrap Mechanic screenshots into Workshop gallery images.

You take the screenshots; this makes them uploadable. Every output is a lossless
1920x1080 PNG in dev/steam/, numbered so the upload order is the filename order.

    python dev/steam_images.py --list          newest screenshots, numbered
    python dev/steam_images.py --add 3         add screenshot 3 from that list
    python dev/steam_images.py --add 3 --name plots --why "claiming a plot"
    python dev/steam_images.py --new           add everything taken since the
                                               last time this ran
    python dev/steam_images.py                 rebuild what is already picked
    python dev/steam_images.py --drop 02       remove one again

THE HOTBAR IS CUT AUTOMATICALLY and the HUD is not. A Scrap Mechanic capture has
the hotbar across the bottom, which is the game's furniture and says nothing
about this mod -- but the roster count top-left and the event clock top-right ARE
the mod, and cutting them would throw away the only proof in the picture that
anything is running. So the default crop takes the bottom off and nothing else.
--full keeps the hotbar for a shot where it matters.

PNG rather than JPEG: half of these end up being UI panels and hard-edged
striped roads, which is what JPEG smears, and a gallery image is looked at full
size. The mod's own preview stays a JPEG -- Steam caps THAT one at 1 MB and the
same picture as a PNG does not fit under it.
"""
import argparse
import datetime
import json
import pathlib
import sys

try:
    from PIL import Image
except ImportError:
    sys.exit("Pillow not installed:  pip install pillow")

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "dev" / "steam"
PICKED = OUT / "picked.json"          # what has been chosen, and why
SIZE = (1920, 1080)

STEAM = pathlib.Path(r"C:\Program Files (x86)\Steam\userdata")
APPID = "387990"

# Fraction of the capture height the hotbar occupies. MEASURED on this owner's
# 3440x1440 captures: the hotbar tops out around y=1245, so a shade under 14%.
HOTBAR = 0.135


def shots_dir():
    best = None
    for d in STEAM.glob("*/760/remote/" + APPID + "/screenshots"):
        if d.is_dir() and (best is None
                           or len(list(d.glob("*.jpg"))) > len(list(best.glob("*.jpg")))):
            best = d
    return best


def shots(src):
    return sorted(src.glob("*.jpg"), key=lambda p: p.stat().st_mtime, reverse=True)


def load():
    if PICKED.is_file():
        try:
            return json.loads(PICKED.read_text(encoding="utf-8"))
        except Exception:
            pass
    return {"images": []}


def save(state):
    OUT.mkdir(parents=True, exist_ok=True)
    PICKED.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")


def render(src_file, dst, full=False):
    im = Image.open(src_file).convert("RGB")
    if not full:
        im = im.crop((0, 0, im.width, int(im.height * (1.0 - HOTBAR))))
    # Cover-fit to 16:9, centred.
    sc = max(SIZE[0] / im.width, SIZE[1] / im.height)
    im = im.resize((round(im.width * sc), round(im.height * sc)), Image.LANCZOS)
    left, top = (im.width - SIZE[0]) // 2, (im.height - SIZE[1]) // 2
    im = im.crop((left, top, left + SIZE[0], top + SIZE[1]))
    im.save(dst, "PNG", optimize=True)
    return dst.stat().st_size // 1024


def build(state, src):
    OUT.mkdir(parents=True, exist_ok=True)
    for old in OUT.glob("*.png"):
        old.unlink()
    total = 0
    for i, entry in enumerate(state["images"], start=1):
        f = src / entry["file"]
        if not f.is_file():
            print(f"  SKIP {entry['file']} -- not in the screenshots folder any more")
            continue
        name = "%02d-%s" % (i, entry.get("name") or pathlib.Path(entry["file"]).stem)
        kb = render(f, OUT / (name + ".png"), entry.get("full", False))
        total += 1
        flag = "  >1MB" if kb > 1024 else ""
        print(f"  {name + '.png':30} {kb:5} KB{flag}   {entry.get('why', '')[:44]}")
    print(f"\n{total} image(s) in {OUT}")
    if total:
        print("Upload order is the filename order. The first thing people see is")
        print("mod/preview.jpg, from dev/make_preview.py -- that one is a JPEG")
        print("because Steam caps the preview at 1 MB.")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split(chr(10))[0])
    ap.add_argument("--list", action="store_true", help="newest screenshots, numbered")
    ap.add_argument("--add", type=int, metavar="N", help="add screenshot N from --list")
    ap.add_argument("--new", action="store_true",
                    help="add every screenshot taken since the newest already picked")
    ap.add_argument("--drop", metavar="NAME", help="remove a picked image by name or number")
    ap.add_argument("--name", help="short name for the file, with --add")
    ap.add_argument("--why", default="", help="one line on what it shows")
    ap.add_argument("--full", action="store_true", help="keep the hotbar in")
    ap.add_argument("--count", type=int, default=20, help="how many to list")
    a = ap.parse_args()

    src = shots_dir()
    if src is None:
        sys.exit(f"no Scrap Mechanic screenshots under {STEAM}")
    state = load()
    picked = {e["file"] for e in state["images"]}

    if a.list:
        print(f"{src}\n")
        for i, f in enumerate(shots(src)[:a.count], start=1):
            when = datetime.datetime.fromtimestamp(f.stat().st_mtime)
            mark = "PICKED" if f.name in picked else "      "
            print(f"  {i:3}  {mark}  {when:%Y-%m-%d %H:%M}  {f.name}")
        print("\n  python dev/steam_images.py --add <number> --name plots "
              "--why \"what it shows\"")
        return

    if a.drop:
        before = len(state["images"])
        state["images"] = [e for i, e in enumerate(state["images"], start=1)
                           if e.get("name") != a.drop and str(i) != a.drop.lstrip("0")
                           and e["file"] != a.drop]
        save(state)
        print(f"dropped {before - len(state['images'])}")
        build(state, src)
        return

    if a.add is not None:
        found = shots(src)
        if not 1 <= a.add <= len(found):
            sys.exit(f"there is no screenshot {a.add} -- try --list")
        f = found[a.add - 1]
        state["images"] = [e for e in state["images"] if e["file"] != f.name]
        state["images"].append({"file": f.name, "name": a.name or "", "why": a.why,
                                "full": bool(a.full)})
        save(state)
        print(f"added {f.name}")

    if a.new:
        # Everything newer than the newest thing already picked. "Since last
        # time" beats a date the user has to remember, and a screenshot taken
        # BEFORE the ones already chosen is almost never the one they meant.
        known = [f for f in shots(src) if f.name in picked]
        cutoff = max((f.stat().st_mtime for f in known), default=0)
        fresh = [f for f in shots(src) if f.stat().st_mtime > cutoff]
        for f in reversed(fresh):
            state["images"].append({"file": f.name, "name": "", "why": "",
                                    "full": bool(a.full)})
        save(state)
        print(f"added {len(fresh)} new screenshot(s)")

    build(state, src)


if __name__ == "__main__":
    main()
