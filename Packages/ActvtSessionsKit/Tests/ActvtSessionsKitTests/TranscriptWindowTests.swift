//
//  TranscriptWindowTests.swift
//  ActvtSessionsKitTests
//

import XCTest
@testable import ActvtSessionsKit

/// A long session is read a window at a time, newest first (S-004). Walking
/// back from the latest window to the start must give every turn of the
/// session exactly once, in order, for each provider. The sessions here are a
/// little over two windows long, so the walk crosses two cuts.
final class TranscriptWindowTests: XCTestCase {

    private var root: URL!
    /// Text that makes each record about 40 KB, so ~1,300 records span three windows.
    private let bulk = String(repeating: "lorem ipsum ", count: 3_400)
    private let records = 1_300

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("actvt-window-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: - Ranges

    func testWindowsTileTheFileBackFromTheEnd() {
        let budget = TranscriptWindow.budget
        let small = TranscriptWindow(.latest, fileSize: 10)
        XCTAssertEqual([small.start, small.end], [0, 10])
        XCTAssertFalse(small.hasEarlier)
        XCTAssertFalse(small.hasLater)

        let size = 2 * budget + 5
        let latest = TranscriptWindow(.latest, fileSize: size)
        XCTAssertEqual([latest.start, latest.end], [budget + 5, size])
        let middle = TranscriptWindow(.before(latest.start), fileSize: size)
        XCTAssertEqual([middle.start, middle.end], [5, budget + 5])
        XCTAssertTrue(middle.hasLater)
        let first = TranscriptWindow(.before(middle.start), fileSize: size)
        XCTAssertEqual([first.start, first.end], [0, 5])
        XCTAssertFalse(first.hasEarlier)
        let next = TranscriptWindow(.after(first.end), fileSize: size)
        XCTAssertEqual([next.start, next.end], [5, budget + 5])

        let opening = TranscriptWindow(.first, fileSize: size)
        XCTAssertEqual([opening.start, opening.end], [0, budget])
        XCTAssertTrue(opening.hasLater)
        XCTAssertEqual(TranscriptWindow(.first, fileSize: 10).end, 10)
    }

    func testJoiningKeepsATurnReadTwiceOnce() throws {
        let now = Date()
        func window(_ ids: [String], _ start: UInt64, _ end: UInt64) -> AgentTranscript {
            AgentTranscript(sessionId: "s", agentKind: .claudeCode, projectPath: "/p",
                            turns: ids.map { .user(recordUUID: $0, text: $0, timestamp: now) },
                            toolResultsByID: [:], window: TranscriptWindow(start: start, end: end, fileSize: 30))
        }
        let joined = try XCTUnwrap(AgentTranscript.joining([window(["a", "b"], 0, 10), window(["b", "c"], 10, 30)]))
        XCTAssertEqual(joined.turns.map(\.recordUUID), ["a", "b", "c"])
        XCTAssertEqual(joined.window, TranscriptWindow(start: 0, end: 30, fileSize: 30))
    }

    // MARK: - Providers

    /// Reads `id` from the latest window back to the start, then joins.
    private func walk(_ source: any AgentSessionSource, id: String) async throws -> (AgentTranscript, windows: Int) {
        var windows = [try await source.loadTranscript(id: id, window: .latest)]
        while let start = windows[0].window, start.hasEarlier {
            windows.insert(try await source.loadTranscript(id: id, window: .before(start.start)), at: 0)
        }
        return (try XCTUnwrap(AgentTranscript.joining(windows)), windows.count)
    }

    private func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    func testClaudeWindowsJoinIntoTheWholeSession() async throws {
        var lines: [String] = []
        var ids: [String] = []
        for i in 0..<records {
            let id = String(format: "r%05d", i)
            ids.append(id)
            let at = "2026-10-19T08:\(String(format: "%02d", i / 60 % 60)):\(String(format: "%02d", i % 60)).000Z"
            if i.isMultiple(of: 2) {
                lines.append(json(["type": "user", "uuid": id, "timestamp": at, "cwd": "/home/u/long",
                                   "message": ["role": "user", "content": "\(i) \(bulk)"]]))
            } else {
                lines.append(json(["type": "assistant", "uuid": id, "timestamp": at,
                                   "message": ["role": "assistant", "content": [["type": "text", "text": "\(i) \(bulk)"]]]]))
            }
        }
        let dir = root.appendingPathComponent("-home-u-long", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: dir.appendingPathComponent("long.jsonl"))
        let source = ClaudeCodeSessionSource(rootURL: root)
        _ = try await source.listSessionRefs()

        let latest = try await source.loadTranscript(id: "long")
        XCTAssertEqual(latest.turns.last?.recordUUID, ids.last, "a long session opens on its newest turn")
        XCTAssertTrue(try XCTUnwrap(latest.window).hasEarlier)

        let (joined, windows) = try await walk(source, id: "long")
        XCTAssertEqual(windows, 3)
        XCTAssertEqual(joined.turns.map(\.recordUUID), ids)

        // ⌘↑ reads the first window on its own; reading on from there joins
        // into the whole session too (B-044).
        let first = try await source.loadTranscript(id: "long", window: .first)
        XCTAssertEqual(first.turns.first?.recordUUID, ids.first, "the first window starts at the session's first turn")
        XCTAssertFalse(try XCTUnwrap(first.window).hasEarlier)
        var forward = [first]
        while let window = forward.last?.window, window.hasLater {
            forward.append(try await source.loadTranscript(id: "long", window: .after(window.end)))
        }
        XCTAssertEqual(try XCTUnwrap(AgentTranscript.joining(forward)).turns.map(\.recordUUID), ids)
    }

    func testCodexWindowsJoinIntoTheWholeSession() async throws {
        let sessionId = "0199f0a1-2b3c-7d4e-8f90-a1b2c3d4e5f6"
        var lines = [json(["type": "session_meta", "timestamp": "2026-10-19T08:00:00.000Z",
                           "payload": ["id": sessionId, "cwd": "/Users/x/proj"]])]
        var ids: [String] = []
        var position = UInt64(lines[0].utf8.count) + 1
        for i in 0..<records {
            let user = i.isMultiple(of: 2)
            ids.append("\(user ? "u" : "a")@\(position)")
            let line = json(["type": "event_msg", "timestamp": "2026-10-19T08:00:01.000Z",
                             "payload": ["type": user ? "user_message" : "agent_message", "message": "\(i) \(bulk)"]])
            lines.append(line)
            position += UInt64(line.utf8.count) + 1
        }
        let day = root.appendingPathComponent("2026/10/19", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: day.appendingPathComponent("rollout-2026-10-19T08-00-00-\(sessionId).jsonl"))
        let source = CodexSessionSource(rootURL: root)
        _ = try await source.listSessionRefs()

        let (joined, windows) = try await walk(source, id: sessionId)
        XCTAssertEqual(windows, 3)
        XCTAssertEqual(joined.turns.map(\.recordUUID), ids)
    }

    /// pi's branch is walked back from the file's last entry, which a window
    /// before the latest doesn't hold: an abandoned branch near the start
    /// still stays out.
    func testPiWindowsJoinIntoTheActiveBranch() async throws {
        let sessionId = "01a09040-0d56-77d0-812d-b9b758f2b046"
        var lines = [json(["type": "session", "version": 3, "id": sessionId,
                           "timestamp": "2026-09-11T11:35:11.959Z", "cwd": "/home/u/pi"])]
        func message(_ id: String, parent: String?, role: String, _ text: String) -> String {
            let content: [[String: Any]] = [["type": "text", "text": text]]
            var message: [String: Any] = ["role": role, "content": content, "timestamp": 1789126602565]
            if role == "assistant" { message["stopReason"] = "stop" }
            return json(["type": "message", "id": id, "parentId": parent as Any,
                         "timestamp": "2026-09-11T11:36:42.568Z", "message": message])
        }
        var ids: [String] = []
        var parent: String?
        for i in 0..<records {
            let id = String(format: "e%05d", i)
            if i == 3 {
                // A reply the user abandoned: its sibling carries on the branch.
                lines.append(message("abandoned", parent: parent, role: "assistant", "dropped \(bulk)"))
            }
            lines.append(message(id, parent: parent, role: i.isMultiple(of: 2) ? "user" : "assistant", "\(i) \(bulk)"))
            ids.append(id)
            parent = id
        }
        let dir = root.appendingPathComponent("--home-u-pi--", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: dir.appendingPathComponent("2026-09-11T11-35-11-959Z_\(sessionId).jsonl"))
        let source = PiSessionSource(rootURL: root)
        _ = try await source.listSessionRefs()

        let (joined, windows) = try await walk(source, id: sessionId)
        XCTAssertEqual(windows, 3)
        XCTAssertEqual(joined.turns.map(\.recordUUID), ids)
        XCTAssertEqual(joined.projectPath, "/home/u/pi")
    }

    // MARK: - Remote

    func testTheWindowTravelsToTheApp() throws {
        let window = TranscriptWindow(start: 5, end: 30, fileSize: 30)
        let transcript = AgentTranscript(sessionId: "s", agentKind: .claudeCode, projectPath: "/p",
                                         turns: [], toolResultsByID: [:], window: window)
        let wire = try JSONEncoder().encode(RemoteTranscript(transcript))
        let decoded = try JSONDecoder().decode(RemoteTranscript.self, from: wire)
        XCTAssertEqual(decoded.agentTranscript()?.window, window)
    }
}
