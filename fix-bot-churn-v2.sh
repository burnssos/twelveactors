#!/bin/sh
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
# Fix RCBot2 <-> twelveactors bot module roster churn.
#
# Root cause (measured live, dod_donner, 1 human):
#   RCBot2's "rcbotd config max_bots" is a TOTAL CLIENT cap, not a bot cap.
#   The twelveactors bot module asked for 12 bots but wrote max_bots 12, so with one
#   human connected only 11 bots fit: every 10 s the module issued "rcbotd
#   addbot", RCBot2 logged "ERROR: Can't create bot, max_bots reached" and
#   kicked a bot to hold the cap. Result: ~1 kick + 1 rejoin every 10 s.
#   Giving headroom instead (max_bots 14) let RCBot2 add its own 13th profile
#   ("moe"), which is not in voiced.txt, so the module kicked that every 10 s.
#
# Fix: the module now budgets humans into the cap (max_bots = target + humans)
#   and re-applies it whenever the human count changes, so the cap always lands
#   exactly on the cast with no headroom for unvoiced profiles.
#
# Verified live before install: max_bots 13 with 1 human -> 12 voiced bots, zero
# kicks over 90 s.
HERE=$(cd "$(dirname "$0")" && pwd)
set -e

SMX_SRC=$HERE/build/ta_bots_rcbot2.smx
SMX_DST=/srv/dods/dod/addons/sourcemod/plugins/ta_bots_rcbot2.smx
CFG=/srv/dods/dod/addons/rcbot2/config/config.ini
TS=$(date +%Y%m%d-%H%M%S)

[ -f "$SMX_SRC" ] || { echo "missing $SMX_SRC"; exit 1; }

cp -a "$SMX_DST" "$SMX_DST.bak.$TS"
cp -a "$CFG" "$CFG.bak.$TS"
echo "[1/4] backups: $SMX_DST.bak.$TS , $CFG.bak.$TS"

cp "$SMX_SRC" "$SMX_DST"
chown dod:dod "$SMX_DST"
chmod 644 "$SMX_DST"
sed -i 's/^rcbotd config min_bots .*/rcbotd config min_bots 0/' "$CFG"
sed -i 's/^rcbotd config max_bots .*/rcbotd config max_bots 13/' "$CFG"
echo "[2/4] installed plugin + config.ini:"
grep -n '^rcbotd config \(min\|max\)_bots' "$CFG"

printf 'sm plugins reload ta_bots_rcbot2\n' > /run/dods/console
sleep 6
echo "[3/4] plugin reloaded; module log:"
journalctl -u dods --since "-20s" --no-pager | grep -E "\[twelveactors\]|ta_bots_rcbot2" | tail -5 || true

echo "[4/4] watch 30 s for churn (kicks should be 0):"
K1=$(journalctl -u dods --since "-1s" --no-pager | wc -l)
sleep 30
echo -n "kicks in last 30s: "
journalctl -u dods --since "-32s" --no-pager | grep -c "Kicked from server" || true
echo -n "addbot refusals in last 30s: "
journalctl -u dods --since "-32s" --no-pager | grep -c "max_bots reached" || true
echo "done"
