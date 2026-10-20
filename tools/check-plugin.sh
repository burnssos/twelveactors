#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
# Compile every shipped plugin with the server's own SourceMod compiler.
#
#   tools/check-plugin.sh                 # tree = parent of tools/
#   tools/check-plugin.sh /path/to/tree   # e.g. a freshly extracted archive
#
# Exits 1 on the first file that fails to compile, which is the same check
# install.sh performs — this just runs it without root and without touching an
# install. Warnings are printed and do not fail the build.
set -euo pipefail

SRC="$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd)"
GAME="${GAME:-/srv/dods}"
SPCOMP="${SPCOMP:-$GAME/dod/addons/sourcemod/scripting/spcomp}"
INCLUDE="${INCLUDE:-$GAME/dod/addons/sourcemod/scripting/include}"

[ -x "$SPCOMP" ] || { echo "missing spcomp: $SPCOMP (set SPCOMP=...)" >&2; exit 1; }
[ -d "$INCLUDE" ] || { echo "missing includes: $INCLUDE (set INCLUDE=...)" >&2; exit 1; }
[ -d "$SRC/plugin" ] || { echo "no plugin/ under $SRC" >&2; exit 1; }

BUILD="$(mktemp -d "${TMPDIR:-/tmp}/tacheck.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT

fail=0
for sp in "$SRC"/plugin/*.sp; do
  name="$(basename "$sp")"
  cp "$sp" "$BUILD/"
  if out="$( cd "$BUILD" && "$SPCOMP" -i"$INCLUDE" "$name" 2>&1 )"; then
    # spcomp exits 0 with warnings; surface them but do not fail.
    if grep -qi "warning" <<<"$out"; then
      printf 'warn  %-24s %s\n' "$name" "$(grep -ci 'warning' <<<"$out") warning(s)"
    else
      printf 'ok    %-24s\n' "$name"
    fi
  else
    printf 'FAIL  %-24s\n%s\n' "$name" "$out" >&2
    fail=1
  fi
  rm -f "$BUILD"/*.smx
done

[ "$fail" -eq 0 ] || exit 1
echo "all plugins compile"
