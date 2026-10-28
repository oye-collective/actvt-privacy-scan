//
//  SessionMemoryTests.swift
//  ActvtSessionsKitTests
//

import XCTest
@testable import ActvtSessionsKit

/// What a session's agent knew, used and learned from memory, read from its
/// transcript. Records are shaped like real ones on dgx (2026-10-07).
final class SessionMemoryTests: XCTestCase {

    private var root: URL!
    private let start = Date(timeIntervalSince1970: 1_791_350_000)
    private let memoryDir = "/home/u/.claude/projects/-home-u-pricing/memory"

    override func setUp() {
        super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("actvt-memory-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: - Records

    private func stamp(_ seconds: Double) -> String {
        Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(start.addingTimeInterval(seconds))
    }

    private let index = """
        - [OpenAI cache writes stay 0.0](openai-cache-write-zero.md) — the user deliberately keeps 0.0, not drift
        - [Parsing OpenAI's pricing page](openai-pricing-page-parsing.md) — full table lives in astro-island props
        """

    private func instructions(at seconds: Double = 0, sidechain: Bool = false) -> [String: Any] {
        ["type": "attachment", "uuid": UUID().uuidString, "timestamp": stamp(seconds), "isSidechain": sidechain,
         "attachment": ["type": "instructions", "files": [
             ["path": "/home/u/.claude/CLAUDE.md", "type": "User", "content": String(repeating: "x", count: 2_000)],
             ["path": "/home/u/pricing/CLAUDE.md", "type": "Project", "content": "# Pricing"],
             ["path": "\(memoryDir)/MEMORY.md", "type": "AutoMem", "content": index],
         ]]]
    }

    private func user(_ text: String, at seconds: Double) -> [String: Any] {
        ["type": "user", "uuid": UUID().uuidString, "timestamp": stamp(seconds), "cwd": "/home/u/pricing",
         "message": ["role": "user", "content": text]]
    }

    private func tool(_ name: String, _ input: [String: Any], id: String, uuid: String = UUID().uuidString,
                      at seconds: Double) -> [String: Any] {
        ["type": "assistant", "uuid": uuid, "timestamp": stamp(seconds),
         "message": ["role": "assistant", "content": [["type": "tool_use", "id": id, "name": name, "input": input]]]]
    }

    private func result(_ id: String, _ content: String, error: Bool = false, at seconds: Double) -> [String: Any] {
        ["type": "user", "uuid": UUID().uuidString, "timestamp": stamp(seconds),
         "message": ["role": "user", "content": [
             ["type": "tool_result", "tool_use_id": id, "content": content, "is_error": error],
         ]]]
    }

    /// A Read result as Claude Code writes it: its own note, then the
    /// numbered file.
    private func readResult(_ file: String) -> String {
        "<system-reminder>This memory is 2 days old.</system-reminder>\n"
            + file.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                .map { "\($0.offset + 1)\t\($0.element)" }.joined(separator: "\n")
    }

    private let feedbackMemory = """
        ---
        name: openai-cache-write-zero
        description: "page shows a Cache writes column; the user deliberately keeps 0.0"
        metadata:
          type: feedback
        ---

        Keep 0.0.
        """

    private func memory(of records: [[String: Any]]) async throws -> (SessionMemory, AgentTranscript) {
        let dir = root.appendingPathComponent("-home-u-pricing", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var data = Data()
        for record in records {
            data += try JSONSerialization.data(withJSONObject: record) + Data("\n".utf8)
        }
        try data.write(to: dir.appendingPathComponent("s.jsonl"))
        let source = ClaudeCodeSessionSource(rootURL: root)
        _ = try await source.listSessionRefs()
        let transcript = try await source.loadTranscript(id: "s")
        return (SessionMemory(transcript), transcript)
    }

    // MARK: - What it knew

    func testTheSessionStartsWithItsInstructionsAndIndex() async throws {
        let (memory, _) = try await memory(of: [instructions(), user("check pricing", at: 1)])
        XCTAssertEqual(memory.sources.map(\.kind), [.user, .project, .memoryIndex])
        XCTAssertEqual(memory.sources.first?.byteCount, 2_000)
        XCTAssertEqual(memory.sources.first?.loadedAt, start)
        XCTAssertEqual(memory.knownCount, 2)
        XCTAssertEqual(memory.memories.map(\.title), ["OpenAI cache writes stay 0.0", "Parsing OpenAI's pricing page"])
        XCTAssertEqual(memory.memories.first?.path, "\(memoryDir)/openai-cache-write-zero.md")
        XCTAssertEqual(memory.memories.first?.hook, "the user deliberately keeps 0.0, not drift")
        XCTAssertEqual(memory.openedCount, 0)
    }

    func testANestedInstructionFileIsASourceToo() async throws {
        let nested: [String: Any] = [
            "type": "attachment", "uuid": "n", "timestamp": stamp(30),
            "attachment": ["type": "nested_memory", "path": "/home/u/pricing/web/CLAUDE.md",
                           "content": ["path": "/home/u/pricing/web/CLAUDE.md", "type": "Project", "content": "# Web"]],
        ]
        let (memory, _) = try await memory(of: [instructions(), user("go", at: 1), nested])
        XCTAssertEqual(memory.sources.last?.kind, .nested)
        XCTAssertEqual(memory.sources.last?.loadedAt, start.addingTimeInterval(30))
    }

    /// After a compaction Claude Code loads the same files again.
    func testAReloadedSourceAppearsOnce() async throws {
        let (memory, _) = try await memory(of: [instructions(), user("go", at: 1), instructions(at: 900)])
        XCTAssertEqual(memory.sources.count, 3)
        XCTAssertEqual(memory.sources.first?.loadedAt, start)
        XCTAssertEqual(memory.memories.count, 2)
        XCTAssertEqual(memory.memories.map(\.knownSince), [start, start], "the first listing counts")
    }

    /// The index loads again after each compaction. A memory this session
    /// created before the index first listed it was learned here, not known.
    func testAMemoryListedOnlyAfterTheSessionWroteItWasLearned() async throws {
        let path = "\(memoryDir)/new-lesson.md"
        let later: [String: Any] = [
            "type": "attachment", "uuid": UUID().uuidString, "timestamp": stamp(600),
            "attachment": ["type": "instructions", "files": [
                ["path": "\(memoryDir)/MEMORY.md", "type": "AutoMem",
                 "content": index + "\n- [New lesson](new-lesson.md) — learned at 60 s"],
            ]],
        ]
        let (memory, _) = try await memory(of: [
            user("go", at: 0),
            tool("Write", ["file_path": path, "content": "---\nname: new-lesson\n---\n"], id: "w1", at: 60),
            result("w1", "File created successfully at: \(path)", at: 60.5),
            later,
            tool("Read", ["file_path": "\(memoryDir)/openai-cache-write-zero.md"], id: "r1", at: 700),
            result("r1", readResult(feedbackMemory), at: 700.5),
        ])
        let lesson = try XCTUnwrap(memory.memories.first { $0.path == path })
        XCTAssertFalse(lesson.wasKnown)
        XCTAssertEqual(lesson.title, "new-lesson")
        XCTAssertEqual(memory.createdCount, 1)
        XCTAssertEqual(memory.knownCount, 2, "the two the index listed before anything was written")
        XCTAssertEqual(memory.memories.first { $0.title == "OpenAI cache writes stay 0.0" }?.knownSince,
                       start.addingTimeInterval(600))
    }

    func testASubagentsLoadsAreNotTheSessions() async throws {
        let (memory, _) = try await memory(of: [instructions(sidechain: true), user("go", at: 1)])
        XCTAssertTrue(memory.isEmpty)
    }

    // MARK: - What it used and learned: today's pricing check

    func testThePricingCheckOpensBothAndUpdatesOne() async throws {
        let parsing = "\(memoryDir)/openai-pricing-page-parsing.md"
        let (memory, _) = try await memory(of: [
            instructions(),
            user("You are performing an automated daily check", at: 1),
            tool("Read", ["file_path": parsing], id: "r1", at: 4),
            result("r1", readResult("---\nname: openai-pricing-page-parsing\nmetadata:\n  type: reference\n---\nbody"), at: 4.5),
            tool("Read", ["file_path": "\(memoryDir)/openai-cache-write-zero.md"], id: "r2", at: 5),
            result("r2", readResult(feedbackMemory), at: 5.5),
            tool("Read", ["file_path": "/home/u/pricing/pricing.json"], id: "r3", at: 10),
            result("r3", "1\t{}", at: 10.5),
            tool("Edit", ["file_path": parsing, "old_string": "- Cyber", "new_string": "- gpt-5.6-sol promo\n- Cyber"],
                 id: "e1", uuid: "edit-turn", at: 41),
            result("e1", "The file \(parsing) has been updated successfully.", at: 41.5),
        ])

        XCTAssertEqual(memory.knownCount, 2)
        XCTAssertEqual(memory.openedCount, 2)
        XCTAssertEqual(memory.updatedCount, 1)
        XCTAssertEqual(memory.createdCount, 0)

        let cache = try XCTUnwrap(memory.memories.first)
        XCTAssertEqual(cache.type, "feedback")
        XCTAssertEqual(cache.title, "OpenAI cache writes stay 0.0", "the index's title wins for a known memory")
        XCTAssertFalse(cache.wasChanged)

        let updated = try XCTUnwrap(memory.event(forToolUseID: "e1"))
        XCTAssertEqual(updated.memory.path, parsing)
        XCTAssertEqual(updated.memory.type, "reference")
        XCTAssertEqual(updated.event.kind, .updated)
        XCTAssertEqual(updated.event.turnUUID, "edit-turn")
        XCTAssertEqual(updated.event.at, start.addingTimeInterval(41))
        XCTAssertEqual(updated.event.written, "- gpt-5.6-sol promo\n- Cyber")
        XCTAssertEqual(updated.event.replaced, "- Cyber")
        XCTAssertEqual(updated.memory.events.map(\.kind), [.opened, .updated])
        XCTAssertNil(memory.event(forToolUseID: "r3"), "a file outside the memory folder is not a memory")
    }

    func testANewMemoryIsLearned() async throws {
        let path = "\(memoryDir)/tiktok-tag-grid-is-ranked.md"
        let (memory, _) = try await memory(of: [
            instructions(),
            tool("Write", ["file_path": path, "content": """
                ---
                name: tiktok-tag-grid-is-ranked
                description: "A tag grid is engagement-ranked, not a recency feed"
                metadata:
                  type: project
                ---
                Body.
                """], id: "w1", at: 60),
            result("w1", "File created successfully at: \(path)", at: 60.5),
            tool("Edit", ["file_path": "\(memoryDir)/MEMORY.md", "old_string": "a", "new_string": "b"], id: "w2", at: 61),
            result("w2", "The file has been updated successfully.", at: 61.5),
        ])
        XCTAssertEqual(memory.createdCount, 1)
        XCTAssertEqual(memory.updatedCount, 0, "the index is bookkeeping, not a memory")
        let learned = try XCTUnwrap(memory.memories.last)
        XCTAssertFalse(learned.wasKnown)
        XCTAssertEqual(learned.title, "tiktok-tag-grid-is-ranked")
        XCTAssertEqual(learned.hook, "A tag grid is engagement-ranked, not a recency feed")
        XCTAssertEqual(learned.type, "project")
        XCTAssertEqual(learned.events.first?.kind, .created)
        XCTAssertTrue(learned.events.first?.written?.contains("Body.") == true)
    }

    func testRewritingAKnownMemoryIsAnUpdate() async throws {
        let (memory, _) = try await memory(of: [
            instructions(),
            tool("Write", ["file_path": "\(memoryDir)/openai-cache-write-zero.md", "content": feedbackMemory],
                 id: "w1", at: 60),
            result("w1", "The file has been updated successfully.", at: 60.5),
        ])
        XCTAssertEqual(memory.updatedCount, 1)
        XCTAssertEqual(memory.createdCount, 0)
    }

    func testAFailedCallChangesNothing() async throws {
        let (memory, _) = try await memory(of: [
            instructions(),
            tool("Read", ["file_path": "\(memoryDir)/gone.md"], id: "r1", at: 5),
            result("r1", "File does not exist.", error: true, at: 5.5),
        ])
        XCTAssertEqual(memory.memories.count, 2)
        XCTAssertEqual(memory.openedCount, 0)
    }

    /// A session from before Claude Code recorded its loads still shows what
    /// it wrote: the folder is recognised by Claude Code's own layout.
    func testWritesShowWithoutARecordedIndex() async throws {
        let (memory, _) = try await memory(of: [
            user("go", at: 0),
            tool("Write", ["file_path": "\(memoryDir)/new.md", "content": "---\nname: new\n---\n"], id: "w1", at: 5),
            result("w1", "File created successfully at: \(memoryDir)/new.md", at: 5.5),
        ])
        XCTAssertTrue(memory.sources.isEmpty)
        XCTAssertEqual(memory.createdCount, 1)
    }

    // MARK: - Pieces

    func testMemoryFilesAreRecognisedByClaudeCodesLayout() {
        XCTAssertTrue(SessionMemory.isMemoryFile("/home/u/.claude/projects/-home-u-x/memory/a.md"))
        XCTAssertTrue(SessionMemory.isMemoryFile("/Users/u/alt-config/projects/-x/memory/a.md"))
        XCTAssertFalse(SessionMemory.isMemoryFile("/home/u/.claude/projects/-home-u-x/memory/MEMORY.md"))
        XCTAssertFalse(SessionMemory.isMemoryFile("/home/u/.claude/projects/-home-u-x/memory/notes.txt"))
        XCTAssertFalse(SessionMemory.isMemoryFile("/home/u/code/memory/a.md"))
        XCTAssertFalse(SessionMemory.isMemoryFile("/home/u/.claude/projects/-x/s.jsonl"))
    }

    func testIndexEntries() {
        let entries = MemorySource.indexEntries(in: """
            # Project Memory

            - [A](a.md) — first hook
            - [B](b.md) - plain hyphen
            * [C](c.md)
            Some prose.
            """, listedAt: start)
        XCTAssertEqual(entries, [
            .init(title: "A", file: "a.md", hook: "first hook", listedAt: start),
            .init(title: "B", file: "b.md", hook: "plain hyphen", listedAt: start),
            .init(title: "C", file: "c.md", hook: nil, listedAt: start),
        ])
    }

    // MARK: - Wire

    func testTheCLICarriesTheSourcesToTheApp() async throws {
        let (_, transcript) = try await memory(of: [instructions(), user("go", at: 1)])
        let payload = RemoteTranscriptPayload(
            cliVersion: "0.6.1", hostname: "dgx", generatedAt: start, transcript: RemoteTranscript(transcript))
        let data = try RemoteSessionPayload.makeEncoder().encode(payload)
        let decoded = try RemoteSessionPayload.makeDecoder().decode(RemoteTranscriptPayload.self, from: data)
        XCTAssertEqual(decoded.transcript.agentTranscript()?.memorySources, transcript.memorySources)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(String(repeating: "x", count: 100)),
                       "a file's content never rides the wire")
    }

    func testAnOlderCLIsTranscriptHasNoSources() throws {
        let json = """
        {"cliVersion":"0.6.0","generatedAt":"2026-10-07T07:19:02.000Z","hostname":"dgx","schemaVersion":1,
         "transcript":{"sessionId":"s","agentKind":"claudeCode","projectPath":"/p","turns":[],"toolResults":{}}}
        """
        let payload = try RemoteSessionPayload.makeDecoder().decode(RemoteTranscriptPayload.self, from: Data(json.utf8))
        XCTAssertEqual(payload.transcript.agentTranscript()?.memorySources, [])
    }
}
