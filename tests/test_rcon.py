# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
"""Argument handling for tools/rcon2.py.

The client is only exercised in --dry-run mode: a live auth attempt against a
server that bans repeated failures is not something a test should do.

What is being protected here: rcon2.py used to take the password as argv[1]
unconditionally, so `rcon2.py sv_alltalk` sent "sv_alltalk" as the password,
was rejected, and two of those got the machine's IP banned for rcon hacking.
"""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOL = os.path.join(HERE, "tools", "rcon2.py")
SECRET = "s3cret-do-not-print"


def run(args, cfg_text=None):
    with tempfile.NamedTemporaryFile("w", suffix=".cfg", delete=False) as f:
        f.write(cfg_text if cfg_text is not None else 'rcon_password "%s"\n' % SECRET)
        path = f.name
    try:
        env = dict(os.environ, DODS_CFG=path)
        p = subprocess.run([sys.executable, TOOL, "--dry-run", *args],
                           capture_output=True, text=True, env=env, timeout=30)
        return p.returncode, p.stdout + p.stderr
    finally:
        os.unlink(path)


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + (("  " + detail) if detail and not ok else ""))
    return ok


def main():
    results = []

    # A bare command must be treated as a command, not as a password.
    rc, out = run(["sv_alltalk"])
    results.append(check("command is not a password", rc == 0 and "would send: sv_alltalk" in out, out))

    # Two commands, neither swallowed as a password.
    rc, out = run(["status", "sm_ta_status"])
    results.append(check("all arguments are commands",
                         rc == 0 and out.count("would send:") == 2, out))

    # The old password-first form still works for install scripts.
    rc, out = run([SECRET, "status"])
    results.append(check("legacy password-first form",
                         rc == 0 and out.count("would send:") == 1 and "would send: status" in out, out))

    # An explicit -p wins over the config.
    rc, out = run(["-p", "other-password", "status"])
    results.append(check("explicit -p", rc == 0 and "would send: status" in out, out))

    # No password anywhere is a clean error, not an empty auth attempt.
    rc, out = run(["status"], cfg_text="// no rcon here\n")
    results.append(check("missing password exits 2", rc == 2 and "no rcon_password" in out, out))

    # No command is an error, not a connection attempt.
    rc, out = run([])
    results.append(check("no command exits 2", rc == 2, out))

    # The password itself never reaches stdout or stderr.
    leaks = [out for _, out in (run([SECRET, "status"]), run(["status"])) if SECRET in out]
    results.append(check("password never printed", not leaks, str(leaks)))

    print("%d/%d rcon argument checks pass" % (sum(results), len(results)))
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
