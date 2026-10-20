#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
# Ship the multi-human reply-routing fix to a running server.
#
# What changed in twelveactors/bridge.py (daemon only):
#   * a reply now comes from a bot on the ASKER'S OWN TEAM. say_team is routed by
#     the engine, so a bot on the other side used to answer into chat the asker
#     never sees — with two humans on opposite teams it looked like being ignored.
#   * a bot name only counts as "addressed" as a WHOLE WORD: "frankly" no longer
#     addresses Frank and "johnny" no longer addresses John. An addressed line
#     skips the unprompted roll, so substring matches were quietly changing the
#     reply rate.
#
# No plugin build, no map change, no dods restart: only the conversation daemon
# restarts (about a second). Its cursors live on disk, so no line is replayed.
#
#   sudo bash install-reply-routing.sh
set -euo pipefail

SRC="${SRC:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
DEST=/opt/twelveactors/twelveactors/bridge.py
SVC=twelveactors.service

[ "$(id -u)" -eq 0 ] || { echo "run this with sudo" >&2; exit 1; }

echo "== [1/4] check source"
python3 -m py_compile "$SRC/twelveactors/bridge.py"
grep -q '_names_bot' "$SRC/twelveactors/bridge.py" || { echo "FAIL: source lacks the fix" >&2; exit 1; }
grep -q 'b\["team"\] == team' "$SRC/twelveactors/bridge.py" || { echo "FAIL: no team filter in source" >&2; exit 1; }
echo "ok: team filter and whole-word match present"

echo "== [2/4] back up and install"
backup="$DEST.bak.$(date +%Y%m%d-%H%M%S)"
cp -a "$DEST" "$backup"
install -o root -g root -m 644 "$SRC/twelveactors/bridge.py" "$DEST"
echo "backup: $backup"
sha256sum "$SRC/twelveactors/bridge.py" "$DEST"

echo "== [3/4] restart daemon"
systemctl restart "$SVC"
sleep 2
systemctl is-active "$SVC"

echo "== [4/4] verify"
journalctl -u "$SVC" --since '-30s' --no-pager | tail -4
printf 'healthz: '
curl -s --max-time 3 localhost:8377/healthz || echo "(no answer — check the journal above)"
echo
echo "done: replies are team-scoped and names match on word boundaries"
