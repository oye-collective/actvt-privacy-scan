//
//  PiSubagentTests.swift
//  ActvtSessionParsersTests
//

import XCTest
@testable import ActvtSessionParsers

/// pi-subagents (0.84, on pi 1.4) writes a session's children under the
/// session's own directory, one to four levels down. They are part of that
/// session, never sessions of their own (T-042). Layout as pi-subagents
/// wrote it on 2026-11-04 (`media/T-042/fixture` in the engineering workspace).
final class PiSubagentTests: XCTestCase {

    private var root: URL!
    private let stem = "2026-11-04T15-54-26-218Z_01a1a744-cc29-741f-ae81-a68a5e76fc15"
    private let slug = "--Users-dev-proj--"

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pi-subagents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func file(_ relative: String, id: String, modified: Date) throws -> URL {
        let url = root.appendingPathComponent(slug).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let header = "{\"type\":\"session\",\"version\":3,\"id\":\"\(id)\",\"timestamp\":\"2026-11-04T15:54:26.218Z\",\"cwd\":\"/Users/dev/proj\"}"
        let user = "{\"type\":\"message\",\"id\":\"u-\(id.prefix(4))\",\"parentId\":null,\"timestamp\":\"2026-11-04T15:54:27.000Z\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"hello from \(id.prefix(8))\"}],\"timestamp\":1}}"
        try Data((header + "\n" + user + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    func testSubAgentsAreListedUnderTheirSession() async throws {
        let t0 = Date(timeIntervalSince1970: 1_793_000_000)
        try file("\(stem).jsonl", id: "01a1a744-cc29-741f-ae81-a68a5e76fc15", modified: t0)
        let fresh = try file("\(stem)/de2a0644/run-0/session.jsonl", id: "01a1a745-0001", modified: t0.addingTimeInterval(10))
        let nester = try file("\(stem)/8e118adb/run-0/session.jsonl", id: "01a1a745-0002", modified: t0.addingTimeInterval(20))
        let nested = try file("\(stem)/8e118adb/run-0/session/c21ad263/run-0/session.jsonl", id: "01a1a745-0003",
                              modified: t0.addingTimeInterval(30))
        let fork = try file("\(stem)/forks/d833019b/2026-11-04T15-55-00-601Z_01a1a745-5279-741f-ae81-a68ca3af6ab5.jsonl",
                            id: "01a1a745-5279-741f-ae81-a68ca3af6ab5", modified: t0.addingTimeInterval(40))
        // pi-subagents' own copies of the transcripts: never part of the count.
        try file("\(stem)/8e118adb/run-0/subagent-artifacts/c21ad263_t042-leaf_0_transcript.jsonl", id: "copy",
                 modified: t0.addingTimeInterval(50))
        try file("subagent-artifacts/de2a0644_t042-leaf_0_transcript.jsonl", id: "copy2", modified: t0.addingTimeInterval(50))

        let source = PiSessionSource(rootURL: root)
        let refs = try await source.listSessionRefs()
        XCTAssertEqual(refs.map(\.id), ["01a1a744-cc29-741f-ae81-a68a5e76fc15"])
        XCTAssertEqual(refs[0].lastUpdatedAt.timeIntervalSince1970, t0.addingTimeInterval(40).timeIntervalSince1970,
                       accuracy: 1, "the session was last updated when its newest sub-agent was")

        let summary = try await source.loadSummary(id: refs[0].id)
        XCTAssertEqual(summary.subagentCount, 4)
        XCTAssertEqual(summary.title, "hello from 01a1a744")

        let indexableRead = await source.indexableFile(for: refs[0].id)
        let indexable = try XCTUnwrap(indexableRead)
        XCTAssertEqual(Set(indexable.subagents.values.map(\.standardizedFileURL)),
                       Set([fresh, nester, nested, fork].map(\.standardizedFileURL)))
        XCTAssertEqual(indexable.mtime.timeIntervalSince1970, t0.addingTimeInterval(40).timeIntervalSince1970, accuracy: 1)
    }

    func testASessionWithoutSubAgentsHasNone() async throws {
        try file("\(stem).jsonl", id: "01a1a744-cc29-741f-ae81-a68a5e76fc15", modified: Date())
        let source = PiSessionSource(rootURL: root)
        let refs = try await source.listSessionRefs()
        let indexableRead = await source.indexableFile(for: refs[0].id)
        let indexable = try XCTUnwrap(indexableRead)
        XCTAssertTrue(indexable.subagents.isEmpty)
        let summary = try await source.loadSummary(id: refs[0].id)
        XCTAssertEqual(summary.subagentCount, 0)
    }
}
