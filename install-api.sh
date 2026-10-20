#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Twelve Actors contributors
# SPDX-License-Identifier: MPL-2.0
# Update the API endpoint / key / model the Twelve Actors daemon uses.
#
#   sudo bash install-api.sh                       # interactive: Enter keeps a value
#   sudo bash install-api.sh --base-url URL --model ID
#   sudo bash install-api.sh --key-file /root/ta.key
#   bash install-api.sh --config /tmp/cfg.json --base-url ... --no-restart
#
# The key is never taken from argv (it would show in `ps`) and never printed.
# Existing keys in config.json (dialog gate, unprompted chance, ...) are kept.
set -euo pipefail

usage() {
  cat <<'EOF'
Update the API endpoint / key / model the Twelve Actors daemon uses.

  sudo bash install-api.sh                       interactive; Enter keeps a value
  sudo bash install-api.sh --base-url URL --model ID
  sudo bash install-api.sh --key-file /root/ta.key
  bash install-api.sh --config /tmp/cfg.json --base-url ... --no-restart

The key is never taken from argv (it would show in `ps`) and never printed.
Keys already in config.json (dialog gate, unprompted chance, ...) are preserved.
EOF
}

DEFAULT_CFG="/srv/dods/dod/addons/sourcemod/data/twelveactors/config.json"
CFG="$DEFAULT_CFG"
ORIG_ARGS="$*"

i=1
while [ "$i" -le "$#" ]; do
  a="${!i}"
  case "$a" in
    -h|--help)  usage; exit 0 ;;
    --config)   j=$((i + 1))
                [ "$j" -le "$#" ] || { echo "--config needs a path" >&2; exit 2; }
                CFG="${!j}"; i=$((i + 1)) ;;
    --config=*) CFG="${a#--config=}" ;;
  esac
  i=$((i + 1))
done

if [ "$(id -u)" -ne 0 ] && [ "$CFG" = "$DEFAULT_CFG" ]; then
  echo "must run as root: the live config is 0600 dod:dod" >&2
  echo "  sudo bash $0 $ORIG_ARGS" >&2
  exit 1
fi
[ -f "$CFG" ] || { echo "missing config: $CFG" >&2; exit 1; }

exec python3 - "$CFG" "$@" <<'PY'
import json, os, shutil, stat, subprocess, sys, time, urllib.request, urllib.error
from datetime import datetime

cfg_path = sys.argv[1]
argv = sys.argv[2:]

# ---- args ----------------------------------------------------------------
base_arg = model_arg = key_file = None
no_restart = False
i = 0
while i < len(argv):
    a = argv[i]
    if a in ("--config", "--base-url", "--model", "--key-file"):
        if a == "--config":
            i += 2; continue
        nxt = argv[i + 1] if i + 1 < len(argv) else ""
        if not nxt:
            sys.exit(f"{a} needs a value")
        if a == "--base-url": base_arg = nxt
        elif a == "--model":  model_arg = nxt
        else:                 key_file = nxt
        i += 2; continue
    if a.startswith("--config="):
        i += 1; continue
    if a.startswith("--base-url="): base_arg = a.split("=", 1)[1]; i += 1; continue
    if a.startswith("--model="):    model_arg = a.split("=", 1)[1]; i += 1; continue
    if a.startswith("--key-file="): key_file = a.split("=", 1)[1]; i += 1; continue
    if a == "--no-restart": no_restart = True; i += 1; continue
    if a in ("-h", "--help"):
        i += 1; continue
    sys.exit(f"unknown argument: {a}")

# Environment fallbacks, same names the installers use.
base_arg  = base_arg  or os.environ.get("TWELVEACTORS_API_BASE") or None
model_arg = model_arg or os.environ.get("TWELVEACTORS_MODEL") or None
key_env   = os.environ.get("TWELVEACTORS_API_KEY") or None

cfg = json.load(open(cfg_path))
old = {k: cfg.get(k) for k in ("base_url", "model", "api_key")}

def masked(cfg):
    k = str(cfg.get("api_key") or "")
    return f"set ({len(k)} chars)" if k and not k.startswith("<") else "NOT SET"

print("== current ==")
print(f"  file       {cfg_path}")
print(f"  base_url   {cfg.get('base_url')}")
print(f"  model      {cfg.get('model')}")
print(f"  api_key    {masked(cfg)}")
print()

# One handle for all prompts: mixing input() (buffered stdin) with getpass
# (/dev/tty) loses lines when someone pastes all three answers at once.
try:
    _tty = open("/dev/tty", "r")
except OSError:
    _tty = None
interactive = bool(_tty and _tty.isatty())

def ask(prompt, current, secret=False):
    if not interactive:
        return current
    shown = "" if secret else f" [{current}]"
    sys.stderr.write(f"{prompt}{shown}: ")
    sys.stderr.flush()
    fd = _tty.fileno()
    saved = None
    if secret:
        try:
            import termios
            saved = termios.tcgetattr(fd)
            quiet = list(saved)
            quiet[3] &= ~termios.ECHO
            termios.tcsetattr(fd, termios.TCSADRAIN, quiet)
        except Exception:
            saved = None
    try:
        line = _tty.readline()
    finally:
        if saved is not None:
            termios.tcsetattr(fd, termios.TCSADRAIN, saved)
            sys.stderr.write("\n")
            sys.stderr.flush()
    return line.strip() or current

new_base  = base_arg  if base_arg  is not None else ask("base_url", cfg.get("base_url", ""))
new_model = model_arg if model_arg is not None else ask("model", cfg.get("model", ""))
if key_file:
    new_key = open(key_file).read().strip()
    # Delete a key file once consumed, but never a pipe/process substitution.
    try:
        st = os.stat(key_file)
        if stat.S_ISREG(st.st_mode):
            os.remove(key_file)
        else:
            print(f"note: {key_file} is not a regular file - left in place")
    except OSError as e:
        print(f"note: could not remove {key_file}: {e}")
elif key_env:
    new_key = key_env.strip()
else:
    new_key = ask("api_key (input hidden)", cfg.get("api_key", ""), secret=True)

# ---- validate ------------------------------------------------------------
new_base = (new_base or "").strip().rstrip("/")
if not (new_base.startswith("http://") or new_base.startswith("https://")):
    sys.exit(f"base_url must start with http:// or https:// (got {new_base!r})")
if any(c.isspace() for c in new_base):
    sys.exit("base_url must not contain whitespace")
new_model = (new_model or "").strip()
if not new_model or any(c.isspace() for c in new_model):
    sys.exit(f"model id must be one word (got {new_model!r})")
new_key = (new_key or "").strip()
if not new_key or new_key.startswith("<"):
    sys.exit("api_key is empty or still a placeholder - the daemon would call nothing")
if any(c.isspace() for c in new_key):
    sys.exit("api_key must not contain whitespace or newlines")
if len(new_key) < 16:
    print(f"warning: key is only {len(new_key)} chars - unusual, continuing", file=sys.stderr)

changed = {k: v for k, v in (("base_url", new_base), ("model", new_model), ("api_key", new_key))
           if v != old[k]}

if not changed:
    print("nothing to change: all three values are already what you entered.")
    sys.exit(0)

# ---- write (backup, atomic replace, keep 0600 dod:dod) -------------------
ts = datetime.now().strftime("%Y%m%d-%H%M%S")
backup = f"{cfg_path}.bak.{ts}"
shutil.copy2(cfg_path, backup)
os.chmod(backup, 0o600)
print(f"backup     {backup}")

cfg.update(changed)
tmp = f"{cfg_path}.new.{os.getpid()}"
with open(tmp, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
    f.flush()
    os.fsync(f.fileno())
os.chmod(tmp, 0o600)
if os.geteuid() == 0:
    shutil.chown(tmp, "dod", "dod")
os.replace(tmp, cfg_path)

print("\n== after ==")
for k in ("base_url", "model"):
    mark = "changed" if k in changed else "kept"
    print(f"  {k:<9}  {cfg[k]}   ({mark})")
print(f"  api_key    {masked(cfg)}   ({'changed' if 'api_key' in changed else 'kept'})")

if os.geteuid() != 0:
    sys.exit(0)

# ---- probe the endpoint before restarting -------------------------------
print(f"\n== probe {cfg['base_url']}/models ==")
req = urllib.request.Request(cfg["base_url"] + "/models",
                             headers={"Authorization": f"Bearer {cfg['api_key']}"})
try:
    with urllib.request.urlopen(req, timeout=10) as r:
        body = r.read(200000).decode("utf-8", "replace")
    print(f"  HTTP {r.status}")
    try:
        ids = [m.get("id") for m in json.loads(body).get("data", [])]
    except Exception:
        ids = []
    if ids:
        print(f"  {len(ids)} models listed")
        print(f"  model '{cfg['model']}': " +
              ("present" if cfg["model"] in ids else "NOT LISTED - check the id"))
except urllib.error.HTTPError as e:
    print(f"  HTTP {e.code} {e.reason} - key or base_url is wrong; not restarting")
    sys.exit(1)
except Exception as e:
    print(f"  probe failed: {e}")
    print("  (some hosts do not serve /models; continuing)")

if no_restart:
    print("\n--no-restart given: config written, daemon left running on the old values.")
    sys.exit(0)

# ---- restart + verify ----------------------------------------------------
print("\n== restart ==")
subprocess.run(["systemctl", "restart", "twelveactors.service"], check=True)
time.sleep(3)
print("  " + subprocess.run(["systemctl", "is-active", "twelveactors.service"],
                             capture_output=True, text=True).stdout.strip())
try:
    with urllib.request.urlopen("http://127.0.0.1:8377/healthz", timeout=5) as r:
        h = json.loads(r.read().decode())
    print(f"  healthz ok={h.get('ok')} model={h.get('model')} turns={h.get('turns')} "
          f"errors={h.get('errors')}")
    if h.get("model") != cfg["model"]:
        print("  WARNING: healthz model does not match config - check the unit's --data path")
except Exception as e:
    print(f"  healthz failed: {e} - check journalctl -u twelveactors.service -n 30")
PY
