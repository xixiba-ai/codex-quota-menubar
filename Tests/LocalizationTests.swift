import Foundation
import XCTest
@testable import Codex_Quota

@MainActor
final class LocalizationTests: XCTestCase {
    func testSystemLanguageResolutionAndEnglishFallback() {
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["zh-Hans-CN", "en"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["en-GB", "zh-Hans"]), .english)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["fr-FR", "zh-TW"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["fr-FR"]), .english)
        XCTAssertEqual(AppLanguage.english.resolved(preferredLanguages: ["zh-Hans"]), .english)
        XCTAssertEqual(AppLanguage.simplifiedChinese.resolved(preferredLanguages: ["en"]), .simplifiedChinese)
    }

    func testLanguagePreferencePersistsAndUnknownValuesUseSystem() {
        let suite = "LocalizationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppLanguageStore(defaults: defaults)
        XCTAssertEqual(store.selection, .system)
        store.select(.english)
        XCTAssertEqual(AppLanguageStore(defaults: defaults).selection, .english)
        store.select(.simplifiedChinese)
        XCTAssertEqual(AppLanguageStore(defaults: defaults).selection, .simplifiedChinese)
        store.select(.system)
        XCTAssertEqual(AppLanguageStore(defaults: defaults).selection, .system)
        defaults.set("invalid", forKey: AppLanguage.defaultsKey)
        XCTAssertEqual(AppLanguageStore(defaults: defaults).selection, .system)
    }

    func testBothTranslationsArePackagedAndHaveMatchingPlaceholders() throws {
        func table(_ language: AppLanguage) throws -> [String: String] {
            let bundle = L10n.bundle(for: language)
            let url = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "strings"))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
        }
        let english = try table(.english)
        let chinese = try table(.simplifiedChinese)
        XCTAssertGreaterThan(english.count, 150)
        XCTAssertEqual(Set(english.keys), Set(chinese.keys))
        let pattern = try NSRegularExpression(pattern: #"\{\d+\}"#)
        func placeholders(_ text: String) -> [String] {
            pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .map { (text as NSString).substring(with: $0.range) }.sorted()
        }
        for (key, value) in english {
            XCTAssertFalse(value.isEmpty, key)
            XCTAssertNil(value.range(of: #"\p{Han}"#, options: .regularExpression), key)
            XCTAssertEqual(placeholders(key), placeholders(value), key)
            XCTAssertEqual(placeholders(key), placeholders(chinese[key]!), key)
        }
        XCTAssertEqual(L10n.tr("取消", language: .english), "Cancel")
        XCTAssertEqual(L10n.tr("取消", language: .simplifiedChinese), "取消")
    }

    func testInterpolationPreservesUserContentAndSupportsReorderedArguments() {
        let title = "中文 title {1} %@ 100% 🛠"
        XCTAssertEqual(L10n.tr("删除会话时出错：\(title)", language: .english), "Could not delete the session: \(title)")
        XCTAssertEqual(L10n.interpolate("{1}: {0}; {1}", arguments: [title, "second"]), "second: \(title); second")
        XCTAssertEqual(L10n.tr("短周期剩余 \(65)%", language: .english), "Short-term remaining: 65%")
        XCTAssertEqual(L10n.tr("短周期剩余 \(65)%", language: .simplifiedChinese), "短周期剩余 65%")
    }

    func testExistingQuotaErrorAndSourceFollowLanguageChangeWithoutRefetch() async {
        let oldArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(oldArguments, forName: UserDefaults.argumentDomain) }
        func setLanguage(_ language: AppLanguage) {
            var arguments = oldArguments
            arguments[AppLanguage.defaultsKey] = language.rawValue
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
        setLanguage(.english)
        let source = FailingQuotaSource()
        let store = QuotaStore(dataSource: source)
        await store.refresh()
        XCTAssertEqual(store.errorMessage, "Codex CLI not found. Install it and sign in to Codex first.")
        XCTAssertEqual(CodexUsageSnapshot.preview.localizedSourceDescription, "Sample data")
        setLanguage(.simplifiedChinese)
        XCTAssertEqual(store.errorMessage, "未找到 Codex CLI；请先安装并登录 Codex")
        XCTAssertEqual(CodexUsageSnapshot.preview.localizedSourceDescription, "示例数据")
        XCTAssertEqual(source.requests, 1)
    }

    func testScheduleUsesEnglishCommasAndRoundTripsSavedTimes() {
        let times = [360, 750, 1080]
        XCTAssertEqual(AutoRefreshSchedule.formattedTimeList(times), "06:00, 12:30, 18:00")
        XCTAssertEqual(AutoRefreshSchedule.parseTimeList(" 06:00,12:30, 18:00 "), times)
        XCTAssertEqual(AutoRefreshSchedule.parseTimeList("18:00, 06:00, 06:00, 12:30"), times)
        XCTAssertEqual(AutoRefreshSchedule.parseTimeList(AutoRefreshSchedule.formattedTimeList(AutoRefreshSchedule.defaultTriggerMinutes)), AutoRefreshSchedule.defaultTriggerMinutes)
        XCTAssertEqual(AutoRefreshSchedule.parseTimeList("00:00, 23:59"), [0, 1439])
    }

    func testScheduleRejectsOtherSeparatorsEmptyEntriesAndInvalidTimes() {
        for input in ["", " ", "06:00、12:30", "06:00，12:30", "06:00 12:30", "06:00;12:30", "06:00\n12:30", "06:00,", ",06:00", "06:00,,12:30", "24:00", "12:60", "6:00", "06:0", "-1:00", "０６:００", "06:00:00"] {
            XCTAssertNil(AutoRefreshSchedule.parseTimeList(input), input)
        }
    }
}

@MainActor
private final class FailingQuotaSource: UsageDataSource {
    var requests = 0
    func fetchUsage() async throws -> CodexUsageSnapshot {
        requests += 1
        throw CodexCLIRefreshTriggerError.executableNotFound
    }
}
