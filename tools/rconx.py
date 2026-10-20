# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
import socket, struct, sys, time

HOST = sys.argv[1]
PORT = int(sys.argv[2])
PW = sys.argv[3]
CMDS = sys.argv[4:]


def pkt(pid, ptype, body):
    p = struct.pack("<ii", pid, ptype) + body.encode() + b"\x00\x00"
    return struct.pack("<i", len(p)) + p


def read_pkt(s):
    raw = b""
    while len(raw) < 4:
        c = s.recv(4 - len(raw))
        if not c:
            raise ConnectionError
        raw += c
    n = struct.unpack("<i", raw)[0]
    body = b""
    while len(body) < n:
        c = s.recv(n - len(body))
        if not c:
            raise ConnectionError
        body += c
    pid, pt = struct.unpack("<ii", body[:8])
    return pid, pt, body[8:-2].decode("utf-8", "replace")


s = socket.create_connection((HOST, PORT), timeout=10)
s.settimeout(2.0)
s.sendall(pkt(1, 3, PW))
print("auth:", s.recv(1024)[:4])
for cmd in CMDS:
    s.sendall(pkt(2, 2, cmd))
    chunks = []
    time.sleep(0.35)
    while True:
        try:
            chunks.append(read_pkt(s)[2])
        except socket.timeout:
            break
    print("$", cmd)
    print("\n".join(chunks))
    print()
s.close()
