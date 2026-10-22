#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
#
# Live migration: bivouac -> twelveactors
#
# Run this AFTER the source tree has been renamed and rebuilt (make-dist.sh
# and install.sh's compile step both produce the ta_*.smx files this script
# installs). Dry-run by default; it prints every action and changes nothing.
#
#   sudo bash install-rename.sh            # dry run, safe
#   sudo bash install-rename.sh --apply    # do it
#
# This file is EXCLUDED from the rename's text-substitution pass on purpose:
# every old name below is literal data it has to match on the live server (old
# cfg filenames, old paths, the sm_bivouac_ / sm_biv_ patterns). A blanket
# find-and-replace rewrites them to the new names, and the migration then does
# nothing, without an error line. Do not "tidy" them.
#
# Rollback is described at the bottom of this file.

set -euo pipefail

DRY_RUN=1
case "${1:-}" in
    --apply) DRY_RUN=0 ;;
    --dry-run|"") DRY_RUN=1 ;;
    -h|--help) sed -n '5,18p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
esac

SM_DIR=/srv/dods/dod/addons/sourcemod
DATA_OLD="$SM_DIR/data/bivouac"
DATA_NEW="$SM_DIR/data/twelveactors"
OPT_OLD=/opt/bivouac
OPT_NEW=/opt/twelveactors
UNIT_OLD=bivouac.service
UNIT_NEW=twelveactors.service
PLUGINS="$SM_DIR/plugins"
SCRIPTING="$SM_DIR/scripting"
CFGDIR=/srv/dods/dod/cfg/sourcemod
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC=$SELF_DIR

say()  { printf '\n== %s\n' "$*"; }
note() { printf '   %s\n' "$*"; }
run()  {
    printf ' + %s\n' "$*"
    if [ "$DRY_RUN" -eq 0 ]; then "$@"; fi
}
runsh() {
    printf ' + %s\n' "$*"
    if [ "$DRY_RUN" -eq 0 ]; then bash -c "$*"; fi
}
die() { printf 'ABORT: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight
say "preflight"
[ "$(id -u)" -eq 0 ] || die "must run as root (sudo bash $0 --apply)"
[ -d "$SM_DIR" ]     || die "no sourcemod dir at $SM_DIR"
[ -d "$OPT_OLD" ]    || die "no deployed bridge at $OPT_OLD"
[ ! -e "$OPT_NEW" ]  || die "$OPT_NEW already exists; refusing to overwrite"
[ -d "$DATA_OLD" ]   || die "no data dir at $DATA_OLD"
[ ! -e "$DATA_NEW" ] || die "$DATA_NEW already exists; refusing to overwrite"
SPCOMP=$SM_DIR/scripting/spcomp64
[ -x "$SPCOMP" ] || SPCOMP=$SM_DIR/scripting/spcomp
[ -x "$SPCOMP" ] || die "no spcomp in $SM_DIR/scripting"
INCLUDE=$SM_DIR/scripting/include
for f in twelveactors ta_bots_rcbot2 ta_botjoin ta_humancap ta_proximity ta_cmdspy; do
    [ -s "$SRC/plugin/$f.sp" ] || die "missing $SRC/plugin/$f.sp"
done
[ -s "$SRC/tools/label_radio.py" ] || die "missing $SRC/tools/label_radio.py"
BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ta-rename.XXXXXX")
trap 'rm -rf "$BUILD_DIR"' EXIT
[ -s "$SRC/systemd/$UNIT_NEW" ]    || die "missing $SRC/systemd/$UNIT_NEW"
# the script must still contain the OLD names it has to match live; if the tree-wide
# rename pass ever touches this file, these two tripwires fire instead of a silent no-op
grep -q 'sm_bivouac_/sm_ta_' "$0" || die "install-rename.sh was rewritten (cfg sed rule gone); the cvar rename would silently no-op"
grep -q '/data/bivouac' "$0"       || die "install-rename.sh was rewritten (old data dir gone); it would migrate nothing"
note "tree: $SRC"
note "mode: $([ "$DRY_RUN" -eq 1 ] && echo DRY-RUN || echo APPLY)"
BAK_COUNT=$(ls -d "$OPT_OLD"/bivouac.bak.* 2>/dev/null | wc -l)
note "package backups nested in $OPT_OLD: $BAK_COUNT"

# ------------------------------------------------------- 1. stop the daemon
say "stop and disable $UNIT_OLD (before touching the data dir: state.sqlite-wal is un-checkpointed)"
if systemctl is-enabled --quiet "$UNIT_OLD" 2>/dev/null; then
    run systemctl disable "$UNIT_OLD"
fi
run systemctl stop "$UNIT_OLD" || true

# ------------------------------------------------------------ 2. data dir
DATA_FILES=$(find "$DATA_OLD" -type f | wc -l)
say "move data dir ($DATA_FILES files, incl. state.sqlite + wal/shm, config.json 0600)"
run mv "$DATA_OLD" "$DATA_NEW"

# ------------------------------------------------------------- 3. /opt tree
say "move deployed bridge and its package dir"
run mv "$OPT_OLD" "$OPT_NEW"
run mv "$OPT_NEW/bivouac" "$OPT_NEW/twelveactors"
runsh "rm -rf '$OPT_NEW/twelveactors/__pycache__'"
note "the $BAK_COUNT bivouac.bak.* package copies travel with the directory (old name kept; rollback material)"

# ---------------------------------------------------------------- 4. unit
say "install $UNIT_NEW, then retire $UNIT_OLD"
run install -o root -g root -m 644 "$SRC/systemd/$UNIT_NEW" "/etc/systemd/system/$UNIT_NEW"
run systemctl daemon-reload
run systemctl enable --now "$UNIT_NEW"
if [ -f "/etc/systemd/system/$UNIT_OLD" ]; then
    run mv "/etc/systemd/system/$UNIT_OLD" "/etc/systemd/system/$UNIT_OLD.pre-rename"
fi
run systemctl daemon-reload

# ------------------------------------------------- 4b. the ta-radio helper
say "install ta-radio from the tree (the deployed biv-radio still points at data/bivouac)"
if [ -e /usr/local/bin/biv-radio ]; then
    run mv /usr/local/bin/biv-radio /usr/local/bin/biv-radio.pre-rename
fi
run install -o root -g root -m 755 "$SRC/tools/label_radio.py" /usr/local/bin/ta-radio
note "rollback: mv /usr/local/bin/biv-radio.pre-rename /usr/local/bin/biv-radio"

# ------------------------------------------------------------- 5. plugins
say "compile the six plugins from source with the server's spcomp (no .smx is committed any more: build/ held a stale copy of ta_bots_rcbot2 and was removed 21 Oct 2026)"
note "compiler: $SPCOMP"
if [ "$DRY_RUN" -eq 0 ]; then
    cp "$SRC"/plugin/twelveactors.sp "$SRC"/plugin/ta_bots_rcbot2.sp \
       "$SRC"/plugin/ta_botjoin.sp "$SRC"/plugin/ta_humancap.sp \
       "$SRC"/plugin/ta_proximity.sp "$SRC"/plugin/ta_cmdspy.sp "$BUILD_DIR"/
    ( cd "$BUILD_DIR" && for f in *.sp; do
          "$SPCOMP" -i"$INCLUDE" "$f" >/dev/null || exit 1
          [ -s "${f%.sp}.smx" ] || { echo "compile produced no ${f%.sp}.smx" >&2; exit 1; }
      done ) || die "compile failed — nothing was installed"
    for f in "$BUILD_DIR"/*.smx; do note "built $(basename "$f") $(stat -c%s "$f") bytes"; done
else
    note "would compile six .sp from $SRC/plugin into a temp dir, then install those"
fi

say "install the renamed .smx set and remove the old bivouac/biv_*.smx (removal, not shadowing)"
for p in twelveactors ta_bots_rcbot2 ta_botjoin ta_humancap ta_proximity ta_cmdspy; do
    run install -o dod -g dod -m 644 "$BUILD_DIR/$p.smx" "$PLUGINS/$p.smx"
done
for old in bivouac.smx bivouac_bots_rcbot2.smx biv_botjoin.smx biv_humancap.smx biv_proximity.smx biv_cmdspy.smx biv_echo.smx; do
    if [ -f "$PLUGINS/$old" ]; then
        run mv "$PLUGINS/$old" "$PLUGINS/$old.pre-rename"
    fi
done
note "*.smx.bak.* files are inert (extension is not .smx) and are left alone"

say "install renamed .sp sources, retire the old ones"
for f in twelveactors ta_bots_rcbot2 ta_botjoin ta_humancap ta_proximity ta_cmdspy; do
    run install -o dod -g dod -m 644 "$SRC/plugin/$f.sp" "$SCRIPTING/$f.sp"
done
for old in bivouac.sp bivouac_bots_rcbot2.sp biv_proximity.sp; do
    if [ -f "$SCRIPTING/$old" ]; then
        run mv "$SCRIPTING/$old" "$SCRIPTING/$old.pre-rename"
    fi
done

# ---------------------------------------------------------------- 6. cfgs
say "write ta_*.cfg with sm_ta_* names, retire the old cfg files"
cfg_map() {  # cfg_map <old> <new>
    local old=$1 new=$2
    local oldbase=${old%.cfg} newbase=${new%.cfg}
    printf ' + sed sm_biv[ouac]*_ -> sm_ta_  %s > %s\n' "$old" "$new"
    if [ "$DRY_RUN" -eq 0 ]; then
        sed -e 's/\bsm_bivouac_/sm_ta_/g' -e 's/\bsm_biv_/sm_ta_/g' \
            -e "s/\\b${oldbase}\\.smx\\b/${newbase}.smx/g" \
            "$CFGDIR/$old" > "$CFGDIR/$new"
        chown dod:dod "$CFGDIR/$new"
        chmod 644 "$CFGDIR/$new"
    fi
    if [ -f "$CFGDIR/$old" ]; then
        run mv "$CFGDIR/$old" "$CFGDIR/$old.pre-rename"
    fi
}
[ -f "$CFGDIR/biv_humancap.cfg" ]  && cfg_map biv_humancap.cfg  ta_humancap.cfg
[ -f "$CFGDIR/biv_proximity.cfg" ] && cfg_map biv_proximity.cfg ta_proximity.cfg

say "rewrite warmode load lines (they name plugin files)"
if [ -f "$CFGDIR/sm_warmode_on.cfg" ]; then
    printf ' + sed bivouac_bots_rcbot2.smx/bivouac.smx -> ta_bots_rcbot2.smx/twelveactors.smx  sm_warmode_on.cfg\n'
    if [ "$DRY_RUN" -eq 0 ]; then
        cp -p "$CFGDIR/sm_warmode_on.cfg" "$CFGDIR/sm_warmode_on.cfg.pre-rename"
        sed -i -e 's/\bbivouac_bots_rcbot2\.smx\b/ta_bots_rcbot2.smx/g' \
               -e 's/\bbivouac\.smx\b/twelveactors.smx/g' "$CFGDIR/sm_warmode_on.cfg"
    fi
fi

# -------------------------------------------------------------- 7. restart
say "restart the game server so SourceMod reloads plugins"
run systemctl restart dods

# ---------------------------------------------------------------- 8. verify
say "verify"
if [ "$DRY_RUN" -eq 0 ]; then
    sleep 4
    systemctl is-active "$UNIT_NEW" || die "$UNIT_NEW is not running"
    curl -fsS --max-time 5 http://127.0.0.1:8377/healthz && echo || die "health endpoint did not answer"
    echo "-- plugins present --"
    ls -1 "$PLUGINS"/twelveactors.smx "$PLUGINS"/ta_*.smx 2>/dev/null || true
    echo "-- stale plugin files (expect six .pre-rename, no live .smx) --"
    ls -1 "$PLUGINS"/bivouac*.smx "$PLUGINS"/biv_*.smx 2>/dev/null || echo "   none"
    echo "-- sourcemod log, last errors --"
    tail -n 200 "$SM_DIR/logs/"*.log 2>/dev/null | grep -iE "native not found|failed|error" | tail -20 || true
    echo
    echo "Now check in game or via console: sm_ta_status (expect 12 bots, voiced > 0)"
    echo "and sm plugins list (expect 'Twelve Actors Core', 'Twelve Actors Bots (RCBot2)'),"
    echo "with no duplicate plugin warnings."
else
    note "dry run: nothing was stopped, moved, installed or restarted"
fi

# --------------------------------------------------------------- rollback
#   sudo systemctl disable --now twelveactors.service
#   sudo mv /opt/twelveactors /opt/twelveactors.failed
#   sudo mv /opt/twelveactors.failed/bivouac.bak.<stamp> /opt/bivouac   # newest package backup
#   sudo mv /srv/dods/dod/addons/sourcemod/data/twelveactors \
#           /srv/dods/dod/addons/sourcemod/data/bivouac
#   sudo mv /etc/systemd/system/bivouac.service.pre-rename /etc/systemd/system/bivouac.service
#   sudo systemctl daemon-reload && sudo systemctl enable --now bivouac.service
#   # plugins: move the *.pre-rename files back over their original names
#   # cfgs:    move biv_*.cfg.pre-rename back, delete ta_*.cfg
#   sudo systemctl restart dods
