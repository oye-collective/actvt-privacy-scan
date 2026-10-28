//
//  CLIRunnerTests.swift
//  ActvtSessionsKitTests
//

import XCTest
@testable import ActvtSessionsKit

/// End-to-end CLI logic against fixture transcript roots (no real home-dir
/// reads — explicit roots only construct the overridden providers).
final class CLIRunnerTests: XCTestCase {

    private var claudeRoot: URL!

    override func setUp() {
        super.setUp()
        claudeRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("actvt-cli-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: claudeRoot)
        super.tearDown()
    }

    private func writeSession(id: String, text: String) throws {
        let projectDir = claudeRoot.appendingPathComponent("-Users-x-proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let record: [String: Any] = [
            "type": "user", "uuid": "u1", "timestamp": "2026-07-16T10:00:00.000Z",
            "cwd": "/Users/x/proj",
            "message": ["role": "user", "content": text],
        ]
        let line = try JSONSerialization.data(withJSONObject: record)
        try (line + Data("\n".utf8)).write(to: projectDir.appendingPathComponent("\(id).jsonl"))
    }

    private func runCLI(_ arguments: [String]) async -> (status: Int32, stdout: String, stderr: String) {
        var out = "", err = ""
        let status = await CLIRunner.run(
            arguments: arguments,
            stdout: { out += $0 + "\n" },
            stderr: { err += $0 + "\n" }
        )
        return (status.code, out, err)
    }

    func testVersion() async {
        let result = await runCLI(["--version"])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), CLIRunner.version)
    }

    func testSessionsJSONAgainstFixture() async throws {
        try writeSession(id: "sess-1", text: "hello from fixture")
        let result = await runCLI(["sessions", "--json", "--claude-root", claudeRoot.path])
        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")

        let payload = try RemoteSessionPayload.makeDecoder()
            .decode(RemoteSessionPayload.self, from: Data(result.stdout.utf8))
        XCTAssertEqual(payload.schemaVersion, RemoteSessionPayload.currentSchemaVersion)
        XCTAssertEqual(payload.sessions.count, 1)
        XCTAssertEqual(payload.sessions[0].id, "sess-1")
        XCTAssertEqual(payload.sessions[0].agentKind, "claudeCode")
        XCTAssertEqual(payload.sessions[0].projectPath, "/Users/x/proj")
        XCTAssertEqual(payload.sessions[0].title, "hello from fixture")
    }

    func testLimitCapsSessions() async throws {
        for i in 0..<5 { try writeSession(id: "sess-\(i)", text: "s\(i)") }
        let result = await runCLI(["sessions", "--json", "--limit", "2", "--claude-root", claudeRoot.path])
        let payload = try RemoteSessionPayload.makeDecoder()
            .decode(RemoteSessionPayload.self, from: Data(result.stdout.utf8))
        XCTAssertEqual(payload.sessions.count, 2)
    }

    func testEmptyRootYieldsEmptySessions() async throws {
        let result = await runCLI(["sessions", "--json", "--claude-root", claudeRoot.path])
        XCTAssertEqual(result.status, 0)
        let payload = try RemoteSessionPayload.makeDecoder()
            .decode(RemoteSessionPayload.self, from: Data(result.stdout.utf8))
        XCTAssertTrue(payload.sessions.isEmpty)
    }

    func testUsageErrors() async {
        let noJSON = await runCLI(["sessions"])
        XCTAssertEqual(noJSON.status, 64)

        let badLimit = await runCLI(["sessions", "--json", "--limit", "zero"])
        XCTAssertEqual(badLimit.status, 64)

        let unknown = await runCLI(["frobnicate"])
        XCTAssertEqual(unknown.status, 64)
    }

    // MARK: - transcript

    func testTranscriptJSONAgainstFixture() async throws {
        try writeSession(id: "sess-1", text: "hello transcript")
        let result = await runCLI([
            "transcript", "--json", "--id", "sess-1", "--kind", "claudeCode",
            "--claude-root", claudeRoot.path,
        ])
        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")

        let payload = try RemoteSessionPayload.makeDecoder()
            .decode(RemoteTranscriptPayload.self, from: Data(result.stdout.utf8))
        XCTAssertEqual(payload.schemaVersion, RemoteTranscriptPayload.currentSchemaVersion)
        XCTAssertEqual(payload.cliVersion, CLIRunner.version)
        XCTAssertEqual(payload.transcript.sessionId, "sess-1")
        XCTAssertEqual(payload.transcript.agentKind, "claudeCode")
        XCTAssertEqual(payload.transcript.turns.count, 1)
        XCTAssertEqual(payload.transcript.turns[0].role, "user")
        XCTAssertEqual(payload.transcript.turns[0].text, "hello transcript")
    }

    func testTranscriptWithoutKindFallsBackToProviderSweep() async throws {
        try writeSession(id: "sess-2", text: "found without kind")
        let result = await runCLI([
            "transcript", "--json", "--id", "sess-2", "--claude-root", claudeRoot.path,
        ])
        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let payload = try RemoteSessionPayload.makeDecoder()
            .decode(RemoteTranscriptPayload.self, from: Data(result.stdout.utf8))
        XCTAssertEqual(payload.transcript.turns.first?.text, "found without kind")
    }

    // MARK: - pi

    private func writePiSession(id: String, text: String) throws -> URL {
        let piRoot = claudeRoot.appendingPathComponent("pi", isDirectory: true)
        let dir = piRoot.appendingPathComponent("--home-x-proj--", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lines: [[String: Any]] = [
            ["type": "session", "version": 3, "id": id, "timestamp": "2026-09-11T11:35:11.959Z", "cwd": "/home/x/proj"],
            ["type": "message", "id": "u1", "parentId": NSNull(), "timestamp": "2026-09-11T11:36:42.568Z",
             "message": ["role": "user", "content": [["type": "text", "text": text]], "timestamp": 1]],
        ]
        var data = Data()
        for line in lines {
            data.append(try JSONSerialization.data(withJSONObject: line))
            data.append(Data("\n".utf8))
        }
        try data.write(to: dir.appendingPathComponent("2026-09-11T11-35-11-959Z_\(id).jsonl"))
        return piRoot
    }

    func testSessionsListsPiRoot() async throws {
        let id = "01a09040-0d56-77d0-812d-b9b758f2b046"
        let piRoot = try writePiSession(id: id, text: "hello from pi")
        let result = await runCLI(["sessions", "--json", "--pi-root", piRoot.path])
        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")

        let payload = try RemoteSessionPayload.makeDecoder()
            .decode(RemoteSessionPayload.self, from: Data(result.stdout.utf8))
        XCTAssertEqual(payload.sessions.count, 1)
        XCTAssertEqual(payload.sessions[0].agentKind, "pi")
        XCTAssertEqual(payload.sessions[0].kind, .pi)
        XCTAssertEqual(payload.sessions[0].id, id)
        XCTAssertEqual(payload.sessions[0].projectPath, "/home/x/proj")
        XCTAssertEqual(payload.sessions[0].title, "hello from pi")
    }

    func testTranscriptByPiKind() async throws {
        let id = "01a09040-0d56-77d0-812d-b9b758f2b046"
        let piRoot = try writePiSession(id: id, text: "pi transcript")
        try writeSession(id: "sess-1", text: "claude too")
        let result = await runCLI([
            "transcript", "--json", "--id", id, "--kind", "pi",
            "--claude-root", claudeRoot.path, "--pi-root", piRoot.path,
        ])
        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let payload = try RemoteSessionPayload.makeDecoder()
            .decode(RemoteTranscriptPayload.self, from: Data(result.stdout.utf8))
        XCTAssertEqual(payload.transcript.agentKind, "pi")
        XCTAssertEqual(payload.transcript.projectPath, "/home/x/proj")
        XCTAssertEqual(payload.transcript.turns.map(\.text), ["pi transcript"])
    }

    func testTranscriptUnknownIDFails() async throws {
        let result = await runCLI([
            "transcript", "--json", "--id", "no-such-session", "--claude-root", claudeRoot.path,
        ])
        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      "a failed lookup must leave stdout empty for the app's empty-response check")
    }

    func testTranscriptUsageErrors() async {
        let noID = await runCLI(["transcript", "--json"])
        XCTAssertEqual(noID.status, 64)

        let noJSON = await runCLI(["transcript", "--id", "x"])
        XCTAssertEqual(noJSON.status, 64)
    }
}
