#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
# Install the improved RCBot2 waypoint files for the nine official DoD:S maps.
# Flag-bit changes only: no waypoint was moved, added or removed.
HERE=$(cd "$(dirname "$0")" && pwd)
set -euo pipefail

SRC="$HERE/waypoints-final"
DST="/srv/dods/dod/addons/rcbot2/waypoints/dod"
STAMP="$(date +%Y%m%d-%H%M%S)"
BK="/srv/dods/backups/waypoints-$STAMP"

[ -d "$SRC" ] || { echo "FAIL: $SRC missing"; exit 1; }
[ -d "$DST" ] || { echo "FAIL: $DST missing"; exit 1; }

mkdir -p "$BK"
chown dod:dod "$BK" 2>/dev/null || true

n=0
for f in "$SRC"/*.rcw; do
  b="$(basename "$f")"
  [ -f "$DST/$b" ] || { echo "FAIL: no existing $DST/$b"; exit 1; }
  cp -a "$DST/$b" "$BK/$b"
  install -o dod -g dod -m 644 "$f" "$DST/$b"
  n=$((n+1))
done

echo "backup: $BK ($n files)"
fail=0
for f in "$SRC"/*.rcw; do
  b="$(basename "$f")"
  a="$(md5sum "$f" | cut -d' ' -f1)"
  c="$(md5sum "$DST/$b" | cut -d' ' -f1)"
  if [ "$a" != "$c" ]; then echo "FAIL: md5 mismatch $b"; fail=1; fi
done
[ "$fail" -eq 0 ] || exit 1

echo
echo "installed:"
ls -l "$DST" | grep -E 'dod_(anzio|argentan|avalanche|colmar|donner|flash|jagd|kalt|palermo)\.rcw'
echo
echo "PASS: $n waypoint files installed, all md5-verified."
echo "Waypoints load at the next map change (this alpha8 build refuses 'rcbotd waypoint load' on a dedicated server)."
