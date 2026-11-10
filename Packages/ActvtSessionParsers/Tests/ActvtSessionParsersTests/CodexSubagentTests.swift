//
//  CodexSubagentTests.swift
//  ActvtSessionParsersTests
//

import XCTest
@testable import ActvtSessionParsers

/// A Codex sub-agent is a rollout of its own whose first record names the
/// session that spawned it (`parent_thread_id`). It is listed as part of that
/// session, as Claude Code's `subagents/` are, never as a session of its own
/// (T-041).
final class CodexSubagentTests: XCTestCase {

    private var root: URL!
    private let parent = "01a1a64c-7873-7b51-81c1-c2ed1c33eda8"
    private let child = "01a1a64c-98c5-70e0-9783-2af8aa14895a"
    private let grandchild = "01a1a64c-aaaa-70e0-9783-2af8aa14895a"
    private let orphan = "01a1a64d-38d8-7dc0-8b40-99f5696d080d"
    private let missingParent = "01a1a64d-22a7-7a13-938a-de904a730c96"

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("codex-subagents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes a rollout the way Codex 0.163 does: `session_meta` first, with the
    /// parent named before a long `instructions` field. `modified` sets its mtime.
    @discardableResult
    private func rollout(_ id: String, parent: String? = nil, day: String = "2026/11/04",
                         modified: Date) throws -> URL {
        var meta = "{\"timestamp\":\"2026-11-04T11:23:11.000Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\""
        if let parent {
            meta += ",\"parent_thread_id\":\"\(parent)\",\"source\":{\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":\"\(parent)\",\"depth\":1}}}"
        } else {
            meta += ",\"source\":\"exec\""
        }
        meta += ",\"cwd\":\"/tmp/proj\",\"instructions\":\"\(String(repeating: "x", count: 18_000))\"}}"
        let user = "{\"timestamp\":\"2026-11-04T11:23:12.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"hello from \(id.prefix(8))\"}}"
        let dir = root.appendingPathComponent(day, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("rollout-2026-11-04T11-23-11-\(id).jsonl")
        try Data((meta + "\n" + user + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    func testTheHeaderNamesTheParent() throws {
        let t = Date()
        let c = try rollout(child, parent: parent, modified: t)
        let p = try rollout(parent, modified: t)
        XCTAssertEqual(CodexSessionsLocator.parentThreadId(ofRolloutAt: c).id, parent)
        XCTAssertTrue(CodexSessionsLocator.parentThreadId(ofRolloutAt: c).final)
        XCTAssertNil(CodexSessionsLocator.parentThreadId(ofRolloutAt: p).id)
        XCTAssertTrue(CodexSessionsLocator.parentThreadId(ofRolloutAt: p).final)
    }

    /// A file Codex has only just created holds no full first record yet: "no
    /// parent" is not an answer to keep.
    func testAHalfWrittenHeaderIsNotFinal() throws {
        let url = root.appendingPathComponent("rollout-2026-11-04T11-23-11-\(child).jsonl")
        try Data("{\"timestamp\":\"2026-11-04T11:23:11.000Z\",\"type\":\"session_".utf8).write(to: url)
        let read = CodexSessionsLocator.parentThreadId(ofRolloutAt: url)
        XCTAssertNil(read.id)
        XCTAssertFalse(read.final)
    }

    func testSubAgentsAreListedUnderTheirRoot() async throws {
        let t0 = Date(timeIntervalSince1970: 1_793_000_000)
        try rollout(parent, modified: t0)
        let childURL = try rollout(child, parent: parent, modified: t0.addingTimeInterval(30))
        // Nested: spawned by the child, and a day later (sub-agents can cross midnight).
        let grandchildURL = try rollout(grandchild, parent: child, day: "2026/11/05", modified: t0.addingTimeInterval(60))
        // Its parent isn't on this machine: it stays a session, so its work isn't lost.
        try rollout(orphan, parent: missingParent, modified: t0.addingTimeInterval(10))

        let source = CodexSessionSource(rootURL: root)
        let refs = try await source.listSessionRefs()

        XCTAssertEqual(Set(refs.map(\.id)), [parent, orphan])
        // The parent was last updated when its newest sub-agent was.
        XCTAssertEqual(refs.first { $0.id == parent }?.lastUpdatedAt.timeIntervalSince1970 ?? 0,
                       t0.addingTimeInterval(60).timeIntervalSince1970, accuracy: 1)

        let summary = try await source.loadSummary(id: parent)
        XCTAssertEqual(summary.subagentCount, 2)
        XCTAssertEqual(summary.title, "hello from 01a1a64c")
        let orphanSummary = try await source.loadSummary(id: orphan)
        XCTAssertEqual(orphanSummary.subagentCount, 0)

        let fileRead = await source.indexableFile(for: parent)
        let file = try XCTUnwrap(fileRead)
        XCTAssertEqual(file.subagents.mapValues(\.standardizedFileURL),
                       [child: childURL.standardizedFileURL, grandchild: grandchildURL.standardizedFileURL])
        XCTAssertEqual(file.mtime.timeIntervalSince1970, t0.addingTimeInterval(60).timeIntervalSince1970, accuracy: 1)
        let orphanFileRead = await source.indexableFile(for: orphan)
        let orphanFile = try XCTUnwrap(orphanFileRead)
        XCTAssertTrue(orphanFile.subagents.isEmpty)
    }

    /// A parent that turns up later (copied over from another machine) takes its
    /// sub-agent back from standing alone.
    func testAParentThatArrivesClaimsItsSubAgent() async throws {
        let t0 = Date(timeIntervalSince1970: 1_793_000_000)
        try rollout(orphan, parent: missingParent, modified: t0)
        let source = CodexSessionSource(rootURL: root)
        let before = try await source.listSessionRefs()
        XCTAssertEqual(before.map(\.id), [orphan])

        try rollout(missingParent, modified: t0.addingTimeInterval(-60))
        try await Task.sleep(nanoseconds: 5_100_000_000)   // past the incremental window: a full walk
        let after = try await source.listSessionRefs()
        XCTAssertEqual(after.map(\.id), [missingParent])
    }

    func testGroupingSurvivesACycle() {
        func s(_ id: String) -> CodexSessionsLocator.DiscoveredSession {
            .init(sessionId: id, fileURL: URL(fileURLWithPath: "/tmp/\(id)"), lastUpdatedAt: Date())
        }
        let parents = ["a": "b", "b": "a"]
        let groups = CodexSessionsLocator.group(["a": s("a"), "b": s("b")]) { parents[$0.sessionId] }
        XCTAssertEqual(groups.mapValues(\.count), ["a": 0, "b": 0], "each stands alone rather than vanishing")
    }
}
