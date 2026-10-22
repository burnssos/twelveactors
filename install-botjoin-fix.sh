#!/bin/sh
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
# Fix the RCBot2 "ERRORNAME committed suicide" spam on the DoD:S server.
#
# What it installs (both verified on a sandbox server on port 27016):
#   1. ta_botjoin.smx            — keeps teamless fake clients in LIFE_DEAD right
#      after their connect spawn, so the team change cannot kill a live body.
#      Result: no death notice, so clients no longer print ERRORNAME suicided.
#   2. ta_bots_rcbot2.smx    — renames a stray RCBot2 profile onto a free
#      persona instead of kicking it (each kick used to cost a death notice and
#      sent RCBot2 straight back into its add path -> add/kick churn).
#
# Run as root:  sudo $HERE/install-botjoin-fix.sh
HERE=$(cd "$(dirname "$0")" && pwd)
set -e

TA_REPO="$HERE"; . "$HERE/tools/compile.sh"

[ "$(id -u)" = "0" ] || { echo "run with sudo"; exit 1; }

PLUGDIR=/srv/dods/dod/addons/sourcemod/plugins
FIFO=/run/dods/console
TS=$(date +%Y%m%d-%H%M%S)
ta_compile ta_botjoin || exit 1
JOIN=$TA_SMX
ta_compile ta_bots_rcbot2 || exit 1
BOTS=$TA_SMX

for f in "$JOIN" "$BOTS"; do
    [ -f "$f" ] || { echo "missing $f"; exit 1; }
done

echo "[1/4] backups (tag $TS)"
cp -a "$PLUGDIR/ta_bots_rcbot2.smx" "$PLUGDIR/ta_bots_rcbot2.smx.bak.$TS"
if [ -f "$PLUGDIR/ta_botjoin.smx" ]; then
    cp -a "$PLUGDIR/ta_botjoin.smx" "$PLUGDIR/ta_botjoin.smx.bak.$TS"
fi

echo "[2/4] installing plugins"
install -o dod -g dod -m 644 "$BOTS" "$PLUGDIR/ta_bots_rcbot2.smx"
install -o dod -g dod -m 644 "$JOIN" "$PLUGDIR/ta_botjoin.smx"

echo "[3/4] reloading over the console FIFO"
if [ -p "$FIFO" ]; then
    printf 'sm plugins reload ta_bots_rcbot2\n' > "$FIFO"
    sleep 2
    printf 'sm plugins load ta_botjoin\n' > "$FIFO"
    sleep 3
    printf 'sm_ta_bots\n' > "$FIFO"
    sleep 2
else
    echo "  WARN: $FIFO missing; plugins load on next map change"
fi

echo "[4/4] verifying (30 s)"
sleep 30
echo -n "  join suicides in the last 40s : "
journalctl -u dods --since "-40s" --no-pager | grep -c 'committed suicide with "world"' || true
echo -n "  bot module lines              : "
journalctl -u dods --since "-40s" --no-pager | grep -E "\[twelveactors\] (renamed|RcBot2 quota|bot module)" | tail -3 || true
echo -n "  plugin loaded                 : "
journalctl -u dods --since "-40s" --no-pager | grep -c "Twelve Actors Bot Join Fix" || true
echo
echo "done. To check later:"
echo "  journalctl -u dods --since '-10min' | grep 'committed suicide with \"world\"'   # expect nothing"
echo "Rollback: cp -a $PLUGDIR/*.bak.$TS $PLUGDIR/  (drop the .bak suffix) and reload"
