"""Prepare the supporting images for the Workshop page.

The Workshop shows one preview (mod/preview.jpg, made by make_preview.py) and
then a gallery. This crops the chosen screenshots to 16:9, cuts the hotbar and
whatever debug text was on screen, and writes them numbered into dev/steam/
ready to upload.

NO OVERLAY ON THESE, deliberately. The preview carries the title, the version
and the work-in-progress warning; a gallery shot that repeats all that is a
worse screenshot and a busier page. These are just the mod, cleanly framed.

WHY THE CROPS ARE WRITTEN DOWN. Every one was chosen by looking at the shot: the
hotbar sits in the bottom ~190px of a 1440-tall capture, the chat log runs down
the left, and the roster HUD in the top left is worth KEEPING because it is the
mod. A blanket crop would take the wrong thing off at least one of them.

    python dev/steam_images.py            build them
    python dev/steam_images.py --list     say what is chosen and why
"""
import pathlib
import sys

try:
    from PIL import Image
except ImportError:
    sys.exit("Pillow not installed:  pip install pillow")

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "dev" / "steam"
SIZE = (1920, 1080)

# Steam keeps screenshots per user; this is resolved rather than hard-coded so
# the script survives another account being added.
STEAM = pathlib.Path(r"C:\Program Files (x86)\Steam\userdata")
APPID = "387990"


def shots_dir():
    best = None
    for user in STEAM.glob("*/760/remote/" + APPID + "/screenshots"):
        if user.is_dir() and (best is None or
                              len(list(user.glob("*.jpg"))) > len(list(best.glob("*.jpg")))):
            best = user
    return best


# name, crop (x, y, w, h) in the 3440x1440 capture, what it shows
CHOSEN = [
    ("01-the-crowd", "20260826014733_1.jpg", (300, 0, 2840, 1245),
     "90 crowd bots on a built city, with the roster and event HUD live. "
     "The mod doing the thing the mod is for."),

    ("02-the-city", "20260825232922_1.jpg", (0, 0, 3440, 1245),
     "The deck running to the horizon -- plots, the metal seams between them, "
     "and the striped roads. What /plotbuild makes."),

    ("03-ground-level", "20260826012038_1.jpg", (700, 0, 2740, 1245),
     "Standing on it, with a few bots about. Shows the scale of one plot "
     "against a person, which the top-down shots cannot."),

    ("04-city-layout", "20260825202433_1.jpg", (380, 40, 2680, 1300),
     "The CITY LAYOUT panel: every dimension of the city, and a live top-down "
     "map that updates as you change them. The panel a host starts on."),
]


def main():
    src = shots_dir()
    if src is None:
        sys.exit(f"no Scrap Mechanic screenshots under {STEAM}")

    if "--list" in sys.argv:
        print(f"source: {src}\n")
        for name, f, crop, why in CHOSEN:
            here = "ok " if (src / f).is_file() else "MISSING"
            print(f"  [{here}] {name}\n      {f}  crop {crop}\n      {why}\n")
        print("Add your own: put the file in the list above with a crop, or drop")
        print("a ready-made 16:9 image straight into dev/steam/.")
        return

    OUT.mkdir(parents=True, exist_ok=True)
    made = 0
    for name, f, crop, why in CHOSEN:
        path = src / f
        if not path.is_file():
            print(f"  SKIP {name} -- {f} is not there any more")
            continue
        im = Image.open(path).convert("RGB")
        x, y, w, h = crop
        im = im.crop((x, y, min(x + w, im.width), min(y + h, im.height)))
        # Cover-fit to 16:9, centred. The crops above are already close, so this
        # only trims a few pixels -- it is here so a hand-typed crop that is
        # slightly off still produces a correctly shaped image.
        sc = max(SIZE[0] / im.width, SIZE[1] / im.height)
        im = im.resize((round(im.width * sc), round(im.height * sc)), Image.LANCZOS)
        im = im.crop(((im.width - SIZE[0]) // 2, (im.height - SIZE[1]) // 2,
                      (im.width - SIZE[0]) // 2 + SIZE[0],
                      (im.height - SIZE[1]) // 2 + SIZE[1]))
        dst = OUT / f"{name}.jpg"
        im.save(dst, "JPEG", quality=92, optimize=True)
        print(f"  {dst.name:22} {dst.stat().st_size // 1024:4} KB   {why[:52]}")
        made += 1

    print(f"\n{made} image(s) in {OUT}")
    print("Upload order is the filename order. The first one people see is")
    print("mod/preview.jpg, which is made by dev/make_preview.py.")


if __name__ == "__main__":
    main()
