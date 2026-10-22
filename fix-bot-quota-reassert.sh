#!/bin/sh
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
# Fix the 24-bot / kick-per-pass churn caused by config.ini landing after the
# bot module starts.
#
# What changed in the module (plugin/ta_bots_rcbot2.sp):
#   ApplyTarget() used to return early when its computed cap had not changed
#   since the last call, so a config.ini exec that ran *after* the plugin loaded
#   (max_bots 24) was never corrected: RCBot2 filled all 24 slots, the module
#   then saw 12 unvoiced bots and kicked one every 10 s, RCBot2 re-added it,
#   forever. It now re-asserts min_bots 0 / max_bots <12+humans> every pass.
#   Timer_Supervise() also counted clients rather than personas, so a duplicated
#   profile ("John" twice, "Thomas" missing) read as a full roster; a duplicate
#   is now treated as a stray and renamed onto the missing persona.
#
# Also pins config.ini to max_bots 12 so the one second between map start and
# the first supervisor pass cannot add a pile of bots.
#
#   sudo sh $HERE/fix-bot-quota-reassert.sh
HERE=$(cd "$(dirname "$0")" && pwd)
set -e
. "$(cd "$(dirname "$0")" && pwd)/tools/rcbot-preflight.sh"

TA_REPO="$HERE"; . "$HERE/tools/compile.sh"

[ "$(id -u)" = "0" ] || { echo "run with sudo"; exit 1; }

PLUGDIR=/srv/dods/dod/addons/sourcemod/plugins
RCDIR=/srv/dods/dod/addons/rcbot2/config
FIFO=/run/dods/console
ta_compile ta_bots_rcbot2 || exit 1
SRC=$TA_SMX
TS=$(date +%Y%m%d-%H%M%S)

[ -f "$SRC" ] || { echo "missing $SRC"; exit 1; }

echo "[1/5] backups (tag $TS)"
cp -a "$PLUGDIR/ta_bots_rcbot2.smx" "$PLUGDIR/ta_bots_rcbot2.smx.bak.$TS"
cp -a "$RCDIR/config.ini" "$RCDIR/config.ini.bak.$TS"

echo "[2/5] installing module"
install -o dod -g dod -m 644 "$SRC" "$PLUGDIR/ta_bots_rcbot2.smx"

echo "[3/5] config.ini max_bots 12 (startup state)"
ta_rcbot_bounds "$RCDIR/config.ini" 12 warn
grep -n 'rcbotd config \(min\|max\)_bots' "$RCDIR/config.ini"

echo "[4/5] reloading module"
if [ -p "$FIFO" ]; then
    printf 'sm plugins reload ta_bots_rcbot2\n' > "$FIFO"
    sleep 3
    printf 'sm_ta_bots_enable 1\n' > "$FIFO"
    sleep 2
else
    echo "  WARN: $FIFO missing; takes effect on next map change"
fi

echo "[5/5] watching 45 s for churn"
BEFORE=$(journalctl -u dods --since "-1s" --no-pager | wc -l)
sleep 45
echo
echo "  module status:"
printf 'sm_ta_bots\n' > "$FIFO" 2>/dev/null || true
printf 'status\n' > "$FIFO" 2>/dev/null || true
sleep 3
echo "  kicks / refusals in the last 50 s:"
journalctl -u dods --since "-50s" --no-pager \
    | grep -cE 'removed unvoiced|no free persona|Can.t create bot|Kicked from server' || true
echo "  quota re-assert lines (new module only logs changes):"
journalctl -u dods --since "-50s" --no-pager | grep -E '\[twelveactors\] RCBot2 quota|module attached' | tail -3 || true
echo
echo "done. Live check:  rcon status   -> should read 12 bots (+ humans) and 24 max"
echo "Rollback: cp -a $PLUGDIR/ta_bots_rcbot2.smx.bak.$TS $PLUGDIR/ta_bots_rcbot2.smx"
echo "          cp -a $RCDIR/config.ini.bak.$TS $RCDIR/config.ini   then 'sm plugins reload ta_bots_rcbot2'"
