#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
# Switch the Twelve Actors daemon's model in the live data dir and restart it.
#
#   sudo bash install-model-switch.sh <model-id>
#   sudo TWELVEACTORS_MODEL=<model-id> bash install-model-switch.sh
#
# No model is hard-coded: with no id this prints the recommendation and exits
# without touching the config. Recommended: deepseek-v4-flash-0731 (cheap, JSON
# mode, honours max_tokens 600). Any OpenAI-compatible model that returns a
# JSON object works - list the host's catalogue and pick one.
set -euo pipefail

MODEL="${1:-${TWELVEACTORS_MODEL:-}}"
CFG="/srv/dods/dod/addons/sourcemod/data/twelveactors/config.json"
TS="$(date +%Y%m%d-%H%M%S)"

if [ -z "$MODEL" ]; then
  BASE="<your-host>/v1"
  if [ -f "$CFG" ]; then
    BASE="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["base_url"])' "$CFG" 2>/dev/null || echo "$BASE")"
  fi
  cat >&2 <<EOF
No model id given - nothing changed.

  recommended : deepseek-v4-flash-0731
                cheap, returns JSON, respects max_tokens 600
  any model   : needs JSON-object output and an explicit max_tokens

  usage       : sudo bash install-model-switch.sh <model-id>
                sudo TWELVEACTORS_MODEL=<model-id> bash install-model-switch.sh

  catalogue   : curl -s "$BASE/models" -H "Authorization: Bearer your-key"
EOF
  exit 2
fi

case "$MODEL" in
  *[[:space:]]*) echo "model id must not contain whitespace: '$MODEL'" >&2; exit 2 ;;
esac

[ -f "$CFG" ] || { echo "missing config: $CFG" >&2; exit 1; }

echo "== before =="
python3 -c "import json;d=json.load(open('$CFG'));print('model =',d['model'])"

cp -a "$CFG" "$CFG.bak.$TS"
echo "backup  -> $CFG.bak.$TS"

python3 - "$CFG" "$MODEL" <<'PY'
import json,sys
path,model=sys.argv[1],sys.argv[2]
d=json.load(open(path))
d["model"]=model
with open(path,"w") as f:          # in-place: keeps inode, owner, mode
    json.dump(d,f,indent=2); f.write("\n")
PY
chown dod:dod "$CFG"
chmod 600 "$CFG"

echo "== after =="
python3 -c "import json;d=json.load(open('$CFG'));print('model =',d['model'])"
ls -l "$CFG"

systemctl restart twelveactors.service
sleep 2

echo "== unit =="
systemctl is-active twelveactors.service
echo "== healthz =="
curl -s localhost:8377/healthz; echo
echo "== journal =="
journalctl -u twelveactors.service -n 8 --no-pager
echo
echo "Done. Confirm 'model' in healthz reads $MODEL."
