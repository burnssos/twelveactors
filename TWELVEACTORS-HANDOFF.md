# Twelve Actors — work performed, and how to install it on another machine

Last updated **2026-10-19 22:03 CDT**. Written for another Hermes agent (or a
human operator) standing the same stack up on a fresh box.

`HERMES-REBUILD.md` is the long install runbook — phases 1–12, with the reasoning
behind each step. This file is the **change log plus the short path**: what was
built and fixed, what has to be true before you call it done, and the exact
commands. Where the two disagree, this file is newer.

---

## 0. If you are the agent doing the install

1. Read sections 1–3 for the shape of the thing, then section 7 for the build.
   Do not invent paths: game `/srv/dods`, service user `dod`, data dir
   `/srv/dods/dod/addons/sourcemod/data/twelveactors`, daemon `/opt/twelveactors`.
2. After every phase, run the check at the end of it. Every failure in section 10
   was silent until someone ran a check — this stack fails by doing nothing, not
   by crashing.
3. Install from the **distributable** (`twelveactors-1.0.0.tar.gz`), not from a source
   checkout with local edits. `tools/preflight.py` refuses a tree that is
   half-upgraded; if it stops you, the tree is wrong, not the check.

---

## 1. What the system is

A Day of Defeat: Source server whose bots are characters rather than strangers.
SourceMod captures chat, kills, rounds and quick-key radio into an append-only
TSV; a Python daemon reads it, picks a persona, asks an OpenAI-compatible model
for one short in-character line, matches the *intent* to a clip the game already
ships, and appends `clip + text` to a second TSV; the plugin plays the clip and
says the text as that bot's own team chat.

No TTS, no audio generation, no voice cloning. Voiced output is the 232
`player/{american,german}/*.wav` clips inside `dod_pak_dir.vpk`, read in place.

```
player chat ─┐
quick keys  ─┤  twelveactors.sp           in.tsv         bridge.py ──► brain.py ──► LLM
deaths/rounds┘  ta_bots_rcbot2.sp       ────────►  ──►  scope.py (free refusal)
                ta_humancap.sp                          │
                ta_botjoin.sp                           ▼
                ta_proximity.sp (opt) ──► out.tsv ──► twelveactors.sp plays clip + say_team
```

`ta_proximity.sp` is optional and ships compiled in `plugins/disabled/`. When it
is loaded it claims each bark through the `Ta_OnBotVoice` forward and emits per
listener; when it is absent the core's own `EmitSoundToAll` plays the bark.

| Component | Value on the reference box |
|---|---|
| OS | Omarchy (Arch), x86-64, Intel N97, 4 GB RAM, no GPU |
| Game | DoD:S dedicated, app 232290, 32-bit (`multilib`) |
| SourceMod | 1.12.0-git7255 |
| RCBot2 | 2.0-alpha8 32-bit, build c5b6eb10, 5,706 waypoints |
| Python | 3.11, standard library only |
| Game root / unit | `/srv/dods`, `dods.service`, user+group `dod` |
| Data dir | `/srv/dods/dod/addons/sourcemod/data/twelveactors` (0750 `dod:dod`) |
| Daemon / unit | `/opt/twelveactors`, `twelveactors.service`, HTTP 127.0.0.1:8377 |
| Model | recommended `deepseek-v4-flash-0731`; any OpenAI-compatible model with JSON output works |
| API base / key | yours: `TWELVEACTORS_API_BASE` / `TWELVEACTORS_API_KEY` at install; none ships in this tree |

---

## 2. Where the truth lives

| Path | Role |
|---|---|
| `$HOME/twelveactors` | **source of truth** — every live fix must exist here |
| `$HOME/share/twelveactors-1.0.0.tar.gz`, `.zip` | distributables built by `./make-dist.sh` |
| `/opt/twelveactors` | deployed daemon (root-owned, runs as `dod`) |
| `/srv/dods/.../data/twelveactors` | live data: `in.tsv`, `out.tsv`, `roster.tsv`, `config.json`, `state.sqlite` |
| `$HOME/snapshots/` | dated backups (`twelveactors-20261019-193244`, `-220359`) |

Verified at the timestamp above — tree and `/opt` byte-identical for every module
that carries a gate:

```
66c0b3d9…  twelveactors/scope.py
fe8fd080…  twelveactors/brain.py
0876d30e…  twelveactors/bridge.py
9cae6472…  twelveactors/db.py
31b0b837…  twelveactors/cards/dods.json
60bd4286…  tools/preflight.py
0097597d…  install-scope-filter.sh
```

Live health at the same moment:

```json
{"ok":true,"clips":232,"bots_known":12,"turns":9888,"engine":"dods",
 "model":"deepseek-v4-flash-0731","bridge":{"in":65,"out":19,"skipped":2,
 "errors":0,"gated":8,"filtered":0},"roster":12,"humans":0,"dialog_open":false,
 "scope":{"filtered":0,"by_reason":{}},"errors":[]}
```

`humans:0, dialog_open:false` is the idle gate working, not a fault.

---

## 3. Work performed — change log with the reason

### 3.1 Foundation (before this session)

| Change | Why it exists |
|---|---|
| `twelveactors.sp` — chat, death, round, radio hooks | Engine has no event bus; TSV is the only durable channel. Radio arrives as `voicemenu`, never `say`, so it needs `AddCommandListener("voicemenu")`. |
| `ta_bots_rcbot2.sp` — population module | RCBot2's `max_bots` is a **total client** cap that counts humans. Writing the bare bot target strangles the roster when someone joins. Module writes `max_bots = target + humans`, re-asserts on every config exec and every change, and renames strays instead of kicking (a kick broadcasts a death notice and re-enters RCBot2's add path). |
| `ta_humancap.sp` | 12 human slots + 12 bot slots out of `+maxplayers 24`; a 13th human is refused at `OnClientConnect`, so no bot is displaced. |
| `ta_botjoin.sp` | RCBot2 sets a bot's team *before* the class command, and DoD:S spawns the fake client on connect — so the team change killed a live classless body and the kill feed showed `ERRORNAME committed suicide`. Holds team-0 fake clients `LIFE_DEAD` on `player_spawn`. |
| Human-presence gate, both halves | Plugin stops writing `in.tsv` when `CountHumans()==0` (`sm_ta_require_human`); daemon drops ambient events unless `roster.tsv` lists a human (`dialog_requires_human`). Idle server costs nothing and nothing queues. |
| Team chat, not white server text | `Timer_Poll` resolves persona → client and calls `FakeClientCommand(client, "say_team %s", text)`, so the engine formats it as that bot's team chat. `sm_ta_team_chat 0` reverts to `PrintToChatAll`. `SaySafe()` strips `"` and `;` first — the text crosses a command parser. |
| Bot radio callouts not answered | RCBot2 bots press the same radio commands players do — `in.tsv` held 341 `voice_grenade` per name per map. Plugin no longer records fake-client `voice_*`; daemon refuses radio from a roster name. |
| `tools/label_radio.py` + `radio_map.json` | Labels live in the client binary; a human names each `menu:item` pair once. Hot-reloads. |

### 3.2 This session (2026-10-19)

1. **Backed up before touching anything** — `$HOME/snapshots/twelveactors-20261019-193244/`,
   four sha256-verified archives (source 144 files, dist, server state).
2. **Verified reply routing was actually deployed**, not just written: tree↔live
   hash match, team filter at `bridge.py:267-277`, `_names_bot` at 87, restart
   timestamp and clean journal.
3. **Switched the model to `deepseek-v4-flash-0731`.** Priced on the daemon's real
   prompt (304 prompt / 74–123 completion incl. 44–93 reasoning tokens):
   **$0.0002 per reply vs $0.00055** on the previous model, ~2.8× cheaper.
   Validated the catalogue and a live-shaped call before editing config. Staged as
   `install-model-switch.sh` (this session cannot sudo).
4. **Measured the real saving** — 9,712 turns/24 h on the old model ≈ $0.26 per
   1,000 replies.
5. **Built the scope gate** (`twelveactors/scope.py`) so off-topic questions cost
   **zero tokens**: 12 personas × 3 in-voice refusal lines in
   `cards/dods.json` (36 lines, unique, printable ASCII); a deterministic
   classifier runs before any socket is opened; a refused line pulls a random
   refusal from that persona and reuses a negative voice clip, so it looks like
   any other reply.
6. **Fixed the first version's leaks** found by testing, not by reading:
   - "how much does a new GPU cost" was a paid turn → GPU/CPU/laptop/salary/taxes
     added to the hard modern family;
   - "Otto 2(2)=?" slipped the worded-math pattern → symbolic arithmetic added;
   - "who will win the election" passed because `win` is a combat word and the
     allowlist ran first → **two-tier order**: `HARD_RULES` (math, meta, modern)
     before the allowlist, `SOFT_RULES` (money, price, cost, news) after it.
7. **Turn log made honest** — `log_turn` was called with one argument too many,
   putting player text in `act` and losing the reply. Fixed the signature and
   added `prompt` and `source` (`llm` / `filter` / `bark`) columns with
   auto-migration, so cost per path is queryable.
8. **Metrics exposed** — `/healthz` reports `scope.filtered` and `by_reason`.
9. **Hostile-input hardening** (requested explicitly):
   - `chars` — anything outside printable ASCII (Cyrillic, CJK, emoji, accents,
     zero-width joiners, RTL overrides, control bytes) refused **on the raw line,
     before normalisation**, so full-width or combining look-alikes cannot be
     folded to ASCII first;
   - `injection` — SQL/database/shell grammar (`drop table`, `select … from`,
     `union select`, `' or 1=1`, `pragma`, `sqlite_master`, `attach database`,
     `$(…)`, semicolon + SQL verb);
   - `oversize` — over 400 characters (the plugin's maximum);
   - `sanitize()` — strips tabs, newlines and C0/C1 controls and collapses space
     runs; `bridge.clean()` routes through it, so no TSV field or log line can
     carry an unprintable byte; `db.log_turn` caps speaker 64 / prompt 400 /
     line 400 / clip 255. **Schema deliberately unchanged** — existing data
     survives.
10. **Username question answered and hardened.** The gate sees chat *text*, never
    the name, so a non-Latin Steam name can still play: `classify()` allowed
    player `"Иван"`/`"玩家一"` with an ammo line while refusing the same
    non-English *text*; the real bridge round-tripped `"Иванов"` through `out.tsv`
    with all four fields intact; the model transliterated to "Ivanov". The
    investigation exposed a real bug — the engine-supplied name was pasted raw
    into a quoted prompt slot, so `Bob "the kid"` could close the slot and append
    instructions. Fixed with `clean_name()` (one line, no controls, quotes →
    apostrophes, cap 32), `quote()` (backslash, then quote escaping) and
    `compose_user()`, applied at the single point `_llm()` builds the prompt;
    `bridge.py` flattens the name at all three ingest points.
11. **Tests written, not just run once** — seven suites, see section 6.
12. **`tools/preflight.py`** — the install-time proof, extracted from the installer
    so it runs without root. Checks the gates against hostile and legitimate
    lines, checks `sanitize`, checks the prompt helpers exist, checks every
    persona has ≥3 unique printable-ASCII refusals, checks the scope block.
    `install-scope-filter.sh` runs it **before** the backup and before anything
    under `/opt` is removed, and re-checks sha256 of the five gate files after the
    copy so a partial `cp` cannot land silently.
13. **Distributables rebuilt** with every one of the above; the archive carries
    `tests/` and `tools/preflight.py` and passes its own suite from inside the
    extracted tarball.
14. **Backups dated** — `twelveactors-20261019-193244` (pre-change) and
    `twelveactors-20261019-220359` (current, 1.7 MB, gzip-verified, state sqlite taken
    with `sqlite3 .backup` rather than a raw copy of a live WAL).
15. **Per-bot voice, and distance as an optional module.** Every American bot
    used to bark in the one US voice DoD:S ships. The core now plays each bark at
    that persona's own pitch and gain (curated in `config/voices.example.tsv`,
    hash-derived otherwise), which costs no asset, no download and no API call —
    pitch travels in the sound packet. The distance curve is deliberately *not*
    in the core: `ta_proximity.sp` is a separate plugin that claims playback
    through the `Ta_OnBotVoice` forward and emits per listener, so a server that
    does not want proximity gets exactly the old behaviour. It ships compiled in
    `plugins/disabled/`; `install-voice.sh --with-proximity` turns it on live.
    `tests/test_voice.py` pins the split so a later edit cannot fold the falloff
    back into the default path.
16. **Audience is everyone, distance is the only trim.** `sm_ta_proximity_team_only`
    defaults to `0`: both teams and spectators hear a bark, so no `sv_alltalk`
    is needed. Audience and attenuation are separate — the listener loop walks
    every human in game and only the team filter can shrink that set; the volume
    curve alone decides how loud each listener gets it. Because SourceMod writes
    `cfg/sourcemod/ta_proximity.cfg` once and never rewrites it, a shipped
    default cannot reach a server that already has the file: `install-voice.sh
    --all-audible` backs the cfg up and rewrites the one `team_only` line in
    place before reloading. `tests/test_voice.py` runs that extracted `sed`
    against quoted, bare and unrelated samples so the migration cannot rot.
    Note that RCBot2's own radio voices (`rcbot_voice_cmds` in
    `addons/rcbot2/config/config.ini`) never pass through SourceMod and so are
    not attenuated by any Twelve Actors plugin; `sm_ta_prox` warns when it sees them.

---

## 4. The scope gate, in detail

`twelveactors/scope.py`, called from `bridge.py` before `brain.py` opens a socket.

Order matters, and each step is deliberate:

| # | Check | Reason string | Notes |
|---|---|---|---|
| 1 | `len(raw) > 400` | `oversize` | plugin caps at 400; longer is an HTTP caller or abuse |
| 2 | non-printable-ASCII | `chars` | raw line, first 400 chars, before normalisation |
| 3 | SQL/shell grammar | `injection` | grammar, not punctuation — see below |
| 4 | same player + line inside 45 s | `repeat` | skipped for deliberate radio presses |
| 5 | `HARD_RULES`: math, meta, modern | `math` / `meta` / `modern` | **before** the allowlist |
| 6 | any `GAME_WORDS` (or `extra_allow`) | — | allowed outright |
| 7 | `SOFT_RULES`: money, price, cost, news | `modern` | **after** the allowlist |
| 8 | more than `max_words` (30) | `length` | |
| 9 | otherwise | `in_scope` | model call |

The two-tier split exists because `win`, `won` and `score` are ordinary combat
words: "who will win the election" must not be rescued by the word "win", while
"this cost us the round" must stay in scope. Rule families that are never
legitimate squad talk run first; ambiguous money words run last, where a combat
word settles the call.

Design rules that keep it from refusing real players:

- **Any combat word allows the line** — ammo, medic, flag, flank, cover, MG,
  push, spawn, the weapon names, the map nouns.
- **Radio-menu presses bypass dedupe** (`dedupe=False`) — a repeated "go go go"
  from the radio menu is new information.
- **The gate is biased toward answering.** It refuses only what is unambiguous.
  A missed refusal costs $0.0002; a wrongful refusal breaks the feature.
- **Refusal is local and free**: random line from `persona["refuse"]`, a negative
  voice clip, `source=filter`, no outbound socket, ~90 ms.
- **Prompt carries the same rule as a second layer** for anything ambiguous that
  slips past.

Config knobs (live `config.json`, defaults in `profiles/dods.json`):

```json
"scope": {"enabled": true, "max_words": 30, "repeat_window_s": 45, "extra_allow": []}
```

`extra_allow` is the escape hatch for a community with its own vocabulary.

Measured on real traffic: 66 human chat lines from `in.tsv` → 7 refused (six
arithmetic, one bitcoin), zero legitimate squad lines caught. Full `in.tsv`
replay (23,808 rows) gave the same seven.

---

## 5. Hardening, in detail

- **Gate before spend.** `chars`, `injection` and `oversize` are not judgement
  calls; they are refused before the repeat guard and before any rule matching,
  so the cheapest rejection happens first.
- **`chars` on the raw line.** Running it after lower-casing/normalisation would
  let full-width `Ａ` fold to `A` and accented forms fold to ASCII. Refused text
  is still stored in the turn log for forensics but never sent upstream.
- **Injection as grammar.** `drop table` is refused; "drop your weapons" is not
  (no object after *drop*). `select … from` is refused; "select fire is on" is
  not. Four such legitimate lines are pinned in the tests.
- **Write-side sanitisation** (defence in depth beside parameterised queries):
  every value in `db.py` is bound; the only f-strings are migrations over
  internal table-name constants, never player text. `sanitize()` guarantees no
  tab/newline/control byte reaches a TSV field or log line.
- **Prompt-slot safety.** `<player>` text is flattened and quote-neutralised, and
  chat text is escaped, so neither can terminate the quoted slot it sits in.
- **Names are never filtered.** A non-Latin Steam name is legitimate; only chat
  text is gated. A tab in a name would shift TSV fields — the roster writer and
  the say path both flatten it, and a shifted row is dropped rather than stored
  corrupt.

---

## 6. Tests and preflight

Run from the repo root; each file is standalone (no pytest needed).

```bash
python3 tests/test_scope.py       # 54 classify cases (16 allow / 38 refuse), sanitize, repeat guard
python3 tests/test_db.py          # 6 injection payloads through the real db layer
python3 tests/test_prompt.py      # 23 checks: names/text, quoting, memory lines
python3 tests/test_preflight.py   # 8 checks: preflight catches 7 kinds of damage
python3 tests/test_rcon.py        # 7 checks: argument / password handling, no leak
python3 tests/test_secrets.py     # 9 checks: scanner finds keys, ignores placeholders
python3 tests/test_voice.py       # 29 checks: pitch table, core/module split, cfg migration
python3 tools/preflight.py        # install-time proof against this tree
```

All seven at once, from the repo root:

```bash
for t in tests/test_*.py; do echo "== $t"; python3 "$t" || break; done
```

Reference output:

```
tests/test_db.py        6 payloads stored as data, gate reason injection
tests/test_preflight.py 8/8 preflight checks pass
tests/test_prompt.py    all prompt tests passed
tests/test_rcon.py      7/7 rcon argument checks pass
tests/test_scope.py     54/54 classify cases pass; 36 refusal lines across 12 personas, 0 problem(s)
tests/test_secrets.py   9/9 secret-scan checks pass
tests/test_voice.py     29/29 voice-module checks pass

preflight ok: 5 hostile lines refused, 3 squad lines allowed, sanitize + prompt
quoting, 12 personas x3+ refusals, scope block present
```

`test_scope.py` includes real `in.tsv` lines, the election traps, non-English and
emoji lines, RTL override, full-width look-alikes, control bytes, injection
payloads, and the four squad lines that must still pass.

`test_voice.py` is the one that guards this feature's shape: the core plugin must
carry the pitch table and no distance maths, `ta_proximity.sp` must claim the
bark with the exact four-argument `Ta_OnBotVoice` signature, the installer must
not enable the module by default, curated pitches must be distinct and inside
92–112, both plugins must compile warning-free, and the shipped
`sm_ta_proximity_team_only` default must be `0`.

---

## 7. Installing on a fresh machine

Long version with reasoning: `HERMES-REBUILD.md` phases 1–8. Short path:

```bash
# 1. OS + 32-bit runtime
sudo pacman -S --needed base-devel lib32-glibc lib32-libstdc++5 lib32-gcc-libs \
    lib32-libx11 lib32-alsa-lib steamcmd python
sudo useradd -r -m -d /var/lib/dods -s /bin/bash dod

# 2. game (run app_update twice; the first pass is often a revision behind)
sudo -u dod mkdir -p /srv/dods
sudo -u dod steamcmd +force_install_dir /srv/dods +login anonymous \
    +app_update 232290 validate +quit

# 3. unit /etc/systemd/system/dods.service — see HERMES-REBUILD.md §2
#    console is a FIFO: /run/dods/console, KillSignal=SIGINT, script -qfc …
sudo systemctl daemon-reload && sudo systemctl enable --now dods

# 4. SourceMod 1.12 + RCBot2 2.0-alpha8 32-bit into /srv/dods/dod
#    metaplugins.ini -> addons/sourcemod/bin/sourcemod_mm
#    rcbot2/config/config.ini -> min_bots 0 / max_bots 12 / nonrandom 1
```

Then the Twelve Actors part, from the extracted distributable:

```bash
tar xzf twelveactors-1.0.0.tar.gz && cd twelveactors-1.0.0

# 5. prove the tree before installing anything
python3 tools/preflight.py .
for t in tests/test_*.py; do python3 "$t" || break; done

# 6. daemon package
sudo install -d -o root -g root -m 755 /opt/twelveactors
sudo cp -r twelveactors /opt/twelveactors/
sudo chown -R root:root /opt/twelveactors

# 7. config (0600 dod:dod) — key, model, port
#    /srv/dods/dod/addons/sourcemod/data/twelveactors/config.json
#    {"engine":"dods","model":"<YOUR_MODEL>",          # recommended:
#                                                      # deepseek-v4-flash-0731
#     "base_url":"<YOUR_API_BASE>","api_key":"<YOUR_API_KEY>",
#     "port":8377,"timeout":20,"dialog_requires_human":true}

# 8. index the voice bank (read-only VPK; expects 232 clips)
sudo -u dod PYTHONPATH=/opt/twelveactors python3 -m twelveactors \
    --data /srv/dods/dod/addons/sourcemod/data/twelveactors scan

# 9. bind the cast to RCBot2 profile slots 1..12
sudo -u dod PYTHONPATH=/opt/twelveactors python3 -m twelveactors \
    --data /srv/dods/dod/addons/sourcemod/data/twelveactors bootstrap --bots 12

# 10. plugins (spcomp from SourceMod)
sudo bash install.sh          # compiles 5 plugins, installs, writes config, restarts
#    ta_proximity lands in plugins/disabled unless it is already enabled
# 11. daemon unit — systemd/twelveactors.service; Requires= and PartOf= dods.service
sudo systemctl enable --now twelveactors
```

`install.sh` is idempotent and is the supported way to ship a code change on an
existing box too.

### Deploying an update to a machine that is already running

| You changed | Run |
|---|---|
| model or API key | `sudo bash install-model-switch.sh [model]` |
| reply routing (`bridge.py`) | `sudo bash install-reply-routing.sh` |
| scope gate / hardening (`scope.py`, `brain.py`, `bridge.py`, `db.py`, cards) | `sudo bash install-scope-filter.sh` |
| `.sp` plugin source | `sudo bash install.sh` |
| voice pitch table, or enabling/disabling the proximity module | `sudo bash install-voice.sh` (`--with-proximity` / `--without-proximity`) |
| barks audible to both teams (existing server) | `sudo bash install-voice.sh --all-audible` |

Every `install-*.sh` backs up what it replaces and prints `/healthz` afterwards.
`install-scope-filter.sh` is the strict one: preflight → all seven test suites →
backup → copy → sha256 compare of the five gate files → restart → healthz.
`install-voice.sh` backs up the `.sp` files and `cfg/sourcemod/ta_proximity.cfg`,
recompiles, reloads the core, rebinds the module, and prints `sm_ta_prox` so the
live dials (near, far, minvol, team_only, audience) are visible without rcon.

---

## 8. Verification ladder

Run in order; each isolates a layer. Brackets = reference values.

```bash
systemctl is-active dods twelveactors                    # active / active
curl -s localhost:8377/healthz                      # clips 232, bots_known 12
sudo tools/label_radio.py --list                    # menu:item pairs seen
/usr/local/bin/dods-console 'rcon sm_ta_bots'      # target=12 bots=12
/usr/local/bin/dods-console 'rcon sm_ta_humancap'  # 12
/usr/local/bin/dods-console 'rcon sm_ta_voices'    # 12 clients, pitch 92-112, gain 1.00
/usr/local/bin/dods-console 'rcon sm_ta_prox'      # near/far/minvol/team_only + audience
sudo -u dod PYTHONPATH=/opt/twelveactors python3 -m twelveactors \
    --data /srv/dods/dod/addons/sourcemod/data/twelveactors selftest
```

Through the daemon without a game client (proves the gate and the model path):

```bash
curl -s -X POST localhost:8377/v1/turn -H 'content-type: application/json' \
  -d '{"player":"Burnside","text":"Otto, what is 2 times 2 plus 5?"}'
curl -s -X POST localhost:8377/v1/turn -H 'content-type: application/json' \
  -d '{"player":"Burnside","text":"Otto, ammo on the flank"}'
```

First must refuse in character with `source=filter`; second must reach the model.
Files on disk prove it:

```bash
sqlite3 /opt/twelveactors/state/state.sqlite \
  "select source,count(*) from turns group by 1;"
curl -s localhost:8377/healthz | python3 -m json.tool | sed -n '/scope/,/}/p'
```

Expected on the reference box after idle: `gated` climbing, `out` flat,
`humans:0`, `dialog_open:false`. Join, and both move within one roster tick.

---

## 9. Failure modes already paid for

| Symptom | Cause | Fix |
|---|---|---|
| Deploy appears to do nothing | unit had `After=dods.service` only | `Requires=` **and** `PartOf=dods.service` |
| Restart fires a burst of barks | bridge replayed `in.tsv` from offset 0 | seek to end on start |
| Bots silent after a rename, no errors | script stopped `twelveactors.service` and never started it; `last_out` froze | start it after the branch, trap EXIT |
| `ERRORNAME committed suicide` every ~10 s | team change killed a classless body | `ta_botjoin.smx`, `player_spawn`, `LIFE_DEAD` |
| 8 of 12 personas, 4 missing | profile `team=` empty / `class=-1` | `bootstrap --bots 12`; module renames strays |
| Random-named bots | `max_bots` 24 > personas, nonrandom 0 | `max_bots = personas + humans`, nonrandom 1 |
| Bots never spawn | RCBot2 rejects `min_bots >= max_bots` | `min_bots 0` |
| Radio keys silent | client sends `voicemenu`, never `say` | `AddCommandListener("voicemenu")` |
| Radio answers generic | `radio_map.json` empty | label pairs once with `tools/label_radio.py` |
| `scan` finds 0 clips | pointed at a split VPK | pass `dod_pak_dir.vpk` |
| HTTP 400 on model call | host default `max_tokens` 65536 > model cap | explicit `max_tokens` |
| Truncated JSON from a reasoning model | `max_tokens` too small — reasoning eats the budget | keep **600**; 200/300 fails |
| Line printed, no voice | no clip matched the intent | shorten the line |
| `install-scope-filter.sh` refuses | preflight found a stale or damaged tree | fix the source; it is telling the truth |

---

## 10. Tradeoffs and deliberately unfinished

- **ASCII-only gate.** Accented English ("café") is refused, because the rule is
  printable ASCII. On this server's real traffic it costs nothing — none of 66
  human lines carried a non-ASCII character — and it blocks homoglyph and
  RTL-override evasion. Relax `chars` only if a community actually types
  accented text.
- **Usernames are not gated.** A non-Latin Steam name plays normally; a client
  missing the glyphs will draw boxes, and an emoji name will not render. That is
  a display limit, not a daemon limit.
- **Per-turn token counts are not stored.** Cost figures come from direct
  measurement ($0.0002/reply), not from the log. Adding prompt/completion token
  columns to `turns` is the obvious next step and was left out to avoid touching
  the schema.
- **Radio labels are per-server data**, not source. `radio_map.json` must be
  built once per install with `tools/label_radio.py`; until then every call gets
  an acknowledgement bark.
- **One engine.** `cards/` and `profiles/` carry `dods`. TF2 is a port, not a
  config change.
- **Piper TTS was tried and removed** (venv, voices, demo clip). Voiced output is
  the game's own clips; the snapshot that proves the experiment is retained.
- **Anonymous Steam logon** is fine on a LAN, throttled in public; use a GSLT for
  a public server.

---

## 11. Paste-ready prompt for the rebuilding agent

> You are installing Twelve Actors on a fresh Arch/Omarchy host. Read
> `TWELVEACTORS-HANDOFF.md` first, then `HERMES-REBUILD.md` phases 1–8. The game root
> is `/srv/dods`, the service user is `dod`, the data dir is
> `/srv/dods/dod/addons/sourcemod/data/twelveactors`, the daemon is `/opt/twelveactors`.
> Before installing anything, run `python3 tools/preflight.py .` and all seven
> test files; a tree that fails them must not be installed. After phase 4 verify
> `scan` finds 232 clips; after phase 9 verify `/healthz` reports `bots_known 12`
> and `clips 232`; after phase 11 send both a math line and an ammo line to
> `POST /v1/turn` and confirm the first is `source=filter` and the second reaches
> the model. Report the final `curl -s localhost:8377/healthz`, the
> `sm_ta_bots` line from the console, and the last two lines of `out.tsv`. If a
> check fails, read section 9 before changing anything — every entry there
> already happened once.
