#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
"""Send RCON commands to the local Day of Defeat: Source server.

    tools/rcon2.py status                    # password read from server.cfg
    tools/rcon2.py 'sm_ta_status' 'status'  # several commands, in order
    tools/rcon2.py -p '<password>' status    # explicit password
    tools/rcon2.py --dry-run status          # show what would be sent

The password defaults to rcon_password in /srv/dods/dod/cfg/server.cfg
(override with DODS_CFG=/path/to/server.cfg). Passwords are never printed.

An RCON client that sends a wrong password repeatedly gets the source IP
banned by srcds ("Banning ... for rcon hacking attempts"), and the only way
back is a console command, so getting the password right matters more than
convenience here.
"""
import os
import re
import socket
import struct
import sys
import time

HOST = os.environ.get("DODS_HOST", "172.24.1.213")
PORT = int(os.environ.get("DODS_PORT", "27015"))
CFG = os.environ.get("DODS_CFG", "/srv/dods/dod/cfg/server.cfg")


def cfg_password(path=CFG):
    """rcon_password from a server.cfg, or '' when it cannot be read."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                m = re.match(r'\s*rcon_password\s+"?([^"\s]+)"?', line)
                if m:
                    return m.group(1)
    except OSError:
        pass
    return ""


def pkt(pid, ptype, body):
    p = struct.pack("<ii", pid, ptype) + body.encode() + b"\x00\x00"
    return struct.pack("<i", len(p)) + p


def read_pkt(s):
    raw = b""
    while len(raw) < 4:
        c = s.recv(4 - len(raw))
        if not c:
            raise ConnectionError("server closed the connection")
        raw += c
    n = struct.unpack("<i", raw)[0]
    body = b""
    while len(body) < n:
        c = s.recv(n - len(body))
        if not c:
            raise ConnectionError("server closed the connection")
        body += c
    pid, ptype = struct.unpack("<ii", body[:8])
    return pid, ptype, body[8:-2].decode("utf-8", "replace")


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__.strip())
        return 0 if argv else 2

    dry = False
    if argv[0] == "--dry-run":
        dry = True
        argv = argv[1:]

    pw = cfg_password()
    if argv and argv[0] == "-p":
        if len(argv) < 2:
            print("-p needs a password", file=sys.stderr)
            return 2
        pw, argv = argv[1], argv[2:]
    # Backwards compatible with the old password-first form: a first argument
    # equal to the configured password is a password, anything else is a
    # command. That is what stops "rcon2.py sv_alltalk" from burning an auth
    # attempt on a command someone forgot to quote.
    elif argv and pw and argv[0] == pw:
        argv = argv[1:]

    if not pw:
        print("no rcon_password found in %s; use -p" % CFG, file=sys.stderr)
        return 2
    if not argv:
        print("no commands given", file=sys.stderr)
        return 2

    if dry:
        print("host %s:%d  password %d chars from %s" % (HOST, PORT, len(pw), CFG))
        for cmd in argv:
            print("would send: %s" % cmd)
        return 0

    s = socket.create_connection((HOST, PORT), timeout=10)
    s.settimeout(2.0)
    s.sendall(pkt(1, 3, pw))
    pid, _, _ = read_pkt(s)
    if pid == -1:
        print("auth rejected: wrong rcon_password (repeated failures ban this IP)", file=sys.stderr)
        return 1
    for cmd in argv:
        s.sendall(pkt(2, 2, cmd))
        chunks = []
        time.sleep(0.3)
        while True:
            try:
                chunks.append(read_pkt(s)[2])
            except socket.timeout:
                break
        print("$", cmd)
        print("\n".join(chunks))
        print()
    s.close()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (ConnectionError, ConnectionResetError, socket.timeout) as exc:
        print("rcon: %s (a reset right after auth usually means this IP is banned)" % exc,
              file=sys.stderr)
        sys.exit(1)
