#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
# Twelve Actors installer for a SourceMod + RCBot2 Day of Defeat: Source server.
#
#   sudo ./install.sh
#
# Env overrides:
#   GAME=/srv/dods  TARGET_BOTS=12  NO_RESTART=1
#   TWELVEACTORS_API_BASE=https://your-host/v1   TWELVEACTORS_API_KEY=...   TWELVEACTORS_MODEL=<id>
#
# No credential is baked into this script. On a terminal the installer asks for
# the base URL, key and model (key input hidden); without a terminal it takes
# the three env vars above and otherwise writes <YOUR_*> placeholders and tells
# you what to edit. deepseek-v4-flash-0731 is the recommended model default,
# not a requirement: any OpenAI-compatible model that returns JSON works.
#
# Three things this installer owns that the server cannot get right by itself:
#
#   1. ta_humancap        caps humans at TARGET_BOTS, so the 12 bot slots are
#                          never displaced by a 13th connection.
#   2. bots module         RCBot2's max_bots is a TOTAL client cap that counts
#                          humans, so the module writes max_bots = target +
#                          humans and re-asserts it on every supervisor pass.
#                          config.ini is exec'd after plugins load, which is why
#                          a one-shot write is not enough.
#   3. config.ini bounds   min_bots 0 / max_bots TARGET_BOTS as the startup
#                          state, so the second between map start and the first
#                          supervisor pass cannot fill all 24 slots with bots.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GAME="${GAME:-/srv/dods}"
SM="$GAME/dod/addons/sourcemod"
DATA="$SM/data/twelveactors"
SPCOMP="$SM/scripting/spcomp"
INCLUDE="$SM/scripting/include"
RCBOT_CFG="$GAME/dod/addons/rcbot2/config/config.ini"
. "$(cd "$(dirname "$0")" && pwd)/tools/rcbot-preflight.sh"
TARGET_BOTS="${TARGET_BOTS:-12}"
NO_RESTART="${NO_RESTART:-0}"

[ "$(id -u)" -eq 0 ] || {
  echo "run as root:  sudo $0" >&2
  exit 1
}
[ -x "$SPCOMP" ] || { echo "missing $SPCOMP (install SourceMod first)" >&2; exit 1; }
[ -f "$RCBOT_CFG" ] || { echo "missing $RCBOT_CFG (install RCBot2 first)" >&2; exit 1; }

echo "== compile (target $TARGET_BOTS bots, cap 0 = no runtime override)"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/tabuild.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
cp "$SRC"/plugin/twelveactors.sp "$SRC"/plugin/ta_bots_rcbot2.sp \
   "$SRC"/plugin/ta_botjoin.sp "$SRC"/plugin/ta_humancap.sp \
   "$SRC"/plugin/ta_proximity.sp "$BUILD/"
cd "$BUILD"
for f in twelveactors ta_bots_rcbot2 ta_botjoin ta_humancap ta_proximity; do
  "$SPCOMP" -i"$INCLUDE" "$f.sp" >/dev/null
  [ -s "$f.smx" ] || { echo "compile failed: $f.sp" >&2; exit 1; }
done

echo "== install plugins"
install -d -o dod -g dod -m 755 "$DATA" "$SM/plugins/disabled"
install -o root -g root -m 644 "$BUILD"/*.sp "$SM/scripting/"
for p in twelveactors ta_bots_rcbot2 ta_botjoin ta_humancap; do
  install -o root -g root -m 644 "$BUILD/$p.smx" "$SM/plugins/"
done
# Proximity voice is an optional module: it ships compiled, but stays in
# plugins/disabled until someone asks for it (./install-voice.sh --with-proximity).
# An operator who already enabled it keeps the enabled copy current instead.
if [ -f "$SM/plugins/ta_proximity.smx" ]; then
  install -o root -g root -m 644 "$BUILD/ta_proximity.smx" "$SM/plugins/"
  echo "   ta_proximity: enabled, updated in place"
else
  install -o root -g root -m 644 "$BUILD/ta_proximity.smx" "$SM/plugins/disabled/"
  echo "   ta_proximity: installed but disabled (optional module)"
fi

# Curated per-bot pitch. Optional: without it the plugin derives a stable pitch
# from each persona name. Never overwrite a file the operator has tuned.
if [ -f "$SRC/config/voices.example.tsv" ] && [ ! -f "$DATA/voices.tsv" ]; then
  install -o dod -g dod -m 644 "$SRC/config/voices.example.tsv" "$DATA/voices.tsv"
  echo "== voices.tsv (curated pitches) installed"
fi

echo "== install daemon to /opt/twelveactors"
rm -rf /opt/twelveactors/twelveactors
install -d -o root -g root -m 755 /opt/twelveactors
cp -r "$SRC/twelveactors" /opt/twelveactors/
find /opt/twelveactors -name __pycache__ -type d -exec rm -rf {} +

echo "== config.json"
if [ ! -f "$DATA/config.json" ]; then
  TA_API_BASE="${TWELVEACTORS_API_BASE:-}"
  TA_MODEL="${TWELVEACTORS_MODEL:-}"
  TA_API_KEY="${TWELVEACTORS_API_KEY:-}"

  # Ask only when there is a terminal. A piped install is not left hanging;
  # it falls through to the env vars, then to placeholders.
  if [ -t 0 ]; then
    if [ -z "$TA_API_BASE" ]; then
      read -r -p "API base URL [https://api.venice.ai/api/v1]: " TA_API_BASE || true
    fi
    if [ -z "$TA_MODEL" ]; then
      read -r -p "Model id [recommended - press Enter for it, or type any id]: " TA_MODEL || true
    fi
    if [ -z "$TA_API_KEY" ]; then
      read -r -s -p "API key (hidden; Enter = try ~/.hermes/config.yaml, blank = placeholder): " TA_API_KEY || true
      echo
    fi
  fi

  # Recommended values, not requirements.
  : "${TA_API_BASE:=https://api.venice.ai/api/v1}"
  : "${TA_MODEL:=deepseek-v4-flash-0731}"

  # Only a Venice base can borrow the Hermes key; another host needs its own.
  if [ -z "$TA_API_KEY" ] && printf '%s' "$TA_API_BASE" | grep -q 'api\.venice\.ai'; then
    TA_API_KEY="$(python3 - <<'PY'
import os
homes = []
if os.environ.get("SUDO_USER"):
    homes.append("/home/" + os.environ["SUDO_USER"])
homes.append(os.path.expanduser("~"))
for home in homes:
    try:
        lines = open(os.path.join(home, ".hermes", "config.yaml")).read().splitlines()
    except OSError:
        continue
    found = False
    for line in lines:
        s = line.strip()
        if "api.venice.ai" in s:
            found = True
        elif found and s.startswith("api_key:"):
            value = s.split(":", 1)[1].strip().strip("\"'")
            if value:
                print(value)
                raise SystemExit(0)
        elif found and s.startswith("- name:"):
            found = False
print("")
PY
)"
  fi

  export TA_API_BASE TA_MODEL TA_API_KEY
  python3 - "$DATA/config.json" <<'PY'
import json, os, sys
path = sys.argv[1]
cfg = {
    "engine": "dods",
    "base_url": os.environ.get("TA_API_BASE") or "<YOUR_API_BASE>",
    "model": os.environ.get("TA_MODEL") or "<YOUR_MODEL>",
    "api_key": os.environ.get("TA_API_KEY") or "<YOUR_API_KEY>",
    "port": 8377,
    "timeout": 20,
    "dialog_requires_human": True,
}
json.dump(cfg, open(path, "w"), indent=2)
open(path, "a").write("\n")
missing = [k for k in ("base_url", "model", "api_key") if cfg[k].startswith("<")]
print("wrote", path, "| missing:", ", ".join(missing) if missing else "none")
PY
  chown dod:dod "$DATA/config.json"
  chmod 600 "$DATA/config.json"

  if grep -q '<YOUR_' "$DATA/config.json"; then
    cat <<EOF

==============================================================================
  Twelve Actors is installed but NOT connected to a model yet.
  Fill in the placeholders, then restart the daemon:

      sudo nano $DATA/config.json
      sudo systemctl restart twelveactors.service

  base_url : your host's OpenAI-compatible base (Venice: https://api.venice.ai/api/v1)
  api_key  : your key. The file is 0600 dod:dod; it stays on this machine.
  model    : recommended deepseek-v4-flash-0731 - cheap, JSON mode, and it
             respects max_tokens 600. Any OpenAI-compatible model that returns
             a JSON object works. To list a host's catalogue:

                 curl -s https://api.venice.ai/api/v1/models -H "Authorization: Bearer your-key"

  Switch models later without reinstalling:
      sudo bash install-model-switch.sh <any-model-id>
==============================================================================
EOF
  fi
fi
chown dod:dod "$DATA"

echo "== scan voice bank"
runuser -u dod -- env PYTHONPATH=/opt/twelveactors python3 -m twelveactors \
    --data "$DATA" scan --install "$GAME"

echo "== bind the cast to RCBot2 profile slots"
# Writes profiles/N.ini, personas.json and voiced.txt. Without this the bots
# keep the launcher's random names and the module (which enforces voiced.txt)
# has nothing to enforce.
runuser -u dod -- env PYTHONPATH=/opt/twelveactors python3 -m twelveactors \
    --data "$DATA" bootstrap --install "$GAME" --bots "$TARGET_BOTS"

echo "== rcbot2 startup bounds (checked, not edited)"
# Twelve Actors does not write RCBot2's files. rcbot_nonrandom_profile is not
# checked at all: the module issues it through the console at load.
ta_rcbot_bounds "$RCBOT_CFG" "$TARGET_BOTS" || exit 1

# The old botfill plugin fought RCBot2's quota; the module replaces it.
if [ -f "$SM/plugins/dods_botfill.smx" ]; then
  mv "$SM/plugins/dods_botfill.smx" "$SM/plugins/disabled/"
fi

echo "== daemon unit"
install -o root -g root -m 644 "$SRC/systemd/twelveactors.service" /etc/systemd/system/twelveactors.service
systemctl daemon-reload
systemctl enable --now twelveactors.service

if [ "$NO_RESTART" = "1" ]; then
  echo "== NO_RESTART=1: plugins load on the next map change"
else
  echo "== restarting dods so both plugins load"
  systemctl restart dods
  sleep 8
fi

echo "== verify"
if [ "$NO_RESTART" != "1" ]; then
  journalctl -u dods --since "-2min" --no-pager \
    | grep -E "\[ta_humancap\] active|\[twelveactors\] bot module attached|\[twelveactors\] voiced roster" || true
fi
echo
echo "expected live state:"
echo "  sm plugins list      -> Twelve Actors Human Cap, Twelve Actors Bots (RCBot2), Twelve Actors Bot Join"
echo "  sm_ta_humancap      -> $TARGET_BOTS"
echo "  sm_ta_bots          -> target=$TARGET_BOTS applied=$((TARGET_BOTS + 1)) bots=$TARGET_BOTS"
echo "  status               -> $TARGET_BOTS bots + humans, $TARGET_BOTS human slot ceiling"
echo "  sm_ta_status        -> humans=N require_human=1 team_chat=1 gated=N (humans=0 means no model turns)"
echo "  sm_ta_voices        -> one line per client with its pitch (voices.tsv, else a name hash)"
echo "  voice                -> core: each bot its own pitch/gain; sm_ta_voice_pitch 0 turns it off"
echo "  ta_proximity        -> optional distance audio, shipped in plugins/disabled;"
echo "                          enable with: sudo ./install-voice.sh --with-proximity"
echo "  bot chat             -> team chat from the bot's client (say_team); sm_ta_team_chat 0 makes it white all-chat"
echo "daemon health:  curl -s localhost:8377/healthz"
