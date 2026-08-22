"""Compile every mod Lua file to catch syntax errors before the game does.

Scrap Mechanic reports a Lua syntax error by refusing to start the game script,
which in a Custom Game looks like a broken world rather than a broken file. This
compiles (never executes) each script through a real Lua parser, so typos are
caught here instead of during an event.

Compile-only means undefined globals -- class, sm, dofile -- are irrelevant;
they are runtime names, not parse-time ones.

Usage: python dev/check_lua.py
"""
import pathlib
import sys

try:
    import lupa
except ImportError:
    sys.exit("lupa not installed:  pip install lupa")

ROOT = pathlib.Path(__file__).resolve().parent.parent
lua = lupa.LuaRuntime()
# Collapse load()'s two return values into one string -- lupa cannot unpack a
# multiple-return directly, and all we need is "" for ok or the error text.
compile_chunk = lua.eval("""
    function(src, name)
        local chunk, err = load(src, name)
        return chunk and "" or tostring(err)
    end
""")

files = sorted(ROOT.glob("mod/**/*.lua"))
if not files:
    sys.exit("no lua files under mod/")

bad = 0
for f in files:
    src = f.read_text(encoding="utf-8")
    err = compile_chunk(src, f"@{f.name}")
    rel = f.relative_to(ROOT)
    if err:
        bad += 1
        print(f"FAIL  {rel}\n      {err}")
    else:
        print(f"ok    {rel}  ({len(src.splitlines())} lines)")

print(f"\n{len(files) - bad}/{len(files)} compiled")
sys.exit(1 if bad else 0)
