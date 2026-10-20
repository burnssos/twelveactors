# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
"""The brain: turn a chat line or a game event into one short in-character reply
plus a voice act to bark with.

Text generation talks to an OpenAI-compatible endpoint (Venice by default).
Clip choice never needs the network: it is a lookup in the local voice bank,
which is why the voice layer still works if the LLM is down or rate-limited.
"""
from __future__ import annotations

import json
import random
import re
import sqlite3
import urllib.request
from dataclasses import dataclass
from pathlib import Path

from . import scope

FALLBACK = {
    "ack": ["Yessir.", "Copy that.", "On it."],
    "go": ["Let's move!", "Go, go, go!", "Moving out!"],
    "attack": ["Push them back!", "Take the point!", "Advance, now!"],
    "defend": ["Hold this line.", "Dig in and hold!", "Nobody falls back."],
    "retreat": ["Fall back!", "Pull back to cover!", "Back to the line!"],
    "support": ["We're coming!", "Covering fire, move!", "Hold on, we're close."],
    "grenade": ["Grenade out!", "Frag incoming!", "Watch your feet!"],
    "ammo": ["Need ammo here!", "Grab a box, we're dry.", "Resupply, now."],
    "thanks": ["Thanks.", "Appreciated.", "Much obliged."],
    "praise": ["Good shot!", "That's one down.", "Nice work."],
    "negative": ["No. Not that way.", "Negative.", "Belay that."],
    "medic": ["Medic!", "Corpsman!", "Man down, medic!"],
    "direction": ["They're on the left!", "Right flank, watch it!", "Behind us!"],
    "objective": ["Take the flag!", "Hold the point!", "Eyes on the objective."],
    "weapon": ["Bring up the heavy gun!", "Use the rocket!", "Charge the emplacement!"],
    "time": ["One minute, move!", "Two minutes left!"],
    "pain": ["Gah!", "I'm hit!", "Son of a—"],
    "celebrate": ["That's how it's done.", "Point's ours.", "They're running."],
}

SYSTEM = """You are {name}, {voice}, a soldier in a World War II skirmish on the map {map}.
Faction: {faction_label}. Year: 1944. You are a bot in Day of Defeat: Source.

Rules:
- Reply with ONE spoken line, at most {max_words} words.
- Stay in character: period vocabulary, no modern slang, no emoji, no stage directions.
- React to what was said, or to the event, briefly and concretely.
- Never mention being an AI, a bot, a model, or a game mechanic.
- The war is your whole world. If asked about arithmetic, prices, news, the
  modern world, or what you are, refuse in one curt line in character and get
  back to the fight. Never answer the question itself.
- Pick exactly one act from this list: {acts}.
- Output strict JSON: {{"act": "<act>", "line": "<line>"}}"""


@dataclass
class Reply:
    speaker: str
    act: str
    line: str
    clip: str
    source: str  # "llm" | "fallback"


class Brain:
    def __init__(self, cfg: dict, db: sqlite3.Connection, profile: dict, cards: dict,
                 clips: str | None = None):
        self.cfg = cfg
        self.db = db
        self.clips_path = clips or str(Path(cfg.get("data_dir", ".")) / "clips.sqlite")
        self.profile = profile
        self.cards = cards
        self.acts = sorted(profile["acts"].keys())
        self.repeats = scope.RepeatGuard()
        self.scope_stats: dict = {"filtered": 0, "by_reason": {}}

    # --- voice -----------------------------------------------------------
    def pick_clip(self, faction: str, act: str) -> str | None:
        conn = sqlite3.connect(self.clips_path)
        try:
            rows = conn.execute(
                "SELECT path FROM clips WHERE faction=? AND act=? ORDER BY variant", (faction, act)
            ).fetchall()
            if not rows:
                rows = conn.execute(
                    "SELECT path FROM clips WHERE faction=? AND act='ack' ORDER BY variant",
                    (faction,),
                ).fetchall()
        finally:
            conn.close()
        if not rows:
            return None
        return random.choice([r[0] for r in rows[:4]])

    # --- text ------------------------------------------------------------
    def respond(self, speaker: str, persona: dict, faction: str, player: str,
                text: str, map_name: str, event: str | None = None,
                memory: list[str] | None = None) -> Reply:
        act_hint = self.profile["event_acts"].get(event or "", "ack")
        line, act, source = None, act_hint, "fallback"
        verdict = scope.classify(text, self.profile, self.repeats, player,
                                 dedupe=event != "radio")
        if not verdict.allowed:
            # Off topic, or the same order twice: answer from the persona's own
            # refusal pool. No request leaves the machine, so no tokens.
            act = "negative" if "negative" in self.acts else "ack"
            line = scope.refusal_line(persona)
            source = "filter"
            self.scope_stats["filtered"] += 1
            reasons = self.scope_stats["by_reason"]
            reasons[verdict.reason] = reasons.get(verdict.reason, 0) + 1
            clip = self.pick_clip(faction, act) or self.pick_clip(faction, "ack") or ""
            return Reply(speaker=speaker, act=act, line=line, clip=clip, source=source)
        try:
            # Chat is ASCII-clean by now (the gate refused anything else); this
            # only removes stray controls so they cannot reach the prompt.
            line, act = self._llm(persona, faction, player, scope.sanitize(text),
                                  map_name, memory)
            source = "llm"
        except Exception as exc:  # network, quota, bad JSON — degrade, never die
            self.cfg.setdefault("_errors", []).append(str(exc)[:200])
        if not line:
            line = random.choice(FALLBACK.get(act, FALLBACK["ack"]))
            source = "fallback"
        clip = self.pick_clip(faction, act) or self.pick_clip(faction, "ack") or ""
        return Reply(speaker=speaker, act=act, line=line, clip=clip, source=source)

    def _llm(self, persona: dict, faction: str, player: str, text: str,
             map_name: str, memory: list[str] | None) -> tuple[str, str]:
        label = self.profile["teams"].get(
            str(2 if faction == "american" else 3), {}
        ).get("label", faction)
        system = SYSTEM.format(
            name=persona["name"], voice=persona["voice"], map=map_name,
            faction_label=label, max_words=self.profile["max_reply_words"],
            acts=", ".join(self.acts),
        )
        user = compose_user(player, text, memory, self._last_event)
        body = {
            "model": self.cfg["model"],
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
            "temperature": 0.9,
            "max_tokens": int(self.profile.get("max_tokens", 600)),
            "response_format": {"type": "json_object"},
            "venice_parameters": {"include_venice_system_prompt": False},
        }
        req = urllib.request.Request(
            self.cfg["base_url"].rstrip("/") + "/chat/completions",
            data=json.dumps(body).encode(),
            headers={
                "Authorization": f"Bearer {self.cfg['api_key']}",
                "Content-Type": "application/json",
            },
        )
        with urllib.request.urlopen(req, timeout=self.cfg.get("timeout", 20)) as r:
            payload = json.loads(r.read())
        choice = payload["choices"][0]
        content = choice["message"].get("content") or ""
        if not content.strip():
            # a reasoning model can spend the whole budget before writing an answer
            content = (choice["message"].get("reasoning_content") or "").strip()
            content = _first_json(content) if "{" in content else ""
        try:
            data = json.loads(_first_json(content))
        except json.JSONDecodeError:
            # A truncated completion still carries a usable line when the quote
            # pair closed; salvage it rather than dropping to a canned bark.
            data = _salvage(content) or {}
        act = str(data.get("act", "")).strip()
        line = " ".join(str(data.get("line", "")).split())
        if act not in self.acts:
            act = "ack"
        if not line:
            raise ValueError("empty line")
        return line[:220], act

    _last_event: str | None = None


def clean_name(value: str, limit: int = 32) -> str:
    """A player name as it may appear in the prompt: one line, no quotes.

    The name comes from the engine, not from us. A name carrying a double
    quote or a newline would otherwise let a player restructure or extend the
    prompt around their chat line, so those are neutralised here rather than
    trusted. Non-ASCII is kept: the characters belong to the player and the
    model is asked to answer in English regardless.
    """
    s = scope.sanitize(value, limit).replace('"', "'")
    return s or "someone"


def quote(text: str) -> str:
    """Escape a chat line so it stays data inside the prompt's double quotes."""
    return str(text).replace("\\", "\\\\").replace('"', '\\"')


def compose_user(player: str, text: str, memory: list[str] | None = None,
                 event: str | None = None) -> str:
    """Build the single user message the model sees for one chat line."""
    user = f'{clean_name(player)} says over the squad channel: "{quote(text)}"'
    if memory:
        user += "\nThings you remember:\n- " + "\n- ".join(memory)
    if event:
        user += f"\nJust happened in the round: {event}"
    return user


def _salvage(text: str) -> dict | None:
    """Pull act/line out of a truncated JSON object; only closed strings count."""
    act = re.search(r'"act"\s*:\s*"([^"\\]*)"', text)
    line = re.search(r'"line"\s*:\s*"((?:[^"\\]|\\.)*)"', text)
    if not line:
        return None
    return {"act": act.group(1) if act else "ack",
            "line": line.group(1).encode().decode("unicode_escape", "ignore")
            if "\\" in line.group(1) else line.group(1)}


def _first_json(text: str) -> str:
    m = re.search(r"\{.*\}", text, re.S)
    return m.group(0) if m else text
