# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
"""HTTP surface + process wiring.

The plugin does not use HTTP (see bridge.py), but the same turn API is served
for tooling, tests and any future non-SourcePawn client.
"""
from __future__ import annotations

import json
import sqlite3
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from . import db as dbm
from .brain import Brain
from .bridge import Bridge

ROOT = Path(__file__).resolve().parent


class App:
    def __init__(self, data: Path, cfg: dict):
        self.data = Path(data)
        self.cfg = cfg
        self.profile = json.loads((ROOT / "profiles" / f"{cfg['engine']}.json").read_text())
        self.cards = json.loads((ROOT / "cards" / f"{cfg['engine']}.json").read_text())
        self.db = dbm.connect(self.data / "state.sqlite")
        self.clips = self.data / "clips.sqlite"
        if not self.clips.exists():
            raise SystemExit(f"no clip index at {self.clips}; run: python -m twelveactors scan")
        self.brain = Brain(cfg, self.db, self.profile, self.cards, str(self.clips))
        self.log_path = self.data / "daemon.log"
        self.bridge = Bridge(self.data, cfg, self.db, self.profile, self.cards, self.brain)

    def log(self, msg: str) -> None:
        line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}"
        print(line, flush=True)
        try:
            with open(self.log_path, "a") as fh:
                fh.write(line + "\n")
        except OSError:
            pass

    def stats(self) -> dict:
        clips = sqlite3.connect(self.clips)
        n = clips.execute("SELECT COUNT(*) FROM clips").fetchone()[0]
        clips.close()
        # Live roster, not the bots table: the table only grows when a bot
        # actually speaks, so it reported 0 on a server full of bots.
        bots = len(self.bridge.bots())
        humans = len(self.bridge.humans())
        turns = self.db.execute("SELECT COUNT(*) FROM turns").fetchone()[0]
        return {
            "clips": n, "bots_known": bots, "turns": turns,
            "engine": self.cfg["engine"], "model": self.cfg["model"],
            "bridge": dict(self.bridge.stats), "roster": len(self.bridge.roster()),
            "humans": humans, "dialog_open": self.bridge.dialog_allowed(),
            "scope": dict(self.brain.scope_stats),
            "errors": self.cfg.get("_errors", [])[-3:],
        }


def make_handler(app: App):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def _send(self, code: int, payload: dict) -> None:
            body = json.dumps(payload).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, fmt, *args):  # keep the journal quiet
            pass

        def do_GET(self):
            if self.path.startswith("/healthz"):
                self._send(200, {"ok": True, **app.stats()})
            elif self.path.startswith("/v1/stats"):
                self._send(200, app.stats())
            elif self.path.startswith("/v1/recent"):
                self._send(200, {"recent": list(app.bridge.recent)})
            elif self.path.startswith("/v1/roster"):
                self._send(200, {"roster": app.bridge.roster()})
            else:
                self._send(404, {"error": "not found"})

        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0))
            try:
                body = json.loads(self.rfile.read(length) or b"{}")
            except json.JSONDecodeError:
                return self._send(400, {"error": "bad json"})
            if self.path.startswith("/v1/turn"):
                self._turn(body)
            else:
                self._send(404, {"error": "not found"})

        def _turn(self, body: dict):
            name = body.get("speaker") or "bot"
            faction = body.get("faction") or "american"
            bot = {"name": name, "team": 2 if faction == "american" else 3}
            persona = app.bridge._persona(bot)
            reply = app.brain.respond(
                speaker=name, persona=persona, faction=faction,
                player=body.get("player") or "Player", text=body.get("text", ""),
                map_name=body.get("map") or app.cfg.get("map", ""),
            )
            dbm.log_turn(app.db, reply.speaker, body.get("player") or "Player",
                         body.get("text", ""), reply.act, reply.line,
                         reply.clip, reply.source)
            self._send(200, {"speaker": reply.speaker, "act": reply.act,
                             "line": reply.line, "clip": reply.clip,
                             "source": reply.source})

    return Handler


def serve(data: Path, cfg: dict) -> None:
    app = App(data, cfg)
    app.log(f"[twelveactors] engine={cfg['engine']} model={cfg['model']} clips={app.stats()['clips']}")
    app.bridge.start()
    port = int(cfg.get("port", 8377))
    srv = ThreadingHTTPServer(("127.0.0.1", port), make_handler(app))
    app.log(f"[twelveactors] http on 127.0.0.1:{port}, bridge watching {app.data / 'in.tsv'}")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        app.bridge.stop()
        srv.server_close()
