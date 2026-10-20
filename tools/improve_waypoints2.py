import pathlib
#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
"""Second pass: guarantee every control point has usable defenders in ITS area.

Mechanism confirmed in RCBot2 source (utils/RCBot2_meta):
  bot_dod_bot.cpp:2543 CDODMod::m_Flags.getRandomTeamControlledFlag(...,&i_area)
     -> bot_dod_mod.cpp:557  *id = i          (i = control-point array index)
  bot_dod_bot.cpp:2549 CWaypoints::randomWaypointGoal(W_FL_DEFEND, team, i_area, true, this)
  bot_waypoint.cpp:2981 forceArea=true keeps only pWpt->getArea() == i_area
     and only pWpt->isUsed() && pWpt->forTeam(iTeam)
  bot_waypoint.cpp:3305 W_FL_UNREACHABLE = "bot can't go here"

So a defender for flag index i can only pick USED, team-legal, DEFEND-flagged
waypoints whose stored area == i. An area with no such point sends the bot to
getPinchPointFromWaypoint() instead, i.e. it stops holding the flag.

This pass, per control point:
  1. resolve the CP's area from the nearest W_FL_CAPPOINT waypoint
  2. if that area has < 2 usable DEFEND points, tag the nearest usable points
     in that area (first one also CROUCH when the area has no crouch near the CP)
  3. if the area has < 3 usable points at all, adopt the nearest usable
     waypoints within 700u into that area (what the in-game area tool does)
     so there is something to defend from
Only the 4-byte flags and 4-byte area fields are ever rewritten; origins,
yaws, paths, radii and file length are untouched.
"""
import sys, os, math, struct
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "tools"))
from rcw import decode, FLAGS
from bsp_ents import ents, vec

DEFEND, CROUCH, UNREACH, CAPPOINT = 1 << 18, 1 << 1, 1 << 2, 1 << 5
NOAXIS, NOALLIES = 1 << 6, 1 << 7
EXCLUDE = sum(1 << b for b in (0, 2, 3, 8, 9, 12, 16, 17, 19, 22, 24))
MAPS = ["dod_anzio", "dod_argentan", "dod_avalanche", "dod_colmar", "dod_donner",
        "dod_flash", "dod_jagd", "dod_kalt", "dod_palermo"]
SRC = "/srv/dods/dod/addons/rcbot2/waypoints/dod/%s.rcw"
BSP = "/srv/dods/dod/maps/%s.bsp"
OUT = str(pathlib.Path(__file__).resolve().parents[1] / "waypoints-final")


def d3(a, b):
    return math.sqrt(sum((a[i] - b[i]) ** 2 for i in range(3)))


def offsets(b):
    version, count = struct.unpack_from("<ii", b, 80)
    off = 92 + (64 if version > 3 else 0)
    rec = []
    for _ in range(count):
        n = struct.unpack_from("<i", b, off + 21)[0]
        rec.append((off + 16, off + 25 + 4 * n))  # flags, area
        off += 25 + 4 * n + 8
    assert off == len(b), (off, len(b))
    return rec


def control_points(bsp):
    out = []
    for kv in ents(bsp):
        if kv.get("classname") != "dod_control_point":
            continue
        o = vec(kv)
        if o:
            out.append((kv.get("targetname") or "?", o,
                        int(kv.get("point_default_owner", "0") or 0)))
    return out


def process(mapname, verbose=True):
    path = SRC % mapname
    d = decode(path)
    b = open(path, "rb").read()
    rec = offsets(b)
    used = [w for w in d["wpts"] if w["used"]]
    if not used:
        return None
    caps = [w for w in used if w["flags"] & CAPPOINT]
    cps = control_points(BSP % mapname)
    newflags, newarea, log = {}, {}, []

    def usable(w):
        return not (w["flags"] & UNREACH) and not (w["flags"] & EXCLUDE)

    # resolve each CP's area from its own capture-point waypoint
    cps_order = cps
    for _pass in range(2):
      for name, o, owner in cps_order:
        if not caps:
            continue
        cap = min(caps, key=lambda w: d3(w["origin"], o))
        area = cap["area"]

        def area_of(w):
            return newarea.get(w["idx"], w["area"])

        def flag_of(w):
            return newflags.get(w["idx"], w["flags"])

        def near_set():
            return [w for w in used if area_of(w) == area and usable(w)
                    and d3(w["origin"], o) <= 450]

        ok = near_set()
        # 3) the flag's own area lacks defenders near it -- adopt neighbours
        #    (what the in-game "waypoint area" tool does), then tag them.
        if len(ok) < 2 or sum(1 for w in ok if flag_of(w) & DEFEND) < 2 \
                or not any(flag_of(w) & CROUCH for w in ok):
            foreign = [c for c in caps if d3(c["origin"], o) > 30
                       and min(d3(c["origin"], c2[1]) for c2 in cps_order) is not None]
            for w in sorted(used, key=lambda w: d3(w["origin"], o)):
                if d3(w["origin"], o) > 450:
                    break
                if not usable(w) or area_of(w) == area:
                    continue
                # never steal another flag's capture point
                if (w["flags"] & CAPPOINT) and min(d3(w["origin"], c[1]) for c in cps_order) < d3(w["origin"], o):
                    continue
                newarea[w["idx"]] = area
                log.append((w["idx"], "area->%d" % area, name))
                ok = near_set()
                if len(ok) >= 3 and sum(1 for x in ok if flag_of(x) & DEFEND) >= 2 \
                        and any(flag_of(x) & CROUCH for x in ok):
                    break
            ok = near_set()

        # 2) no / too few defenders
        have_crouch = any(flag_of(w) & CROUCH for w in ok)
        defenders = [w for w in ok if flag_of(w) & DEFEND]
        if len(defenders) < 2:
            cands = sorted([w for w in ok if usable(w)], key=lambda w: d3(w["origin"], o))
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
                if i == 0 and not have_crouch:
                    bits |= CROUCH
                    have_crouch = True
                newflags[w["idx"]] = newflags.get(w["idx"], w["flags"]) | bits
                log.append((w["idx"], "+".join(n for bit, n in FLAGS if bits & bit), name))
            defenders = picked

        # 2b) defenders exist but none crouches at the flag -- duck at least one
        if not have_crouch and defenders:
            nearest = sorted(defenders, key=lambda w: d3(w["origin"], o))[0]
            newflags[nearest["idx"]] = newflags.get(nearest["idx"], nearest["flags"]) | CROUCH
            log.append((nearest["idx"], "+CROUCH", name))
            have_crouch = True

        # report the resulting state
        if verbose:
            fin = [w for w in used if newarea.get(w["idx"], w["area"]) == area]
            nf = sum(1 for w in fin if (newflags.get(w["idx"], w["flags"]) & DEFEND))
            nc = sum(1 for w in fin if (newflags.get(w["idx"], w["flags"]) & CROUCH)
                     and d3(w["origin"], o) <= 500)
            print("   %-16s area=%d points=%3d defend=%2d crouch_near=%d" % (name, area, len(fin), nf, nc))

    if not newflags and not newarea:
        os.makedirs(OUT, exist_ok=True)
        dst = os.path.join(OUT, os.path.basename(path))
        open(dst, "wb").write(b)
        return dict(map=mapname, changes=0, log=[], out=dst)

    nb = bytearray(b)
    for idx, f in newflags.items():
        fo, _ = rec[idx]
        old = struct.unpack_from("<i", nb, fo)[0]
        assert old == d["wpts"][idx]["flags"], (mapname, idx)
        struct.pack_into("<i", nb, fo, f)
    for idx, a in newarea.items():
        _, ao = rec[idx]
        assert struct.unpack_from("<i", nb, ao)[0] == d["wpts"][idx]["area"]
        struct.pack_into("<i", nb, ao, a)
    os.makedirs(OUT, exist_ok=True)
    dst = os.path.join(OUT, os.path.basename(path))
    open(dst, "wb").write(nb)
    assert len(nb) == len(b)
    return dict(map=mapname, changes=len(newflags) + len(newarea), log=log, out=dst)


if __name__ == "__main__":
    total = 0
    for m in MAPS:
        print("== %s" % m)
        r = process(m)
        if r:
            total += r["changes"]
            print("   %d record(s) changed" % r["changes"])
    print("TOTAL %d" % total)
