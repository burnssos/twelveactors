#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
# Per-bot voice (core) and optional proximity audio (module).
#
#   sudo ./install-voice.sh                     keep the module as it is
#   sudo ./install-voice.sh --with-proximity    enable distance falloff
#   sudo ./install-voice.sh --without-proximity disable it again
#   sudo ./install-voice.sh --team-only         audible to the bot's own team only
#                                               (everyone hears barks by default)
#
# Upgrades a server that is already running, without touching the daemon, the
# config or the map:
#
#   twelveactors.smx       every bot speaks its clip at its own pitch and gain
#                     (data/twelveactors/voices.tsv, else a hash of the name).
#                     Core behaviour, on by default, sm_ta_voice_pitch 0
#                     turns just the pitch off.
#   ta_proximity.smx optional. Hooks the core's Ta_OnBotVoice forward and
#                     sends each bark only to listeners inside the radius, at
#                     the volume of their distance. Without it the core plays
#                     every bark to everyone at one volume.
#
# Rollback: cp -a <plugins>/twelveactors.smx.bak.<tag> <plugins>/twelveactors.smx
#           then sm plugins reload twelveactors
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run with sudo: sudo $0" >&2; exit 1; }

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GAME="${GAME:-/srv/dods}"
SM="$GAME/dod/addons/sourcemod"
PLUGDIR="$SM/plugins"
DISABLED="$PLUGDIR/disabled"
DATA="$SM/data/twelveactors"
FIFO="${FIFO:-/run/dods/console}"
SPCOMP="$SM/scripting/spcomp"
INCLUDE="$SM/scripting/include"
TS=$(date +%Y%m%d-%H%M%S)
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/tavoice.XXXXXX")
trap 'rm -rf "$BUILD"' EXIT

MODE="keep"
AUDIENCE="all"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --with-proximity)    MODE="on" ;;
    --without-proximity) MODE="off" ;;
    --team-only)         AUDIENCE="team" ;;
    --all-audible)       AUDIENCE="all" ;;
    ""|keep)             MODE="keep" ;;
    *) echo "usage: $0 [--with-proximity|--without-proximity] [--team-only|--all-audible]" >&2
       exit 2 ;;
  esac
  shift
done

[ -x "$SPCOMP" ] || { echo "missing $SPCOMP" >&2; exit 1; }
install -d -o dod -g dod -m 755 "$DISABLED" 2>/dev/null || mkdir -p "$DISABLED"

echo "[1/5] compile twelveactors.sp and ta_proximity.sp with the server's spcomp"
cp "$SRC/plugin/twelveactors.sp" "$SRC/plugin/ta_proximity.sp" "$BUILD/"
( cd "$BUILD" && "$SPCOMP" -i"$INCLUDE" twelveactors.sp >/dev/null && \
                "$SPCOMP" -i"$INCLUDE" ta_proximity.sp >/dev/null )
[ -s "$BUILD/twelveactors.smx" ] && [ -s "$BUILD/ta_proximity.smx" ] || {
  echo "compile failed" >&2; exit 1; }
echo "      core $(stat -c %s "$BUILD/twelveactors.smx") bytes, module $(stat -c %s "$BUILD/ta_proximity.smx") bytes"

echo "[2/5] install core (backup tag $TS)"
if [ -f "$PLUGDIR/twelveactors.smx" ]; then
  cp -a "$PLUGDIR/twelveactors.smx" "$PLUGDIR/twelveactors.smx.bak.$TS"
fi
install -o dod -g dod -m 644 "$BUILD/twelveactors.smx" "$PLUGDIR/twelveactors.smx"
install -o root -g root -m 644 "$BUILD/twelveactors.sp" "$SM/scripting/twelveactors.sp"
install -o root -g root -m 644 "$BUILD/ta_proximity.sp" "$SM/scripting/ta_proximity.sp"

# Curated pitches, if the operator has not written their own table. The plugin
# hashes each name without this file, which works but is arbitrary.
if [ ! -f "$DATA/voices.tsv" ] && [ -f "$SRC/config/voices.example.tsv" ]; then
  install -d -o dod -g dod -m 755 "$DATA"
  install -o dod -g dod -m 644 "$SRC/config/voices.example.tsv" "$DATA/voices.tsv"
  echo "      curated voices.tsv installed (12 personas)"
fi

echo "[3/5] optional proximity module: $MODE"
ENABLE_PROX=0
case "$MODE" in
  on)  ENABLE_PROX=1 ;;
  off) rm -f "$PLUGDIR/ta_proximity.smx"; install -m 644 "$BUILD/ta_proximity.smx" "$DISABLED/" ;;
  keep)
    if [ -f "$PLUGDIR/ta_proximity.smx" ]; then ENABLE_PROX=1; fi
    if [ "$ENABLE_PROX" = "1" ]; then
      install -o dod -g dod -m 644 "$BUILD/ta_proximity.smx" "$PLUGDIR/ta_proximity.smx"
    else
      install -m 644 "$BUILD/ta_proximity.smx" "$DISABLED/"
    fi
    ;;
esac
if [ "$ENABLE_PROX" = "1" ]; then
  install -o dod -g dod -m 644 "$BUILD/ta_proximity.smx" "$PLUGDIR/ta_proximity.smx"
  echo "      proximity: ENABLED"

  # Audience. Everyone hears barks by default; the convar defaults to 0 now, so
  # the only thing that can keep the old team-only behaviour alive is a cfg
  # written before this change. Migrate that one line in place, leave every
  # other value alone.
  CFG="$GAME/dod/cfg/sourcemod/ta_proximity.cfg"
  WANT=0
  [ "$AUDIENCE" = "team" ] && WANT=1
  if [ -f "$CFG" ]; then
    cp -a "$CFG" "$CFG.bak.$TS"
    sed -i -E "s|^sm_ta_proximity_team_only([[:space:]]+)\"?[01]\"?[[:space:]]*\$|sm_ta_proximity_team_only\1\"$WANT\"|" "$CFG"
  fi
  # The reload in [4/5] re-executes this cfg, so the rewritten line is live
  # without a map change.
  if [ "$WANT" = "1" ]; then
    echo "      audience: speaker's own team only"
  else
    echo "      audience: everyone hears every bark"
  fi
else
  echo "      proximity: not loaded (core plays flat audio)"
fi

echo "[4/5] reload (no map change)"
if [ -p "$FIFO" ]; then
  if [ "$ENABLE_PROX" = "1" ]; then
    # Module first out of the way, so it rebinds to the reloaded core's forward.
    printf 'sm plugins unload ta_proximity\n' > "$FIFO" 2>/dev/null || true
    sleep 1
  fi
  printf 'sm plugins reload twelveactors\n' > "$FIFO"
  sleep 3
  if [ "$ENABLE_PROX" = "1" ]; then
    printf 'sm plugins load ta_proximity\n' > "$FIFO"
    sleep 2
  fi
else
  echo "      WARN: $FIFO missing; plugins load on the next map change"
fi

echo "[5/5] verify"
RC=$(grep -oP '(?<=rcon_password ")[^"]+' "$GAME/dod/cfg/server.cfg" | head -1)
if [ -n "$RC" ]; then
  python3 "$SRC/tools/rcon2.py" "$RC" 'sm_ta_status' 'sm_ta_voices' 'sm_ta_prox' 2>/dev/null \
    || echo "      rcon did not answer (an earlier failed auth can ban this IP until a map change)"
fi
# SourceMod's own log is the fallback proof: it records every plugin load and
# LogMessage, and it is readable without rcon.
LOG="$SM/logs/L$(date +%Y%m%d).log"
if [ -f "$LOG" ]; then
  echo "      recent SourceMod log lines:"
  grep -E "\[twelveactors\] (precached|voice tuning)|\[ta_prox\] loaded|error" "$LOG" 2>/dev/null | tail -4 | sed 's/^/        /'
fi

PROX_STATE="absent"
[ "$ENABLE_PROX" = "1" ] && PROX_STATE="loaded"

cat <<EOF

What you should see above:
  sm_ta_status  -> voice pitch=1 proximity_module=$PROX_STATE
  sm_ta_voices  -> one line per client with its pitch (92..112, or voices.tsv)
  sm_ta_prox    -> only when the module is loaded

Tuning, all live, no restart:
  sm_ta_voice_pitch 0|1          per-bot pitch on/off
  sm_ta_reload                       re-read data/twelveactors/voices.tsv
  sm_ta_proximity_enable 0|1         distance falloff (module only)
  sm_ta_proximity_near 150           full volume inside this many units
  sm_ta_proximity_far 1200           silence (or minvol) at this distance
  sm_ta_proximity_minvol 0.0         volume floor at far
  sm_ta_proximity_team_only 0        everyone hears barks (1 = own team only)
  sm_ta_proximity_debug 1            log distance and volume per listener

rollback:
  cp -a $PLUGDIR/twelveactors.smx.bak.$TS $PLUGDIR/twelveactors.smx
  sudo ./install-voice.sh --without-proximity
EOF
