#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
# Deploy the Twelve Actors build that turns the radio keys into chat events, then
# prove it works end to end from the server console.
# Run once:  sudo bash $HERE/install-radio-menu.sh
HERE=$(cd "$(dirname "$0")" && pwd)
set -u
SMX_SRC=$HERE/plugin/twelveactors.smx
SMX_DST=/srv/dods/dod/addons/sourcemod/plugins/twelveactors.smx
PY_SRC=$HERE/twelveactors/bridge.py
PY_DST=/opt/twelveactors/twelveactors/bridge.py
FIFO=/run/dods/console
DATA=/srv/dods/dod/addons/sourcemod/data/twelveactors

[ "$(id -u)" -eq 0 ] || { echo "must run as root: sudo bash $0"; exit 1; }
[ -f "$SMX_SRC" ] || { echo "missing $SMX_SRC"; exit 1; }
[ -f "$PY_SRC" ]  || { echo "missing $PY_SRC"; exit 1; }

echo "== 1. daemon: always answer a radio pick =="
install -o root -g root -m 0644 "$PY_SRC" "$PY_DST" || { echo "bridge install failed"; exit 1; }
systemctl restart twelveactors || { echo "daemon restart failed"; exit 1; }
sleep 2
systemctl is-active twelveactors

echo
echo "== 2. plugin: radio menu -> say event =="
install -o dod -g dod -m 0644 "$SMX_SRC" "$SMX_DST" || { echo "plugin install failed"; exit 1; }
echo "installed: $(md5sum "$SMX_DST" | cut -d' ' -f1)"

if [ ! -p "$FIFO" ]; then
  echo "warning: $FIFO missing - run: systemctl restart dods"
  exit 0
fi

in_before=$(wc -l < "$DATA/in.tsv" 2>/dev/null || echo 0)
out_before=$(wc -l < "$DATA/out.tsv" 2>/dev/null || echo 0)

printf 'sm plugins load twelveactors\n' > "$FIFO"; sleep 1
printf 'sm plugins reload twelveactors\n' > "$FIFO"; sleep 3
printf 'sm_ta_debug 1\n' > "$FIFO"; sleep 1

echo
echo "== 3. console test: radio item 15, 'I need ammo!' =="
printf 'sm_ta_radiosim 14\n' > "$FIFO"; sleep 4

in_after=$(wc -l < "$DATA/in.tsv" 2>/dev/null || echo 0)
out_after=$(wc -l < "$DATA/out.tsv" 2>/dev/null || echo 0)

echo
echo "--- inbound $in_before -> $in_after ---"
tail -n +$((in_before + 1)) "$DATA/in.tsv" 2>/dev/null | tail -4
echo "--- barks $out_before -> $out_after ---"
tail -n +$((out_before + 1)) "$DATA/out.tsv" 2>/dev/null | tail -4

echo
if [ "$in_after" -gt "$in_before" ] && [ "$out_after" -gt "$out_before" ]; then
  echo "PASS: radio pick became a say event and produced a bark."
  echo "In game: press C, V or B, then pick 1-6. C=orders V=replies B=tactical."
else
  echo "FAIL: no new events. Send this output back."
fi
