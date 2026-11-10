//
//  CodexTurnIdTests.swift
//  ActvtSessionParsersTests
//

import XCTest
@testable import ActvtSessionParsers

/// Codex records carry no ids, so a turn is named by the byte offset of its
/// first record: the same id however much of the file was read before it,
/// which windowed reads of long sessions rely on (S-004).
final class CodexTurnIdTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("actvt-codex-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func record(_ type: String, _ payload: [String: Any], at time: String) -> String {
        let object: [String: Any] = ["type": type, "timestamp": time, "payload": payload]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    func testTurnsAreNamedByTheOffsetOfTheirFirstRecord() async throws {
        let sessionId = "0199f0a1-2b3c-7d4e-8f90-a1b2c3d4e5f6"
        let lines = [
            record("session_meta", ["id": sessionId, "cwd": "/Users/x/proj"], at: "2026-10-19T08:00:00.000Z"),
            record("event_msg", ["type": "user_message", "message": "first"], at: "2026-10-19T08:00:01.000Z"),
            record("event_msg", ["type": "agent_message", "message": "one"], at: "2026-10-19T08:00:02.000Z"),
            record("event_msg", ["type": "agent_message", "message": "two"], at: "2026-10-19T08:00:03.000Z"),
            record("event_msg", ["type": "user_message", "message": "second"], at: "2026-10-19T08:00:04.000Z"),
            record("event_msg", ["type": "agent_message", "message": "three"], at: "2026-10-19T08:00:05.000Z"),
        ]
        var offsets: [UInt64] = []
        var position: UInt64 = 0
        for line in lines {
            offsets.append(position)
            position += UInt64(line.utf8.count) + 1
        }
        let day = root.appendingPathComponent("2026/10/19", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: day.appendingPathComponent("rollout-2026-10-19T08-00-00-\(sessionId).jsonl"))

        let transcript = try await CodexSessionSource(rootURL: root).loadTranscript(id: sessionId)

        XCTAssertEqual(transcript.turns.map(\.recordUUID), [
            "u@\(offsets[1])",
            "a@\(offsets[2])",   // one turn for "one" and "two", named by its first record
            "u@\(offsets[4])",
            "a@\(offsets[5])",
        ])
        XCTAssertEqual(transcript.projectPath, "/Users/x/proj")
    }
}
