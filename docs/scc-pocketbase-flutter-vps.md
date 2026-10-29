# Smart Content Creator — PocketBase Flutter integration

## Current scope (verified in Draft PR #2)

- VPS endpoint: `https://creator-api.indexesstore.com`, with valid trusted TLS and `GET /api/health` returning HTTP 200.
- `lib/main.dart` has an explicit build-time PocketBase boot path **before** Firebase initialization and the legacy GetX dependency bindings.
- `lib/scc_pocketbase_app.dart` implements a standalone functional user interface: normal-user login, session restore, private product list/add/edit/delete, private media upload/list, and logout.
- `lib/services/pocketbase/scc_pocketbase_client.dart` uses an HTTPS-only API URL and user-scoped bearer tokens stored in FlutterSecureStorage. It does not use a PocketBase superuser token.
- The legacy application remains unchanged when the build flag is absent; this is a controlled integration path, **not a complete removal of all Firebase-dependent features**.
- Public signup is intentionally disabled on the server until email verification and anti-abuse are configured. The PocketBase superuser cannot log into the normal app UI. An authorized administrator must provision a normal user separately.

## Test-build opt-in (not a public release)

```bash
flutter pub get
flutter test test/services/scc_pocketbase_client_test.dart test/widgets/scc_pocketbase_app_test.dart
flutter build apk --debug --dart-define=SCC_POCKETBASE_URL=https://creator-api.indexesstore.com
```

The debug APK is for a controlled device test. Never publish the debug APK as a store release or upload any signing keys to source control.

## Test plan

1. Install the private debug APK on an authorized test phone.
2. Confirm no Firebase login or initialization is invoked in PocketBase build mode.
3. Sign in with a **normal** preprovisioned PocketBase user account (not the superuser), verify session persistence and invalid-session handling.
4. Create a draft product, edit and delete it; confirm user A cannot read/modify/delete user B's products.
5. Upload a small JPG/PNG/WEBP or MP4 (at most 25 MiB) and confirm only the owner can list/download it.
6. Disable networking and verify the app shows safe error handling without exposing tokens.
7. Confirm WAHA, Shopify, and Caddy routes remain functional.

## Not yet migrated

- The original GetX/Firebase login/signup/OTP and catalog controller/screens still exist under the default legacy build mode.
- Image/AI-generation/AI chat services are not yet connected to a credentialed, quota-limited VPS AI worker.
- Email delivery, password reset and public signup remain unavailable. No automatic migration of existing Firebase users/data.
- Protected media listing exists but the new UI currently lists names only, without a protected-token thumbnail viewer.
- HTTPS endpoint is working, but verified encrypted off-site backups, restore drill, per-user upload quotas, rate limiting, release signing and real-device acceptance are pending.

**The URL and Flutter build define are not secrets. No administrator credentials belong in code or APK.**

## Private Android APK build verification (2026-10-29)

- GitHub Actions run `40950995136` **completed successfully**: https://github.com/helalalfqih-sketch/-/actions/runs/40950995136
- Artifact ID `12932272335`, name `scc-pocketbase-android-debug`.
- The artifact ZIP was extracted and the APK's ZIP structure verified locally.
- APK uncompressed size: `414328990` bytes; SHA-256: `17b453a1ba7dab5ba72bf0a804e9a9022961b3f516c527f1e3d4ec5f627a1a5b`.
- **No device-level pass claimed:** cloud emulator attachment rejected the local APK path; no Android session was created.
- Build artifact is a debug-signed APK, **not a release-signed APK/AAB**. It should be used only on a test device.
- Confirm the normal-user PocketBase account exists before attempting login: the superuser is intentionally not usable for the app.
- The legacy Android manifest still contains Firebase-related integrations, and `android:usesCleartextTraffic=true` must be audited before a production release.
