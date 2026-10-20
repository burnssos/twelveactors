#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
"""tools/preflight.py must pass a good tree and name what is wrong in a bad one.

The installer refuses to touch /opt unless this check exits 0, so a false pass
is worse than a false failure: it would deploy a tree with a dead gate. Each
case below damages one thing and asserts the matching complaint.
"""

import json
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
PREFLIGHT = ROOT / "tools/preflight.py"


def run(tree):
    p = subprocess.run([sys.executable, str(PREFLIGHT), str(tree)],
                       capture_output=True, text=True,
                       env={"PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1"})
    return p.returncode, (p.stdout + p.stderr).strip()


def clone():
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="pf-test-"))
    shutil.copytree(ROOT / "twelveactors", tmp / "twelveactors",
                    ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    (tmp / "tools").mkdir()
    shutil.copy2(PREFLIGHT, tmp / "tools/preflight.py")
    return tmp


def expect(name, mutate, needle, code=1):
    tree = clone()
    try:
        mutate(tree)
        rc, out = run(tree)
        ok = rc == code and needle in out
        print(f"{'ok  ' if ok else 'FAIL'} {name}: rc={rc} {out.splitlines()[0] if out else ''}")
        return ok
    finally:
        shutil.rmtree(tree, ignore_errors=True)


def main():
    results = []
    rc, out = run(ROOT)
    ok = rc == 0 and out.startswith("preflight ok:")
    print(f"{'ok  ' if ok else 'FAIL'} clean tree: {out.splitlines()[0]}")
    results.append(ok)

    def drop_refusals(t):
        p = t / "twelveactors/cards/dods.json"
        cards = json.loads(p.read_text())
        first = cards["american"][0]
        first["refuse"] = first["refuse"][:1]
        p.write_text(json.dumps(cards))

    results.append(expect("persona short on refusals", drop_refusals,
                          "refusal lines"))

    def duplicate(t):
        p = t / "twelveactors/cards/dods.json"
        cards = json.loads(p.read_text())
        pool = [p for v in cards.values() for p in v]
        pool[1]["refuse"][0] = pool[0]["refuse"][0]
        p.write_text(json.dumps(cards))

    results.append(expect("duplicate refusal line", duplicate, "duplicates"))

    def unprintable(t):
        p = t / "twelveactors/cards/dods.json"
        cards = json.loads(p.read_text())
        cards["german"][0]["refuse"][0] = "Schnauze, Kamerad ☠"
        p.write_text(json.dumps(cards))

    results.append(expect("non-ASCII refusal", unprintable, "printable ASCII"))

    def stale_scope(t):
        p = t / "twelveactors/scope.py"
        p.write_text(p.read_text().replace("MAX_CHARS", "MAX_CHARS_OLD", 1))

    results.append(expect("stale scope.py", stale_scope, "stale or inconsistent"))

    def no_helpers(t):
        p = t / "twelveactors/brain.py"
        p.write_text(p.read_text().replace("def clean_name(", "def _clean_name(", 1))

    results.append(expect("brain.py without clean_name", no_helpers, "clean_name"))

    def no_scope_block(t):
        p = t / "twelveactors/profiles/dods.json"
        prof = json.loads(p.read_text())
        prof.pop("scope", None)
        p.write_text(json.dumps(prof))

    results.append(expect("profile without scope block", no_scope_block,
                          "no scope block"))

    def empty(t):
        shutil.rmtree(t / "twelveactors")

    results.append(expect("missing package", empty, "no twelveactors/scope.py"))

    bad = results.count(False)
    print(f"{len(results) - bad}/{len(results)} preflight checks pass")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
