# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
#
# Shared RCBot2 preflight. POSIX sh; source it, do not execute it.
#
#   . "$HERE/tools/rcbot-preflight.sh"
#   ta_rcbot_bounds "$RCBOT_CFG" 12     # verify; print instructions; exit 1 if wrong
#   ta_rcbot_bounds "$RCBOT_CFG" 12 warn   # verify; print; continue anyway
#
# WHY THIS REPLACED `sed -i`
#
# Six scripts used to edit RCBot2's own config/config.ini in place. RCBot2 is
# separately installed software under AGPL-3.0; Twelve Actors is MPL-2.0, and its
# documented position is that it reads and writes no file belonging to another
# program. Six scripts rewriting RCBot2's settings file contradicted that.
#
# So this verifies and instructs instead. The operator edits their own installed
# software, which is what was always meant to happen.
#
# Nothing is lost. The bot module already asserts both bounds through the console
# on every supervisor pass (`ta_bots_rcbot2.sp`), and already issues
# `rcbot_nonrandom_profile 1` the same way at :157 — so the file settings only
# ever covered the ~1 second between map start and plugin load. The file is the
# startup state, not the running state.
#
# Why the file still has to be right at all: config.ini execs AFTER SourceMod
# plugins load, so a wrong value there briefly wins and can start a kick/add
# pass before the module takes over. See design/UPSTREAM-BOT-QUOTA.md (D3) and
# the upstream fix that would remove the need for this function entirely.

# ta_rcbot_bounds <path-to-config.ini> <target-bots> [warn]
ta_rcbot_bounds() {
    ta_cfg=$1
    ta_target=$2
    ta_mode=${3:-strict}

    if [ ! -f "$ta_cfg" ]; then
        echo "  RCBot2 config not found: $ta_cfg" >&2
        echo "  (is RCBot2 installed? it is a separate download — see its own README)" >&2
        [ "$ta_mode" = warn ] && return 0
        return 1
    fi

    ta_min=$(sed -n 's/^rcbotd config min_bots  *\([-0-9][0-9]*\).*/\1/p' "$ta_cfg" | tail -1)
    ta_max=$(sed -n 's/^rcbotd config max_bots  *\([-0-9][0-9]*\).*/\1/p' "$ta_cfg" | tail -1)

    ta_ok=1
    [ "$ta_min" = "0" ] || ta_ok=0
    [ "$ta_max" = "$ta_target" ] || ta_ok=0

    if [ "$ta_ok" = "1" ]; then
        echo "  RCBot2 startup bounds OK: min_bots 0, max_bots $ta_target"
        return 0
    fi

    echo ""
    echo "  RCBot2's startup bounds are not what Twelve Actors expects."
    echo ""
    echo "    file:    $ta_cfg"
    echo "    found:   min_bots=${ta_min:-<unset>}  max_bots=${ta_max:-<unset>}"
    echo "    wanted:  min_bots=0  max_bots=$ta_target"
    echo ""
    echo "  Twelve Actors does not edit RCBot2's files. Please set these two"
    echo "  lines yourself, then re-run:"
    echo ""
    echo "    rcbotd config min_bots 0"
    echo "    rcbotd config max_bots $ta_target"
    echo ""
    echo "  Why these values: max_bots is a TOTAL-CLIENT cap in RCBot2, humans"
    echo "  included — not a bot cap. min_bots 0 stands RCBot2's own population"
    echo "  manager down so the Twelve Actors module owns the roster; without it"
    echo "  the two fight and you get a bot kicked and re-added every 10s."
    echo ""

    [ "$ta_mode" = warn ] && return 0
    return 1
}
