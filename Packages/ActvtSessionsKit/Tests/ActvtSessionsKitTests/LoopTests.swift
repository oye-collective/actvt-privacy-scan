//
//  LoopTests.swift
//  ActvtSessionsKitTests
//

import XCTest
@testable import ActvtSessionsKit

/// `actvt-cli loops`: each loop agent read from its own transcript as
/// working, asleep or overdue, wherever in the file its last call sits, and
/// `ended` when Claude Code's process registry has no live process for it.
final class LoopTests: XCTestCase {

    /// A config directory like `~/.claude`: `projects/` holds the transcripts,
    /// `sessions/` (only when a test writes one) the process registry.
    private var config: URL!
    private var root: URL!
    private let tickEnd = Date(timeIntervalSince1970: 1_800_000_000)
    private let grace: TimeInterval = 600

    override func setUp() {
        super.setUp()
        config = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("actvt-loops-\(UUID().uuidString)", isDirectory: true)
        root = config.appendingPathComponent("projects", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: config)
        super.tearDown()
    }

    // MARK: - Records, shaped like a dgx loop tick (2026-10-12)

    private func stamp(_ date: Date) -> String {
        Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date)
    }

    private func user(_ text: String, at date: Date, cwd: String = "/home/u/loop") -> [String: Any] {
        ["type": "user", "uuid": UUID().uuidString, "timestamp": stamp(date), "cwd": cwd,
         "message": ["role": "user", "content": text]]
    }

    private func wakeup(_ input: [String: Any], at date: Date) -> [String: Any] {
        ["type": "assistant", "uuid": UUID().uuidString, "timestamp": stamp(date),
         "message": ["role": "assistant", "stop_reason": "tool_use", "content": [
             ["type": "tool_use", "id": "toolu_w", "name": "ScheduleWakeup", "input": input],
         ]]]
    }

    private func toolUse(_ name: String, input: [String: Any], at date: Date) -> [String: Any] {
        ["type": "assistant", "uuid": UUID().uuidString, "timestamp": stamp(date),
         "message": ["role": "assistant", "stop_reason": "tool_use", "content": [
             ["type": "tool_use", "id": "toolu_b", "name": name, "input": input],
         ]]]
    }

    private func toolResult(_ text: String = "ok", at date: Date) -> [String: Any] {
        ["type": "user", "uuid": UUID().uuidString, "timestamp": stamp(date),
         "message": ["role": "user", "content": [
             ["type": "tool_result", "tool_use_id": "toolu_x", "content": text],
         ]]]
    }

    private func reply(_ text: String, at date: Date) -> [String: Any] {
        ["type": "assistant", "uuid": UUID().uuidString, "timestamp": stamp(date),
         "message": ["role": "assistant", "stop_reason": "end_turn", "content": [["type": "text", "text": text]]]]
    }

    private func turnDuration(at date: Date) -> [String: Any] {
        ["type": "system", "subtype": "turn_duration", "uuid": UUID().uuidString, "timestamp": stamp(date)]
    }

    private func fire(at date: Date) -> [String: Any] {
        ["type": "system", "subtype": "scheduled_task_fire", "uuid": UUID().uuidString, "timestamp": stamp(date)]
    }

    /// One complete tick that goes to sleep for `delay` seconds.
    private func tick(delay: Int, at end: Date? = nil, cwd: String = "/home/u/loop") -> [[String: Any]] {
        let end = end ?? tickEnd
        return [
            user("/senior-software-engineer", at: end.addingTimeInterval(-300), cwd: cwd),
            wakeup(["delaySeconds": delay, "prompt": "/senior-software-engineer",
                    "reason": "R-006 waiting for tag", "noop": true], at: end),
            toolResult("Next wakeup scheduled for 17:07:00 (in 1842s).", at: end.addingTimeInterval(1)),
            reply("Nothing changed. Next check at about 17:07.", at: end.addingTimeInterval(2)),
            turnDuration(at: end.addingTimeInterval(3)),
        ]
    }

    private func lines(_ records: [[String: Any]]) throws -> Data {
        var data = Data()
        for record in records {
            data += try JSONSerialization.data(withJSONObject: record) + Data("\n".utf8)
        }
        return data
    }

    /// Writes a transcript dated like a real one: its mtime is its newest
    /// record, which is when its agent last wrote to it.
    @discardableResult
    private func write(_ data: Data, project: String = "-home-u-loop", session: String = "loop",
                       modified: Date? = nil) throws -> URL {
        let dir = root.appendingPathComponent(project, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(session).jsonl")
        try data.write(to: url)
        let newest = data.split(separator: 0x0A).compactMap { line -> Date? in
            guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let stamp = record["timestamp"] as? String else { return nil }
            return try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(stamp)
        }.max()
        if let date = modified ?? newest {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        return url
    }

    private func loops(at now: Date, includeEnded: Bool = false) async -> [RemoteAgentLoop] {
        await CLIRunner.collectLoops(
            source: ClaudeCodeSessionSource(rootURL: root), now: now, grace: grace, includeEnded: includeEnded
        ).loops
    }

    /// Writes Claude Code's registry entry for a process, shaped like dgx's
    /// (2026-10-15): `<pid>.json` with the session it runs and its start.
    private func register(pid: Int32, session: String, procStart: String) throws {
        let dir = config.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let entry: [String: Any] = ["pid": pid, "sessionId": session, "cwd": "/home/u/loop", "procStart": procStart,
                                    "kind": "interactive", "status": "idle", "version": "2.1.300"]
        try JSONSerialization.data(withJSONObject: entry)
            .write(to: dir.appendingPathComponent("\(pid).json"))
    }

    /// This test process's start, recorded the way Claude Code records its own.
    private func ownProcStart() throws -> String {
        #if os(Linux)
        let stat = try String(contentsOfFile: "/proc/self/stat", encoding: .utf8)
        return try XCTUnwrap(ClaudeProcessRegistry.linuxStartTime(stat: stat))
        #else
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "lstart=", "-p", String(getpid())]
        ps.environment = ["LC_ALL": "C", "TZ": "UTC"]
        let pipe = Pipe()
        ps.standardOutput = pipe
        try ps.run()
        ps.waitUntilExit()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
        #endif
    }

    // MARK: - State

    func testATickThatWentToSleepIsAsleepUntilItsWake() async throws {
        try write(lines(tick(delay: 1800)))
        let loops = await loops(at: tickEnd.addingTimeInterval(1000))
        XCTAssertEqual(loops.count, 1)
        let loop = try XCTUnwrap(loops.first)
        XCTAssertEqual(loop.state, "asleep")
        XCTAssertEqual(loop.projectPath, "/home/u/loop")
        XCTAssertEqual(loop.sessionId, "loop")
        XCTAssertEqual(loop.agentKind, "claudeCode")
        XCTAssertEqual(loop.wakesAt, tickEnd.addingTimeInterval(1800))
        XCTAssertEqual(loop.lastTick, .init(scheduledAt: tickEnd, reason: "R-006 waiting for tag", noop: true))
        // The newest record of any kind, here the turn's duration line.
        XCTAssertEqual(loop.lastActivityAt, tickEnd.addingTimeInterval(3))
    }

    func testItIsStillAsleepWithinTheGrace() async throws {
        try write(lines(tick(delay: 1800)))
        let loops = await loops(at: tickEnd.addingTimeInterval(1800 + grace - 1))
        XCTAssertEqual(loops.first?.state, "asleep")
    }

    /// The 2026-10-05 case: the session stopped writing records and never woke.
    func testASessionPastItsWakeThatNeverWokeIsOverdue() async throws {
        try write(lines(tick(delay: 1800)))
        let loops = await loops(at: tickEnd.addingTimeInterval(1800 + grace))
        XCTAssertEqual(loops.first?.state, "overdue")
    }

    func testAWokenLoopIsWorkingWhileItsTurnIsOpen() async throws {
        let woke = tickEnd.addingTimeInterval(1800)
        try write(lines(tick(delay: 1800) + [
            fire(at: woke),
            user("/senior-software-engineer", at: woke),
            toolUse("Bash", input: ["command": "date"], at: woke.addingTimeInterval(5)),
        ]))
        // Long past its wake: it is awake and working, not overdue.
        let loops = await loops(at: woke.addingTimeInterval(3 * 3600))
        XCTAssertEqual(loops.first?.state, "working")
        XCTAssertEqual(loops.first?.lastActivityAt, woke.addingTimeInterval(5))
    }

    /// The user typing into a sleeping loop doesn't cancel its schedule, and
    /// once answered the loop is asleep again, not working.
    func testAUserTurnInBetweenLeavesItAsleep() async throws {
        try write(lines(tick(delay: 1800) + [
            user("what is the B-009 decision?", at: tickEnd.addingTimeInterval(120)),
            reply("It is the SDK install.", at: tickEnd.addingTimeInterval(130)),
        ]))
        let loops = await loops(at: tickEnd.addingTimeInterval(200))
        XCTAssertEqual(loops.first?.state, "asleep")
        XCTAssertEqual(loops.first?.wakesAt, tickEnd.addingTimeInterval(1800))
    }

    func testStoppingTheLoopRemovesIt() async throws {
        try write(lines(tick(delay: 1800) + [
            wakeup(["stop": true], at: tickEnd.addingTimeInterval(60)),
            reply("Loop stopped.", at: tickEnd.addingTimeInterval(61)),
        ]))
        let loops = await loops(at: tickEnd.addingTimeInterval(100))
        XCTAssertTrue(loops.isEmpty)
    }

    func testASessionThatNeverScheduledIsNoLoop() async throws {
        try write(lines([user("fix the tests", at: tickEnd), reply("Done.", at: tickEnd.addingTimeInterval(5))]))
        let loops = await loops(at: tickEnd)
        XCTAssertTrue(loops.isEmpty)
    }

    /// A command or a tool result that mentions the call quotes it inside a
    /// string, so its quotes are escaped and it never counts as one.
    func testAQuotedCallIsNotACall() async throws {
        try write(lines([
            user("count the wakes", at: tickEnd),
            toolUse("Bash", input: ["command": #"grep -c '"name":"ScheduleWakeup"' *.jsonl"#], at: tickEnd.addingTimeInterval(1)),
            toolResult(#"{"name":"ScheduleWakeup","input":{"delaySeconds":60}}"#, at: tickEnd.addingTimeInterval(2)),
            reply("Twelve.", at: tickEnd.addingTimeInterval(3)),
        ]))
        let loops = await loops(at: tickEnd.addingTimeInterval(10))
        XCTAssertTrue(loops.isEmpty)
    }

    // MARK: - Liveness (Claude Code's process registry)

    /// Without a registry (an older Claude Code), the transcript alone
    /// decides, as before, and the payload says it couldn't tell.
    func testWithoutARegistryLivenessIsUnknown() async throws {
        try write(lines(tick(delay: 1800)))
        let loops = await loops(at: tickEnd.addingTimeInterval(1800 + grace))
        XCTAssertEqual(loops.first?.state, "overdue")
        XCTAssertEqual(loops.first?.liveness, "unknown")
    }

    /// The dgx cases of #44: a session that scheduled a wake and then ended,
    /// with no process left, is ended, not overdue.
    func testALoopWithNoLiveProcessIsEnded() async throws {
        try write(lines(tick(delay: 1800)))
        try register(pid: getpid(), session: "another-session", procStart: try ownProcStart())
        let loops = await loops(at: tickEnd.addingTimeInterval(1800 + grace))
        XCTAssertEqual(loops.first?.state, "ended")
        XCTAssertEqual(loops.first?.liveness, "registry")
    }

    /// With its process running, a loop past its wake is still overdue: that
    /// is the alarm the watchdog acts on.
    func testALiveLoopPastItsWakeIsOverdue() async throws {
        try write(lines(tick(delay: 1800)))
        try register(pid: getpid(), session: "loop", procStart: try ownProcStart())
        let loops = await loops(at: tickEnd.addingTimeInterval(1800 + grace))
        XCTAssertEqual(loops.first?.state, "overdue")
        XCTAssertEqual(loops.first?.liveness, "registry")
    }

    /// A process that died mid-turn leaves the turn open; the registry is what
    /// tells it from one still working.
    func testALoopThatDiedMidTurnIsEnded() async throws {
        let woke = tickEnd.addingTimeInterval(1800)
        try write(lines(tick(delay: 1800) + [fire(at: woke), user("/senior-software-engineer", at: woke)]))
        try register(pid: getpid(), session: "another-session", procStart: try ownProcStart())
        let loops = await loops(at: woke.addingTimeInterval(60))
        XCTAssertEqual(loops.first?.state, "ended")
    }

    /// A pid the system reused for another process doesn't keep a loop alive.
    func testAReusedPidIsNotTheLoopsProcess() async throws {
        try write(lines(tick(delay: 1800)))
        try register(pid: getpid(), session: "loop", procStart: "1")
        let loops = await loops(at: tickEnd.addingTimeInterval(1800 + grace))
        XCTAssertEqual(loops.first?.state, "ended")
    }

    /// Ended loops show for a day, so a stop is seen; then they drop off by
    /// themselves unless asked for.
    func testAnEndedLoopIsListedForADayThenLeftOut() async throws {
        try write(lines(tick(delay: 1800)))
        try register(pid: getpid(), session: "another-session", procStart: try ownProcStart())
        let lastActivity = tickEnd.addingTimeInterval(3)
        let withinADay = await loops(at: lastActivity.addingTimeInterval(CLIRunner.endedLoopRetention))
        XCTAssertEqual(withinADay.map(\.state), ["ended"])
        let later = lastActivity.addingTimeInterval(CLIRunner.endedLoopRetention + 1)
        let pastADay = await loops(at: later)
        XCTAssertTrue(pastADay.isEmpty)
        let included = await loops(at: later, includeEnded: true)
        XCTAssertEqual(included.map(\.state), ["ended"])
    }

    /// The retention is applied from the file's time, before the transcript is
    /// read, so a sweep doesn't read every session the host ever had. The
    /// records here claim a recent tick, but the file was last written two
    /// days ago and its process has exited: it is skipped unread.
    func testAnExitedSessionWrittenBeforeTheWindowIsNotRead() async throws {
        let now = tickEnd.addingTimeInterval(3600)
        try write(lines(tick(delay: 1800)), modified: now.addingTimeInterval(-2 * CLIRunner.endedLoopRetention))
        try register(pid: getpid(), session: "another-session", procStart: try ownProcStart())
        let skipped = await loops(at: now)
        XCTAssertTrue(skipped.isEmpty)
        // A live process is always read, however old its file.
        try register(pid: getpid(), session: "loop", procStart: try ownProcStart())
        let live = await loops(at: now)
        XCTAssertEqual(live.map(\.sessionId), ["loop"])
    }

    func testTheRegistryChecksThePidAndItsStart() throws {
        let start = try ownProcStart()
        XCTAssertTrue(ClaudeProcessRegistry.isAlive(pid: getpid(), procStart: start))
        XCTAssertFalse(ClaudeProcessRegistry.isAlive(pid: getpid(), procStart: "1"))
        XCTAssertFalse(ClaudeProcessRegistry.isAlive(pid: 0, procStart: start))
    }

    /// Field 22 counts from after the command name, which may hold spaces
    /// and parentheses.
    func testTheLinuxStartIsReadAfterTheCommandName() {
        let stat = "4242 (my (odd) cmd) S 1 4242 4242 0 -1 4194560 100 0 0 0 5 3 0 0 20 0 8 0 155127713 1000 50"
        XCTAssertEqual(ClaudeProcessRegistry.linuxStartTime(stat: stat), "155127713")
    }

    /// macOS records `ps -o lstart` in the C locale and UTC, with a
    /// space-padded day.
    func testTheMacStartParsesPsLstart() throws {
        let date = try XCTUnwrap(ClaudeProcessRegistry.parseLstart("Mon Oct  5 12:55:14 2026"))
        XCTAssertEqual(date, Date(timeIntervalSince1970: 1_791_204_914))
    }

    // MARK: - Far from the tail

    /// Mid-tick, a loop that has read big files has its last call megabytes
    /// back. It must still be found, or the watchdog restarts a healthy loop.
    func testACallFarBeyondTheTailIsStillFound() async throws {
        let woke = tickEnd.addingTimeInterval(1800)
        var records = tick(delay: 1800) + [fire(at: woke), user("/senior-software-engineer", at: woke)]
        for second in 1...30 {
            records.append(toolResult(String(repeating: "x", count: 100_000), at: woke.addingTimeInterval(TimeInterval(second))))
        }
        try write(lines(records))

        let loops = await loops(at: woke.addingTimeInterval(60))
        XCTAssertEqual(loops.first?.state, "working")
        XCTAssertEqual(loops.first?.wakesAt, woke)

        // The session list's cheap tail read still doesn't see it, by design.
        let source = ClaudeCodeSessionSource(rootURL: root)
        _ = try await source.listSessionRefs()
        let summary = try await source.loadSummary(id: "loop")
        XCTAssertNil(summary.wakesAt)
    }

    /// A call that straddles two of the backwards search's chunks.
    func testACallAcrossAChunkEdgeIsFound() throws {
        let before = try lines([user("/senior-software-engineer", at: tickEnd.addingTimeInterval(-300))])
        let call = try lines([wakeup(["delaySeconds": 1800, "reason": "edge"], at: tickEnd)])
        let marker = Data(#""name":"ScheduleWakeup""#.utf8)
        let markerStart = before.count + call.range(of: marker)!.lowerBound

        // A padding line sized so the chunk edge falls 5 bytes into the marker.
        let emptyPad = try lines([toolResult("", at: tickEnd.addingTimeInterval(1))])
        let target = ClaudeLoopReader.chunkSize + markerStart + 5 - before.count - call.count - emptyPad.count
        let pad = try lines([toolResult(String(repeating: "y", count: target), at: tickEnd.addingTimeInterval(1))])
        let data = before + call + pad
        XCTAssertEqual(data.count - ClaudeLoopReader.chunkSize, markerStart + 5)

        let url = try write(data)
        let tick = try XCTUnwrap(try ClaudeLoopReader.lastTick(fileURL: url))
        XCTAssertEqual(tick.reason, "edge")
        XCTAssertEqual(tick.wakesAt, tickEnd.addingTimeInterval(1800))
    }

    // MARK: - One per project

    func testARestartedLoopReplacesTheDeadOneInItsProject() async throws {
        // Sessions are ordered by file mtime, so each is set to its last write.
        let dead = tickEnd.addingTimeInterval(-86_400)
        let files = [
            (try write(lines(tick(delay: 1800, at: dead)), session: "dead"), dead),
            (try write(lines(tick(delay: 1800)), session: "restarted"), tickEnd),
            (try write(lines(tick(delay: 1800, cwd: "/home/u/other")), project: "-home-u-other", session: "other"), tickEnd),
        ]
        for (url, date) in files {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }

        let loops = await loops(at: tickEnd.addingTimeInterval(100))
        XCTAssertEqual(Set(loops.map(\.projectPath)), ["/home/u/loop", "/home/u/other"])
        XCTAssertEqual(loops.first { $0.projectPath == "/home/u/loop" }?.sessionId, "restarted")
    }

    // MARK: - CLI

    func testTheCLIPrintsLoopsAsJSON() async throws {
        try write(lines(tick(delay: 1800)))
        var out = ""
        var err = ""
        let status = await CLIRunner.runLoops(
            ["--json", "--grace-minutes", "0", "--include-ended", "--claude-root", root.path],
            now: tickEnd.addingTimeInterval(1800),
            stdout: { out += $0 }, stderr: { err += $0 })
        XCTAssertEqual(status.code, 0, err)
        let payload = try RemoteLoopPayload.makeDecoder().decode(RemoteLoopPayload.self, from: Data(out.utf8))
        XCTAssertEqual(payload.schemaVersion, 1)
        XCTAssertEqual(payload.cliVersion, CLIRunner.version)
        XCTAssertEqual(payload.graceSeconds, 0)
        XCTAssertEqual(payload.loops.map(\.state), ["overdue"])
    }

    func testTheCLIRejectsABadGrace() async {
        var err = ""
        let status = await CLIRunner.run(arguments: ["loops", "--json", "--grace-minutes", "soon"],
                                          stdout: { _ in }, stderr: { err += $0 })
        XCTAssertEqual(status.code, 64)
        XCTAssertTrue(err.contains("--grace-minutes"))
    }
}
