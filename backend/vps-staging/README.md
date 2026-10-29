# Smart Content Creator — VPSDime isolated prototype

Status: **two loopback-only staging services**, **two empty databases**, **no public endpoint**, **not PocketBase**, **not production**.

## On the existing VPSDime machine

| Service | Host binding | Features | Default permission |
| --- | --- | --- | --- |
| `scc-staging-api.service` | `127.0.0.1:8789` | SQLite health/status/products | Read-only; bearer token in private local file |
| `scc-auth-preview.service` | `127.0.0.1:8790` | Experimental signup/login/logout, role-scoped draft products | Signup disabled by default; all other operations require session |

Services are user-level systemd units under `chatgpt-admin`. `Linger=no`: persistence after logout/reboot is **not guaranteed**. No Docker socket privileges or production ports were granted. WAHA, Shopify and Firebase are untouched.

## Files

- `schema.sql` / `init_db.py`: first 8-table EMPTY SQLite reference DB.
- `scc_staging_api.py` / `smoke_test.py`: read-only local API and health/auth smoke tests.
- `auth_preview.py`: experimental server-side auth and per-user draft product policy.
- `init_auth_preview.py`: separate 10-table EMPTY auth-preview DB (includes two auth-only tables), refuses to overwrite.
- `run_auth_preview.py`: starts auth-preview on loopback with registration **off**.
- `test_auth_preview.py`: temporary-database tests with registration enabled only inside tests.
- `.gitignore`: excludes local SQLite files and secret tokens.

All real data stays under `/home/chatgpt-admin/scc-vps-staging/data` on VPSDime, with restricted directory permissions. Never commit database files, sessions or credentials.

## Safe tests on a disposable checkout

```bash
cd backend/vps-staging
python3 -B init_db.py
python3 -B smoke_test.py
python3 -B init_auth_preview.py
python3 -B -m unittest -v test_auth_preview
```

These commands create **fresh local databases**. Do not run in a directory with preexisting data; the initializer refuses to overwrite it.

Tests exercise: no anonymous access; signup default off; email normalization; hashed password verification; hashed session token storage; logout and expired sessions; no self-assigned admin roles; different users cannot read each other's products; rejecting owner/role injection; validation; localhost-only bind.

## Flutter preview clients

- `lib/services/vps_staging_api.dart`: health probe, defaults to off; opt in via `SCC_VPS_API_URL`.
- `lib/services/vps_auth_preview_client.dart`: in-memory-session auth preview, defaults to off; opt in via `SCC_VPS_AUTH_PREVIEW_URL`.

Both clients enforce HTTPS. Since VPS services are on **localhost only**, they cannot currently be reached by the mobile app. A separately reviewed HTTPS gateway and real account provisioning must precede any integration. Never hardcode the local admin token.

## Production NOT ready

This is **not an official PocketBase server**, and its Python auth implementation has not undergone a production security audit. Email verification, password recovery, abuse/rate-limiting, refresh tokens, secure media storage and production RBAC are incomplete. Do **not** publish either listener or replace Firebase authentication with this prototype.

PocketBase will need its own verified binary, independent database, migrations and reviewed per-record access rules. The existing custom SQLite files are not PocketBase-native. WAHA backup verification was skipped by the user and the VPS has limited spare RAM and disk.
