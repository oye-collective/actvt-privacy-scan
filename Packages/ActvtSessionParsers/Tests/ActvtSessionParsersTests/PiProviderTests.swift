//
//  PiProviderTests.swift
//  ActvtSessionParsersTests
//

import XCTest
@testable import ActvtSessionParsers

/// Locator, parser and source for the pi coding agent, against synthesized
/// session files in a temporary root. Shapes mirror real pi 0.85.1 output.
final class PiProviderTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("actvt-pi-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: - Fixture builders

    private static let sessionId = "01a09040-0d56-77d0-812d-b9b758f2b046"
    private static let fileName = "2026-09-11T11-35-11-959Z_\(sessionId).jsonl"

    private func line(_ obj: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func header(cwd: String = "/home/dev/projects/demo") -> String {
        line(["type": "session", "version": 3, "id": Self.sessionId,
              "timestamp": "2026-09-11T11:35:11.959Z", "cwd": cwd])
    }

    private func modelChange(id: String, parent: String?) -> String {
        line(["type": "model_change", "id": id, "parentId": parent as Any,
              "timestamp": "2026-09-11T11:35:11.991Z", "provider": "vllm", "modelId": "qwen3.8-27b"])
    }

    private func user(id: String, parent: String?, _ text: String, at: String = "2026-09-11T11:36:42.568Z") -> String {
        line(["type": "message", "id": id, "parentId": parent as Any, "timestamp": at,
              "message": ["role": "user", "content": [["type": "text", "text": text]], "timestamp": 1789126602565]])
    }

    private func assistant(
        id: String, parent: String?, blocks: [[String: Any]],
        stopReason: String = "stop", errorMessage: String? = nil,
        usage: [String: Any]? = nil, at: String = "2026-09-11T11:36:50.000Z"
    ) -> String {
        var message: [String: Any] = [
            "role": "assistant", "content": blocks, "api": "openai-completions",
            "provider": "vllm", "model": "qwen3.8-27b", "stopReason": stopReason, "timestamp": 1789126610000,
            "usage": usage ?? ["input": 100, "output": 20, "cacheRead": 0, "cacheWrite": 0, "reasoning": 5,
                               "totalTokens": 120, "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": 0]],
        ]
        if let errorMessage { message["errorMessage"] = errorMessage }
        return line(["type": "message", "id": id, "parentId": parent as Any, "timestamp": at, "message": message])
    }

    private func toolResult(id: String, parent: String?, callId: String, content: [[String: Any]], isError: Bool = false) -> String {
        line(["type": "message", "id": id, "parentId": parent as Any, "timestamp": "2026-09-11T11:36:51.000Z",
              "message": ["role": "toolResult", "toolCallId": callId, "toolName": "bash",
                          "content": content, "isError": isError, "timestamp": 1789126611000]])
    }

    @discardableResult
    private func write(_ lines: [String], slug: String = "--home-dev-projects-demo--", name: String = fileName) throws -> URL {
        let dir = root.appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The real 48-line DGX session, reduced to its shape: header, model,
    /// thinking level, a prompt, a tool-using response, its result, a reply.
    private func linearSession() -> [String] {
        [
            header(),
            modelChange(id: "m1", parent: nil),
            line(["type": "thinking_level_change", "id": "t1", "parentId": "m1",
                  "timestamp": "2026-09-11T11:35:11.991Z", "thinkingLevel": "medium"]),
            user(id: "u1", parent: "t1", "Remove the Last commit column in @02-services-catalogue.md"),
            assistant(id: "a1", parent: "u1", blocks: [
                ["type": "thinking", "thinking": "Need to read the file first."],
                ["type": "text", "text": "Reading the file."],
                ["type": "toolCall", "id": "call-1", "name": "read",
                 "arguments": ["path": "/home/dev/projects/demo/02-services-catalogue.md"]],
            ], stopReason: "toolUse"),
            toolResult(id: "r1", parent: "a1", callId: "call-1", content: [["type": "text", "text": "| Service | Last commit |"]]),
            assistant(id: "a2", parent: "r1", blocks: [["type": "text", "text": "Done, the column is gone."]]),
        ]
    }

    // MARK: - Locator

    func testLocatorParsesFileNameIntoIdAndStart() {
        let parsed = PiSessionsLocator.parseFileName(Self.fileName)
        XCTAssertEqual(parsed?.sessionId, Self.sessionId)
        let expected = try! Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse("2026-09-11T11:35:11.959Z")
        XCTAssertEqual(parsed?.startedAt, expected)
        XCTAssertNil(PiSessionsLocator.parseFileName("notes.jsonl"))
        XCTAssertNil(PiSessionsLocator.parseFileName("2026-09-11T11-35-11-959Z_not-a-uuid.jsonl"))
    }

    func testLocatorWalksSlugDirectoriesAndSkipsForeignFiles() throws {
        try write(linearSession())
        try write(linearSession(), slug: "--Users-x-other--", name: "2026-09-12T08-00-00-000Z_01a09f9d-aaea-73f4-8bf1-e02b93dfde23.jsonl")
        try write(["{}"], slug: "--Users-x-other--", name: "README.jsonl")
        try "stray".write(to: root.appendingPathComponent("stray.jsonl"), atomically: true, encoding: .utf8)

        let found = try PiSessionsLocator.discoverSessions(at: root)
        XCTAssertEqual(Set(found.map(\.sessionId)), [Self.sessionId, "01a09f9d-aaea-73f4-8bf1-e02b93dfde23"])
    }

    func testLocatorMissingRootIsEmptyNotError() throws {
        let missing = root.appendingPathComponent("nope", isDirectory: true)
        XCTAssertEqual(try PiSessionsLocator.discoverSessions(at: missing).count, 0)
    }

    func testLocatorHonorsPiEnvironmentOverrides() {
        let sessionDir = PiSessionsLocator.defaultSessionsURL(environment: ["PI_CODING_AGENT_SESSION_DIR": "/tmp/s"])
        XCTAssertEqual(sessionDir.path, "/tmp/s")
        let agentDir = PiSessionsLocator.defaultSessionsURL(environment: ["PI_CODING_AGENT_DIR": "/tmp/agent"])
        XCTAssertEqual(agentDir.path, "/tmp/agent/sessions")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(PiSessionsLocator.defaultSessionsURL(environment: [:]).path, home + "/.pi/agent/sessions")
    }

    // MARK: - Parser

    private func parseEntry(_ raw: String) -> PiTranscriptParser.Entry? {
        if case .entry(let e)? = PiTranscriptParser.parseLine(Data(raw.utf8)) { return e }
        return nil
    }

    func testParserReadsHeader() {
        guard case .header(let h)? = PiTranscriptParser.parseLine(Data(header().utf8)) else {
            return XCTFail("expected header")
        }
        XCTAssertEqual(h.sessionId, Self.sessionId)
        XCTAssertEqual(h.cwd, "/home/dev/projects/demo")
        XCTAssertEqual(h.version, 3)
    }

    func testParserReadsAssistantUsageAndToolCallPath() {
        let entry = parseEntry(assistant(id: "a1", parent: "u1", blocks: [
            ["type": "toolCall", "id": "c1", "name": "edit", "arguments": ["path": "/p/f.swift", "oldText": "a", "newText": "b"]],
        ], stopReason: "toolUse", usage: [
            "input": 3472, "output": 215, "cacheRead": 10, "cacheWrite": 7, "cacheWrite1h": 2, "reasoning": 0,
            "totalTokens": 3687, "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": 0.0125],
        ]))
        guard case .message(.assistant(let a))? = entry?.kind else { return XCTFail("expected assistant") }
        XCTAssertEqual(a.model, "qwen3.8-27b")
        XCTAssertEqual(a.stopReason, "toolUse")
        XCTAssertEqual(a.usage?.input, 3472)
        XCTAssertEqual(a.usage?.cacheWrite, 7)
        XCTAssertEqual(a.usage?.cacheWrite1h, 2)
        XCTAssertEqual(a.usage?.costTotal, 0.0125)
        guard case .toolCall(let id, let name, let arguments, let filePath)? = a.blocks.first else {
            return XCTFail("expected toolCall")
        }
        XCTAssertEqual(id, "c1")
        XCTAssertEqual(name, "edit")
        XCTAssertEqual(filePath, "/p/f.swift")
        XCTAssertEqual(arguments, #"{"newText":"b","oldText":"a","path":"\/p\/f.swift"}"#)
    }

    func testParserDropsImageBytes() {
        let entry = parseEntry(toolResult(id: "r1", parent: "a1", callId: "c1", content: [
            ["type": "text", "text": "Read image file [image/png]"],
            ["type": "image", "data": String(repeating: "A", count: 4096), "mimeType": "image/png"],
        ]))
        guard case .message(.toolResult(_, _, let text, _))? = entry?.kind else { return XCTFail("expected toolResult") }
        XCTAssertEqual(text, "Read image file [image/png]\n[image]")
    }

    func testParserKeepsRareEntryTypesForTreeWalks() {
        let compaction = parseEntry(line(["type": "compaction", "id": "c1", "parentId": "a1", "timestamp": "2026-09-04T07:59:04.957Z",
                                          "summary": "...", "firstKeptEntryId": "u3", "tokensBefore": 180000]))
        guard case .compaction(_, let before, _)? = compaction?.kind else { return XCTFail("expected compaction") }
        XCTAssertEqual(before, 180000)

        let info = parseEntry(line(["type": "session_info", "id": "s1", "parentId": "c1", "timestamp": "2026-09-04T08:00:00.000Z", "name": "Data room"]))
        guard case .sessionInfo(let name)? = info?.kind else { return XCTFail("expected session_info") }
        XCTAssertEqual(name, "Data room")

        let label = parseEntry(line(["type": "label", "id": "l1", "parentId": "s1", "timestamp": "2026-09-04T08:00:00.000Z", "targetId": "u1", "label": "x"]))
        guard case .other(let type)? = label?.kind else { return XCTFail("expected other") }
        XCTAssertEqual(type, "label")

        XCTAssertNil(PiTranscriptParser.parseLine(Data("not json".utf8)))
        XCTAssertNil(PiTranscriptParser.parseLine(Data(#"{"type":"message"}"#.utf8)), "an entry without an id cannot join the tree")
    }

    func testActivePathFollowsLeafAndSkipsAbandonedBranch() {
        // u1 -> a1 -> u2a -> a2a (abandoned), then the user re-edits: u2b -> a2b (leaf).
        let entries = [
            user(id: "u1", parent: nil, "one"),
            assistant(id: "a1", parent: "u1", blocks: [["type": "text", "text": "r1"]]),
            user(id: "u2a", parent: "a1", "first attempt"),
            assistant(id: "a2a", parent: "u2a", blocks: [["type": "text", "text": "r2a"]]),
            user(id: "u2b", parent: "a1", "second attempt"),
            assistant(id: "a2b", parent: "u2b", blocks: [["type": "text", "text": "r2b"]]),
        ].compactMap(parseEntry)
        XCTAssertEqual(entries.count, 6)
        XCTAssertEqual(PiTranscriptParser.activePath(entries).map(\.id), ["u1", "a1", "u2b", "a2b"])
    }

    func testActivePathStopsAtMissingParent() {
        let entries = [
            user(id: "u2", parent: "missing", "orphaned"),
            assistant(id: "a2", parent: "u2", blocks: [["type": "text", "text": "r"]]),
        ].compactMap(parseEntry)
        XCTAssertEqual(PiTranscriptParser.activePath(entries).map(\.id), ["u2", "a2"])
        XCTAssertTrue(PiTranscriptParser.activePath([]).isEmpty)
    }

    // MARK: - Source

    func testSourceListsSummarizesAndTranscribes() async throws {
        try write(linearSession())
        let source = PiSessionSource(rootURL: root)
        let available = await source.isAvailable
        XCTAssertTrue(available)

        let refs = try await source.listSessionRefs()
        XCTAssertEqual(refs.map(\.id), [Self.sessionId])
        XCTAssertEqual(refs.first?.agentKind, .pi)

        let summary = try await source.loadSummary(id: Self.sessionId)
        XCTAssertEqual(summary.projectPath, "/home/dev/projects/demo")
        XCTAssertEqual(summary.title, "Remove the Last commit column in @02-services-catalogue.md")
        XCTAssertEqual(summary.messageCount, 3)
        XCTAssertNil(summary.aiTitle)
        XCTAssertEqual(summary.startedAt, try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse("2026-09-11T11:35:11.959Z"))

        let transcript = try await source.loadTranscript(id: Self.sessionId)
        XCTAssertEqual(transcript.agentKind, .pi)
        XCTAssertEqual(transcript.projectPath, "/home/dev/projects/demo")
        XCTAssertEqual(transcript.turns.count, 4)   // model note, user, assistant, assistant

        guard case .systemNotification(_, let note, _) = transcript.turns[0] else { return XCTFail("expected model note") }
        XCTAssertEqual(note, "Model: vllm/qwen3.8-27b")
        guard case .user("u1", let prompt, _) = transcript.turns[1] else { return XCTFail("expected user") }
        XCTAssertTrue(prompt.hasPrefix("Remove the Last commit"))
        guard case .assistant("a1", let blocks, _) = transcript.turns[2] else { return XCTFail("expected assistant") }
        XCTAssertEqual(blocks.count, 3)
        guard case .toolUse(let callId, let name, let input) = blocks[2] else { return XCTFail("expected toolUse") }
        XCTAssertEqual(callId, "call-1")
        XCTAssertEqual(name, "read")
        XCTAssertTrue(input.contains("02-services-catalogue.md"))
        XCTAssertEqual(transcript.toolResultsByID["call-1"]?.content, "| Service | Last commit |")
        XCTAssertEqual(transcript.toolResultsByID["call-1"]?.isError, false)

        let file = await source.indexableFile(for: Self.sessionId)
        XCTAssertEqual(file?.url.lastPathComponent, Self.fileName)
        XCTAssertNil(file?.sidecarDir)
    }

    func testSourceTitlePrefersSessionName() async throws {
        var lines = linearSession()
        lines.append(line(["type": "session_info", "id": "s1", "parentId": "a2",
                           "timestamp": "2026-09-11T11:40:00.000Z", "name": "Catalogue cleanup"]))
        try write(lines)
        let summary = try await PiSessionSource(rootURL: root).loadSummary(id: Self.sessionId)
        XCTAssertEqual(summary.title, "Catalogue cleanup")
    }

    func testSourceTranscriptShowsActiveBranchOnly() async throws {
        try write([
            header(),
            user(id: "u1", parent: nil, "one"),
            assistant(id: "a1", parent: "u1", blocks: [["type": "text", "text": "r1"]]),
            user(id: "u2a", parent: "a1", "abandoned"),
            assistant(id: "a2a", parent: "u2a", blocks: [["type": "text", "text": "r2a"]]),
            user(id: "u2b", parent: "a1", "kept"),
            assistant(id: "a2b", parent: "u2b", blocks: [["type": "text", "text": "r2b"]]),
        ])
        let transcript = try await PiSessionSource(rootURL: root).loadTranscript(id: Self.sessionId)
        XCTAssertEqual(transcript.turns.map(\.recordUUID), ["u1", "a1", "u2b", "a2b"])
    }

    func testSourceSurfacesErrorsBashAndCompaction() async throws {
        try write([
            header(),
            user(id: "u1", parent: nil, "go"),
            assistant(id: "a1", parent: "u1", blocks: [], stopReason: "error", errorMessage: "connection refused"),
            line(["type": "message", "id": "b1", "parentId": "a1", "timestamp": "2026-09-11T11:37:00.000Z",
                  "message": ["role": "bashExecution", "command": "ls", "output": "a.txt", "exitCode": 0,
                              "cancelled": false, "truncated": false, "timestamp": 1789126620000]]),
            line(["type": "compaction", "id": "c1", "parentId": "b1", "timestamp": "2026-09-11T11:38:00.000Z",
                  "summary": "s", "firstKeptEntryId": "u1", "tokensBefore": 5000]),
            line(["type": "custom_message", "id": "x1", "parentId": "c1", "timestamp": "2026-09-11T11:38:01.000Z",
                  "customType": "ext", "content": "hidden", "display": false]),
            line(["type": "custom_message", "id": "x2", "parentId": "x1", "timestamp": "2026-09-11T11:38:02.000Z",
                  "customType": "ext", "content": "shown", "display": true]),
        ])
        let transcript = try await PiSessionSource(rootURL: root).loadTranscript(id: Self.sessionId)
        let rendered = transcript.turns.map { turn -> String in
            switch turn {
            case .user(_, let t, _): return "user:\(t)"
            case .assistant(_, let b, _):
                return "assistant:" + b.map { if case .text(let s) = $0 { return s } else { return "?" } }.joined()
            case .systemNotification(_, let t, _): return "system:\(t)"
            }
        }
        XCTAssertEqual(rendered, [
            "user:go",
            "assistant:connection refused",
            "user:! ls",
            "system:a.txt",
            "system:Context compacted: 5000 tokens summarized.",
            "system:shown",
        ])
    }

    func testSourceUnknownIdThrows() async throws {
        try write(linearSession())
        let source = PiSessionSource(rootURL: root)
        do {
            _ = try await source.loadSummary(id: "no-such")
            XCTFail("expected sessionNotFound")
        } catch AgentSessionSourceError.sessionNotFound(let id) {
            XCTAssertEqual(id, "no-such")
        }
    }
}
