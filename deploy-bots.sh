#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
# Rebuild and deploy the two bot-side plugins from plugin/.
# Needs root: sudo ./deploy-bots.sh
#
# The module owns the RCBot2 quota (min 0 / max = target + humans, re-asserted
# every pass), so do NOT pin max_bots -1 here: RCBot2 refuses "addbot" while the
# cap is -1 and the roster never fills. config.ini only needs a sane startup
# value; the module corrects it on the first supervisor pass.
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SM=/srv/dods/dod/addons/sourcemod
SPCOMP=$SM/scripting/spcomp
INCLUDE=$SM/scripting/include
BUILD=/tmp/tadeploy
CFG=/srv/dods/dod/addons/rcbot2/config/config.ini
SRC="$SELF/plugin"
TARGET=${TARGET_BOTS:-12}

[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0" >&2; exit 1; }

echo "== compile"
rm -rf "$BUILD" && mkdir -p "$BUILD"
cp "$SRC"/ta_bots_rcbot2.sp "$SRC"/ta_botjoin.sp "$BUILD/"
cd "$BUILD"
"$SPCOMP" -i"$INCLUDE" ta_bots_rcbot2.sp
"$SPCOMP" -i"$INCLUDE" ta_botjoin.sp

echo "== install plugins"
install -o root -g root -m 644 "$BUILD/ta_bots_rcbot2.smx" "$BUILD/ta_botjoin.smx" "$SM/plugins/"
install -o root -g root -m 644 "$BUILD/ta_bots_rcbot2.sp" "$BUILD/ta_botjoin.sp" "$SM/scripting/"

echo "== rcbot2 config: startup bounds only (module re-asserts every pass)"
cp -n "$CFG" "$CFG.bak" || true
sed -i -E "s/^rcbotd config min_bots .*/rcbotd config min_bots 0/" "$CFG"
sed -i -E "s/^rcbotd config max_bots .*/rcbotd config max_bots $TARGET/" "$CFG"
# Pin ordered profile loading in the file too, so a restart seats bots on
# profiles 1..N even before the module's first supervisor pass runs.
if grep -qE '^#?rcbot_nonrandom_profile' "$CFG"; then
    sed -i -E "s|^#?rcbot_nonrandom_profile .*|rcbot_nonrandom_profile 1|" "$CFG"
else
    echo 'rcbot_nonrandom_profile 1' >> "$CFG"
fi
grep -nE "^rcbotd config (min|max)_bots|^rcbot_nonrandom_profile" "$CFG"

echo "== reload"
if [ -p /run/dods/console ]; then
    printf 'sm plugins reload ta_bots_rcbot2\n' > /run/dods/console
    printf 'sm plugins load ta_botjoin\n' > /run/dods/console
else
    echo "  console FIFO missing; plugins load on the next map change"
fi

echo "== done"
echo "verify: journalctl -u dods --since '-5min' | grep -E 'committed suicide with \"world\"|renamed stray|unvoiced'"
