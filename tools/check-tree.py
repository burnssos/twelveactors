#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
"""Structural checks on the tree. Exits 1 on any failure.

    tools/check-tree.py            # check the repo this file lives in
    tools/check-tree.py /path      # check another tree

Each check exists because the thing it looks for actually happened on
21 October 2026, and in every case a one-second grep would have caught what a
careful read did not. Enforcement belongs in tooling, not in memory --
`tools/check-secrets.py` already makes that argument about credentials.

  1. No tracked .smx. A committed build/ta_bots_rcbot2.smx held a ConVar handle
     that plugin/ta_bots_rcbot2.sp had already had removed, and four scripts
     installed that binary instead of compiling. The documentation asserted the
     fix was complete while a compiled copy of the bug sat in the same tree.

  2. No .sp in two places with different contents. The same incident: build/
     and plugin/ each held five plugins and nothing enforced that they agreed.
     A fix applied to one copy of a file is not a fix.

  3. No script installing a .smx that no compile step produces. The four
     scripts above pointed at a prebuilt path; now they call ta_compile.

  4. Nothing writes a file under addons/rcbot2/. Twelve Actors' licensing
     position is that it writes no file belonging to RCBot2. Six scripts used
     to `sed -i` its config.ini and two rewrote its profiles/*.ini. Reads are
     allowed (tools/rcbot-preflight.sh verifies two values and reports).
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parents[1])
fails: list[str] = []


def tracked() -> list[str]:
    try:
        out = subprocess.run(["git", "-C", str(ROOT), "ls-files"],
                             capture_output=True, text=True, check=True)
        return out.stdout.split()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return []


files = tracked()
in_git = bool(files)

# 1 -- no tracked compiled output
smx = [f for f in files if f.endswith(".smx")]
if smx:
    fails.append("tracked .smx (compiled output must not be committed):\n    "
                 + "\n    ".join(smx))

# 2 -- no .sp duplicated across directories with differing contents
by_name: dict[str, list[Path]] = {}
for sp in ROOT.rglob("*.sp"):
    if ".git" in sp.parts:
        continue
    by_name.setdefault(sp.name, []).append(sp)
for name, paths in sorted(by_name.items()):
    if len(paths) < 2:
        continue
    blobs = {p.read_bytes() for p in paths}
    where = ", ".join(str(p.relative_to(ROOT)) for p in sorted(paths))
    if len(blobs) > 1:
        fails.append(f"{name} exists in {len(paths)} places with DIFFERENT "
                     f"contents: {where}")
    else:
        print(f"note  {name} duplicated but identical: {where}")

# 3 -- no script installing a .smx that nothing compiles
smx_ref = re.compile(r'(?:install|cp)\b[^\n]*?([\w./$"{}-]+\.smx)')
for sh in sorted(ROOT.rglob("*.sh")):
    if ".git" in sh.parts:
        continue
    text = sh.read_text(errors="replace")
    for m in smx_ref.finditer(text):
        path = m.group(1)
        # Fine: a destination, a variable fed by ta_compile, or a tmpdir build.
        if "$TA_SMX" in text or "ta_compile" in text or "TMPD" in path or "$BUILD" in path:
            continue
        if "/plugins/" in path or path.startswith("$PLUGDIR") or path.startswith("$DST") or path.startswith("$SMX_DST"):
            continue  # install destination, not a source
        if "build/" in path:
            fails.append(f"{sh.relative_to(ROOT)}: installs prebuilt {path} "
                         f"(compile from plugin/ via tools/compile.sh instead)")

# 4 -- nothing writes a file belonging to RCBot2
WRITERS = re.compile(
    r"(sed\s+-i|>\s*[\"']?\S*addons/rcbot2|tee\s|write_bytes|write_text|\.chmod|chown)")
for src in sorted(list(ROOT.rglob("*.sh")) + list(ROOT.rglob("*.py"))):
    if ".git" in src.parts or src.name == "check-tree.py":
        continue
    for i, line in enumerate(src.read_text(errors="replace").splitlines(), 1):
        if "addons/rcbot2" not in line and "$PROFILES" not in line and "$RCBOT_CFG" not in line:
            continue
        if line.lstrip().startswith(("#", "//", '"""', "*")):
            continue
        if WRITERS.search(line):
            fails.append(f"{src.relative_to(ROOT)}:{i}: appears to WRITE an "
                         f"RCBot2 file -- reads are fine, writes are not:\n"
                         f"    {line.strip()[:100]}")

if not in_git:
    print("note  not a git checkout; skipped the tracked-file checks")

if fails:
    print()
    for f in fails:
        print(f"FAIL  {f}", file=sys.stderr)
    print(f"\n{len(fails)} structural check(s) failed", file=sys.stderr)
    sys.exit(1)

print("ok: no tracked .smx, no divergent duplicate plugins, no prebuilt "
      "installs, no writes to RCBot2 files")
