#!/bin/sh
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
# Stop the dods_botfill / RCBot2 roster churn on the DoD:S server.
#
# Cause: config.ini sets rcbotd config max_bots 12. max_bots is a TOTAL-PLAYER
# cap (humans + bots) and RCBot2's own manager fills up to it, while
# dods_botfill kicks the surplus every 4 s. With 1 human, botfill wants 11 bots,
# RCBot2 wants 12 clients -> one bot kicked and one added every 10 s, all day.
#
# Fix: turn RCBot2's manager off (max_bots -1 means "no cap"; the value -1
# bypasses the max>min validation in rcbot_subcmds/config.cpp) and let
# dods_botfill own the roster.
set -e

CFG=/srv/dods/dod/addons/rcbot2/config/config.ini
STAMP=$(date +%Y%m%d-%H%M%S)

cp -a "$CFG" "$CFG.bak.$STAMP"
echo "[1/4] backup: $CFG.bak.$STAMP"

# min_bots 0, max_bots -1
sed -i 's/^rcbotd config min_bots .*/rcbotd config min_bots 0/' "$CFG"
sed -i 's/^rcbotd config max_bots .*/rcbotd config max_bots -1/' "$CFG"
echo "[2/4] config.ini now:"
grep -n '^rcbotd config \(min\|max\)_bots' "$CFG"

# apply live (no map change needed: the subcommand sets the value in memory)
printf 'rcbotd config max_bots -1\n' > /run/dods/console
sleep 5
echo "[3/4] asked the running server for max_bots -1"
journalctl -u dods --since "-20s" --no-pager | grep -i "max_bots\|min_bots" | tail -5 || true

echo "[4/4] watch for churn to stop (no more 'Kicked from server' every 10 s):"
journalctl -u dods --since "-1min" --no-pager | grep -c "Kicked from server" || true
echo "done"
