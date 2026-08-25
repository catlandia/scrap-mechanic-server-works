"""Read the table /bench wrote, outside the game.

`/bench results` prints the run in chat, which is fine for one glance and no good
for anything else -- chat scrolls, it wraps, and it is gone when the world
closes. The run is also written to `$CONTENT_DATA/Bench.json`, which is a real
file in the installed mod folder, and this reads it.

    python dev/bench_report.py                 the last run
    python dev/bench_report.py --csv           the same, as CSV to paste anywhere
    python dev/bench_report.py <path>          a Bench.json you kept a copy of

WHAT THE COLUMNS MEAN, AND WHICH ONE TO READ FIRST

    bots      how many crowd bots were standing. Row 0 is the empty-city
              baseline, and every percentage below is against it.
    fps       the HOST's frame rate over the window, from real elapsed seconds.
              This is the number that degraded in the one real event on record.
    min       the worst single second in the window. A mean of 55 with a min of
              9 is a stutter, and a stutter is what people actually complain
              about.
    tick/s    server simulation rate. 40 is healthy. This project has never yet
              seen it move first.
    shapes    every shape in the world, from the protection patrol's own census.
    bodies    every body. The gap between this and shapes is the interesting
              part: bodies are what the engine rebuilds, shapes are what it
              draws.

Read `fps` and `tick/s` as a PAIR. The whole finding this project keeps running
into is that they do not fail together -- 19 players never dented the tick rate,
and 5 players starved three clients of network data while the tick rate sat at
39.8. If tick/s is flat all the way down the table and fps halves, that is the
expected shape, not a broken run.

WHAT IS NOT IN HERE

The per-client network budget. Bots hold no client connection, so no number of
them produces one -- it needs a guest, and one guest is enough. It lives in the
game log, and `dev/session_stats.py` reports it.
"""
import io
import json
import os
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MODS = pathlib.Path(os.path.expandvars(
    r"%APPDATA%\Axolot Games\Scrap Mechanic\User"
))


def installed_bench():
    """The Bench.json the running game wrote, in the installed mod folder."""
    name = json.loads(
        (ROOT / "mod" / "description.json").read_text(encoding="utf-8-sig"))["name"]
    for user in MODS.glob("User_*"):
        candidate = user / "Mods" / name / "Bench.json"
        if candidate.is_file():
            return candidate
    return None


def rows_from(path):
    data = json.loads(io.open(path, encoding="utf-8-sig").read())
    rows = data.get("rows") if isinstance(data, dict) else data
    if not isinstance(rows, list):
        sys.exit(f"{path}: no rows in this file")
    return rows


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    want_csv = "--csv" in sys.argv

    path = pathlib.Path(args[0]) if args else installed_bench()
    if path is None or not path.is_file():
        sys.exit("no Bench.json found -- run /bench start in game first, "
                 "and let it finish (results are written at the end).")

    rows = rows_from(path)
    if not rows:
        sys.exit(f"{path}: the run recorded no rows")

    print(f"{path}")
    print(f"{len(rows)} stage(s)")
    print()

    base = rows[0]
    base_fps = base.get("fps") or 0

    if want_csv:
        print("bots,fps,fps_min,tick_per_s,shapes,bodies,seconds,pct_of_baseline")
        for r in rows:
            pct = (r.get("fps", 0) / base_fps * 100) if base_fps else 0
            print(f"{r.get('bots', 0)},{r.get('fps', 0):.2f},"
                  f"{r.get('fpsMin', 0):.2f},{r.get('tickRate', 0):.2f},"
                  f"{r.get('shapes') or ''},{r.get('bodies', 0)},"
                  f"{r.get('secs', 0):.1f},{pct:.1f}")
        return

    print("  bots     fps     min   tick/s    shapes   bodies   vs empty")
    for r in rows:
        pct = (r.get("fps", 0) / base_fps * 100) if base_fps else 0
        bar = "#" * int(min(pct, 100) / 5)
        print(f"  {r.get('bots', 0):>4}  {r.get('fps', 0):>6.1f}  "
              f"{r.get('fpsMin', 0):>6.1f}   {r.get('tickRate', 0):>6.1f}  "
              f"{str(r.get('shapes') or '?'):>8}  {r.get('bodies', 0):>6}   "
              f"{pct:>5.0f}%  {bar}")

    print()
    # Say where it turned rather than leaving it to be eyeballed, and say it in
    # both directions -- "nothing moved" is a result too, and on this project's
    # evidence so far it is the likelier one for tick rate.
    tick_at = next((r["bots"] for r in rows
                    if r.get("tickRate", 0) > 0 and r["tickRate"] < 36), None)
    fps_at = next((r["bots"] for r in rows
                   if base_fps and r.get("fps", 0) < base_fps * 0.5), None)

    print(f"  tick rate: {'fell below 36 Hz at %d bots' % tick_at if tick_at else 'never fell below 36 Hz'}")
    print(f"  frame rate: {'halved at %d bots' % fps_at if fps_at else 'never halved'}")

    worst = min(rows, key=lambda r: r.get("fpsMin", 0))
    if worst.get("fpsMin", 0) < base_fps * 0.5 and base_fps:
        print(f"  worst single second: {worst['fpsMin']:.0f} fps, "
              f"at {worst.get('bots', 0)} bots -- a stutter, not a slowdown")

    clients = rows[-1].get("clients") or []
    if len(clients) > 1:
        print()
        print("  per client, at the last size:")
        for c in clients:
            print(f"    {c.get('name', '?'):<20} {c.get('fps', 0):>6.1f} fps")

    print()
    print("  the per-client NETWORK budget is not in this file -- bots hold no")
    print("  client connection. It needs one guest, and it is in the game log:")
    print("      python dev/session_stats.py")


if __name__ == "__main__":
    main()
