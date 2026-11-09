#!/usr/bin/env python3
"""Build committed-source macOS bundles or run focused checks without full Xcode.

No installed app, generated asset catalog, or user settings are read. Call this from
package-release.sh to package a clean git archive; direct use is for local builds.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent


def sdk_path():
    override = os.environ.get('CODEX_QUOTA_CLT_SDK')
    # The CLT 27.x SDK references SwiftUI macro plugins shipped only with full Xcode.
    # SDK 26.5 supports this app's macOS 13 APIs using the existing property wrappers.
    compatible = Path('/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk')
    sdk = Path(override) if override else compatible if compatible.is_dir() else Path(
        subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip())
    if not sdk.is_dir():
        raise SystemExit('SDK not found. Set CODEX_QUOTA_CLT_SDK to a compatible macOS SDK.')
    return sdk.resolve()


def run_logged(command, log, cwd=ROOT):
    with log.open('w') as stream:
        result = subprocess.run(command, cwd=cwd, stdout=stream, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f'Command failed; see {log}. For CLT SwiftUI macro errors, use a compatible SDK via CODEX_QUOTA_CLT_SDK.')


def compiler(sdk, cache):
    return ['xcrun', 'swiftc', '-swift-version', '5', '-sdk', str(sdk), '-module-cache-path', str(cache)]


def resources(app, work):
    destination = app / 'Contents/Resources'
    destination.mkdir(parents=True)
    iconset = work / 'AppIcon.iconset'
    iconset.mkdir()
    asset = ROOT / 'Resources/Assets.xcassets/AppIcon.appiconset'
    manifest = {}
    for image in json.loads((asset / 'Contents.json').read_text())['images']:
        size = image['size'].split('x')[0]
        scale = '@2x' if image['scale'] == '2x' else ''
        source = asset / image['filename']
        shutil.copyfile(source, iconset / f'icon_{size}x{size}{scale}.png')
    subprocess.run(['iconutil', '--convert', 'icns', '--output', str(destination / 'AppIcon.icns'), str(iconset)], check=True)
    for name, source_name in [('StatusIcon.png', 'status_18.png'), ('StatusIcon@2x.png', 'status_36.png')]:
        shutil.copyfile(ROOT / 'Resources/Assets.xcassets/StatusIcon.imageset' / source_name, destination / name)
    for language in ('en', 'zh-Hans'):
        folder = destination / f'{language}.lproj'
        folder.mkdir()
        source = ROOT / 'Resources' / f'{language}.lproj/Localizable.strings'
        subprocess.run(['plutil', '-lint', str(source)], check=True, stdout=subprocess.DEVNULL)
        shutil.copyfile(source, folder / 'Localizable.strings')
    shutil.copyfile(ROOT / 'LICENSE', destination / 'LICENSE.txt')
    for source in sorted((ROOT / 'Resources').rglob('*')):
        if source.is_file():
            manifest[str(source.relative_to(ROOT))] = hashlib.sha256(source.read_bytes()).hexdigest()
    generated = {str(p.relative_to(app)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(destination.rglob('*')) if p.is_file()}
    return {'source': manifest, 'bundle': generated, 'method': 'iconutil from source PNGs; named PNG status resources; no reused Assets.car'}


def build(args):
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    app = args.app.resolve()
    if app.exists():
        raise SystemExit(f'Refusing to overwrite: {app}')
    sdk = sdk_path()
    sources = sorted(str(p.relative_to(ROOT)) for p in (ROOT / 'Sources').glob('*.swift'))
    def compile_arch(arch):
        command = compiler(sdk, work / f'modules-{arch}') + [
            '-O', '-whole-module-optimization', '-module-name', 'Codex_Quota',
            '-target', f'{arch}-apple-macos13.0', *sources, '-o', str(work / f'CodexQuota-{arch}')]
        run_logged(command, work / f'build-{arch}.log')
    with ThreadPoolExecutor(max_workers=2) as executor:
        list(executor.map(compile_arch, ('arm64', 'x86_64')))
    binary = app / 'Contents/MacOS/Codex Quota'
    binary.parent.mkdir(parents=True)
    subprocess.run(['lipo', '-create', str(work / 'CodexQuota-arm64'), str(work / 'CodexQuota-x86_64'), '-output', str(binary)], check=True)
    binary.chmod(0o755)
    resource_manifest = resources(app, work)
    info = {
        'CFBundleDevelopmentRegion': 'en', 'CFBundleDisplayName': 'Codex Quota',
        'CFBundleExecutable': 'Codex Quota', 'CFBundleIconFile': 'AppIcon.icns',
        'CFBundleIdentifier': 'com.example.CodexQuotaMenuBar', 'CFBundleInfoDictionaryVersion': '6.0',
        'CFBundleName': 'Codex Quota', 'CFBundlePackageType': 'APPL', 'CFBundleSupportedPlatforms': ['MacOSX'],
        'CFBundleShortVersionString': args.version.split('-')[0], 'CFBundleVersion': args.build,
        'CodexQuotaReleaseVersion': args.version, 'CodexQuotaSourceCommit': args.commit,
        'LSMinimumSystemVersion': '13.0', 'LSUIElement': True,
    }
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    (app / 'Contents/PkgInfo').write_bytes(b'APPL????')
    (work / 'RESOURCE-MANIFEST.json').write_text(json.dumps(resource_manifest, indent=2) + '\n')
    (work / 'BUILD-METHOD.txt').write_text(f'CLT swiftc; Swift 5 language mode; -O wholemodule; {sdk.name}; source PNG assets\n')
    print(f'Built universal bundle: {app}')


def verify(args):
    work = args.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    sdk = sdk_path()
    suites = [
        ('reset-reminder', 'RESET_REMINDER_CLI_TEST', ['Sources/ResetReminder.swift', 'Sources/UsageModels.swift', 'Sources/Localization.swift', 'Tests/ResetReminderTests.swift']),
        ('codex-reset', 'CODEX_RESET_CLI_TEST', ['Sources/CodexResetMonitor.swift', 'Sources/Localization.swift', 'Tests/CodexResetMonitorTests.swift']),
    ]
    for name, flag, files in suites:
        binary = work / name
        run_logged(compiler(sdk, work / 'modules') + ['-D', flag, *files, '-o', str(binary)], work / f'{name}-build.log')
        result = subprocess.check_output([str(binary)], cwd=ROOT, text=True)
        (work / f'{name}-tests.log').write_text(result)
        print(result.strip())
    print(f'Focused CLT checks passed. Full XCTest requires Xcode. Logs: {work}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    release = sub.add_parser('build')
    release.add_argument('--app', type=Path, required=True)
    release.add_argument('--work', type=Path, required=True)
    release.add_argument('--version', required=True)
    release.add_argument('--build', required=True)
    release.add_argument('--commit', required=True)
    checks = sub.add_parser('verify')
    checks.add_argument('--work', type=Path, required=True)
    args = parser.parse_args()
    if args.command == 'build':
        build(args)
    else:
        verify(args)


if __name__ == '__main__':
    main()
