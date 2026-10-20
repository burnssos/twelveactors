# Twelve Actors — every change performed, with the source that implements it

Written 2026-10-19 22:09 CDT for another Hermes agent (or a human operator)
standing this stack up on a different machine. Every claim below points at the
file and line numbers in this tree that implement it, and quotes the code, so
the receiving agent can verify the behaviour instead of trusting this document.

Companion documents: `TWELVEACTORS-HANDOFF.md` (change log and short install path)
and `HERMES-REBUILD.md` (long phase-by-phase runbook). This file is the one that
carries the source citations. Where they disagree, this file is newest.

---

## 0. Short version for the installing agent

1. Unpack `twelveactors-1.0.0.tar.gz`.
2. Run the tree's own proof before installing anything:
   `python3 tools/preflight.py .` — exits 0 only if the gates, the prompt
   helpers, all 12 persona refusal pools and the scope block are present.
3. Run the test suites: `for t in tests/test_*.py; do python3 "$t"; done`.
4. Install with
   `sudo GAME=/srv/dods TARGET_BOTS=12 TWELVEACTORS_API_BASE=<your-base> TWELVEACTORS_API_KEY=<your-key> TWELVEACTORS_MODEL=<model-id> ./install.sh`.
   On a terminal it asks for base URL, model and key instead (key input hidden).
   It compiles the plugins, writes `/opt/twelveactors`, indexes the voice bank, binds
   the cast, fixes RCBot2's bounds and starts `twelveactors.service`.
5. Confirm the generated config carries your values, not placeholders
   (`grep -c '<YOUR_' <data>/config.json` is 0) and that `/healthz` reports
   `clips: 232`, `bots_known: 12`, `dialog_open: true` with a human connected.
   No credential ships in this tree: `python3 tools/check-secrets.py .` proves
   it, and `make-dist.sh` aborts the build if one ever appears.
6. For later updates use the installer that carries the same preflight:
   `sudo ./install-scope-filter.sh`.

Do not invent paths. Game `/srv/dods`; service user `dod`; SourceMod data
`/srv/dods/dod/addons/sourcemod/data/twelveactors`; daemon `/opt/twelveactors`.

---

## 1. What the system is

A Day of Defeat: Source server whose RCBot2 bots are characters rather than
strangers. SourceMod captures chat, kills, rounds and radio presses into an
append-only TSV; a Python daemon reads it, picks a persona bound to that bot,
asks an OpenAI-compatible model for one short in-character line, matches the
intent to a clip the game already ships, and appends `clip` + `text` to a second
TSV; the plugin plays the clip and says the text as that bot's own team chat.

```
player chat ─► SourceMod (twelveactors.sp) ─► in.tsv
                                          │
                              twelveactors/bridge.py (poll)
                                          │
                         scope.py ── refused ─► persona refuse line + clip
                                          │ allowed
                              twelveactors/brain.py ─► Venice chat/completions
                                          │
                                     out.tsv ─► plugin: clip + say_team
```

No TTS, no generated audio, no voice cloning. Output audio is the 232
`player/{american,german}/*.wav` clips inside `dod_pak_dir.vpk`, read in place.

---

## 2. Work performed

### 2.1 Foundation (before this session)

| Change | Why | Source |
|---|---|---|
| Chat/death/round/radio capture to TSV | The engine has no event bus and no durable channel | `plugin/twelveactors.sp` |
| Named `voice_*` command listener | DoD:S sends named commands, not HL2 `voicemenu m i` | `plugin/twelveactors.sp:96-104` |
| Bot population module | RCBot2's `max_bots` counts humans, not bots | `plugin/ta_bots_rcbot2.sp:103-127` |
| Human cap at 12 | Reserve 12 of 24 slots for bots | `plugin/ta_humancap.sp:40-62` |
| Hold teamless fake clients dead | Team change killed a classless fake client → `ERRORNAME committed suicide` | `plugin/ta_botjoin.sp:52-66` |
| Human-presence gate, both halves | Idle server must cost nothing | `plugin/twelveactors.sp:78-79`, `twelveactors/bridge.py:169-180` |
| Team chat instead of white server text | Bots must speak as themselves, to their own team | `plugin/twelveactors.sp:377-390` |
| Radio labelling tool | Pair names live in the client binary | `tools/label_radio.py`, `radio_map.json` |

### 2.2 This session (2026-10-19)

1. Backed up before touching anything: `~/snapshots/twelveactors-20261019-193244/`,
   four sha256-verified archives.
2. Verified the reply-routing deploy by hash, not by assumption: tree and
   `/opt` identical; team filter and `_names_bot` present.
3. Switched the model to `deepseek-v4-flash-0731`. Priced on the daemon's real
   prompt: **$0.0002 per reply vs $0.00055**, about 2.8× cheaper.
4. Built the deterministic scope gate (`twelveactors/scope.py`) so off-topic lines
   cost **zero tokens**, with in-character refusals from the persona.
5. Fixed the leaks testing found: GPU/CPU/laptop/salary/taxes added to the
   hard family; symbolic arithmetic added; election lines no longer rescued by
   the combat word "win" (two-tier rule order).
6. Fixed `log_turn` (one argument too many put player text in `act`), added
   `prompt` and `source` columns with auto-migration, exposed `scope.filtered`
   and `by_reason` in `/healthz`.
7. Hardened hostile input: `chars`, `injection`, `oversize` gates, `sanitize()`
   on every write path, capped DB fields, parameterised queries throughout.
8. Fixed prompt-slot injection through the engine-supplied player name:
   `clean_name()`, `quote()`, `compose_user()`.
9. Wrote four test suites (54 scope cases, 23 prompt checks, 8 preflight
   damage cases, 6 DB payloads) and `tools/preflight.py`, which the installer
   runs before it touches `/opt`.
10. Rebuilt `~/share/twelveactors-1.0.0{.tar.gz,.zip}` with all of the above,
    including `tests/`, `tools/preflight.py` and both installers.
11. Dated backups: `twelveactors-20261019-193244` (pre-change) and
    `twelveactors-20261019-220359` (current; state sqlite taken with
    `sqlite3 .backup`, not a raw copy of a live WAL).
12. Fixed `install.sh` to generate `deepseek-v4-flash-0731` instead of the old
    expensive model — a fresh machine otherwise starts on the wrong model.
13. Removed every credential from the tree and made that structural, not a
    promise: `tools/check-secrets.py` scans for key-shaped tokens and for the
    literal live key, `make-dist.sh` aborts when it finds one, and both
    installers take `TWELVEACTORS_API_BASE` / `TWELVEACTORS_API_KEY` / `TWELVEACTORS_MODEL`
    (or prompt for them) and write `<YOUR_*>` placeholders when given nothing.
    The model default is labelled as a recommendation, and
    `install-model-switch.sh` now refuses to guess one.

---

## 3. The source, cited

### 3.1 The gate: `twelveactors/scope.py`

Runs before `brain.py` opens a socket. Two hard gates first, because they are
not judgement calls:

```python
# twelveactors/scope.py:37-45
# Printable ASCII only: 0x20..0x7e. Tested against the raw line, before any
# normalisation, so full-width or combining look-alikes cannot be folded into
# their ASCII forms first.
_ASCII_PRINTABLE = re.compile(r"^[\x20-\x7e]*$")

# Chat lines arrive capped at 400 characters from the plugin; anything longer
# is either a direct HTTP caller or abuse, and neither needs a model call.
MAX_CHARS = 400
_SCAN = 400
```

```python
# twelveactors/scope.py:47-63
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
```

The two-tier rule set is the fix for "who will win the election" passing on the
word `win`:

```python
# twelveactors/scope.py:89-106 (comment + math family)
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
        r"|\bsolve\s+for\b|\bmultipl(?:y|ied)\s+by\b"
        # Symbolic arithmetic: "2(2)=?", "5*5", "12/4" — a player checking a bot's
        # maths is never asking about the round.
        r"|\d+\s*\(\s*\d+\s*\)|=+\s*\?|\d+\s*[\^*]\s*\d+", re.I)),
```

The `meta` family (lines 107-113) catches chatbot/model/system-prompt probes.
The `modern` family (114-131) catches politics, weather, devices, code, media,
money and hardware. The ambiguous money words are last, so a combat word can
still win:

```python
# twelveactors/scope.py:134-142
# Ambiguous: these words are also ordinary round talk, so a combat word
# elsewhere in the line takes precedence. Checked only after the allowlist.
SOFT_RULES: list[tuple[str, re.Pattern]] = [
    ("modern", re.compile(
        r"\bhow\s+much\s+(?:does|is)\s+(?:a|an|the)\s+"
        r"(?:house|car|phone|game|console|dollar|euro|pound)\b"
        r"|\bmoney\b|\bdollars?\b|\bprices?\b|\bcosts?\b|\bexpensive\b"
        r"|\bnews\b", re.I)),
]
```

The classifier's order is the whole design. Note that `chars` runs on `raw`,
before `_norm()` lower-cases or strips anything:

```python
# twelveactors/scope.py:192-229
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
```

Write-side sanitisation, used by every ingest and by `brain._llm`:

```python
# twelveactors/scope.py:161-172
def sanitize(text: str, limit: int = MAX_CHARS) -> str:
    """Flatten a line for storage: no tabs, newlines, controls or runs of space.
    ...
    """
    s = _CONTROL.sub(" ", str(text))
    s = s.replace("\t", " ").replace("\n", " ").replace("\r", " ")
    return " ".join(s.split())[:limit]
```

Repeat guard (45 s default, bounded so a long round cannot leak memory) and the
refusal picker:

```python
# twelveactors/scope.py:232-254
class RepeatGuard:
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
    pool = persona.get("refuse") or _GENERIC_REFUSE
    return random.choice(pool)
```

### 3.2 The brain: `twelveactors/brain.py`

The system prompt carries the same rule as a second layer for ambiguous lines:

```python
# twelveactors/brain.py:41-53
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
```

The refusal path returns before any network call:

```python
# twelveactors/brain.py:101-113
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
```

`max_tokens` is pinned at 600 on purpose. With 200 or 300 the reasoning model
spends the budget thinking, returns truncated JSON, and the turn degrades to a
canned bark:

```python
# twelveactors/brain.py:139-149
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
```

Prompt-slot safety: the name comes from the engine, so it is flattened and its
quotes are neutralised; the chat text is escaped so it stays data inside the
quoted slot:

```python
# twelveactors/brain.py:183-209
def clean_name(value: str, limit: int = 32) -> str:
    """A player name as it may appear in the prompt: one line, no quotes.
    ...
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
```

### 3.3 The bridge: `twelveactors/bridge.py`

Every ingest flattens engine-supplied strings through the same sanitiser:

```python
# twelveactors/bridge.py:84-97
def clean(text: str) -> str:
    # TSV fields must never contain a tab or newline, and nothing unprintable
    # should reach a log or a database column even from a refused turn.
    return scope.sanitize(str(text))

def _names_bot(name: str, low: str) -> bool:
    """True when the chat text addresses this bot by whole word.
    ...
    """
    return re.search(r"\b" + re.escape(name.lower()) + r"\b", low) is not None
```

The human-presence gate is duplicated in the daemon because the daemon is the
expensive side:

```python
# twelveactors/bridge.py:169-180
    def dialog_allowed(self) -> bool:
        """False when the gate is on and nobody is in game to hear a bark.
        ...
        """
        if not self.cfg.get("dialog_requires_human", True):
            return True
        return bool(self.humans())
```

`on_say` refuses bot text, answers from the asker's own team, and gives an
addressed bot precedence:

```python
# twelveactors/bridge.py:255-299
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
```

Bot-pressed radio commands are refused, or the model pays for bot-to-bot
chatter (341 `voice_grenade` presses per name per map was observed):

```python
# twelveactors/bridge.py:334-340
        # RCBot2 bots press the same radio commands the player does (voice_grenade
        # and voice_backup alone were hundreds of events per map). Answering those
        # is bot-to-bot chatter: it costs a model turn per press and the reply is
        # addressed to a bot. Refuse them the same way on_say refuses bot text.
        if self._is_bot_name(name):
            self.stats["skipped"] += 1
            return None
```

### 3.4 Storage: `twelveactors/db.py`

Schema and the additive migration that keeps existing databases working:

```python
# twelveactors/db.py:26-43
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
```

```python
# twelveactors/db.py:46-59
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
```

Every value is bound; `_cap` is about row size and log hygiene, not escaping:

```python
# twelveactors/db.py:105-122
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
```

The only f-strings in the module are those two migrations over internal
table-name constants, never player text.

### 3.5 SourceMod plugins

Team chat is sent from the bot's own client, so the engine formats it as that
bot's team chat with its name and colour:

```sourcepawn
// plugin/twelveactors.sp:377-390
        if (text[0] != '\0') {
            // Say it as the bot, not as the server: say_team from the bot's
            // own client gives team chat, the bot's name, its team colour and
            // team-only visibility. White all-chat stays as the fallback for a
            // line whose speaker has since left (no client, no team to pick).
            int speakerId = FindSpeaker(speaker);
            char sayLine[MAX_LINE];
            SaySafe(text, sayLine, sizeof(sayLine));
            if (g_cvTeamChat.BoolValue && speakerId > 0 && GetClientTeam(speakerId) > 1) {
                FakeClientCommand(speakerId, "say_team %s", sayLine);
            } else {
                PrintToChatAll(" \x07%s\x01 :  %s", speaker, sayLine);
            }
        }
```

The human-presence switch, on by default:

```sourcepawn
// plugin/twelveactors.sp:78-79
    g_cvRequireHuman = CreateConVar("sm_ta_require_human", "1",
        "Only run bot dialog while at least one human player is connected", FCVAR_NOTIFY);
```

The churn fix: RCBot2 sets a bot's team before its class command, and DoD:S
spawns the fake client on connect, so the team change killed a live classless
body. Teamless fake clients are held `LIFE_DEAD` on spawn:

```sourcepawn
// plugin/ta_botjoin.sp:52-66
public Action Ev_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvEnable.BoolValue) return Plugin_Continue;

    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client <= 0 || !IsClientInGame(client) || !IsFakeClient(client))
        return Plugin_Continue;
    if (GetClientTeam(client) > 1)
        return Plugin_Continue;   // already on a team: normal spawn, leave it alone

    SetEntProp(client, Prop_Send, "m_lifeState", LIFE_DEAD);
    if (g_cvDebug.BoolValue)
        LogMessage("[botjoin] slot %d held dead until it joins a team", client);
    return Plugin_Continue;
}
```

The human cap, enforced at connect so a 13th human never displaces a bot:

```sourcepawn
// plugin/ta_humancap.sp:40-62
public bool OnClientConnect(int client, char[] rejectmsg, int maxlen)
{
    if (IsFakeClient(client)) return true;

    int cap = g_cvCap.IntValue;
    if (cap <= 0) return true;

    int humans = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (i == client) continue;
        if (IsClientInGame(i) && !IsFakeClient(i)) humans++;
    }

    if (humans >= cap) {
        FormatEx(rejectmsg, maxlen,
            "Server full: %d human slots, %d reserved for bots.", cap, MaxClients - cap);
        char name[MAX_NAME_LENGTH];
        GetClientName(client, name, sizeof(name));
        LogMessage("[ta_humancap] rejected \"%s\" (%d/%d humans)", name, humans, cap);
        return false;
    }
    return true;
}
```

The population module budgets humans into RCBot2's total-client cap and
re-asserts it after every config exec:

```sourcepawn
// plugin/ta_bots_rcbot2.sp:103-130
    // RCBot2's max_bots is a TOTAL CLIENT cap, humans included — not a bot cap.
    // Writing max_bots = target while a human is connected leaves room for only
    // target-1 bots, so every "rcbotd addbot" this module issues is refused with
    // "Can't create bot, max_bots reached" while RCBot2 kicks to stay under the
    // cap: that is the kick/add churn. Budget the humans into the cap instead.
    int cap = target + CountHumans();
    if (cap > MaxClients) cap = MaxClients;

    bool changed = (cap != g_iAppliedTarget);
    if (!force && !changed && ++g_iPasses < 12) return;
    g_iPasses = 0;

    char cmd[128];
    // min first: RCBot2 refuses any pair where max <= min, and a stale min from
    // a previous config would otherwise block the write.
    ServerCommand("rcbotd config min_bots 0");
    Format(cmd, sizeof(cmd), "rcbotd config max_bots %d", cap);
    ServerCommand(cmd);
    // Take free profiles in order (1,2,3...), so every added bot lands on a
    // persona slot instead of a random profile from the launcher set.
    ServerCommand("rcbot_nonrandom_profile 1");
```

### 3.6 The proof: `tools/preflight.py`

Every hostile case names the exact reason it must produce; every legitimate
squad line must still pass:

```python
# tools/preflight.py:29-43
REFUSED = [
    ("chars", "Привет, товарищ"),
    ("chars", "Good game 👍"),
    ("chars", "cafe\u0301", "combining accent"),
    ("injection", "'; drop table turns; --"),
    ("oversize", None),  # built from scope.MAX_CHARS below
]
ALLOWED = [
    "drop your weapons",
    "select fire is on",
    "Otto, ammo on the flank",
]
HELPERS = ("clean_name", "quote", "compose_user")
MIN_REFUSALS = 3
MAX_REFUSAL_CHARS = 240
```

```python
# tools/preflight.py:61-83
    # --- the gate itself ---------------------------------------------------
    try:
        cases = [(want, text if text is not None
                  else "x" * (scope.MAX_CHARS + 1))
                 for want, text, *_ in REFUSED]
        for want, text in cases:
            got = scope.classify(text)
            if got.reason != want:
                problems.append(f"{want} not refused: {text[:40]!r} "
                                f"(got {got.reason or 'allowed'})")
        for text in ALLOWED:
            if not scope.classify(text).allowed:
                problems.append(f"legitimate line refused: {text!r}")
        if scope.sanitize("a\tb\nc  d") != "a b c d":
            problems.append("sanitize leaves control characters in place")
    except Exception as exc:
        return _fail(f"source is stale or inconsistent: "
                     f"{type(exc).__name__}: {exc}")

    # --- prompt hardening --------------------------------------------------
    for name in HELPERS:
        if not callable(getattr(brain, name, None)):
            problems.append(f"brain.py lacks {name}()")
```

It also proves every persona has at least three refusal lines, all printable
ASCII and unique across the cast (lines 85-109), and that the profile carries a
readable `scope` block (111-124).

### 3.7 The installers

`install-scope-filter.sh` runs that proof **before** the backup and before
anything under `/opt` is removed, then proves the copy landed byte-identical:

```bash
# install-scope-filter.sh:17-39
# Refuse to install a stale tree. The whole package is copied below, so every
# gate rides along — but only if this source actually carries them. Checked
# before anything under /opt is touched, so a half-upgraded tree cannot land.
# The check lives in tools/preflight.py so it can also be run without root.
echo "== preflight =="
[ -f "$SRC/tools/preflight.py" ] || {
  echo "missing $SRC/tools/preflight.py — stale tree, refusing to install" >&2
  exit 1
}
PYTHONDONTWRITEBYTECODE=1 python3 "$SRC/tools/preflight.py" "$SRC"

if [ -d "$SRC/tests" ]; then
  for t in "$SRC"/tests/test_*.py; do
    [ -e "$t" ] || continue
    printf '  %-22s ' "$(basename "$t")"
    out=$(PYTHONDONTWRITEBYTECODE=1 python3 "$t" 2>&1) || {
      echo FAIL
      echo "$out" | tail -25
      exit 1
    }
    echo pass
  done
fi
```

```bash
# install-scope-filter.sh:52-70
if [ -d "$DEST" ]; then
  backup="$DEST.bak.$(date +%Y%m%d-%H%M%S)"
  cp -a "$DEST" "$backup"
  echo "backup  -> $backup"
fi

rm -rf "$DEST"
cp -r "$SRC/twelveactors" /opt/twelveactors/
find /opt/twelveactors -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null || true
chown -R root:root /opt/twelveactors

# The copy is what runs now: prove the modules that carry the gates landed
# identical to the source instead of trusting cp.
for f in scope.py brain.py bridge.py db.py cards/dods.json; do
  a=$(sha256sum "$SRC/twelveactors/$f" | cut -d' ' -f1)
  b=$(sha256sum "$DEST/$f" | cut -d' ' -f1)
  [ "$a" = "$b" ] || { echo "copy mismatch: $f" >&2; exit 1; }
done
echo "deployed: scope/brain/bridge/db/cards identical to source"
```

`install.sh` (fresh machine) compiles the four plugins, installs the daemon,
indexes the voice bank, binds the cast to RCBot2 profile slots, sets the
startup bounds, installs the unit and restarts the game server:

```bash
# install.sh:63-67
echo "== install daemon to /opt/twelveactors"
rm -rf /opt/twelveactors/twelveactors
install -d -o root -g root -m 755 /opt/twelveactors
cp -r "$SRC/twelveactors" /opt/twelveactors/
find /opt/twelveactors -name __pycache__ -type d -exec rm -rf {} +
```

```bash
# install.sh:171-180
echo "== scan voice bank"
runuser -u dod -- env PYTHONPATH=/opt/twelveactors python3 -m twelveactors \
    --data "$DATA" scan --install "$GAME"

echo "== bind the cast to RCBot2 profile slots"
runuser -u dod -- env PYTHONPATH=/opt/twelveactors python3 -m twelveactors \
    --data "$DATA" bootstrap --install "$GAME" --bots "$TARGET_BOTS"
```

Nothing about credentials is baked in. `install.sh` reads them from the
environment (or asks on a terminal, with the key input hidden) and writes
placeholders when it was given nothing:

```bash
# install.sh:125-138
python3 - "$DATA/config.json" <<'PY'
import json, os, sys
path = sys.argv[1]
cfg = {
    "engine": "dods",
    "base_url": os.environ.get("TA_API_BASE") or "<YOUR_API_BASE>",
    "model": os.environ.get("TA_MODEL") or "<YOUR_MODEL>",
    "api_key": os.environ.get("TA_API_KEY") or "<YOUR_API_KEY>",
    "port": 8377,
    "timeout": 20,
    "dialog_requires_human": True,
}
json.dump(cfg, open(path, "w"), indent=2)
open(path, "a").write("\n")
```

The one key the installer will fill in by itself is a Venice key already in
`~/.hermes/config.yaml`, and only while the base URL is Venice's
(`install.sh:95-122`). Every other host needs the operator's own key. When a
placeholder survives, the installer prints the file to edit and the restart
command instead of starting a daemon that cannot authenticate:

```bash
  Twelve Actors is installed but NOT connected to a model yet.
  Fill in the placeholders, then restart the daemon:

      sudo nano /srv/dods/dod/addons/sourcemod/data/twelveactors/config.json
      sudo systemctl restart twelveactors.service
```

### 3.7a What the operator must supply, and why the model is a recommendation

| Config key | Supplied how | Recommended value |
|---|---|---|
| `base_url` | `TWELVEACTORS_API_BASE`, or the prompt, or the placeholder | any OpenAI-compatible base; Venice is `https://api.venice.ai/api/v1` |
| `api_key` | `TWELVEACTORS_API_KEY`, or the hidden prompt; file is `0600 dod:dod` | none — yours |
| `model` | `TWELVEACTORS_MODEL`, or the prompt; change later with `install-model-switch.sh <id>` | `deepseek-v4-flash-0731` |

`deepseek-v4-flash-0731` is recommended, not required. It was chosen because it
is cheap on this workload (measured ~$0.0002 per reply: 304 prompt tokens,
74-123 completion tokens including 44-93 reasoning tokens), it returns a JSON
object, and it honours an explicit small `max_tokens`. A replacement has to do
those three things; that is the whole contract:

1. Accept an OpenAI-style `POST /chat/completions` with `response_format` JSON.
2. Honour `max_tokens: 600` (`brain.py:146`). A model that treats it as advice
   will burn the budget on reasoning and return truncated JSON, which the
   bridge turns into a canned bark - a visible failure, not a silent one.
3. Return one short line per call; long prose breaks the chat box and the
   18-word cap in `profiles/dods.json`.

To use another model, list the host's catalogue and switch by id:

```bash
curl -s "$BASE/models" -H "Authorization: Bearer <your-key>" | python3 -m json.tool
sudo bash install-model-switch.sh <model-id>
```

`install-model-switch.sh` no longer invents a default: with no id it prints the
recommendation and exits 2, leaving the config untouched
(`install-model-switch.sh:17-38`).

### 3.8 Runtime shape

```ini
# systemd/twelveactors.service
[Unit]
Description=Twelve Actors NPC conversation daemon (Day of Defeat: Source)
After=network-online.target dods.service
Wants=network-online.target

[Service]
Type=simple
User=dod
Group=dod
Environment=PYTHONPATH=/opt/twelveactors
Environment=PYTHONUNBUFFERED=1
WorkingDirectory=/opt/twelveactors
ExecStart=/usr/bin/python3 -m twelveactors --data /srv/dods/dod/addons/sourcemod/data/twelveactors serve
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/srv/dods/dod/addons/sourcemod/data/twelveactors
ProtectHome=true

[Install]
WantedBy=multi-user.target
```

On this machine the live config is `0600 dod:dod` and holds the real key; it
lives under `/srv/dods`, never in this tree. The shipped template carries
placeholders only (`config/config.example.json`):

```json
{
  "engine": "dods",
  "model": "deepseek-v4-flash-0731",
  "base_url": "<YOUR_API_BASE>",
  "api_key": "<YOUR_API_KEY>",
  "port": 8377,
  "timeout": 20,
  "dialog_requires_human": true,
  "_note_model": "deepseek-v4-flash-0731 is RECOMMENDED (cheap, JSON mode). Any OpenAI-compatible model that returns a JSON object and honours max_tokens works; put its id here. Switch later with install-model-switch.sh <id>."
}
```

`tools/check-secrets.py` proves the claim instead of asserting it — it walks
every file for `VENICE_…`, `sk-…`, `Bearer …` and long `api_key` values, and
with `--live-config` also for the literal key of a given config. It prints
only a four-character prefix, so running it cannot leak what it found:

```bash
python3 tools/check-secrets.py .
# ok: no credentials found in . (137 files scanned)

python3 tools/check-secrets.py --live-config /srv/dods/dod/addons/sourcemod/data/twelveactors/config.json .
# same answer: the live key appears nowhere in the tree
```

`make-dist.sh` runs the same check against the staging directory and exits 1
before `tar` if it finds anything (`make-dist.sh:46-54`), so a key cannot ride
out in an archive by accident.

Profile knobs (`twelveactors/profiles/dods.json`):

```json
"max_reply_words": 18,
"max_tokens": 600,
"scope": {"enabled": true, "max_words": 30, "repeat_window_s": 45, "extra_allow": []}
```

---

## 4. Installing on another computer

```bash
# 0. prerequisites, as on the reference box:
#    Linux, 32-bit runtime, SourceMod 1.12 in /srv/dods/dod/addons/sourcemod,
#    RCBot2 2.0-alpha8 in /srv/dods/dod/addons/rcbot2, service user `dod`,
#    python3, sqlite3. See HERMES-REBUILD.md sections 1-3 for the full stack.

tar xzf twelveactors-1.0.0.tar.gz
cd twelveactors-1.0.0

# 1. prove the tree before anything is installed
python3 tools/preflight.py .
# expect: preflight ok: 5 hostile lines refused, 3 squad lines allowed,
#         sanitize + prompt quoting, 12 personas x3+ refusals, scope block present

# 2. the suites
for t in tests/test_*.py; do echo "== $t"; python3 "$t"; done

# 3. install - credentials come from you, never from this tree
sudo GAME=/srv/dods TARGET_BOTS=12 \
     TWELVEACTORS_API_BASE=https://api.venice.ai/api/v1 \
     TWELVEACTORS_API_KEY=<your-key> \
     TWELVEACTORS_MODEL=deepseek-v4-flash-0731 \
     ./install.sh
# omit the three TWELVEACTORS_* vars and the installer asks on a terminal instead;
# with no terminal it writes <YOUR_API_BASE>/<YOUR_API_KEY>/<YOUR_MODEL> and
# prints the file to edit.
```

`install.sh` expects `spcomp` at
`/srv/dods/dod/addons/sourcemod/scripting/spcomp` and
`/srv/dods/dod/addons/rcbot2/config/config.ini`. It refuses to run if either is
missing rather than installing half the stack.

Afterwards:

```bash
curl -s localhost:8377/healthz | python3 -m json.tool
# ok, clips 232, bots_known 12, model <the id you installed>,
# roster 13 (12 bots + you), dialog_open true, errors []

# in the server console:
sm plugins list      # Twelve Actors Human Cap / Twelve Actors Bots (RCBot2) / Twelve Actors Bot Join / Twelve Actors
sm_ta_status        # humans=N require_human=1 team_chat=1 gated=N
sm_ta_humancap 12
```

If the machine already has a config from an older install, switch it explicitly
(the script takes any id and refuses to guess one):

```bash
sudo ./install-model-switch.sh <model-id>     # recommended: deepseek-v4-flash-0731
```

### Updating an existing machine

```bash
sudo ./install-scope-filter.sh
```

That one script runs `tools/preflight.py`, runs every test under `tests/`,
refuses a source tree that carries a credential (`tools/check-secrets.py`),
backs up `/opt/twelveactors/twelveactors` with a timestamp, copies the whole package,
verifies sha256 of the five gate files, restarts the unit and prints
`/healthz` plus the journal tail.

---

## 5. Verification ladder (what "working" actually looks like)

1. **Preflight, secrets and tests** — `python3 tools/preflight.py .`,
   `python3 tools/check-secrets.py .` and every `tests/test_*.py` exit 0.
2. **Daemon** — `/healthz` returns `ok: true`, `clips: 232`, `bots_known: 12`,
   and `model` equal to the id you installed.
3. **Human gate** — with nobody connected, `humans: 0`, `dialog_open: false`,
   and bot chatter produces no `in.tsv` growth and no model turns.
4. **Team routing** — a human on team 2 gets replies from team-2 bots; a human
   on team 3 gets team-3 bots; `out.tsv` lines carry four fields.
5. **Scope gate, live** — ask an off-topic line and check the turn log:
   ```bash
   sqlite3 state/state.sqlite \
     "select source, count(*) from turns group by 1;"
   # llm | filter | bark
   sqlite3 state/state.sqlite \
     "select ts, speaker, prompt, line from turns where source='filter' order by id desc limit 5;"
   ```
6. **Zero-token refusal** — a filtered line answers in ~90 ms and opens no
   socket; `/healthz` increments `scope.by_reason` instead of `turns` upstream.
7. **Hash match after a deploy** —
   ```bash
   for f in scope.py brain.py bridge.py db.py; do
     sha256sum twelveactors/$f /opt/twelveactors/twelveactors/$f
   done
   ```

Measured on real traffic: 66 human chat lines replayed → 7 refused (six
arithmetic, one bitcoin), zero legitimate squad lines caught. The full
`in.tsv` (23,808 rows) gave the same seven.

---

## 6. Failure modes already paid for

| Symptom | Cause | Fix in source |
|---|---|---|
| `ERRORNAME committed suicide` in the kill feed | Team change killed a teamless fake client before clients knew its name | `plugin/ta_botjoin.sp:52-66` |
| Bots kick/add churn, `Can't create bot, max_bots reached` | `max_bots` is a total client cap counting humans | `plugin/ta_bots_rcbot2.sp:103-127` |
| 13th human displaces a bot | No human ceiling | `plugin/ta_humancap.sp:40-62` |
| Bot lines look like white server announcements | `PrintToChatAll` | `plugin/twelveactors.sp:377-390` |
| Bot answers another bot's radio spam | RCBot2 presses `voice_*` too | `bridge.py:334-340`, `plugin/twelveactors.sp:271-277` |
| Off-topic questions cost tokens | No pre-filter | `twelveactors/scope.py` |
| "who will win the election" passes | `win` is a game word and ran first | `HARD_RULES` before allowlist, `scope.py:213-224` |
| "how much does a new GPU cost" passes | Missing hardware words | `scope.py:127-131` |
| "Otto 2(2)=?" passes | Worded-math pattern only | `scope.py:104-106` |
| Truncated JSON, canned bark | `max_tokens` too small for a reasoning model | `brain.py:146` pinned 600 |
| Player text landed in `act` column | `log_turn` called with an extra argument | `db.py:112-122` |
| Name with a quote can rewrite the prompt | Raw name pasted into a quoted slot | `brain.py:183-208` |
| Tab in a name shifts TSV fields | No ingest sanitiser | `bridge.py:84-87`, `bridge.py:262` |
| Half-upgraded tree installs silently | No install-time proof | `tools/preflight.py`, `install-scope-filter.sh:17-39` |

Tradeoffs left deliberately:

- The `chars` gate is ASCII-only, so accented English such as "café" is
  refused. It cost nothing on this server's traffic (none of 66 human lines had
  a non-ASCII character), and the alternative — folding Unicode first — is what
  opens the homoglyph hole.
- Usernames are never filtered. A non-Latin Steam name can play; the name is
  flattened and quote-neutralised instead. A client missing the glyphs renders
  boxes, and a tab in a name drops that one line rather than corrupting the row.
- Per-reply token counts are not stored in `turns`; cost figures come from
  direct measurement, not from the log.
- No TTS. Output audio is the game's own clips; text is separate.

---

## 7. Tests

| File | What it proves | Result on this tree |
|---|---|---|
| `tests/test_scope.py` | 54 classifier cases: math/meta/modern, election traps, non-English, emoji, RTL override, full-width, controls, injection, oversize, must-pass squad lines; sanitize; repeat guard; 36 unique refusal lines | 54/54, sanitize pass, repeat pass, 0 problems |
| `tests/test_prompt.py` | 23 checks: names survive, quotes neutralised, hostile name cannot open a second quoted slot, memory/event lines append | all pass |
| `tests/test_db.py` | Six injection payloads through the real DB layer: schema unchanged, payload round-trips verbatim, gate labels each `injection` | pass |
| `tests/test_preflight.py` | Damages a copy of the tree eight ways and asserts preflight fails for the right reason | 8/8 |
| `tests/test_secrets.py` | Nine cases: real `VENICE_`/`sk-`/`Bearer`/JSON-key values and a binary file must be caught; placeholders, `sk-...` and a short live key must not | 9/9 |

Run them from the tree and again from the extracted archive; the archive ships
them on purpose.

---

## 8. Hash manifest (tree, at the time of writing)

```
66c0b3d9494803a4ce512088dc1908b0eb27435708bd6f0a4a229e2257f06ad8  twelveactors/scope.py
fe8fd0809e762797feb8d19cca6dbbeac2498e7520a16a996060c48a6055319d  twelveactors/brain.py
0876d30edb9d65b5cc2b4277d8bf7981f01cbe979705758b3baf55f9190757b9  twelveactors/bridge.py
9cae64722887339b27bd098abc43986d7b03d10b25b10bf553ca28ad5c3f0d9f  twelveactors/db.py
31b0b837328b8a4335fdc0463c812e4aae23f8a306b981b8b8b6c28bffebbfe6  twelveactors/cards/dods.json
60bd4286f0ed2bdf1def3672886a9dd26853f7e0543f94c603721a1172b0e393  tools/preflight.py
aaa294b6dc520d1b880625f49857303c2caca58bd2ebd33fd7b7365e248b2b3e  tools/check-secrets.py
99383db20ee03cb8b5e29acd60d28d63e1e390f404ed51779fd5193cefbd42c9  install.sh
88e6836631aa527dfe2e6ca76e7b64ffa01604ec1e04fa9efe5fbfc6b2add083  install-scope-filter.sh
62218ab65a8129c638e7bd40dfb2fc4b3b7e788c213941f16dfd3f7e90a55dd3  install-model-switch.sh
f12238a977abc85ac516aa5b962a97d7a414118c7b48d77d0c5d3c8d93daad80  make-dist.sh
f50ca5657f17091035b25e53ce864c186a49e29e92e6c599a3a92b60c4d7923e  tools/make-handoff-zip.sh
13fd9d6b3c631da3faee4dd16dca550b92254d698ab9b36fc237c9d6393e8cb9  config/config.example.json
```

Compare a deployment with:

```bash
sha256sum /opt/twelveactors/twelveactors/scope.py /opt/twelveactors/twelveactors/brain.py \
          /opt/twelveactors/twelveactors/bridge.py /opt/twelveactors/twelveactors/db.py \
          /opt/twelveactors/twelveactors/cards/dods.json
```

---

## 9. Source tree map

```
twelveactors/            daemon package (scope, brain, bridge, db, server, voicebank, vpkread)
twelveactors/cards/      persona definitions incl. the refuse pool
twelveactors/profiles/   per-engine profile: acts, teams, scope knobs, max_tokens
plugin/             SourceMod plugins (twelveactors, ta_proximity, bots module, botjoin, humancap)
tools/              preflight, secret scan, rcon, radio labelling, spawnwatch, waypoints
tests/              seven suites: db, prompt, scope, secrets, preflight, rcon, voice
systemd/            twelveactors.service
install.sh          fresh install
install*.sh        fresh install and targeted updates, each run with sudo
make-dist.sh        builds ~/share/twelveactors-1.0.0{.tar.gz,.zip}
```

### 9.1 One-file handoff bundle

`tools/make-handoff-zip.sh` produces what you send to another machine: it
rebuilds the distributable first (so the bundle can never disagree with the
tree), then writes `~/share/twelveactors-handoff-<YYYYmmdd-HHMMSS>.zip` containing

```
START-HERE.md              what to read, what to supply, model contract
twelveactors-1.0.0/             the full distributable tree (62 files)
twelveactors-1.0.0.tar.gz       the same tree, for a Linux box
TWELVEACTORS-WORK-PERFORMED.md  this document (loose copy)
TWELVEACTORS-HANDOFF.md         state and operating notes (loose copy)
HERMES-REBUILD.md          rebuild-from-source notes (loose copy)
README.md                  overview (loose copy)
MANIFEST.txt               counts and full file list
SHA256SUMS.txt             sha256 of every entry
```

It refuses to write the zip if `tools/check-secrets.py` finds a credential in
the staged tree, and it re-verifies from the *extracted* archive afterwards —
secret scan, `tools/preflight.py`, all seven test suites, and
`sha256sum -c SHA256SUMS.txt` — because a staging directory that passes proves
nothing about what `zip` actually wrote. 70 archive entries, ~496 KB:

```bash
./tools/make-handoff-zip.sh
```

No `state/` and no `config.json` are ever included, only
`config/config.example.json` with `<YOUR_API_BASE>` / `<YOUR_API_KEY>`
placeholders; `model` there is the recommended id, and any OpenAI-compatible id
may replace it.

The live `/opt/twelveactors` was verified byte-identical to this tree for all five
gate files at 22:03 CDT on 2026-10-19, and `twelveactors.service` was active.

---

## 10. Per-bot voice, and the optional proximity module (2026-10-19 23:30 CDT)

DoD:S ships exactly one male US voice line set and one male German set, so
before this change every American bot in the cast barked in the same voice. The
fix is a playback pitch per persona, carried in the sound packet, so no asset,
no client download and no `precache_budget` change is involved.

Two features, deliberately split, because one is a property of the bridge and
the other is a property of the server's taste:

1. **Per-bot pitch — core, default on.** `plugin/twelveactors.sp:117` creates
   `sm_ta_voice_pitch` (default `1`). `PersonaVoice()`
   (`plugin/twelveactors.sp:511`) resolves a persona to `(pitch, gain)`: from
   `data/twelveactors/voices.tsv` when the persona has a row, otherwise from an
   FNV-1a hash of the name into 92–112, which is stable across maps and
   restarts without any file. `LoadVoices()` (`:478`) reads the table and
   `sm_ta_reload` re-reads it live. `PlayBark()` (`:536`) emits the clip to
   everyone at that pitch and gain — volume behaviour is unchanged from before
   this work, which is the point of keeping it in the core.
   `sm_ta_voices` (`:600`) prints the resolved pitch and gain per client, so
   the cast can be inspected without joining.

2. **Distance falloff — optional module.** `plugin/ta_proximity.sp` is a
   second, independent plugin. It is the only place in the tree with distance
   maths (`GetVectorDistance`, `Falloff` at `:147`), and the only place that
   emits per listener (`EmitSoundToClient`, `:125`).

The seam is a source-level forward, not a shared global or a convar probe. The
core creates it in `AskPluginLoad2` (`plugin/twelveactors.sp:79`) as

```
CreateGlobalForward("Ta_OnBotVoice", ET_Hook, Param_Cell, Param_String, Param_Cell, Param_Float)
```

and, in `PlayBark`, pushes `(speakerId, clip, pitch, gain)` before its own
`EmitSoundToAll`. A plugin that defines `public Action Ta_OnBotVoice(int,
const char[], int, float)` receives the call and returns `Plugin_Handled` to
claim playback; anything else and the core plays it flat. Consequences worth
knowing, all of them verified by `tests/test_voice.py`:

- Global forwards bind by public function name, so load order does not matter:
  module before core, after core, or reloaded independently all work. On a core
  reload the module is unloaded first by the installer and loaded again, which
  is the one ordering the installer enforces rather than assumes.
- Two playback modules cannot double-emit: `ET_Hook` stops at the first
  `Plugin_Handled`.
- A bark whose persona left the server between the daemon's write and the
  poll has no origin to measure; the module returns `Plugin_Continue` and the
  core's flat path still delivers the audio.

`ta_proximity`'s curve is linear in amplitude from `near` (150 u, default
`sm_ta_proximity_near`) to `far` (1200 u, `sm_ta_proximity_far`), reaching
`sm_ta_proximity_minvol` (`0.0` — beyond `far` the clip is simply not sent).
Barks reach everyone in range (`sm_ta_proximity_team_only`, `0` — the volume
carries the distance cue, so restricting the audience to one team only removes
information; `--team-only` restores the restriction, `sv_alltalk 1` forces
everyone), and spectators always hear them. Emission uses
`SNDLEVEL_NONE` so the engine does not apply a second attenuation curve on top
of the computed volume while the origin still spatialises the sound; the comment
at `plugin/ta_proximity.sp:123` records that reasoning. `sm_ta_prox` reports
the dials and the last bark's listener count and distance range.

Distribution rule: the module is compiled by `install.sh` but installed into
`plugins/disabled/` (`install.sh`, "optional module" branch), so a fresh install
behaves exactly like the previous release. `install-voice.sh` is the upgrade and
toggle path on a running server — it compiles both plugins with the server's own
`spcomp`, backs up the core `.smx`, installs, unloads/loads the module, reloads
the core over the console FIFO and prints `sm_ta_status`, `sm_ta_voices` and
`sm_ta_prox` over rcon. `--with-proximity` enables, `--without-proximity`
disables, no argument keeps the current state.

Proof added: `tests/test_voice.py` (29 checks) pins the split — the core must
create the forward, must not contain `GetVectorDistance` or `Falloff`, the
module must implement the exact four-argument signature and claim the bark,
`sm_ta_proximity_team_only` must default to 0 so every player hears a bark,
the voice installer must offer `--all-audible` and migrate a pre-existing cfg
line (the extracted `sed` is run through bash against quoted, bare and unrelated
samples), the installer must not enable the module by default, the curated
pitches must be distinct
and inside 92–112, and both plugins must compile warning-free when `spcomp` is
reachable. `tools/check-plugin.sh` compiles every `plugin/*.sp` in a tree without
root. Total suites: seven (`test_db`, `test_preflight`, `test_prompt`,
`test_rcon`, `test_scope`, `test_secrets`, `test_voice`).
