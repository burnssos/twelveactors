# Twelve Actors

A conversation layer for Source-engine bots. Twelve Actors binds each bot slot
to a persona with a voice, lets an LLM write short in-character lines, and then
plays the line back using **the voice clips the game already ships** — no TTS,
no audio generation, no voice cloning. (Chat with ai-bots using affordable llm models for inference).

Built against Day of Defeat: Source with RCBot2, but the design is
engine-shaped, not mod-shaped: HL2:DM, CS:S and TF2 expose the same hooks.

```
 player chat  ──┐
 quick keys   ──┤   SourceMod plugin        append-only TSV        Python daemon
 deaths/rounds──┴──►  twelveactors.sp ──►   in.tsv      ──►   twelveactors/bridge.py
                      ta_bots_rcbot2.sp                       ├─ personae (sqlite)
                      ta_botjoin.sp  (no team-change death)   │
                                                              ├─ LLM (OpenAI-compatible)
                                                              └─ voice clip picker
                                        out.tsv  ◄──  clip + chat line
                                           │
                      twelveactors.sp plays the clip on the speaking bot
```

## What it does

- **Bots text chat back.** Address a bot by name in chat and it answers, in character,
  with a line short enough to be spoken.
- **Real voices.** Every line is matched to an existing `.wav` inside the game's
  `dod_pak_dir.vpk` (read in place — nothing is extracted to disk) and played as
  that bot's `scene`/`speech` sound. 232 distinct clips on a stock DoD:S install.
- **A cast, not a crowd.** 12 hand-written personas (Allied and German) bound to
  RCBot2 profile slots 1..12. The bot module owns population: it adds bots one at
  a time, in profile order, and renames any bot whose name is not on the voiced
  list onto the persona that is missing — it only kicks when every persona is
  already on the server. Kicks cost a death notice in the kill feed and send
  RCBot2 straight back into its add path, so they are the last resort, not the
  first.
- **Events, not just chat.** Deaths and round starts can trigger a bark, and
  in-game quick-key radio (`C`/`V`/`B`) is captured and answered.
- **Silent when nobody is listening.** With zero human players the plugin stops
  writing events and the daemon refuses to spend a model turn, so an idle server
  full of bots costs nothing. Nothing is queued either: the read cursors keep
  moving, so the first person to join never hears a backlog of stale barks.
  Bot-issued radio callouts are never answered — they used to be, at the cost of
  a model turn each.
- **Text-first protocol.** Two append-only TSV files between plugin and daemon.
  No HTTP, no sockets, no named pipes in the hot path; if the daemon is down the
  game does not care, and if the game restarts the daemon simply resumes.

## Requirements

Everything below is required to run it.

| Thing | Version used | Notes |
|---|---|---|
| Day of Defeat: Source dedicated server | app 232290, build 25338204 | 32-bit binary; on Arch enable `multilib` |
| MetaMod:Source | 1.11+ | the loader SourceMod itself runs under. `addons/metamod.vdf` points at `addons/metamod/bin/server`, and `addons/metamod/metaplugins.ini` lists `addons/sourcemod/bin/sourcemod_mm` |
| SourceMod | 1.12.0-git7255 | hosts the five plugins in `plugin/`; 1.11 crashes on current srcds builds |
| RCBot2 | 2.0-alpha8, 32-bit, build c5b6eb10 | supplies the bots, the console surface the bot module drives (`rcbotd addbot`, `min_bots`/`max_bots`), and the `.rcw` waypoint format the nine maps in `waypoints-final/` (published as `waypoints/`) are written in |
| Python | 3.9 or newer (3.14.7 on the reference box) | daemon and tools; standard library only |
| Linux with systemd | any | developed on Omarchy/Arch, x86-64 |

There is no `requirements.txt`, `pyproject.toml`, or `pip install` step, because
there are no third-party Python packages. The daemon imports only `argparse`,
`hashlib`, `json`, `os`, `random`, `re`, `sqlite3`, `struct`, `sys`,
`threading`, `time`, `urllib.request`, `pathlib`, `http.server`, `collections`
and `dataclasses`; the tools add `shutil`, `socket`, `subprocess`, `tempfile`,
`glob` and `math`, plus their own sibling modules. `sqlite3` needs `libsqlite3`
present (3.53.1 here) — that is an embedded library, not a database server.

Optional, in the sense that it degrades cleanly without them:

| Thing | Effect |
|---|---|
| An OpenAI-compatible `/chat/completions` endpoint (`TWELVEACTORS_API_BASE` / `_API_KEY` / `_MODEL`) | writes the lines. With no model configured the daemon falls back to clip-only barks, so **no API key is needed just to play** |
| `ta_proximity.smx` | distance falloff for barks. `install.sh` compiles it and drops it in `plugins/disabled/` unless you enable it |

Worth stating what is *not* a dependency, since it is easy to assume otherwise:

- **No TTS or audio tooling.** No `ffmpeg`, `sox`, `lame`, no voice model. Clips
  are the `.wav`s the game already ships, read in place out of
  `dod_pak_dir.vpk` by `twelveactors/vpkread.py` and indexed into `clips.sqlite`
  (232 clips on a stock install). Nothing is extracted to disk.
- **No Node, no Docker, no database server, and no separately installed web
  server.** The daemon embeds a standard-library HTTP listener bound to
  `127.0.0.1:8377` — localhost only — and speaks to the plugin through two TSV
  files.
- **No network exposure required.** It runs fine with no public address and no
  port forward.

Build and maintenance tooling, not needed to keep the server running: `curl`,
`tar`, `unzip`, `steamcmd` (install and update the game), the `sqlite3` CLI
(reading `clips.sqlite` or the state DB by hand), and SourceMod's own `spcomp`
plus its `scripting/include/` to rebuild the five `.smx` from the shipped `.sp`.
`install.sh` checks for `spcomp` and refuses to run without it.

## Install

```bash
git clone <this repo> twelveactors && cd twelveactors
sudo TWELVEACTORS_API_BASE=https://api.venice.ai/api/v1 \
     TWELVEACTORS_API_KEY=<your-key> \
     TWELVEACTORS_MODEL=deepseek-v4-flash-0731 \
     ./install.sh
```

Omit the three `TWELVEACTORS_*` variables and the installer asks for them on a
terminal (the key is read with echo off). With no terminal it writes
`<YOUR_API_BASE>` / `<YOUR_API_KEY>` / `<YOUR_MODEL>` and prints the file to
edit, so a botched install cannot look like a working one.

`install.sh` compiles the five plugins, installs the daemon to `/opt/twelveactors`,
writes `config.json`, indexes the voice clips, binds the cast to the RCBot2
profile slots (`twelveactors bootstrap`: profiles, `personas.json`, `voiced.txt`),
pins the RCBot2 config to `min_bots 0` / `max_bots 12`, installs and starts
`twelveactors.service`, and restarts `dods` so the plugins load. It must run as root
and is idempotent — re-running it is the supported way to ship a code change.

Assumptions (override with env vars): game at `/srv/dods`, engine profile `dods`,
12 bots, port 8377.

Manual install, and every step explained, is in **[HERMES-REBUILD.md](HERMES-REBUILD.md)** —
that file is written so an AI agent or a person can rebuild the whole thing from
a bare server.

## Configuration

`/srv/dods/dod/addons/sourcemod/data/twelveactors/config.json` (mode 0600, game user):

```json
{
  "engine": "dods",
  "model": "deepseek-v4-flash-0731",
  "base_url": "https://api.venice.ai/api/v1",
  "api_key": "<your-key>",
  "port": 8377,
  "timeout": 20,
  "dialog_requires_human": true
}
```

`model` and `base_url` are yours to choose: the daemon needs an
OpenAI-compatible `/chat/completions` that returns a JSON object and respects
`max_tokens`. `deepseek-v4-flash-0731` is the recommendation (cheap, ~$0.0002
per measured reply), not a requirement — list your host's `/models` and switch
with `sudo bash install-model-switch.sh <id>`.

`dialog_requires_human` (default `true` when the key is absent) is the daemon
half of the human-presence gate: with nobody in game it refuses to spend a model
turn on ambient events such as a bot death or a round start. The plugin has its
own half, `sm_ta_require_human` (default `1`), which stops events being
written at all. Either one alone is enough to keep an idle server free; both are
on by default, and both must be turned off to get barks with no human present.

To change the model, edit `model` and restart the daemon. `sudo ./install-model-switch.sh <model-id>`
does both from the source tree (defaults to `deepseek-v4-flash-0731`): it backs up
the live `config.json`, rewrites the field in place so owner and mode survive,
restarts `twelveactors.service` and prints `/healthz`. Model ids are those of the
provider's catalogue — with Venice, `curl -s https://api.venice.ai/api/v1/models
-H "Authorization: Bearer $KEY"` lists them. Check any candidate first with one
chat/completions call shaped like `brain.py` sends (JSON object response format,
`max_tokens` 600): a model that lacks JSON mode returns 400 and every line falls
back to the canned clips, and a reasoning model can spend the whole budget
thinking and return empty content.

Bot lines are delivered as team chat: the plugin resolves the persona name in
`out.tsv` to that bot's client and issues `say_team` from it, so the engine
prints the line with the bot's own name and team colour, visible to its team
only, instead of white server text. `sm_ta_team_chat` (default `1`) turns
that off and restores the white `PrintToChatAll` line. The one remaining white
path is a reply whose speaker has left the server between the daemon's write
and the plugin's poll — there is no client, so no team to speak from.

On an already-running server, `sudo ./install-team-chat.sh` ships this one
change without a map change or a `dods` restart: it compiles `twelveactors.sp` with
the server's own `spcomp`, backs up the old `.smx`, installs it, reloads the
plugin over the console FIFO and prints the `team_chat=` state. A fresh
`install.sh` needs no such step — it builds the plugin from this tree.

### Voice: per-bot pitch (core), distance falloff (optional module)

DoD:S ships one male US voice and one male German voice, so every American bot
barks in exactly the same voice. Pitch is carried in the sound packet, not baked
into the file, so a per-bot pitch costs nothing: no new assets, no client
download, no `precache_budget` change. `sm_ta_voice_pitch` (default `1`)
gives each persona a pitch from `data/twelveactors/voices.tsv`:

```
John	97	1.0      # name<TAB>pitch<TAB>gain, gain optional
Paul	103	1.0
```

Rows are matched by name, case-insensitively; a persona with no row gets a pitch
derived from an FNV-1a hash of its name (92–112, the same band as the curated
table), which is stable across
restarts but arbitrary. `config/voices.example.tsv` is the curated table, and
`install.sh` copies it to `data/twelveactors/voices.tsv` only when none exists.
`sm_ta_reload` re-reads it live. `sm_ta_voices` prints the pitch and gain each
connected client is currently assigned.

That is core behaviour and it is the whole of it: with no module loaded every
bark plays to everyone at one volume, exactly as before. Distance falloff is a
separate, optional plugin — `ta_proximity.smx` — because "how loud is a man two
streets away" is a server's taste, not a requirement of the bridge.

The core calls a global forward before it plays anything:

```
Ta_OnBotVoice(speakerId, clip, pitch, gain)   // ET_Hook, 4 params
```

`ta_proximity` implements that public function, sends the clip to each listener
individually at the volume of their own distance, and returns `Plugin_Handled`
so the core does not also emit it. No module, or a module that declines, falls
through to the core's flat playback. The curve it uses:

| distance | volume |
|---|---|
| ≤ 150 u | 1.00 (full) |
| 300 u | 0.86 (−1.3 dB) |
| 450 u | 0.71 (−2.9 dB) |
| 600 u | 0.57 (−4.9 dB) |
| 750 u | 0.43 (−7.4 dB) |
| 900 u | 0.29 (−10.9 dB) |
| 1050 u | 0.14 (−16.9 dB) |
| ≥ 1200 u | not sent |

Its dials are `sm_ta_proximity_enable`, `_near` (150), `_far` (1200), `_minvol`
(0.0 — `far` is silence; raise it for a faint tail), `_team_only` (0, so every
player in the radius hears a bark regardless of team; set it to 1 for the
speaker's own team only, and `sv_alltalk 1` forces everyone either way) and
`_debug` (log every listener's distance and volume). Spectators (team 1) always
hear barks, which is also how the module can be observed from a spec slot.

The module ships compiled but disabled — `plugins/disabled/ta_proximity.smx` —
so a fresh install behaves exactly like the old one. Enable it on a live server,
no map change:

```
sudo ./install-voice.sh --with-proximity
sm_ta_status        # voice pitch=1 proximity_module=loaded tuned=12
sm_ta_prox          # near/far/minvol plus the last bark's listener count
```

`--without-proximity` puts it back and unloads it. `--team-only` restricts audio
to the speaker's own team instead of the default (everyone in range hears it).

The convar default changes nothing on a server that already has
`cfg/sourcemod/ta_proximity.cfg`, because SourceMod writes that file once and
never rewrites it. `install-voice.sh --with-proximity --all-audible` migrates the
one line (`cp` to `.bak.<timestamp>` first, then `sed` the value in place) before
the reload, which is what makes an upgraded server match the new default.

`install-voice.sh` also
recompiles and reloads the core, so it is the upgrade path for a server whose
`twelveactors.smx` predates the pitch work. `sm_ta_voice_pitch 0` turns the
pitch off on its own without touching the module.

Nothing here is generated at reply time — the clips are the stock voice files,
already precached — so both halves add no API cost and no latency.

Who answers, when more than one human is connected: the daemon filters the bot
pool to the asker's own team before choosing a speaker. `say_team` is routed by
the engine, so a bot on the other side would speak into chat that player never
sees — with one human it reads as normal, with two it reads as being ignored.
An addressed name is matched as a whole word, so "frankly" does not address
Frank and "johnny" does not address John; an addressed line always answers, so
substring matches used to change the reply rate for ordinary chat. Spectators
(team 1) have no bots on their team and keep the cross-team pool; a team with no
bots left gets no reply rather than one from the enemy side. This is daemon-only:
`sudo ./install-reply-routing.sh` installs `bridge.py` and restarts
`twelveactors.service` — no plugin build, no map change, no `dods` restart.

Any OpenAI-compatible endpoint works. Persona voices, chat prefix, cooldowns and
per-event behaviour live in `twelveactors/profiles/dods.json`; the cast itself is in
`twelveactors/cards/dods.json`.

### Keeping the bots on topic

Every answered line costs a model turn, and a public server will eventually get
someone asking arithmetic, prices, the news, or what the bots "really" are.
`twelveactors/scope.py` refuses those before any request is made: the reply comes from
the persona's own `refuse` list in `cards/dods.json`, which is three lines per
character in that character's voice, and no token is spent. The system prompt
carries the same rule as a second layer, so a line that slips past the gate is
still declined in character rather than answered.

The gate is deliberately blunt and biased towards answering. Two gates run
before any judgement call, because they are not judgement calls:

* `chars` — printable ASCII only. Cyrillic, CJK, emoji, accents, zero-width
  joiners, right-to-left overrides, full-width look-alikes and control
  characters are refused on sight. A DoD:S player typing English never needs
  them, and they are the usual vehicle for homoglyph evasion aimed at a model.
  Checked against the raw line, before normalisation, so nothing is folded into
  ASCII first; non-ASCII is still stored in the turn log for forensics.
* `injection` — SQL, database and shell grammar (`drop table`, `select … from`,
  `union select`, `' or 1=1`, `pragma`, `sqlite_master`, `$(…)`, and similar).
  The database layer binds every value as a parameter regardless (see
  `tests/test_db.py`, which stores six payloads and checks the schema is
  untouched), so this is defence in depth: an obvious attempt is refused in
  character for nothing instead of being paid for. Round talk that borrows the
  same words still passes — "drop your weapons", "select fire", "update me when
  the flag is up".

A player's *name* is not gated: it comes from the engine, not from a keyboard,
and refusing a person because their Steam name is Cyrillic would cut them off
from the squad. The name is instead flattened on the way in (`clean()` in the
bridge) and neutralised where it enters the prompt (`clean_name()` and
`quote()` in `brain.py`): one line, no control bytes, quotes removed from the
name and escaped in the chat line, so a name or a message can never close the
prompt's quoted slot and add its own instruction. Non-ASCII in a name is kept
through storage and through the reply, so `Иванов` is answered as `Иванов`.

Then the off-topic families, in two tiers, because combat words would otherwise
smuggle bad lines past them ("win" is a game word, and "who will win the
election" used to be answered at cost):

* the unambiguous families are checked first — `math` (including symbolic forms
  like `2(2)=?`, `5*5`), `meta` (AI/model/prompt talk) and `modern` (devices,
  hardware, money, politics, weather, jokes, code) — and refuse outright;
* then any combat word (`ammo`, `medic`, `flag`, `flank`, `cover`, `MG`, `push`,
  …) allows the line, so "how much ammo is left" never trips the price pattern;
* only after that do the ambiguous money words (`cost`, `price`, `money`,
  `expensive`) refuse, which keeps "this cost us the round" in scope;
* finally `length` (over `scope.max_words`, default 30), `oversize` (over 400
  characters, more than the plugin can emit) and `repeat`: the same player
  sending the same line inside `scope.repeat_window_s` (default 45) gets one
  answer, not five. Radio-menu calls are exempt — a deliberate press is always
  new information.

`sanitize()` in the same module is the write-side half: tabs, newlines, C0/C1
controls and runs of space never reach a TSV field, a log line or a column, and
`db.log_turn` caps every field, so a hostile line cannot bloat the table. The
gate runs on the raw line; the sanitised form is what is stored and sent.

Knobs live under `scope` in `profiles/dods.json` (`enabled`, `max_words`,
`repeat_window_s`, `extra_allow` for more combat words). `max_tokens` is 600 and
should stay there: with a reasoning model, a 200-token cap spends the budget
thinking and truncates the JSON mid-string, which costs a fallback bark.

`sudo ./install-scope-filter.sh` installs this against a running server and
restarts the daemon. It copies the whole package, so every gate, the prompt
quoting and the storage sanitiser land together. Before it touches `/opt` it
runs `tools/preflight.py`, which refuses a stale source: five hostile lines
(Cyrillic, emoji, a combining accent, `'; drop table`, oversize) must be refused
for the right reason, three real squad lines must still pass, `sanitize()` must
strip controls, `brain.py` must expose `clean_name`/`quote`/`compose_user`, every
persona must carry three printable-ASCII refusal lines with no duplicates, and
the profile must have a `scope` block. It then runs every `tests/test_*.py` from
the source tree. A tree missing a gate aborts the install with the reason
instead of deploying half of it; after the copy it checks the deployed
`scope.py`, `brain.py`, `bridge.py`, `db.py` and cards against the source by
hash, so a partial `cp` cannot go unnoticed. The same check runs without root:

```bash
python3 tools/preflight.py            # this tree
python3 tools/preflight.py /path/to/tree
```

`python3 tests/test_scope.py` runs the gate's regression
cases (real `in.tsv` lines plus traps), `python3 tests/test_db.py` proves a
stored payload stays data, `python3 tests/test_prompt.py` pins what a
player name can and cannot do to the prompt, and `python3 tests/test_preflight.py`
damages a copy of the tree eight ways to prove the preflight fails loudly rather
than waving a broken gate through. `test_secrets.py` proves the scanner finds a
real key and ignores placeholders, `test_rcon.py` pins argument and password
handling without echoing a secret, and `test_voice.py` pins the core/module voice
split and the cfg migration; all seven ship with the archive.
`/healthz` reports `scope.filtered` and a per-reason
breakdown, and the `turns` table now stores the player's `prompt` and the reply
`source` (`llm`, `filter`, `bark`), so the effect is measurable rather than
assumed: `sqlite3 state.sqlite "select source,count(*) from turns group by 1"`.

## Console commands

| Command | What it does |
|---|---|
| `sm_ta` / `sm_ta_status` | bridge state: clips, bots known, queue, errors |
| `sm_ta_say <text>` | send a line to the daemon as yourself |
| `sm_ta_test <act>` | force a voice act (`ack`, `attack`, `go`, …) |
| `sm_ta_reload` | re-read `clips.txt` and `voices.tsv` after a change |
| `sm_ta_voices` | each client's voice pitch and gain, as resolved right now |
| `sm_ta_prox` | proximity module: dials plus the last bark's listener count |
| `sm_ta_bots` | module state: target, applied, live bot count |
| `sm_ta_bots_reload` | re-read `voiced.txt` |

## Protocol

One event per line, tab-separated, append-only.

```
in.tsv    seq \t say    \t userid \t name \t team \t is_bot \t text
          seq \t death  \t victimid \t victim \t team \t attacker \t weapon
          seq \t radio  \t userid \t name \t team \t menu \t item
          seq \t round  \t 0 \t - \t 0 \t - \t mapname

out.tsv   seq \t speaker \t clip \t text          (empty text = pure bark)
```

The daemon starts reading at the **end** of `in.tsv`, so restarting it never
replays the backlog as a burst of stale barks. On map start the plugin adopts the
highest `seq` in `out.tsv`, so nothing is spoken twice.

## Quick-key radio (C / V / B)

Those keys never produce a `say`; the client sends `voicemenu <menu> <item>` and
the server only draws a HUD line. The plugin hooks `voicemenu` (and the legacy
`voicemenu1/2/3` names) and forwards the raw pair, because DoD:S keeps the label
table in the client binary where the server cannot read it.

Meaning is therefore learned once and cached in `radio_map.json`:

```bash
tools/label_radio.py --list
tools/label_radio.py --set 0:3="you spotted an enemy" --set 0:5="you need backup"
```

Labelled pairs get an in-character answer; unlabelled ones still get an
acknowledgement bark, and every pair seen lands in `radio_seen.tsv`.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Bots have random names (`Raaaaa`, `ramb0`) | RCBot2 picked launcher profiles | module sets `rcbot_nonrandom_profile 1` and renames a stray onto the missing persona; check `sm_ta_bots` |
| Kill feed spams `ERRORNAME committed suicide`, bots respawn every ~10 s | a join-time kill: RCBot2 changes team before it sends the class command, DoD:S spawns the fake client on connect, so the team change kills a live body before clients know its name | `ta_botjoin.smx` keeps teamless fake clients `LIFE_DEAD` until they join a team; stale copies of `ta_bots_rcbot2.smx` that `kickid` strays cause the rest — see `BOT-JOIN-FIX.md` |
| Only 8 of 12 personas appear | blank `team=` / `class=-1` in a profile | `twelveactors bootstrap` repairs slots |
| Bot count drifts | another quota plugin is loaded | `botfill.smx` is moved to `plugins/disabled/` |
| Daemon runs old code after a deploy | unit lacked `PartOf=dods.service` | shipped unit has `Requires=` + `PartOf=` |
| Restart produces a burst of barks | daemon replayed `in.tsv` | fixed: it seeks to end of file |
| No lines at all | daemon down or key missing | `curl localhost:8377/healthz`, `journalctl -u twelveactors` |
| Bots go silent right after a roster change or server restart | a script stopped `twelveactors.service` and the restart path never started it (`rename-bots.sh` did exactly this) | `systemctl is-active twelveactors`; `systemctl start twelveactors`. `rename-bots.sh` now starts it on both paths and traps EXIT so an aborted run cannot leave it down |
| Radio keys do nothing | plugin older than the `voicemenu` hook | recompile and `sm plugins reload twelveactors` |
| Bots say nothing while you are not connected | expected: the human-presence gate is on | `sm_ta_status` shows `humans=0 require_human=1`; set `sm_ta_require_human 0` to disable |
| Bot lines appear as white server text, not team chat | plugin older than the `say_team` delivery, or `sm_ta_team_chat 0`, or the speaker left before the poll | `sm_ta_status` shows `team_chat=1`; engine log shows `"<bot><id><BOT><Axis>" say_team "..."` |
| A second player gets no answer, or an enemy bot answers into your chat | daemon older than the team-scoped reply fix | `grep -c _names_bot /opt/twelveactors/twelveactors/bridge.py` is 0; `sudo ./install-reply-routing.sh` installs it and restarts the daemon |

Logs: `journalctl -u twelveactors -f`, `.../data/twelveactors/` (`in.tsv`, `out.tsv`,
`roster.tsv`, `radio_seen.tsv`), and `sm_ta` in the server console.

## Porting to another Source game

The plugin talks to `twelveactors.sp`'s event hooks, not to DoD:S specifically. To
move it: add `twelveactors/profiles/<engine>.json` and `twelveactors/cards/<engine>.json`,
point `config.json` at the new engine, and check that the game ships a usable
voice bank (the scan reports how many clips it found). Bot control is the only
mod-specific part — `ta_bots_rcbot2.sp` is RCBot2's console surface
(`rcbotd addbot`, `rcbotd config min_bots/max_bots`), and a different bot mod
needs its own small module with the same `voiced.txt` contract.

## Shipping this to another machine

`./tools/make-handoff-zip.sh` rebuilds the distributable and bundles it with the
docs into one file, `~/share/twelveactors-handoff-<date>.zip`: the full tree, the
`.tar.gz`, `START-HERE.md`, the four documents, a manifest and per-file
sha256s. It refuses to build if `tools/check-secrets.py` finds a credential,
and it re-runs the secret scan, preflight and every test suite from the
extracted archive before reporting success. No `state/` and no live
`config.json` are included — the receiver supplies `api_base`, `api_key` and
`model`. `deepseek-v4-flash-0731` is the recommended model; any
OpenAI-compatible id that returns a JSON object and honours `max_tokens` works.

`./tools/make-source-zip.sh` is the other flavour: same guarantees, but it
bundles the **entire working tree** rather than the distributable subset —
every plugin `.sp`, installer, tool, test, card, waypoint set and document,
plus loose copies of the `.md` files at the archive root and a `START-HERE.md`
that states the three values to supply. It drops `__pycache__`, `*.pyc`,
`logs/`, every `*.sqlite*` and `daemon.log`, and rewrites the packaged
`state/config.json` to `<YOUR_API_BASE>` / `<YOUR_API_KEY>` so no endpoint or
key travels with it. Output: `~/share/twelveactors-source-<date>.zip`.

## Licence

MPL-2.0 for Twelve Actors' own code — see [LICENSE](LICENSE). Every source file
carries the two SPDX lines (`SPDX-FileCopyrightText` and
`SPDX-License-Identifier: MPL-2.0`) so a file lifted out of the tree still
travels with its terms. The Mozilla Public License requires the notice in
Exhibit A where practical; the SPDX identifier plus the `LICENSE` file it
points at is the REUSE convention for that notice, and is what we ship.

What MPL-2.0 asks in practice is per-file: run Twelve Actors unmodified on your own
server and you owe nothing beyond the grant. Modify `twelveactors/bridge.py` and
distribute it — in a zip, in a container, on a fork — and that file, with your
changes in Source Code Form, has to go out under MPL-2.0 as well. Files you did
not touch stay yours, and you may combine the result with closed code in a
larger work, which is what makes it workable for plugins hosted inside a
proprietary engine. Running a modified copy as a network service without ever
distributing it triggers no obligation — MPL has no network clause; if that
matters to you, AGPL-3.0 is the licence that covers it, and MPL §3.3 permits
relicensing this code into it.

Voice clips, maps and models stay under Valve's terms; nothing from the game is
redistributed here, the daemon reads the installed VPK at runtime.
