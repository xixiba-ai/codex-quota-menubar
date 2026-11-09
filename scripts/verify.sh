#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/private/tmp/CodexQuotaMenuBarDerivedData}"
cd "$ROOT"
if xcodebuild -version >/dev/null 2>&1; then
  xcodebuild -project CodexQuotaMenuBar.xcodeproj -scheme CodexQuotaMenuBar \
    -configuration Debug -derivedDataPath "$DERIVED_DATA_PATH" test
else
  # Same-source CLI suites exercise reminders and API monitoring without network or user preferences.
  python3 scripts/build-clt.py verify --work "$DERIVED_DATA_PATH/CLTChecks"
fi
