#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
"""Label quick-key radio pairs for Twelve Actors.

DoD:S builds its voice menus on the client and sends only
`voicemenu <menu> <item>` integers, so the server never sees the words. But the
menu text itself IS on the server: dod/resource/dod_english.txt (UTF-16LE) has
the three lists as "Menu_AmerVoiceA/B/C" and "Menu_GerVoiceA/B/C".

That means you do not have to type 27 phrases by hand. `--autofill` writes the
whole table from the resource file, assuming the usual Source numbering
(menu 0/1/2 = A/B/C, item 0 = first entry). One press in game confirms it, and
`--calibrate` fixes the whole table from a single observed press if the
numbering is off.

  sudo ta-radio --autofill                      # fill from the game's own text
  sudo ta-radio --watch                         # one press confirms it
  sudo ta-radio --calibrate 0:1 --saw "Hold"    # fix numbering from that press

  sudo ta-radio --list
  sudo ta-radio --set 0:3="you spotted an enemy"
  sudo ta-radio --watch --prompt                # manual, one at a time
"""
from __future__ import annotations

import argparse
import json
import os
import re
import time
from pathlib import Path

DEFAULT_DATA = Path(
    os.environ.get("TWELVEACTORS_DATA", "/srv/dods/dod/addons/sourcemod/data/twelveactors")
)
DEFAULT_RESOURCE = Path(
    os.environ.get("TWELVEACTORS_RESOURCE", "/srv/dods/dod/resource/dod_english.txt")
)

# game token -> short menu name. American wording is used as canonical text;
# the German lists differ only in a few lines (grenade / bazooka wording).
MENU_TOKENS = {
    "A": "menu_AmerVoiceA",
    "B": "Menu_AmerVoiceB",
    "C": "Menu_AmerVoiceC",
}
# assumed voicemenu index for each menu, and assumed item index of entry "1."
DEFAULT_MENU_INDEX = {"A": 0, "B": 1, "C": 2}
DEFAULT_ITEM_BASE = 0


def read_presses(data: Path) -> list[tuple[str, str, str, str]]:
    """Every press, oldest first: (menu, item, player, time)."""
    path = data / "radio_seen.tsv"
    rows = []
    if not path.exists():
        return rows
    for line in path.read_text(errors="replace").splitlines():
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        rows.append(
            (
                parts[0],
                parts[1],
                parts[2] if len(parts) > 2 else "",
                parts[3] if len(parts) > 3 else "",
            )
        )
    return rows


def load_map(data: Path) -> dict[str, str]:
    path = data / "radio_map.json"
    try:
        return {str(k): str(v) for k, v in json.loads(path.read_text()).items()}
    except (OSError, ValueError):
        return {}


def save_map(data: Path, mapping: dict[str, str]) -> Path:
    path = data / "radio_map.json"
    path.write_text(json.dumps(mapping, indent=2, sort_keys=True) + "\n")
    try:
        os.chmod(path, 0o644)
    except OSError:
        pass
    return path


# ---------------------------------------------------------------- menu parsing


def decode_resource(path: Path) -> str:
    raw = path.read_bytes()
    if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return raw.decode("utf-16")
    try:
        return raw.decode("utf-16-le")
    except UnicodeDecodeError:
        return raw.decode("utf-8", "replace")


def parse_menus(path: Path = DEFAULT_RESOURCE) -> dict[str, list[str]]:
    """{'A': ['Go go go!', ...9 entries], 'B': [...], 'C': [...]}"""
    text = decode_resource(path)
    out: dict[str, list[str]] = {}
    for name, token in MENU_TOKENS.items():
        m = re.search(r'"%s"\s+"(.*?)"' % re.escape(token), text, re.S)
        if not m:
            raise SystemExit(f"{token} not found in {path}")
        entries = []
        for line in m.group(1).replace("\r", "").split("\n"):
            line = line.strip()
            num, sep, label = line.partition(". ")
            if not sep or not num.isdigit():
                continue
            if num == "0":  # "0. Cancel" is not a command
                continue
            entries.append(label.strip())
        out[name] = entries
    return out


def _norm(text: str) -> str:
    return re.sub(r"[^a-z0-9 ]", "", text.lower()).strip()


def build_table(
    menus: dict[str, list[str]],
    menu_index: dict[str, int] | None = None,
    item_base: int = DEFAULT_ITEM_BASE,
) -> dict[str, str]:
    menu_index = menu_index or DEFAULT_MENU_INDEX
    table: dict[str, str] = {}
    for name, entries in menus.items():
        m = menu_index[name]
        for pos, phrase in enumerate(entries):
            table[f"{m}:{pos + item_base}"] = phrase
    return table


def describe(table: dict[str, str]) -> None:
    by_menu: dict[int, list[tuple[int, str]]] = {}
    for key, phrase in table.items():
        m, i = (int(p) for p in key.split(":"))
        by_menu.setdefault(m, []).append((i, phrase))
    for m in sorted(by_menu):
        rows = sorted(by_menu[m])
        print(f"  menu {m}  ({rows[0][0]}..{rows[-1][0]})")
        print("    " + " | ".join(f"{i}:{p}" for i, p in rows))


# ---------------------------------------------------------------------- actions


def autofill(data: Path, resource: Path) -> None:
    menus = parse_menus(resource)
    table = build_table(menus)
    path = save_map(data, table)
    print(f"filled {len(table)} pairs from {resource}")
    describe(table)
    print(f"\nwrote {path}")
    print(
        "now press C then 1 in game (ta-radio --watch) to confirm menu 0 item 0 "
        "is 'Go go go!'. If the terminal shows a different pair, run:\n"
        '  sudo ta-radio --calibrate <that pair> --saw "Go go go!"'
    )


def calibrate(data: Path, anchors: list[tuple[str, str]], resource: Path) -> None:
    """anchors: [(pair, text_seen)]. One anchor is enough if only the item
    numbering is shifted; two pin the menu order exactly."""
    menus = parse_menus(resource)
    facts: list[tuple[str, float, int, int]] = []
    for key, saw in anchors:
        m, _, i = key.partition(":")
        if not (m.isdigit() and i.isdigit()):
            raise SystemExit(f"bad pair {key!r}, want MENU:ITEM (e.g. 1:0)")
        want = _norm(saw)
        hits = [
            (name, pos)
            for name, entries in menus.items()
            for pos, phrase in enumerate(entries)
            if _norm(phrase) == want
        ]
        if not hits:
            hits = [
                (name, pos)
                for name, entries in menus.items()
                for pos, phrase in enumerate(entries)
                if want and want in _norm(phrase)
            ]
        if not hits:
            raise SystemExit(
                f"no menu entry matches {saw!r}; known entries include "
                + ", ".join(sorted({p for e in menus.values() for p in e})[:6])
            )
        # prefer a menu nobody anchored yet
        used = {f[0] for f in facts}
        hits.sort(key=lambda h: (h[0] in used, DEFAULT_MENU_INDEX[h[0]] != int(m), h[0]))
        name, pos = hits[0]
        facts.append((name, pos, int(m), int(i)))

    bases = {i - pos for _n, pos, _m, i in facts}
    if len(bases) > 1:
        raise SystemExit(
            "anchors disagree about the item numbering "
            f"({sorted(bases)}) — bad phrase for one of them"
        )
    item_base = bases.pop()

    menu_index = {name: m for name, _pos, m, _i in facts}
    free = sorted(set(DEFAULT_MENU_INDEX.values()) - set(menu_index.values()))
    for name in [n for n in DEFAULT_MENU_INDEX if n not in menu_index]:
        if not free:
            raise SystemExit("menu numbering is inconsistent — need another press")
        menu_index[name] = free.pop(0)

    table = build_table(menus, menu_index, item_base)
    path = save_map(data, table)
    for name, pos, m, i in facts:
        print(f'{m}:{i} = menu {name} entry {pos + 1} ("{menus[name][pos]}")')
    print(
        "derived: "
        + ", ".join(f"{n}=menu{m}" for n, m in sorted(menu_index.items()))
        + f", entry 1 = item {item_base}"
    )
    print(f"rewrote {len(table)} pairs in {path}")
    describe(table)


def show(data: Path) -> None:
    mapping = load_map(data)
    counts: dict[str, int] = {}
    for menu, item, _who, _when in read_presses(data):
        key = f"{menu}:{item}"
        counts[key] = counts.get(key, 0) + 1

    if not counts:
        print(f"no presses yet in {data / 'radio_seen.tsv'}")
        print("join, press C, pick an item, then run this again")
        print("or run  ta-radio --autofill  to fill the table from the game files")
        return

    print(f"{'pair':>6}  {'pressed':>8}  meaning")
    for key in sorted(counts, key=lambda k: [int(p) for p in k.split(":")]):
        print(f"{key:>6}  x{counts[key]:<7} {mapping.get(key, '— unlabelled')}")
    missing = [k for k in counts if k not in mapping]
    if missing:
        print(
            f"\n{len(missing)} pressed pair(s) unlabelled: "
            + ", ".join(sorted(missing, key=lambda k: [int(p) for p in k.split(":")]))
        )


def watch(data: Path, prompt: bool) -> None:
    seen_path = data / "radio_seen.tsv"
    offset = seen_path.stat().st_size if seen_path.exists() else 0
    print(f"watching {seen_path}")
    print("press a quick key in game (one item at a time). Ctrl-C to stop.\n")
    while True:
        try:
            size = seen_path.stat().st_size
        except FileNotFoundError:
            time.sleep(1.0)
            continue
        if size < offset:  # truncated / replaced
            offset = 0
        if size > offset:
            with seen_path.open("rb") as fh:
                fh.seek(offset)
                chunk = fh.read(size - offset)
            offset = size
            for line in chunk.decode("utf-8", "replace").splitlines():
                parts = line.split("\t")
                if len(parts) < 2:
                    continue
                key = f"{parts[0]}:{parts[1]}"
                who = parts[2] if len(parts) > 2 else "?"
                stamp = parts[3] if len(parts) > 3 else ""
                label = load_map(data).get(key)
                state = f'= "{label}"' if label else "— unlabelled"
                print(f"[{stamp}] {who}: pair {key}  {state}")
                if prompt and not label:
                    try:
                        text = input("   what did the game say? (blank = skip) > ")
                    except EOFError:
                        return
                    if text.strip():
                        mapping = load_map(data)
                        mapping[key] = text.strip()
                        save_map(data, mapping)
                        print(f'   saved {key} = "{mapping[key]}"')
        time.sleep(0.4)


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Label DoD:S quick-key radio pairs for Twelve Actors."
    )
    ap.add_argument("--data", type=Path, default=DEFAULT_DATA)
    ap.add_argument("--resource", type=Path, default=DEFAULT_RESOURCE)
    ap.add_argument("--list", action="store_true", help="show pairs and their labels")
    ap.add_argument(
        "--autofill",
        action="store_true",
        help="fill every pair from the game's own menu text in dod_english.txt",
    )
    ap.add_argument(
        "--calibrate",
        action="append",
        default=[],
        metavar="MENU:ITEM=TEXT",
        help='fix the numbering from a press you saw, e.g. --calibrate 1:0="Go go go!"',
    )
    ap.add_argument("--watch", action="store_true", help="follow presses as they happen")
    ap.add_argument(
        "--prompt",
        action="store_true",
        help="with --watch: ask for a meaning after each new pair",
    )
    ap.add_argument(
        "--set",
        action="append",
        default=[],
        metavar="MENU:ITEM=PHRASE",
        help='label a pair, e.g. --set 0:3="you spotted an enemy"',
    )
    args = ap.parse_args()

    if args.autofill:
        autofill(args.data, args.resource)

    if args.calibrate:
        anchors = []
        for item in args.calibrate:
            key, _, text = item.partition("=")
            if not (key.strip() and text.strip()):
                raise SystemExit(f'bad --calibrate {item!r}, want MENU:ITEM="text seen"')
            anchors.append((key.strip(), text.strip()))
        calibrate(args.data, anchors, args.resource)

    if args.set:
        mapping = load_map(args.data)
        for item in args.set:
            key, _, phrase = item.partition("=")
            key, phrase = key.strip(), phrase.strip()
            a, sep, b = key.partition(":")
            if not (sep and a.isdigit() and b.isdigit() and phrase):
                raise SystemExit(f"bad --set {item!r}, want MENU:ITEM=PHRASE")
            mapping[key] = phrase
        path = save_map(args.data, mapping)
        print(f"wrote {len(mapping)} label(s) to {path}")
        print("the daemon reloads it on the next radio press — no restart needed")

    if args.watch:
        try:
            watch(args.data, args.prompt)
        except KeyboardInterrupt:
            print()
    elif not (args.set or args.autofill or args.calibrate) or args.list:
        show(args.data)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
