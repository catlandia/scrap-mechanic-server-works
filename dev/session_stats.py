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
             to client 765611990XXXXXXXX Budget is currently: -280930
             (steam id redacted -- it identified a real guest, and this
              repo is public. The tool prints live ids at runtime; only
              the pasted EXAMPLE is masked.)

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
# WHO WAS REFUSED, AND WHAT THE VISIBILITY SETTING WAS WHEN THEY WERE.
#
# MEASURED across this machine's 340 logs: 50 successful connections, 10
# refusals -- and 8 of those 10 are one person, in one session, retrying every
# few seconds and failing every time, right up until the host widened the
# Multiplayer setting. Their very next attempt connected.
#
# A refusal is `Connecting -> None` with no `Finding Route` in between. A real
# connection goes Connecting -> Finding Route -> Connected, so a state line that
# falls back to None from Connecting never got as far as routing: it was turned
# away, not dropped.
#
# The mode is logged as `Multiplayer: Multiplayer(N)` on load and on every
# change, which is what makes the correlation readable at all.
# WHAT ELSE WAS LOADED. The game lists every mod on startup in one line:
#
#   Server Works - UGC - Type: CustomGameMod Version: 1/1 - Content ID: <uuid>
#                        - Steam File ID: 0 - Local: true
#
# This matters more now that `allow_add_mods` is true. A Blocks-and-Parts mod
# enabled beside this one runs server-side Lua on the host with nearly our own
# reach -- there is no sandbox between mods (docs/MODS-AND-TRUST.md). Only the
# HOST can tick that box, so it is their own risk and nobody else's, but "my
# own risk" is only true if they can see what they took.
MODLINE = re.compile(
    rb"\s*(.+?) - UGC - Type: (\w+)"
    rb"(?:.*?Content ID: ([0-9a-f-]+))?"
    rb"(?:.*?Steam File ID: (\d+))?")

STATE = re.compile(rb"State: ([A-Za-z ]+) -> ([A-Za-z ]+)")
CONN = re.compile(rb"Connection handle: (\d+), user: (\d+)")
MPMODE = re.compile(rb"Multiplayer: Multiplayer\((\d+)\)")
NOAUTH = re.compile(rb"User (\d+) is not authenticated")

HEAD = re.compile(rb"^\d\d:\d\d:\d\d \(\d+/\d+\) \[[^\]]*\] ?")
NUM = re.compile(rb"-?\d+\.?\d*")

HEALTHY_TICK = 40.0
NL = chr(10)


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
    # the connection story: mode changes, refusals, and auth drops
    mods = []
    joins = {"modes": [], "refused": collections.Counter(),
             "connected": collections.Counter(), "noauth": [], "last_user": None,
             "mode_now": None}

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
            if b" - UGC - Type: " in line:
                m2 = MODLINE.search(line)
                if m2:
                    mods.append(tuple(
                        (g.decode(errors="replace") if g else "") for g in m2.groups()))

            c = CONN.search(line)
            if c:
                joins["last_user"] = c.group(2).decode()
            mp = MPMODE.search(line)
            if mp:
                joins["mode_now"] = int(mp.group(1))
                joins["modes"].append((m and t or None, joins["mode_now"]))
            st = STATE.search(line)
            if st and joins["last_user"]:
                a = st.group(1).decode().strip()
                b = st.group(2).decode().strip()
                if a == "Connecting" and b == "None":
                    joins["refused"][(joins["last_user"], joins["mode_now"])] += 1
                elif b == "Connected":
                    joins["connected"][joins["last_user"]] += 1
            na = NOAUTH.search(line)
            if na:
                joins["noauth"].append((m and t or None, na.group(1).decode(),
                                        joins["mode_now"]))

            # sampling 1-in-7 is enough to rank spam and keeps the scan fast
            if want_spam and lines % 7 == 0:
                msg = HEAD.sub(b"", line).strip()
                spam[NUM.sub(b"#", msg)[:110]] += 1

    return per_minute, users, max_pid, lines, spam, budget, joins, mods


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

    per_minute, users, max_pid, lines, spam, budget, joins, mods = scan(path, want_spam)
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

    # WHO GOT IN, WHO DID NOT, AND WHAT THE SETTING WAS AT THE TIME.
    #
    # A refusal is Connecting -> None with no Finding Route in between: turned
    # away before routing, rather than dropped after it. MEASURED over the 340
    # logs on this machine -- 50 connections, 10 refusals -- and 8 of those 10
    # were ONE person retrying every few seconds into a visibility setting that
    # did not allow them, ending the instant the host widened it.
    # EVERY MOD THAT LOADED. First, because if something else was running the
    # rest of this report is about that as much as about us.
    print(NL + "mods loaded")
    if not mods:
        print("  none listed (an older build, or the line format changed)")
    else:
        for name, kind, cid, fid in mods:
            where = "local" if fid in ("", "0") else f"workshop {fid}"
            print(f"  {name[:42]:42} {kind:18} {where}")
        others = [m for m in mods if m[1] != "CustomGameMod"]
        if others:
            print(f"  ^ {len(others)} mod(s) besides the custom game were loaded.")
            print("    There is no sandbox between mods: anything here ran server-side")
            print("    Lua on the host with nearly this mod's reach. Only the host can")
            print("    enable one, so this is a record of what THEY chose to trust.")

    print(NL + "who could join")
    modes = joins["modes"]
    if modes:
        shown = ", ".join(
            ("" if t is None else "%02d:%02d " % (t // 3600, t % 3600 // 60))
            + "Multiplayer(%d)" % v for t, v in modes)
        print("  visibility setting: " + shown)
        if len(modes) > 1:
            print("  ^ IT CHANGED MID-SESSION. Narrowing it drops everyone the new")
            print("    setting does not allow, one tick later, logged as 'not")
            print("    authenticated' rather than as anything about the setting.")
    else:
        print("  visibility setting: never logged (single player, or an old build)")

    if joins["connected"]:
        print("  connected: %d from %d user(s)"
              % (sum(joins["connected"].values()), len(joins["connected"])))
    if joins["refused"]:
        print("  REFUSED:   %d attempt(s) -- turned away before routing"
              % sum(joins["refused"].values()))
        for (who, mode), n in joins["refused"].most_common():
            print("    %3dx  user %s  while Multiplayer(%s)" % (n, who, mode))
        print("    A refusal is the visibility setting, not the network. The person")
        print("    retrying sees nothing, and neither does the host.")
    else:
        print("  refused:   none")
    if joins["noauth"]:
        print("  dropped as 'not authenticated': %d" % len(joins["noauth"]))
        for t, who, mode in joins["noauth"][:6]:
            when = "" if t is None else "%02d:%02d " % (t // 3600, t % 3600 // 60)
            print("    %suser %s  while Multiplayer(%s)" % (when, who, mode))

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
