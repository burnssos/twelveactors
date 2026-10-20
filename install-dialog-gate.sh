#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
# Install the human-presence gate: bot dialog costs nothing while no human is in
# game, and nothing is queued for the next person who joins.
#
#   sudo $HERE/install-dialog-gate.sh
#
# Two independent halves, both installed here:
#   1. twelveactors.smx   — Emit() stops writing in.tsv when CountHumans() == 0;
#                      Timer_Poll keeps advancing last_out without playing, so
#                      no backlog is replayed on join. Cvar:
#                      sm_ta_require_human (default 1).
#   2. /opt/twelveactors  — bridge.py refuses a model turn for an ambient event
#                      (bot death / round start) unless roster.tsv lists a
#                      human. A say/radio/voice from a non-bot name is allowed
#                      even with a stale roster, so a player who joins and asks
#                      for ammo in the first 3 s is not dropped. config key:
#                      dialog_requires_human (defaults to true when absent).
#
# Rollback: the previous .smx is kept as plugins/twelveactors.smx.bak.<tag>, and
# /opt/twelveactors/twelveactors can be restored from git or a copy of the old tree.
HERE=$(cd "$(dirname "$0")" && pwd)
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run with sudo: sudo $0" >&2; exit 1; }

SRC=$HERE
SM=/srv/dods/dod/addons/sourcemod
DATA=$SM/data/twelveactors
PLUGDIR=$SM/plugins
FIFO=/run/dods/console
SPCOMP=$SM/scripting/spcomp
INCLUDE=$SM/scripting/include
TS=$(date +%Y%m%d-%H%M%S)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/tagate.XXXXXX")
trap 'rm -rf "$BUILD"' EXIT

echo "[1/6] compile twelveactors.sp with the server's own spcomp"
cp "$SRC/plugin/twelveactors.sp" "$BUILD/"
( cd "$BUILD" && "$SPCOMP" -i"$INCLUDE" twelveactors.sp >/dev/null )
[ -s "$BUILD/twelveactors.smx" ] || { echo "compile failed" >&2; exit 1; }
echo "      ok: $(stat -c %s "$BUILD/twelveactors.smx") bytes"

echo "[2/6] install plugin (backup tag $TS)"
cp -a "$PLUGDIR/twelveactors.smx" "$PLUGDIR/twelveactors.smx.bak.$TS"
install -o dod -g dod -m 644 "$BUILD/twelveactors.smx" "$PLUGDIR/twelveactors.smx"
install -o root -g root -m 644 "$BUILD/twelveactors.sp" "$SM/scripting/twelveactors.sp"

echo "[3/6] install daemon to /opt/twelveactors"
rm -rf /opt/twelveactors/twelveactors
cp -r "$SRC/twelveactors" /opt/twelveactors/
find /opt/twelveactors -name __pycache__ -type d -exec rm -rf {} +
chown -R root:root /opt/twelveactors
python3 -m py_compile /opt/twelveactors/twelveactors/bridge.py /opt/twelveactors/twelveactors/server.py
echo "      ok: bridge.py + server.py compile"

echo "[4/6] restart the daemon"
systemctl restart twelveactors.service
sleep 2
systemctl is-active --quiet twelveactors.service || {
    echo "twelveactors.service failed to start:" >&2
    journalctl -u twelveactors -n 20 --no-pager >&2
    exit 1
}

echo "[5/6] reload the plugin (no map change needed)"
if [ -p "$FIFO" ]; then
    printf 'sm plugins reload twelveactors\n' > "$FIFO"
    sleep 3
else
    echo "      WARN: $FIFO missing; plugin loads on the next map change"
fi

echo "[6/6] verify both halves"
RC=$(grep -oP '(?<=rcon_password ")[^"]+' /srv/dods/dod/cfg/server.cfg | head -1)
RCON="python3 $SRC/tools/rcon2.py $RC"
$RCON 'sm_ta_status' 2>/dev/null | grep -m1 '\[twelveactors\] enable' || true

echo
echo -n "daemon health: "
curl -s --max-time 5 http://127.0.0.1:8377/healthz || echo "(no answer)"
echo

HUMANS=$(curl -s --max-time 5 http://127.0.0.1:8377/healthz \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("humans", -1))' 2>/dev/null || echo -1)
SIZE_BEFORE=$(stat -c %s "$DATA/in.tsv" 2>/dev/null || echo 0)
GATED_BEFORE=$(curl -s --max-time 5 http://127.0.0.1:8377/healthz \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["bridge"].get("gated",0))' 2>/dev/null || echo 0)

if [ "$HUMANS" = "0" ]; then
    echo "no human connected -> watching in.tsv for 15 s; it must not grow"
    sleep 15
    SIZE_AFTER=$(stat -c %s "$DATA/in.tsv" 2>/dev/null || echo 0)
    GATED_AFTER=$(curl -s --max-time 5 http://127.0.0.1:8377/healthz \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["bridge"].get("gated",0))' 2>/dev/null || echo 0)
    echo "  in.tsv bytes : $SIZE_BEFORE -> $SIZE_AFTER   (equal = plugin gate working)"
    echo "  daemon gated : $GATED_BEFORE -> $GATED_AFTER (climbing = daemon gate working)"
    echo "  dialog_open  : $(curl -s --max-time 5 http://127.0.0.1:8377/healthz | python3 -c 'import json,sys; print(json.load(sys.stdin).get("dialog_open"))')"
else
    echo "a human is connected (humans=$HUMANS), so both gates are open by design."
    echo "  in.tsv bytes now: $SIZE_BEFORE  (should keep growing while you play)"
    echo "  dialog_open     : $(curl -s --max-time 5 http://127.0.0.1:8377/healthz | python3 -c 'import json,sys; print(json.load(sys.stdin).get("dialog_open"))')"
    echo
    echo "  disconnect and run this to watch the gate close:"
    echo "    curl -s localhost:8377/healthz   # humans:0, dialog_open:false"
    echo "    stat -c %s $DATA/in.tsv; sleep 15; stat -c %s $DATA/in.tsv"
fi

echo
echo "disable the plugin half at runtime with:  sm_ta_require_human 0"
echo "disable the daemon half by adding \"dialog_requires_human\": false to $DATA/config.json"
echo "rollback: cp -a $PLUGDIR/twelveactors.smx.bak.$TS $PLUGDIR/twelveactors.smx  (then reload)"
