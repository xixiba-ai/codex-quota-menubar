import Foundation
import XCTest
@testable import Codex_Quota

@MainActor
final class CodexSessionDataSourceTests: XCTestCase {
    private func response(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testEmptyDeleteSuccess() throws {
        let result = try CodexSessionDataSource.decodeResponse(response(#"{"id":2,"result":{}}"#))
        XCTAssertTrue(result.isEmpty)
    }

    func testServerRejectionPreservesCodeAndReason() throws {
        let message = try response(#"{"id":2,"error":{"code":-32600,"message":"Thread is in use","data":{"detail":"not displayed"}}}"#)
        XCTAssertThrowsError(try CodexSessionDataSource.decodeResponse(message)) { error in
            guard case let CodexSessionDataSource.Error.requestFailed(code, reason) = error else {
                return XCTFail("Expected a server rejection, got \(error)")
            }
            XCTAssertEqual(code, -32600)
            XCTAssertEqual(reason, "Thread is in use")
            XCTAssertTrue(error.localizedDescription.contains("Thread is in use"))
            XCTAssertFalse(error.localizedDescription.contains("not displayed"))
        }
    }

    func testMalformedResponsesRemainInvalid() throws {
        for json in [#"{"id":2}"#, #"{"id":2,"result":null}"#,
                     #"{"id":2,"result":[]}"#,
                     #"{"id":2,"error":{"code":-32600},"result":{}}"#] {
            let message = try response(json)
            XCTAssertThrowsError(try CodexSessionDataSource.decodeResponse(message)) { error in
                guard case CodexSessionDataSource.Error.invalidMessage = error else {
                    return XCTFail("Expected invalid response, got \(error)")
                }
            }
        }
    }

    func testActiveWriterRejectionExplainsHowToRetry() throws {
        // Captured from two real CLI processes sharing an isolated fixture home.
        let message = try response(#"{"id":2,"error":{"code":-32600,"message":"thread 00000000-0000-4000-8000-000000000001 already has an active writer"}}"#)
        XCTAssertThrowsError(try CodexSessionDataSource.decodeResponse(message)) { error in
            XCTAssertEqual(error.localizedDescription,
                           L10n.tr("会话仍被 Codex 或其他客户端占用。请先在对应客户端关闭该会话，再重试删除。"))
        }
    }

    func testListResponseKeepsDataAndCursor() throws {
        let result = try CodexSessionDataSource.decodeResponse(response(#"{"id":1,"result":{"data":[],"nextCursor":"page2"}}"#))
        XCTAssertEqual(result["nextCursor"] as? String, "page2")
        XCTAssertNotNil(result["data"] as? [[String: Any]])
    }
}
