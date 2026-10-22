# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
"""File bridge between the SourceMod plugin and the daemon.

Transport is two append-only TSV files plus a roster snapshot:

  in.tsv     seq \t kind \t a \t b \t c \t d \t e   (plugin -> daemon)
  out.tsv    seq \t speaker \t clip \t text          (daemon -> plugin)
  roster.tsv name \t team \t is_bot                 (plugin, every 3s)

TSV, not JSON: SourcePawn has no JSON parser in core and hand-rolled escaping of
arbitrary player text is where these bridges usually break. Player text is
sanitised to no tabs/newlines on the plugin side, so splitting is unambiguous.

Why files at all: core SourceMod has no HTTP client, and the shipped webternet
extension has no include on this install. A file bridge needs no extension, no
gamedata and no network from the game process, and it keeps working when the
daemon restarts mid-round.
"""
from __future__ import annotations

import json

import os
import random
import re
import threading
import time
from collections import deque
from pathlib import Path

from . import db as dbm
from . import scope
from .brain import Brain

COOLDOWN_BOT = 8.0
COOLDOWN_GLOBAL = 1.2
MAX_AGE = 6.0
BARK_CHANCE_DEATH = 0.28
BARK_CHANCE_ROUND = 0.45
BARK_CHANCE_RADIO = 0.60   # quick-key radio with no learned meaning

# DoD:S radio menu items are sent to the server as named commands, not as a
# menu/index pair. Wording follows the American voice menu in dod_english.txt.
VOICE_TEXT = {
    "voice_gogogo": "Go go go!",
    "voice_hold": "Hold this position!",
    "voice_cover": "Covering fire!",
    "voice_coverflanks": "Squad, flank them!",
    "voice_sticktogether": "Stick together!",
    "voice_usesmoke": "Smoke em!",
    "voice_usegrens": "Use your grenades!",
    "voice_ceasefire": "Cease fire!",
    "voice_fallback": "Fall back!",
    "voice_fireleft": "Fire to the left!",
    "voice_fireright": "Fire to the right!",
    "voice_left": "Move left!",
    "voice_right": "Move right!",
    "voice_attack": "Attack!",
    "voice_tank": "Tank!",
    "voice_movewithtank": "Move with the tank!",
    "voice_yessir": "Yes Sir!",
    "voice_negative": "Negative!",
    "voice_backup": "I need backup!",
    "voice_fireinhole": "Fire in the hole!",
    "voice_grenade": "Grenade, take cover!",
    "voice_sniper": "Sniper!",
    "voice_niceshot": "Nice shot!",
    "voice_thanks": "Thanks!",
    "voice_areaclear": "Area clear!",
    "voice_dropweapons": "Drop your weapons!",
    "voice_displace": "Displace!",
    "voice_mgahead": "MG Ahead!",
    "voice_enemybehind": "Enemy behind us!",
    "voice_moveupmg": "We need an MG up here!",
    "voice_needammo": "I need ammo!",
    "voice_usebazooka": "Use the bazooka!",
    "voice_bazookaspotted": "Panzerschreck!",
    "voice_takeammo": "Take my ammo!",
    "voice_medic": "Medic!",
    "voice_wegothim": "We got him!",
    "voice_wtf": "What was that?",
}


def clean(text: str) -> str:
    # TSV fields must never contain a tab or newline, and nothing unprintable
    # should reach a log or a database column even from a refused turn.
    return scope.sanitize(str(text))


def _names_bot(name: str, low: str) -> bool:
    """True when the chat text addresses this bot by whole word.

    Substring matching made "frankly" address Frank and "johnny" address John,
    and an addressed line skips the unprompted roll — so ordinary chat silently
    changed the reply rate. \\b also accepts the possessive: "John's right".
    """
    return re.search(r"\b" + re.escape(name.lower()) + r"\b", low) is not None


class Bridge:
    def __init__(self, data: Path, cfg: dict, db, profile: dict, cards: dict, brain: Brain):
        self.data = Path(data)
        self.cfg = cfg
        self.db = db
        self.profile = profile
        self.cards = cards
        self.brain = brain
        self.in_path = self.data / "in.tsv"
        self.out_path = self.data / "out.tsv"
        self.roster_path = self.data / "roster.tsv"
        self.radio_map_path = self.data / "radio_map.json"
        self.radio_seen_path = self.data / "radio_seen.tsv"
        self._radio_cache: tuple[dict, float] = ({}, -1.0)
        self._radio_pairs: set[str] = set()
        self.personas = {}
        try:
            self.personas = json.loads((self.data / "personas.json").read_text())
        except (FileNotFoundError, ValueError):
            pass
        # Start at the end of in.tsv: replaying the backlog on every restart
        # makes the server bark a burst of stale lines the moment it comes up.
        try:
            self._offset = self.in_path.stat().st_size
        except FileNotFoundError:
            self._offset = 0
        self._out_seq = self._read_out_seq()
        self._bot_cooldown: dict[str, float] = {}
        self._last_global = 0.0
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self.stats = {"in": 0, "out": 0, "skipped": 0, "errors": 0, "gated": 0,
                      "filtered": 0}
        self._gated = False
        self.recent: deque[dict] = deque(maxlen=40)

    # ------------------------------------------------------------ plumbing
    def _read_out_seq(self) -> int:
        if not self.out_path.exists():
            return 0
        last = 0
        for line in self.out_path.read_text(errors="replace").splitlines():
            head = line.split("\t", 1)[0]
            if head.isdigit():
                last = max(last, int(head))
        return last

    def roster(self) -> list[dict]:
        if not self.roster_path.exists():
            return []
        bots = []
        for line in self.roster_path.read_text(errors="replace").splitlines():
            parts = line.split("\t")
            if len(parts) < 3 or not parts[0]:
                continue
            try:
                team = int(parts[1])
            except ValueError:
                continue
            bots.append({"name": parts[0], "team": team, "bot": parts[2] == "1"})
        return bots

    def bots(self) -> list[dict]:
        return [b for b in self.roster() if b["bot"]]

    def humans(self) -> list[dict]:
        return [p for p in self.roster() if not p["bot"]]

    def dialog_allowed(self) -> bool:
        """False when the gate is on and nobody is in game to hear a bark.

        The plugin gates at the source too; this is the independent half. The
        daemon is the expensive side (one model turn per event, plus the clip
        lookup and DB writes), so it refuses to spend anything while the roster
        shows only bots — including when the roster is missing, which can only
        mean the server is not up.
        """
        if not self.cfg.get("dialog_requires_human", True):
            return True
        return bool(self.humans())

    def faction_of(self, team: int) -> str:
        entry = self.profile["teams"].get(str(team))
        return entry["faction"] if entry else "american"

    def _persona(self, bot: dict) -> dict:
        faction = self.faction_of(bot["team"])
        # A bound persona wins: the bot module asks RCBot2 for each persona by
        # name at creation (`rcbotd addbot <class> <team> <name>`), so the name
        # in the scoreboard *is* the character. Nothing is pre-seeded into
        # RCBot2's profile files any more.
        bound = self.personas.get(bot["name"])
        if bound and bound.get("faction") == faction:
            return bound
        pool = self.cards[faction]
        idx = int.from_bytes(
            __import__("hashlib").sha1(bot["name"].encode()).digest()[:4], "big"
        ) % len(pool)
        return pool[idx]

    def _write_out(self, speaker: str, clip: str, text: str) -> int:
        with self._lock:
            self._out_seq += 1
            seq = self._out_seq
            line = "\t".join([str(seq), clean(speaker)[:32], clip or "", clean(text)])
            with self.out_path.open("a", encoding="utf-8") as fh:
                fh.write(line + "\n")
            self.stats["out"] += 1
            self.recent.append({"seq": seq, "speaker": speaker, "clip": clip, "text": text})
        return seq

    # -------------------------------------------------------------- events
    def _bot_ready(self, name: str) -> bool:
        now = time.time()
        if now - self._last_global < COOLDOWN_GLOBAL:
            return False
        if now - self._bot_cooldown.get(name, 0) < COOLDOWN_BOT:
            return False
        self._bot_cooldown[name] = now
        self._last_global = now
        return True

    def _respond(self, bot: dict, player: str, text: str, event: str | None = None) -> dict | None:
        if not self._bot_ready(bot["name"]):
            return None
        faction = self.faction_of(bot["team"])
        persona = self._persona(bot)
        memory = dbm.recall(self.db, bot["name"], limit=4)
        reply = self.brain.respond(
            speaker=bot["name"], persona=persona, faction=faction,
            player=player, text=text,
            map_name=self.cfg.get("map", "dod_anzio"), event=event, memory=memory,
        )
        self._write_out(bot["name"], reply.clip, reply.line)
        try:
            dbm.ensure_bot(self.db, bot["name"], faction, self.cards)
        except Exception:
            self.stats["errors"] += 1
        dbm.log_turn(self.db, bot["name"], player, clean(text)[:200],
                     reply.act, reply.line, reply.clip, reply.source)
        if reply.source == "filter":
            self.stats["filtered"] += 1
        return {"speaker": bot["name"], "line": reply.line, "act": reply.act,
                "clip": reply.clip, "source": reply.source}

    def _bark(self, bot: dict, act: str) -> dict | None:
        if not self._bot_ready(bot["name"]):
            return None
        faction = self.faction_of(bot["team"])
        clip = self.brain.pick_clip(faction, act)
        if not clip:
            return None
        self._write_out(bot["name"], clip, "")
        dbm.log_turn(self.db, bot["name"], "-", f"[event:{act}]", act, "", clip, "bark")
        return {"speaker": bot["name"], "line": "", "act": act, "clip": clip, "source": "bark"}

    def on_say(self, fields: list[str]) -> dict | None:
        # seq \t say \t userid \t name \t team \t is_bot \t text
        if len(fields) < 7:
            return None
        # The name is engine-supplied data: flatten it like the chat text so a
        # stray control byte or a quote cannot travel onward into a log, a row
        # or the prompt. Non-ASCII survives on purpose.
        name = clean(fields[3])
        name, team_raw, bot_flag, text = name, fields[4], fields[5], fields[6]
        # A deliberate radio-menu pick carries a trailing flag; it must always
        # get an answer rather than rolling unprompted_chance like idle chatter.
        radio = len(fields) > 7 and fields[7].strip() == "1"
        if bot_flag == "1" or not text:
            return None  # never answer bots; loops are the classic failure here
        try:
            team = int(team_raw)
        except ValueError:
            team = 2
        bots = self.bots()
        if not bots:
            self.stats["skipped"] += 1
            return None

        # Answer from the asker's own team. say_team is routed by the engine, so
        # a bot on the other side would speak into chat this player never sees —
        # with two humans on opposite teams that reads as being ignored. Teams
        # 2 (Allies) and 3 (Axis) both have bots; anything else (spectator,
        # unassigned) has none, so that case keeps the old cross-team pool.
        if team in (2, 3):
            team_bots = [b for b in bots if b["team"] == team]
            if not team_bots:
                self.stats["skipped"] += 1
                return None
            bots = team_bots

        # addressed bot wins: "Kowalski, ..." / "hipinger: ..."
        low = text.lower()
        addressed = [b for b in bots if _names_bot(b["name"], low)]
        pool = addressed or bots
        chance = self.profile.get("unprompted_chance", 0.35)
        if not addressed and not radio and random.random() > chance:
            self.stats["skipped"] += 1
            return None
        bot = random.choice(pool)
        return self._respond(bot, name, text, event="radio" if radio else None)

    def _radio_map(self) -> dict[str, str]:
        """menu:item -> the call in plain words.

        The menu text itself is on the server: dod/resource/dod_english.txt
        (UTF-16LE) holds the three lists as Menu_AmerVoiceA/B/C. `ta-radio
        --autofill` builds this table from them, and `--calibrate` fixes the
        numbering from one observed press. Pairs still unknown get a bark.
        """
        try:
            mtime = self.radio_map_path.stat().st_mtime
        except FileNotFoundError:
            self._radio_cache = ({}, -1.0)
            return {}
        if self._radio_cache[1] != mtime:
            try:
                raw = json.loads(self.radio_map_path.read_text())
                self._radio_cache = ({str(k): str(v) for k, v in raw.items()}, mtime)
            except ValueError:
                self.stats["errors"] += 1
        return self._radio_cache[0]

    def _is_bot_name(self, name: str) -> bool:
        low = name.lower()
        return any(b["name"].lower() == low for b in self.bots())

    def on_radio(self, fields: list[str]) -> dict | None:
        # seq \t radio \t userid \t name \t team \t menu \t item
        if len(fields) < 7:
            return None
        name = clean(fields[3])
        name, team_raw, menu, item = name, fields[4], fields[5], fields[6]
        if not name:
            return None
        # RCBot2 bots press the same radio commands the player does (voice_grenade
        # and voice_backup alone were hundreds of events per map). Answering those
        # is bot-to-bot chatter: it costs a model turn per press and the reply is
        # addressed to a bot. Refuse them the same way on_say refuses bot text.
        if self._is_bot_name(name):
            self.stats["skipped"] += 1
            return None
        key = f"{menu}:{item}"
        # Log every press, not just the first sighting of a pair: this file
        # exists so a human can label what each key did, and pressing the same
        # item twice has to show up twice.
        try:
            with self.radio_seen_path.open("a") as fh:
                fh.write(
                    f"{menu}\t{item}\t{name}\t{time.strftime('%H:%M:%S')}\n"
                )
        except OSError:
            self.stats["errors"] += 1
        self._radio_pairs.add(key)

        bots = self.bots()
        if not bots:
            self.stats["skipped"] += 1
            return None
        try:
            team = int(team_raw)
        except ValueError:
            team = 0
        squad = [b for b in bots if b["team"] == team] or bots
        bot = random.choice(squad)

        phrase = self._radio_map().get(key)
        if phrase:
            return self._respond(bot, name, phrase, event="radio")
        if random.random() > BARK_CHANCE_RADIO:
            self.stats["skipped"] += 1
            return None
        act = random.choice(self.profile.get("radio_acts", ["ack"]))
        return self._bark(bot, act)

    def on_voice(self, fields: list[str]) -> dict | None:
        """A named DoD:S voice command: seq \t voice \t userid \t name \t team \t cmd.

        DoD:S picks radio items with commands such as "voice_hold" instead of
        sending a menu/index pair, so the words come from this table rather
        than from radio_map.json.
        """
        if len(fields) < 6:
            return None
        name, team_raw = clean(fields[3]), fields[4]
        cmd = fields[5].strip()
        if not name or not cmd or cmd.lstrip("+-") == "voicerecord":
            # Microphone key: the server sees the press, never the audio, so
            # there is nothing to answer.
            return None
        if self._is_bot_name(name):
            # Same reason as on_radio: a bot's own callout must not buy a turn.
            self.stats["skipped"] += 1
            return None
        phrase = VOICE_TEXT.get(cmd, cmd.removeprefix("voice_").replace("_", " "))
        bots = self.bots()
        if not bots:
            self.stats["skipped"] += 1
            return None
        try:
            team = int(team_raw)
        except ValueError:
            team = 0
        squad = [b for b in bots if b["team"] == team] or bots
        return self._respond(random.choice(squad), name, phrase, event="radio")

    def on_death(self, fields: list[str]) -> dict | None:
        # seq \t death \t victimid \t victim \t team \t attacker \t weapon
        bots = self.bots()
        if not bots or random.random() > BARK_CHANCE_DEATH:
            return None
        act = random.choice(self.profile.get("death_acts", ["ack"]))
        candidate = random.choice(bots)
        return self._bark(candidate, act)

    def on_round(self, fields: list[str]) -> dict | None:
        if len(fields) > 6 and fields[6]:
            self.cfg["map"] = fields[6]
        bots = self.bots()
        if not bots or random.random() > BARK_CHANCE_ROUND:
            return None
        act = random.choice(self.profile.get("round_acts", ["go"]))
        return self._bark(random.choice(bots), act)

    # ---------------------------------------------------------------- loop
    def _event_allowed(self, fields: list[str]) -> bool:
        """Human-presence gate, decided per event rather than per poll.

        A player-initiated event (say / radio / voice) is its own proof that a
        human is in game, and that matters: roster.tsv is a 3 s snapshot, so a
        player who joins and immediately asks for ammo would otherwise be
        dropped while the roster still lists only bots. Ambient events (bot
        deaths, round starts) have no such proof and need a human on the
        roster before they may cost a model turn.
        """
        if not self.cfg.get("dialog_requires_human", True):
            return True
        kind = fields[1]
        if kind in ("say", "radio", "voice") and len(fields) > 3:
            name = fields[3]
            if kind == "say" and len(fields) > 6 and fields[5] == "1":
                return False  # a bot talking to itself
            bots = {b["name"] for b in self.bots()}
            if name and name not in bots:
                return True
        return bool(self.humans())

    def _handle(self, line: str) -> dict | None:
        fields = line.split("\t")
        if len(fields) < 2:
            return None
        self.stats["in"] += 1
        allowed = self._event_allowed(fields)
        self._gated = not allowed
        if not allowed:
            self.stats["gated"] += 1
            return None
        kind = fields[1]
        try:
            if kind == "say":
                return self.on_say(fields)
            if kind == "death":
                return self.on_death(fields)
            if kind == "radio":
                return self.on_radio(fields)
            if kind == "voice":
                return self.on_voice(fields)
            if kind == "round":
                return self.on_round(fields)
            if kind == "test":
                # seq \t test \t userid \t name \t is_bot \t x \t act
                act = fields[6] if len(fields) > 6 else "ack"
                bots = self.bots()
                if not bots:
                    return None
                bot = random.choice(bots)
                return self._bark(bot, act)
        except Exception as exc:  # never let one bad line kill the bridge
            self.stats["errors"] += 1
            self.cfg.setdefault("_errors", []).append(str(exc)[:200])
        return None

    def poll_once(self) -> int:
        if not self.in_path.exists():
            return 0
        size = self.in_path.stat().st_size
        if size < self._offset:
            self._offset = 0  # file was truncated/replaced
        if size == self._offset:
            return 0
        with self.in_path.open("r", encoding="utf-8", errors="replace") as fh:
            fh.seek(self._offset)
            chunk = fh.read()
            self._offset = fh.tell()
        handled = 0
        for line in chunk.splitlines():
            if line.strip():
                if self._handle(line) is not None:
                    handled += 1
        return handled

    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                self.poll_once()
            except Exception as exc:
                self.stats["errors"] += 1
                self.cfg.setdefault("_errors", []).append(str(exc)[:200])
            self._stop.wait(0.25)

    def start(self) -> None:
        if self._thread is None:
            self._thread = threading.Thread(target=self._run, name="twelveactors-bridge", daemon=True)
            self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=3)
