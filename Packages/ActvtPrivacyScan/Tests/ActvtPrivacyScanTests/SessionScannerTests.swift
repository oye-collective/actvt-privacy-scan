//
//  SessionScannerTests.swift
//  ActvtPrivacyScanTests
//

import ActvtSessionsKit
import XCTest
@testable import ActvtPrivacyScan

final class SessionScannerTests: XCTestCase {

    private let token = "ghp_" + String(repeating: "A1b2", count: 9)
    /// A real-format IBAN and card number: they pass MOD97 and Luhn, so the
    /// detector reports them wherever it is shown them.
    private let iban = "GB82WEST12345698765432"
    private let card = "4111111111111111"
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("privacy-scan-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("-Users-x-proj"),
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeClaudeSession(_ id: String, _ records: [[String: Any]]) throws {
        let body = try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try Data((body.joined(separator: "\n") + "\n").utf8)
            .write(to: root.appendingPathComponent("-Users-x-proj/\(id).jsonl"))
    }

    private func session() throws -> [[String: Any]] {
        [
            ["type": "user", "uuid": "u1", "timestamp": "2026-03-01T12:00:00.000Z", "cwd": "/Users/x/proj",
             "message": ["role": "user", "content": "deploy with mail to ops@example.com"]],
            ["type": "assistant", "uuid": "a1", "timestamp": "2026-03-01T12:00:05.000Z",
             "message": ["model": "claude-opus-4-7", "role": "assistant",
                         "content": [["type": "tool_use", "id": "t1", "name": "Bash",
                                      "input": ["command": "export GITHUB_TOKEN=\(token)"]]]]],
            ["type": "user", "uuid": "u2", "timestamp": "2026-03-01T12:00:06.000Z",
             "message": ["role": "user",
                         "content": [["type": "tool_result", "tool_use_id": "t1", "content": "password=hunter2hunter2"]]]],
            // Not text: an attached image's base64 and a record id. Neither may be read.
            ["type": "user", "uuid": card, "timestamp": "2026-03-01T12:00:07.000Z",
             "message": ["role": "user",
                         "content": [["type": "image",
                                      "source": ["type": "base64", "media_type": "image/png", "data": "iVBOR\(iban)xyz"]]]]],
        ]
    }

    /// Findings come from the prompt, the tool call and the tool output, and
    /// never from image data or record ids.
    func testScansWhatAPersonReadsAndNothingElse() async throws {
        try writeClaudeSession("s1", try session())
        let source = ClaudeCodeSessionSource(rootURL: root)
        let refs = try await source.listSessionRefs()
        XCTAssertEqual(refs.map(\.id), ["s1"])

        let findings = try await SessionScanner().scan(refs[0], from: source)
        XCTAssertEqual(findings.map(\.kind), [.user, .toolInput, .toolResult])
        XCTAssertEqual(findings.map(\.category), [.privateEmail, .secret, .secret])
        XCTAssertEqual(findings[1].tool, "Bash")
        XCTAssertEqual(findings[1].length, token.count)
        XCTAssertFalse(findings.contains { $0.category == .bankAccount || $0.category == .creditCard })
    }

    /// No finding carries the value or its end.
    func testFindingsNeverHoldTheValue() async throws {
        try writeClaudeSession("s1", try session())
        let source = ClaudeCodeSessionSource(rootURL: root)
        let ref = try await source.listSessionRefs()[0]
        for finding in try await SessionScanner().scan(ref, from: source) {
            XCTAssertFalse(finding.preview.contains(token))
            XCTAssertFalse(finding.preview.contains("hunter2"))
            XCTAssertFalse(finding.preview.contains("ops@"))
        }
        XCTAssertEqual(SessionScanner.preview(of: token), "ghp_… (40 chars)")
        XCTAssertEqual(SessionScanner.preview(of: "hunter2hunter2"), "… (14 chars)")
    }

    /// The same secret twice counts as one distinct value.
    func testRepeatsShareAHash() async throws {
        var records = try session()
        records.append(["type": "user", "uuid": "u3", "timestamp": "2026-03-01T12:00:08.000Z",
                        "message": ["role": "user", "content": "again: \(token)"]])
        try writeClaudeSession("s1", records)
        let source = ClaudeCodeSessionSource(rootURL: root)
        let ref = try await source.listSessionRefs()[0]
        let tokens = try await SessionScanner().scan(ref, from: source).filter { $0.length == token.count }
        XCTAssertEqual(tokens.count, 2)
        XCTAssertEqual(Set(tokens.map(\.valueHash)).count, 1)
    }

    /// A secret a subagent typed is found in its own transcript, and says
    /// which subagent; the session's thread is scanned once as before.
    func testScansSubagentTranscripts() async throws {
        try writeClaudeSession("s1", try session())
        let dir = root.appendingPathComponent("-Users-x-proj/s1/subagents")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let records: [[String: Any]] = [
            ["type": "user", "uuid": "su1", "timestamp": "2026-03-01T12:01:00.000Z", "isSidechain": true,
             "agentId": "a42", "cwd": "/Users/x/proj", "message": ["role": "user", "content": "check the deploy"]],
            ["type": "assistant", "uuid": "sa1", "timestamp": "2026-03-01T12:01:05.000Z", "isSidechain": true,
             "agentId": "a42",
             "message": ["model": "claude-opus-4-7", "role": "assistant",
                         "content": [["type": "tool_use", "id": "st1", "name": "Bash",
                                      "input": ["command": "curl -H 'Authorization: token \(token)'"]]]]],
        ]
        let body = try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try Data((body.joined(separator: "\n") + "\n").utf8).write(to: dir.appendingPathComponent("agent-a42.jsonl"))
        try Data(#"{"agentType":"general-purpose","description":"Check the deploy"}"#.utf8)
            .write(to: dir.appendingPathComponent("agent-a42.meta.json"))

        let source = ClaudeCodeSessionSource(rootURL: root)
        let ref = try await source.listSessionRefs()[0]
        let findings = try await SessionScanner().scan(ref, from: source)
        XCTAssertEqual(findings.filter { $0.subagent == nil }.map(\.kind), [.user, .toolInput, .toolResult])
        let fromSubagent = findings.filter { $0.subagent != nil }
        XCTAssertEqual(fromSubagent.map(\.kind), [.toolInput])
        XCTAssertEqual(fromSubagent.first?.tool, "Bash")
        XCTAssertEqual(fromSubagent.first?.subagent?.agentType, "general-purpose")
        XCTAssertEqual(fromSubagent.first?.length, token.count)
    }

    /// System notifications are scaffolding, and empty texts are skipped.
    func testScannableTextsSkipNotificationsAndEmptyText() {
        let at = Date(timeIntervalSince1970: 0)
        let transcript = AgentTranscript(
            sessionId: "s", agentKind: .claudeCode, projectPath: "/p",
            turns: [
                .systemNotification(recordUUID: "n", text: "mail ops@example.com", timestamp: at),
                .user(recordUUID: "u", text: "", timestamp: at),
                .assistant(recordUUID: "a", blocks: [.thinking("hmm"), .text("ok")], timestamp: at),
            ],
            toolResultsByID: ["t": ToolResult(content: "out", isError: false)])
        XCTAssertEqual(transcript.scannableTexts.map(\.kind), [.thinking, .assistant, .toolResult])
    }
}
