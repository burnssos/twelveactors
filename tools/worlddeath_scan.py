#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
"""Classify world suicides in a captured dods log.

Class-selection suicides land within a second of 'joined team'/'changed role'
and carry no victim position. Anything else is a real out-of-world death
(fell through geometry, trigger_hurt pit, etc.) and is what we care about.
"""
import re, sys, collections

path = sys.argv[1]
lines = []
for raw in open(path, "rb"):
    s = raw.decode("utf-8", "replace").replace("\x00", "").strip()
    if not s:
        continue
    lines.append(s)

ts = re.compile(r"(\d\d/\d\d/\d{4} - \d\d:\d\d:\d\d)")
suicide = re.compile(r'"(.+?)<(\d+)><BOT><(?:(\w+)>)?\" committed suicide with "(.*?)"')
join = re.compile(r'"(.+?)<(\d+)><BOT>')

events = []
for i, s in enumerate(lines):
    m = suicide.search(s)
    if not m:
        continue
    name, uid, team, weapon = m.group(1), m.group(2), m.group(3) or "-", m.group(4)
    window = " ".join(lines[max(0, i - 4):i])
    near_join = ("joined team" in window and ("<%s>" % uid) in window) or \
                ("changed role" in window and ("<%s>" % uid) in window) or \
                ("entered the game" in window and ("<%s>" % uid) in window)
    events.append((i, ts.search(s).group(1) if ts.search(s) else "?", name, uid, team, weapon, near_join))

classsel = [e for e in events if e[6]]
other = [e for e in events if not e[6]]

print("total world suicides : %d" % len(events))
print("class-selection      : %d" % len(classsel))
print("other                : %d" % len(other))

byw = collections.Counter(e[5] for e in other)
print("weapons on 'other'   :", dict(byw))
byteam = collections.Counter(e[4] for e in other)
print("teams on 'other'     :", dict(byteam))

if other:
    print("\n-- non-class-selection world deaths --")
    for i, t, name, uid, team, weapon, _ in other:
        print("%-24s %-16s uid=%-4s %-7s weapon=%s" % (t, name, uid, team, weapon))
        print("   context: %s" % lines[max(0, i - 1)][-120:])
