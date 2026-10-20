#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
"""UDP logger for the DoD:S server log stream (logaddress_add).

Run as the normal user, not root. The game server sends its log stream to
UDP 27777; this writes it to a clean text file, one server line per line.

    python3 spawnwatch_capture.py [outfile] [seconds]

With no seconds argument it runs until killed.
"""
import os
import socket
import sys
import time

default_log = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "logs", "spawnwatch.log")
out = sys.argv[1] if len(sys.argv) > 1 else default_log
secs = int(sys.argv[2]) if len(sys.argv) > 2 else 0

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", 27777))
s.settimeout(1.0)

os.makedirs(os.path.dirname(out), exist_ok=True)
f = open(out, "a", buffering=1)
f.write("# capture started %s\n" % time.strftime("%Y-%m-%d %H:%M:%S"))

end = time.time() + secs if secs else None
n = 0
try:
    while end is None or time.time() < end:
        try:
            data, _ = s.recvfrom(8192)
        except socket.timeout:
            continue
        text = data.decode("utf-8", "replace").replace("\x00", "")
        for line in text.splitlines():
            line = line.strip()
            if line:
                f.write(line + "\n")
                n += 1
finally:
    f.close()
    print("lines %d -> %s" % (n, out))
