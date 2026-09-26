import AppKit
import SwiftUI
import XCTest
@testable import Codex_Quota

/// Run explicitly with QUOTA_DOC_SNAPSHOTS=/absolute/output/directory.
/// The views are drawn by AppKit into bitmaps; no window is shown on the desktop.
@MainActor
final class DocumentationSnapshots: XCTestCase {
    func testRenderDocumentationScreens() async throws {
        guard let path = ProcessInfo.processInfo.environment["QUOTA_DOC_SNAPSHOTS"],
              !path.isEmpty else {
            throw XCTSkip("Set QUOTA_DOC_SNAPSHOTS to render documentation images")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let defaults = UserDefaults.standard
        let originalArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain) }

        let now = Date()
        let fresh = QuotaStore(dataSource: DocumentationQuotaSource(snapshot: snapshot(updatedAt: now)))
        let stale = QuotaStore(dataSource: DocumentationQuotaSource(snapshot: snapshot(updatedAt: now.addingTimeInterval(-10 * 60))))
        await fresh.refresh()
        await stale.refresh()
        XCTAssertEqual(fresh.freshness(), .current)
        XCTAssertEqual(stale.freshness(), .stale)

        for (language, suffix) in [(AppLanguage.english, "en"), (.simplifiedChinese, "zh")] {
            var arguments = originalArguments
            arguments[AppLanguage.defaultsKey] = language.rawValue
            defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            let suiteName = "DocumentationSnapshots.\(UUID().uuidString)"
            let languageDefaults = UserDefaults(suiteName: suiteName)!
            defer { languageDefaults.removePersistentDomain(forName: suiteName) }
            languageDefaults.set(language.rawValue, forKey: AppLanguage.defaultsKey)
            let languageStore = AppLanguageStore(defaults: languageDefaults)

            try render(
                QuotaHelpView(store: fresh, languageStore: languageStore, openSessions: {}, dismiss: {}),
                size: NSSize(width: 620, height: 660),
                to: output.appendingPathComponent("help-\(suffix).png")
            )
            try render(
                AboutView(currentTag: "1.0.0-preview.4"),
                size: NSSize(width: 438, height: 290),
                to: output.appendingPathComponent("about-\(suffix).png")
            )
            try render(
                QuotaMenuContent(store: fresh),
                size: NSSize(width: 310, height: 240),
                to: output.appendingPathComponent("quota-\(suffix).png")
            )
            try render(
                QuotaMenuContent(store: stale),
                size: NSSize(width: 310, height: 240),
                to: output.appendingPathComponent("quota-stale-\(suffix).png")
            )
        }
    }

    private func snapshot(updatedAt: Date) -> CodexUsageSnapshot {
        let now = Date()
        return CodexUsageSnapshot(
            shortTerm: UsageWindow(remainingPercent: 65, resetsAt: now.addingTimeInterval(2 * 60 * 60 + 30 * 60), windowDurationMinutes: 300),
            longTerm: UsageWindow(remainingPercent: 55, resetsAt: now.addingTimeInterval(3 * 24 * 60 * 60), windowDurationMinutes: 10_080),
            updatedAt: updatedAt,
            sourceDescription: "Sample data"
        )
    }

    private func render<Content: View>(_ content: Content, size: NSSize, to url: URL) throws {
        let root = content
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw SnapshotError.bitmapUnavailable
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw SnapshotError.pngUnavailable
        }
        try png.write(to: url, options: .atomic)
        window.contentView = nil
        window.close()
    }

    private enum SnapshotError: Error {
        case bitmapUnavailable
        case pngUnavailable
    }
}

@MainActor
private final class DocumentationQuotaSource: UsageDataSource {
    let snapshot: CodexUsageSnapshot

    init(snapshot: CodexUsageSnapshot) { self.snapshot = snapshot }

    func fetchUsage() async throws -> CodexUsageSnapshot { snapshot }
}
