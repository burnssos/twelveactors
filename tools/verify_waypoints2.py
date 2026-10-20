import pathlib
#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
"""Verify the staged waypoint set before/after install.

Checks, per map:
  1. file size identical to the live file (no records added or removed)
  2. every byte that differs lies inside a record's flags or area int
  3. every control point has >=2 usable DEFEND points and >=1 CROUCH point
     in its own area within 450u -- the only thing forceArea can select
  4. header mapname matches the filename
Exit 0 = PASS.
"""
import sys, os, math, struct
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "tools"))
from rcw import decode
from improve_waypoints2 import offsets, MAPS
from bsp_ents import ents, vec

UNREACH, DEFEND, CROUCH, CAPPOINT = 1 << 2, 1 << 18, 1 << 1, 1 << 5
LIVE = "/srv/dods/dod/addons/rcbot2/waypoints/dod/%s.rcw"
STAGE = str(pathlib.Path(__file__).resolve().parents[1] / "waypoints-final" / "%s.rcw")
BSP = "/srv/dods/dod/maps/%s.bsp"


def d3(a, b):
    return math.sqrt(sum((a[i] - b[i]) ** 2 for i in range(3)))


def main():
    fails = 0
    print("%-14s %5s %6s %8s %6s %s" % ("map", "size", "stray", "flags", "area", "coverage"))
    for m in MAPS:
        live, stage = LIVE % m, STAGE % m
        if not os.path.exists(stage):
            print("%-14s MISSING %s" % (m, stage))
            fails += 1
            continue
        a, b = open(live, "rb").read(), open(stage, "rb").read()
        d = decode(stage)
        ok = True
        if len(a) != len(b):
            print("%-14s SIZE %d != %d" % (m, len(a), len(b)))
            fails += 1
            ok = False
            continue
        if d["mapname"] != m:
            print("%-14s HEADER mapname=%r" % (m, d["mapname"]))
            fails += 1
            ok = False
        rec = offsets(a)
        allowed = set()
        for fo, ao in rec:
            allowed.update(range(fo, fo + 4))
            allowed.update(range(ao, ao + 4))
        stray = sum(1 for i in range(len(a)) if a[i] != b[i] and i not in allowed)
        nf = sum(1 for fo, _ in rec if struct.unpack_from("<i", a, fo)[0] != struct.unpack_from("<i", b, fo)[0])
        na = sum(1 for _, ao in rec if struct.unpack_from("<i", a, ao)[0] != struct.unpack_from("<i", b, ao)[0])
        if stray:
            fails += 1
            ok = False
        used = [w for w in d["wpts"] if w["used"]]
        caps = [w for w in used if w["flags"] & CAPPOINT]
        bad = []
        for kv in ents(BSP % m):
            if kv.get("classname") != "dod_control_point":
                continue
            o = vec(kv)
            if not o:
                continue
            area = min(caps, key=lambda w: d3(w["origin"], o))["area"] if caps else 0
            near = [w for w in used if w["area"] == area
                    and not w["flags"] & UNREACH and d3(w["origin"], o) <= 450]
            dd = sum(1 for w in near if w["flags"] & DEFEND)
            cc = sum(1 for w in near if w["flags"] & CROUCH)
            if len(near) < 2 or dd < 2 or cc < 1:
                bad.append("%s(%d/%d/%d)" % (kv.get("targetname"), len(near), dd, cc))
        if bad:
            fails += 1
            ok = False
        print("%-14s %5s %6d %8d %6d %s" % (
            m, "ok" if len(a) == len(b) else "BAD", stray, nf, na,
            ", ".join(bad) if bad else "all flags covered"))
        if not ok:
            print("    FAIL %s" % m)
    print()
    if fails:
        print("FAIL: %d map(s) failed verification." % fails)
        return 1
    print("PASS: 9 maps, layout preserved, every control point has defenders in its own area.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
