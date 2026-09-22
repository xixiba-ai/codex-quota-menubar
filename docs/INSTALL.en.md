# Install the Codex Quota preview

**English** | [简体中文](INSTALL.md)

## Download and requirements

Download `Codex-Quota-VERSION-universal.dmg` from [GitHub Releases](https://github.com/xixiba-ai/codex-quota-menubar/releases). The universal app includes Apple Silicon and Intel builds and targets macOS 13 or later.

Install and sign in to Codex CLI on your Mac before using quota features. The installer does not include Codex CLI or any login credentials. This first public preview has not been tested on every supported macOS version and hardware configuration.

**The current app interface is in Simplified Chinese.** This guide includes the Chinese menu labels needed for installation and first use.

## Install

1. If an older Codex Quota is running, choose **退出** (Quit) from its menu bar menu.
2. Open the DMG and drag **Codex Quota.app** into the **Applications** folder beside it.
3. Eject the disk image, then open Codex Quota from Applications.
4. Look for the app in the menu bar at the top of your screen. It has no Dock icon. A help window appears on first launch.

## macOS prompts on first launch

This preview **has no Apple Developer ID signature and has not been notarized by Apple**. Its ad-hoc signature provides local integrity checking, not developer identity verification. macOS may display a warning that the developer cannot be verified or that Apple cannot check the app for malicious software.

After confirming the download source and checking the file, if you decide to proceed, try opening the app once. Then open **System Settings → Privacy & Security**, find **Open Anyway** for this app, and follow the system prompts. Organization-managed Macs may not allow this exception.

If macOS reports that the app is damaged or contains malware, stop installation, check the download and checksum again, and report the issue. You do not need to disable system-wide security protections.

See [Apple: Open apps safely on your Mac](https://support.apple.com/en-gb/102445).

## Verify the download

Each release includes `SHA256SUMS.txt`. Save it beside the DMG and run:

```sh
shasum -a 256 Codex-Quota-*-universal.dmg
```

Compare the result with the entry for the same DMG filename in `SHA256SUMS.txt`. If you downloaded every release attachment, run `shasum -a 256 -c SHA256SUMS.txt` to check them all.

## Defaults and privacy

- Quota is read through your locally authenticated Codex CLI. The CLI handles account authentication.
- **自动刷新额度** (scheduled quota activity) and **重置概率预测** (reset forecast) are off by default. Scheduled activity sends real Codex requests and may use a small amount of quota. Forecasts contact willcodexquotareset.com, which receives ordinary network request information such as your IP address.
- The session browser displays local session titles, task previews, and project paths. Remove private details before sharing screenshots or feedback.
- Session deletion is permanent. Read the confirmation prompt before proceeding.

## License and feedback

The project uses the **MIT License**. The full license is included at the root of the disk image and inside the app's resources. Keep the copyright notice and license when modifying or redistributing the software.

[Source code](https://github.com/xixiba-ai/codex-quota-menubar) · [Report an issue](https://github.com/xixiba-ai/codex-quota-menubar/issues)
