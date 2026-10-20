# Rebuilding Twelve Actors on another Hermes

This is the operator's file: everything needed to stand the whole thing up from a
bare Linux box, plus the reasoning and the failures that shaped it. Read it top to
bottom the first time; after that it doubles as the runbook.

`TWELVEACTORS-HANDOFF.md` is the dated change log and the short path — read its
section 0 first if you are an agent, and section 9 for failure modes added since
this file was written. The model in both files is `deepseek-v4-flash-0731`.

If you are an AI agent doing the rebuild, the last section is a prompt you can be
handed verbatim. Do not skip Phase 8 — every failure below was silent until a
check was run.

---

## 0. What you are building

A Day of Defeat: Source server whose bots are characters rather than strangers:

- SourceMod plugin captures chat, deaths, round starts and quick-key radio into
  an append-only TSV.
- A Python daemon reads that file, picks a persona, asks an OpenAI-compatible LLM
  for one short line, matches the *intent* of the line to a clip from the game's
  own voice bank, and appends `clip + text` to a second TSV.
- The plugin plays that clip on that bot and optionally prints the text.

The hard constraint that shapes everything: **no text-to-speech**. Voiced output
is 232 pre-recorded DoD:S clips, chosen by intent. A line that cannot be matched
to a clip is printed, not spoken.

### Verified reference environment

| Component | Value |
|---|---|
| OS | Omarchy (Arch), x86-64, Intel N97, 4 GB RAM, no GPU |
| Game | DoD:S dedicated server, app 232290, 32-bit (`multilib` required) |
| SourceMod | 1.12.0-git7255, metamod via `metaplugins.ini` |
| RCBot2 | 2.0-alpha8 32-bit, build c5b6eb10, 5,706 waypoints |
| Python | 3.9+ (3.14.7 on the reference box), standard library only |
| Game root | `/srv/dods`, service `dods.service`, user/group `dod` |
| Data dir | `/srv/dods/dod/addons/sourcemod/data/twelveactors` (0750, `dod:dod`) |
| Daemon | `/opt/twelveactors`, service `twelveactors.service` |

Nothing here needs a GPU, a database server, or a public address. 4 GB is enough
for a 12-bot server plus the daemon.

### Repository layout

```
twelveactors/                  the daemon package (python -m twelveactors)
  __main__.py             CLI: scan | serve | say | selftest | bootstrap
  bridge.py               TSV tailer, event handlers, reply shipping
  brain.py                prompt building + model call
  voicebank.py            clip index, intent matching
  vpkread.py              read-only VPK v1 reader (no extraction)
  db.py                   sqlite: personae, memory, turn log
  cards/dods.json         the cast (name, team, voice brief)
  profiles/dods.json      engine profile: events, acts, cooldowns, paths
plugin/twelveactors.sp                 bridge, chat/death/round/voicemenu hooks
plugin/ta_bots_rcbot2.sp     bot population module
plugin/ta_humancap.sp            caps humans so the 12 bot slots always fit
plugin/ta_botjoin.sp             keeps teamless fake clients dead (no join suicide)
systemd/twelveactors.service
config/config.example.json
tools/label_radio.py
install.sh                one-shot installer
make-dist.sh              build the distributable (.tar.gz/.zip)
```

---

## 1. Operating system

Arch/Omarchy is assumed. Any systemd distro works if it has 32-bit runtime
libraries; on Arch that means:

```bash
sudo pacman -S --needed base-devel lib32-glibc lib32-libstdc++5 lib32-gcc-libs \
    lib32-libx11 lib32-alsa-lib steamcmd python
```

Create the game user once; the server never runs as root:

```bash
sudo useradd -r -m -d /var/lib/dods -s /bin/bash dod
```

`HOME=/var/lib/dods` matters: Steam client libraries and the steamcmd cache live
there, and srcds writes `~/.steam` on first run.

---

## 2. Game server

```bash
sudo -u dod mkdir -p /srv/dods
sudo -u dod steamcmd +force_install_dir /srv/dods +login anonymous \
    +app_update 232290 validate +quit
```

`app_update` twice is not superstition — the first pass frequently leaves the
server binaries one revision behind.

**No Game Server Login Token.** Anonymous logon works, but it is throttled during
busy hours and the server will not appear in the public browser reliably. For a
public server, generate a token at steamcommunity.com/dev/managegameservers and
pass `+sv_setsteamaccount <token>` in the launch line. For LAN play, ignore it.

### systemd unit (`/etc/systemd/system/dods.service`)

The console is a FIFO, which is what makes `rcon` unnecessary for administration:

```ini
[Unit]
Description=Day of Defeat: Source dedicated server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=dod
Group=dod
Environment=HOME=/var/lib/dods SHELL=/bin/bash
WorkingDirectory=/srv/dods
RuntimeDirectory=dods
RuntimeDirectoryMode=0755
ExecStartPre=/bin/sh -c 'test -p /run/dods/console || mkfifo -m 600 /run/dods/console'
ExecStart=/bin/sh -c 'exec 3<>/run/dods/console; exec /usr/bin/script -qfc "/srv/dods/srcds_run -game dod -console -norestart -port 27015 +maxplayers 24 +map dod_anzio +exec server.cfg" /dev/null <&3'
Restart=always
RestartSec=15
KillSignal=SIGINT
KillMode=mixed
TimeoutStopSec=25

[Install]
WantedBy=multi-user.target
```

Two details learned the hard way: srcds ignores `SIGTERM` badly, so `KillSignal=SIGINT`;
and `script -qfc` keeps srcds believing it owns a terminal, which it requires for
console input.

---

## 3. SourceMod and RCBot2

Download SourceMod **1.12** (1.11 crashes on current srcds builds) and RCBot2
**2.0-alpha8 32-bit** — the 64-bit build does not load in a 32-bit srcds.

```bash
cd /tmp
curl -LO <sourcemod-1.12-linux.tar.gz>
sudo tar xzf sourcemod-1.12-linux.tar.gz -C /srv/dods/dod
sudo curl -L <rcbot2-linux-32.tar.gz> | sudo tar xz -C /srv/dods/dod
sudo chown -R dod:dod /srv/dods/dod/addons
```

Enable Metamod's plugin list explicitly — `metaplugins.ini` is honoured when
`metamod.vdf` loads:

```
/srv/dods/dod/addons/metamod/metaplugins.ini
  addons/sourcemod/bin/sourcemod_mm
```

Verify from the console (`/usr/local/bin/dods-console`, a FIFO wrapper):

```
meta list          → 1 plugin  sourcemod
sm version         → SourceMod 1.12.0-git7255
sm exts list       → metamod + sdkhooks …
rcon bot_quota 12  → "Unknown command" is expected (RCBot2 uses its own cvars)
```

RCBot2 installs into `addons/rcbot2/` with `bin/rcbot.2.dods.so`, `config/`,
`profiles/`, `waypoints/`. Its config is a **console script**, not key=value:

```
addons/rcbot2/config/config.ini
  rcbotd config min_bots 0
  rcbotd config max_bots 12
  rcbot_nonrandom_profile 1
```

`min_bots` must be `0`: RCBot2 rejects a config where `max_bots <= min_bots`, and
its own quota fights the module described in Phase 7.

---

## 4. Voice bank

The daemon never copies audio out of the game. `vpkread.py` opens
`dod_pak_dir.vpk` read-only and indexes entries like
`sound/player/american/us_yessir.wav`, so a scan is cheap and repeatable:

```bash
sudo -u dod PYTHONPATH=/opt/twelveactors python3 -m twelveactors \
    --data /srv/dods/dod/addons/sourcemod/data/twelveactors scan
```

Outputs `clips.sqlite` (path, faction, phrase guess) and `clips.txt`. Reference
run: **232 clips** (Allied + German `player/` lines). If the count is near zero,
the VPK path in `profiles/dods.json` is wrong or the file is one of Valve's
multi-part archives (pass the `_dir.vpk`).

Clips carry no meaning in their filename beyond the phrase slug
(`us_wegothim2.wav` → "we got him"), which is exactly what the matcher uses:
the model's line is embedded and compared to those slugs. That is why lines must
stay short — a spoken line is a few words, not a sentence.

---

## 5. The cast

`twelveactors/cards/dods.json` holds both factions:

```json
{"id": "kowalski", "name": "Sgt. Kowalski", "team": 2,
 "voice": "gruff squad leader, 12 years in the army, sparing with words, dry humour, protective of his men",
 "short": "Kowalski"}
```

Teams are DoD:S numbering: `2` Allied, `3` German. Twelve personas total, six per
side. `voice` is a brief for the model, not a style descriptor for TTS — it has to
constrain *content*, because the voice itself is the game's.

---

## 6. The daemon

```bash
sudo mkdir -p /opt/twelveactors
sudo cp -r twelveactors /opt/twelveactors/
sudo chown -R root:root /opt/twelveactors && sudo chmod -R u=rwX,go=rX /opt/twelveactors
```

`/srv/dods/dod/addons/sourcemod/data/twelveactors/config.json` (0600, `dod:dod`):

```json
{"engine": "dods", "model": "<YOUR_MODEL>",
 "base_url": "<YOUR_API_BASE>", "api_key": "<YOUR_API_KEY>",
 "port": 8377, "timeout": 20}
```

Pick any OpenAI-compatible endpoint and model: the daemon only needs
`/chat/completions`, JSON output and an honoured `max_tokens`. Recommended:
`deepseek-v4-flash-0731` (cheap, measured ~$0.0002 per reply) — not required.

### Unit (`/etc/systemd/system/twelveactors.service`)

The two lines that cause the most confusion are `Requires=` and `PartOf=`:

```ini
[Unit]
Description=Twelve Actors NPC conversation daemon (Day of Defeat: Source)
After=network-online.target dods.service
Requires=dods.service
PartOf=dods.service
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

Without `PartOf=dods.service`, `systemctl restart dods` leaves the daemon running
the previous build of the code — you deploy a fix and nothing changes. That is
documented in Phase 9 because it burned a full debugging session.

### Model-call gotchas (Venice and other OpenAI-compatible hosts)

- Set an explicit `max_tokens` in the request (the daemon does). Hosts that
  default to 65536 return HTTP 400 for models with a lower output cap.
- Chat-completion model IDs are literal in scripts; Hermes `/model` aliases are
  a CLI convenience only. Do not put an alias in `config.json`.
- A 20 s timeout is generous for a 1–2 sentence reply and keeps a hung request
  from stalling the bridge.

### Human-presence gate (resource saving)

Barks are gated on a human being in game, because on an idle server the only
listeners are bots and every death/round event would otherwise cost a model
call. Two independent halves, either one sufficient:

- **Plugin** (`twelveactors.sp`): `sm_ta_require_human` (default `1`). `Emit()`
  refuses to write `in.tsv` when `CountHumans() == 0` — human = in game, not
  fake, not SourceTV — and `Timer_Poll` keeps advancing `last_out` without
  printing or playing, so nothing queued while empty is replayed later.
- **Daemon** (`bridge.py`): `dialog_requires_human` in `config.json` (default
  true). `_event_allowed()` drops ambient events unless `roster.tsv` lists a
  human. A `say`/`radio`/`voice` from a name that is not on the bot roster is
  its own proof of a human and is allowed regardless: `roster.tsv` is a 3 s
  snapshot, so a player who joins and immediately asks for ammo must not be
  dropped as stale.

- **Bot callouts are never answered.** RCBot2 bots press the same radio
  commands the player does; `in.tsv` held 341 `voice_grenade` events per name
  per map. The plugin no longer records a fake client's `voice_*`/`voicemenu`,
  and `bridge.py` refuses a radio/voice event whose sender is on the bot
  roster. Both are needed: the plugin check covers new events, the daemon check
  covers a roster that has not caught up yet.

Verify: with no human connected, `curl -s localhost:8377/healthz` shows
`"humans":0,"dialog_open":false` and the `gated` counter climbing while `out`
stays put; `sm_ta_status` in console shows `humans=0 require_human=1 gated=N`
and `in.tsv` stops growing. Join, and both numbers move within one roster tick.

### Delivery: team chat, not white server text

Bot lines are said by the bot, not printed by the plugin. `Timer_Poll` in
`twelveactors.sp` resolves the persona name from `out.tsv` to a client index
(`FindSpeaker`, case-insensitive, in game, not SourceTV) and calls
`FakeClientCommand(client, "say_team %s", text)`. The engine then formats the
line as that client's team chat: bot name, team colour, team-only visibility.
`SaySafe()` strips `"` and `;` first, because the text goes through the client
command parser, where a quote ends the argument and a semicolon starts a new
command.

`sm_ta_team_chat` (default `1`) reverts to the old `PrintToChatAll` white
line when set to `0`. The fallback path is also white: a reply whose speaker is
no longer in game has no client, so there is no team to speak from. The voice
clip is unaffected — it is still the `player/<faction>/...` clip for the bot's
team and still plays for everyone, so `say_team` changes the text channel only.

Verified on the throwaway server (port 27016, RCBot2): a line for `Weiss` on
Axis produced `"Weiss<11><BOT><Axis>" say_team "Testing team chat from Weiss."`
in the engine log, which is the same line a human's team chat writes.

`install-team-chat.sh` installs it; `sm_ta_status` reports `team_chat=1`.

### Playback voice: per-bot pitch in the core, distance in a module

`PlayBark` (`twelveactors.sp`) resolves the persona's pitch and gain before playing
anything. The pitch comes from `data/twelveactors/voices.tsv` (`John<TAB>97<TAB>1.0`)
or, for a persona with no row, from an FNV-1a hash of the name into 92–112, so
a cast is distinguishable with no new assets and no client download. Pitch is a
field in the sound packet, not a property of the `.wav`. `sm_ta_voice_pitch
0` disables it, `sm_ta_reload` re-reads the table, `sm_ta_voices` prints what
each client currently gets.

Distance is not in the core. `ta_proximity.sp` is a separate optional plugin:
the core creates the global forward `Ta_OnBotVoice(speakerId, clip, pitch,
gain)` (ET_Hook, four params) in `AskPluginLoad2` and calls it before its own
`EmitSoundToAll`; a plugin defining that public function returns
`Plugin_Handled` and takes over playback, emitting the clip per listener at the
volume of that listener's distance. No module means the old flat broadcast,
unchanged. The module ships compiled but parked in `plugins/disabled/`;
`install-voice.sh --with-proximity` enables it, `--without-proximity` removes
it, and both paths reload the core first so the forward is current.

`tests/test_voice.py` pins this split: the core must not contain
`GetVectorDistance`, the module must implement the exact signature, and both
must compile. Do not "simplify" by folding the falloff back into the core — the
whole point is that a server can decline it.

---

## 7. Bot population module

`ta_bots_rcbot2.sp` exists because RCBot2's quota behaves badly with a fixed
cast. Its contract:

1. Write `voiced.txt` — one persona name per line (`twelveactors bootstrap` does it).
2. Own `rcbotd config min_bots 0` and `max_bots <target + humans>`. `max_bots` is
   a *total client* cap, humans included, so writing the bare bot target strangles
   the roster the moment someone joins. The module re-asserts the pair after every
   config exec (`OnConfigsExecuted`, so `server.cfg`, per-map configs and
   `config.ini` cannot leave a stale cap), whenever the computed number changes
   (a human joins or leaves), and once every 12 supervisor passes as drift
   correction. It does not write every pass: RCBot2 logs both values on every
   accepted write, which would be ~2 journal lines every 10 seconds.
3. Force `rcbot_nonrandom_profile 1` so `rcbotd addbot` consumes profiles in order.
4. Every few seconds: if live personas < target, `addbot`; if a bot's name is not
   on `voiced.txt` (or two bots wear the same persona, which happens when RCBot2
   loses track of a profile), rename one onto a free persona instead of kicking
   it; only kick when every persona is already taken, or when the roster is over
   target. A kick broadcasts a death notice and puts RCBot2 straight back into its
   add path, so kicks are the expensive option.

Consequence: the population is the cast. Random launcher profiles (`Raaaaa`,
`ramb0`) cannot survive a tick.

### Slot budget

`+maxplayers 24` is the whole server. `ta_humancap.sp` splits it: humans are
capped at `sm_ta_humancap` (default 12) and the remaining 12 slots belong to the
cast, so a 13th human is refused at connect instead of displacing a bot:

```
Server full: 12 human slots, 12 reserved for bots.
```

The cap is checked in `OnClientConnect`, which runs before the client is put in
server — no kick, no join/part churn, and fake clients (bots, SourceTV, Replay)
are never counted. Capping humans is deliberate: kicking a bot to make room
broadcasts a death notice and sends RCBot2 straight back into its add path, which
is the churn the module exists to stop.

Verify the three numbers agree after any change:

```
sm_ta_humancap        -> 12
sm_ta_bots            -> target=12 applied=13 bots=12   (applied = target + humans)
status                 -> 12 bots + humans, 24 max
```

Population is not the only way a bot dies at join time. `ta_botjoin.sp` is a
separate two-hundred-line plugin for that: RCBot2 changes a bot's team *before*
it sends the class command, and DoD:S spawns the fake client on connect, so the
team change kills a live, classless body. Clients get that death notice before
they learn the bot's name and render it as `ERRORNAME committed suicide`. The
plugin holds any fake client still in team 0 in `LIFE_DEAD` after its connect
spawn, so the team change has nothing to kill; the class command then spawns the
bot normally at its team spawn. Hook `player_spawn`, not `OnClientPutInServer`:
killing the body earlier (or setting the desired class, or re-checking lifeState
on a timer) still produced the suicide.

### Profiles

`/srv/dods/dod/addons/rcbot2/profiles/1.ini` … `12.ini`, one persona each:

```ini
name=Kowalski
team=2
class=0
skill=3
```

Rules that are not obvious:

- `name=` is mandatory; without it the slot keeps the launcher's random name.
- `class=0` means auto. A literal `class=-1` makes RCBot2 skip the profile
  silently — the bot never appears and nothing is logged.
- Do **not** add `model=`; the parser accepts it but the field shifts later keys.
- Blank `team=` is legal-but-useless: the profile loads only for the smaller side.

`twelveactors bootstrap --bots 12` rewrites all of this from the cards, writes
`voiced.txt`, and repairs blank `team=`/`class=-1` left by a previous install. Run
it after any card change.

---

## 8. Plugins

```bash
cd plugin
INC="-i /srv/dods/dod/addons/sourcemod/scripting/include"
/srv/dods/dod/addons/sourcemod/scripting/spcomp $INC -o /tmp/twelveactors.smx twelveactors.sp
/srv/dods/dod/addons/sourcemod/scripting/spcomp $INC -o /tmp/ta_bots_rcbot2.smx ta_bots_rcbot2.sp
/srv/dods/dod/addons/sourcemod/scripting/spcomp $INC -o /tmp/ta_humancap.smx ta_humancap.sp
/srv/dods/dod/addons/sourcemod/scripting/spcomp $INC -o /tmp/ta_botjoin.smx ta_botjoin.sp
/srv/dods/dod/addons/sourcemod/scripting/spcomp $INC -o /tmp/ta_proximity.smx ta_proximity.sp
sudo install -m 0644 /tmp/twelveactors.smx /tmp/ta_bots_rcbot2.smx /tmp/ta_humancap.smx /tmp/ta_botjoin.smx \
  /srv/dods/dod/addons/sourcemod/plugins/
# Optional module: keep it out of the load path until asked for.
sudo install -m 0644 /tmp/ta_proximity.smx /srv/dods/dod/addons/sourcemod/plugins/disabled/
sudo install -m 0644 *.sp /srv/dods/dod/addons/sourcemod/scripting/
sudo systemctl restart dods twelveactors
```

`socket`-style includes are not needed; everything used is in stock SourceMod.
If `spcomp` prints nothing, it still wrote the file — check the timestamp.

Retire any other population plugin (`botfill.smx`, `dods_botfill.smx`) by moving
it to `plugins/disabled/`. Two quota managers produce rosters that look random.

---

## 9. Verification ladder

Run these in order; each one isolates a layer. Expected values from the reference
box in brackets.

```bash
# 1. server up, 12 bots, roster matches the cast
systemctl is-active dods                                  # active
/usr/local/bin/dods-console status | head -20
/usr/local/bin/dods-console "rcon sm_ta_bots"            # target=12 bots=12

# 2. daemon alive and healthy
curl -s localhost:8377/healthz
# {"ok":true,"clips":232,"bots_known":12,"turns":150,"engine":"dods",
#  "model":"deepseek-v4-flash-0731","bridge":{"in":1,"out":0,"skipped":0,
#  "errors":0,"gated":0},"roster":12,"humans":1,"dialog_open":true,"errors":[]}
#  bots_known must be 12 — it is read from roster.tsv, written by the plugin;
#  humans=0 with dialog_open=false is the gate working, not a fault

# 3. one turn, no game needed
sudo -u dod PYTHONPATH=/opt/twelveactors python3 -m twelveactors \
    --data /srv/dods/dod/addons/sourcemod/data/twelveactors selftest
# checks clip index, model call and voice pick; prints the chosen clip

# 4. one turn through the game
/usr/local/bin/dods-console 'rcon sm_ta_say "Miller you hear that tank?"'
tail -3 /srv/dods/dod/addons/sourcemod/data/twelveactors/out.tsv
# <seq>  Miller  player/american/us_yessim.wav  ...
#    a human must be connected: sm_ta_say is gated like every other event.
#    For a headless test use `sm_ta_require_human 0` first.

# 5. quick keys
#    join, press C then choose an item; then:
sudo tools/label_radio.py --list        # shows menu:item pairs seen
```

If step 2 shows `bots_known: 0` while bots are in game, the plugin is writing
`in.tsv` but not `roster.tsv` — the plugin and daemon builds are mismatched.

---

## 10. Failure modes, with the actual cause

| Symptom | Root cause | Fix |
|---|---|---|
| Daemon ignores new events after a deploy | unit had `After=dods.service` only; restart of dods never touched the daemon | `Requires=` + `PartOf=` in the unit |
| Bots stop replying after a roster change, no errors anywhere | `rename-bots.sh` stopped `twelveactors.service` and its `--restart` path never started it; the plugin kept writing `in.tsv`, `last_out` froze | `systemctl start twelveactors`; the script now starts it after the branch and traps EXIT |
| Restart fires a burst of barks | bridge replayed `in.tsv` from offset 0 | seek to end of file on start |
| 8 of 12 personas in, 4 missing | profiles had `team=` empty and `class=-1` | `twelveactors bootstrap` rewrites them; module renames strays onto the missing persona |
| Random-named bots appear | `max_bots` 24 > personas 12, `rcbot_nonrandom_profile 0` | `max_bots` = personas + humans, nonrandom 1, rename-not-kick |
| Kill feed spams `ERRORNAME committed suicide` and bots rejoin every ~10 s | team change killed a live classless body (RCBot2 sets team before class; DoD:S spawns on connect) | load `ta_botjoin.smx`; update the bot module so strays are renamed, not kicked |
| Bots never spawn | RCBot2 rejected `min_bots` ≥ `max_bots` | `min_bots 0`, module adds one at a time |
| Radio keys silent | client sends `voicemenu`, never `say` | `AddCommandListener("voicemenu")`, not `OnClientSayCommand` |
| Radio answers are generic | `radio_map.json` empty — labels live in the client binary | label pairs with `tools/label_radio.py` |
| `scan` finds 0 clips | pointed at the split VPK, not `dod_pak_dir.vpk` | pass the `_dir.vpk` |
| LLM 400 with `max_tokens` | host default 65536 > model cap | explicit `max_tokens` in the request |
| Chat line printed, no voice | no clip matched the intent | shorten the line; the matcher works on a small bank |

---

## 11. What is deliberately unfinished

- **Radio labels.** `radio_seen.tsv` fills as humans press keys; a human (or an
  agent reading the DoD:S menu screenshots) still has to name each pair once.
  Until then every call gets an acknowledgement bark rather than a specific answer.
- **One engine.** `cards/` and `profiles/` carry a `dods` profile. TF2's voice
  bank is far larger and its bot mod is different; that is a port, not a config
  change.
- **Memory is per-bot and short.** Personae have a sqlite memory table but the
  prompt only carries recent turns. Long-arc continuity would need summarisation.
- **Anonymous Steam logon.** Fine on a LAN, throttled in public.

---

## 12. Prompt for the rebuilding agent

> You are rebuilding Twelve Actors on a fresh Arch/Omarchy host. Work through
> HERMES-REBUILD.md phases 1–8 in order, stopping at the end of each phase to run
> its check. Do not invent paths: the game root is `/srv/dods`, the service user
> is `dod`, the data dir is
> `/srv/dods/dod/addons/sourcemod/data/twelveactors`, the daemon lives at
> `/opt/twelveactors`. Report at the end: `curl -s localhost:8377/healthz`, the
> `sm_ta_bots` line from the server console, and the last two lines of `out.tsv`.
> If a check fails, read Phase 10 before changing anything — every entry there is
> a failure that already happened once.
