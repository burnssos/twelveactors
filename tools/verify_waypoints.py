import pathlib
#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
"""Verify improved .rcw files differ from originals only in waypoint flag bits."""
import sys, os, struct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rcw import decode, FLAGS
from improve_waypoints import record_offsets

ORIG = sys.argv[1] if len(sys.argv) > 1 else "/srv/dods/dod/addons/rcbot2/waypoints/dod"
NEW = sys.argv[2] if len(sys.argv) > 2 else str(pathlib.Path(__file__).resolve().parents[1] / "waypoints-improved")
ok = True
for f in sorted(os.listdir(NEW)):
    if not f.endswith(".rcw"):
        continue
    a = open(os.path.join(ORIG, f), "rb").read()
    b = open(os.path.join(NEW, f), "rb").read()
    offs, end, size = record_offsets(a)
    da, db = decode(os.path.join(ORIG, f)), decode(os.path.join(NEW, f))
    problems = []
    if len(a) != len(b):
        problems.append("size %d != %d" % (len(a), len(b)))
    if da["count"] != db["count"] or da["mapname"] != db["mapname"]:
        problems.append("header changed")
    if da["wpts"].__len__() != db["wpts"].__len__():
        problems.append("record count changed")
    diffidx = set()
    n = min(len(a), len(b))
    for off in range(0, n):
        if a[off] != b[off]:
            # find which record's flags field this offset belongs to
            hit = [i for i, fo in enumerate(offs) if fo <= off < fo + 4]
            if not hit:
                problems.append("byte %d outside any flags field" % off)
                break
            diffidx.add(hit[0])
    # structural equality everywhere except flags
    for i, (wa, wb) in enumerate(zip(da["wpts"], db["wpts"])):
        a2 = {k: v for k, v in wa.items() if k != "flags"}
        b2 = {k: v for k, v in wb.items() if k != "flags"}
        if a2 != b2:
            problems.append("wpt %d differs outside flags" % i)
            break
    # every changed record must only gain bits
    for i in diffidx:
        fa, fb = da["wpts"][i]["flags"], db["wpts"][i]["flags"]
        if fa & fb != fa:
            problems.append("wpt %d lost flags 0x%x -> 0x%x" % (i, fa, fb))
    print("%-16s %s  %d record(s) retagged  offsets ok=%s  size %d" % (
        f, "PASS" if not problems else "FAIL", len(diffidx),
        sorted(set(diffidx)) == sorted(diffidx), len(b)))
    for p in problems:
        print("   !", p)
        ok = False
sys.exit(0 if ok else 1)
