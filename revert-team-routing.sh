#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
# Revert the unnamed say_team routing change on a running server.
#
#   sudo ./revert-team-routing.sh
#
# Puts back the state that existed before install-team-routing.sh:
#
#   plugin/twelveactors.sp   back to the seven-field say line (no channel, no
#                       nearest-bot, no round phase). Two extra events that only
#                       existed to track the phase are gone with it.
#   twelveactors/bridge.py   back to random routing of unanswered chat, with
#                       unprompted_chance deciding whether anyone replies.
#   twelveactors/brain.py    back to classifying inside respond(); the precheck()
#                       split existed so a squad burst could share one verdict.
#
# Ordering: the plugin is reloaded first, so the daemon never sees a line shaped
# for code it no longer has. The old daemon reads seven fields and treats an
# eighth "1" as a radio pick, so any 10-field line still sitting in in.tsv is
# parsed harmlessly (channel "team"/"all" simply is not "1").
#
# The daemon backup from the routing install is left in place; this takes its
# own backup too.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run with sudo: sudo $0" >&2; exit 1; }

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GAME="${GAME:-/srv/dods}"
SM="$GAME/dod/addons/sourcemod"
PLUGDIR="$SM/plugins"
DATA="$SM/data/twelveactors"
FIFO="${FIFO:-/run/dods/console}"
SPCOMP="$SM/scripting/spcomp"
INCLUDE="$SM/scripting/include"
TS=$(date +%Y%m%d-%H%M%S)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/tarevert.XXXXXX")
trap 'rm -rf "$BUILD"' EXIT

echo "== [1/5] check source is actually the pre-routing tree"
python3 -m py_compile "$SRC/twelveactors/bridge.py" "$SRC/twelveactors/brain.py"
if grep -qE '_answer_team_chat|team_chat_route|_last_responder' "$SRC/twelveactors/bridge.py"; then
  echo "FAIL: bridge.py still has routing" >&2; exit 1
fi
if grep -qE 'sm_ta_team_route|NearestBot|IsOpenPhase' "$SRC/plugin/twelveactors.sp"; then
  echo "FAIL: twelveactors.sp still has routing" >&2; exit 1
fi
if grep -q 'def precheck' "$SRC/twelveactors/brain.py"; then
  echo "FAIL: brain.py still has the precheck split" >&2; exit 1
fi
echo "ok: daemon and plugin are the pre-routing versions"

echo "== [2/5] compile twelveactors.sp with the server's spcomp"
[ -x "$SPCOMP" ] || { echo "missing $SPCOMP" >&2; exit 1; }
cp "$SRC/plugin/twelveactors.sp" "$BUILD/"
( cd "$BUILD" && "$SPCOMP" -i"$INCLUDE" twelveactors.sp >/dev/null )
[ -s "$BUILD/twelveactors.smx" ] || { echo "compile failed" >&2; exit 1; }
echo "      core $(stat -c %s "$BUILD/twelveactors.smx") bytes"

echo "== [3/5] install the plugin (backup .bak.$TS)"
install -d -o dod -g dod -m 755 "$PLUGDIR"
if [ -f "$PLUGDIR/twelveactors.smx" ]; then
  cp -a "$PLUGDIR/twelveactors.smx" "$PLUGDIR/twelveactors.smx.bak.$TS"
fi
install -o dod -g dod -m 644 "$BUILD/twelveactors.smx" "$PLUGDIR/twelveactors.smx"
install -o root -g root -m 644 "$BUILD/twelveactors.sp" "$SM/scripting/twelveactors.sp"

echo "== [4/5] reload the plugin, then install and restart the daemon"
if [ -p "$FIFO" ]; then
  printf 'sm plugins reload twelveactors\n' > "$FIFO"
  sleep 3
else
  echo "      WARN: $FIFO missing; the old plugin loads on the next map change"
fi

install -d -o root -g root -m 755 /opt/twelveactors
if [ -d /opt/twelveactors/twelveactors ]; then
  cp -a /opt/twelveactors/twelveactors "/opt/twelveactors/twelveactors.bak.$TS"
fi
rm -rf /opt/twelveactors/twelveactors
cp -r "$SRC/twelveactors" /opt/twelveactors/
find /opt/twelveactors/twelveactors -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null || true
chown -R root:root /opt/twelveactors/twelveactors
chmod -R a+rX /opt/twelveactors/twelveactors
sha256sum "$SRC/twelveactors/bridge.py" /opt/twelveactors/twelveactors/bridge.py \
          "$SRC/twelveactors/brain.py"  /opt/twelveactors/twelveactors/brain.py

systemctl restart twelveactors.service
sleep 2
systemctl is-active twelveactors.service

echo "== [5/5] verify"
printf 'healthz: '
curl -s --max-time 3 localhost:8377/healthz || echo "(no answer — journalctl -u twelveactors -n 20)"
echo
journalctl -u twelveactors.service --since '-30s' --no-pager | tail -3
LOG="$SM/logs/L$(date +%Y%m%d).log"
if [ -f "$LOG" ]; then
  echo "      recent SourceMod log lines:"
  grep -E "\[twelveactors\] (Loaded|precached|voice tuning)|error" "$LOG" 2>/dev/null | tail -3 | sed 's/^/        /'
fi

# A stale convar in memory is harmless, but say so, because it is the one thing
# that would make the old plugin look like the new one.
cat <<EOF

What you should see:
  sm_ta_status   -> no team_route= field
  healthz         -> bridge stats without a "routed" counter

Live tuning that still applies (unchanged by this revert):
  unprompted_chance             in data/twelveactors/config.json

If sm_ta_team_route still answers a value, it is only because the plugin
has not reloaded yet (no map change and the FIFO was unavailable); the setting
then does nothing the old code reads.

rollback of this rollback:
  cp -a $PLUGDIR/twelveactors.smx.bak.$TS $PLUGDIR/twelveactors.smx
  cp -a /opt/twelveactors/twelveactors.bak.$TS /opt/twelveactors/twelveactors
  sudo systemctl restart twelveactors.service
  echo "sm plugins reload twelveactors" > $FIFO
EOF
