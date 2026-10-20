#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
# Install the temporary command-sniffer plugin (diagnoses what the DoD:S client
# actually sends for the radio menu / chat).
# Run as:  sudo <repo>/tools/install-cmdspy.sh
set -euo pipefail
SM=/srv/dods/dod/addons/sourcemod
SRC=/home/admin1/.hermes/cache/scratch/sp/ta_cmdspy.smx
if [ ! -f "$SRC" ]; then
  echo "missing $SRC — recompile ta_cmdspy.sp first" >&2
  exit 1
fi
install -o dod -g dod -m 644 "$SRC" "$SM/plugins/ta_cmdspy.smx"
: > /dev/null
touch "$SM/data/twelveactors/cmdspy.tsv" 2>/dev/null || true
chown dod:dod "$SM/data/twelveactors/cmdspy.tsv" 2>/dev/null || true
chmod 644 "$SM/data/twelveactors/cmdspy.tsv" 2>/dev/null || true
echo "installed $SM/plugins/ta_cmdspy.smx"
echo "now, from rcon/console:  sm plugins load ta_cmdspy.smx"
