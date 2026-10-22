#!/bin/sh
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
# install-spawnwatch.sh -- install the DoD:S spawn/death position logger.
#
# What it does:
#   1. installs the spawnwatch SourceMod plugin (compiles it if needed)
#   2. starts a UDP listener on port 27777 as your normal user
#   3. loads the plugin on the live server and points its log stream at us
#   4. dumps every client's current position once, to prove it works
#
# Run:  sudo ./tools/install-spawnwatch.sh
#       sudo ./tools/install-spawnwatch.sh --compile
#
# Output lands in <repo>/logs/spawnwatch.log (override with LOGDIR=...)
# Each game line looks like:
#   [sw] SPAWN <name> team=2 bot=1 pos=x y z dTank=n
#   [sw] DEATH <name> team=2 bot=1 pos=x y z dTank=n killer=<name> dKiller=n
# dTank is distance to the donner tank flag at -554 -101 -12.
set -eu

SRV=/srv/dods
MOD=$SRV/dod
PLUGDIR=$MOD/addons/sourcemod/plugins
SCRIPTDIR=$(cd "$(dirname "$0")" && pwd)
SRC=$SCRIPTDIR/dods_spawnwatch.sp
SMX=$SCRIPTDIR/dods_spawnwatch.smx
CAP=$SCRIPTDIR/spawnwatch_capture.py
LOGDIR=${LOGDIR:-$(cd "$SCRIPTDIR/.." && pwd)/logs}
LOG=$LOGDIR/spawnwatch.log
OWNER=${SUDO_USER:-$(id -un)}
FIFO=/run/dods/console
PORT=27777
COMPILE=0
[ "${1:-}" = "--compile" ] && COMPILE=1

# Write one line to the server console fifo, never blocking forever.
con() {
    if ! timeout 5 sh -c 'printf "%s\n" "$1" > "$2"' _ "$1" "$FIFO" 2>/dev/null; then
        echo "      WARN: console write failed or timed out: $1"
    fi
}

[ "$(id -u)" -eq 0 ] || { echo "run me with sudo: sudo sh $0"; exit 1; }
[ -p "$FIFO" ] || { echo "ERROR: no console fifo at $FIFO (is the dods service up?)"; exit 1; }
[ -f "$CAP" ] || { echo "ERROR: missing $CAP"; exit 1; }

if [ "$COMPILE" -eq 1 ] || [ ! -f "$SMX" ]; then
    echo "[1/5] compiling $SRC"
    SPCOMP=$MOD/addons/sourcemod/scripting/spcomp
    [ -x "$SPCOMP" ] || { echo "ERROR: spcomp not found at $SPCOMP"; exit 1; }
    TMPD=$(mktemp -d)
    "$SPCOMP" -o"$TMPD/dods_spawnwatch.smx" "$SRC" \
        -i"$MOD/addons/sourcemod/scripting/include"
    install -o "$OWNER" -g "$OWNER" -m 644 "$TMPD/dods_spawnwatch.smx" "$SMX"
    rm -rf "$TMPD"
else
    # Only reachable if someone has a local .smx lying about: no compiled
    # output is committed any more. A tracked build/ta_bots_rcbot2.smx once
    # shipped a plugin whose source had already been corrected (21 Oct 2026),
    # so a stale binary beside fresh source is exactly the hazard to avoid.
    echo "[1/5] using existing $SMX (local build; delete it to force a recompile)"
fi

echo "[2/5] installing plugin into $PLUGDIR"
install -o dod -g dod -m 644 "$SMX" "$PLUGDIR/dods_spawnwatch.smx"

echo "[3/5] (re)starting log capture on udp/$PORT"
mkdir -p "$LOGDIR"
chown "$OWNER:$OWNER" "$LOGDIR"
for pid in $(ss -lunpH 2>/dev/null | grep ":$PORT " | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u); do
    echo "      stopping old listener pid $pid"
    kill "$pid" 2>/dev/null || true
done
sleep 1
runuser -u "$OWNER" -- setsid nohup /usr/bin/python3 "$CAP" "$LOG" >/dev/null 2>&1 &
sleep 2

echo "[4/5] loading plugin and pointing the server log stream at us"
IP=$(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | head -1)
[ -n "$IP" ] || IP=172.24.1.213
con 'sm plugins unload dods_spawnwatch'
sleep 1
con 'sm plugins load dods_spawnwatch'
con 'log on'
con "logaddress_add $IP:$PORT"
sleep 3
con 'sm_posdump'

echo "[5/5] verifying (6s)"
sleep 6
N=$(grep -c '\[sw\]' "$LOG" 2>/dev/null || true)
N=${N:-0}
echo
echo "spawnwatch lines in $LOG: $N"
if [ "$N" -gt 0 ]; then
    grep '\[sw\]' "$LOG" | tail -20
    echo
    echo "OK. Leave the capture running. Read it with:"
    echo "  tail -f $LOG | grep '\\[sw\\]'"
    echo "Classify world deaths (falls vs class-selection) with:"
    echo "  python3 $SCRIPTDIR/worlddeath_scan.py $LOG"
else
    echo "No [sw] lines yet. Loaded line should appear within a few seconds;"
    echo "check the server log for a plugin load error, and confirm with an rcon"
    echo "  logaddress_list"
    exit 2
fi
