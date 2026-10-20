#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
"""Check that a Twelve Actors source tree is complete before it is installed.

    python3 tools/preflight.py [SOURCE_DIR]     # default: the tree this file is in

Exits 0 when the tree carries every gate this project expects, 1 with the
reason when it does not. Runs without root, so the same check can be made by
hand before staging a deploy, and the installer calls it before it touches
/opt: a half-upgraded tree must never replace a working install.

What it verifies:

  * scope.py refuses hostile text for the right reason (chars, injection,
    oversize) and still allows ordinary squad chatter
  * sanitize() removes tabs and newlines
  * brain.py exposes the prompt helpers that neutralise an engine-supplied name
  * every persona carries at least three refusal lines, ASCII-printable and
    unique across the whole cast (a refusal is read out by TTS, so an
    unprintable byte would break the clip lookup)
  * the profile carries a scope block the daemon can read
"""

from __future__ import annotations

import json
import pathlib
import sys

REFUSED = [
    ("chars", "Привет, товарищ"),
    ("chars", "Good game 👍"),
    ("chars", "cafe\u0301", "combining accent"),
    ("injection", "'; drop table turns; --"),
    ("oversize", None),  # built from scope.MAX_CHARS below
]
ALLOWED = [
    "drop your weapons",
    "select fire is on",
    "Otto, ammo on the flank",
]
HELPERS = ("clean_name", "quote", "compose_user")
MIN_REFUSALS = 3
MAX_REFUSAL_CHARS = 240


def _fail(msg: str) -> int:
    print(msg)
    return 1


def check(src: pathlib.Path) -> int:
    sys.path.insert(0, str(src))
    try:
        from twelveactors import brain, scope
    except Exception as exc:  # missing file, syntax error, stale name
        return _fail(f"source is stale or inconsistent: cannot import the "
                     f"package from {src}: {type(exc).__name__}: {exc}")

    problems: list[str] = []

    # --- the gate itself ---------------------------------------------------
    try:
        cases = [(want, text if text is not None
                  else "x" * (scope.MAX_CHARS + 1))
                 for want, text, *_ in REFUSED]
        for want, text in cases:
            got = scope.classify(text)
            if got.reason != want:
                problems.append(f"{want} not refused: {text[:40]!r} "
                                f"(got {got.reason or 'allowed'})")
        for text in ALLOWED:
            if not scope.classify(text).allowed:
                problems.append(f"legitimate line refused: {text!r}")
        if scope.sanitize("a\tb\nc  d") != "a b c d":
            problems.append("sanitize leaves control characters in place")
    except Exception as exc:
        return _fail(f"source is stale or inconsistent: "
                     f"{type(exc).__name__}: {exc}")

    # --- prompt hardening --------------------------------------------------
    for name in HELPERS:
        if not callable(getattr(brain, name, None)):
            problems.append(f"brain.py lacks {name}()")

    # --- personas ----------------------------------------------------------
    try:
        cards = json.loads((src / "twelveactors/cards/dods.json").read_text())
    except Exception as exc:
        return _fail(f"cannot read cards/dods.json: {exc}")
    personas = [p for pool in cards.values() for p in pool]
    seen: dict[str, str] = {}
    for p in personas:
        pid = p.get("id", "?")
        lines = p.get("refuse") or []
        if len(lines) < MIN_REFUSALS:
            problems.append(f"{pid}: {len(lines)} refusal lines, "
                            f"need {MIN_REFUSALS}")
        for line in lines:
            if not isinstance(line, str) or not line.strip():
                problems.append(f"{pid}: empty refusal line")
                continue
            if any(ord(ch) < 32 or ord(ch) > 126 for ch in line):
                problems.append(f"{pid}: refusal not printable ASCII: {line!r}")
            if len(line) > MAX_REFUSAL_CHARS:
                problems.append(f"{pid}: refusal over {MAX_REFUSAL_CHARS} chars")
            if line in seen:
                problems.append(f"{pid}: refusal duplicates {seen[line]}: "
                                f"{line!r}")
            seen[line] = pid

    # --- profile -----------------------------------------------------------
    try:
        profile = json.loads((src / "twelveactors/profiles/dods.json").read_text())
    except Exception as exc:
        return _fail(f"cannot read profiles/dods.json: {exc}")
    sc = profile.get("scope")
    if not isinstance(sc, dict):
        problems.append("profile has no scope block")
    else:
        for key in ("enabled", "max_words", "repeat_window_s"):
            if key not in sc:
                problems.append(f"scope block lacks {key}")
        if not isinstance(sc.get("max_words"), int) or sc.get("max_words", 0) <= 0:
            problems.append("scope.max_words must be a positive integer")

    if problems:
        print("\n".join(f"- {p}" for p in problems))
        return 1

    print(f"preflight ok: {len(cases)} hostile lines refused, "
          f"{len(ALLOWED)} squad lines allowed, sanitize + prompt quoting, "
          f"{len(personas)} personas x{MIN_REFUSALS}+ refusals, "
          f"scope block present")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) > 1 and argv[1] in ("-h", "--help"):
        print(__doc__.strip())
        return 0
    here = pathlib.Path(__file__).resolve().parents[1]
    src = pathlib.Path(argv[1]).resolve() if len(argv) > 1 else here
    if not (src / "twelveactors/scope.py").is_file():
        return _fail(f"no twelveactors/scope.py under {src}")
    return check(src)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
