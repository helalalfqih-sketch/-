# Smart Content Creator — production deployment foundation

**Status: NOT DEPLOYED. No PocketBase binary downloaded or run. No HTTPS endpoint live.**

## Verified environment (2026-10-29)
- VPS: waha-shopify-test (VPSDime), 2 vCPU, 4 GiB RAM, ~4.8 GB free disk and ~1.5 GiB available RAM.
- DNS: creator-api.indexesstore.com resolves to 185.197.31.233.
- Existing Caddy runs in the WAHA Docker Compose project on ports 80/443; its Caddyfile is root-owned.
- Direct TLS probe to the origin at the new hostname FAILED; no virtual host or certificate for creator-api was configured.
- Desktop Commander runs as chatgpt-admin without Docker daemon permissions; do not bypass tool restrictions.

## Architecture
- Official verified PocketBase executable only (NO third-party PocketBase images).
- A distinct Docker Compose project (`scc-production`) with its own named data volume.
- No host ports published. The service joins the existing Docker network `indexes-waha_default` and advertises only `scc-pocketbase:8090` internally.
- The new `creator-api.indexesstore.com` Caddy block must be **added**, not replace existing WAHA/Shopify routes, after service & security verification.
- Root/superuser management endpoints are denied by the proposed Caddy block; private admin setup must use authorized on-host tooling.
- Server-side auth and owner-only collection access must be implemented and tested BEFORE any public routing. `schema-contract.json` is only a design, not a migration.

## Supply-chain verification (prerequisite)
1. Choose a maintained **official** PocketBase release after checking official release notes and architecture compatibility.
2. Obtain the linux_amd64 ZIP and its trusted expected SHA256 from an independently verified release source.
3. Place the ZIP outside the GitHub repository. Run `python3 verify_release_zip.py /secure/path/release.zip VERIFIED_SHA256`.
4. Review the pinned Alpine image digest for `ALPINE_IMAGE` and set `POCKETBASE_VERSION` in a private runtime environment, never in Git.
5. Do not build or start containers until the binary, Alpine digest and collection migrations have been verified.

## Operator deployment prerequisites
- root-authorized review and apply of Compose / Caddy changes; existing WAHA stack must remain online.
- Docker network `indexes-waha_default` available; the Caddy container already belongs to that network.
- New persistent volume with restore plan and isolated admin account.
- PocketBase migration for Auth users, products, media, AI tasks, subscriptions and audit records; enforce authorization at the service.
- Configure secure emails, password reset, abuse controls and logs without exposing secrets.
- Verify TLS certificate, HTTP routing, CORS restrictions, error handling and rollback before enabling Flutter.

## Conditions for release
- Login/signup/reset work for distinct users, with admin role not client-modifiable.
- A user's products/media are inaccessible to another user in automated negative tests.
- AI calls are authenticated, quota-limited and actually use configured provider keys on the server (not the old mock function).
- New Android APK/AAB builds succeed with Firebase disabled in the intended release configuration.
- Mobile tests on a real device pass; production database starts empty.
- WAHA, Shopify, and `account.indexesstore.com` remain unaffected.

## Safety
Do not map 8090 to the host or publish raw PocketBase admin ports. Do not expose old Python preview ports 8789/8790. Do not use the custom SQLite staging databases as PocketBase internal data. WAHA backup verification was skipped for staging by user choice; this carries loss risk and requires a separate release decision.
