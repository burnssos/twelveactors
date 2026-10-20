#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
"""Parse the entity lump of a Source .bsp and report DoD:S gameplay entities."""
import struct, sys, os, re, glob, json

INTEREST = {
    "info_player_allies", "info_player_axis", "info_player_start",
    "dod_capture_area", "dod_objective", "dod_control_point", "dod_flag",
    "func_capture_area", "dod_bomb_target", "func_bomb_target",
    "item_health", "item_ammo", "ammo_", "weapon_",
}


def lump(path, idx):
    b = open(path, "rb").read()
    ident, ver = struct.unpack_from("<ii", b, 0)
    if ident != 0x50534256:  # VBSP
        raise ValueError("not a bsp: %08x" % ident)
    off, ln = struct.unpack_from("<ii", b, 8 + 16 * idx)
    return b[off:off + ln], ver


def ents(path):
    data, ver = lump(path, 0)
    s = data.decode("latin1")
    out = []
    for m in re.finditer(r"\{([^{}]*)\}", s):
        body = m.group(1)
        kv = dict(re.findall(r'"([^"]+)"\s+"([^"]*)"', body))
        if kv:
            out.append(kv)
    return out


def vec(kv, key="origin"):
    v = kv.get(key)
    if not v:
        return None
    try:
        return tuple(float(x) for x in v.split()[:3])
    except ValueError:
        return None


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return
    for p in args:
        e = ents(p)
        print("== %s  (%d entities)" % (os.path.basename(p), len(e)))
        cls = {}
        for kv in e:
            cls[kv.get("classname", "?")] = cls.get(kv.get("classname", "?"), 0) + 1
        interesting = {k: v for k, v in cls.items()
                       if k in INTEREST or k.startswith(("dod_", "func_capture", "item_", "ammo_", "weapon_"))}
        print("   ", ", ".join("%s=%d" % kv for kv in sorted(interesting.items())))
        for kv in e:
            c = kv.get("classname", "")
            if c in ("dod_capture_area", "dod_objective", "dod_control_point", "dod_flag", "func_capture_area"):
                o = vec(kv)
                keys = {k: v for k, v in kv.items() if k not in ("origin", "classname", "angles", "hammerid")}
                print("    %-20s %-46s %s" % (c, str(o), json.dumps(keys)[:160]))


if __name__ == "__main__":
    main()
