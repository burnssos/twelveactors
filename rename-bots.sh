#!/bin/sh
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
# rename-bots.sh — switch the Twelve Actors cast to the new names, keeping history.
#
#   Team USA (6):     John, Paul, Frank, Donald, Thomas, Edward
#   Team German (6):  Walter, Herbert, Alfred, Kurt, Otto, Rolf
#
# What it does:
#   1. backs up cards, personas.json, voiced.txt, profiles 1-12 and state.sqlite
#   2. rewrites the persona cards (source tree, /opt install, share bundle)
#   3. stops the conversation daemon (and restarts it on every exit path)
#   4. renames the bots/memory/turns rows in state.sqlite so each character
#      keeps its history under its new name
#   5. runs `twelveactors bootstrap`, which writes personas.json, voiced.txt and
#      RCBot2 profiles 1..12 (alternating US/DE, so the teams stay 6v6)
#   6. restarts dods.service so RCBot2 re-reads the profiles from disk
#
# Usage:  sudo sh $HERE/rename-bots.sh
#         sudo sh $HERE/rename-bots.sh --no-restart
#
# --no-restart skips the game-server restart: RCBot2 loads profiles at startup,
# so the new names then appear on the next map change or manual restart.
HERE=$(cd "$(dirname "$0")" && pwd)
set -eu

SRC=$HERE
PKG=/opt/twelveactors/twelveactors
SHARE=/home/admin1/share/twelveactors-1.0.0/twelveactors
INSTALL=/srv/dods
DATA=$INSTALL/dod/addons/sourcemod/data/twelveactors
PROFILES=$INSTALL/dod/addons/rcbot2/profiles
PY=/usr/bin/python3
SQLITE=/usr/sbin/sqlite3
[ -x "$SQLITE" ] || SQLITE=sqlite3
CONSOLE=/run/dods/console

RESTART=1
[ "${1:-}" = "--no-restart" ] && RESTART=0

TS=$(date +%Y%m%d-%H%M%S)
BACKUP=$SRC/backup-rename-$TS

[ -f "$SRC/twelveactors/cards/dods.json" ] || { echo "cards not found under $SRC"; exit 1; }
[ -d "$PROFILES" ] || { echo "rcbot2 profiles not found at $PROFILES"; exit 1; }

echo "== backup -> $BACKUP"
mkdir -p "$BACKUP"
cp -a "$SRC/twelveactors/cards/dods.json" "$BACKUP/cards-dods.json"
cp -a "$DATA/personas.json"          "$BACKUP/personas.json"
cp -a "$DATA/voiced.txt"             "$BACKUP/voiced.txt"
for f in 1 2 3 4 5 6 7 8 9 10 11 12; do
    cp -a "$PROFILES/$f.ini" "$BACKUP/profile-$f.ini"
done
"$SQLITE" "$DATA/state.sqlite" ".backup '$BACKUP/state.sqlite'"
echo "   ok"

echo "== rewrite persona cards"
"$PY" - "$SRC/twelveactors/cards/dods.json" "$PKG/cards/dods.json" "$SHARE/cards/dods.json" <<'PY'
import json, sys

us = ["John", "Paul", "Frank", "Donald", "Thomas", "Edward"]
de = ["Walter", "Herbert", "Alfred", "Kurt", "Otto", "Rolf"]

cards = json.load(open(sys.argv[1]))
for key, names in (("american", us), ("german", de)):
    got = cards.get(key) or []
    if len(got) != len(names):
        raise SystemExit(f"{key}: expected {len(names)} cards, found {len(got)}")
    for card, name in zip(got, names):
        card["short"] = name      # in-game name, must match voiced.txt
        card["name"] = name       # persona name shown to the model
        card["id"] = name.lower() # persona key stored in state.sqlite

text = json.dumps(cards, indent=2, ensure_ascii=False) + "\n"
for path in sys.argv[1:]:
    open(path, "w").write(text)
print("   american:", ", ".join(us))
print("   german:  ", ", ".join(de))
PY

echo "== stop conversation daemon"
systemctl stop twelveactors.service 2>/dev/null || true
# The daemon is the only thing that turns in.tsv into out.tsv. If this script
# aborts anywhere below (set -e, a failed bootstrap, a bad profile), the bots
# go completely silent with no error anywhere — so guarantee it comes back.
trap 'systemctl start twelveactors.service >/dev/null 2>&1 || true' EXIT INT TERM HUP

echo "== migrate state.sqlite (same characters, new names)"
"$PY" - "$DATA/state.sqlite" <<'PY'
import sqlite3, sys

# slot order 1..12 is US/DE alternating: Kowalski was slot 1, Kranz slot 2, ...
mapping = {
    "Kowalski": "John",     "Kranz": "Walter",
    "Delgado":  "Paul",     "Vogel": "Herbert",
    "Brennan":  "Frank",    "Reiner": "Alfred",
    "Miller":   "Donald",   "Bach": "Kurt",
    "Okafor":   "Thomas",   "Weiss": "Otto",
    "Rossi":    "Edward",   "Hartmann": "Rolf",
}

db = sqlite3.connect(sys.argv[1], timeout=30)
db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
for old, new in mapping.items():
    if db.execute("SELECT 1 FROM bots WHERE name=?", (new,)).fetchone():
        print(f"   warning: {new} already present, merging {old} into it")
        db.execute("UPDATE bots SET turns=turns+COALESCE((SELECT turns FROM bots WHERE name=?),0) WHERE name=?",
                   (old, new))
        db.execute("DELETE FROM bots WHERE name=?", (old,))
    else:
        db.execute("UPDATE bots SET name=? WHERE name=?", (new, old))
    db.execute("UPDATE OR IGNORE memory SET bot=? WHERE bot=?", (new, old))
    db.execute("DELETE FROM memory WHERE bot=?", (old,))
    # re-point persona every time: older rows drifted between slots
    db.execute("UPDATE bots SET persona=? WHERE name=?", (new.lower(), new))
    # exact name plus rank-prefixed variants ("Cpl.Brennan", "FeldwebelKranz")
    db.execute("UPDATE turns SET speaker=? WHERE speaker=? OR speaker LIKE ?",
               (new, old, "%" + old))
db.commit()
rows = db.execute("SELECT name, persona, faction, turns FROM bots ORDER BY name").fetchall()
print("   bots now:")
for r in rows:
    print(f"     {r[0]:<8} {r[1]:<8} {r[2]:<9} turns={r[3]}")
db.close()
PY

echo "== regenerate profiles, personas.json, voiced.txt"
cd /opt/twelveactors
"$PY" -m twelveactors --data "$DATA" bootstrap --install "$INSTALL" --bots 12

echo "== tidy profile headers"
"$PY" - "$PROFILES" <<'PY'
import re, sys
from pathlib import Path

profiles = Path(sys.argv[1])
for idx in range(1, 13):
    p = profiles / f"{idx}.ini"
    if not p.exists():
        continue
    raw = p.read_bytes().decode("utf-8", errors="replace")
    name = re.search(r"^name\s*=\s*(\S+)", raw, re.M)
    if not name:
        continue
    header = re.search(r"^# Bot Profile id = \d+.*$", raw, re.M)
    if header:
        raw = raw.replace(header.group(0),
                          f"# Bot Profile id = {idx} : Twelve Actors persona ({name.group(1)})")
    p.write_bytes(raw.encode())
print("   headers updated")
PY

chown dod:dod "$PROFILES"/*.ini "$DATA/personas.json" "$DATA/voiced.txt" \
               "$DATA/state.sqlite" "$DATA/state.sqlite-wal" "$DATA/state.sqlite-shm" 2>/dev/null || true
chmod 644 "$PROFILES"/*.ini "$DATA/personas.json" "$DATA/voiced.txt"

if [ "$RESTART" = "1" ]; then
    echo "== restart game server (RCBot2 reads profiles at startup)"
    systemctl restart dods.service
    echo "   waiting 25s for the module to refill the cast"
    sleep 25
    if [ -p "$CONSOLE" ]; then
        printf 'sm_ta_bots\n' > "$CONSOLE" 2>/dev/null || true
        sleep 2
    fi
    echo "== log check"
    journalctl -u dods --since "-40s" --no-pager 2>/dev/null \
        | grep -E "voiced roster loaded|bot module attached|removed unvoiced|Can't create bot" \
        | tail -10 || true
    echo "== names seen in game"
    journalctl -u dods --since "-40s" --no-pager 2>/dev/null \
        | grep -oE '\[sw\] SPAWN [A-Za-z]+' | awk '{print $3}' | sort -u | tr '\n' ' '
    echo
else
    echo "== server restart skipped"
    echo "   new names appear on the next map change or server restart"
fi

# Start unconditionally: the restart branch used to leave the daemon stopped,
# which is exactly how "the bots stopped replying" happens. twelveactors.service is
# PartOf=dods.service, so a dods restart may also have bounced it; `start` is
# a no-op when it is already running.
echo "== start conversation daemon"
systemctl start twelveactors.service || { echo "ERROR: twelveactors.service failed to start" >&2; exit 1; }
systemctl is-active --quiet twelveactors.service || { echo "ERROR: twelveactors.service is not active" >&2; exit 1; }

echo
echo "== result"
for f in 1 2 3 4 5 6 7 8 9 10 11 12; do
    printf '%2s  ' "$f"
    grep -m1 '^name' "$PROFILES/$f.ini" | sed 's/name *= *//'
done
echo "voiced.txt:"
sed 's/^/   /' "$DATA/voiced.txt"
echo "daemon:  $(systemctl is-active twelveactors.service)"
echo "server:  $(systemctl is-active dods.service)"
echo "backup:  $BACKUP"
echo "done"
