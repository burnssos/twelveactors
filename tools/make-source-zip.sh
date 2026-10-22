#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
# Bundle the WHOLE source tree (not just the distributable subset) together with
# every .md document into one dated .zip that can be handed to another machine
# or another Hermes agent.
#
#   tools/make-source-zip.sh                 -> ~/share/twelveactors-source-<stamp>.zip
#   OUT=/tmp VERSION=1.1.0 tools/make-source-zip.sh
#
# Layout of the archive:
#
#   twelveactors-source-<stamp>/
#     START-HERE.md                  what this is, what to supply, model choice
#     twelveactors/                       the full working tree, as-is
#       <every source file, plugin, installer, tool, test, card>
#       *.md                         the documents also sit inside the tree
#     TWELVEACTORS-WORK-PERFORMED.md      loose copies, for reading without unpacking
#     TWELVEACTORS-HANDOFF.md
#     HERMES-REBUILD.md
#     README.md
#     BOT-JOIN-FIX.md
#     MANIFEST.txt / SHA256SUMS.txt
#
# Excluded on purpose: __pycache__/*.pyc (rebuilt interpreter junk), logs/
# (machine-specific), and the live runtime state (state/*.sqlite*, daemon.log).
# state/config.json travels, but only in its scrubbed template form.
#
# Refuses to write the zip if a credential scan fails, then re-verifies from the
# EXTRACTED archive: secrets scan, preflight, every test suite, and the manifest
# hashes. A clean staging directory proves nothing about what zip actually wrote.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-$HOME/share}"
VERSION="${VERSION:-1.0.0}"
STAMP="$(date +%Y%m%d-%H%M%S)"
NAME="twelveactors-source-$STAMP"
ZIP="$OUT/$NAME.zip"

say() { printf '%s\n' "$*"; }

for f in tools/check-secrets.py tools/preflight.py; do
  [ -f "$SRC/$f" ] || { echo "missing $SRC/$f" >&2; exit 1; }
done

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/tasrc.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ROOT="$STAGE/$NAME"
TREE="$ROOT/twelveactors"
mkdir -p "$TREE"

say "== copying the source tree from $SRC"
# -a keeps modes and symlinks; the filter drops only what cannot be source.
# build/ no longer exists (removed 21 Oct 2026; it held a stale ta_bots_rcbot2.smx).
# compile time. The verification step below runs the test suites inside the
# extracted copy, and test_voice.py recompiles when spcomp is reachable — so any
# .smx in the bundle fails its own checksum a second later. Binaries are also
# not source.
( cd "$SRC" && tar -cf - \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    --exclude='./logs' \
    --exclude='./build' \
    --exclude='*.sqlite' \
    --exclude='*.sqlite-shm' \
    --exclude='*.sqlite-wal' \
    --exclude='daemon.log' \
    . ) | ( cd "$TREE" && tar -xf - )

# The scrubbed runtime config must not hardcode anyone's endpoint in a bundle
# that is meant to be installed elsewhere.
if [ -f "$TREE/state/config.json" ]; then
  python3 - "$TREE/state/config.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["base_url"] = "<YOUR_API_BASE>"
d["api_key"] = "<YOUR_API_KEY>"
json.dump(d, open(p, "w"), indent=2)
open(p, "a").write("\n")
PY
fi

say "== staging loose documents"
for f in TWELVEACTORS-WORK-PERFORMED.md TWELVEACTORS-HANDOFF.md HERMES-REBUILD.md README.md BOT-JOIN-FIX.md; do
  [ -f "$SRC/$f" ] && cp -a "$SRC/$f" "$ROOT/"
done

cat > "$ROOT/START-HERE.md" <<'MD'
# Start here

Complete Twelve Actors source tree — the Day of Defeat: Source NPC chat bridge, its
SourceMod plugins, installers, tools, tests and persona cards —
plus every document written about it.

Nothing here costs money to look at, and nothing is pre-configured: the API
endpoint, the key and the model are yours to supply.

## Read in this order

1. `TWELVEACTORS-WORK-PERFORMED.md` — every mechanism built so far, each claim cited
   to `path:line` in the code that implements it. Start at section 1 for the
   architecture picture, section 12 for a fresh-machine install.
2. `TWELVEACTORS-HANDOFF.md` — current running state, ports, paths, operating
   commands, known failure modes.
3. `HERMES-REBUILD.md` — compiling the `.sp` plugins with spcomp, where the
   `.smx` files must land.
4. `README.md` — short overview and quick start.
5. `BOT-JOIN-FIX.md` — the RCBot2 team-change kill-feed bug and its fix.

## Supply these three values

| setting      | config key   | notes |
|--------------|--------------|-------|
| API base URL | `base_url`   | any OpenAI-compatible `/chat/completions` endpoint |
| API key      | `api_key`    | ships as `<YOUR_API_KEY>`; nothing works until it is real |
| model id     | `model`      | see "Model choice" below |

`install.sh` asks for all three. With a TTY it prompts and reads the key hidden;
without one it writes the `<YOUR_*>` placeholders and prints the exact file to
edit plus the restart command. Non-interactive:

```bash
sudo TWELVEACTORS_API_BASE='https://your-endpoint/v1' \
     TWELVEACTORS_API_KEY='...' \
     TWELVEACTORS_MODEL='your-model-id' \
     bash install.sh
```

Templates carrying the placeholders: `twelveactors/config/config.example.json`
(installed with the dist) and `twelveactors/state/config.json` (scrubbed copy of the
runtime config; the live one belongs at `/srv/dods/...`).

Check it afterwards with `curl -s localhost:8377/healthz` — expect `"ok": true`
and your model id. If every reply is a canned bark, the model call is failing:
wrong key, wrong base URL, or a model id the key cannot reach.

## Model choice — recommendation, not a requirement

**Recommended: `deepseek-v4-flash-0731`.** Measured at roughly $0.0002 per
reply at this prompt size, and it honours a small `max_tokens` without
truncating its JSON.

Any model meeting this contract will work:

- OpenAI-style `POST {base_url}/chat/completions` with a `messages` array;
- returns a JSON object containing one short line of dialogue;
- honours `max_tokens` around 600 — a reasoning model that spends the budget
  thinking emits truncated JSON and the bridge falls back to a canned bark;
- low enough latency for speech inside a live game.

Change it at any time with `install-model-switch.sh <model-id>`; run with no id
and it prints the recommendation without touching the config.
`curl {base_url}/models` lists what your key can actually reach.

## Secrets

The tree is scanned before packaging (`tools/check-secrets.py`) and carries no
credential. Keep it that way: never commit a filled-in `config.json`, and
re-run the scanner before repackaging or publishing anything derived from this.
The scanner prints only a 4-character prefix of anything it finds, so running
it can never leak what it detects.

## Verifying the tree

```bash
python3 twelveactors/tools/check-secrets.py twelveactors   # no credentials
python3 twelveactors/tools/preflight.py   twelveactors     # gates + persona cards sane
for t in twelveactors/tests/test_*.py; do python3 "$t"; done
```

All of the above is what the packaging run itself executes against the
extracted archive before it reports success.
MD

say "== scanning the staged tree for credentials"
if ! python3 "$SRC/tools/check-secrets.py" -q "$ROOT"; then
  echo "BUILD ABORTED: the bundle would carry a credential." >&2
  exit 1
fi
say "secrets: none in staged tree"

{
  echo "name:      $NAME"
  echo "built:     $(date -u '+%Y-%m-%dT%H:%M:%SZ') (UTC)"
  echo "host:      $(uname -srm)"
  echo "version:   $VERSION"
  echo "files:     $(find "$ROOT" -type f ! -name SHA256SUMS.txt | wc -l)"
  echo "bytes:     $(du -sb "$ROOT" | cut -f1)"
  echo
  echo "--- source tree ---"
  ( cd "$ROOT" && find twelveactors -type f | sort )
  echo
  echo "--- loose documents ---"
  ( cd "$ROOT" && find . -maxdepth 1 -type f | sed 's|^\./||' | sort )
} > "$ROOT/MANIFEST.txt"

( cd "$ROOT" && find . -type f ! -name SHA256SUMS.txt -print0 \
    | sort -z | xargs -0 sha256sum ) > "$ROOT/SHA256SUMS.txt"

say "== writing $ZIP"
mkdir -p "$OUT"
rm -f "$ZIP"
( cd "$STAGE" && zip -qr "$ZIP" "$NAME" )

# ---- verify from the extracted archive, not the staging dir ------------------
VSTAGE="$(mktemp -d "${TMPDIR:-/tmp}/taverify.XXXXXX")"
trap 'rm -rf "$STAGE" "$VSTAGE"' EXIT
unzip -q "$ZIP" -d "$VSTAGE"
V="$VSTAGE/$NAME"

python3 "$V/twelveactors/tools/check-secrets.py" -q "$V" \
  || { echo "FAIL: extracted bundle carries a credential" >&2; exit 1; }
python3 "$V/twelveactors/tools/preflight.py" "$V/twelveactors" \
  || { echo "FAIL: extracted tree fails preflight" >&2; exit 1; }
for t in "$V"/twelveactors/tests/test_*.py; do
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
say "verified: extracted tree scans clean, passes preflight, $(ls "$V"/twelveactors/tests/test_*.py | wc -l) test suites, hashes match"
