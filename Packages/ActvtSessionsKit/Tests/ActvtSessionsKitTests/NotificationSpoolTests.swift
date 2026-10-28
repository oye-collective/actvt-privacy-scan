//
//  NotificationSpoolTests.swift
//  ActvtSessionsKitTests
//

import XCTest
@testable import ActvtSessionsKit

/// The spool a remote agent writes and Actvt's SSH poll drains.
///
/// The contract that matters is exactly-once-without-loss: an entry survives
/// until the app says it took delivery, and never reappears afterwards. Both
/// halves have a failure mode worth pinning: losing a "your agent needs you"
/// defeats the feature, and replaying one is the spam it was built to stop.
final class NotificationSpoolTests: XCTestCase {

    private var directory: URL!
    private var spool: NotificationSpool!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("spool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        spool = NotificationSpool(url: directory.appendingPathComponent("notifications.jsonl"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func append(_ message: String, kind: String = "needsInput", at: Date? = nil) throws
        -> RemoteAgentNotification {
        try spool.append(kind: kind, message: message, project: "actvt", now: at ?? t0)
    }

    // MARK: - Ids

    func testIdsStartAtOneAndIncrease() throws {
        XCTAssertEqual(try append("first").id, 1)
        XCTAssertEqual(try append("second").id, 2)
        XCTAssertEqual(try append("third").id, 3)
    }

    func testDrainReturnsEverythingWhenNothingIsAcknowledged() throws {
        try append("first")
        try append("second")
        let drained = try spool.drain(since: nil, now: t0)
        XCTAssertEqual(drained.map(\.id), [1, 2])
        XCTAssertEqual(drained.map(\.message), ["first", "second"])
    }

    // MARK: - Acknowledgement

    /// The core guarantee: an unacknowledged entry is still there next time.
    /// This is what makes a poll that dies mid-transfer harmless.
    func testAnUnacknowledgedEntrySurvivesRepeatedDrains() throws {
        try append("still waiting")
        XCTAssertEqual(try spool.drain(since: nil, now: t0).map(\.id), [1])
        XCTAssertEqual(try spool.drain(since: nil, now: t0).map(\.id), [1])
        XCTAssertEqual(try spool.drain(since: nil, now: t0).map(\.id), [1])
    }

    func testAcknowledgingDropsOnlyWhatWasTaken() throws {
        try append("first")
        try append("second")
        try append("third")
        let remaining = try spool.drain(since: 1, now: t0)
        XCTAssertEqual(remaining.map(\.id), [2, 3])
        XCTAssertEqual(try spool.drain(since: 1, now: t0).map(\.id), [2, 3])
    }

    func testAcknowledgingEverythingLeavesNothingToHandOver() throws {
        try append("first")
        try append("second")
        XCTAssertTrue(try spool.drain(since: 2, now: t0).isEmpty)
    }

    // MARK: - Last notified

    /// An acknowledged entry still says its session announced a stop: that is
    /// what keeps the app's own "went quiet" guess back after a relaunch.
    func testLastNotifiedCountsAcknowledgedEntriesUntilTheyAgeOut() throws {
        try spool.append(kind: "finished", message: "done", project: nil,
                         sessionId: "s1", agentKind: "claudeCode", now: t0)
        _ = try spool.drain(since: 1, now: t0)
        XCTAssertEqual(try spool.lastNotified(now: t0.addingTimeInterval(60)), ["s1": t0])
        XCTAssertEqual(try spool.lastNotified(now: t0.addingTimeInterval(3_600 + 60)), [:])
    }

    func testLastNotifiedKeepsEachSessionsLatestAndSkipsAnonymousEntries() throws {
        try spool.append(kind: "needsInput", message: "a", project: nil, sessionId: "s1", now: t0)
        try spool.append(kind: "finished", message: "b", project: nil, sessionId: "s1",
                         now: t0.addingTimeInterval(30))
        try spool.append(kind: "finished", message: "c", project: nil, sessionId: "s2", now: t0)
        try append("anonymous")
        XCTAssertEqual(try spool.lastNotified(now: t0.addingTimeInterval(60)),
                       ["s1": t0.addingTimeInterval(30), "s2": t0])
    }

    /// Ids keep climbing after a drain, so a watermark the app already holds
    /// can never accidentally suppress a newer message.
    func testIdsDoNotRestartAfterTheSpoolEmpties() throws {
        try append("first")
        _ = try spool.drain(since: 1, now: t0)
        XCTAssertEqual(try append("second").id, 2)
    }

    /// The spool can start over: its file and sidecar removed, or a new
    /// machine under the same name. The app still holds the old spool's
    /// watermark, which is above every new id; taken at its word, it would
    /// hide each new message from that host for good (B-026).
    func testAWatermarkFromAnEarlierSpoolAcknowledgesNothing() throws {
        try append("first")
        try append("second")
        XCTAssertEqual(try spool.sequence(now: t0), 2)
        XCTAssertEqual(try spool.drain(since: 7, now: t0).map(\.id), [1, 2])
        XCTAssertEqual(try spool.drain(since: 2, now: t0).map(\.id), [], "an in-range watermark still holds")
    }

    func testTheSequenceOutlivesTheEntries() throws {
        XCTAssertEqual(try spool.sequence(now: t0), 0)
        try append("first", at: t0)
        XCTAssertEqual(try spool.sequence(now: t0.addingTimeInterval(3_600 + 60)), 1, "aged out, still issued")
    }

    // MARK: - Retention

    func testEntriesOlderThanRetentionAreDropped() throws {
        try append("ancient", at: t0)
        try append("recent", at: t0.addingTimeInterval(3_000))
        let drained = try spool.drain(since: nil, now: t0.addingTimeInterval(3_600 + 60))
        XCTAssertEqual(drained.map(\.message), ["recent"])
    }

    /// An unreachable Mac must not let the file grow without bound.
    func testRetentionAppliesEvenWithNothingAcknowledged() throws {
        for i in 0..<20 {
            try append("msg \(i)", at: t0.addingTimeInterval(Double(i)))
        }
        let drained = try spool.drain(since: nil, now: t0.addingTimeInterval(10_000))
        XCTAssertTrue(drained.isEmpty)
    }

    // MARK: - Robustness

    func testMissingSpoolDrainsToNothing() throws {
        let absent = NotificationSpool(url: directory.appendingPathComponent("nope.jsonl"))
        XCTAssertTrue(try absent.drain(since: nil, now: t0).isEmpty)
    }

    /// The file is written by whatever CLI version was installed when the
    /// agent stopped, so one bad line must not discard its siblings.
    func testAGarbageLineDoesNotDiscardValidOnes() throws {
        try append("good one")
        let url = directory.appendingPathComponent("notifications.jsonl")
        var raw = try String(contentsOf: url, encoding: .utf8)
        raw += "{ not json at all\n"
        try raw.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(try spool.drain(since: nil, now: t0).map(\.message), ["good one"])
    }

    func testConcurrentAppendsAllSurviveWithDistinctIds() throws {
        // Both bound locally: capturing `self.t0` makes the closure capture the
        // test case itself, which the Linux toolchain rejects as non-Sendable.
        let spool = self.spool!
        let now = t0
        DispatchQueue.concurrentPerform(iterations: 12) { i in
            _ = try? spool.append(kind: "finished", message: "m\(i)", project: nil, now: now)
        }
        let drained = try spool.drain(since: nil, now: t0)
        XCTAssertEqual(drained.count, 12)
        XCTAssertEqual(Set(drained.map(\.id)).count, 12, "ids collided under concurrent appends")
    }

    // MARK: - CLI surface

    func testNotifyRequiresAMessage() {
        var errors: [String] = []
        let status = CLIRunner.runNotify(
            ["--kind", "finished"], stdout: { _ in }, stderr: { errors.append($0) }, spool: spool)
        XCTAssertEqual(status.code, 64)
        XCTAssertTrue(errors.contains { $0.contains("--message is required") }, "\(errors)")
    }

    func testNotifyRejectsAnUnknownKind() {
        var errors: [String] = []
        let status = CLIRunner.runNotify(
            ["--message", "hi", "--kind", "explode"],
            stdout: { _ in }, stderr: { errors.append($0) }, spool: spool)
        XCTAssertEqual(status.code, 64)
        XCTAssertTrue(errors.contains { $0.contains("needsInput") }, "\(errors)")
    }

    /// The common case is an agent that just stopped and wants the user, so
    /// omitting --kind should do the useful thing rather than fail.
    func testNotifyDefaultsToNeedsInput() throws {
        let status = CLIRunner.runNotify(
            ["--message", "Which database should I target?"],
            stdout: { _ in }, stderr: { _ in }, spool: spool, now: t0)
        XCTAssertEqual(status.code, 0)
        let drained = try spool.drain(since: nil, now: t0)
        XCTAssertEqual(drained.map(\.kind), ["needsInput"])
    }

    func testNotifyRecordsTheCallingSession() throws {
        let status = CLIRunner.runNotify(
            ["--message", "Ready for review", "--kind", "finished"],
            stdout: { _ in }, stderr: { _ in }, spool: spool,
            environment: ["CODEX_THREAD_ID": "019d91ec-4e6f-7211-8f84-d862a910117e"], now: t0)
        XCTAssertEqual(status.code, 0)
        let entry = try XCTUnwrap(try spool.drain(since: nil, now: t0).first)
        XCTAssertEqual(entry.sessionId, "019d91ec-4e6f-7211-8f84-d862a910117e")
        XCTAssertEqual(entry.agentKind, "codexCLI")
    }

    func testEachAgentsVariableNamesItsKind() {
        XCTAssertEqual(CLIRunner.callingSession(environment: ["CLAUDE_CODE_SESSION_ID": "a"])?.agentKind, .claudeCode)
        XCTAssertEqual(CLIRunner.callingSession(environment: ["CODEX_THREAD_ID": "b"])?.agentKind, .codexCLI)
        XCTAssertEqual(CLIRunner.callingSession(environment: ["PI_SESSION_ID": "c"])?.agentKind, .pi)
        XCTAssertEqual(CLIRunner.callingSession(environment: ["PI_SESSION_ID": "c"])?.id, "c")
    }

    /// An agent run from another agent's shell sees both ids. Recording
    /// neither beats a banner that opens the wrong session.
    func testNoSessionIsRecordedWhenTheCallerIsAmbiguousOrAbsent() {
        XCTAssertNil(CLIRunner.callingSession(environment: [:]))
        XCTAssertNil(CLIRunner.callingSession(environment: ["CLAUDE_CODE_SESSION_ID": " "]))
        XCTAssertNil(CLIRunner.callingSession(
            environment: ["CLAUDE_CODE_SESSION_ID": "a", "CODEX_THREAD_ID": "b"]))
    }

    func testNotifyTruncatesARunawayMessage() throws {
        let status = CLIRunner.runNotify(
            ["--message", String(repeating: "x", count: 5_000)],
            stdout: { _ in }, stderr: { _ in }, spool: spool, now: t0)
        XCTAssertEqual(status.code, 0)
        let drained = try spool.drain(since: nil, now: t0)
        XCTAssertEqual(drained.first?.message.count, CLIRunner.notifyMessageLimit)
    }

    /// A spool that can't be read must never take the session list down with
    /// it: remote sessions worked before notifications existed.
    func testAnUnreadableSpoolYieldsNoNotificationsRatherThanThrowing() {
        let unreadable = NotificationSpool(
            url: URL(fileURLWithPath: "/dev/null/not-a-directory/spool.jsonl"))
        XCTAssertTrue(CLIRunner.drainSpool(spool: unreadable, environment: [:]).isEmpty)
    }

    func testDrainSpoolReadsTheWatermarkFromTheEnvironment() throws {
        try append("first")
        try append("second")
        let drained = CLIRunner.drainSpool(spool: spool, environment: ["ACTVT_NOTIFY_SINCE": "1"])
        XCTAssertEqual(drained.map(\.id), [2])
    }
}
