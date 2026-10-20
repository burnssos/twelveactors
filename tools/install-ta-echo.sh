#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
# Install the Twelve Actors Echo diagnostic plugin and load it live.
#   sudo ./tools/install-ta-echo.sh
# It prints, in your game chat, every radio/mic/chat command the server
# actually receives from you. Remove with:
#   sudo rm /srv/dods/dod/addons/sourcemod/plugins/ta_echo.smx
HERE=$(cd "$(dirname "$0")" && pwd)
set -euo pipefail

SM=/srv/dods/dod/addons/sourcemod
SRC=$HERE/ta_echo.sp
DST=$SM/plugins/ta_echo.smx

[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }
SPCOMP=$SM/scripting/spcomp
[ -x "$SPCOMP" ] || { echo "missing $SPCOMP (the server's own compiler)" >&2; exit 1; }

TMPD=$(mktemp -d)
"$SPCOMP" -o"$TMPD/ta_echo.smx" "$SRC" -i"$SM/scripting/include"
install -o dod -g dod -m 644 "$TMPD/ta_echo.smx" "$DST"
rm -rf "$TMPD"

mkdir -p "$SM/data/twelveactors"
touch "$SM/data/twelveactors/ta_echo.tsv"
chown dod:dod "$SM/data/twelveactors/ta_echo.tsv" "$SM/data/twelveactors"
chmod 644 "$SM/data/twelveactors/ta_echo.tsv"
echo "installed $DST"

PW=$(grep -oP '(?<=rcon_password ")[^"]+' /srv/dods/dod/cfg/server.cfg)
python3 "$HERE/rcon2.py" "$PW" 'sm plugins load ta_echo.smx' 'sm plugins list' \
  | sed -n '1,40p'
echo
echo "Now press C (or V / B) in game: chat should say [TA] heard ..."
echo "Log: $SM/data/twelveactors/ta_echo.tsv"
