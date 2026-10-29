#!/usr/bin/env bash
# Apply the creator-api Caddy host without changing the existing WAHA/Shopify routes.
# MUST run via an authorized root VPS console. Never executes via chatgpt-admin.
set -Eeuo pipefail
umask 077

readonly CADDY=indexes-waha-caddy-1
readonly PB=scc-production-pocketbase-1
readonly EXISTING=/opt/indexes-waha/apps/shopify-admin/indexes-waha/deploy/Caddyfile
readonly FRAGMENT=/opt/scc-production/creator-api.Caddyfile
readonly EXISTING_SHA=5d9abca634372248a58fb57f513416b36eba182ee783cdd72f28ca1fe7601ce0
readonly DOMAIN=creator-api.indexesstore.com
readonly EXPECTED_IP=185.197.31.233

if [ "$(id -u)" -ne 0 ]; then
  echo "Use the authorized VPS root console." >&2
  exit 1
fi
for f in "$EXISTING" "$FRAGMENT"; do
  if [ ! -f "$f" ]; then echo "Missing $f" >&2; exit 1; fi
  if [ "$(stat -c %U "$f")" != root ]; then
    echo "Unsafe ownership on $f" >&2; exit 1
  fi
done

# Refuse to override a legitimate concurrent change to the WAHA configuration.
printf '%s  %s\n' "$EXISTING_SHA" "$EXISTING" | sha256sum -c -
if grep -qF "$DOMAIN {" "$EXISTING"; then
  echo "Already contains $DOMAIN: manual review required; nothing changed." >&2
  exit 1
fi
grep -qF 'reverse_proxy scc-pocketbase:8090' "$FRAGMENT" || {
  echo "Fragment does not contain the expected internal upstream" >&2; exit 1;
}
grep -qF 'respond @private_admin "Not Found" 404' "$FRAGMENT" || {
  echo "Fragment does not restrict the admin endpoints" >&2; exit 1;
}
docker container inspect "$CADDY" >/dev/null
docker container inspect "$PB" >/dev/null
test "$(docker inspect -f '{{.State.Running}}' "$CADDY")" = true
test "$(docker inspect -f '{{.State.Health.Status}}' "$PB")" = healthy
test "$(docker inspect -f '{{json .HostConfig.PortBindings}}' "$PB")" = '{}'

# Both containers must be on the existing shared private network.
for container in "$CADDY" "$PB"; do
  docker inspect -f '{{json .NetworkSettings.Networks}}' "$container" |
    python3 -c 'import json,sys; n=json.load(sys.stdin); assert "indexes-waha_default" in n, "Container not on the expected network"'
done

getent ahostsv4 "$DOMAIN" | awk -v expected="$EXPECTED_IP" '$1 == expected { found=1 } END{exit !found}' || {
  echo "DNS does not yet resolve to the correct origin; aborting." >&2; exit 1;
}

candidate=$(mktemp /opt/scc-production/.Caddyfile-candidate.XXXXXX)
backup="$EXISTING.scc-backup.$(date -u +%Y%m%d-%H%M%S)"
changed=false
finish() {
  code=$?
  trap - EXIT
  if [ "$code" -ne 0 ] && [ "$changed" = true ] && [ -f "$backup" ]; then
    echo 'Attempting rollback of Caddy configuration...' >&2
    # Preserve the inode of the bind-mounted Caddyfile.
    cat "$backup" > "$EXISTING"
    docker exec "$CADDY" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >&2 || true
  fi
  rm -f "$candidate"
  exit "$code"
}
trap finish EXIT

cp -- "$EXISTING" "$candidate"
printf '\n\n' >> "$candidate"
cat "$FRAGMENT" >> "$candidate"

echo "=== PREVALIDATE with the running Caddy image/env; no live changes yet ==="
docker cp "$candidate" "$CADDY:/tmp/Caddyfile-scc-candidate"
docker exec "$CADDY" caddy validate --config /tmp/Caddyfile-scc-candidate --adapter caddyfile

# Preserve a pristine copy for rollback; do not expose credentials in stdout.
cp -a "$EXISTING" "$backup"
chmod 0600 "$backup"
printf '%s  %s\n' "$EXISTING_SHA" "$EXISTING" | sha256sum -c -

echo "=== RELOAD additional creator-api site only ==="
# WRITE IN PLACE: Docker bind-mounts the original file inode as :ro.
cat "$candidate" > "$EXISTING"
changed=true
docker exec "$CADDY" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile

# Caddy obtains certificates automatically, so do not silently claim TLS success.
echo "=== CHECK STRICT ORIGIN HTTPS ==="
for i in $(seq 1 15); do
  if health="$(curl -fsS --connect-timeout 3 --max-time 7 \
      --resolve "$DOMAIN:443:127.0.0.1" \
      "https://$DOMAIN/api/health")"; then
    if printf '%s' "$health" |
       python3 -c 'import json,sys; assert json.load(sys.stdin)["code"] == 200'; then
      for path in '/_/' '/api/collections/_superusers/auth-with-password'; do
        status=$(curl -sS --connect-timeout 3 --max-time 7 \
          --resolve "$DOMAIN:443:127.0.0.1" \
          -o /dev/null -w '%{http_code}' "https://$DOMAIN$path")
        if [ "$status" != 404 ]; then
          echo "UNSAFE: administrative route $path returned $status" >&2
          exit 1
        fi
      done
      echo "HTTPS_OK: trusted TLS + PocketBase 200 + administrative endpoints blocked."
      echo "Caddy rollback file saved at $backup"
      exit 0
    fi
  fi
  sleep 2
done
echo "HTTPS_PENDING: Caddy reloaded, but a trusted TLS certificate or API routing was not verified."
echo "Do not connect Flutter yet. Check authorized Caddy logs and rerun strict TLS check."
echo "Caddy rollback file saved at $backup"
