#!/bin/sh
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
# Reserve 12 of the 24 slots for the bot cast.
#
# Installs:
#   ta_bots_rcbot2.smx (v2) — bot quota is re-budgeted every 10 s as
#       target + live humans, so a human joining can never strangle the roster.
#   ta_humancap.smx (new)       — rejects the 13th human at connect time, so
#       bots always have their 12 slots and are never displaced.
# Sets config.ini to min_bots 0 / max_bots 24 so a map change or restart cannot
# restore the old cap of 12 that caused the churn.
HERE=$(cd "$(dirname "$0")" && pwd)
set -e
. "$(cd "$(dirname "$0")" && pwd)/tools/rcbot-preflight.sh"

TA_REPO="$HERE"; . "$HERE/tools/compile.sh"

PLUGDIR=/srv/dods/dod/addons/sourcemod/plugins
CFG=/srv/dods/dod/addons/rcbot2/config/config.ini
FIFO=/run/dods/console
TS=$(date +%Y%m%d-%H%M%S)
BOTS=$(ta_compile ta_bots_rcbot2) || exit 1
CAP=$(ta_compile ta_humancap) || exit 1

for f in "$BOTS" "$CAP"; do
    [ -f "$f" ] || { echo "missing $f"; exit 1; }
done

# 1. backups
cp -a "$PLUGDIR/ta_bots_rcbot2.smx" "$PLUGDIR/ta_bots_rcbot2.smx.bak.$TS"
cp -a "$CFG" "$CFG.bak.$TS"
if [ -f "$PLUGDIR/ta_humancap.smx" ]; then
    cp -a "$PLUGDIR/ta_humancap.smx" "$PLUGDIR/ta_humancap.smx.bak.$TS"
fi
echo "[1/5] backups tagged $TS"

# 2. install plugins
install -o dod -g dod -m 644 "$BOTS" "$PLUGDIR/ta_bots_rcbot2.smx"
install -o dod -g dod -m 644 "$CAP"  "$PLUGDIR/ta_humancap.smx"
echo "[2/5] installed ta_bots_rcbot2.smx + ta_humancap.smx"

# 3. persist the quota settings
ta_rcbot_bounds "$CFG" 24 warn
grep -n '^rcbotd config \(min\|max\)_bots' "$CFG"

# 4. load / reload
if [ -p "$FIFO" ]; then
    printf 'sm plugins reload ta_bots_rcbot2\n' > "$FIFO"
    sleep 3
    printf 'sm plugins load ta_humancap\n' > "$FIFO"
    sleep 2
    printf 'sm_ta_bots\n' > "$FIFO"
    sleep 2
    printf 'sm_ta_humancap\n' > "$FIFO"
    echo "[4/5] reloaded over console fifo"
else
    echo "[4/5] WARN: $FIFO missing; plugins load on next map change"
fi

# 5. watch 30 s
sleep 30
echo "[5/5] last 30s:"
echo -n "  kicks:        "; journalctl -u dods --since "-32s" --no-pager | grep -c "Kicked from server" || true
echo -n "  max_bots ref: "; journalctl -u dods --since "-32s" --no-pager | grep -c "max_bots reached" || true
journalctl -u dods --since "-40s" --no-pager | grep -E "\[ta_humancap\]|\[twelveactors\]|max_bots set" | tail -6 || true
echo "done"
