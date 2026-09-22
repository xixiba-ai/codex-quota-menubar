# Codex Quota Menu Bar — Maintenance guide

**English** | [简体中文](HANDOFF.md)

## Start here

```sh
cd /path/to/codex-quota-menubar
./scripts/verify.sh
xcodebuild -project CodexQuotaMenuBar.xcodeproj -scheme CodexQuotaMenuBar -configuration Debug -derivedDataPath /private/tmp/CodexQuotaMenuBarDerivedData build
open "/private/tmp/CodexQuotaMenuBarDerivedData/Build/Products/Debug/Codex Quota.app"
```

The verification script runs unit tests. The app targets macOS 13+ and lives in the menu bar, without a Dock icon or persistent main window.

## Project layout

| Path | Responsibility |
| --- | --- |
| `Sources/CodexQuotaMenuBarApp.swift` | AppKit menu bar entry point, menu actions, and schedule editor. |
| `Sources/QuotaStore.swift` | Quota state, 60-second polling, and manual refresh. |
| `Sources/UsageDataSource.swift` | Local Codex CLI app-server and optional HTTPS source. |
| `Sources/QuotaViews.swift` | Quota display views. |
| `Sources/QuotaHelpView.swift` | First-launch help, feature explanations, FAQ, and connection check. |
| `Sources/AutoRefreshScheduler.swift` | Scheduling, persistence, and wake/clock-change compensation. |
| `Sources/CodexCLIRefreshTrigger.swift` | Scheduled one-shot Codex CLI requests. |
| `Sources/ResetForecast.swift` | Optional third-party forecast requests, validation, coalescing, and settings. |
| `Tests/AutoRefreshSchedulerTests.swift` | Schedule, toggle, compensation, custom-time, and compatibility tests. |
| `Resources/` | App and status icons. |
| `distribution/releases/` | Versioned DMGs, installation guides, license, and checksums; excluded from Git. |
| `scripts/package-release.sh` | Isolated preview build, checks, and DMG packaging from committed source. |
| `project.yml` | XcodeGen definition. Prefer editing this for target and build-setting changes. |
| `CodexQuotaMenuBar.xcodeproj/` | Included Xcode project. Regenerate with `xcodegen generate` after changing `project.yml`. |

## Runtime structure

```text
Menu bar UI
 ├─ QuotaStore ──> UsageDataSource ──> Codex CLI app-server / HTTPS endpoint
 └─ AutoRefreshScheduler ──> CodexCLIRefreshTrigger ──> local Codex CLI
```

- Quota is checked every 60 seconds, with additional local CLI update notifications.
- Forecasts are off by default. When enabled, they follow active quota checks and scheduled CLI activity; passive quota notifications do not request forecasts.
- Scheduled requests are independent of quota reads and run at the configured times.
- Default trigger times are `05:30`, `10:30`, `15:30`, and `20:30`, adjustable through **修改触发时间…**.
- The toggle, schedule, last result, and handled windows are stored under the `autoRefreshState` UserDefaults key.
- On launch, wake, or clock change, only the newest missed window is compensated for; handled windows are not repeated.

## Help window

The first-launch help state uses `hasShownGettingStarted` in UserDefaults. Closing the help window does not quit the app. The menu reopens the same window rather than creating duplicates. Help uses `QuotaStore` for connection status and manual refresh, without changing scheduled-activity or forecast settings.

Verify first-launch display, reopening after closing, subsequent launches without automatic help, all three help sections, connection errors, and opening the session browser. To repeat the first-launch check, quit the app and run `defaults delete com.example.CodexQuotaMenuBar hasShownGettingStarted`.

## Tests and builds

```sh
./scripts/verify.sh

xcodebuild -project CodexQuotaMenuBar.xcodeproj \
  -scheme CodexQuotaMenuBar \
  -configuration Release \
  -derivedDataPath /private/tmp/CodexQuotaMenuBarDerivedData \
  build
```

## Install a local development build

Quit the running app before copying the new build into `/Applications`:

```sh
pkill -f "Codex Quota.app/Contents/MacOS/Codex Quota" || true
ditto "/private/tmp/CodexQuotaMenuBarDerivedData/Build/Products/Debug/Codex Quota.app" "/Applications/Codex Quota.app"
open "/Applications/Codex Quota.app"
```

An old `distribution/staging/Codex Quota.app` may also be discovered by LaunchServices and has the same bundle ID. Launch using an explicit absolute path. Use the isolated packaging process below for releases, not the old staging directory.

## Package a preview release

Complete verification and commit your changes first, then run:

```sh
./scripts/package-release.sh 1.0.0-preview.2 2
```

Use a new version for a new release. The script requires full Xcode; use `DEVELOPER_DIR` to select a specific installation. It exports the current commit, builds arm64 and x86_64 Release binaries in a separate temporary directory, checks the version and bundle contents, adds the MIT license and installation guides, and creates a DMG and SHA-256 checksums. It stops if output for that version already exists.

Artifacts go to `distribution/releases/VERSION/`. Build logs and staging files remain in the local temporary directory. Subsequent packages include both `INSTALL.md` and `INSTALL.en.md`. Before publishing, mount the DMG, verify its bundle signature and architectures, perform a startup check, and review it for private data. Upload only release attachments from the versioned output directory to a GitHub Release targeting the matching source commit, marked as a prerelease.

The existing `v1.0.0-preview.1` installer contains the original Chinese installation guide. Its published binary and checksums are unchanged by documentation translations; the current English guide is available online.

## Configure a data source

The default source is your locally authenticated Codex CLI. Optional settings:

```sh
defaults write com.example.CodexQuotaMenuBar codexExecutablePath "$HOME/.local/bin/codex"
defaults write com.example.CodexQuotaMenuBar usageEndpoint 'https://your-authorized-service.example/usage'
defaults write com.example.CodexQuotaMenuBar usageEndpointBearerToken 'YOUR_TOKEN'
```

Remove `usageEndpoint` to use the local CLI again. Never put real tokens in source, documentation, or Git history.

## Inspect scheduled-activity logs

CLI error details are logged as private fields to avoid exposing local paths or other sensitive information in default logs.

Filter Console by subsystem `com.example.CodexQuotaMenuBar` and category `AutoRefresh`, or run:

```sh
log show --last 1h --predicate 'subsystem == "com.example.CodexQuotaMenuBar" AND category == "AutoRefresh"'
```

## When changing scheduling

1. Preserve decoding compatibility for existing `AutoRefreshState` data; add defaults for new persisted fields.
2. Cover cross-day schedules, exact trigger times, wake compensation, and clock changes when changing time calculations.
3. Verify both enabled and disabled menu states when changing menu text or behavior.
4. Run `./scripts/verify.sh`.
5. When installing locally, copy to `/Applications` and relaunch by absolute path.

## Known limitations

- Codex's local app-server protocol is experimental. CLI upgrades may require adapting `UsageDataSource.swift`.
- Developer signing is disabled in the project. The packaging script applies an ad-hoc integrity signature only; Developer ID signing and Apple notarization are not configured.
- Legacy `distribution/Codex Quota.dmg` and `distribution/staging/` are outside the release process and should not be uploaded.

## Localization

`Sources/Localization.swift` resolves the saved `appLanguage` setting (`system`, `zh-Hans`, or `en`) and reads `Resources/en.lproj/Localizable.strings` and `Resources/zh-Hans.lproj/Localizable.strings`. System mode chooses the first supported language in the preferred-language list, with English as the fallback. Language changes update menus, open windows, dates, and app-owned errors without restarting or sending a Codex request. Session content and external service messages are not translated.

Use `L10n.tr` for app-owned text. Interpolated values become numbered placeholders; keep matching placeholders in both resource files. Do not translate user text or change persisted enum values. `LocalizationTests` checks resource parity, placeholder safety, language persistence, quota errors, and schedule input. Test launches skip live CLI and scheduler startup.

Schedule input accepts only `HH:mm` 24-hour times separated by ASCII commas, with optional surrounding whitespace. Formatting always uses `, ` in both languages. Existing schedules store numeric minutes, so no migration is needed.
