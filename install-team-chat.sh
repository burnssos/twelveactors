#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
# Deliver bot lines as team chat from the bot itself.
#
#   sudo ./install-team-chat.sh          (GAME=/srv/dods by default)
#
# For a fresh server this is not needed: install.sh compiles twelveactors.sp from
# this tree, so team chat is in the first build. This script upgrades a
# server that is already running without touching the daemon or changing map.
#
# Before: replies went out through PrintToChatAll, so every line was white
# server text with the persona name typed into it.
# After:  the plugin resolves the speaker to its client and issues
#         FakeClientCommand(client, "say_team ..."), so the engine renders the
#         line exactly like a player's team chat: bot's name, team colour,
#         visible to that bot's team only. Cvar:
#         sm_ta_team_chat (default 1; 0 restores the white line).
#
# Only the plugin changes; the daemon and its config are untouched.
# Rollback: cp -a plugins/twelveactors.smx.bak.<tag> plugins/twelveactors.smx then reload.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run with sudo: sudo $0" >&2; exit 1; }

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GAME="${GAME:-/srv/dods}"
SM="$GAME/dod/addons/sourcemod"
PLUGDIR=$SM/plugins
FIFO="${FIFO:-/run/dods/console}"
SPCOMP=$SM/scripting/spcomp
INCLUDE=$SM/scripting/include
TS=$(date +%Y%m%d-%H%M%S)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/tateam.XXXXXX")
trap 'rm -rf "$BUILD"' EXIT

echo "[1/4] compile twelveactors.sp with the server's own spcomp"
cp "$SRC/plugin/twelveactors.sp" "$BUILD/"
( cd "$BUILD" && "$SPCOMP" -i"$INCLUDE" twelveactors.sp >/dev/null )
[ -s "$BUILD/twelveactors.smx" ] || { echo "compile failed" >&2; exit 1; }
echo "      ok: $(stat -c %s "$BUILD/twelveactors.smx") bytes"

echo "[2/4] install plugin (backup tag $TS)"
cp -a "$PLUGDIR/twelveactors.smx" "$PLUGDIR/twelveactors.smx.bak.$TS"
install -o dod -g dod -m 644 "$BUILD/twelveactors.smx" "$PLUGDIR/twelveactors.smx"
install -o root -g root -m 644 "$BUILD/twelveactors.sp" "$SM/scripting/twelveactors.sp"

echo "[3/4] reload the plugin (no map change needed)"
if [ -p "$FIFO" ]; then
    printf 'sm plugins reload twelveactors\n' > "$FIFO"
    sleep 3
else
    echo "      WARN: $FIFO missing; the plugin loads on the next map change"
fi

echo "[4/4] verify"
RC=$(grep -oP '(?<=rcon_password \")[^\"]+' /srv/dods/dod/cfg/server.cfg | head -1)
STATUS=$(python3 "$SRC/tools/rcon2.py" "$RC" 'sm_ta_status' 2>/dev/null | grep -m1 '\[twelveactors\] enable' || true)
echo "  $STATUS"
case "$STATUS" in
    *team_chat=1*) echo "  team chat: ON" ;;
    *) echo "  team chat: NOT ACTIVE — check that twelveactors.smx reloaded" >&2 ;;
esac

cat <<'EOF'

To see it end to end while you are in game:
  sudo dods-console "sm_ta_test attack"
That queues a test event to the daemon; its reply is delivered with say_team
from that bot, so it arrives as normal team chat in the bot's team colour.

Notes:
  - A reply whose persona is no longer in game (bot renamed or disconnected
    between the daemon's write and the plugin's poll) has no team to speak
    from, so it falls back to the old white line. That is the only remaining
    white path.
  - say_team is team-only by engine rule: a bot on Axis speaking does not put
    text in front of an Allied player. The voice clip is unchanged and still
    plays for everyone, so the bark is still audible across teams.
  - sm_ta_team_chat 0 restores the white all-chat line at runtime.
EOF

echo "rollback: cp -a $PLUGDIR/twelveactors.smx.bak.$TS $PLUGDIR/twelveactors.smx  (then sm plugins reload twelveactors)"
