# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
"""Keep the bots in their lane, before the model is ever called.

The daemon pays for every turn it sends upstream. Most of what a public server
gets is on topic — ammo, medics, flanks, the flag — and that is worth a model
call. A line about arithmetic, prices, the modern world, or what the bot "is"
is not: it can be answered from the persona's own refusal pool for nothing.

Two layers, on purpose:

* this module, which decides without a network call and covers the obvious
  cases (a hard gate, no token spent, reply still in character);
* the system prompt, which carries the same rule for anything ambiguous that
  slips past the gate.

Anything carrying a combat word is allowed, except where an unambiguous
off-topic family matches first (a stray "win" must not carry "who will win the
election" past the gate). That way "how much ammo is left" is never caught by
the "how much is" price pattern.

Two gates sit ahead of everything else, because they are not judgement calls:

* ``chars`` — anything outside printable ASCII. A DoD:S player typing English
  never needs Cyrillic, CJK, emoji, accents, zero-width joiners or control
  characters, and those are the usual vehicles for homoglyph evasion and
  right-to-left override tricks aimed at a model.
* ``injection`` — SQL, database and shell grammar. The daemon binds every
  value as a parameter, so this is not the only defence (see ``db.log_turn``);
  the gate just means an obvious attack attempt is refused in character for
  free instead of being paid for.
"""
from __future__ import annotations

import re
import time
from dataclasses import dataclass

# Printable ASCII only: 0x20..0x7e. Tested against the raw line, before any
# normalisation, so full-width or combining look-alikes cannot be folded into
# their ASCII forms first.
_ASCII_PRINTABLE = re.compile(r"^[\x20-\x7e]*$")

# Chat lines arrive capped at 400 characters from the plugin; anything longer
# is either a direct HTTP caller or abuse, and neither needs a model call.
MAX_CHARS = 400
_SCAN = 400

# SQL/database/shell grammar. These are phrases no soldier says into a squad
# channel, so a hard refusal costs nothing and never mistakes "drop your
# weapons" (no object after "drop") for "drop table".
INJECTION = re.compile(
    r"\bdrop\s+(?:table|database|index|view|trigger)\b"
    r"|\b(?:select|insert|update|delete)\b[^.;\n]{0,60}\b(?:from|into|set|where)\b"
    r"|\bunion\s+(?:all\s+)?select\b"
    r"|\b(?:or|and)\s+['\"]?\d+['\"]?\s*=\s*['\"]?\d+"
    r"|['\"]\s*--"
    r"|\b(?:pragma|sqlite_master|sqlite_sequence|sqlite3?)\b"
    r"|\battach\s+database\b|\bvacuum\s+into\b"
    r"|\bexec(?:ute)?\s*\("
    r"|\bdatabases?\b|\bsql\b"
    r"|;\s*(?:drop|delete|update|insert|select|alter|create)\b"
    r"|\$\([^)]{0,60}\)",
    re.I,
)

# C0/C1 controls except tab (handled as whitespace). Never written to a TSV
# field, a log line or a SQL parameter.
_CONTROL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f-\x9f]")

# A combat word means the line belongs in the round, whatever else it says.
GAME_WORDS = {
    "ammo", "ammunition", "medic", "grenade", "nade", "nades", "smoke", "flash",
    "flag", "point", "cap", "capture", "objective", "spawn", "map", "round",
    "match", "team", "squad", "sarge", "sergeant", "lieutenant", "captain",
    "private", "corporal", "orders", "radio", "command", "enemy", "hostile",
    "kraut", "jerry", "yank", "yankee", "axis", "allies", "allied", "german",
    "american", "brit", "sniper", "mg", "mg42", "mg34", "tank", "halftrack",
    "artillery", "mortar", "bazooka", "panzerschreck", "rifle", "pistol",
    "smg", "carbine", "bayonet", "knife", "spade", "reload", "clip", "mag",
    "cover", "flank", "push", "hold", "retreat", "fallback", "advance",
    "charge", "bunker", "trench", "bridge", "street", "alley", "roof",
    "window", "hill", "field", "building", "door", "gate", "fountain",
    "fire", "shot", "shots", "kill", "killed", "dead", "died", "hit", "hurt",
    "wounded", "health", "resupply", "supply", "supplies", "smg", "bar",
    "garand", "thompson", "mp40", "k98", "stg", "stg44", "springfield",
    "victory", "win", "won", "lose", "lost", "score", "spawn", "camp",
    "push", "rush", "defend", "attack", "charges", "grenades", "sector",
}

# Ordered: the first pattern that matches names the reason, and reasons are
# what the stats report so the gate can be tuned against real traffic.
#
# Two tiers, because a combat word must not be able to smuggle a bad line past
# the gate. "win" and "score" are game words, and "who will win the election"
# used to pass on the strength of "win" alone. So the unambiguous families are
# checked *before* the allowlist, and only the ambiguous money/noun words are
# checked after it, where a game word still settles the call ("this cost us the
# round" stays in scope).
HARD_RULES: list[tuple[str, re.Pattern]] = [
    ("math", re.compile(
        r"\b\d+\s*(?:x|\*|times|plus|\+|minus|-|/|divided\s+by|over)\s*\d+\b"
        r"|\bsquare\s+root\b|\bwhat(?:'s| is)\s+\d"
        r"|\bhow\s+much\s+is\b|\bcalculate\b|\bpercent(?:age)?\s+of\b"
        r"|solve\s+for|\bmultipl(?:y|ied)\s+by"
        # Symbolic arithmetic: "2(2)=?", "5*5", "12/4" — a player checking a bot's
        # maths is never asking about the round.
        r"|\d+\s*\(\s*\d+\s*\)|=+\s*\?|\d+\s*[\^*]\s*\d+", re.I)),
    ("meta", re.compile(
        r"\bchat\s?gpt\b|\bopen\s?ai\b|\bdeep\s?seek\b|\bclaude\b|\bgpt\b"
        r"|\bllm\b|\blarge\s+language\b|\bvenice\b|\bapi\b|\bprompt\b"
        r"|\b(?:system|your)\s+instructions?\b|\btokens?\b|\bparameters?\b"
        r"|\bare\s+you\s+(?:an?\s+)?(?:bot|ai|real|human|alive|sentient|program)\b"
        r"|\bwhat\s+model\b|\bwhich\s+model\b|\bwhat\s+are\s+you\b"
        r"|\bignore\s+(?:your|all|previous)\b|\bjailbreak\b", re.I)),
    ("modern", re.compile(
        r"\bplaystation\b|\bxbox\b|\bnintendo\b|\biphone\b|\bandroid\b"
        r"|\bcomputer\b|\binternet\b|\bwifi\b|\bgoogle\b|\byoutube\b"
        r"|\btiktok\b|\bfacebook\b|\bbitcoin\b|\bcrypto\b|\bstock\s+market\b"
        r"|\bpresident\b|\belections?\b|\btrump\b|\bbiden\b|\bobama\b"
        r"|\bvotes?\b|\bvoting\b|\bpolitic(?:s|al)\b|\bgovernment\b"
        r"|\bweather\b|\bforecast\b|\bmovie\b|\bfilm\b|\bnetflix\b"
        r"|\bsong\b|\bband\b|\bjoke\b|\bpoem\b|\brecipe\b|\bcook\b"
        r"|\bpython\b|\bjavascript\b|\bjava\b|\bcode\b|\bprogram\b"
        r"|\bscript\b|\bwrite\s+me\b|\btranslate\b|\bsummari[sz]e\b"
        r"|\bessay\b|\bemail\b|\bhomework\b|\bwikipedia\b"
        r"|\bwhat\s+year\s+is\s+it\b|\bwhat\s+time\s+is\s+it\b"
        r"|\btoday'?s\s+date\b|\btemperature\b"
        # Money and hardware: a player asks about these in the modern world, never
        # about the round. These are unambiguous, so they are checked before the
        # combat allowlist; the ambiguous money words sit in SOFT_RULES instead.
        r"|\bgpu\b|\bcpu\b|\bgraphics?\s+card\b|\bvideo\s+card\b|\blaptop\b"
        r"|\bsmart\s?phone\b|\bsalary\b|\binflation\b|\btaxes\b", re.I)),
]

# Ambiguous: these words are also ordinary round talk, so a combat word
# elsewhere in the line takes precedence. Checked only after the allowlist.
SOFT_RULES: list[tuple[str, re.Pattern]] = [
    ("modern", re.compile(
        r"\bhow\s+much\s+(?:does|is)\s+(?:a|an|the)\s+"
        r"(?:house|car|phone|game|console|dollar|euro|pound)\b"
        r"|\bmoney\b|\bdollars?\b|\bprices?\b|\bcosts?\b|\bexpensive\b"
        r"|\bnews\b", re.I)),
]

_GENERIC_REFUSE = [
    "Not a soldier's question. Back to your post.",
    "Save it. There's a war on.",
    "Ask me about the fight, not that.",
]


@dataclass
class Verdict:
    allowed: bool
    reason: str = "in_scope"


def _norm(text: str) -> str:
    return re.sub(r"[^a-z0-9 ]+", " ", text.lower()).strip()


def sanitize(text: str, limit: int = MAX_CHARS) -> str:
    """Flatten a line for storage: no tabs, newlines, controls or runs of space.

    The gate refuses unprintable characters, but every write path stores the
    prompt before a verdict is known — so nothing control-like may reach a TSV
    field, a log line or a SQL parameter even from a refused turn. Non-ASCII is
    kept in storage on purpose: a refusal record is worth more intact than
    scrubbed.
    """
    s = _CONTROL.sub(" ", str(text))
    s = s.replace("\t", " ").replace("\n", " ").replace("\r", " ")
    return " ".join(s.split())[:limit]


def _has_game_word(words: set[str]) -> bool:
    return bool(words & GAME_WORDS)


def classify(text: str, profile: dict | None = None,
             repeats: "RepeatGuard | None" = None,
             player: str = "", dedupe: bool = True) -> Verdict:
    """Decide whether a human line is worth a model call.

    ``profile["scope"]`` may set ``enabled`` (default true), ``max_words``
    (default 30) and ``extra_allow`` (more combat words). ``dedupe`` is off for
    deliberate radio-menu calls, which are new information every time.
    """
    scope_cfg = (profile or {}).get("scope") or {}
    if scope_cfg.get("enabled") is False or not text or not text.strip():
        return Verdict(True)

    raw = str(text)
    # Not a judgement call, and checked before anything cheaper: a line longer
    # than the plugin can produce, or one carrying characters no English
    # keyboard emits, is refused on sight.
    if len(raw) > MAX_CHARS:
        return Verdict(False, "oversize")
    scan = raw[:_SCAN]
    if not _ASCII_PRINTABLE.match(scan):
        return Verdict(False, "chars")
    if INJECTION.search(scan):
        return Verdict(False, "injection")

    low = text.lower()
    words = set(_norm(low).split())

    if dedupe and repeats is not None and repeats.seen(
            player, low, float(scope_cfg.get("repeat_window_s", 45))):
        return Verdict(False, "repeat")

    allow = GAME_WORDS | {w.lower() for w in scope_cfg.get("extra_allow", [])}

    # Unambiguous off-topic families first: a game word must not rescue them.
    for reason, pattern in HARD_RULES:
        if pattern.search(low):
            return Verdict(False, reason)

    if words & allow:
        return Verdict(True)

    # Money and generic nouns only now, where a combat word already won.
    for reason, pattern in SOFT_RULES:
        if pattern.search(low):
            return Verdict(False, reason)

    if len(words) > int(scope_cfg.get("max_words", 30)):
        return Verdict(False, "length")

    return Verdict(True)


class RepeatGuard:
    """Remembers (player, line) for a window so a spammed order is answered once."""

    def __init__(self) -> None:
        self._last: dict[tuple[str, str], float] = {}

    def seen(self, player: str, text: str, window_s: float) -> bool:
        key = (player.lower(), _norm(text))
        now = time.time()
        if now - self._last.get(key, 0.0) < window_s:
            self._last[key] = now
            return True
        self._last[key] = now
        if len(self._last) > 512:  # bounded: a long round must not leak
            cutoff = now - max(window_s, 60)
            self._last = {k: v for k, v in self._last.items() if v >= cutoff}
        return False


def refusal_line(persona: dict) -> str:
    import random
    pool = persona.get("refuse") or _GENERIC_REFUSE
    return random.choice(pool)
