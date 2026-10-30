#!/usr/bin/env bash
# Apply Smart Content Creator's production AI route on the existing PocketBase.
# Only the PocketBase container is recreated. Existing WAHA/Shopify/Caddy untouched.
# Run from the authorized VPS root console after configure_ai_provider.sh.
set -Eeuo pipefail
umask 077

if [ "$(id -u)" -ne 0 ]; then
  echo "Root VPS console required." >&2
  exit 1
fi
BASE=/opt/scc-production
SRC=/home/chatgpt-admin/scc-production-prep
CONTAINER=scc-production-pocketbase-1
CONFIG="$BASE/compose.production.yml"
ENVFILE="$BASE/ai.env"

[ -s "$ENVFILE" ] || {
  echo "AI provider credentials are not configured; deployment blocked." >&2
  exit 1
}
if [ "$(stat -c '%a' "$ENVFILE")" != 600 ] ||
   [ "$(stat -c '%U' "$ENVFILE")" != root ]; then
  echo "AI secret file must be mode 0600 and owned by root." >&2
  exit 1
fi
for src in "$SRC/compose.production.yml" "$SRC/pb_hooks/scc_ai.pb.js"; do
  [ -f "$src" ] || { echo "Missing a required reviewed file." >&2; exit 1; }
done

docker image inspect local/scc-pocketbase:0.40.6 >/dev/null
docker network inspect indexes-waha_default >/dev/null
docker inspect "$CONTAINER" >/dev/null
[ "$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER")" = healthy ] ||
  { echo "PocketBase must already be healthy." >&2; exit 1; }
[ "$(docker inspect -f '{{json .HostConfig.PortBindings}}' "$CONTAINER")" = '{}' ] ||
  { echo "Refusing PocketBase public host-port exposure." >&2; exit 1; }

install -d -o root -g root -m 0755 "$BASE/pb_hooks"
OLD=$(mktemp "$BASE/.compose-rollback.XXXXXX")
NEW=$(mktemp "$BASE/.compose-candidate.XXXXXX")
FINISHED=0
restore() {
  status=$?
  trap - EXIT
  if [ "$FINISHED" -ne 1 ]; then
    if [ -f "$OLD" ]; then
      cp -p "$OLD" "$CONFIG"
      docker compose -f "$CONFIG" up -d --no-deps --no-build --force-recreate pocketbase >&2 || true
    fi
  fi
  rm -f "$OLD" "$NEW"
  exit "$status"
}
trap restore EXIT
cp -p "$CONFIG" "$OLD"
install -o root -g root -m 0644 "$SRC/compose.production.yml" "$NEW"
# Confirm build shape using the server's actual Docker Compose version.
docker compose -f "$NEW" config --quiet
python3 - "$NEW" <<'PY'
import sys,yaml
cfg=yaml.safe_load(open(sys.argv[1]))
svc=cfg["services"]["pocketbase"]
assert svc.get("ports") is None
assert svc.get("read_only") is True
assert "ALL" in svc["cap_drop"]
assert "--hooksDir=/pb_hooks" in svc["entrypoint"]
assert "/opt/scc-production/pb_hooks:/pb_hooks:ro" in svc["volumes"], "Expected read-only production hooks mount"
assert cfg["networks"]["wa"]["external"] is True
PY
# Stage and hash the hook only after all preflight assertions.
install -o root -g root -m 0644 "$SRC/pb_hooks/scc_ai.pb.js" "$BASE/pb_hooks/scc_ai.pb.js"
chmod 0644 "$NEW"
cp -p "$NEW" "$CONFIG"
docker compose -f "$CONFIG" up -d --no-deps --no-build --force-recreate pocketbase

for i in $(seq 1 30); do
  state=$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER")
  if [ "$state" = healthy ]; then break; fi
  sleep 2
done
[ "$state" = healthy ] || {
  echo "PocketBase is not healthy after hook deployment." >&2
  exit 1
}
[ "$(docker inspect -f '{{json .HostConfig.PortBindings}}' "$CONTAINER")" = '{}' ] ||
  { echo "Refusing published PocketBase host ports." >&2; exit 1; }

status=$(curl --silent --show-error --connect-timeout 4 --max-time 12 \
  -o /dev/null -w '%{http_code}' \
  -X POST -H 'Content-Type: application/json' \
  -d '{"mode":"chat","prompt":"hello"}' \
  https://creator-api.indexesstore.com/api/scc/ai/text)
[ "$status" = 401 ] || {
  echo "AI route is not enforcing anonymous authentication; blocked." >&2
  exit 1
}
FINISHED=1
echo "AI_GATEWAY_DEPLOYED: PocketBase healthy, private-only, route anonymous=401."
echo "Provider model invocation and billing are NOT confirmed by this check."
