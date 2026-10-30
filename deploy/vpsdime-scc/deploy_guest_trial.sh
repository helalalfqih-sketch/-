#!/usr/bin/env bash
# Execute only after owner approval from the authorized VPS root console.
set -Eeuo pipefail
umask 077
BASE=/opt/scc-production
SRC=/home/chatgpt-admin/scc-production-prep
CONTAINER=scc-production-pocketbase-1
IMAGE=local/scc-pocketbase:0.40.6
VOLUME=scc_production_pocketbase_data
MIG=1793370000_guest_devices.js
ALPINE=alpine@sha256:ff7f0c727dd796aa36787bfcd9a64bf35a6ce72a73451b3359fde849b6703d63
[ "$(id -u)" -eq 0 ] || { echo 'Authorized root console required'; exit 1; }
[ "$(stat -c '%U:%a' "$BASE/ai.env")" = root:600 ]
[ "$(stat -c '%U' "$BASE")" = root ]
for file in "pb_migrations/$MIG" pb_hooks/scc_guest.pb.js pb_hooks/scc_ai.pb.js; do
  [ -s "$SRC/$file" ] || { echo 'Missing reviewed guest trial files'; exit 1; }
done
docker image inspect "$IMAGE" >/dev/null
docker image inspect "$ALPINE" >/dev/null
[ "$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER")" = healthy ]
[ "$(docker inspect -f '{{json .HostConfig.PortBindings}}' "$CONTAINER")" = '{}' ]
docker compose -f "$BASE/compose.production.yml" config --quiet
BACKUP=$(mktemp -d /root/scc-guest-backup.XXXXXX)
cp -p "$BASE/ai.env" "$BACKUP/ai.env"
cp -a "$BASE/pb_hooks" "$BACKUP/pb_hooks"
install -d -m 0755 "$BACKUP/migrations"
install -m 0644 "$SRC/pb_migrations/$MIG" "$BACKUP/migrations/$MIG"
FINISHED=0
STOPPED=0
cleanup() {
  status=$?
  trap - EXIT
  if [ "$FINISHED" -ne 1 ] && [ "$STOPPED" -eq 1 ]; then
    cp -p "$BACKUP/ai.env" "$BASE/ai.env"
    cp -a "$BACKUP/pb_hooks/." "$BASE/pb_hooks/"
    if [ ! -f "$BACKUP/pb_hooks/scc_guest.pb.js" ]; then rm -f "$BASE/pb_hooks/scc_guest.pb.js"; fi
    docker compose -f "$BASE/compose.production.yml" up -d --no-deps --no-build --force-recreate pocketbase >&2 || true
    echo 'Trial activation failed; previous hooks and environment restored. Additive schema may remain.' >&2
  fi
  echo "Local backup retained: $BACKUP"
  exit "$status"
}
trap cleanup EXIT
STOPPED=1
docker stop "$CONTAINER" >/dev/null
docker run --rm --network none --cap-drop ALL --security-opt no-new-privileges:true \
  -v "$VOLUME:/source:ro" -v "$BACKUP:/backup" "$ALPINE" \
  sh -c 'tar -czf /backup/data.tar.gz -C /source .'
tar -xOzf "$BACKUP/data.tar.gz" ./data.db > "$BACKUP/check.db"
python3 - "$BACKUP/check.db" <<'PY'
import sqlite3,sys
with sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True) as con:
    assert con.execute('PRAGMA integrity_check').fetchone()[0]=='ok'
PY
rm "$BACKUP/check.db"
docker run --rm --network none --user 10001:10001 --read-only \
  --tmpfs /tmp:rw,nosuid,nodev,size=32m --cap-drop ALL --security-opt no-new-privileges:true \
  -v "$VOLUME:/pb_data" -v "$BACKUP/migrations:/pb_migrations:ro" \
  --entrypoint /usr/local/bin/pocketbase "$IMAGE" \
  migrate up --dir=/pb_data --migrationsDir=/pb_migrations --automigrate=false
install -o root -g root -m 0644 "$SRC/pb_migrations/$MIG" "$BASE/pb_migrations/$MIG"
for hook in scc_guest.pb.js scc_ai.pb.js; do
  install -o root -g root -m 0644 "$SRC/pb_hooks/$hook" "$BASE/pb_hooks/$hook"
done
python3 - "$BASE/ai.env" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
lines=[line for line in p.read_text().splitlines() if not line.startswith('SCC_GUEST_ENABLED=')]
p.write_text('\n'.join(lines)+'\nSCC_GUEST_ENABLED=1\n')
PY
docker compose -f "$BASE/compose.production.yml" up -d --no-deps --no-build --force-recreate pocketbase
for i in $(seq 1 30); do
  health=$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER")
  [ "$health" = healthy ] && break
  sleep 2
done
[ "$health" = healthy ]
[ "$(docker inspect -f '{{json .HostConfig.PortBindings}}' "$CONTAINER")" = '{}' ]
check() {
  curl --silent --show-error --connect-timeout 4 --max-time 12 -o /dev/null -w '%{http_code}' \
    -X POST -H 'Content-Type: application/json' -d '{}' "https://creator-api.indexesstore.com$1"
}
[ "$(check /api/scc/guest/session)" = 400 ]
[ "$(check /api/scc/ai/text)" = 401 ]
FINISHED=1
echo 'GUEST_TRIAL_ENABLED: health and guard checks passed. Real Android/OpenAI flow still requires verification.'
