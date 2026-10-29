# Smart Content Creator - VPSDime staging API

This is a local-only read-only reference backend using Python 3.12 and SQLite, NOT PocketBase or a production auth service.

## Isolation
- `scc_staging_api.py` listens only at `127.0.0.1:8789`.
- No public endpoint, no Docker or Firebase writes, no user registration.
- Local `data/.local_admin_token` uses owner-only permissions; NEVER put it in Flutter, Git or messages.
- Eight empty SQLite tables are a prototype. PocketBase needs its own internal database, collections and migrations.
- Keep the existing WAHA Docker stack untouched.

## Offline test (new disposable checkout only)
```bash
python3 init_db.py
python3 smoke_test.py
```
The initializer refuses to overwrite existing data. Expected: health 200, unauthorized 401, empty data 200, writes 405, loopback-only.

## VPS run status
A separate `systemd --user` service on VPSDime runs the staging API locally. Linger=no; it may terminate after user logout or reboot.

## Production restrictions
Before client access, use a verified official PocketBase release (or another audited backend) with real auth, role/ownership policy, restricted media, rate limits, secure TLS, and recovery safeguards. Firebase is not migrated and remains unchanged.
