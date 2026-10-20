#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
# Build the distributable from this tree.
#
#   ./make-dist.sh            -> ~/share/twelveactors-1.0.0/{.tar.gz,.zip}
#   OUT=/tmp VERSION=1.1.0 ./make-dist.sh
#
# Only source ships: no .smx, no sqlite, no logs, no backups, no host paths.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${OUT:-$HOME/share}"
VERSION="${VERSION:-1.0.0}"
NAME="twelveactors-$VERSION"
DEST="$OUT/$NAME"

rm -rf "$DEST"
mkdir -p "$DEST/plugin" "$DEST/config" "$DEST/tools"

cp -a "$SRC/twelveactors" "$DEST/"
find "$DEST/twelveactors" -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null || true
find "$DEST/twelveactors" -name '*.pyc' -delete 2>/dev/null || true

# Tests ship: the scope gate is the one place a regex can quietly cost money.
[ -d "$SRC/tests" ] && cp -a "$SRC/tests" "$DEST/"
find "$DEST/tests" -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null || true

cp -a "$SRC"/plugin/*.sp "$DEST/plugin/"
cp -a "$SRC/systemd" "$DEST/"
cp "$SRC/config/config.example.json" "$DEST/config/"
# Curated per-bot pitch. Optional: without it the plugin hashes each name.
[ -f "$SRC/config/voices.example.tsv" ] && cp "$SRC/config/voices.example.tsv" "$DEST/config/"
# Tools that ship: anything that runs against a live server and does not bake in
# a developer's home directory. One-off waypoint-editing scripts stay in the tree.
TOOLS="label_radio.py rcon2.py worlddeath_scan.py install-spawnwatch.sh spawnwatch_capture.py install-ta-echo.sh preflight.py check-secrets.py check-plugin.sh make-handoff-zip.sh"
for t in $TOOLS; do
  [ -f "$SRC/tools/$t" ] && cp -a "$SRC/tools/$t" "$DEST/tools/"
done
cp -a "$SRC/tools/dods_spawnwatch.sp" "$SRC/tools/dods_spawnwatch.smx" "$SRC/tools/ta_echo.sp" "$DEST/tools/" 2>/dev/null || true
find "$DEST/tools" -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null || true
cp -a "$SRC/waypoints-final" "$DEST/waypoints"

for f in install.sh install-team-chat.sh install-reply-routing.sh install-model-switch.sh \
         install-scope-filter.sh install-voice.sh deploy-bots.sh make-dist.sh README.md TWELVEACTORS-HANDOFF.md \
         TWELVEACTORS-WORK-PERFORMED.md HERMES-REBUILD.md BOT-JOIN-FIX.md LICENSE .gitignore; do
  [ -f "$SRC/$f" ] && cp -a "$SRC/$f" "$DEST/$f"
done

# A credential must never leave the machine in a distributable. This is fatal,
# not a warning: a published key cannot be un-published.
if ! python3 "$SRC/tools/check-secrets.py" -q "$DEST"; then
  echo "BUILD ABORTED: the archive would carry a credential." >&2
  echo "Fix the file above (placeholder, e.g. <YOUR_API_KEY>) and rebuild." >&2
  exit 1
fi
echo "secrets: none in $DEST"

# no host-specific paths or build products in the archive
HOMEPATH='/home/[A-Za-z0-9_.-]+/twelveactors'
if grep -rnE "$HOMEPATH" "$DEST" \
     --include='*.sh' --include='*.py' --include='*.md' 2>/dev/null \
     | grep -v "$DEST/make-dist.sh" >/dev/null; then
  echo "WARN: archive still contains a developer home path:" >&2
  grep -rnE "$HOMEPATH" "$DEST" --include='*.sh' --include='*.py' --include='*.md' >&2 || true
fi

chmod +x "$DEST"/*.sh "$DEST"/tools/*.sh 2>/dev/null || true

tar -C "$OUT" -czf "$OUT/$NAME.tar.gz" "$NAME"
rm -f "$OUT/$NAME.zip"
(cd "$OUT" && zip -qr "$NAME.zip" "$NAME")

echo "built $OUT/$NAME.tar.gz"
echo "built $OUT/$NAME.zip"
echo "files: $(find "$DEST" -type f | wc -l)"
tar tzf "$OUT/$NAME.tar.gz" | sed -n '1,12p'
