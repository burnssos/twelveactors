#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
"""Improve RCBot2 DoD:S waypoint files (flag-only, byte-layout preserving).

Grounded in the bot's own selection code:
  * bot_dod_bot.cpp BOT_UTIL_DEFEND_POINT / _NEAREST_POINT call
      CWaypoints::randomWaypointGoal(W_FL_DEFEND, m_iTeam, i_area, true, ...)
    with bForceArea=true, so only DEFEND waypoints in the *flag's own area*
    are eligible; with none, bots fall back to a pinch point and never hold.
  * CDODMod::checkWaypointForTeam honours W_FL_NOALLIES / W_FL_NOAXIS, so a
    defend point can be restricted to the team that owns the objective.
  * CWaypointTypes::W_FL_CROUCH makes the bot duck while defending.

Rules (each waypoint is changed at most once, flags OR-ed in):
  A  objective whose area has no DEFEND waypoint  -> tag up to 2 nearby used
     waypoints DEFEND (+ owner's team flag) and the first one CROUCH if the
     area has no crouch waypoint near the objective.
  B  objective whose area has DEFEND but no crouch near it -> tag the nearest
     existing DEFEND waypoint CROUCH.
  C  symmetric maps (every objective owned, both teams own >=2) -> restrict
     existing SNIPER / MACHINEGUN / PRONE waypoints to the team whose half
     they sit in (0.75 * far-spawn distance test); contested ones untouched.

Only the 4-byte flags field of a record is rewritten, so origins, aim yaws,
paths, areas, radii and the file length all stay identical.
"""
import sys, os, struct, math, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rcw import decode, FLAGS
from bsp_ents import ents, vec

DEFEND, CROUCH, PRONE = 1 << 18, 1 << 1, 1 << 15
SNIPER, MG = 1 << 11, 1 << 14
NOAXIS, NOALLIES = 1 << 6, 1 << 7
CAPPOINT = 1 << 5
EXCLUDE = sum(1 << b for b in (0, 2, 3, 8, 9, 12, 16, 17, 19, 22, 24))  # jump/unreachable/ladder/health/opens_later/ammo/tele/areaonly/noflag/fallback
NAMES = {bit: n for bit, n in FLAGS}
TEAM_LOCK_MAPS = {"dod_palermo.rcw"}


def d3(a, b):
    return math.sqrt(sum((a[i] - b[i]) ** 2 for i in range(3)))


def record_offsets(b):
    """Absolute offset of each record's flags int, plus end-of-records and file size."""
    version, count = struct.unpack_from("<ii", b, 80)
    off = 92 + (64 if version > 3 else 0)
    out = []
    for _ in range(count):
        n = struct.unpack_from("<i", b, off + 21)[0]
        out.append(off + 16)
        off += 25 + 4 * n + 8
    return out, off, len(b)


def objectives(bsp):
    out = []
    for kv in ents(bsp):
        if kv.get("classname") != "dod_control_point":
            continue
        o = vec(kv)
        if o:
            out.append((kv.get("targetname") or "?", o, int(kv.get("point_default_owner", "0") or 0)))
    return out


def spawn_centres(bsp):
    c = {"allies": [], "axis": []}
    for kv in ents(bsp):
        cn = kv.get("classname")
        if cn in ("info_player_allies", "info_player_axis"):
            o = vec(kv)
            if o:
                c["allies" if cn.endswith("allies") else "axis"].append(o)
    return {k: (tuple(sum(p[i] for p in v) / len(v) for i in range(3)) if v else None) for k, v in c.items()}


def plan(rcw, bsp):
    d = decode(rcw)
    b = open(rcw, "rb").read()
    offs, end, size = record_offsets(b)
    used = [w for w in d["wpts"] if w["used"]]
    objs = objectives(bsp)
    tune = {}  # idx -> [extra bits, reasons]

    def add(w, bits, why):
        e = tune.setdefault(w["idx"], [0, []])
        e[0] |= bits
        e[1].append(why)

    for name, o, owner in objs:
        if not used:
            continue
        nearest = min(used, key=lambda w: d3(w["origin"], o))
        area = nearest["area"]
        inarea = [w for w in used if w["area"] == area]
        defenders = [w for w in inarea if w["flags"] & DEFEND]
        crouchers = [w for w in inarea if w["flags"] & CROUCH and d3(w["origin"], o) <= 400]
        if not defenders:
            cands = [w for w in inarea if d3(w["origin"], o) <= 400 and not (w["flags"] & EXCLUDE)]
            cands.sort(key=lambda w: d3(w["origin"], o))
            picked = []
            for w in cands:
                if len(picked) >= 2:
                    break
                if any(d3(w["origin"], p["origin"]) < 60 for p in picked):
                    continue
                picked.append(w)
            for i, w in enumerate(picked):
                bits = DEFEND
                if owner == 2:
                    bits |= NOAXIS
                elif owner == 3:
                    bits |= NOALLIES
                if i == 0 and not crouchers:
                    bits |= CROUCH
                add(w, bits, "A:%s" % name)
        elif not crouchers:
            near = sorted([w for w in defenders if d3(w["origin"], o) <= 600],
                          key=lambda w: d3(w["origin"], o))
            if near:
                add(near[0], CROUCH, "B:%s" % name)

    # rule C -- team-specific tactical points.
    # Applied only where the community ratings sheet names this as the defect
    # (dod_palermo: "special waypoints are not team-specific, so bots fight and
    # angle on the wrong side"). Maps rated Good are left alone.
    owners = [x[2] for x in objs]
    owned = [o for o in owners if o in (2, 3)]
    team_lock = os.path.basename(rcw) in TEAM_LOCK_MAPS
    if team_lock and owned.count(2) >= 2 and owned.count(3) >= 2:
        cs = spawn_centres(bsp)
        if cs["allies"] and cs["axis"]:
            for w in used:
                if (w["flags"] & (SNIPER | MG | PRONE)) == 0:
                    continue
                if w["flags"] & (NOAXIS | NOALLIES):
                    continue
                da, dx = d3(w["origin"], cs["allies"]), d3(w["origin"], cs["axis"])
                if da < 0.75 * dx:
                    add(w, NOAXIS, "C:allied-half")
                elif dx < 0.75 * da:
                    add(w, NOALLIES, "C:axis-half")

    changes = []
    for idx in sorted(tune):
        bits, why = tune[idx]
        w = d["wpts"][idx]
        changes.append(dict(idx=idx, origin=tuple(round(x) for x in w["origin"]), area=w["area"],
                            add=bits, why=why, had=w["flags"],
                            dist=round(min(d3(w["origin"], o) for _, o, _ in objs)) if objs else -1))
    return d, changes, b, offs, end, size


def names(bits):
    return "+".join(n for bit, n in FLAGS if bits & bit) or "none"


def main():
    args = sys.argv[1:]
    out_dir = None
    if "--out" in args:
        i = args.index("--out")
        out_dir = args[i + 1]
        del args[i:i + 2]
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    total = 0
    for m in args:
        if m.endswith(".rcw") or os.sep in m:
            rcw = m
            stem = os.path.basename(m)[:-4]
        else:
            stem = m
            rcw = "/srv/dods/dod/addons/rcbot2/waypoints/dod/%s.rcw" % m
        bsp = "/srv/dods/dod/maps/%s.bsp" % stem
        d, changes, b, offs, end, size = plan(rcw, bsp)
        print("== %s: %d waypoint(s) retagged" % (m, len(changes)))
        for c in changes:
            print("   #%3d %-26s area=%d d=%4du  %-40s (%s)" % (
                c["idx"], str(c["origin"]), c["area"], c["dist"], names(c["add"]), ",".join(c["why"])))
        total += len(changes)
        if out_dir:
            nb = bytearray(b)
            for c in changes:
                fo = offs[c["idx"]]
                old = struct.unpack_from("<i", nb, fo)[0]
                assert old == c["had"], (m, c["idx"], old, c["had"])
                struct.pack_into("<i", nb, fo, old | c["add"])
            dst = os.path.join(out_dir, os.path.basename(rcw))
            open(dst, "wb").write(nb)
    print("TOTAL: %d waypoint(s) across %d map(s)" % (total, len(args)))


if __name__ == "__main__":
    main()
