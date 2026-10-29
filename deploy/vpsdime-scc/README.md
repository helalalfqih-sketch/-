# Smart Content Creator — PocketBase on VPSDime

## Actual state (29 Oct 2026)

- **PocketBase v0.40.6 installed and running privately** on the existing VPS under the Docker container `scc-production-pocketbase-1`. Confirmed previously `healthy` and `/api/health` returned HTTP 200. Not currently visible from the public internet.
- Owner created the first superuser privately through the VPS root console. Credentials and setup links are NEVER committed to Git.
- Docker volume `scc_production_pocketbase_data` persists the `data.db` file.
- A first **local** backup was created under `/root/scc-backups/`; its archive passed the TAR listing test. A second, off-VPS restore verification is still required.
- **The production database schema has not been migrated**. Current production user registration is not yet locked by the pending migration, so do **not** expose the API publicly.
- Existing WAHA, Shopify, and Caddy routes must be preserved. DNS `creator-api.indexesstore.com` resolves to 185.197.31.233, but TLS for the hostname has not been configured.
- Runtime migration files were staged (without execution) under `/home/chatgpt-admin/scc-production-prep/`.
- The remote ChatGPT connection uses an unprivileged `chatgpt-admin` user: no Docker daemon access. Only the authorized VPS root console can apply the production migration.

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
