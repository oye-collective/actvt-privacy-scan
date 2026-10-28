//
//  SubagentTranscriptTests.swift
//  ActvtSessionsKitTests
//

import XCTest
@testable import ActvtSessionsKit

/// A Claude Code session's subagents, each read from its own transcript.
/// Records are shaped like real ones on mac-bar (2026-10-20): every record
/// in a subagent's file is marked `isSidechain`.
final class SubagentTranscriptTests: XCTestCase {

    private var root: URL!
    private var project: URL { root.appendingPathComponent("-Users-x-proj", isDirectory: true) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("actvt-subagents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ records: [[String: Any]], to url: URL) throws {
        let body = try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try Data((body.joined(separator: "\n") + "\n").utf8).write(to: url)
    }

    private func user(_ uuid: String, _ text: String, sidechain: Bool) -> [String: Any] {
        ["type": "user", "uuid": uuid, "timestamp": "2026-03-01T12:00:00.000Z", "isSidechain": sidechain,
         "cwd": "/Users/x/proj", "message": ["role": "user", "content": text]]
    }

    private func toolCall(_ uuid: String, id: String, command: String, sidechain: Bool) -> [String: Any] {
        ["type": "assistant", "uuid": uuid, "timestamp": "2026-03-01T12:00:05.000Z", "isSidechain": sidechain,
         "message": ["model": "claude-opus-4-7", "role": "assistant",
                     "content": [["type": "tool_use", "id": id, "name": "Bash", "input": ["command": command]]]]]
    }

    private func toolResult(_ uuid: String, id: String, _ content: String, sidechain: Bool) -> [String: Any] {
        ["type": "user", "uuid": uuid, "timestamp": "2026-03-01T12:00:06.000Z", "isSidechain": sidechain,
         "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": content]]]]
    }

    /// The session: its own prompt, plus one subagent record written inline
    /// the way older Claude Code versions did. Two subagent files beside it,
    /// one with its `.meta.json` and one without.
    private func writeSession() throws {
        try write([user("p1", "audit the deploy", sidechain: false),
                   user("p2", "inline subagent prompt", sidechain: true)],
                  to: project.appendingPathComponent("s1.jsonl"))
        let subagents = project.appendingPathComponent("s1/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        try write([user("a1", "check the logs", sidechain: true),
                   toolCall("a2", id: "t1", command: "tail -n 50 app.log", sidechain: true),
                   toolResult("a3", id: "t1", "all quiet", sidechain: true)],
                  to: subagents.appendingPathComponent("agent-a42.jsonl"))
        try Data(#"{"agentType":"Explore","description":"Check the logs"}"#.utf8)
            .write(to: subagents.appendingPathComponent("agent-a42.meta.json"))
        try write([user("b1", "count the errors", sidechain: true)],
                  to: subagents.appendingPathComponent("agent-b7.jsonl"))
    }

    /// The session's thread leaves subagent records out, inline or not.
    func testSessionThreadExcludesSubagentRecords() async throws {
        try writeSession()
        let source = ClaudeCodeSessionSource(rootURL: root)
        _ = try await source.listSessionRefs()
        let transcript = try await source.loadTranscript(id: "s1", window: .latest)
        XCTAssertEqual(transcript.turns.map(\.recordUUID), ["p1"])
    }

    /// Each subagent file is listed, with its type and task when recorded.
    func testListsSubagents() async throws {
        try writeSession()
        let source = ClaudeCodeSessionSource(rootURL: root)
        _ = try await source.listSessionRefs()
        let subagents = try await source.listSubagents(of: "s1")
        XCTAssertEqual(subagents, [
            AgentSubagentRef(sessionId: "s1", agentId: "a42", agentType: "Explore", description: "Check the logs"),
            AgentSubagentRef(sessionId: "s1", agentId: "b7", agentType: nil, description: nil),
        ])
    }

    /// A subagent's transcript reads in full: every record in its file is its
    /// own, though each is marked `isSidechain`.
    func testLoadsASubagentsTranscript() async throws {
        try writeSession()
        let source = ClaudeCodeSessionSource(rootURL: root)
        _ = try await source.listSessionRefs()
        let subagent = try await source.listSubagents(of: "s1")[0]
        let transcript = try await source.loadTranscript(of: subagent, window: .latest)
        XCTAssertEqual(transcript.sessionId, "s1")
        XCTAssertEqual(transcript.projectPath, "/Users/x/proj")
        XCTAssertEqual(transcript.turns.map(\.recordUUID), ["a1", "a2"])
        XCTAssertEqual(transcript.toolResultsByID["t1"]?.content, "all quiet")
    }

    /// A session that spawned none lists none.
    func testSessionWithoutSubagentsListsNone() async throws {
        try write([user("p1", "hello", sidechain: false)], to: project.appendingPathComponent("s2.jsonl"))
        let source = ClaudeCodeSessionSource(rootURL: root)
        _ = try await source.listSessionRefs()
        let subagents = try await source.listSubagents(of: "s2")
        XCTAssertEqual(subagents, [])
    }
}
