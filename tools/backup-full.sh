#!/usr/bin/env bash
# Full, revertible backup of the DoD:S server + bot stack + twelveactors bridge.
# Run as root:  sudo /home/admin1/dods-backup.sh
set -euo pipefail

STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="/home/admin1/backups/dods-$STAMP"
OWNER="admin1:admin1"

# The bridge was renamed once: bivouac -> twelveactors. Detect the live layout so
# this script backs up the right paths before AND after that migration.
if [ -d /opt/twelveactors ]; then
  OPT=/opt/twelveactors
  BRIDGE_UNIT=twelveactors.service
  DATA_DIR=/srv/dods/dod/addons/sourcemod/data/twelveactors
  RADIO=/usr/local/bin/ta-radio
else
  OPT=/opt/bivouac
  BRIDGE_UNIT=bivouac.service
  DATA_DIR=/srv/dods/dod/addons/sourcemod/data/bivouac
  RADIO=/usr/local/bin/biv-radio
fi
DB_TAG="$(basename "$DATA_DIR")"

mkdir -p "$DEST"
echo "==> backup dir: $DEST"

# ---------- 0. capture live state (for a faithful revert) ----------
{
  echo "# State at backup time"
  echo
  echo "## date"; date -Is
  echo
  echo "## uname"; uname -a
  echo
  echo "## os"; grep -E '^(PRETTY_NAME|ID|BUILD_ID)=' /etc/os-release
  echo
  echo "## services"
  systemctl is-enabled dods.service dods-update.timer "$BRIDGE_UNIT" || true
  systemctl is-active dods.service "$BRIDGE_UNIT" || true
  systemctl show -p ExecStart -p User -p Group -p WorkingDirectory -p Nice dods.service
  echo
  echo "## $BRIDGE_UNIT"
  systemctl show -p ExecStart -p User -p Group -p WorkingDirectory "$BRIDGE_UNIT" 2>/dev/null || echo "$BRIDGE_UNIT not present"
  echo
  echo "## listen sockets"
  ss -lunp | grep -E '27015|:2701' || true
  ss -ltnp | grep -E ':2701|:8377' || true
  echo
  echo "## live query"
  /usr/local/bin/dods-query 127.0.0.1 || true
  echo
  echo "## bridge health"
  curl -fsS --max-time 3 http://127.0.0.1:8377/healthz || echo "healthz unreachable"
  echo
  echo "## versions (pacman)"
  pacman -Q steamcmd lib32-glibc lib32-gcc-libs lib32-zlib 2>/dev/null || true
  echo
  echo "## explicit package list"
  pacman -Qqe
} > "$DEST/STATE.md" 2>&1

# ---------- 1. the game tree (includes addons/sourcemod/data/*, plugins, cfgs) ----------
echo "==> tar /srv/dods"
tar -C /srv --zstd -cf "$DEST/01-srv-dods.tar.zst" dods

# ---------- 2. system files, helpers, admin docs ----------
echo "==> tar system + helpers"
SYS_FILES=(/etc/systemd/system/dods.service
           /etc/systemd/system/dods-update.service
           /etc/systemd/system/dods-update.timer
           /var/lib/dods
           /usr/local/bin/dods-query
           /usr/local/bin/dods-console
           /usr/local/bin/dods-players
           /usr/local/bin/dods-rcon)
for u in bivouac.service twelveactors.service; do
  [ -e "/etc/systemd/system/$u" ] && SYS_FILES+=("/etc/systemd/system/$u")
done
for r in biv-radio ta-radio; do
  [ -e "/usr/local/bin/$r" ] && SYS_FILES+=("/usr/local/bin/$r")
done
tar -P --zstd -cf "$DEST/02-system.tar.zst" "${SYS_FILES[@]}"

# ---------- 2b. the bridge: deployed package, backups, and the source tree ----------
echo "==> tar $DB_TAG bridge + source"
tar -P --zstd -cf "$DEST/03-twelveactors.tar.zst" \
  "$OPT" \
  /home/admin1/twelveactors \
  /home/admin1/dods-backup.sh

# ---------- 2c. consistent sqlite copies (tar of a live WAL db is not atomic) ----------
echo "==> sqlite .backup snapshots"
mkdir -p "$DEST/04-sqlite"
for db in /srv/dods/dod/addons/sourcemod/data/*/*.sqlite; do
  [ -f "$db" ] || continue
  name="$(basename "$(dirname "$db")")-$(basename "$db")"
  sqlite3 "$db" ".backup '$DEST/04-sqlite/$name'" && echo "ok $db -> 04-sqlite/$name"
done

install -m 0644 /home/admin1/dods-source-server-runbook.md "$DEST/" 2>/dev/null || true
install -m 0644 /home/admin1/dods-bot-stack-runbook.md "$DEST/" 2>/dev/null || true
install -m 0644 /srv/dods/ADMIN.md "$DEST/ADMIN.md" 2>/dev/null || true

# ---------- 3. integrity ----------
echo "==> checksums"
( cd "$DEST" && sha256sum *.tar.zst > SHA256SUMS )

echo "==> verifying archives"
before=$(find /srv/dods -type f | wc -l)
after=$(tar --zstd -tf "$DEST/01-srv-dods.tar.zst" | grep -v '/$' | wc -l)
{
  echo "files in /srv/dods now : $before"
  echo "files in archive       : $after"
  echo "tar listing errors     : $(tar --zstd -tf "$DEST/01-srv-dods.tar.zst" 2>&1 >/dev/null | wc -l)"
  if [ "$after" -ge "$before" ]; then echo "RESULT: OK"; else echo "RESULT: MISMATCH"; fi
  echo
  echo "03-twelveactors members:"; tar --zstd -tf "$DEST/03-twelveactors.tar.zst" 2>/dev/null | grep -c . || true
  echo "04-sqlite files:"; ls -l "$DEST/04-sqlite" 2>/dev/null || true
} | tee "$DEST/VERIFY.txt"

# ---------- 4. restore instructions ----------
cat > "$DEST/RESTORE.md" <<EOF
# Restore — DoD:S server backup $STAMP

Archives are owned root, extracted as root. Server user is \`dod\` (uid 960).

## Fast path: back to this exact state

\`\`\`bash
sudo systemctl stop dods $BRIDGE_UNIT      # and disable the update timer while restoring
sudo systemctl stop dods-update.timer
cd $DEST
sha256sum -c SHA256SUMS                     # expect 3 OKs

# put the current trees aside instead of deleting them
sudo mv /srv/dods /srv/dods.broken-\$(date +%F-%H%M)
sudo mv $OPT $OPT.broken-\$(date +%F-%H%M)

sudo tar -C /srv --zstd -xpf 01-srv-dods.tar.zst
sudo tar -P --zstd -xpf 02-system.tar.zst   # units, /var/lib/dods, helpers
sudo tar -P --zstd -xpf 03-twelveactors.tar.zst
sudo systemctl daemon-reload
sudo systemctl enable --now dods.service dods-update.timer $BRIDGE_UNIT
sleep 45
dods-query 127.0.0.1
curl -s http://127.0.0.1:8377/healthz
\`\`\`

\`dods-query\` should report the map from STATE.md with 12 bots and no VAC. If it does not,
\`sudo journalctl -u dods -n 100\` — MetaMod/bootstrap errors mean the ownership or the
\`addons/\` tree did not survive extraction: \`sudo chown -R dod:dod /srv/dods\`.

## sqlite state

\`04-sqlite/\` holds consistent \`.backup\` copies of every database under
\`data/*/\` (state.sqlite, clips.sqlite). A tar of a running WAL database is not
atomic; these are. To use one, stop the bridge and copy it over:

\`\`\`bash
sudo systemctl stop $BRIDGE_UNIT
sudo cp $DEST/04-sqlite/$DB_TAG-state.sqlite $DATA_DIR/state.sqlite
sudo rm -f $DATA_DIR/state.sqlite-wal \
           $DATA_DIR/state.sqlite-shm
sudo chown dod:dod $DATA_DIR/state.sqlite
sudo systemctl start $BRIDGE_UNIT
\`\`\`

## Selective restore

- Only configs: extract the single path from the big archive, e.g.
  \`sudo tar -C /srv --zstd -xpf 01-srv-dods.tar.zst dod/dod/cfg/server.cfg\`
  (paths inside 01- are relative to /srv, so they start with \`dods/\`).
- Only the bot stack: same archive, path \`dods/dod/addons/\`.
- Only units: from 02-, path \`etc/systemd/system/dods.service\` etc.
- Only the bridge: from 03-, path \`${OPT#/}\` or \`home/admin1/twelveactors\`.

## What is NOT in here

- Steam content itself is reproducible: \`steamcmd +app_update 232290\` (see the install runbook).
- Nothing outside /srv/dods, /var/lib/dods, the systemd units, /usr/local/bin/dods-*,
  $RADIO, $OPT, /home/admin1/twelveactors, and the runbooks in
  /home/admin1.
- Steam GSLT / account credentials: anonymous login, nothing stored.
EOF

chown -R "$OWNER" "$DEST"
echo
echo "==> done: $DEST"
du -sh "$DEST"; ls -lh "$DEST"
