//
//  SummaryMessageCountTests.swift
//  ActvtSessionParsersTests
//

import XCTest
@testable import ActvtSessionParsers

/// A summary's message count (B-065). The summary reads only the file's head,
/// so it has a count only when that head is the whole file, and it counts as
/// the metrics index does: one per assistant response, though Claude Code
/// writes a record per content block. Before, a long session showed its
/// head's count (1 on dgx's loops) and a short one counted every block.
final class SummaryMessageCountTests: XCTestCase {

    private var root: URL!
    private var project: URL { root.appendingPathComponent("-Users-x-proj", isDirectory: true) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("actvt-summary-count-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ records: [[String: Any]], id: String, trailer: String = "") throws {
        let body = try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try Data((body.joined(separator: "\n") + "\n" + trailer).utf8)
            .write(to: project.appendingPathComponent("\(id).jsonl"))
    }

    private func prompt(_ uuid: String) -> [String: Any] {
        ["type": "user", "uuid": uuid, "timestamp": "2026-11-19T08:00:00.000Z", "isSidechain": false,
         "cwd": "/Users/x/proj", "gitBranch": "main",
         "message": ["role": "user", "content": "Fix the deploy"]]
    }

    /// One record of response `response`: Claude Code writes one per content block.
    private func block(_ uuid: String, response: String) -> [String: Any] {
        ["type": "assistant", "uuid": uuid, "timestamp": "2026-11-19T08:00:05.000Z", "isSidechain": false,
         "message": ["id": response, "model": "claude-opus-4-7", "role": "assistant",
                     "content": [["type": "text", "text": "ok"]]]]
    }

    private func filler(_ kb: Int) -> [String: Any] {
        ["type": "api-request-blob", "blob": String(repeating: "x", count: kb * 1024)]
    }

    private func summary(_ id: String) async throws -> AgentSessionSummary {
        let source = ClaudeCodeSessionSource(rootURL: root)
        _ = try await source.listSessionRefs()
        return try await source.loadSummary(id: id)
    }

    /// Two prompts, two responses of three and two blocks: 4 messages, not 7.
    func testAShortSessionCountsEachResponseOnce() async throws {
        try write([prompt("u1"), block("a1", response: "r1"), block("a2", response: "r1"), block("a3", response: "r1"),
                   prompt("u2"), block("a4", response: "r2"), block("a5", response: "r2")], id: "short")
        let count = try await summary("short").messageCount
        XCTAssertEqual(count, 4)
    }

    /// A session longer than the head read has no count: the head's would be
    /// a fraction of it.
    func testASessionLongerThanTheHeadHasNoCount() async throws {
        try write([prompt("u1"), block("a1", response: "r1"), filler(300),
                   prompt("u2"), block("a2", response: "r2")], id: "long")
        let s = try await summary("long")
        XCTAssertNil(s.messageCount)
        XCTAssertEqual(s.projectPath, "/Users/x/proj", "the rest of the summary still comes from the head")
    }

    /// More lines than the head takes is not the whole file either.
    func testASessionWithMoreLinesThanTheHeadTakesHasNoCount() async throws {
        var records: [[String: Any]] = []
        for i in 0..<120 {
            records.append(prompt("u\(i)"))
            records.append(block("a\(i)", response: "r\(i)"))
        }
        try write(records, id: "many")
        let count = try await summary("many").messageCount
        XCTAssertNil(count)
    }

    /// A last record still being written (no newline yet) isn't a line, and
    /// doesn't stop the file from being read whole.
    func testARecordStillBeingWrittenIsLeftOut() async throws {
        try write([prompt("u1"), block("a1", response: "r1")], id: "live", trailer: #"{"type":"user","uuid":"u2","#)
        let count = try await summary("live").messageCount
        XCTAssertEqual(count, 2)
    }

    /// The head, exactly: a file that ends at the byte limit is whole, and
    /// one byte more is not.
    func testTheHeadKnowsWhereTheFileEnds() throws {
        let line = Data(repeating: 0x61, count: 1023) + Data([0x0A])
        let exact = root.appendingPathComponent("exact.jsonl")
        try Data((0..<(SessionFileHead.byteLimit / 1024)).flatMap { _ in line }).write(to: exact)
        let whole = try SessionFileHead(url: exact, maxLines: 1000)
        XCTAssertTrue(whole.isWholeFile)
        XCTAssertEqual(whole.lines.count, 256)

        let over = root.appendingPathComponent("over.jsonl")
        try (Data(contentsOf: exact) + Data([0x62])).write(to: over)
        XCTAssertFalse(try SessionFileHead(url: over, maxLines: 1000).isWholeFile)
    }
}
