import Foundation
import Combine

enum AppLanguage: String, CaseIterable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    static let defaultsKey = "appLanguage"

    func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        guard self == .system else { return self }
        for language in preferredLanguages {
            let code = language.lowercased().replacingOccurrences(of: "_", with: "-")
            if code == "zh" || code.hasPrefix("zh-") { return .simplifiedChinese }
            if code == "en" || code.hasPrefix("en-") { return .english }
        }
        return .english
    }
}

@MainActor
final class AppLanguageStore: ObservableObject {
    static let shared = AppLanguageStore()
    @Published private(set) var selection: AppLanguage
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = AppLanguage(rawValue: defaults.string(forKey: AppLanguage.defaultsKey) ?? "") ?? .system
    }

    func select(_ language: AppLanguage) {
        guard selection != language else { return }
        defaults.set(language.rawValue, forKey: AppLanguage.defaultsKey)
        selection = language
    }
}

/// Keeps interpolation values separate from the translation key. Session names, paths,
/// external errors, and percent signs are never interpreted as format instructions.
struct LocalizedMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    let key: String
    let arguments: [String]

    init(stringLiteral value: String) {
        key = value
        arguments = []
    }

    init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key
        arguments = stringInterpolation.arguments
    }

    struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []

        init(literalCapacity: Int, interpolationCount: Int) {
            key.reserveCapacity(literalCapacity)
            arguments.reserveCapacity(interpolationCount)
        }

        mutating func appendLiteral(_ literal: String) { key += literal }
        mutating func appendInterpolation<T>(_ value: T) {
            key += "{\(arguments.count)}"
            arguments.append(String(describing: value))
        }
    }
}

enum L10n {
    static var language: AppLanguage {
        let selected = AppLanguage(rawValue: UserDefaults.standard.string(forKey: AppLanguage.defaultsKey) ?? "") ?? .system
        return selected.resolved()
    }

    static var locale: Locale { Locale(identifier: language.rawValue) }

    static func bundle(for language: AppLanguage) -> Bundle {
        guard let path = Bundle.main.path(forResource: language.resolved().rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return .main }
        return bundle
    }

    static func tr(_ message: LocalizedMessage, language: AppLanguage? = nil) -> String {
        let template = bundle(for: language ?? self.language).localizedString(forKey: message.key, value: message.key, table: nil)
        return interpolate(template, arguments: message.arguments)
    }

    static func interpolate(_ template: String, arguments: [String]) -> String {
        let expression = try! NSRegularExpression(pattern: #"\{(\d+)\}"#)
        let result = NSMutableString(string: template)
        // Work backwards so replacements cannot change offsets or interpolate user data again.
        for match in expression.matches(in: template, range: NSRange(template.startIndex..., in: template)).reversed() {
            let indexText = (template as NSString).substring(with: match.range(at: 1))
            if let index = Int(indexText), arguments.indices.contains(index) {
                result.replaceCharacters(in: match.range, with: arguments[index])
            }
        }
        return result as String
    }
}
