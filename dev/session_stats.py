"""Reconstruct server/client performance from a Scrap Mechanic session log.

Every log line is stamped `HH:MM:SS (tick/frame)`. The first counter advances at
the simulation rate (40 Hz when healthy), the second at the render rate. So
dividing each counter's delta by wall-clock delta recovers, retroactively, both
the server tick rate and the client frame rate for any session already played --
no test group required.

The log also writes `Loaded player <id> (for user <steamid>)` on join, which is
the only place the engine ever reveals a Steam ID. Lua cannot see it (see
CLAUDE.md), so this is also the mapping any cross-event ban list has to be
built on.

Usage:
    python dev/session_stats.py                     # newest log
    python dev/session_stats.py <path-to-log>
    python dev/session_stats.py <path> --spam       # rank repeated lines
"""
import collections
import glob
import os
import re
import statistics
import sys

LOG_DIR = r"D:\SteamLibrary\steamapps\common\Scrap Mechanic\Logs"

STAMP = re.compile(rb"^(\d\d):(\d\d):(\d\d) \((\d+)/(\d+)\)")
JOIN = re.compile(rb"Loaded player (\d+) \(for user (\d+)\)")
HEAD = re.compile(rb"^\d\d:\d\d:\d\d \(\d+/\d+\) \[[^\]]*\] ?")
NUM = re.compile(rb"-?\d+\.?\d*")

HEALTHY_TICK = 40.0


def newest_log():
    logs = glob.glob(os.path.join(LOG_DIR, "game-*.log"))
    if not logs:
        sys.exit(f"no game-*.log under {LOG_DIR}")
    return max(logs, key=os.path.getmtime)


def scan(path, want_spam):
    # One sample per wall-clock minute is plenty and keeps multi-GB logs cheap.
    per_minute = {}
    users, max_pid, lines = set(), 0, 0
    spam = collections.Counter()

    with open(path, "rb") as f:
        for line in f:
            lines += 1
            m = STAMP.match(line)
            if m:
                h, mi, s, tick, frame = m.groups()
                t = int(h) * 3600 + int(mi) * 60 + int(s)
                per_minute[t // 60] = (t, int(tick), int(frame))
            j = JOIN.search(line)
            if j:
                users.add(j.group(2).decode())
                max_pid = max(max_pid, int(j.group(1)))
            # sampling 1-in-7 is enough to rank spam and keeps the scan fast
            if want_spam and lines % 7 == 0:
                msg = HEAD.sub(b"", line).strip()
                spam[NUM.sub(b"#", msg)[:110]] += 1

    return per_minute, users, max_pid, lines, spam


def rates(per_minute):
    out, prev = [], None
    for k in sorted(per_minute):
        t, tick, frame = per_minute[k]
        if prev:
            dt = t - prev[0]
            # skip gaps (alt-tab, load screens) and the catch-up burst after a
            # world load, which reports thousands of ticks per second
            if 30 <= dt <= 600:
                tr = (tick - prev[1]) / dt
                if 0 < tr < 200:
                    out.append((k, tr, (frame - prev[2]) / dt, dt))
        prev = (t, tick, frame)
    return out


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    want_spam = "--spam" in sys.argv
    path = args[0] if args else newest_log()

    size = os.path.getsize(path)
    print(f"{os.path.basename(path)}  ({size / 1e6:.1f} MB)")

    per_minute, users, max_pid, lines, spam = scan(path, want_spam)
    print(f"lines {lines:,}   distinct steam users {len(users)}   highest player id {max_pid}")

    r = rates(per_minute)
    if not r:
        print("no usable rate windows")
        return

    ticks = [x[1] for x in r]
    frames = [x[2] for x in r]
    print(
        f"tick/s   median {statistics.median(ticks):5.1f}  min {min(ticks):5.1f}   "
        f"(healthy = {HEALTHY_TICK:.0f})"
    )
    print(f"frame/s  median {statistics.median(frames):5.1f}  min {min(frames):5.1f}")

    starved = [x for x in r if x[1] < HEALTHY_TICK * 0.9]
    print(f"\nwindows where the server fell below 90% of {HEALTHY_TICK:.0f} Hz: "
          f"{len(starved)}/{len(r)}")
    for k, tr, fr, dt in sorted(starved, key=lambda x: x[1])[:10]:
        print(f"  {k // 60:02d}:{k % 60:02d}   tick {tr:5.1f}   frame {fr:5.1f}   ({dt}s)")

    print("\ntimeline")
    for k, tr, fr, _ in r:
        bar = "#" * int(fr / 2)
        print(f"  {k // 60:02d}:{k % 60:02d}  tick {tr:5.1f}  frame {fr:5.1f}  {bar}")

    if want_spam:
        print("\nmost repeated lines (count extrapolated from 1-in-7 sample)")
        for msg, n in spam.most_common(12):
            print(f"{n * 7:>12,}  {msg.decode('utf-8', 'replace')}")

    if users:
        print("\nplayer id -> steam id mapping is in this log; "
              "re-run with grep for the full list")


if __name__ == "__main__":
    main()
