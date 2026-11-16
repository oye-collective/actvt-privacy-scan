//
//  ClaudeSummaryTitleTests.swift
//  ActvtSessionParsersTests
//

import XCTest
@testable import ActvtSessionParsers

/// A Claude Code session's summary title (B-061). Since 2026-10 Claude Code
/// writes request records (`api-request-shape`, `api-request-blob`, ~80-100 KB
/// each) near the head, so the first `ai-title` can sit past the 256 KB head
/// read, and it rewrites the title every turn, so the newest one is the title.
final class ClaudeSummaryTitleTests: XCTestCase {

    private var root: URL!
    private var project: URL { root.appendingPathComponent("-Users-x-proj", isDirectory: true) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("actvt-summary-title-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ records: [[String: Any]], id: String) throws {
        let body = try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try Data((body.joined(separator: "\n") + "\n").utf8)
            .write(to: project.appendingPathComponent("\(id).jsonl"))
    }

    private let prompt: [String: Any] = [
        "type": "user", "uuid": "u1", "timestamp": "2026-11-11T08:00:00.000Z", "isSidechain": false,
        "cwd": "/Users/x/proj", "gitBranch": "main",
        "message": ["role": "user", "content": "Base directory for this skill: /Users/x/.claude/skills/sse"]]

    private func reply(_ uuid: String) -> [String: Any] {
        ["type": "assistant", "uuid": uuid, "timestamp": "2026-11-11T08:00:05.000Z", "isSidechain": false,
         "message": ["model": "claude-opus-4-7", "role": "assistant", "content": [["type": "text", "text": "ok"]]]]
    }

    /// A request record the size of a real one: filler the summary skips.
    private func request(_ kb: Int) -> [String: Any] {
        ["type": "api-request-blob", "blob": String(repeating: "x", count: kb * 1024)]
    }

    private func title(_ text: String) -> [String: Any] { ["type": "ai-title", "aiTitle": text] }

    private func summary(_ id: String) async throws -> AgentSessionSummary {
        let source = ClaudeCodeSessionSource(rootURL: root)
        _ = try await source.listSessionRefs()
        return try await source.loadSummary(id: id)
    }

    /// The dgx loop shape: the head is the prompt and ~300 KB of request
    /// records, the titles come after. Before B-061 the title was the prompt.
    func testTheNewestTitleWinsWhenTheHeadIsFullOfRequestRecords() async throws {
        try write([prompt, request(100), request(100), request(100),
                   title("Sse loop"), reply("a1"), title("Senior software engineer tmux loop"), reply("a2")],
                  id: "loop")
        let s = try await summary("loop")
        XCTAssertEqual(s.aiTitle, "Senior software engineer tmux loop")
        XCTAssertEqual(s.title, "Senior software engineer tmux loop")
        XCTAssertEqual(s.projectPath, "/Users/x/proj", "cwd still comes from the head")
        XCTAssertEqual(s.gitBranch, "main")
    }

    /// A title in the head, with more than the tail's 64 KB written after it,
    /// is still the title.
    func testAHeadTitleIsKeptWhenTheTailHasNone() async throws {
        try write([prompt, title("Fix the deploy"), reply("a1"), request(100)], id: "early")
        let s = try await summary("early")
        XCTAssertEqual(s.aiTitle, "Fix the deploy")
    }

    /// A short session, whose head and tail overlap, takes its newest title.
    func testAShortSessionTakesItsNewestTitle() async throws {
        try write([prompt, title("First guess"), reply("a1"), title("Better title"), reply("a2")], id: "short")
        let s = try await summary("short")
        XCTAssertEqual(s.aiTitle, "Better title")
    }
}
