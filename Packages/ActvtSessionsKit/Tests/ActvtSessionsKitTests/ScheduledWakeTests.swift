//
//  ScheduledWakeTests.swift
//  ActvtSessionsKitTests
//

import XCTest
@testable import ActvtSessionsKit

/// A loop agent's `ScheduleWakeup` read back as `wakesAt`: from the summary,
/// through the CLI's wire format, and safely absent from older CLIs.
final class ScheduledWakeTests: XCTestCase {

    private var root: URL!
    private let tickEnd = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("actvt-wake-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: - Records, shaped like a dgx loop tick (2026-10-06)

    private func stamp(_ date: Date) -> String {
        Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date)
    }

    private func user(_ text: String, at date: Date) -> [String: Any] {
        ["type": "user", "uuid": UUID().uuidString, "timestamp": stamp(date), "cwd": "/home/u/loop",
         "message": ["role": "user", "content": text]]
    }

    private func wakeup(_ input: [String: Any], at date: Date) -> [String: Any] {
        ["type": "assistant", "uuid": UUID().uuidString, "timestamp": stamp(date),
         "message": ["role": "assistant", "content": [
             ["type": "tool_use", "id": "toolu_\(UUID().uuidString.prefix(8))", "name": "ScheduleWakeup", "input": input],
         ]]]
    }

    private func toolResult(at date: Date) -> [String: Any] {
        ["type": "user", "uuid": UUID().uuidString, "timestamp": stamp(date),
         "message": ["role": "user", "content": [
             ["type": "tool_result", "tool_use_id": "toolu_x", "content": "Next wakeup scheduled for 17:07:00 (in 1842s)."],
         ]]]
    }

    private func reply(_ text: String, at date: Date) -> [String: Any] {
        ["type": "assistant", "uuid": UUID().uuidString, "timestamp": stamp(date),
         "message": ["role": "assistant", "content": [["type": "text", "text": text]]]]
    }

    /// One complete loop tick that ends asleep for `delay` seconds.
    private func tick(delay: Int) -> [[String: Any]] {
        [
            user("/senior-software-engineer", at: tickEnd.addingTimeInterval(-300)),
            wakeup(["delaySeconds": delay, "prompt": "/senior-software-engineer", "reason": "waiting"], at: tickEnd),
            toolResult(at: tickEnd.addingTimeInterval(1)),
            reply("Nothing changed. Next check at about 17:07.", at: tickEnd.addingTimeInterval(2)),
        ]
    }

    private func summary(of records: [[String: Any]], padding: Int = 0) async throws -> AgentSessionSummary {
        let dir = root.appendingPathComponent("-home-u-loop", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var data = Data()
        for record in records {
            data += try JSONSerialization.data(withJSONObject: record) + Data("\n".utf8)
        }
        if padding > 0 {
            // Later writes that push the wake-up out of the tail.
            data += try JSONSerialization.data(withJSONObject: reply(String(repeating: "x", count: padding),
                                                                     at: tickEnd.addingTimeInterval(10)))
                + Data("\n".utf8)
        }
        try data.write(to: dir.appendingPathComponent("loop.jsonl"))
        let source = ClaudeCodeSessionSource(rootURL: root)
        _ = try await source.listSessionRefs()
        return try await source.loadSummary(id: "loop")
    }

    // MARK: - Summary

    func testATickThatEndsAsleepWakesAfterItsDelay() async throws {
        let summary = try await summary(of: tick(delay: 1800))
        XCTAssertEqual(summary.wakesAt, tickEnd.addingTimeInterval(1800))
    }

    func testASessionThatNeverScheduledHasNoWake() async throws {
        let summary = try await summary(of: [
            user("fix the tests", at: tickEnd), reply("Done.", at: tickEnd.addingTimeInterval(5)),
        ])
        XCTAssertNil(summary.wakesAt)
    }

    func testStoppingTheLoopClearsTheWake() async throws {
        let summary = try await summary(of: tick(delay: 1800) + [
            wakeup(["stop": true], at: tickEnd.addingTimeInterval(60)),
        ])
        XCTAssertNil(summary.wakesAt)
    }

    /// The user typing into a sleeping loop doesn't cancel its schedule.
    func testAUserTurnInBetweenKeepsTheScheduledWake() async throws {
        let summary = try await summary(of: tick(delay: 1800) + [
            user("what is the B-009 decision?", at: tickEnd.addingTimeInterval(120)),
            reply("It is the SDK install.", at: tickEnd.addingTimeInterval(130)),
        ])
        XCTAssertEqual(summary.wakesAt, tickEnd.addingTimeInterval(1800))
    }

    func testTheLatestScheduleWins() async throws {
        let summary = try await summary(of: tick(delay: 1800) + [
            wakeup(["delaySeconds": 600], at: tickEnd.addingTimeInterval(1900)),
        ])
        XCTAssertEqual(summary.wakesAt, tickEnd.addingTimeInterval(2500))
    }

    /// Beyond the tail it reads as never scheduled: judged by the last write,
    /// exactly as before this existed.
    func testAWakeBeyondTheTailIsNotSeen() async throws {
        let summary = try await summary(of: tick(delay: 1800), padding: 70 * 1024)
        XCTAssertNil(summary.wakesAt)
        XCTAssertEqual(summary.title, "/senior-software-engineer")
    }

    // MARK: - Wire

    func testTheCLICarriesTheWakeToTheApp() async throws {
        let summary = try await summary(of: tick(delay: 1800))
        let payload = RemoteSessionPayload(
            cliVersion: "0.6.1", hostname: "dgx", generatedAt: tickEnd,
            sessions: [RemoteAgentSession(summary)]
        )
        let data = try RemoteSessionPayload.makeEncoder().encode(payload)
        let decoded = try RemoteSessionPayload.makeDecoder().decode(RemoteSessionPayload.self, from: data)
        XCTAssertEqual(decoded.sessions.first?.wakesAt, tickEnd.addingTimeInterval(1800))
    }

    func testAnOlderCLIPayloadDecodesWithoutAWake() throws {
        let json = """
        {"cliVersion":"0.5.0","generatedAt":"2026-10-06T14:55:14.479Z","hostname":"dgx","schemaVersion":1,
         "sessions":[{"agentKind":"claudeCode","id":"a","lastUpdatedAt":"2026-10-06T14:42:39.000Z",
                      "messageCount":3,"projectPath":"/p","startedAt":"2026-10-06T08:00:00.000Z",
                      "subagentCount":0,"title":"t"}]}
        """
        let payload = try RemoteSessionPayload.makeDecoder().decode(RemoteSessionPayload.self, from: Data(json.utf8))
        XCTAssertNil(payload.sessions.first?.wakesAt)
    }
}
