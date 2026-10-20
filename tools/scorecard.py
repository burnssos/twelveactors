import pathlib
#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
"""Scorecard: waypoint health per map, original (live) vs improved (staged).

Metrics that actually affect bot behaviour:
  frag      connected components of the path graph (bots cannot walk between them)
  orphan    used waypoints with no paths and no incoming refs (dead weight)
  unreach   waypoints flagged W_FL_UNREACHABLE
  far       waypoint whose nearest neighbour is >300u (pathless island)
  defdec    objectives with no DEFEND waypoint in the objective's own area
  crhdec    objectives with no CROUCH within 400u
  capfar    objectives whose nearest waypoint is >150u
"""
import sys, os, math, struct
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "tools"))
from rcw import decode, FLAGS
from bsp_ents import ents, vec

DEFEND, CROUCH, UNREACH = 1 << 18, 1 << 1, 1 << 2
MAPS = ["dod_anzio", "dod_argentan", "dod_avalanche", "dod_colmar", "dod_donner",
        "dod_flash", "dod_jagd", "dod_kalt", "dod_palermo"]
LIVE = "/srv/dods/dod/addons/rcbot2/waypoints/dod/%s.rcw"
NEW = str(pathlib.Path(__file__).resolve().parents[1] / "waypoints-improved" / "%s.rcw")
BSP = "/srv/dods/dod/maps/%s.bsp"


def d3(a, b):
    return math.sqrt(sum((a[i] - b[i]) ** 2 for i in range(3)))


def graph_stats(used):
    n = len(used)
    idx_of = {w["idx"]: i for i, w in enumerate(used)}
    adj = [set() for _ in range(n)]
    for i, w in enumerate(used):
        for p in w["paths"]:
            j = idx_of.get(p)
            if j is not None and j != i:
                adj[i].add(j)
                adj[j].add(i)
    seen, comps = [False] * n, []
    for s in range(n):
        if seen[s]:
            continue
        stack, size = [s], 0
        seen[s] = True
        while stack:
            v = stack.pop()
            size += 1
            for u in adj[v]:
                if not seen[u]:
                    seen[u] = True
                    stack.append(u)
        comps.append(size)
    comps.sort(reverse=True)
    orphan = sum(1 for i in range(n) if not adj[i])
    far = 0
    for i, w in enumerate(used):
        best = min((d3(w["origin"], v["origin"]) for j, v in enumerate(used) if j != i), default=1e9)
        if best > 300:
            far += 1
    return dict(comps=len(comps), biggest=comps[0] if comps else 0,
                second=comps[1] if len(comps) > 1 else 0, orphan=orphan, far=far,
                stray=sum(1 for c in comps[1:] if c < 5))


def score(rcw, bsp):
    d = decode(rcw)
    used = [w for w in d["wpts"] if w["used"]]
    objs = [(kv.get("targetname") or "?", vec(kv)) for kv in ents(bsp)
            if kv.get("classname") == "dod_control_point" and vec(kv)]
    defdec = crhdec = capfar = 0
    for name, o in objs:
        if not used:
            defdec += 1
            crhdec += 1
            continue
        near = min(used, key=lambda w: d3(w["origin"], o))
        area = near["area"]
        inarea = [w for w in used if w["area"] == area]
        if not any(w["flags"] & DEFEND for w in inarea):
            defdec += 1
        if not any(w["flags"] & CROUCH and d3(w["origin"], o) <= 400 for w in inarea):
            crhdec += 1
        if d3(near["origin"], o) > 150:
            capfar += 1
    g = graph_stats(used)
    return dict(used=len(used), objs=len(objs), defdec=defdec, crhdec=crhdec, capfar=capfar,
                unreach=sum(1 for w in used if w["flags"] & UNREACH), **g)


def main():
    print("%-14s %5s %5s %6s %5s %6s %6s %7s %6s %5s %5s" % (
        "map", "used", "objs", "comps", "2nd", "stray", "orphan", "unreach", "far", "def-", "crh-"))
    print("-" * 88)
    rows = {}
    for m in MAPS:
        for tag, path in (("old", LIVE % m), ("new", NEW % m)):
            if not os.path.exists(path):
                continue
            rows[(m, tag)] = score(path, BSP % m)
        o, n = rows.get((m, "old")), rows.get((m, "new"))
        if not o:
            continue
        def line(tag, s):
            return "%-14s %5d %5d %6d %5d %6d %6d %7d %6d %5d %5d" % (
                (m if tag == "old" else "  -> improved"), s["used"], s["objs"], s["comps"],
                s["second"], s["stray"], s["orphan"], s["unreach"], s["far"], s["defdec"], s["crhdec"])
        print(line("old", o))
        if n:
            print(line("new", n))
    print()
    print("worst on ORIGINAL maps (higher = worse; def-/crh- = objectives uncovered):")
    for (m, tag), s in sorted(rows.items(), key=lambda kv: -(kv[1]["defdec"] * 10 + kv[1]["crhdec"] * 6 + kv[1]["orphan"] + kv[1]["unreach"] * 0.5 + kv[1]["comps"])):
        if tag != "old":
            continue
        risk = s["defdec"] * 10 + s["crhdec"] * 6 + s["orphan"] * 2 + s["far"] + (s["comps"] - 1) * 3
        print("  %-14s risk=%-4d def-=%d crh-=%d comps=%d stray=%d orphan=%d far=%d unreach=%d" % (
            m, risk, s["defdec"], s["crhdec"], s["comps"], s["stray"], s["orphan"], s["far"], s["unreach"]))


if __name__ == "__main__":
    main()
