"""Rebuild the crowd bot's garment pools from what vanilla actually puts on
in-game NPCs, instead of from everything that happens to sit on disk.

Run from the repo root. Rewrites the W.PIECES table in mod/Scripts/BotCharacter.lua.
"""
import collections
import io
import json
import re

GAME = r"D:\SteamLibrary\steamapps\common\Scrap Mechanic"
BOT = r"E:\Projects\Server Works\server-works\mod\Scripts\BotCharacter.lua"

O = "$SURVIVAL_DATA/Character/Char_Male/Outfit/"
H = "$SURVIVAL_DATA/Character/Char_Male/Head/"
R = "$SURVIVAL_DATA/Character/Char_Male/Hair/"
F = "$SURVIVAL_DATA/Character/Char_Male/Facialfeatures/"
B = "$SURVIVAL_DATA/Character/Char_Male/Body/"
PREFIX = [("O", O), ("H", H), ("R", R), ("F", F), ("B", B)]


def load(p):
    t = io.open(p, encoding="utf-8-sig").read()
    t = re.sub(r"//[^\n]*", "", t)
    t = re.sub(r",(\s*[}\]])", r"\1", t)
    return json.loads(t)


def slot_of(r):
    for frag, name in (("/Head/", "head"), ("/Hair/", "hair"),
                       ("/Facialfeatures/", "facial"), ("/Jacket/", "jacket"),
                       ("body_jacket", "jacket"), ("/Gloves/", "gloves"),
                       ("body_gloves", "gloves"), ("/Pants/", "pants"),
                       ("body_pants", "pants"), ("/Shoes/", "shoes"),
                       ("body_shoes", "shoes"), ("/Backpack/", "backpack"),
                       ("/Hat/", "hat")):
        if frag in r:
            return name
    return None


# --- what vanilla's own in-game NPCs wear -----------------------------------
worn = collections.defaultdict(lambda: collections.defaultdict(set))
d = load(GAME + r"\Survival\Character\CharacterSets\npc_mechanics.json")
for c in d["characters"]:
    sex = "female" if "female" in c["name"] else "male"
    for r in c.get("renderables", []):
        if "/Animations/" in r:
            continue
        s = slot_of(r)
        if s:
            worn[s][sex].add(r)

# Gloves and the demolition hat are char_shared_, so either sex may wear them.
for s in ("gloves", "backpack", "hat"):
    shared = {r for sx in ("male", "female") for r in worn[s][sx]
              if "char_shared_" in r}
    for sx in ("male", "female"):
        worn[s][sx] |= shared

# --- the face categories, which ARE the customisation menu -------------------
# CharacterCustomizationGui.cpp names nine categories, and FACE, HAIR and
# HAIR_FACIAL are three of them: every numbered variant on disk is one of the
# options a player scrolls through. Those are taken in full rather than
# restricted to the five vanilla happens to have put on an NPC.
import glob
import os


def rends(sub, pat):
    out = []
    for p in glob.glob(os.path.join(GAME, "Survival", "Character", "Char_Male",
                                    sub, "**", "*.rend"), recursive=True):
        leaf = os.path.basename(p)
        if pat in leaf:
            out.append("$SURVIVAL_DATA/Character/Char_Male/" +
                       os.path.relpath(p, os.path.join(GAME, "Survival", "Character", "Char_Male"))
                       .replace("\\", "/"))
    return sorted(out)


faces = {
    "head": {"male": rends("Head", "char_male_head"),
             "female": rends("Head", "char_female_head")},
    "hair": {"male": rends("Hair", "char_male_hair") + rends("Hair", "char_female_hair"),
             "female": rends("Hair", "char_female_hair") + rends("Hair", "char_male_hair")},
    "facial": {"male": rends("Facialfeatures", "char_male_facialhair"),
               "female": []},
}

pools = {}
for s in ("head", "hair", "facial"):
    pools[s] = faces[s]
for s in ("jacket", "gloves", "pants", "shoes", "backpack", "hat"):
    pools[s] = {sx: sorted(worn[s][sx]) for sx in ("male", "female")}


def short(path):
    for name, pre in PREFIX:
        if path.startswith(pre):
            return f'{name} .. "{path[len(pre):]}"'
    return f'"{path}"'


lines = ["W.PIECES = {"]
ORDER = ["head", "hair", "facial", "jacket", "gloves", "pants", "shoes",
         "backpack", "hat"]
for s in ORDER:
    lines.append(f"\t{s} = {{")
    for sx in ("male", "female"):
        got = pools[s][sx]
        if not got:
            lines.append(f"\t\t{sx} = {{}},")
            continue
        lines.append(f"\t\t{sx} = {{")
        for r in got:
            lines.append(f"\t\t\t{short(r)},")
        lines.append("\t\t},")
    lines.append("\t},")
    lines.append("")
lines.append("}")
table = "\n".join(lines)

src = io.open(BOT, encoding="utf-8").read()
start = src.index("W.PIECES = {")
end = src.index("W.PIECES.backpack.female = W.PIECES.backpack.male")
src = src[:start] + table + "\n\n" + src[end:]
# that alias is now produced by the generator itself
src = src.replace("W.PIECES.backpack.female = W.PIECES.backpack.male\n", "")
io.open(BOT, "w", encoding="utf-8").write(src)

total = sum(len(pools[s][sx]) for s in ORDER for sx in ("male", "female"))
print("rebuilt W.PIECES;", total, "slot entries")
for s in ORDER:
    print(f"  {s:9} male {len(pools[s]['male']):2}  female {len(pools[s]['female']):2}")
