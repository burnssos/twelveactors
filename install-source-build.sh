#!/bin/bash
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
# Install the plugin built from the fixed source (plugin/twelveactors.sp), then show
# whether the poll timer is alive. Source fixes included:
#   1. StartTimers() rebuilds the 0.4s poll + 3s roster timers on plugin start
#      AND on every map start (a repeat timer with TIMER_FLAG_NO_MAPCHANGE dies
#      at changelevel; before this, barks were written to out.tsv and never read)
#   2. Timer_Roster acts as a watchdog and rebuilds the poll timer if it is
#      ever null, so a missed hook cannot silence playback permanently.
HERE=$(cd "$(dirname "$0")" && pwd)
# pipefail matters here: spcomp below is piped into `tail`, and without it the
# pipeline's status is tail's, which succeeds even when the compile failed. The
# install step would then ship whatever .smx was already on disk — a stale
# plugin, silently. Every other build script in this tree already sets it.
set -eo pipefail
SRC=$HERE/plugin
DST=/srv/dods/dod/addons/sourcemod/plugins/twelveactors.smx
PW=$(grep -oP '(?<=rcon_password ")[^"]+' /srv/dods/dod/cfg/server.cfg)

echo "== building from source =="
SM=/srv/dods/dod/addons/sourcemod/scripting
"$SM/spcomp" -i "$SM/include" -o "$SRC/twelveactors.smx" "$SRC/twelveactors.sp" | tail -4

echo "== installing =="
install -o dod -g dod -m 644 "$SRC/twelveactors.smx" "$DST"
echo "installed $(stat -c%s "$DST") bytes  md5 $(md5sum "$DST" | cut -d' ' -f1)"

cd $HERE
python3 tools/rcon2.py "$PW" "sm plugins reload twelveactors" "sm_ta_status" | tail -5

echo
echo "== source markers present =="
grep -c "StartTimers\|rebuilt by roster watchdog" "$SRC/twelveactors.sp"
echo "PASS: fix is in the source and the server is running that build."
