# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
#
# Shared compile helper. POSIX sh; source it, do not execute it.
#
#   TA_REPO="$HERE"; . "$HERE/tools/compile.sh"
#   SMX=$(ta_compile ta_bots_rcbot2) || exit 1
#   install -o dod -g dod -m 644 "$SMX" "$PLUGDIR/ta_bots_rcbot2.smx"
#
# WHY THIS EXISTS: four scripts used to install a prebuilt build/*.smx. On
# 21 Oct 2026 build/ta_bots_rcbot2.sp was found to still contain a ConVar handle
# that plugin/ta_bots_rcbot2.sp had already had removed — so those four scripts
# were shipping the uncorrected plugin while the documentation said otherwise.
# build/ is gone and *.smx is gitignored. Everything compiles from plugin/ now.
#
# Compiles into a temp dir, never into the source tree or the plugins dir: that
# is what avoids the spcomp "error 419" permission failure and the root-owned
# output that follows it. The caller installs with explicit ownership.

SM_SCRIPTING="${SM_SCRIPTING:-/srv/dods/dod/addons/sourcemod/scripting}"
TA_BUILD_DIR=""

ta_compile() {
    ta_name=$1
    ta_src="${TA_REPO:?TA_REPO must be set before sourcing compile.sh}/plugin/${ta_name}.sp"

    [ -f "$ta_src" ] || { echo "ta_compile: no source at $ta_src" >&2; return 1; }

    ta_spcomp="$SM_SCRIPTING/spcomp64"
    [ -x "$ta_spcomp" ] || ta_spcomp="$SM_SCRIPTING/spcomp"
    [ -x "$ta_spcomp" ] || {
        echo "ta_compile: no spcomp in $SM_SCRIPTING" >&2
        echo "            set SM_SCRIPTING=/path/to/sourcemod/scripting" >&2
        return 1
    }

    [ -n "$TA_BUILD_DIR" ] || {
        TA_BUILD_DIR=$(mktemp -d) || return 1
        # shellcheck disable=SC2064
        trap "rm -rf '$TA_BUILD_DIR'" EXIT HUP INT TERM
    }

    ta_out="$TA_BUILD_DIR/${ta_name}.smx"
    ta_log="$TA_BUILD_DIR/${ta_name}.log"

    # Not piped, so the exit status is spcomp's own. spcomp exits 0 on warnings,
    # so the -s test below is the real check: a failed compile leaves no output.
    if ! "$ta_spcomp" -i "$SM_SCRIPTING/include" -o "$ta_out" "$ta_src" >"$ta_log" 2>&1; then
        echo "ta_compile: $ta_name FAILED to compile" >&2
        sed -n '$p;/error/p' "$ta_log" >&2
        return 1
    fi
    [ -s "$ta_out" ] || {
        echo "ta_compile: $ta_name produced no .smx (see $ta_log)" >&2
        return 1
    }

    if grep -qi "warning" "$ta_log"; then
        echo "ta_compile: $ta_name compiled with warnings:" >&2
        grep -i "warning" "$ta_log" >&2
    fi

    echo "$ta_out"
}
