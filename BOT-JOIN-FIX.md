# Bot join suicide / ERRORNAME churn — diagnosis and fix

## Symptom
Bots "spawn and die" continuously; every client's kill feed shows
`ERRORNAME committed suicide` (allied and axis). Worst case: one bot every
10 s (measured 6-7/min on 2026-10-19 between 10:54 and 11:07).

## What is actually happening (measured on a sandbox copy of the server)
```
[sw] SPAWN  John team=0 bot=1 pos=0 0 -132      <- fake client spawned alive, no team
       "John<408><BOT><Unassigned>" joined team "Allies"
       "John<408><BOT><Allies>" committed suicide with "world"   <- team change kills a live body
[sw] DEATH  John team=2 bot=1 pos=0 0 -74 killer=world
       "John<408><BOT><Allies>" changed role to "#class_allied_garand"
```
RCBot2 changes a bot's team first and sends the class command afterwards.
DoD:S spawns the fake client on connect, so the team change kills a live body.
The death notice is broadcast before clients know the bot's name, so the client
prints `PLAYER_ERROR_NAME` = "ERRORNAME".

The *churn* (bots appearing every 10 s) is the bot module kicking any bot whose
name is not in `addons/sourcemod/data/twelveactors/voiced.txt`. RCBot2's
`rcbot_nonrandom_profile 1` falls back to a random launcher profile (`moe`,
`ramb0`, `[Ja]Hugh[SS]`, ...) whenever it cannot find a persona for the smaller
team, so the module kicked a bot every pass and RCBot2 re-added one.

## Fix (two plugins, verified on a sandbox server on port 27016)
1. `ta_botjoin.smx` (new) — on `player_spawn`, any fake client still in team 0
   is set to `m_lifeState = LIFE_DEAD`. The team change then has nothing to
   kill; the class command spawns the bot normally at its team spawn point.
   Verified: 0 `committed suicide with "world"` lines while the roster filled
   0 -> 12, and every bot spawned alive (positions dumped via `sm_posdump`).
2. `ta_bots_rcbot2.smx` — a stray (unvoiced) bot is renamed onto a free
   persona instead of kicked. Verified: `moe` -> `Kowalski` on the next pass,
   no kick, no death. Falls back to a kick only when every persona is in use.

## Install
```
sudo ./deploy-bots.sh
```
Backups: `/srv/dods/dod/addons/sourcemod/plugins/*.bak.<timestamp>`.

## Verify
```
journalctl -u dods --since '-10min' | grep 'committed suicide with "world"'   # expect nothing
journalctl -u dods --since '-10min' | grep -E 'renamed stray|removed unvoiced'
```

Installed live 2026-10-19 12:04 (module reload) + 12:04:43 (`ta_botjoin` load),
measured over the next minutes:

```
12:02:12 … 12:04:32   7 x "removed unvoiced bot (slot 13)" + "moe committed suicide with world"
                      <- before: one per 10 s, the churn itself
12:04:51 … 12:05:51   7 x "renamed stray bot (slot N) to <persona>"      <- roster settling
12:05:51 onward       no kicks, no renames, no world suicides
60 s window at 12:07  0 world suicides, 0 renames, 0 removals, 17 respawns (normal play)
12:07:25              "(1)John<56><BOT><Unassigned>" joined team "Allies" — no death notice
```

A single `committed suicide with "bazooka"` after the fix is a bot that fired a
rocket into a wall, not the join bug: filter on `with "world"`.

## Sources
Canonical source is `twelveactors/plugin/`:

- `plugin/ta_botjoin.sp` — the join fix (installed as `ta_botjoin.smx`).
- `plugin/ta_bots_rcbot2.sp` — rename-instead-of-kick.

`deploy-bots.sh` compiles and installs both from `plugin/`; `install.sh` does the
same on a fresh install. `build/` is scratch compiler output, not shipped and not
authoritative — edit `plugin/*.sp`, then run `deploy-bots.sh`. The
experiments that did NOT work are in `plugin/ta_botjoin_experimental.sp`:
killing the bot at connect, setting the desired class, and a per-tick lifeState
timer all still produced the join suicide — the `player_spawn` hook is the only
one that lands in time.
