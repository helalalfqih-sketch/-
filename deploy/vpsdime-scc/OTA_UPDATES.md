# Install once, receive supported Dart updates

## Current evidence

`shorebird.yaml` already registers app `50f79796-407c-4909-a7c2-8ed8d05d25b3`, is bundled in pubspec assets, and does not disable automatic updates. Existing APK workflows call `flutter build`, not `shorebird release`; those APKs are not a verified OTA baseline. Recent private builds use fresh disposable signing keys. The current Android ID is `com.example.smart_content_creator` and pubspec is `1.2.1+5`; confirm the permanent identity and existing Shorebird releases before choosing a base version. Do not reset or create a duplicate Shorebird app.

## Prepared entrypoint

`scripts/scc_ota.sh check` validates the CLI, the expected Shorebird app, the explicit permanent package ID, and the certificate fingerprint of the existing keystore. It neither uploads nor publishes. Set `SHOREBIRD_TOKEN`, `SCC_OTA_PACKAGE_ID`, and `SCC_SIGNING_CERT_SHA256` securely in the build environment. Use the existing long-lived keystore through `android/key.properties`; keep it backed up securely. Never generate a replacement key per build or commit credentials.

After static analysis, client/widget tests and backend checks pass, an explicitly approved clean commit can run `scripts/scc_ota.sh release VERSION+BUILD` with `SCC_OTA_APPROVED_SHA` matching its full SHA. This uploads a Shorebird base release and builds the PocketBase entrypoint. Do not run until account access, version availability, signing identity and the live guest backend are verified. Flutter 3.41.6 support in the account's Shorebird toolchain also needs verification.

Install this baseline once, then run `scripts/scc_ota.sh patch SAME_VERSION+BUILD` for reviewed Dart changes. This targets **staging**, not stable. On a test device, verify the recorded base release, patch number, preserved guest identity/data, restart application, guest CRUD/private media and actual AI flow. Test rollback. Only then approve promotion to stable through Shorebird's supported console/CLI. Ordinary commits do not publish patches automatically.

The updater downloads a patch at launch; it takes effect after a later application restart. Dart UI/logic changes are eligible. Native code, permissions, bundled assets/fonts/images and Flutter engine changes require a new full release. With a persistent signing identity that full release can update the installed app without uninstalling, but it is still an Android package update. Server-side content/AI changes can take effect without a mobile release when their API contract stays compatible.

## Acceptance gate / blockers

No OTA base release or real patch delivery is verified yet. Available tooling has not verified access to the existing Shorebird account or the permanent signing key. Never describe source configuration or a successful normal Flutter build as OTA success. Keep the guest deployment approval separate; OTA does not enable the server's guest route.

Official references:
- https://docs.shorebird.dev/code-push/
- https://docs.shorebird.dev/code-push/ci/github/
- https://docs.shorebird.dev/code-push/release/
- https://docs.shorebird.dev/code-push/patch/
