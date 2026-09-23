import Foundation
import XCTest
@testable import Codex_Quota

final class CodexTerminalResumeLauncherTests: XCTestCase {
    private func session(id: String, cwd: String) -> CodexSession {
        CodexSession(
            id: id, name: nil, preview: "test", cwd: cwd,
            createdAt: .now, updatedAt: .now, status: .idle
        )
    }

    func testAdversarialValuesReachOnlyFakeCLIAsLiteralArguments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ResumeTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("a 'quote' $HOME `touch BAD` 中文\nnext", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let fakeCLI = root.appendingPathComponent("fake 'codex'.sh")
        let output = root.appendingPathComponent("arguments")
        try Data("#!/bin/sh\nprintf '%s\\0' \"$PWD\" \"$@\" > \(ShellQuote.quote(output.path))\n".utf8).write(to: fakeCLI)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCLI.path)
        let id = "--option ' $HOME `touch BAD` 中文\nnext"
        let launcher = CodexTerminalResumeLauncher(scriptDirectory: root.appendingPathComponent("private"))
        let script = try launcher.prepareScript(for: session(id: id, cwd: project.path), executable: fakeCLI)
        let permissions = try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o700)
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: script.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(directoryPermissions?.intValue, 0o700)

        // Run only the fake CLI. This proves the generated shell script preserves arguments.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let arguments = try Data(contentsOf: output).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(arguments, [project.path, "resume", "--", id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: script.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("BAD").path))
    }

    func testMissingProjectAndCLILeaveNoCommandFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ResumeTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let launcher = CodexTerminalResumeLauncher(scriptDirectory: root.appendingPathComponent("private"))
        XCTAssertThrowsError(try launcher.prepareScript(for: session(id: "id", cwd: root.appendingPathComponent("missing").path), executable: URL(fileURLWithPath: "/bin/sh")))
        XCTAssertThrowsError(try launcher.prepareScript(for: session(id: "id", cwd: root.path), executable: root.appendingPathComponent("missing-cli")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("private").path))
    }

    func testOpenFailureReportsErrorAndRemovesCommandFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ResumeTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var openedScript: URL?
        let launcher = CodexTerminalResumeLauncher(
            scriptDirectory: root.appendingPathComponent("private"),
            resolveExecutable: { URL(fileURLWithPath: "/bin/sh") },
            terminalApplication: { URL(fileURLWithPath: "/Applications/Utilities/Terminal.app") },
            openCommand: { script, _, completion in
                openedScript = script
                completion(NSError(domain: "Test", code: 1))
            }
        )
        var receivedError: Error?
        launcher.launch(session(id: "id", cwd: root.path)) { receivedError = $0 }
        XCTAssertNotNil(receivedError)
        XCTAssertNotNil(openedScript)
        XCTAssertFalse(FileManager.default.fileExists(atPath: openedScript!.path))
    }

    func testCopyCommandQuotesApostropheAndOptionLikeID() {
        let command = session(id: "--a'b", cwd: "/tmp/a'b").resumeCommand
        XCTAssertEqual(command, "cd '/tmp/a'\\''b' && codex resume -- '--a'\\''b'")
    }
}
