#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
"""Decode RCBot2 .rcw waypoint files (header v5) into structured data.

Format (from APGRoboCop/rcbot2 utils/RCBot2_meta/bot_waypoint.cpp):
  CWaypointHeader  : char[16] filetype 'RCBot2', char[64] mapname, int32 version,
                     int32 numWaypoints, int32 flags          -> 92 bytes
  CWaypointAuthorInfo: char[32] author, char[32] modifiedBy  -> 64 bytes (v>3)
  per waypoint (v>=3):
    float[3] origin, int32 aimYaw, int32 flags, bool used(1),
    int32 numPaths, int32 paths[numPaths], int32 area, float radius
"""
import struct, sys, os, json, math, glob

FLAGS = [
    (1 << 0, "JUMP"), (1 << 1, "CROUCH"), (1 << 2, "UNREACHABLE"), (1 << 3, "LADDER"),
    (1 << 4, "FLAG/RESCUE"), (1 << 5, "CAPPOINT/GOAL"), (1 << 6, "NOBLU/NOAXIS"),
    (1 << 7, "NORED/NOALLIES"), (1 << 8, "HEALTH"), (1 << 9, "OPENS_LATER"),
    (1 << 10, "ROCKETJUMP/BOMB_TO_OPEN/DOOR"), (1 << 11, "SNIPER"), (1 << 12, "AMMO"),
    (1 << 13, "RESUPPLY/BOMBS_HERE"), (1 << 14, "SENTRY/MACHINEGUN"), (1 << 15, "DOUBLEJUMP/PRONE"),
    (1 << 16, "TELE_ENTRANCE/ARMOR"), (1 << 17, "TELE_EXIT"), (1 << 18, "DEFEND"),
    (1 << 19, "AREAONLY"), (1 << 20, "ROUTE"), (1 << 21, "WAIT_GROUND"),
    (1 << 22, "NO_FLAG/COVER_RELOAD"), (1 << 23, "LIFT"), (1 << 24, "FLAGONLY"),
    (1 << 25, "FALL"), (1 << 26, "BREAKABLE"), (1 << 27, "SPRINT"),
    (1 << 28, "TELEPORT_CHEAT"), (1 << 29, "OWNER_ONLY"), (1 << 30, "USE"),
]


def decode(path):
    b = open(path, "rb").read()
    if b[:6] != b"RCBot2":
        raise ValueError("bad magic %r" % b[:6])
    mapname = b[16:80].split(b"\0")[0].decode("latin1")
    version, count, hflags = struct.unpack_from("<iii", b, 80)
    off = 92
    author = b""
    modifier = b""
    if version > 3:
        author = b[off:off + 32].split(b"\0")[0].decode("latin1")
        modifier = b[off + 32:off + 64].split(b"\0")[0].decode("latin1")
        off += 64
    wpts = []
    for i in range(count):
        ox, oy, oz = struct.unpack_from("<fff", b, off)
        yaw, flags, used = struct.unpack_from("<iiB", b, off + 12)
        n = struct.unpack_from("<i", b, off + 21)[0]
        if n < 0 or n > 64:
            raise ValueError("bogus path count %d at wpt %d (offset %d)" % (n, i, off))
        paths = list(struct.unpack_from("<%di" % n, b, off + 25)) if n else []
        p = off + 25 + 4 * n
        area = struct.unpack_from("<i", b, p)[0]
        radius = struct.unpack_from("<f", b, p + 4)[0]
        off = p + 8
        wpts.append(dict(idx=i, origin=(ox, oy, oz), yaw=yaw, flags=flags,
                         used=bool(used), paths=paths, area=area, radius=radius))
    return dict(file=path, mapname=mapname, version=version, count=count,
                hflags=hflags, author=author, modifier=modifier, wpts=wpts,
                size=len(b), trailing=len(b) - off)


def flag_names(f):
    return [n for bit, n in FLAGS if f & bit]


def summarize(d):
    used = [w for w in d["wpts"] if w["used"]]
    hist = {}
    for w in used:
        for bit, name in FLAGS:
            if w["flags"] & bit:
                hist[name] = hist.get(name, 0) + 1
    areas = {}
    for w in used:
        areas[w["area"]] = areas.get(w["area"], 0) + 1
    withpaths = sum(1 for w in used if w["paths"])
    badrefs = sum(1 for w in used for p in w["paths"] if p >= d["count"] or p == w["idx"])
    dupe_paths = sum(1 for w in used if len(set(w["paths"])) != len(w["paths"]))
    # neighbour spacing
    near = far = 0
    for i, w in enumerate(used):
        best = 1e9
        for j, v in enumerate(used):
            if i == j:
                continue
            dd = (w["origin"][0] - v["origin"][0]) ** 2 + (w["origin"][1] - v["origin"][1]) ** 2 + (w["origin"][2] - v["origin"][2]) ** 2
            if dd < best:
                best = dd
                if best < 8 * 8:
                    break
        best = math.sqrt(best)
        if best < 20:
            near += 1
        if best > 300:
            far += 1
    return dict(map=d["mapname"], file=os.path.basename(d["file"]), version=d["version"],
                count=d["count"], used=len(used), size=d["size"], trailing=d["trailing"],
                hflags=d["hflags"], author=d["author"], modifier=d["modifier"],
                flags=hist, areas=len(areas), area0=areas.get(0, 0),
                withpaths=withpaths, badrefs=badrefs, dupe_paths=dupe_paths,
                clumped=near, isolated=far,
                radius=round(sum(w["radius"] for w in used) / max(1, len(used)), 2))


def main():
    args = sys.argv[1:]
    as_json = "--json" in args
    args = [a for a in args if a != "--json"]
    files = []
    for a in args:
        files.extend(sorted(glob.glob(os.path.join(a, "*.rcw"))) if os.path.isdir(a) else [a])
    out = []
    for f in files:
        try:
            d = decode(f)
        except Exception as e:
            print("ERR %s: %s" % (f, e), file=sys.stderr)
            continue
        out.append(d)
    if as_json:
        print(json.dumps(out))
        return
    print("%-14s %5s %5s %8s %4s %5s %5s %4s %4s %4s %6s  %s" % (
        "map", "count", "used", "size", "ver", "path", "clump", "iso", "bad", "area", "radius", "author>modifier"))
    for d in out:
        s = summarize(d)
        print("%-14s %5d %5d %8d %4d %5d %5d %4d %4d %4d %6.1f  %s > %s" % (
            s["map"], s["count"], s["used"], s["size"], s["version"],
            s["withpaths"], s["clumped"], s["isolated"], s["badrefs"], s["areas"],
            s["radius"], s["author"], s["modifier"]))
        print("    flags:", ", ".join("%s=%d" % kv for kv in sorted(s["flags"].items(), key=lambda kv: -kv[1])) or "none")
        if s["trailing"]:
            print("    WARN trailing bytes:", s["trailing"])


if __name__ == "__main__":
    main()
