# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
"""Bridge timing and file-growth tests.

Pins three behaviours:

- a slow model call cannot make the bots answer stale chat: the reader thread
  stamps each line on arrival, events older than event_max_age_s are dropped,
  and a reply ready later than reply_max_age_s is discarded;
- out.tsv and radio_seen.tsv are trimmed to a tail, and the highest seq
  survives the trim, so neither a restarted daemon nor the plugin replays or
  skips lines;
- a half-written line in in.tsv is left for the next read, and a rotated
  (shrunk) in.tsv is read from the top.

The model is a stub; no network is used.

Run: python3 -m pytest tests -q   (or python3 tests/test_bridge_timing.py)
"""
from __future__ import annotations

import json
import sys
import tempfile
import time
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from twelveactors import bridge as bridge_mod  # noqa: E402
from twelveactors import db as dbm  # noqa: E402

CARDS = json.loads((ROOT / "twelveactors/cards/dods.json").read_text())
PROFILE = json.loads((ROOT / "twelveactors/profiles/dods.json").read_text())

FAILS: list[str] = []


def check(name: str, cond: bool, detail: str = "") -> None:
    print(("ok   " if cond else "FAIL ") + name + (f" - {detail}" if detail and not cond else ""))
    if not cond:
        FAILS.append(name)


class StubBrain:
    """Answers every line, optionally after a delay (a slow model)."""

    def __init__(self, delay: float = 0.0):
        self.delay = delay
        self.calls = 0

    def respond(self, speaker, persona, faction, player, text, map_name, event=None, memory=None):
        self.calls += 1
        if self.delay:
            time.sleep(self.delay)
        return SimpleNamespace(speaker=speaker, act="ack", line=f"re: {text}",
                               clip="player/american/us_yessir.wav", source="llm")

    def pick_clip(self, faction, act):
        return "player/american/us_yessir.wav"


def make(tmp: Path, brain: StubBrain, **cfg) -> bridge_mod.Bridge:
    # Two Allied bots and one human, as the plugin's roster snapshot writes it.
    (tmp / "roster.tsv").write_text("John\t2\t1\nPaul\t2\t1\nAlice\t2\t0\n")
    db = dbm.connect(tmp / "state.sqlite")
    base = {"dialog_requires_human": True}
    base.update(cfg)
    return bridge_mod.Bridge(tmp, base, db, PROFILE, CARDS, brain)


def say(seq: int, text: str, name: str = "Alice") -> str:
    return f"{seq}\tsay\t5\t{name}\t2\t0\t{text}"


def out_lines(tmp: Path) -> list[str]:
    p = tmp / "out.tsv"
    return p.read_text().splitlines() if p.exists() else []


def test_fresh_event_answered() -> None:
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        b = make(tmp, StubBrain())
        r = b._handle_timed(time.monotonic(), say(1, "John, status?"))
        check("fresh addressed line is answered", r is not None and len(out_lines(tmp)) == 1)


def test_stale_event_dropped() -> None:
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        brain = StubBrain()
        b = make(tmp, brain)
        r = b._handle_timed(time.monotonic() - 10.0, say(1, "John, status?"))
        check("event older than MAX_AGE is dropped", r is None and not out_lines(tmp))
        check("dropped event costs no model call", brain.calls == 0)
        check("dropped event is counted as stale", b.stats["stale"] == 1)


def test_late_reply_discarded() -> None:
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        b = make(tmp, StubBrain(delay=0.3), reply_max_age_s=0.2)
        r = b._handle_timed(time.monotonic(), say(1, "John, status?"))
        check("reply ready after reply_max_age_s is not played", r is None and not out_lines(tmp))
        check("late reply is counted", b.stats["late"] == 1)
        check("late reply frees the bot's cooldown", "John" not in b._bot_cooldown)


def test_reply_age_check_can_be_disabled() -> None:
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        b = make(tmp, StubBrain(delay=0.3), reply_max_age_s=0)
        r = b._handle_timed(time.monotonic(), say(1, "John, status?"))
        check("reply_max_age_s 0 disables the late-reply check", r is not None)


def test_backlog_behind_slow_model_is_dropped() -> None:
    """End to end through the real reader and worker threads.

    The first question takes 1.2 s to answer. Two more arrive meanwhile. With a
    0.5 s event age limit, they are stale by the time the worker reaches them,
    and the bots must not answer them late.
    """
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        brain = StubBrain(delay=1.2)
        (tmp / "in.tsv").write_text("")
        b = make(tmp, brain, event_max_age_s=0.5, reply_max_age_s=0)
        b.start()
        try:
            with (tmp / "in.tsv").open("a") as fh:
                fh.write(say(1, "John, first question") + "\n")
            time.sleep(0.4)
            with (tmp / "in.tsv").open("a") as fh:
                fh.write(say(2, "Paul, second question") + "\n")
                fh.write(say(3, "John, third question") + "\n")
            time.sleep(2.2)
        finally:
            b.stop()
        lines = out_lines(tmp)
        check("first question answered", any("first question" in ln for ln in lines), str(lines))
        check("backlog behind the slow call is not answered late",
              not any("second" in ln or "third" in ln for ln in lines), str(lines))
        check("backlog counted as stale", b.stats["stale"] == 2, str(b.stats))
        check("model was called once, not three times", brain.calls == 1, str(brain.calls))


def test_out_trim_keeps_tail_and_seq() -> None:
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        old = (bridge_mod.OUT_TRIM_BYTES, bridge_mod.OUT_KEEP_LINES)
        bridge_mod.OUT_TRIM_BYTES, bridge_mod.OUT_KEEP_LINES = 2000, 5
        try:
            b = make(tmp, StubBrain())
            for i in range(200):
                b._write_out("John", "x.wav", f"line {i}")
            lines = out_lines(tmp)
            size = (tmp / "out.tsv").stat().st_size
            check("out.tsv stays bounded", size <= 2000 + 200, f"{size} bytes")
            check("trim keeps a tail, not an empty file", 1 <= len(lines) <= 40, str(len(lines)))
            check("last line written is kept", lines and lines[-1].startswith("200\t"), lines[-1:])
            # A restarted daemon must continue the sequence, not restart at 1.
            b2 = make(tmp, StubBrain())
            check("restart continues seq after a trim", b2._out_seq == 200, str(b2._out_seq))
            check("no temp file left behind", not (tmp / "out.tsv.tmp").exists())
        finally:
            bridge_mod.OUT_TRIM_BYTES, bridge_mod.OUT_KEEP_LINES = old


def test_radio_seen_trim() -> None:
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        old = (bridge_mod.RADIO_SEEN_TRIM_BYTES, bridge_mod.RADIO_SEEN_KEEP_LINES)
        bridge_mod.RADIO_SEEN_TRIM_BYTES, bridge_mod.RADIO_SEEN_KEEP_LINES = 1000, 10
        try:
            b = make(tmp, StubBrain())
            for i in range(300):
                b.on_radio(["%d" % i, "radio", "5", "Alice", "2", "0", str(i % 6)])
            size = (tmp / "radio_seen.tsv").stat().st_size
            check("radio_seen.tsv stays bounded", size <= 1000 + 100, f"{size} bytes")
        finally:
            bridge_mod.RADIO_SEEN_TRIM_BYTES, bridge_mod.RADIO_SEEN_KEEP_LINES = old


def test_partial_line_waits() -> None:
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        (tmp / "in.tsv").write_text("")
        b = make(tmp, StubBrain())
        with (tmp / "in.tsv").open("a") as fh:
            fh.write(say(1, "John, half wri"))
        check("half-written line is not read yet", b._read_new() == [])
        with (tmp / "in.tsv").open("a") as fh:
            fh.write("tten\n")
        got = b._read_new()
        check("completed line is read whole", got == [say(1, "John, half written")], str(got))


def test_rotated_in_file_read_from_top() -> None:
    with tempfile.TemporaryDirectory() as d:
        tmp = Path(d)
        (tmp / "in.tsv").write_text("".join(say(i, f"old {i}") + "\n" for i in range(50)))
        b = make(tmp, StubBrain())  # starts at end of file
        check("existing backlog is skipped at start", b._read_new() == [])
        (tmp / "in.tsv").unlink()  # the plugin rotates it
        (tmp / "in.tsv").write_text(say(51, "fresh") + "\n")
        got = b._read_new()
        check("rotated in.tsv is read from the top", got == [say(51, "fresh")], str(got))


def test_error_list_bounded() -> None:
    with tempfile.TemporaryDirectory() as d:
        b = make(Path(d), StubBrain())
        for i in range(500):
            b._note_error(RuntimeError(f"boom {i}"))
        errs = b.cfg["_errors"]
        check("error list is bounded", len(errs) == 20 and errs[-1] == "boom 499", str(len(errs)))


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
    total = sum(1 for n in globals() if n.startswith("test_"))
    if FAILS:
        print(f"\n{len(FAILS)} check(s) failed")
        sys.exit(1)
    print(f"\nall bridge timing checks pass ({total} tests)")
