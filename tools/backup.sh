#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
# Snapshot everything needed to get back to "now" before a big change.
#
#   tools/backup.sh [DESTDIR]        # default ~/backups/twelveactors-<timestamp>
#
# Captures, as one directory:
#   1. the whole source tree (~/twelveactors) minus the re-creatable bulk
#      (.venv-tts, voices/*.onnx models, logs) -- a few MB
#   2. the current distributable archives from ~/share
#   3. live server state from the SourceMod data dir: TSVs, rosters,
#      personas, radio map, clips.sqlite and a *consistent* copy of
#      state.sqlite (sqlite3 .backup, not a raw copy of a hot WAL)
#   4. MANIFEST.txt: timestamps of installed artifacts vs sources, sha256
#      of every archive, and the voice roster in use
#
# Runs entirely as the invoking user; anything unreadable (data/config.json
# is 0600 dod) is listed in the manifest as SKIPPED instead of failing the run.
set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOME_DIR="$(dirname "$SRC")"
TS="$(date +%Y%m%d-%H%M%S)"
DEST="${1:-$HOME/snapshots/twelveactors-$TS}"
STATE_DIR="${STATE_DIR:-/srv/dods/dod/addons/sourcemod/data/twelveactors}"
SHARE_DIR="${SHARE_DIR:-$HOME/share}"

mkdir -p "$DEST" || exit 1
echo "backup -> $DEST"

# 1. source tree (bulk excluded; regenerable with pip / download_voices)
tar -czf "$DEST/twelveactors-src-$TS.tar.gz" -C "$HOME_DIR" \
    --exclude="$(basename "$SRC")/.venv-tts" \
    --exclude="$(basename "$SRC")/voices/*.onnx" \
    --exclude="$(basename "$SRC")/voices/*.onnx.json" \
    --exclude="$(basename "$SRC")/logs" \
    --exclude="$(basename "$SRC")/__pycache__" \
    --exclude="$(basename "$SRC")/twelveactors/__pycache__" \
    "$(basename "$SRC")" || exit 1

# 2. distributables as shipped
for f in "$SHARE_DIR"/twelveactors-*.tar.gz "$SHARE_DIR"/twelveactors-*.zip; do
    [ -e "$f" ] && cp -p "$f" "$DEST/dist-$(basename "$f")"
done

# 3. live state
STATE_TAR="$DEST/server-state-$TS.tar.gz"
if [ -d "$STATE_DIR" ]; then
    stage="$(mktemp -d)"
    mkdir -p "$stage/state"
    skipped=""
    for f in in.tsv out.tsv roster.tsv radio_seen.tsv personas.json voiced.txt \
             radio_map.json clips.sqlite clips.txt daemon.log; do
        if [ -r "$STATE_DIR/$f" ]; then cp -p "$STATE_DIR/$f" "$stage/state/" 2>/dev/null
        else skipped="$skipped $f"; fi
    done
    if [ -r "$STATE_DIR/state.sqlite" ]; then
        sqlite3 "file:$STATE_DIR/state.sqlite?mode=ro" \
            ".backup '$stage/state/state.sqlite'" 2>/dev/null \
            || cp -p "$STATE_DIR/state.sqlite" "$stage/state/" 2>/dev/null
    else
        skipped="$skipped state.sqlite"
    fi
    tar -czf "$STATE_TAR" -C "$stage" state && echo "state: ok ($(du -h "$STATE_TAR" | cut -f1))"
    rm -rf "$stage"
else
    skipped="$skipped ALL(no $STATE_DIR)"
fi

# 4. manifest
MAN="$DEST/MANIFEST.txt"
{
    echo "twelveactors snapshot $TS on $(hostname)"
    echo
    echo "== units"
    for u in dods twelveactors; do printf '%-10s %s\n' "$u" "$(systemctl is-active "$u" 2>&1)"; done
    echo
    echo "== installed vs source timestamps"
    printf '%-28s %s\n' "installed .smx" "$(ls -l --time-style=+%F_%T /srv/dods/dod/addons/sourcemod/plugins/twelveactors.smx 2>/dev/null | awk '{print $6, $5"B"}')"
    printf '%-28s %s\n' "plugin/twelveactors.sp" "$(ls -l --time-style=+%F_%T "$SRC/plugin/twelveactors.sp" | awk '{print $6, $5"B"}')"
    printf '%-28s %s\n' "installed bridge.py" "$(ls -l --time-style=+%F_%T /opt/twelveactors/twelveactors/bridge.py 2>/dev/null | awk '{print $6, $5"B"}')"
    printf '%-28s %s\n' "twelveactors/bridge.py" "$(ls -l --time-style=+%F_%T "$SRC/twelveactors/bridge.py" | awk '{print $6, $5"B"}')"
    echo
    echo "== installed .smx vs source .sp (newer source = live binary is stale)"
    for p in twelveactors ta_botjoin ta_humancap ta_bots_rcbot2; do
        sp="$SRC/plugin/$p.sp"; smx="/srv/dods/dod/addons/sourcemod/plugins/$p.smx"
        s1=$(stat -c %Y "$sp" 2>/dev/null); s2=$(stat -c %Y "$smx" 2>/dev/null)
        printf '%-22s smx=%s sp=%s %s\n' "$p" \
            "$(date -d "@${s2:-0}" +%F_%T 2>/dev/null)" \
            "$(date -d "@${s1:-0}" +%F_%T 2>/dev/null)" \
            "$([ -n "$s2" ] && [ "${s2:-0}" -ge "${s1:-0}" ] && echo ok || echo STALE)"
    done
    echo "(scripting/ copies are only refreshed by install.sh; they are not the live build)"
    echo
    echo "== piper voices present (models not archived)"
    ls -1 "$SRC/voices"/*.onnx 2>/dev/null | xargs -r -n1 basename
    echo
    echo "== skipped (unreadable as $(id -un))"
    echo "${skipped:- none}"
    echo
    echo "== archives"
    ( cd "$DEST" && sha256sum *.tar.gz *.zip 2>/dev/null )
} > "$MAN"

echo
ls -lh "$DEST"
echo
cat "$MAN"
