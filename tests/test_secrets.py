#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
"""tools/check-secrets.py must catch real keys and leave placeholders alone.

make-dist.sh aborts a build on this check, so both error directions matter: a
missed key ships a credential, and a false positive makes the build refuse for
no reason. Each case writes one file into a temp tree and asserts the verdict.
The scanner masks what it finds, so the assertions match on the reason, never
on a secret value.
"""

import json
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
CHECK = ROOT / "tools/check-secrets.py"

FAKE_VENICE = "VENICE_" + "A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8S9t0"
FAKE_SK = "sk-" + "0123456789abcdefghijklmnopqrstuvwxyzABCD"
FAKE_BEARER = "Bearer " + "abcdefghijklmnopqrstuvwxyz0123456789"


def run(tree, *extra):
    p = subprocess.run(
        [sys.executable, str(CHECK), *extra, str(tree)],
        capture_output=True,
        text=True,
        env={"PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1"},
    )
    return p.returncode, (p.stdout + p.stderr).strip()


def check(name, files, want_rc, needle=""):
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="sec-test-"))
    try:
        for rel, body in files.items():
            p = tmp / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            if isinstance(body, bytes):
                p.write_bytes(body)
            else:
                p.write_text(body)
        rc, out = run(tmp)
        ok = rc == want_rc and (needle in out if needle else True)
        if not ok:
            print(f"  FAIL {name}: rc={rc} want={want_rc} out={out[:300]}")
        return ok
    finally:
        import shutil

        shutil.rmtree(tmp, ignore_errors=True)


def main():
    results = []

    results.append(check("clean tree", {"a.py": "print('hello')\n"}, 0))
    results.append(
        check(
            "placeholders are fine",
            {
                "config.json": json.dumps(
                    {"api_key": "<YOUR_API_KEY>", "base_url": "<YOUR_API_BASE>"}
                ),
                "README.md": "key: REPLACE_ME\nBearer sk-...\n",
            },
            0,
        )
    )
    results.append(
        check("venice-prefixed key", {"cfg.py": f"KEY='{FAKE_VENICE}'\n"}, 1, "venice-prefixed")
    )
    results.append(check("openai-style key", {"notes.log": FAKE_SK + "\n"}, 1, "openai-style"))
    results.append(
        check("bearer token", {"headers.txt": f"Authorization: {FAKE_BEARER}\n"}, 1, "bearer")
    )
    results.append(
        check(
            "json api_key value",
            {"config.json": json.dumps({"api_key": "z" * 40})},
            1,
            "api key value",
        )
    )
    results.append(
        check(
            "binary file is scanned",
            {"clip.dat": b"\x00\x01" + FAKE_VENICE.encode() + b"\x00"},
            1,
            "venice-prefixed",
        )
    )

    # The literal-key mode: a config that is not in the tree must still be found
    # if its key was copied somewhere else.
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="sec-live-"))
    try:
        live = tmp / "live.json"
        live.write_text(json.dumps({"api_key": "L" * 32}))
        tree = tmp / "tree"
        tree.mkdir()
        (tree / "copy.txt").write_text("prefix " + "L" * 32 + " suffix\n")
        rc, out = run(tree, "--live-config", str(live))
        ok = rc == 1 and "live API key" in out
        if not ok:
            print(f"  FAIL literal live key: rc={rc} out={out[:300]}")
        results.append(ok)
    finally:
        import shutil

        shutil.rmtree(tmp, ignore_errors=True)

    # A short placeholder in the live config must not make everything a hit.
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="sec-live2-"))
    try:
        live = tmp / "live.json"
        live.write_text(json.dumps({"api_key": "REPLACE_ME"}))
        tree = tmp / "tree"
        tree.mkdir()
        (tree / "a.txt").write_text("nothing here\n")
        rc, _ = run(tree, "--live-config", str(live))
        results.append(rc == 0)
    finally:
        import shutil

        shutil.rmtree(tmp, ignore_errors=True)

    bad = results.count(False)
    print(f"{len(results) - bad}/{len(results)} secret-scan checks pass")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
