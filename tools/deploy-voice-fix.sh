#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
# Deploy the DoD:S voice-menu fix.
#   sudo $HERE/tools/deploy-voice-fix.sh
#
# Installs the rebuilt twelveactors plugin (now listens to DoD:S named voice_*
# commands as well as voicemenu), plus two diagnostics that prove what the
# server actually receives. Restarts the daemon so the new bridge.py loads.
HERE=$(cd "$(dirname "$0")" && pwd)
set -euo pipefail

SM=/srv/dods/dod/addons/sourcemod
SRC=/home/admin1/.hermes/cache/scratch/sp
DATA=$SM/data/twelveactors

for f in twelveactors ta_echo ta_cmdspy; do
  [ -f "$SRC/$f.smx" ] || { echo "missing $SRC/$f.smx" >&2; exit 1; }
done

install -o dod -g dod -m 644 "$SRC/twelveactors.smx"    "$SM/plugins/twelveactors.smx"
install -o dod -g dod -m 644 "$SRC/ta_echo.smx"   "$SM/plugins/ta_echo.smx"
install -o dod -g dod -m 644 "$SRC/ta_cmdspy.smx" "$SM/plugins/ta_cmdspy.smx"
install -o dod -g dod -m 644 $HERE/plugin/twelveactors.sp "$SM/scripting/twelveactors.sp" || true

touch "$DATA/ta_echo.tsv" "$DATA/cmdspy.tsv"
chown dod:dod "$DATA/ta_echo.tsv" "$DATA/cmdspy.tsv"
chmod 644 "$DATA/ta_echo.tsv" "$DATA/cmdspy.tsv"

systemctl restart twelveactors.service
sleep 2
systemctl is-active twelveactors.service

PW=$(grep -oP '(?<=rcon_password ")[^"]+' /srv/dods/dod/cfg/server.cfg)
python3 $HERE/tools/rcon2.py "$PW" \
  'sm plugins reload twelveactors.smx' \
  'sm plugins load ta_echo.smx' \
  'sm plugins load ta_cmdspy.smx' \
  'sm_ta_debug 1' \
  'sm plugins list'

echo
echo "Done. In game: press C and pick an item."
echo "  chat shows      [TA] heard <command> ...   (proves the server got it)"
echo "  log file        $DATA/ta_echo.tsv"
echo "  every command   $DATA/cmdspy.tsv"
echo "  bridge debug    $SM/logs/L$(date +%Y%m%d).log  (grep twelveactors)"
