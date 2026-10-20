#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
# One-shot root fix for the Twelve Actors bridge on this box.
#   1. installs the command-spy plugin (diagnostic: shows what the DoD:S client
#      actually sends when you use C / V / B, and when you type in chat)
#   2. stops sm_warmode_on.cfg from unloading the Twelve Actors plugins
# Run: sudo bash $HERE/fix-voice-menu.sh
HERE=$(cd "$(dirname "$0")" && pwd)
set -euo pipefail

SM=/srv/dods/dod/addons/sourcemod
PLUGINS=$SM/plugins

echo "== 1. cmdspy =="
install -o dod -g dod -m 0644 $HERE/plugin/ta_cmdspy.smx "$PLUGINS/ta_cmdspy.smx"
ls -l "$PLUGINS/ta_cmdspy.smx"

echo "== 2. warmode =="
CFG=/srv/dods/dod/cfg/sourcemod/sm_warmode_on.cfg
if ! grep -q 'ta_bots_rcbot2.smx' "$CFG"; then
  cp -a "$CFG" "$CFG.bak.$(date +%Y%m%d-%H%M%S)"
  # insert our two loads just before the lock, so warmode still unloads
  # everything else but leaves the bridge alive
  python3 - "$CFG" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
lines = p.read_text().splitlines(True)
add = ["sm plugins load ta_bots_rcbot2.smx\n", "sm plugins load twelveactors.smx\n"]
out = []
for ln in lines:
    if ln.strip().startswith("sm plugins load_lock"):
        out.extend(add)
    out.append(ln)
p.write_text("".join(out))
PY
  chown dod:dod "$CFG"
  echo "patched:"
  cat "$CFG"
else
  echo "already patched"
fi

echo
echo "Done. Now load the spy without restarting anything:"
echo "  curl -s http://127.0.0.1:8377/v1/stats >/dev/null   # daemon check"
echo "  rcon: sm plugins load ta_cmdspy.smx"
