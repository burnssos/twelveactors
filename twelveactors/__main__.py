# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
"""twelveactors command line: scan, serve, say, selftest."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from . import voicebank, server
from . import db as dbm

ROOT = Path(__file__).resolve().parent


def default_data() -> Path:
    return Path("/srv/dods/dod/addons/sourcemod/data/twelveactors")


def load_cfg(data: Path) -> dict:
    cfg_path = data / "config.json"
    if cfg_path.exists():
        return json.loads(cfg_path.read_text())
    cfg = {
        "engine": "dods",
        "model": "deepseek-v4-1-flash-1017",
        "base_url": "https://api.venice.ai/api/v1",
        "api_key": _hermes_key(),
        "port": 8377,
        "timeout": 20,
    }
    data.mkdir(parents=True, exist_ok=True)
    cfg_path.write_text(json.dumps(cfg, indent=2))
    cfg_path.chmod(0o640)
    return cfg


def _hermes_key() -> str:
    """Read the Venice key out of the Hermes config without a YAML dependency."""
    path = Path.home() / ".hermes" / "config.yaml"
    if not path.exists():
        return ""
    in_venice = False
    for line in path.read_text(errors="replace").splitlines():
        if "api.venice.ai" in line:
            in_venice = True
        elif in_venice and line.strip().startswith("api_key:"):
            value = line.split(":", 1)[1].strip().strip("'\"")
            if value:
                return value
        elif in_venice and line.startswith("  - name:"):
            in_venice = False
    return ""


def cmd_scan(args) -> int:
    data = Path(args.data)
    profile = ROOT / "profiles" / f"{args.engine}.json"
    if not profile.exists():
        print(f"no profile for {args.engine}", file=sys.stderr)
        return 2
    out = data / "clips.sqlite"
    stats = voicebank.scan(profile, Path(args.install), out)
    prof = json.loads(profile.read_text())
    clips = voicebank.precache_list(out, prof.get("precache_budget", 234))
    (data / "clips.txt").write_text("\n".join(clips) + "\n")
    print(json.dumps({**stats, "precache": len(clips)}, indent=2))
    return 0


def cmd_serve(args) -> int:
    data = Path(args.data)
    cfg = load_cfg(data)
    if args.port:
        cfg["port"] = args.port
    server.serve(data, cfg)
    return 0


def cmd_say(args) -> int:
    data = Path(args.data)
    cfg = load_cfg(data)
    app = server.App(data, cfg)
    faction = args.faction or "american"
    bot = {"name": args.speaker, "team": 2 if faction == "american" else 3}
    reply = app.brain.respond(
        speaker=args.speaker, persona=app.bridge._persona(bot), faction=faction,
        player=args.player, text=args.text, map_name=args.map,
    )
    print(json.dumps({"speaker": reply.speaker, "act": reply.act, "line": reply.line,
                      "clip": reply.clip, "source": reply.source}, indent=2))
    return 0


def cmd_selftest(args) -> int:
    data = Path(args.data)
    cfg = load_cfg(data)
    app = server.App(data, cfg)
    ok = True
    print("engine   ", cfg["engine"])
    print("clips    ", app.stats()["clips"])
    print("key set  ", bool(cfg.get("api_key")))
    try:
        faction = "american"
        bot = {"name": "HiPinger", "team": 2}
        reply = app.brain.respond("HiPinger", app.bridge._persona(bot), faction,
                                  "TestPlayer", "Kowalski, you hear that artillery?",
                                  "dod_anzio")
        print("llm      ", reply.source, "|", reply.act, "|", reply.line)
        print("clip     ", reply.clip)
        ok = reply.source == "llm" and bool(reply.clip)
    except Exception as exc:
        print("llm       FAILED:", exc)
        ok = False
    print("RESULT   ", "PASS" if ok else "FAIL")
    return 0 if ok else 1


def cmd_bootstrap(args) -> int:
    """Assemble the cast and write Twelve Actors' own data files.

    The point is coherence -- the name over the bot's head in the scoreboard is
    the character whose voice and memory the daemon uses, not a slot number.

    This used to rewrite `name`, `team` and `class` in RCBot2's own
    addons/rcbot2/profiles/N.ini files. It no longer touches them, for two
    reasons established 21 Oct 2026:

      1. They are not ours. RCBot2's repository ships no profiles/ directory at
         all -- like its waypoints, the profile set arrives from a separate
         download under no stated terms. Rewriting other people's files in place
         was never defensible, and it is the same finding that removed the .rcw
         waypoint tooling.
      2. It is unnecessary. `rcbotd addbot <class> <team> <name>` sets the name
         and team at creation, verified on a live server -- a bot added as
         ZZTest3 kept that name for 37 s with the supervisor disabled. The
         plugin asks for the persona it wants; nothing has to be pre-seeded.

    Consequence worth knowing: the cast size is now bounded by the card deck
    rather than by how many N.ini files happen to exist. Previously a missing
    profile silently shrank the roster.
    """
    data = Path(args.data)
    cards = json.loads((ROOT / "cards" / "dods.json").read_text())
    us, de = cards["american"], cards["german"]

    order = []
    for k in range((args.bots + 1) // 2):
        order.append(us[k % len(us)])
        if len(order) < args.bots:
            order.append(de[k % len(de)])

    bound = {}
    written = []
    for idx, persona in enumerate(order, start=1):
        faction = "american" if persona["team"] == 2 else "german"
        bound[persona["short"]] = {**persona, "faction": faction}
        written.append(
            f"{idx:>2} {persona['short']:<12} {persona['name']:<20} team {persona['team']}"
        )

    (data / "personas.json").write_text(json.dumps(bound, indent=2))

    # voiced.txt v2: name TAB team. The plugin enforces that the population is
    # the cast and nothing else, and now also that a persona only lands on its
    # own faction -- which used to be guaranteed by the team= line written into
    # the profile files.
    #
    # The #v2 marker exists so a plugin that only understands one column can say
    # so instead of keying on "John\t2" and naming a bot that. Deploy the
    # reader before this writer; see design/PERSONA-BINDING.md.
    lines = ["#v2 name<TAB>team"]
    lines += [f"{p['short']}\t{p['team']}" for p in bound.values()]
    (data / "voiced.txt").write_text("\n".join(lines) + "\n")

    print("\n".join(written))
    print(f"bound {len(bound)} personas -> {data / 'personas.json'}")
    print("no RCBot2 file was touched; the plugin names bots at creation")
    return 0

def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="twelveactors")
    p.add_argument("--data", default=str(default_data()))
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("scan", help="index a game's shipped voice clips")
    s.add_argument("--install", default="/srv/dods")
    s.add_argument("--engine", default="dods")
    s.set_defaults(func=cmd_scan)

    s = sub.add_parser("serve", help="run the daemon")
    s.add_argument("--port", type=int)
    s.set_defaults(func=cmd_serve)

    s = sub.add_parser("say", help="one turn, no daemon needed")
    s.add_argument("text")
    s.add_argument("--speaker", default="HiPinger")
    s.add_argument("--player", default="Player")
    s.add_argument("--faction", default="american")
    s.add_argument("--map", default="dod_anzio")
    s.set_defaults(func=cmd_say)

    s = sub.add_parser("selftest", help="check index + model + voice")
    s.set_defaults(func=cmd_selftest)

    s = sub.add_parser("bootstrap", help="assemble the cast; writes personas.json and voiced.txt")
    s.add_argument("--install", default="/srv/dods")
    s.add_argument("--bots", type=int, default=12)
    s.set_defaults(func=cmd_bootstrap)

    args = p.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
