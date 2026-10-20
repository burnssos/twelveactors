# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
"""Minimal VPK reader (v1/v2), stdlib only.

Reads the directory tree of a Source VPK and can extract embedded or
chunk-file contents.  Used by the voice scanner; no external deps.
"""
from __future__ import annotations

import struct
from dataclasses import dataclass
from pathlib import Path

SIG = 0x55AA1234
DIR_INDEX = 0x7FFF


@dataclass(frozen=True)
class Entry:
    path: str          # full in-archive path, e.g. sound/player/american/us_yessir.wav
    crc: int
    preload: int
    archive_index: int
    offset: int
    length: int
    pre: bytes = b""


class VPK:
    def __init__(self, dir_vpk: Path):
        self.dir_vpk = Path(dir_vpk)
        self.header_size = 0
        self.version = 0
        self.entries: list[Entry] = []
        self._read_tree()

    def _read_tree(self) -> None:
        data = self.dir_vpk.read_bytes()
        sig, version = struct.unpack_from("<II", data, 0)
        if sig != SIG:
            raise ValueError(f"{self.dir_vpk}: not a VPK (sig={sig:#x})")
        self.version = version
        if version == 1:
            (tree_size,) = struct.unpack_from("<I", data, 8)
            self.header_size = 12
        elif version == 2:
            tree_size, _file_data_size = struct.unpack_from("<II", data, 8)
            self.header_size = 28
        else:
            raise ValueError(f"{self.dir_vpk}: unsupported VPK version {version}")

        pos = self.header_size
        end = self.header_size + tree_size
        while pos < end:
            ext, pos = _cstr(data, pos)
            if ext == "":
                break
            while True:
                folder, pos = _cstr(data, pos)
                if folder == "":
                    break
                while True:
                    name, pos = _cstr(data, pos)
                    if name == "":
                        break
                    crc, preload, aidx, off, ln = struct.unpack_from("<IHHII", data, pos)
                    pos += 16
                    pre = data[pos:pos + preload] if preload else b""
                    pos += preload
                    (term,) = struct.unpack_from("<H", data, pos)
                    pos += 2
                    if term != 0xFFFF:
                        raise ValueError(f"{self.dir_vpk}: bad entry terminator at {pos - 2}")
                    full = "/".join(p for p in (folder, f"{name}.{ext}") if p)
                    self.entries.append(Entry(full, crc, preload, aidx, off, ln, pre))
        self._data = data

    def read(self, entry: Entry) -> bytes:
        if entry.preload:
            return entry.pre
        if entry.archive_index == DIR_INDEX:
            start = self.header_size + _tree_size(self._data) + entry.offset
        else:
            chunk = self.dir_vpk.with_name(
                self.dir_vpk.name.replace("_dir.vpk", f"_{entry.archive_index:03d}.vpk")
            )
            with open(chunk, "rb") as fh:
                fh.seek(entry.offset)
                return fh.read(entry.length)
        return self._data[start:start + entry.length]

    def find(self, prefix: str, suffix: str = "") -> list[Entry]:
        return [e for e in self.entries if e.path.startswith(prefix) and e.path.endswith(suffix)]


def _tree_size(data: bytes) -> int:
    (size,) = struct.unpack_from("<I", data, 8)
    return size


def _cstr(data: bytes, pos: int) -> tuple[str, int]:
    end = data.index(b"\x00", pos)
    return data[pos:end].decode("utf-8", "replace"), end + 1


def wav_duration(data: bytes) -> tuple[float, int, int, int]:
    """Return (seconds, rate, channels, bits) from a RIFF/WAVE blob."""
    if len(data) < 44 or data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        return 0.0, 0, 0, 0
    pos, rate, channels, bits = 12, 0, 0, 0
    while pos + 8 <= len(data):
        cid = data[pos:pos + 4]
        size = struct.unpack_from("<I", data, pos + 4)[0]
        body = pos + 8
        if cid == b"fmt ":
            channels = struct.unpack_from("<H", data, body + 2)[0]
            rate = struct.unpack_from("<I", data, body + 4)[0]
            bits = struct.unpack_from("<H", data, body + 14)[0]
        elif cid == b"data":
            if rate and channels and bits:
                return size / float(rate * channels * (bits // 8)), rate, channels, bits
            return 0.0, rate, channels, bits
        pos = body + size + (size & 1)
    return 0.0, rate, channels, bits
