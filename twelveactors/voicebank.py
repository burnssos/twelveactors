# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
"""Voice bank: discover a game's shipped speech clips and index them by act.

Nothing is extracted to disk by default; clips are read from the VPK on demand
because the game already has them installed.  What we build is an index:
act -> faction -> [clip paths], with durations, so the daemon can choose a
variant at runtime and the plugin can precache exactly what it needs.
"""
from __future__ import annotations

import json
import re
import sqlite3
from pathlib import Path

from .vpkread import VPK, wav_duration

SCHEMA = """
CREATE TABLE IF NOT EXISTS clips (
    id INTEGER PRIMARY KEY,
    path TEXT NOT NULL UNIQUE,      -- sound-relative, e.g. player/american/us_yessir.wav
    vpk TEXT NOT NULL,
    faction TEXT NOT NULL,
    act TEXT NOT NULL,
    base TEXT NOT NULL,             -- filename without faction prefix / variant digits
    variant INTEGER NOT NULL,
    bytes INTEGER NOT NULL,
    seconds REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS clips_act ON clips(faction, act);
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
"""


def _norm(name: str, prefix: str) -> tuple[str, int]:
    """us_gogogo3 -> ("gogogo", 3); ger_yessir -> ("yessir", 1)."""
    stem = name[:-4] if name.lower().endswith(".wav") else name
    if stem.startswith(prefix):
        stem = stem[len(prefix):]
    m = re.match(r"^(.*?)(\d*)$", stem)
    base, digits = m.group(1), m.group(2)
    return base, int(digits) if digits else 1


def classify(name: str, acts: dict[str, list[str]], prefix: str) -> str | None:
    base, _ = _norm(name, prefix)
    # exact act word match first, then longest-prefix match (moveupmg -> moveupmg)
    for act, words in acts.items():
        if base in words:
            return act
    best, best_len = None, 0
    for act, words in acts.items():
        for w in words:
            if base.startswith(w) and len(w) > best_len:
                best, best_len = act, len(w)
    return best


def scan(profile_path: Path, install: Path, out_db: Path) -> dict:
    profile = json.loads(Path(profile_path).read_text())
    install = Path(install) / profile.get("game_dir", "")
    vpk_dirs = sorted(install.glob("*.vpk"))
    rows: list[tuple] = []
    seen: set[str] = set()

    for vpk_path in vpk_dirs:
        if not vpk_path.name.endswith("_dir.vpk"):
            continue
        vpk = VPK(vpk_path)
        for entry in vpk.entries:
            if "/player/" not in entry.path or not entry.path.endswith(".wav"):
                continue
            rel = entry.path[len("sound/"):] if entry.path.startswith("sound/") else entry.path
            if rel in seen:
                continue
            parts = rel.split("/")
            if len(parts) < 3:
                continue  # sound/player/<foley>.wav — not speech
            faction = parts[1]
            if faction not in ("american", "german", "british"):
                continue
            fname = parts[-1]
            prefix = profile.get("speech_prefix_by_faction", {}).get(
                faction, f"{faction[:3]}_"
            )
            act = classify(fname, profile["acts"], prefix)
            if not act:
                continue
            try:
                blob = vpk.read(entry)
            except Exception:
                continue
            seconds, _, _, _ = wav_duration(blob)
            base, variant = _norm(fname, prefix)
            rows.append((rel, vpk_path.name, faction, act, base, variant, len(blob), seconds))
            seen.add(rel)

    out_db.parent.mkdir(parents=True, exist_ok=True)
    tmp = out_db.with_suffix(".tmp")
    if tmp.exists():
        tmp.unlink()
    db = sqlite3.connect(tmp)
    db.executescript(SCHEMA)
    db.executemany(
        "INSERT OR REPLACE INTO clips(path,vpk,faction,act,base,variant,bytes,seconds)"
        " VALUES (?,?,?,?,?,?,?,?)",
        rows,
    )
    db.execute(
        "INSERT OR REPLACE INTO meta(key,value) VALUES ('install',?)", (str(install),)
    )
    db.execute(
        "INSERT OR REPLACE INTO meta(key,value) VALUES ('engine',?)",
        (profile["engine"],),
    )
    db.commit()
    db.close()
    tmp.replace(out_db)

    by_act: dict[str, dict[str, int]] = {}
    for r in rows:
        by_act.setdefault(r[3], {}).setdefault(r[2], 0)
        by_act[r[3]][r[2]] += 1
    return {
        "clips": len(rows),
        "seconds": round(sum(r[7] for r in rows), 1),
        "by_act": by_act,
        "db": str(out_db),
    }


def precache_list(db_path: Path, budget: int) -> list[str]:
    """Deterministic, act-balanced subset for the plugin to precache.

    Round-robin over (act, faction) buckets so every act has a representative
    before any bucket gets a second variant.
    """
    db = sqlite3.connect(db_path)
    rows = db.execute(
        "SELECT path, faction, act FROM clips ORDER BY act, faction, variant, path"
    ).fetchall()
    db.close()
    buckets: dict[tuple[str, str], list[str]] = {}
    for path, faction, act in rows:
        buckets.setdefault((act, faction), []).append(path)
    chosen: list[str] = []
    depth = 0
    while len(chosen) < budget:
        added = False
        for items in buckets.values():
            if len(chosen) >= budget:
                break
            if depth < len(items):
                chosen.append(items[depth])
                added = True
        if not added:
            break
        depth += 1
    return chosen
