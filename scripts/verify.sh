#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/private/tmp/CodexQuotaMenuBarDerivedData}"

cd "$ROOT"
xcodebuild \
  -project CodexQuotaMenuBar.xcodeproj \
  -scheme CodexQuotaMenuBar \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  test
