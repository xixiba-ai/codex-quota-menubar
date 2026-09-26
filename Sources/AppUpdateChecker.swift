import Foundation

/// A SemVer 2.0 version. Build metadata does not affect precedence.
struct AppVersion: Comparable, Equatable {
    let major: UInt64
    let minor: UInt64
    let patch: UInt64
    let prerelease: [String]

    init?(tag: String) {
        let value = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let pattern = #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"#
        guard let range = value.range(of: pattern, options: .regularExpression),
              range.lowerBound == value.startIndex, range.upperBound == value.endIndex else { return nil }
        let core = value.split(separator: "-", maxSplits: 1)[0].split(separator: "+", maxSplits: 1)[0]
        let numbers = core.split(separator: ".")
        guard numbers.count == 3,
              let major = UInt64(numbers[0]), let minor = UInt64(numbers[1]), let patch = UInt64(numbers[2]) else { return nil }
        let withoutBuild = value.split(separator: "+", maxSplits: 1)[0]
        let identifiers = withoutBuild.split(separator: "-", maxSplits: 1).dropFirst().first.map { String($0).split(separator: ".").map(String.init) } ?? []
        guard identifiers.allSatisfy({ identifier in
            !identifier.allSatisfy(\.isNumber) || identifier == "0" || !identifier.hasPrefix("0")
        }) else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
        prerelease = identifiers
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) {
            if left == right { continue }
            let leftNumeric = left.allSatisfy(\.isNumber)
            let rightNumeric = right.allSatisfy(\.isNumber)
            if leftNumeric != rightNumeric { return leftNumeric }
            if leftNumeric {
                if left.count != right.count { return left.count < right.count }
                return left.lexicographicallyPrecedes(right)
            }
            return left.lexicographicallyPrecedes(right)
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    /// The explicit release tag keeps a preview build distinct from its final version.
    static func currentTag(in bundle: Bundle = .main) -> String {
        if let tag = bundle.object(forInfoDictionaryKey: "CodexQuotaReleaseVersion") as? String,
           AppVersion(tag: tag) != nil { return tag }
        let marketing = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        if !build.isEmpty, AppVersion(tag: "\(marketing)-preview.\(build)") != nil {
            return "v\(marketing)-preview.\(build)"
        }
        return "v\(marketing)"
    }
}

struct AppRelease: Equatable {
    let tag: String
    let url: URL
}

enum AppUpdateResult: Equatable {
    case upToDate
    case updateAvailable(AppRelease)
}

enum AppUpdateError: Error, Equatable {
    case invalidCurrentVersion
    case unavailable
    case invalidResponse
}

struct AppUpdateChecker {
    static let releasesURL = URL(string: "https://github.com/xixiba-ai/codex-quota-menubar/releases")!
    static let apiURL = URL(string: "https://api.github.com/repos/xixiba-ai/codex-quota-menubar/releases?per_page=100")!

    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func check(currentTag: String) async throws -> AppUpdateResult {
        guard let current = AppVersion(tag: currentTag) else { throw AppUpdateError.invalidCurrentVersion }
        var request = URLRequest(url: Self.apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CodexQuotaMenuBar", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw AppUpdateError.unavailable }
        guard let http = response as? HTTPURLResponse else { throw AppUpdateError.invalidResponse }
        guard http.statusCode == 200 else { throw AppUpdateError.unavailable }
        guard let releases = try? JSONDecoder().decode([GitHubRelease].self, from: data) else {
            throw AppUpdateError.invalidResponse
        }

        let validReleases = releases
            .filter { !$0.draft }
            .compactMap { release -> (version: AppVersion, release: AppRelease)? in
                guard let version = AppVersion(tag: release.tagName),
                      let url = Self.releaseURL(for: release.tagName) else { return nil }
                return (version, AppRelease(tag: release.tagName, url: url))
            }
        guard !validReleases.isEmpty else { throw AppUpdateError.invalidResponse }
        let newest = validReleases
            .filter { !current.prerelease.isEmpty || $0.version.prerelease.isEmpty }
            .max { $0.version < $1.version }
        guard let newest else { return .upToDate }
        guard newest.version > current else { return .upToDate }
        return .updateAvailable(newest.release)
    }

    private static func releaseURL(for tag: String) -> URL? {
        // SemVer tags contain only URL path-safe ASCII characters after parsing.
        guard AppVersion(tag: tag) != nil else { return nil }
        return releasesURL.appendingPathComponent("tag").appendingPathComponent(tag)
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let draft: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case draft
        }
    }
}
