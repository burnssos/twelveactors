#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
# Install the scope filter: off-topic questions get an in-character refusal from
# the persona's own pool instead of a model call.
#
#   sudo ./install-scope-filter.sh [SOURCE_DIR]
#
# Replaces /opt/twelveactors/twelveactors, restarts twelveactors.service. The database gains
# the prompt/source columns on the next connect; existing rows are untouched.
set -euo pipefail

SRC="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
DEST=/opt/twelveactors/twelveactors

[ "$(id -u)" -eq 0 ] || { echo "run as root:  sudo $0" >&2; exit 1; }
[ -f "$SRC/twelveactors/scope.py" ] || { echo "no scope.py under $SRC/twelveactors" >&2; exit 1; }

# Refuse to install a stale tree. The whole package is copied below, so every
# gate rides along — but only if this source actually carries them. Checked
# before anything under /opt is touched, so a half-upgraded tree cannot land.
# The check lives in tools/preflight.py so it can also be run without root.
echo "== preflight =="
[ -f "$SRC/tools/preflight.py" ] || {
  echo "missing $SRC/tools/preflight.py — stale tree, refusing to install" >&2
  exit 1
}
PYTHONDONTWRITEBYTECODE=1 python3 "$SRC/tools/preflight.py" "$SRC"

if [ -d "$SRC/tests" ]; then
  for t in "$SRC"/tests/test_*.py; do
    [ -e "$t" ] || continue
    printf '  %-22s ' "$(basename "$t")"
    out=$(PYTHONDONTWRITEBYTECODE=1 python3 "$t" 2>&1) || {
      echo FAIL
      echo "$out" | tail -25
      exit 1
    }
    echo pass
  done
fi

# A key in the tree would be copied into /opt, where it outlives any cleanup.
echo "== secrets =="
[ -f "$SRC/tools/check-secrets.py" ] || {
  echo "missing $SRC/tools/check-secrets.py — refusing to deploy" >&2
  exit 1
}
PYTHONDONTWRITEBYTECODE=1 python3 "$SRC/tools/check-secrets.py" "$SRC" || {
  echo "credential in the source tree — refusing to deploy" >&2
  exit 1
}

if [ -d "$DEST" ]; then
  backup="$DEST.bak.$(date +%Y%m%d-%H%M%S)"
  cp -a "$DEST" "$backup"
  echo "backup  -> $backup"
fi

rm -rf "$DEST"
cp -r "$SRC/twelveactors" /opt/twelveactors/
find /opt/twelveactors -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null || true
chown -R root:root /opt/twelveactors

# The copy is what runs now: prove the modules that carry the gates landed
# identical to the source instead of trusting cp.
for f in scope.py brain.py bridge.py db.py cards/dods.json; do
  a=$(sha256sum "$SRC/twelveactors/$f" | cut -d' ' -f1)
  b=$(sha256sum "$DEST/$f" | cut -d' ' -f1)
  [ "$a" = "$b" ] || { echo "copy mismatch: $f" >&2; exit 1; }
done
echo "deployed: scope/brain/bridge/db/cards identical to source"

systemctl restart twelveactors.service
sleep 2
echo "== unit =="
systemctl is-active twelveactors.service
echo "== healthz =="
curl -s --max-time 4 http://127.0.0.1:8377/healthz || echo "(no answer — check: journalctl -u twelveactors -n 20)"
echo
echo "== journal =="
journalctl -u twelveactors -n 6 --no-pager
