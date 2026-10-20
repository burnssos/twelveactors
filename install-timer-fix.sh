#!/bin/bash
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
# Install the poll-timer fix: without it, the repeating poll timer dies at every
# map change and barks stop being played (they are still written to out.tsv).
HERE=$(cd "$(dirname "$0")" && pwd)
set -e
NEW=$HERE/plugin/twelveactors.smx
DST=/srv/dods/dod/addons/sourcemod/plugins/twelveactors.smx
PW=$(grep -oP '(?<=rcon_password ")[^"]+' /srv/dods/dod/cfg/server.cfg)

install -o dod -g dod -m 644 "$NEW" "$DST"
echo "installed $(md5sum "$DST" | cut -d' ' -f1) ($(stat -c%s "$DST") bytes)"

cd $HERE
python3 tools/rcon2.py "$PW" "sm plugins reload twelveactors" "sm_ta_status"
