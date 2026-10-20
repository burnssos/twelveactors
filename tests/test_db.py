# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
"""Storage tests: hostile chat text is data, never SQL.

The gate refuses injection-shaped lines (scope.classify -> "injection"), but
refused turns are still logged, and a future caller might skip the gate. These
tests prove the database layer itself cannot be talked into executing player
text: every value is bound as a parameter, so a payload round-trips intact and
the schema is untouched.

Run: python3 -m pytest tests -q   (or python3 tests/test_db.py)
"""
from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from twelveactors import db as dbm  # noqa: E402
from twelveactors import scope  # noqa: E402

CARDS = json.loads((ROOT / "twelveactors/cards/dods.json").read_text())

PAYLOADS = [
    "'; drop table turns; --",
    "1' or '1'='1",
    "'); delete from bots; --",
    "pragma table_info(turns)",
    "union select name from sqlite_master",
    "'; update turns set line='pwned'; --",
]


def _schema(db) -> set[str]:
    return {r[0] for r in db.execute(
        "SELECT name FROM sqlite_master WHERE type='table'")}


def test_injection_is_data() -> int:
    bad = 0
    with tempfile.TemporaryDirectory() as td:
        db = dbm.connect(Path(td) / "state.sqlite")
        before = _schema(db)
        for i, payload in enumerate(PAYLOADS):
            name = f"Otto'; drop table bots; --{i}"
            dbm.ensure_bot(db, name, "german", CARDS)
            dbm.log_turn(db, name, "Burnside", payload, "ack",
                         "Negative.", "clip.wav", "filter")
        if _schema(db) != before:
            bad += 1
            print(f"FAIL schema changed: {before} -> {_schema(db)}")
        rows = db.execute(
            "SELECT prompt FROM turns WHERE speaker LIKE 'Otto%' ORDER BY id").fetchall()
        stored = [r["prompt"] for r in rows]
        if stored != PAYLOADS:
            bad += 1
            print(f"FAIL payloads not stored verbatim: {stored!r}")
        # The table still answers and the quotes are literal, not syntax.
        hit = db.execute("SELECT COUNT(*) FROM bots WHERE name=?",
                         ("Otto'; drop table bots; --0",)).fetchone()[0]
        if hit != 1:
            bad += 1
            print(f"FAIL quoted name lookup returned {hit}, want 1")
        # And the classifier refuses the same lines before any model call.
        profile = json.loads((ROOT / "twelveactors/profiles/dods.json").read_text())
        for payload in PAYLOADS:
            v = scope.classify(payload, profile)
            if v.allowed or v.reason != "injection":
                bad += 1
                print(f"FAIL classify({payload!r}) = {v}, want injection")
    print(f"{len(PAYLOADS)} payloads stored as data, gate reason injection"
          f"{'' if not bad else f' — {bad} problem(s)'}")
    return bad


if __name__ == "__main__":
    sys.exit(1 if test_injection_is_data() else 0)
