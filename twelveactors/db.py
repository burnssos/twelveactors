# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
"""SQLite state: bot roster, persona binding, per-bot memory, turn log."""
from __future__ import annotations

import hashlib
import sqlite3
import time
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS bots (
    name TEXT PRIMARY KEY,
    persona TEXT NOT NULL,
    faction TEXT NOT NULL,
    first_seen REAL NOT NULL,
    last_seen REAL NOT NULL,
    turns INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS memory (
    bot TEXT NOT NULL,
    key TEXT NOT NULL,
    value TEXT NOT NULL,
    weight REAL NOT NULL DEFAULT 1.0,
    updated REAL NOT NULL,
    PRIMARY KEY (bot, key)
);
CREATE TABLE IF NOT EXISTS turns (
    id INTEGER PRIMARY KEY,
    ts REAL NOT NULL,
    speaker TEXT NOT NULL,
    player TEXT,
    prompt TEXT,
    act TEXT,
    line TEXT,
    clip TEXT,
    source TEXT
);
CREATE INDEX IF NOT EXISTS turns_ts ON turns(ts);
"""

# Columns added after the first installs; ALTER keeps old databases working.
MIGRATIONS = {
    "turns": [("prompt", "TEXT"), ("source", "TEXT")],
}


def connect(path: Path) -> sqlite3.Connection:
    path.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(path, timeout=15, check_same_thread=False)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA synchronous=NORMAL")
    db.executescript(SCHEMA)
    for table, cols in MIGRATIONS.items():
        have = {r[1] for r in db.execute(f"PRAGMA table_info({table})")}
        for name, decl in cols:
            if name not in have:
                db.execute(f"ALTER TABLE {table} ADD COLUMN {name} {decl}")
    db.commit()
    return db


def persona_for(name: str, cards: dict, faction: str) -> dict:
    pool = cards.get(faction) or cards["american"]
    h = int(hashlib.sha256(name.encode("utf-8")).hexdigest(), 16)
    return pool[h % len(pool)]


def ensure_bot(db: sqlite3.Connection, name: str, faction: str, cards: dict) -> sqlite3.Row:
    now = time.time()
    row = db.execute("SELECT * FROM bots WHERE name=?", (name,)).fetchone()
    if row:
        db.execute("UPDATE bots SET last_seen=?, faction=? WHERE name=?", (now, faction, name))
        db.commit()
        if row["faction"] != faction:
            db.execute("UPDATE bots SET faction=? WHERE name=?", (faction, name))
            db.commit()
            row = db.execute("SELECT * FROM bots WHERE name=?", (name,)).fetchone()
        return row
    persona = persona_for(name, cards, faction)
    db.execute(
        "INSERT INTO bots(name,persona,faction,first_seen,last_seen,turns) VALUES (?,?,?,?,?,0)",
        (name, persona["id"], faction, now, now),
    )
    db.commit()
    return db.execute("SELECT * FROM bots WHERE name=?", (name,)).fetchone()


def remember(db: sqlite3.Connection, bot: str, key: str, value: str, weight: float = 1.0) -> None:
    db.execute(
        "INSERT INTO memory(bot,key,value,weight,updated) VALUES (?,?,?,?,?) "
        "ON CONFLICT(bot,key) DO UPDATE SET value=excluded.value, "
        "weight=memory.weight+excluded.weight, updated=excluded.updated",
        (bot, key, value, weight, time.time()),
    )
    db.commit()


def recall(db: sqlite3.Connection, bot: str, limit: int = 5) -> list[sqlite3.Row]:
    return db.execute(
        "SELECT key,value,weight FROM memory WHERE bot=? ORDER BY weight DESC, updated DESC LIMIT ?",
        (bot, limit),
    ).fetchall()


def _cap(value, limit: int) -> str:
    """Bound a stored value. Every query binds parameters, so this is about
    row size and log hygiene, not escaping: a value is never interpolated into
    SQL anywhere in this module, however hostile it looks."""
    return ("" if value is None else str(value))[:limit]


def log_turn(db, speaker: str, player: str, prompt: str, act: str, line: str,
             clip: str = "", source: str = "llm") -> None:
    db.execute(
        "INSERT INTO turns(ts,speaker,player,prompt,act,line,clip,source) "
        "VALUES (?,?,?,?,?,?,?,?)",
        (time.time(), _cap(speaker, 64), _cap(player, 64), _cap(prompt, 400),
         _cap(act, 32), _cap(line, 400), _cap(clip, 255), _cap(source, 16)),
    )
    db.execute("UPDATE bots SET turns=turns+1, last_seen=? WHERE name=?",
               (time.time(), _cap(speaker, 64)))
    db.commit()
