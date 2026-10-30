# Smart Content Creator — PocketBase on VPSDime

## Verified deployed state (29 Oct 2026)

- **PocketBase v0.40.6 is running privately** as `scc-production-pocketbase-1` on VPSDime, with a separately persistent Docker volume `scc_production_pocketbase_data`. No host port for PocketBase is published.
- The first superuser was provisioned privately. Public superuser URLs are hidden by Caddy; NEVER add credentials/tokens to Git or chat.
- Production migration `1793305000_scc_schema_v1.js` **WAS APPLIED** by the authorized root operator, with exact SHA256 verification, a new consistent local backup, SQLite integrity OK, and `MIGRATION_OK: PocketBase healthy; no public host ports.`
- The original root-managed Caddyfile was safely amended with the separate `creator-api.indexesstore.com` virtual host; certificate issuance completed and both the API and administrative-route guards passed the operator's `HTTPS_OK` check.
- Independently checked from the VPS: strict public HTTPS returned 200 and `ssl_verify_result=0` for `https://creator-api.indexesstore.com/api/health`. Let's Encrypt issued a certificate for the correct SAN, valid from 2026-10-29 to 2027-01-27.
- `/_`, `/_/` and superuser/auth administrative routes returned 404; anonymous user signup returned 403; unauthenticated products returned 0 records, and user_roles and audit_events returned 403. Verify all endpoint policy after future upgrades.
- WAHA ping still returned 200/pong; the original Shopify primary domain remains `indexesstore.com`.
- Initial local backups were created, including pre-schema archive `/root/scc-backups/scc-pre-schema-20261029-200639.tar.gz`. An off-site encrypted backup and restore drill remain outstanding.
- The server is RAM and disk constrained (~1.4 GiB available RAM and ~4.7 GiB free disk). Enforce media quotas and plan external object storage before onboarding users.
- PocketBase currently returns `Access-Control-Allow-Origin: *`. This is not a standalone authorization bypass, but requires an explicit origin policy before browser/web release.
- **Not production-ready as a complete app.** Existing Flutter app still starts Firebase; a separately tested PocketBase client exists but is not integrated into the real login/catalog/AI flows.

## Implemented and locally tested

`pb_migrations/1793305000_scc_schema_v1.js`:
- Keeps the built-in PocketBase `users` authentication collection (no parallel auth database) and temporarily disables public registration.
- Adds `products`, `media_assets`, `content_items`, `ai_jobs`, `subscriptions`, `audit_events`, `user_roles`.
- Requires authenticated owner for personal product/content/media CRUD, forbids transferring owner, locks user-managed roles/subscriptions/AI job results and audit records.
- Marks private media file fields as `protected` and limits individual uploads to 25 MiB.
- Uses integer minor currency units to avoid floating-point prices.

`test_access_policy.py` passed against the same **official PocketBase 0.40.6 binary**, using two temporary users and an ephemeral localhost database, deleted when tests completed. Confirmed anonymous signup forbidden; owner-only products/drafts; cross-user read/change/delete denial; spoofed owner creation denial; self role/premium/AI-result/audit write denial; self-verification denial; protected PNG upload and public file read denial.

Flutter opt-in client `lib/services/pocketbase/scc_pocketbase_client.dart` supports normal user login/refresh, protected device token storage, private products and file uploads. It is **not wired into Flutter startup yet**, and its CI unit tests must pass before use. Build-time opt-in: `--dart-define=SCC_POCKETBASE_URL=https://creator-api.indexesstore.com` only after HTTPS is live.

## Authorized root-only production schema apply

Use the **VPSDime root console**, not the remote unprivileged Desktop Commander. Run exactly once initially; repeat execution is designed to be idempotent but makes another backup:

```bash
set -e
SOURCE=/home/chatgpt-admin/scc-production-prep
TARGET=/opt/scc-production

install -d -o root -g root -m 0755 "$TARGET/pb_migrations"
install -o root -g root -m 0644   "$SOURCE/pb_migrations/1793305000_scc_schema_v1.js"   "$TARGET/pb_migrations/1793305000_scc_schema_v1.js"
install -o root -g root -m 0644   "$SOURCE/compose.production.yml" "$TARGET/compose.production.yml"
install -o root -g root -m 0700   "$SOURCE/apply_production_schema.sh" "$TARGET/apply_production_schema.sh"

echo "bc9663838bf94bb4a731aa575703f073a4a3795fbe2e53932e4197a85aa5b7e9  $TARGET/pb_migrations/1793305000_scc_schema_v1.js" | sha256sum -c -

bash "$TARGET/apply_production_schema.sh"
```

This root-only script guards against accidental public port publishing, verifies the pinned migration SHA, stops **PocketBase only**, creates a fresh consistent local backup, validates its SQLite integrity, applies the migration in a network-isolated one-off container, and recreates **PocketBase only** from root-owned runtime config. It checks PocketBase health and keeps Caddy/Shopify/WAHA unchanged.

Never paste superuser passwords or first-run setup URLs into chat or store them in files.

## Next production release gates

1. Inspect production collection schema and confirm migration history, health, and zero public host ports.
2. Complete off-site encrypted backups, restore drill, mail delivery, password reset, account verification and abuse/rate controls.
3. Review current PocketBase release/security advisories and update safely from 0.40.6 before external exposure.
4. Prepare and validate Caddy host block `creator-api.indexesstore.com` in existing root-owned WAHA stack; never replace existing virtual hosts. Verify public HTTPS certificate and reject dashboard/superuser API endpoints.
5. Integrate normal user PocketBase auth/product flows into Flutter app startup. Current `lib/main.dart` and other services still initialize Firebase.
6. Implement real AI gateway with server-only provider keys and job quotas; the legacy Firebase function currently contains a placeholder AI response, not a real backend.
7. Run device testing, signed APK/AAB and release gate checks. **NOT PRODUCTION-READY YET**.

Never expose old staging Python ports 8789/8790. Never publish PocketBase port 8090 on the host. The official PocketBase release is pre-v1: schema and app upgrade discipline is important.


## HTTPS rollout record — APPLIED and VERIFIED

The root operator installed the reviewed creator-api Caddy fragment and ran `enable_creator_https.sh`. Caddy validated the full candidate config, reloaded in place, and returned `HTTPS_OK` after TLS certificate issuance. No published PocketBase host ports. The original Caddy routes remained in the file.

For future Caddy changes, **do not rerun the one-time apply script blindly**: its pre-change SHA guard intentionally expects the old config and will stop once the new virtual host exists. Treat future edits as a new reviewed change. Rollback file is retained at `/opt/indexes-waha/apps/shopify-admin/indexes-waha/deploy/Caddyfile.scc-backup.20261029-202038` on the VPS.

`CORS: *` is currently seen on OPTIONS requests. Keep authentication and collection authorization enforceable server-side. Restrict browser origins before a web release.

