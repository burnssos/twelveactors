#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
"""Per-map waypoint coverage vs DoD:S objectives and spawns."""
import sys, os, math, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rcw import decode, FLAGS, summarize
from bsp_ents import ents, vec

W_BITS = dict(FLAGS)


def dist(a, b):
    return math.sqrt(sum((a[i] - b[i]) ** 2 for i in range(3)))


def analyze(rcw, bsp):
    d = decode(rcw)
    used = [w for w in d["wpts"] if w["used"]]
    e = ents(bsp)
    objs = []
    for kv in e:
        if kv.get("classname") in ("dod_control_point", "dod_objective", "dod_flag", "dod_bomb_target", "func_bomb_target"):
            o = vec(kv)
            if o:
                objs.append((kv.get("targetname") or kv.get("classname"), o))
    spawns = {"allies": [], "axis": []}
    for kv in e:
        c = kv.get("classname")
        o = vec(kv) if not kv.get("origin") is None else None
        if c in ("info_player_allies", "info_player_axis") and o:
            spawns["allies" if c.endswith("allies") else "axis"].append(o)

    def centroid(ps):
        if not ps:
            return None
        n = len(ps)
        return tuple(sum(p[i] for p in ps) / n for i in range(3))

    cs = {k: centroid(v) for k, v in spawns.items()}

    print("== %s  (%d used waypoints, %d objectives)" % (d["mapname"], len(used), len(objs)))
    if all(cs.values()):
        print("   spawn centres: allies %s  axis %s" % (tuple(round(x) for x in cs["allies"]), tuple(round(x) for x in cs["axis"])))
    print("   %-16s %-26s %6s %5s %5s %5s %4s %4s %4s %4s" % (
        "objective", "origin", "near", "cap", "def", "snp", "mg", "crh", "noAx", "noAl"))
    for name, o in objs:
        near = sorted(used, key=lambda w: dist(w["origin"], o))
        dmin = dist(near[0]["origin"], o)
        def cnt(bit, r=500):
            return sum(1 for w in used if dist(w["origin"], o) <= r and w["flags"] & bit)
        cap = sum(1 for w in used if dist(w["origin"], o) <= 300 and w["flags"] & (1 << 5))
        print("   %-16s %-26s %6.0f %5d %5d %5d %4d %4d %4d %4d" % (
            name, "%d,%d,%d" % tuple(round(x) for x in o), dmin, cap,
            cnt(1 << 18), cnt(1 << 11), cnt(1 << 14), cnt(1 << 1), cnt(1 << 6), cnt(1 << 7)))
    # team split of tactical points
    if all(cs.values()):
        split = {"allies_half": 0, "axis_half": 0, "mid": 0}
        tactical = [w for w in used if w["flags"] & ((1 << 18) | (1 << 11) | (1 << 14) | (1 << 15) | (1 << 1))]
        for w in tactical:
            da, dx = dist(w["origin"], cs["allies"]), dist(w["origin"], cs["axis"])
            if da * 0.75 < dx:
                split["allies_half"] += 1
            elif dx * 0.75 < da:
                split["axis_half"] += 1
            else:
                split["mid"] += 1
        print("   tactical pts (defend/sniper/mg/prone/crouch) by territory: %s of %d" % (split, len(tactical)))
    # spawn egress
    for side, ps in spawns.items():
        if not ps:
            continue
        dmins = []
        for p in ps:
            dmins.append(min(dist(w["origin"], p) for w in used))
        dmins.sort()
        print("   %s spawns: nearest waypoint median %.0f, worst %.0f, >200u: %d/%d" % (
            side, dmins[len(dmins) // 2], dmins[-1], sum(1 for x in dmins if x > 200), len(dmins)))
    s = summarize(d)
    print("   flags:", ", ".join("%s=%d" % kv for kv in sorted(s["flags"].items(), key=lambda kv: -kv[1])))
    print()


if __name__ == "__main__":
    for m in sys.argv[1:]:
        analyze("/srv/dods/dod/addons/rcbot2/waypoints/dod/%s.rcw" % m,
                "/srv/dods/dod/maps/%s.bsp" % m)
