import XCTest
@testable import Codex_Quota

final class AppVersionTests: XCTestCase {
    func testSemVerPrecedenceIncludingPreviewAndStable() {
        let ordered = [
            "v1.0.0-preview.3", "v1.0.0-preview.4", "v1.0.0-preview.10",
            "v1.0.0-rc.1", "v1.0.0", "v1.0.1"
        ].compactMap(AppVersion.init(tag:))
        XCTAssertEqual(ordered.count, 6)
        for index in 1..<ordered.count {
            XCTAssertLessThan(ordered[index - 1], ordered[index])
        }
        XCTAssertEqual(AppVersion(tag: "v1.0.0+build.8"), AppVersion(tag: "1.0.0+build.9"))
        XCTAssertLessThan(AppVersion(tag: "1.0.0-alpha.1")!, AppVersion(tag: "1.0.0-alpha.beta")!)
    }

    func testRejectsMalformedTags() {
        for tag in ["", "1.0", "1.0.0.1", "1.0.0-preview.03", "01.0.0", "1.0.0-", "1.0.0/../../other"] {
            XCTAssertNil(AppVersion(tag: tag), tag)
        }
    }
}

final class AppUpdateCheckerTests: XCTestCase {
    override func tearDown() {
        UpdateURLProtocol.handler = nil
        super.tearDown()
    }

    func testSelectsHighestPublishedReleaseIncludingPrereleases() async throws {
        UpdateURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "api.github.com")
            XCTAssertEqual(request.url?.path, "/repos/xixiba-ai/codex-quota-menubar/releases")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (200, Data("""
            [
              {"tag_name":"v9.0.0","draft":true},
              {"tag_name":"v1.0.0-preview.10","draft":false,"html_url":"https://evil.example/"},
              {"tag_name":"v1.0.0-preview.4","draft":false},
              {"tag_name":"unexpected-tag","draft":false}
            ]
            """.utf8))
        }
        let result = try await checker().check(currentTag: "v1.0.0-preview.3")
        XCTAssertEqual(result, .updateAvailable(AppRelease(
            tag: "v1.0.0-preview.10",
            url: URL(string: "https://github.com/xixiba-ai/codex-quota-menubar/releases/tag/v1.0.0-preview.10")!
        )))
    }

    func testStableReleaseOutranksPreviewAndCurrentStableIsUpToDate() async throws {
        UpdateURLProtocol.handler = { _ in
            (200, Data("""
            [{"tag_name":"v1.0.0-preview.20","draft":false},
             {"tag_name":"v1.0.0","draft":false}]
            """.utf8))
        }
        let previewResult = try await checker().check(currentTag: "v1.0.0-preview.3")
        XCTAssertEqual(previewResult,
                       .updateAvailable(AppRelease(tag: "v1.0.0", url: URL(string: "https://github.com/xixiba-ai/codex-quota-menubar/releases/tag/v1.0.0")!)))
        let stableResult = try await checker().check(currentTag: "v1.0.0")
        XCTAssertEqual(stableResult, .upToDate)
    }

    func testInstalledStableReleaseIgnoresNewerPrerelease() async throws {
        UpdateURLProtocol.handler = { _ in
            (200, Data("""
            [{"tag_name":"v1.1.0-preview.1","draft":false},
             {"tag_name":"v1.0.0","draft":false}]
            """.utf8))
        }
        let result = try await checker().check(currentTag: "v1.0.0")
        XCTAssertEqual(result, .upToDate)

        UpdateURLProtocol.handler = { _ in
            (200, Data(#"[{"tag_name":"v1.1.0-preview.1","draft":false}]"#.utf8))
        }
        let previewsOnlyResult = try await checker().check(currentTag: "v1.0.0")
        XCTAssertEqual(previewsOnlyResult, .upToDate)
    }

    func testNoUsablePublishedReleasesIsInvalidResponse() async {
        UpdateURLProtocol.handler = { _ in
            (200, Data("""
            [{"tag_name":"v2.0.0","draft":true},
             {"tag_name":"not-a-version","draft":false}]
            """.utf8))
        }
        do {
            _ = try await checker().check(currentTag: "v1.0.0-preview.3")
            XCTFail("Expected invalid response")
        } catch { XCTAssertEqual(error as? AppUpdateError, .invalidResponse) }
    }

    func testHTTPAndMalformedResponsesReturnSafeErrors() async {
        UpdateURLProtocol.handler = { _ in (503, Data(#"{"message":"private details"}"#.utf8)) }
        do {
            _ = try await checker().check(currentTag: "v1.0.0-preview.3")
            XCTFail("Expected unavailable")
        } catch { XCTAssertEqual(error as? AppUpdateError, .unavailable) }

        UpdateURLProtocol.handler = { _ in (200, Data("not JSON".utf8)) }
        do {
            _ = try await checker().check(currentTag: "v1.0.0-preview.3")
            XCTFail("Expected invalid response")
        } catch { XCTAssertEqual(error as? AppUpdateError, .invalidResponse) }
    }

    func testTransportErrorReturnsSafeError() async {
        UpdateURLProtocol.handler = { _ in
            throw NSError(domain: "PrivateTransportDetails", code: -1)
        }
        do {
            _ = try await checker().check(currentTag: "v1.0.0-preview.3")
            XCTFail("Expected unavailable")
        } catch { XCTAssertEqual(error as? AppUpdateError, .unavailable) }
    }

    func testInvalidInstalledVersionStopsBeforeNetwork() async {
        UpdateURLProtocol.handler = { _ in
            XCTFail("No request expected")
            return (200, Data("[]".utf8))
        }
        do {
            _ = try await checker().check(currentTag: "bad")
            XCTFail("Expected invalid current version")
        } catch { XCTAssertEqual(error as? AppUpdateError, .invalidCurrentVersion) }
    }

    private func checker() -> AppUpdateChecker {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateURLProtocol.self]
        return AppUpdateChecker(session: URLSession(configuration: configuration))
    }
}

private final class UpdateURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
