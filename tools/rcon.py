#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
"""Minimal Source RCON client (no deps) for live diagnostics."""
import socket
import struct
import sys

HOST, PORT = "172.24.1.113", 27015
SERVERDATA_AUTH = 3
SERVERDATA_AUTH_RESPONSE = 2
SERVERDATA_EXECCOMMAND = 2


def pkt(pid, ptype, body):
    payload = struct.pack("<ii", pid, ptype) + body.encode("utf-8") + b"\x00\x00"
    return struct.pack("<i", len(payload)) + payload


def read_pkt(sock):
    raw = b""
    while len(raw) < 4:
        chunk = sock.recv(4 - len(raw))
        if not chunk:
            raise ConnectionError("closed")
        raw += chunk
    (size,) = struct.unpack("<i", raw)
    body = b""
    while len(body) < size:
        chunk = sock.recv(size - len(body))
        if not chunk:
            raise ConnectionError("closed")
        body += chunk
    pid, ptype = struct.unpack("<ii", body[:8])
    return pid, ptype, body[8:-2].decode("utf-8", "replace")


def run(password, commands, timeout=6):
    out = []
    with socket.create_connection((HOST, PORT), timeout=timeout) as s:
        s.settimeout(timeout)
        s.sendall(pkt(1, SERVERDATA_AUTH, password))
        pid, ptype, _ = read_pkt(s)
        if pid == -1:
            return ["AUTH FAILED"]
        for cmd in commands:
            s.sendall(pkt(2, SERVERDATA_EXECCOMMAND, cmd))
            resp = []
            try:
                while True:
                    pid, ptype, text = read_pkt(s)
                    if ptype == 0 and "Unknown request" in text:
                        continue
                    resp.append(text)
                    if ptype == 0:
                        break
            except socket.timeout:
                resp.append("(no response)")
            out.append(f"$ {cmd}\n" + "\n".join(r.strip() for r in resp if r.strip()))
    return out


if __name__ == "__main__":
    pw = sys.argv[1]
    print("\n\n".join(run(pw, sys.argv[2:])))
