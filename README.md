<div align="center">

# Twelve Actors

**Your bots finally talk back, in character and in their own voices.**

An AI conversation layer for Source-engine bots, built for **Day of Defeat: Source** with SourceMod and RCBot2.
Players type to a bot by name and get an in-character answer in team chat, followed by a real voice line from the game.

![SourceMod 1.12](https://img.shields.io/badge/SourceMod-1.12-d0a24a)
![RCBot2](https://img.shields.io/badge/bots-RCBot2-7fa7d4)
![Python 3.9+, stdlib only](https://img.shields.io/badge/python-3.9%2B%20stdlib%20only-79b47a)
![No GPU, no TTS](https://img.shields.io/badge/GPU%20%2F%20TTS-not%20needed-8b98a5)
![License MPL-2.0](https://img.shields.io/badge/license-MPL--2.0-c98a7a)

[Website](https://twelveactors.com) · [Install](#install) · [Bot fixes](#bot-fixes-for-dods) · [How it works](#how-it-works) · [Rebuild guide](HERMES-REBUILD.md)

</div>

---

```
You (team chat):  Frank, where'd everybody go?
Frank  (team):    Same place the rations went. Stay low and watch the left street.
                  🔊 plus a matching stock DoD:S voice clip, pitched to Frank's voice
```

*Illustrative exchange. Lines are written live by the model from each persona's card.*

## Why it's different

Most "AI NPC" projects need a GPU, a text-to-speech service, voice cloning, or a custom client download. Twelve Actors needs none of these.

| The usual approach | Twelve Actors |
|---|---|
| Generate speech with TTS or voice cloning | **Re-uses the voice clips DoD:S already ships.** The model writes the line and picks the matching stock clip, which plays straight from the game's own `.vpk` (232 clips on a stock install). Nothing is extracted, generated or downloaded. |
| Every bot of a faction sounds identical | **Each persona gets its own pitch.** Pitch travels in the sound packet, so twelve distinct voices cost no new assets, no client downloads and no precache budget. |
| Run a local model on a GPU | **Any OpenAI-compatible API.** The recommended model measured about **$0.0002 per reply**. With no API key at all, bots still bark stock clips. |
| HTTP or sockets inside the game process | **Two plain text files** between the plugin and the daemon. If the daemon goes down, the game never notices. When it comes back, it picks up where it left off. |
| Idle bot servers quietly burn tokens | **Zero cost when nobody is on.** With no humans connected, the plugin stops writing events and the daemon refuses to call the model. |
| Prompt injection and trolls run up the bill | **Off-topic and abusive lines are refused before any request is made.** The refusal comes from the bot itself, in character, and costs nothing. |

## Features

### 🎭 A cast, not a crowd
Twelve hand-written soldiers, six Allied and six German, each with a personality, a voice pitch and their own in-character refusals.

| Allies | | Axis | |
|---|---|---|---|
| **John** | gruff squad leader, dry humour | **Walter** | weary veteran NCO, precise and formal |
| **Paul** | green replacement from Brooklyn | **Herbert** | homesick young conscript, steady under fire |
| **Frank** | sardonic veteran, hates the rations | **Alfred** | cold staff officer who speaks in orders |
| **Donald** | quiet Iowa farm kid, says the hard truth | **Kurt** | cynical Berliner with black humour |
| **Thomas** | calm, practical engineer | **Otto** | methodical MG gunner, obsessed with ammo |
| **Edward** | loud, superstitious, carries a lucky medal | **Rolf** | over-eager raw recruit |

The bot module keeps exactly this cast on the server. Bots are added by name onto the right team, and stray bots are **renamed instead of kicked**, so the kill feed stays clean. Personas are plain JSON: write your own squad without touching code.

### 💬 Conversations that feel like squad chat
- **Address a bot by name** ("Otto, how's the ammo?") and it answers (short per-bot cooldowns keep chat from flooding). Ordinary chat gets an occasional unprompted reply.
- **Replies arrive as real team chat**, sent from the bot itself with its name and team colour. They're visible only to its own team, exactly like a player's.
- **Your own team answers.** With players on both sides, each person hears from their own squad, never from the enemy.
- **Bots remember.** Recent exchanges are stored per bot in SQLite and fed back into the conversation.

### 🔊 Voice without generating audio
- The model chooses an *act* (acknowledge, attack, fall back…), and the daemon picks a matching stock clip for that faction.
- **Per-bot pitch** gives twelve recognisably different voices. You can tune it per persona in `voices.tsv`, or let it derive from the name automatically.
- **Optional distance falloff** (`ta_proximity`): a bark is full volume at arm's length, fades out down the street, and is still directional in stereo.

### 🎖️ Game events, not just chat
- Deaths and round starts can trigger barks.
- A **server-side radio menu** (`sm_ta_radio`) sends orders like "Hold this position!" or "I need ammo!" through the same pipeline, and a squadmate on your team replies.

### 🛡️ Built for public servers
- **Scope gate:** maths, prices, politics, "are you an AI?", code and similar off-topic chat are refused in character before any API call.
- **Injection-hardened:** non-ASCII homoglyph tricks, SQL and shell payloads are refused. Player names are neutralised before they enter the prompt, every database write is parameterised, and every field is sanitised before it touches a file.
- **Measurable:** `/healthz` and the `turns` table show how many replies came from the model, from the filter or from a canned bark.

### 🔧 Fixes for RCBot2 on DoD:S
Three plugins clear up long-standing problems with RCBot2 bots on DoD:S: kill-feed spam, bots being kicked and re-added, and humans pushing bots out. They're described in full under [Bot fixes for DoD:S](#bot-fixes-for-dods), and two of them are worth installing even if you never use the AI side.

### 📦 Light to run
- The daemon is **Python standard library only**: no pip, no Node, no Docker, no database server.
- **One idempotent installer** compiles the plugins, installs the daemon as a systemd service, indexes the clips and binds the cast. Re-running it is the upgrade path.
- **Seven test suites** and a preflight check refuse to deploy a tree with a missing safety gate.

## Bot fixes for DoD:S

RCBot2 is the only bot system for DoD:S, and running it on a public server brings problems most admins have learned to live with. Twelve Actors needed a stable, named roster, so it fixes them at the source. Each fix is a separate SourceMod plugin, and `install.sh` compiles and enables all three.

### 1. No more `ERRORNAME committed suicide` spam: `ta_botjoin`

**The symptom.** Every time a bot joins, the kill feed shows `ERRORNAME committed suicide`, and on a server that refills bots it never stops.

**The cause.** DoD:S spawns a bot's body alive the moment it connects, before it belongs to a team. RCBot2 then moves the bot onto a team before choosing a class, and in DoD:S a team change kills a living player. That death notice goes out before clients have learned the bot's name, so it shows up as `ERRORNAME`. Captured from a live server:

```
SPAWN  Kowalski team=0 bot=1                                   <- alive, no team yet
"Kowalski<408><BOT><Unassigned>" joined team "Allies"
"Kowalski<408><BOT><Allies>" committed suicide with "world"    <- the team change kills it
"Kowalski<408><BOT><Allies>" changed role to "#class_allied_garand"
```

**The fix.** When a bot spawns with no team, the plugin marks it as already dead. The team change then has nothing to kill, and the class pick spawns the bot normally at its team's spawn point. On a test server, filling from 0 to 12 bots produced **zero** suicide lines, and every bot spawned alive.

**Standalone:** yes. It touches only teamless bots, doesn't depend on any other part of Twelve Actors, and can be switched off with `sm_ta_botjoin_enable 0`.

### 2. No more kick/re-add churn: `ta_bots_rcbot2`

**The symptom.** The bot count never settles. Bots are kicked and re-added every few seconds, each kick puts another line in the kill feed, and the scoreboard keeps shuffling.

**The causes.** There were two:
- A fill plugin and RCBot2's own `config.ini` disagreed: one kept 11 bots and the other wanted 12, so a bot was added and kicked on every pass, forever.
- RCBot2's `max_bots` counts **human players too**. With `max_bots 12` and one person connected, RCBot2 refuses to add the twelfth bot and kicks to stay under the cap.

**The fix.** This plugin becomes the only thing that sets the bot count:
- It turns off RCBot2's auto-quota and sets `max_bots` to **target bots + humans currently connected**. It recalculates whenever someone joins or leaves, and re-applies after every config file runs, so `server.cfg` or a map config can't quietly undo it.
- It moves the old `dods_botfill.smx` (the plugin that fought RCBot2) into `plugins/disabled/` during install.
- It adds bots one at a time, by name, onto whichever team is short, which keeps the sides at six and six.
- When a bot appears under a random RCBot2 name like `Raaaaa`, it **renames** the bot onto a missing persona instead of kicking it. A kick costs a kill-feed line and sends RCBot2 straight back to adding a bot. It only kicks when every persona is already in use.
- It ignores humans who happen to use a persona's name, so a player called "John" can't trigger a bot kick every 10 seconds.
- It writes to RCBot2's settings only when something has changed, plus a periodic re-check, instead of every pass. That keeps the server log from filling with roughly 17,000 lines a day.

**Standalone:** mostly. Without the cast list (`voiced.txt`) it skips all naming and simply holds a steady bot count. Check it live with `sm_ta_bots`.

### 3. Humans can't push the bots out: `ta_humancap`

**The symptom.** On a busy night, players fill every slot, the bots get pushed off the server, and whatever manages bot numbers fights the engine for the last free slot.

**The fix.** Human connections are capped (`sm_ta_humancap`, which the installer sets to the bot target, 12 by default). Anyone past the cap is turned away at connect time with a clear message, for example *"Server full: 12 human slots, 12 reserved for bots."* Bots and SourceTV are never counted or blocked. Set it to `0` to turn the cap off.

**Standalone:** yes. It's useful on any server that wants guaranteed bot slots.

## How it works

```
 player chat  ──┐
 radio menu   ──┤   SourceMod plugin        append-only TSV        Python daemon
 deaths/rounds──┴──►  twelveactors.sp ──►   in.tsv      ──►   twelveactors/bridge.py
                      ta_bots_rcbot2.sp                       ├─ scope gate (no-cost refusals)
                      ta_botjoin.sp  (no team-change death)   ├─ personas + memory (sqlite)
                                                              ├─ LLM (any OpenAI-compatible API)
                                                              └─ voice clip picker (stock .vpk)
                                        out.tsv  ◄──  clip + chat line
                                           │
                      twelveactors.sp: say_team from the bot + pitched voice clip
```

The design is engine-shaped, not mod-shaped. HL2:DM, CS:S and TF2 expose the same hooks, so porting means a new persona card and profile, plus a small bot module if the game uses different bots. See [Porting](#porting-to-another-source-game).

## Components

### Required

| Component | What it's for | Notes |
|---|---|---|
| **Day of Defeat: Source dedicated server** on Linux | the game | needs root and systemd; the installer assumes `/srv/dods` (override with env vars) |
| **MetaMod:Source** 1.11+ | loads SourceMod | |
| **SourceMod** 1.12 | runs the plugins | 1.11 crashes on current server builds. Its compiler (`spcomp`) is needed at install time |
| **RCBot2** | supplies the bots | build must match your server's bitness (the reference server is 32-bit) |
| **RCBot2 waypoints** for each map you run | let bots navigate | not shipped here; see [Credits](#credits) for where to get them |
| **Python** 3.9+ | runs the daemon | standard library only, no `pip install` |
| `twelveactors.smx` | core plugin: sends events out, plays lines and voice clips | |
| `ta_bots_rcbot2.smx` | keeps the twelve-persona cast on the server | without it bots still talk, but with whatever names RCBot2 gives them |
| `twelveactors.service` | the daemon: personas, memory, scope gate, AI calls, clip picking | without it bots stay silent |

### Optional

| Component | What it adds | Without it | Default |
|---|---|---|---|
| **OpenAI-compatible API key** | bots write typed replies in character | bots still play stock voice clips | asked for at install |
| `ta_botjoin.smx` | stops the `ERRORNAME committed suicide` spam | RCBot2's join-time deaths show in the kill feed | **on** |
| `ta_humancap.smx` | reserves slots so humans can't push the bots out | a full server can push bots off | **on**, capped at 12 |
| `ta_proximity.smx` | bot barks fade with distance | every bark plays at one volume to everyone | off (`install-voice.sh --with-proximity`) |
| `voices.tsv` | hand-tuned pitch and volume per persona | pitch is derived from each bot's name | example table copied at install |
| `radio_map.json` | labels quick-key radio picks so they get real replies | unlabelled picks may get an acknowledgement bark instead | empty |
| `steamcmd`, `sqlite3` CLI | updating the game; inspecting the databases by hand | | maintenance only |

Exact versions and further detail are under [Requirements](#requirements).

Quick-key note: DoD:S's own C/V/B radio picks may not reach the server on every client build, so the reliable path is the server-side `sm_ta_radio` menu. See [Quick-key radio](#quick-key-radio-c--v--b).

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
every plugin `.sp`, installer, tool, test, card and document,
plus loose copies of the `.md` files at the archive root and a `START-HERE.md`
that states the three values to supply. It drops `__pycache__`, `*.pyc`,
`logs/`, every `*.sqlite*` and `daemon.log`, and rewrites the packaged
`state/config.json` to `<YOUR_API_BASE>` / `<YOUR_API_KEY>` so no endpoint or
key travels with it. Output: `~/share/twelveactors-source-<date>.zip`.

## Credits

Twelve Actors supplies dialogue. It supplies no bots, and it supplies no
waypoints. Both come from **RCBot2**, which is a separate project under a
separate licence, maintained by other people.

**RCBot2** — [APGRoboCop/rcbot2](https://github.com/APGRoboCop/rcbot2),
**AGPL-3.0**. Founded by **Cheeseh**; current maintenance, Linux conversion and
DoD:S waypointing by **[APG]RoboCop[CL]**; with contributions from Ducky1231 /
Pongo, nosoop, Anonymous Player / caxanga334, Technochips, RussiaTails, Sappho,
Soft As Hell, and **DNA.styx** for the DoD:S and main config fixes. Bot base from
Botman's HPB Template. Install it yourself, from its own repository, under its
own terms.

**The waypoints**, without which the bots cannot navigate a map at all, are
hand-made and are *not* part of RCBot2's repository — RCBot2's own README
directs you to `rcbot.bots-united.com/waypoints.php`. The nine DoD:S sets this
project was developed against name **Cheeseh**, **[APG]RoboCop[CL]**,
**genmac** and **LQ777** in their own file headers.

> **That distribution site is offline** (checked 21 October 2026). The only
> copies now reachable are Wayback Machine snapshots, e.g.
> [this one from November 2024](https://web.archive.org/web/20241104011324/rcbot.bots-united.com/waypoints.php).
> Across every snapshot going back years — the address predates Day of Defeat:
> Source itself, so the earliest ones are for the original Half-Life mod —
> **no licence or terms of use are stated anywhere on the page.**
>
> That is why no waypoints are shipped here. Files whose authors are named in
> their own headers, offered under no stated terms, are not ours to modify and
> redistribute — and the official source going offline raises the obligation to
> credit those authors rather than lowering it, because for some installers a
> third-party copy would be the only one left. If you need waypoints, take them
> from the archive link above and treat them as the work of the four people
> named, not as part of this project.

> **Removed 21 October 2026.** Earlier versions of this repository shipped 26
> modified `.rcw` waypoint files in `waypoints-final/`, `waypoints-improved/` and
> `waypoints-v2/`, together with tooling that implemented RCBot2's binary
> waypoint format. They were the work of the four people named above,
> redistributed with no attribution and under no grant — these files arrive from
> a download page under no stated terms, so unlike RCBot2's own code there was
> never a licence permitting modification or redistribution. All of it has been
> deleted. The 52 flag corrections that tooling produced are being offered
> upstream to those authors instead, where they help every RCBot2 server rather
> than one. Git history and any release built before that date still contain the
> files.

Get your waypoints from the link above, as RCBot2 intends.

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
matters to you, AGPL-3.0 is the licence that covers that case.

### §3.3, and the SourceMod plugins

An earlier version of this section said MPL §3.3 "permits relicensing this code
into" AGPL-3.0. That is not what the clause does, and the error mattered because
§3.3 is the answer to a question this project actually has.

§3.3 does not relicense MPL files. It permits a **Larger Work** that combines
MPL-covered files with GPL-family code to be distributed under that Secondary
License (GPL-2.0+, LGPL-2.1+ or AGPL-3.0), provided the MPL files carry no
"Incompatible With Secondary Licenses" notice. The MPL files remain MPL; what
the clause governs is the terms of the combination.

Which is exactly the situation of the server plugins. **SourceMod is
GPL-3.0**, and `plugin/*.sp` each `#include <sourcemod>` and mostly
`#include <sdktools>` at compile time — so the compiled `.smx` is a combination,
not merely a file loaded by a host, and AlliedModders publish the position that
plugins are derivative works which must be GPL-compatible
(<https://sm.alliedmods.net/license.php>).

MPL-2.0 was designed to be compatible here; it just has to be said out loud. So:

> **Every SourceMod plugin in `plugin/` is offered under MPL-2.0 OR
> GPL-3.0-or-later, at your option** — `twelveactors.sp`, `ta_bots_rcbot2.sp`,
> `ta_botjoin.sp`, `ta_botjoin_experimental.sp`, `ta_cmdspy.sp`,
> `ta_humancap.sp` and `ta_proximity.sp`. Each carries that SPDX identifier and
> none carries the "Incompatible With Secondary Licenses" notice, so §3.3
> applies and a GPL-3.0 distribution of the compiled plugin is permitted.

The client-side parts never touch SourceMod, so this does not reach them. That
containment is the point of keeping the parts separate in the first place.

### What sits beside this, and under what terms

| | Licence | Relationship |
|---|---|---|
| **SourceMod** | GPL-3.0 | Compiles the plugins and loads them; see §3.3 above |
| **RCBot2** | **AGPL-3.0** | Supplies the bots. Separately installed by the operator, from its own repository. Nothing of its code is copied, included, linked or called; no file of its is written. See **Credits** above |
| **RCBot2 waypoints** | **no stated terms** | Not in RCBot2's repository and not covered by its AGPL grant. Download them yourself; none are redistributed here |
| Voice clips, maps, models | Valve's terms | Nothing from the game is redistributed; the daemon reads the installed VPK at runtime |

**AGPL-3.0 §13 and this server.** RCBot2's network clause is triggered by running
a *modified* RCBot2 where users interact with it over a network — which a game
server plainly is. Running RCBot2 **unmodified** alongside Twelve Actors triggers
nothing, and nothing in this repository modifies it: every interaction is a
command string handed to Valve's console or a query to Valve's cvar registry. If
you do patch RCBot2, that obligation is yours and it does not reach these files.

*Not legal advice.*
