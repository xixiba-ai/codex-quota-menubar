#!/bin/zsh
set -euo pipefail

# Build only committed files in an isolated directory. Never reuse the local app or staging area.
ROOT="${0:A:h:h}"
VERSION="${1:?Usage: package-release.sh VERSION [BUILD_NUMBER]}"
BUILD_NUMBER="${2:-1}"
if ! [[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$' && "$BUILD_NUMBER" =~ '^[0-9]+$' ]]; then
  print -u2 'Invalid version or build number.'
  exit 1
fi
cd "$ROOT"
if [[ -n "$(git status --porcelain)" ]]; then
  print -u2 'Commit or stash working-tree changes before packaging.'
  exit 1
fi

OUTPUT="$ROOT/distribution/releases/$VERSION"
if [[ -e "$OUTPUT" ]]; then
  print -u2 "Output already exists: $OUTPUT"
  exit 1
fi
WORK_DIR="$(mktemp -d /private/tmp/codex-quota-package.XXXXXX)"
print "Build workspace: $WORK_DIR"
mkdir -p "$WORK_DIR/source" "$WORK_DIR/staging" "$WORK_DIR/artifacts"
git archive HEAD | tar -x -C "$WORK_DIR/source"
SOURCE_COMMIT="$(git rev-parse HEAD)"
APP_VERSION="${VERSION%%-*}"

xcodebuild \
  -project "$WORK_DIR/source/CodexQuotaMenuBar.xcodeproj" \
  -scheme CodexQuotaMenuBar \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$WORK_DIR/DerivedData" \
  ONLY_ACTIVE_ARCH=NO 'ARCHS=arm64 x86_64' CODE_SIGNING_ALLOWED=NO \
  DEBUG_INFORMATION_FORMAT=dwarf SWIFT_SERIALIZE_DEBUGGING_OPTIONS=NO \
  "MARKETING_VERSION=$APP_VERSION" "CURRENT_PROJECT_VERSION=$BUILD_NUMBER" \
  "INFOPLIST_KEY_CFBundleShortVersionString=$APP_VERSION" \
  "INFOPLIST_KEY_CFBundleVersion=$BUILD_NUMBER" \
  build > "$WORK_DIR/build.log" 2>&1 || {
    print -u2 "Build failed. See $WORK_DIR/build.log"
    exit 1
  }

APP="$WORK_DIR/staging/Codex Quota.app"
ditto --noextattr --norsrc "$WORK_DIR/DerivedData/Build/Products/Release/Codex Quota.app" "$APP"
cp "$WORK_DIR/source/LICENSE" "$APP/Contents/Resources/LICENSE.txt"
cp "$WORK_DIR/source/LICENSE" "$WORK_DIR/staging/LICENSE.txt"
cp "$WORK_DIR/source/docs/INSTALL.md" "$WORK_DIR/staging/INSTALL.md"
cp "$WORK_DIR/source/docs/INSTALL.en.md" "$WORK_DIR/staging/INSTALL.en.md"
ln -s /Applications "$WORK_DIR/staging/Applications"
cat > "$WORK_DIR/staging/BUILD-INFO.txt" <<EOF
Codex Quota $VERSION
App version: $APP_VERSION
Build number: $BUILD_NUMBER
Source commit: $SOURCE_COMMIT
Repository: https://github.com/xixiba-ai/codex-quota-menubar
Architectures: arm64, x86_64
Minimum macOS: 13.0
Signing: ad-hoc only; no Apple Developer ID; not notarized
License: MIT
EOF

# Strip debug records, then seal the bundle without using a personal signing identity.
xcrun strip -S "$APP/Contents/MacOS/Codex Quota"
codesign --force --sign - --identifier com.example.CodexQuotaMenuBar "$APP"
codesign --verify --deep --strict "$APP"

python3 - "$WORK_DIR/staging" "$APP_VERSION" "$BUILD_NUMBER" <<'PY'
from pathlib import Path
import plistlib, re, subprocess, sys

root = Path(sys.argv[1])
app = root / 'Codex Quota.app'
architectures = subprocess.check_output(['lipo', '-archs', str(app / 'Contents/MacOS/Codex Quota')], text=True).split()
assert set(architectures) == {'arm64', 'x86_64'}, architectures
with (app / 'Contents/Info.plist').open('rb') as source:
    info = plistlib.load(source)
assert info['CFBundleIdentifier'] == 'com.example.CodexQuotaMenuBar'
assert info['CFBundleShortVersionString'] == sys.argv[2]
assert info['CFBundleVersion'] == sys.argv[3]
assert info['LSMinimumSystemVersion'] == '13.0'
patterns = [
    rb'/(?:Users|home)/[^\s/]+/',
    rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
    rb'\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{25,}|sk-[A-Za-z0-9_-]{20,})',
]
for path in root.rglob('*'):
    if path.is_symlink():
        assert path == root / 'Applications' and path.readlink() == Path('/Applications')
        continue
    lower = path.name.lower()
    assert not any(s in lower for s in ('xctest', 'xcunit', 'xcui', 'testing.framework', '.ds_store'))
    assert not lower.endswith(('.log', '.jsonl', '.pem', '.key', '.p12', '.pfx', '.dSYM'.lower()))
    assert lower not in ('auth.json', '.env', '.git')
    if path.is_file():
        data = path.read_bytes()
        assert not any(re.search(pattern, data) for pattern in patterns), f'Privacy check failed: {path.relative_to(root)}'
print('Bundle, architecture, version, and publication checks passed.')
PY

DMG_NAME="Codex-Quota-$VERSION-universal.dmg"
hdiutil create -fs HFS+ -format UDZO -volname 'Codex Quota' \
  -srcfolder "$WORK_DIR/staging" "$WORK_DIR/artifacts/$DMG_NAME"
hdiutil verify "$WORK_DIR/artifacts/$DMG_NAME"
cp "$WORK_DIR/staging/INSTALL.md" "$WORK_DIR/staging/INSTALL.en.md" "$WORK_DIR/staging/LICENSE.txt" \
  "$WORK_DIR/staging/BUILD-INFO.txt" "$WORK_DIR/artifacts/"
(
  cd "$WORK_DIR/artifacts"
  shasum -a 256 "$DMG_NAME" INSTALL.md INSTALL.en.md LICENSE.txt BUILD-INFO.txt > SHA256SUMS.txt
)
mkdir -p "${OUTPUT:h}"
mv "$WORK_DIR/artifacts" "$OUTPUT"
print "Release files: $OUTPUT"
print "Build log and staging retained locally: $WORK_DIR"
