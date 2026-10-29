#!/usr/bin/env bash
# Root-only one-time apply after files are staged to /opt/scc-production.
# PocketBase is the only container stopped/recreated; WAHA/Caddy/Shopify untouched.
set -Eeuo pipefail
umask 077

BASE=/opt/scc-production
CONTAINER=scc-production-pocketbase-1
VOLUME=scc_production_pocketbase_data
MIG=1793305000_scc_schema_v1.js
EXPECTED=bc9663838bf94bb4a731aa575703f073a4a3795fbe2e53932e4197a85aa5b7e9
BACKUP_DIR=/root/scc-backups
BACKUP="scc-pre-schema-$(date -u +%Y%m%d-%H%M%S).tar.gz"
ALPINE="alpine@sha256:ff7f0c727dd796aa36787bfcd9a64bf35a6ce72a73451b3359fde849b6703d63"
IMAGE="local/scc-pocketbase:0.40.6"

[ "$(id -u)" -eq 0 ] || { echo 'Run from authorized root console' >&2; exit 1; }
[ -f "$BASE/pb_migrations/$MIG" ] || { echo 'Missing migration' >&2; exit 1; }
cd "$BASE"
printf '%s  %s\n' "$EXPECTED" "$BASE/pb_migrations/$MIG" | sha256sum -c -
[ "$(stat -c '%U' "$BASE")" = root ] || { echo 'Production folder must be root-owned' >&2; exit 1; }
[ "$(stat -c '%U' "$BASE/pb_migrations/$MIG")" = root ] || { echo 'Migration must be root-owned' >&2; exit 1; }

docker network inspect indexes-waha_default >/dev/null
docker volume inspect "$VOLUME" >/dev/null
docker image inspect "$IMAGE" >/dev/null
docker image inspect "$ALPINE" >/dev/null
docker inspect "$CONTAINER" >/dev/null
test "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" = true
# Block accidental public host-port exposure.
test "$(docker inspect -f '{{json .HostConfig.PortBindings}}' "$CONTAINER")" = '{}'
docker compose -f "$BASE/compose.production.yml" config --quiet
[ -z "$(docker compose -f "$BASE/compose.production.yml" config --format json | python3 -c 'import sys,json; print(json.load(sys.stdin)["services"]["pocketbase"].get("ports",""))' 2>/dev/null)" ] || { echo 'Ports must stay unpublished' >&2; exit 1; }

install -d -m 0700 "$BACKUP_DIR"
echo "=== STOP PocketBase only ==="
docker stop "$CONTAINER" >/dev/null

recover() {
  status=$?
  if [ "$status" -ne 0 ]; then
    echo 'Schema apply failed; attempting to restart PocketBase only.' >&2
    docker start "$CONTAINER" >/dev/null 2>&1 || true
  fi
}
trap recover EXIT

echo "=== CONSISTENT BACKUP ==="
docker run --rm --network none --cap-drop ALL \
  --security-opt no-new-privileges:true \
  -v "$VOLUME:/source:ro" -v "$BACKUP_DIR:/backup" \
  "$ALPINE" sh -c 'tar -czf "/backup/$1" -C /source .' sh "$BACKUP"

tar -tzf "$BACKUP_DIR/$BACKUP" >/dev/null
TMP="$(mktemp -d /root/scc-schema-verify.XXXXXX)"
trap 'rm -rf "$TMP"; recover' EXIT
tar -xOzf "$BACKUP_DIR/$BACKUP" ./data.db > "$TMP/data.db"
python3 - "$TMP/data.db" <<'PY'
import sqlite3,sys
con=sqlite3.connect(f"file:{sys.argv[1]}?mode=ro",uri=True)
result=con.execute("PRAGMA integrity_check").fetchone()[0]
con.close()
assert result=="ok", "SQLite backup integrity failure"
print("Backup SQLite integrity: ok")
PY

echo "=== APPLY schema OFFLINE in an isolated one-off process ==="
docker run --rm --network none --user 10001:10001 \
  --read-only --tmpfs /tmp:rw,nosuid,nodev,size=32m \
  --cap-drop ALL --security-opt no-new-privileges:true \
  -v "$VOLUME:/pb_data" \
  -v "$BASE/pb_migrations:/pb_migrations:ro" \
  --entrypoint /usr/local/bin/pocketbase "$IMAGE" \
  migrate up --dir=/pb_data --migrationsDir=/pb_migrations --automigrate=false

echo "=== START updated PocketBase only ==="
docker compose -f "$BASE/compose.production.yml" \
  up -d --no-deps --no-build --force-recreate pocketbase

echo "=== WAIT FOR HEALTH ==="
for i in $(seq 1 30); do
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}absent{{end}}' "$CONTAINER")"
  if [ "$health" = healthy ]; then break; fi
  sleep 2
done
test "$health" = healthy || { echo "PocketBase did not become healthy: $health" >&2; exit 1; }
test "$(docker inspect -f '{{json .HostConfig.PortBindings}}' "$CONTAINER")" = '{}'
docker exec "$CONTAINER" wget -qO- http://127.0.0.1:8090/api/health
echo
echo "MIGRATION_OK: PocketBase healthy; no public host ports."
echo "LOCAL_BACKUP=$BACKUP_DIR/$BACKUP"
