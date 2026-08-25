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

AND IT WRITES THE ONE NETWORK MEASUREMENT THE ENGINE GIVES AWAY.

    WARNING: NetworkServer.cpp:231 Skip sending unreliable network data
             to client 76561199070209586 Budget is currently: -280930

That is the host giving up on sending a client its state updates for that
tick, because that client's send budget is exhausted. It is the closest thing
to a 'the server cannot keep up with this player' signal the engine has, and
unlike tick rate it is PER CLIENT.

Two facts about it, both measured across the 150 logs in this install, and
both load-bearing for how this mod can be tested at all:

  * it only ever names a REMOTE client. Not once, in any log here, does it
    name the host's own loopback id. So a solo session cannot produce one --
    and neither can any number of /crowd bots, which hold no client
    connection. Measuring this needs a guest.
  * because the budget is per client and independent, ONE guest exercises it
    exactly as well as twenty would. Twenty multiplies the HOST's total
    upload, which is arithmetic on top of a measured per-client rate rather
    than a separate measurement.

Worst seen in this install: -856841 across 3 clients (2026-07-10), -486900
with 2 clients (2026-08-03), and 1729 skips over 81 minutes (2026-02-27).

A budget of exactly 0 in the first seconds of a session is NOT a warning --
that is the counter before it has been initialised, and it appears in almost
every log here. Only a negative value is data actually being dropped.

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
# NetworkServer.cpp:227 in older builds, :231 in this one. The line number is
# deliberately not part of the pattern for exactly that reason.
SKIP = re.compile(rb"Skip sending unreliable network data to client (\d+)"
                  rb"\s*Budget is currently:\s*(-?\d+)")
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
    # steam id -> [skips, worst deficit, first minute seen, last minute seen]
    budget = {}

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
            k = SKIP.search(line)
            if k:
                deficit = int(k.group(2))
                # 0 is the uninitialised counter, not a drop. See the docstring.
                if deficit < 0:
                    who = k.group(1).decode()
                    e = budget.setdefault(who, [0, 0, None, None])
                    e[0] += 1
                    e[1] = min(e[1], deficit)
                    if m:
                        minute = t // 60
                        e[2] = minute if e[2] is None else e[2]
                        e[3] = minute
            # sampling 1-in-7 is enough to rank spam and keeps the scan fast
            if want_spam and lines % 7 == 0:
                msg = HEAD.sub(b"", line).strip()
                spam[NUM.sub(b"#", msg)[:110]] += 1

    return per_minute, users, max_pid, lines, spam, budget


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

    per_minute, users, max_pid, lines, spam, budget = scan(path, want_spam)
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

    print("\nnetwork: server -> client updates DROPPED for want of budget")
    if not budget:
        print("  none -- and for a solo session that is the expected answer,")
        print("  not a clean bill of health. The engine only computes a send")
        print("  budget for a REMOTE client, so nothing here can fail until")
        print("  somebody else is actually connected. /crowd bots do not count.")
    else:
        for who, (n, worst, first, last) in sorted(
                budget.items(), key=lambda kv: -kv[1][0]):
            span = ("" if first is None else
                    f"   {first // 60:02d}:{first % 60:02d}"
                    f"-{last // 60:02d}:{last % 60:02d}")
            print(f"  client {who}   {n:,} skip(s)   "
                  f"worst {worst:,} bytes over budget{span}")
        print("  one skip is one tick of state that client never received.")

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
