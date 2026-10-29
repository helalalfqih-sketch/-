# VPSDime staging backend — NOT PRODUCTION

**Source branch:** `shorebird-test`  
**Preview branch:** `codex/scc-vps-backend-preview-20261029`  
**Host:** `waha-shopify-test` (VPSDime) — existing WAHA must remain untouched.

## Completed on VPS

A standalone, EMPTY SQLite prototype was created under:

`/home/chatgpt-admin/scc-vps-staging/data/smart_content_creator.sqlite3`

Eight tables: users, user_roles, products, media_assets, content_items, ai_jobs, subscriptions, audit_events.

A local-only Python HTTP read-only API was created at:

`/home/chatgpt-admin/scc-vps-staging/scc_staging_api.py`

A smoke test was executed and passed: `GET /healthz` 200; unauthorized `GET /v1/status` 401; authorized status 200 with zero rows; authorized products empty; write request 405. The server used a random loopback port for testing and was stopped afterward.

The current API is **not PocketBase**. No official PocketBase binary was installed, and the SQLite schema must **not** be used as a PocketBase system database.

## Flutter preview integration

`lib/services/vps_staging_api.dart` adds an explicitly opt-in HTTPS health check.
It does not modify startup, routes, login, existing Firebase services, or existing data.

By default, `SCC_VPS_API_URL` is empty, so **no VPS request is made**.

Once a separate HTTPS endpoint is secured, the opt-in build flag can be supplied:

```sh
flutter run --dart-define=SCC_VPS_API_URL=https://YOUR-PROTECTED-BACKEND-DOMAIN
```

**Do not** point this client at `127.0.0.1` from a mobile app, embed an administrator token in Flutter, or enable plain HTTP in a release build.

## Next steps (not done)

1. Safely obtain and verify a supported official PocketBase release, when available, and run it isolated with a new private data directory and localhost-only listener. The existing SQLite database is only a reference schema.
2. Implement server-enforced user roles, ownership, and secure files; define migrations supported by the selected PocketBase release.
3. Create real Flutter repositories for Auth, products, media, and jobs behind feature flags, with mocks and auth tests.
4. Test against an authenticated HTTPS endpoint, then enable a separate preview. Do not change the Firebase-connected production app without explicit authorization.
5. Review remaining disk/RAM and WAHA backup policy before leaving any new service running.

## Security caveat

The user requested skipping verification of WAHA backups for this isolated staging work. WAHA data remains at risk on host failure; do not assume backups exist. No Firebase data was transferred, no production API published, and no WAHA/Docker services restarted.
