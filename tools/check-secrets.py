#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
"""Refuse to ship a tree that carries a credential.

    python3 tools/check-secrets.py .
    python3 tools/check-secrets.py --live-config /path/config.json .

Checks every file (text or binary) for:

  * credential-shaped tokens:  VENICE_…, sk-…, sk-proj-…, Bearer …,
    and api_key/api-key/token values long enough to be real;
  * the literal value of the key in --live-config, if given.

Placeholders are fine: "sk-...", "<YOUR_API_KEY>", "REPLACE_ME", "",
"YOUR_KEY_HERE". Nothing is printed in full — a hit shows the first four
characters and the length only, so running this cannot leak the secret it
found. Exit 0 clean, 1 dirty, 2 bad usage.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys

SKIP_DIRS = {".git", "__pycache__", ".pytest_cache", "node_modules"}

# Long, credential-shaped runs only. "sk-..." and "sk-<YOUR_KEY>" are too
# short to match, which is what keeps placeholder docs clean.
PATTERNS = [
    ("venice-prefixed token", re.compile(rb"VENICE_[A-Za-z0-9_-]{20,}")),
    ("openai-style key", re.compile(rb"\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}")),
    ("bearer token", re.compile(rb"Bearer\s+[A-Za-z0-9._~+/=-]{20,}")),
    (
        "api key value",
        re.compile(
            rb"""(?:api[_-]?key|apikey|token)["']?\s*[:=]\s*["']?"""
            rb"""(?!REPLACE|YOUR|<|\$|\{|\s*$)[A-Za-z0-9._~+/=-]{24,}""",
            re.I,
        ),
    ),
]

ALLOW_SUBSTRINGS = (b"REPLACE", b"YOUR", b"CHANGEME", b"EXAMPLE", b"PLACEHOLDER")


def mask(raw: bytes) -> str:
    head = raw[:4].decode("ascii", "replace")
    return f"{head}…({len(raw)} chars, masked)"


def load_live_key(path: str) -> bytes:
    with open(path, "rb") as fh:
        cfg = json.load(fh)
    key = str(cfg.get("api_key", "")).strip()
    if len(key) < 12:
        return b""
    return key.encode()


def scan(root: str, live_key: bytes) -> list[str]:
    findings: list[str] = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            path = os.path.join(dirpath, name)
            try:
                blob = open(path, "rb").read()
            except (OSError, PermissionError):
                continue
            if live_key and live_key in blob:
                findings.append(f"{path}: contains the live API key")
                continue
            for label, rx in PATTERNS:
                for m in rx.finditer(blob):
                    hit = m.group(0)
                    if any(s in hit.upper() for s in ALLOW_SUBSTRINGS):
                        continue
                    line = blob.count(b"\n", 0, m.start()) + 1
                    findings.append(f"{path}:{line}: {label} {mask(hit)}")
    return findings


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("tree", nargs="?", default=".", help="tree to scan")
    ap.add_argument(
        "--live-config",
        metavar="PATH",
        help="config.json holding the real key; scanned for literally",
    )
    ap.add_argument("-q", "--quiet", action="store_true")
    args = ap.parse_args()

    if not os.path.isdir(args.tree):
        print(f"not a directory: {args.tree}", file=sys.stderr)
        return 2

    live_key = b""
    if args.live_config:
        try:
            live_key = load_live_key(args.live_config)
        except (OSError, ValueError) as exc:
            print(f"cannot read live config: {exc}", file=sys.stderr)
            return 2

    findings = scan(args.tree, live_key)
    files = 0
    for _, dirnames, filenames in os.walk(args.tree):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        files += len(filenames)
    if findings:
        print(f"FAIL: {len(findings)} credential hit(s) in {args.tree}", file=sys.stderr)
        for line in findings:
            print("  " + line, file=sys.stderr)
        print(
            "Replace with a placeholder (<YOUR_API_KEY>, REPLACE_ME) or delete the file.",
            file=sys.stderr,
        )
        return 1

    if not args.quiet:
        print(f"ok: no credentials found in {args.tree} ({files} files scanned)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
