#!/usr/bin/env bash
# Manual reviewed release/patch only; never invoked by an ordinary source push.
set -Eeuo pipefail
ACTION=${1:-check}
VERSION=${2:-}
case "$ACTION" in check|release|patch) ;; *) echo 'Usage: scc_ota.sh check|release|patch [version+build]' >&2; exit 2;; esac
cd "$(git rev-parse --show-toplevel)"
command -v shorebird >/dev/null || { echo 'Shorebird CLI is required.' >&2; exit 1; }
command -v keytool >/dev/null
command -v python3 >/dev/null
test -f android/key.properties || { echo 'Persistent Android signing is required.' >&2; exit 1; }
test -n "${SHOREBIRD_TOKEN:-}" || { echo 'Configure SHOREBIRD_TOKEN securely; never paste it into chat.' >&2; exit 1; }
test -n "${SCC_SIGNING_CERT_SHA256:-}" || { echo 'Set the verified persistent signing certificate SHA-256.' >&2; exit 1; }
test -n "${SCC_OTA_PACKAGE_ID:-}" || { echo 'Set the confirmed permanent Android application ID.' >&2; exit 1; }

# Check the existing keystore without printing passwords or accepting a fresh test key.
python3 - <<'PY'
import hashlib, os, pathlib, re, subprocess
properties = {}
for line in pathlib.Path('android/key.properties').read_text().splitlines():
    if '=' in line and not line.lstrip().startswith('#'):
        key,value=line.split('=',1)
        properties[key.strip()]=value.strip()
for key in ('storeFile','storePassword','keyAlias','keyPassword'):
    if not properties.get(key): raise SystemExit('Incomplete signing configuration')
file=pathlib.Path(properties['storeFile'])
if not file.is_absolute(): file=pathlib.Path('android/app')/file
environment=dict(os.environ, SCC_KEYSTORE_PASSWORD=properties['storePassword'])
result=subprocess.run(['keytool','-exportcert','-keystore',str(file),'-alias',properties['keyAlias'],
    '-storepass:env','SCC_KEYSTORE_PASSWORD'],env=environment,capture_output=True)
if result.returncode: raise SystemExit('Could not read signing certificate')
expected=os.environ['SCC_SIGNING_CERT_SHA256'].replace(':','').lower()
if not re.fullmatch('[0-9a-f]{64}',expected): raise SystemExit('Invalid certificate SHA-256')
if hashlib.sha256(result.stdout).hexdigest()!=expected: raise SystemExit('Signing certificate mismatch')
gradle=pathlib.Path('android/app/build.gradle.kts').read_text()
match=re.search(r'applicationId\s*=\s*"([^"]+)"',gradle)
if not match or match.group(1)!=os.environ['SCC_OTA_PACKAGE_ID']: raise SystemExit('Application ID mismatch')
config=pathlib.Path('shorebird.yaml').read_text()
if '50f79796-407c-4909-a7c2-8ed8d05d25b3' not in config: raise SystemExit('Unexpected Shorebird application')
if re.search(r'^\s*auto_update:\s*false\s*$',config,re.M): raise SystemExit('Automatic updates are disabled')
print('Signing identity, package and updater configuration checked; no release uploaded.')
PY
shorebird --version
if [ "$ACTION" = check ]; then exit 0; fi
test -z "$(git status --porcelain)" || { echo 'Release from a clean reviewed checkout.' >&2; exit 1; }
SHA=$(git rev-parse HEAD)
test "${SCC_OTA_APPROVED_SHA:-}" = "$SHA" || { echo 'Set SCC_OTA_APPROVED_SHA to the reviewed commit before uploading.' >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$ ]] || { echo 'An explicit version+build is required.' >&2; exit 1; }
ACTUAL=$(python3 -c 'import pathlib,re; print(re.search(r"^version:\s*(\S+)",pathlib.Path("pubspec.yaml").read_text(),re.M).group(1))')
test "$ACTUAL" = "$VERSION" || { echo 'pubspec version must match the chosen release.' >&2; exit 1; }
case "$ACTION" in
  release)
    shorebird release android --artifact apk --flutter-version 3.41.6 \
      --target-platform android-arm64,android-x64 --target lib/main_scc_release.dart \
      -- --dart-define=SCC_POCKETBASE_URL=https://creator-api.indexesstore.com
    ;;
  patch)
    # Staging first: do not push an untested patch to existing installations.
    shorebird patch android --release-version "$VERSION" --track staging \
      --target lib/main_scc_release.dart \
      -- --dart-define=SCC_POCKETBASE_URL=https://creator-api.indexesstore.com
    ;;
esac
