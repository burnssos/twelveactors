#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
# Bundle the whole distribution plus its docs into one .zip that can be handed
# to another machine (or another agent) as a single file.
#
#   tools/make-handoff-zip.sh                  -> ~/share/twelveactors-handoff-<date>.zip
#   OUT=/tmp VERSION=1.1.0 tools/make-handoff-zip.sh
#
# Rebuilds the distributable first, so the bundle can never disagree with the
# tree:
#
#   START-HERE.md                  what to read, what to supply
#   twelveactors-<ver>/                 the full distributable tree
#   twelveactors-<ver>.tar.gz           same tree, for a Linux box
#   TWELVEACTORS-WORK-PERFORMED.md      what was built and where (loose copy)
#   TWELVEACTORS-HANDOFF.md             state and operating notes (loose copy)
#   HERMES-REBUILD.md              rebuild-from-source notes (loose copy)
#   README.md                      overview (loose copy)
#   MANIFEST.txt / SHA256SUMS.txt  contents and hashes
#
# Refuses to write the zip if a credential scan fails, and re-verifies from the
# extracted archive afterwards: a staging directory that passes proves nothing
# about what zip actually wrote.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-$HOME/share}"
VERSION="${VERSION:-1.0.0}"
DIST="$OUT/twelveactors-$VERSION"
STAMP="$(date +%Y%m%d-%H%M%S)"
NAME="twelveactors-handoff-$STAMP"
ZIP="$OUT/$NAME.zip"

say() { printf '%s\n' "$*"; }

[ -x "$SRC/make-dist.sh" ] || { echo "missing $SRC/make-dist.sh" >&2; exit 1; }

say "== rebuilding the distributable from $SRC"
OUT="$OUT" VERSION="$VERSION" "$SRC/make-dist.sh"

[ -f "$OUT/twelveactors-$VERSION.tar.gz" ] || { echo "no tarball built" >&2; exit 1; }

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/tahandoff.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ROOT="$STAGE/$NAME"
mkdir -p "$ROOT"

say "== staging $NAME"
cp -a "$DIST" "$ROOT/"
cp -a "$OUT/twelveactors-$VERSION.tar.gz" "$ROOT/"
for f in TWELVEACTORS-WORK-PERFORMED.md TWELVEACTORS-HANDOFF.md HERMES-REBUILD.md README.md; do
  [ -f "$SRC/$f" ] && cp -a "$SRC/$f" "$ROOT/"
done

cat > "$ROOT/START-HERE.md" <<'MD'
# Start here

This archive is the complete Twelve Actors distribution (Day of Defeat: Source NPC
chat bridge, SourceMod plugins and an HTTP model bridge) together with the
notes for how it was built.

## Read in this order

1. `TWELVEACTORS-WORK-PERFORMED.md` — every mechanism built so far, each claim cited
   to `path:line` in the code next to it.
2. `TWELVEACTORS-HANDOFF.md` — current state, ports, paths, operating commands.
3. `HERMES-REBUILD.md` — rebuilding the SourceMod plugins from source.
4. `README.md` — overview and quick start.

## What you must supply

Nothing that costs money is baked in. Before the bridge can answer a single
line you need to provide three values:

| setting           | where                     | notes |
|-------------------|---------------------------|-------|
| API base URL      | `config.json: api_base`   | any OpenAI-compatible `/chat/completions` endpoint |
| API key           | `config.json: api_key`    | starts as `<YOUR_API_KEY>`; the daemon cannot call anything until it is real |
| model id          | `config.json: model`      | see below |

The installer asks for all three. With a TTY it prompts (the key is read
hidden); without one it writes the placeholders and prints the exact file and
restart command. You can also pass them non-interactively:

```bash
sudo TWELVEACTORS_API_BASE='https://your-endpoint/v1' \
     TWELVEACTORS_API_KEY='...' \
     TWELVEACTORS_MODEL='your-model-id' \
     bash install.sh
```

Verify afterwards with `curl -s localhost:8377/healthz` — it should report
`"ok": true` and your model id in `"model"`. If every reply is a canned bark,
the first model call failed: check the key and the endpoint.

## Model choice

**Recommended: `deepseek-v4-flash-0731`** — measured at roughly $0.0002 per
reply at this prompt size, and it honours a small `max_tokens` without
truncating its JSON.

Any model that meets this contract works:

- OpenAI-style `POST {api_base}/chat/completions`, `messages` array;
- returns a JSON object (a single short line of dialogue in it);
- honours `max_tokens` around 600 (a reasoning model that spends the budget
  thinking returns truncated JSON and falls back to a canned bark);
- low latency — a reply is spoken into a live game.

Change it at any time with `install-model-switch.sh <model-id>`; with no id it
prints the recommendation and changes nothing. `curl {api_base}/models` lists
what your key can reach.

## Secrets

The tree was scanned before packaging (`tools/check-secrets.py`) and carries no
credential. Keep it that way: never commit a filled-in `config.json`, and
re-run the scanner before you repackage or publish anything derived from this.
MD

say "== scanning the staged tree for credentials"
if ! python3 "$SRC/tools/check-secrets.py" -q "$ROOT"; then
  echo "BUILD ABORTED: the bundle would carry a credential." >&2
  exit 1
fi
say "secrets: none in $ROOT"

# Manifest of exactly what is being shipped.
{
  echo "name:      $NAME"
  echo "built:     $(date -u '+%Y-%m-%dT%H:%M:%SZ') (UTC)"
  echo "host:      $(uname -srm)"
  echo "version:   $VERSION"
  echo "files:     $(find "$ROOT" -type f | wc -l)"
  echo "bytes:     $(du -sb "$ROOT" | cut -f1)"
  echo "dist files: $(find "$DIST" -type f | wc -l)"
  echo
  echo "--- twelveactors-$VERSION (distributable) ---"
  ( cd "$ROOT" && find "twelveactors-$VERSION" -type f | sort )
  echo
  echo "--- loose documents ---"
  ( cd "$ROOT" && find . -maxdepth 1 -type f | sed 's|^\./||' | sort )
} > "$ROOT/MANIFEST.txt"

( cd "$ROOT" && find . -type f ! -name SHA256SUMS.txt -print0 \
    | sort -z | xargs -0 sha256sum ) > "$ROOT/SHA256SUMS.txt"

say "== writing $ZIP"
rm -f "$ZIP"
( cd "$STAGE" && zip -qr "$ZIP" "$NAME" )

# ---- verify from the extracted archive, not the staging dir ------------------
VSTAGE="$(mktemp -d "${TMPDIR:-/tmp}/taverify.XXXXXX")"
trap 'rm -rf "$STAGE" "$VSTAGE"' EXIT
unzip -q "$ZIP" -d "$VSTAGE"
V="$VSTAGE/$NAME"

python3 "$V/twelveactors-$VERSION/tools/check-secrets.py" -q "$V" \
  || { echo "FAIL: extracted bundle carries a credential" >&2; exit 1; }
python3 "$V/twelveactors-$VERSION/tools/preflight.py" "$V/twelveactors-$VERSION" \
  || { echo "FAIL: extracted distributable fails preflight" >&2; exit 1; }
for t in "$V/twelveactors-$VERSION"/tests/test_*.py; do
  python3 "$t" >/dev/null || { echo "FAIL: $t" >&2; exit 1; }
done
( cd "$V" && sha256sum -c --quiet SHA256SUMS.txt ) \
  || { echo "FAIL: manifest hashes do not match" >&2; exit 1; }

ZIP_FILES="$(unzip -Z1 "$ZIP" | grep -v '/$' | wc -l)"
say ""
say "built  $ZIP"
say "size   $(du -h "$ZIP" | cut -f1)"
say "files  $ZIP_FILES (archive entries)"
say "sha256 $(sha256sum "$ZIP" | cut -d' ' -f1)"
say "verified: extracted bundle scans clean, passes preflight, $(ls "$V/twelveactors-$VERSION"/tests/test_*.py | wc -l) test suites, hashes match"
