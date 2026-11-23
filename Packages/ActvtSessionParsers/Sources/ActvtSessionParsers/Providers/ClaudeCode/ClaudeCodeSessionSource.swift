//
//  ClaudeCodeSessionSource.swift
//  Actvt
//

import Foundation
#if canImport(os)
import os.log
#endif

/// `AgentSessionSource` for Claude Code.
///
/// Lists sessions from multiple roots: the CLI's `~/.claude/projects` plus any
/// `projects` stores the Claude *Desktop* app keeps under Application Support
/// (discovered by `ClaudeDesktopProjectsLocator`). One source handles all roots
/// — a second registry instance would break `provider(for: kind)` routing.
///
/// Owns a `[sessionId: (session, root)]` cache so summary/sidecar/transcript
/// resolution uses the root each session was actually found under. The cache is
/// rebuilt on every `listSessionRefs()` (the cold-path walk is cheap —
/// directory enumeration + stat only).
public actor ClaudeCodeSessionSource: AgentSessionSource {
    public nonisolated let kind: AgentKind = .claudeCode
    private nonisolated let logger = Logger(subsystem: "com.actvt.io", category: "ClaudeCodeSessionSource")

    /// A discovered session pinned to the root it came from.
    private struct Located {
        let session: ClaudeProjectsLocator.DiscoveredSession
        let root: URL
    }

    /// Roots supplied at init (always listed).
    private let fixedRoots: [URL]
    /// Whether desktop roots are (re)discovered dynamically. True for the
    /// default registry instance; false when explicit roots were injected (tests).
    private let discoversDesktopRoots: Bool
    private var cachedDesktopRoots: [URL] = []
    private var lastDesktopDiscovery: Date = .distantPast
    /// Desktop stores appear/disappear as the app is (un)installed or sessions
    /// are created; re-discover at most this often, from `listSessionRefs()`.
    private static let desktopRediscoveryInterval: TimeInterval = 5 * 60

    private var byId: [String: Located] = [:]

    /// A single line past this (a giant embedded image) is skipped rather than
    /// materialized. A whole transcript is bounded by its window
    /// (`TranscriptWindow.budget`).
    private static let maxLineBytes = 8 * 1024 * 1024          // 8 MB per line

    /// Default instance: the CLI root, any alternate `~/.claude-*` config roots
    /// (a second account, a work/personal split), plus dynamically-discovered
    /// desktop roots.
    ///
    /// `extraRoots` are user-configured directories from Settings. They are
    /// appended rather than replacing discovery, and de-duplicated by
    /// standardized path so naming the same directory twice can't double-count
    /// its sessions.
    public init(extraRoots: [URL] = []) {
        let discovered = [ClaudeProjectsLocator.defaultProjectsURL]
            + ClaudeProjectsLocator.discoverAlternateProjectsURLs()
        var seen: Set<String> = []
        self.fixedRoots = (discovered + extraRoots).filter {
            seen.insert($0.standardizedFileURL.path).inserted
        }
        self.discoversDesktopRoots = true
    }

    /// Explicit roots only — no desktop discovery. Used by tests.
    public init(rootURLs: [URL]) {
        self.fixedRoots = rootURLs
        self.discoversDesktopRoots = false
    }

    /// Single explicit root (test convenience; existing call sites).
    public init(rootURL: URL) {
        self.init(rootURLs: [rootURL])
    }

    public nonisolated var isAvailable: Bool {
        get async {
            let fm = FileManager.default
            let fixedExists = fixedRoots.contains { root in
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: root.path, isDirectory: &isDir) && isDir.boolValue
            }
            if fixedExists { return true }
            // Cheap when the desktop app is absent: two stat calls.
            return discoversDesktopRoots && !ClaudeDesktopProjectsLocator.discoverRoots().isEmpty
        }
    }

    // MARK: - Roots

    /// All roots to list right now. Desktop roots are re-discovered lazily, at
    /// most every `desktopRediscoveryInterval` — a newly-appeared store shows up
    /// on a later refresh (the focus-refresh backstop covers the gap).
    private func currentRoots() -> [URL] {
        guard discoversDesktopRoots else { return fixedRoots }
        let now = Date()
        if now.timeIntervalSince(lastDesktopDiscovery) >= Self.desktopRediscoveryInterval {
            cachedDesktopRoots = ClaudeDesktopProjectsLocator.discoverRoots()
            lastDesktopDiscovery = now
        }
        return fixedRoots + cachedDesktopRoots
    }

    // MARK: - Listing (Tier 1)

    public func listSessionRefs() async throws -> [AgentSessionRef] {
        var map: [String: Located] = [:]
        for root in currentRoots() {
            let discovered: [ClaudeProjectsLocator.DiscoveredSession]
            do {
                discovered = try ClaudeProjectsLocator.discoverSessions(at: root)
            } catch {
                logger.warning("Failed to enumerate \(root.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
            for entry in discovered {
                // Session ids are UUIDs, so cross-root duplicates shouldn't
                // happen; keep the newer file defensively if one ever does.
                if let existing = map[entry.sessionId],
                   existing.session.lastUpdatedAt >= entry.lastUpdatedAt {
                    continue
                }
                map[entry.sessionId] = Located(session: entry, root: root)
            }
        }
        self.byId = map

        return map.values
            .map(\.session)
            .sorted { $0.lastUpdatedAt > $1.lastUpdatedAt }
            .map { AgentSessionRef(id: $0.sessionId, agentKind: .claudeCode, lastUpdatedAt: $0.lastUpdatedAt) }
    }

    // MARK: - Enrichment (Tier 2)

    public func loadSummary(id: String) async throws -> AgentSessionSummary {
        let located = try await resolveSession(id: id)
        let session = located.session
        let head = try SessionFileHead(url: session.fileURL, maxLines: 200)
        var derived = deriveSummaryFields(from: head.lines, fallbackId: id)
        let tail = try readTailRecords(from: session.fileURL)
        // Claude Code rewrites the title as the session goes (hundreds of
        // `ai-title` records in a long one), and since 2026-10 the head can be
        // filled by request records before the first, so the newest title is
        // read from the tail, where a live session's latest sits (B-061).
        if let latest = Self.latestAITitle(in: tail) { derived.aiTitle = latest }
        // A `/rename` is re-appended the same way, so its latest (or the
        // record that cleared it) is in the tail too (T-044, #67).
        if let latest = Self.latestCustomTitle(in: tail) { derived.customTitle = latest }

        return AgentSessionSummary(
            id: id,
            agentKind: .claudeCode,
            projectPath: derived.cwd ?? "(unknown)",
            title: derived.title ?? id,
            aiTitle: derived.aiTitle,
            customTitle: derived.name,
            startedAt: derived.startedAt ?? session.lastUpdatedAt,
            lastUpdatedAt: session.lastUpdatedAt,
            messageCount: head.isWholeFile ? derived.messageCount : nil,
            gitBranch: derived.gitBranch,
            subagentCount: ClaudeProjectsLocator.subagentCount(for: session, root: located.root),
            wakesAt: Self.scheduledWake(in: tail)
        )
    }

    /// The last `ai-title` among these lines, or nil if they hold none.
    static func latestAITitle(in lines: [Data]) -> String? {
        for data in lines.reversed() {
            if case let .aiTitle(text)? = ClaudeTranscriptParser.parseLine(data) { return text }
        }
        return nil
    }

    /// The text of the last `custom-title` among these lines (empty when that
    /// record cleared the name), or nil if they hold none.
    static func latestCustomTitle(in lines: [Data]) -> String? {
        for data in lines.reversed() {
            if case let .customTitle(text)? = ClaudeTranscriptParser.parseLine(data) { return text }
        }
        return nil
    }

    /// When the session's agent last scheduled itself to resume, or nil if it
    /// never did, or its last schedule ended the loop (`stop`).
    ///
    /// A loop agent ends each tick with `ScheduleWakeup` and then writes
    /// nothing for its whole sleep. The call is the agent saying when it will
    /// be back, and until then its silence is not a stop. The schedule
    /// survives a user turn typed in between, so the last call wins whatever
    /// follows it. A call further back than the tail reads as none, which
    /// leaves the session judged by its last write, as before.
    static func scheduledWake(in lines: [Data]) -> Date? {
        ClaudeLoopReader.lastTick(in: lines)?.wakesAt
    }

    /// The session read as a loop agent: its last tick, wherever in the file
    /// the call sits, or nil when it never scheduled a wake or stopped. Used
    /// by `actvt-cli loops`; the summary's `wakesAt` keeps to the tail, which
    /// is enough for a list refresh and cheap enough to run on every one.
    public func loadLoopTick(id: String) async throws -> ClaudeLoopTick? {
        let session = try await resolveSession(id: id).session
        return try ClaudeLoopReader.lastTick(fileURL: session.fileURL)
    }

    /// The `projects` root a session was found under, whose config directory
    /// holds Claude Code's process registry.
    public func projectsRoot(id: String) async throws -> URL {
        try await resolveSession(id: id).root
    }

    // MARK: - Full transcript

    public func loadTranscript(id: String, window request: TranscriptWindowRequest) async throws -> AgentTranscript {
        let session = try await resolveSession(id: id).session
        return try readTranscript(at: session.fileURL, id: id, thread: .main, window: request)
    }

    /// A file outside the projects roots may be a session or a subagent's
    /// thread, so sidechain records are kept, as for a subagent.
    public func loadTranscript(fileAt url: URL, window request: TranscriptWindowRequest) async throws -> AgentTranscript {
        try readTranscript(at: url, id: url.deletingPathExtension().lastPathComponent, thread: .subagent, window: request)
    }

    // MARK: - Usage

    /// Every response the session used, each once, from its own file and its
    /// subagents' (`ClaudeResponseUsage`, the app index's definition).
    public func responseUsage(id: String) async throws -> [ClaudeResponseUsage] {
        let located = try await resolveSession(id: id)
        return try ClaudeProjectsLocator.responseUsage(of: located.session, root: located.root)
    }

    // MARK: - Subagents

    /// Each `subagents/agent-<id>.jsonl` beside the session, with the type and
    /// task its `.meta.json` records.
    public func listSubagents(of id: String) async throws -> [AgentSubagentRef] {
        let located = try await resolveSession(id: id)
        let dir = ClaudeProjectsLocator.sidecarDirectory(for: located.session, root: located.root)
            .appendingPathComponent("subagents", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []
        return files
            .filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("agent-") }
            .map { file in
                let name = file.deletingPathExtension().lastPathComponent
                let meta = (try? Data(contentsOf: dir.appendingPathComponent("\(name).meta.json")))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                return AgentSubagentRef(sessionId: id, agentId: String(name.dropFirst("agent-".count)),
                                        agentType: meta?["agentType"] as? String,
                                        description: meta?["description"] as? String)
            }
            .sorted { $0.agentId < $1.agentId }
    }

    public func loadTranscript(of subagent: AgentSubagentRef, window request: TranscriptWindowRequest) async throws -> AgentTranscript {
        let located = try await resolveSession(id: subagent.sessionId)
        let file = ClaudeProjectsLocator.sidecarDirectory(for: located.session, root: located.root)
            .appendingPathComponent("subagents/agent-\(subagent.agentId).jsonl")
        return try readTranscript(at: file, id: subagent.sessionId, thread: .subagent, window: request)
    }

    // MARK: - Reading a transcript file

    /// Which thread a transcript file holds. In a session's own file, Claude
    /// Code marks a subagent's records `isSidechain` (older versions wrote them
    /// there, inline). A subagent's own file holds only its thread, every
    /// record marked so.
    private enum TranscriptThread {
        case main, subagent

        func owns(isSidechain: Bool) -> Bool {
            self == .subagent || !isSidechain
        }
    }

    private func readTranscript(at fileURL: URL, id: String, thread: TranscriptThread,
                                window request: TranscriptWindowRequest) throws -> AgentTranscript {
        var turns: [AgentTurn] = []
        var cwd: String?
        var toolResultsByID: [String: ToolResult] = [:]
        var memorySources: [MemorySource] = []
        let window: TranscriptWindow

        do {
            window = try TranscriptWindow(request, fileAt: fileURL)
            // Stream via a buffered chunked reader rather than `URL.lines`
            // (AsyncLineSequence), which vends one byte per async `next()` and is
            // pathologically slow for large transcripts.
            try AgentTranscriptLineReader.forEachLine(in: fileURL, startingIn: window.start..<window.end) { data, _ in
                // Skip individual oversized lines (e.g. a giant embedded image)
                // rather than buffering them into the transcript.
                let lineBytes = data.count
                if lineBytes > Self.maxLineBytes {
                    logger.warning("Skipping oversized transcript line (\(lineBytes, privacy: .public) bytes) in session \(id, privacy: .public)")
                    return
                }
                guard let record = ClaudeTranscriptParser.parseLine(data) else { return }

                switch record {
                case let .userText(uuid, text, timestamp, recordCwd, _, isSidechain):
                    guard thread.owns(isSidechain: isSidechain) else { return }
                    if cwd == nil, let recordCwd { cwd = recordCwd }
                    turns.append(.user(recordUUID: uuid, text: text, timestamp: timestamp))

                case let .userToolResults(_, results, _, isSidechain):
                    // Tool results render inline on their announcing assistant
                    // turn (matched by tool_use_id), not as standalone turns.
                    guard thread.owns(isSidechain: isSidechain) else { return }
                    for result in results {
                        toolResultsByID[result.toolUseID] = ToolResult(
                            content: result.content,
                            isError: result.isError
                        )
                    }

                case let .assistant(uuid, rawBlocks, timestamp, isSidechain, _):
                    guard thread.owns(isSidechain: isSidechain) else { return }
                    // Token-only assistant records (no display blocks) carry
                    // usage for metrics but render nothing — skip them here.
                    guard !rawBlocks.isEmpty else { return }
                    let blocks = rawBlocks.map { rawBlock -> AssistantBlock in
                        switch rawBlock {
                        case .text(let t):                       return .text(t)
                        case .thinking(let t):                   return .thinking(t)
                        case .toolUse(let id, let name, let input):
                            return .toolUse(id: id, name: name, input: input)
                        }
                    }
                    turns.append(.assistant(recordUUID: uuid, blocks: blocks, timestamp: timestamp))

                case let .systemNotification(uuid, _, text, timestamp):
                    turns.append(.systemNotification(recordUUID: uuid, text: text, timestamp: timestamp))

                case .aiTitle, .customTitle:
                    return

                case let .memorySources(_, sources, _, isSidechain):
                    // Sources load again after every compaction: each path
                    // stays once, and an index gains what it newly lists.
                    guard thread.owns(isSidechain: isSidechain) else { return }
                    for source in sources {
                        if let first = memorySources.firstIndex(where: { $0.path == source.path }) {
                            memorySources[first].absorb(source)
                        } else {
                            memorySources.append(source)
                        }
                    }
                }
            }
        } catch {
            throw AgentSessionSourceError.transcriptUnreadable(id: id, underlying: error)
        }

        return AgentTranscript(
            sessionId: id,
            agentKind: .claudeCode,
            projectPath: cwd ?? "(unknown)",
            turns: turns,
            toolResultsByID: toolResultsByID,
            memorySources: memorySources,
            window: window
        )
    }

    // MARK: - Watcher

    public func makeWatcher() async -> AgentSessionWatcher? {
        // Recursive FSEvents watch over every current root; the store starts it
        // and refreshes on change. Falls back to focus-refresh if unavailable.
        // Desktop roots appearing after this point aren't watched until restart
        // — the periodic re-discovery + focus refresh still list them.
        // No FSEvents off-macOS (the CLI lists on demand and needs no watcher).
        #if canImport(CoreServices)
        CompositeSessionWatcher(roots: currentRoots())
        #else
        nil
        #endif
    }

    // MARK: - Metrics indexing

    /// Resolve a session to its `.jsonl` plus the `(mtime, size)` the indexer
    /// uses as its invalidation key, and the sidecar directory holding
    /// `subagents/`. Reuses the existing locator path logic.
    public func indexableFile(for id: String) async -> IndexableFile? {
        guard let located = try? await resolveSession(id: id) else { return nil }
        let session = located.session
        let url = session.fileURL
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let mtime = values?.contentModificationDate ?? session.lastUpdatedAt
        let size = Int64(values?.fileSize ?? 0)
        let sidecar = ClaudeProjectsLocator.sidecarDirectory(for: session, root: located.root)
        return IndexableFile(url: url, mtime: mtime, fileSize: size, sidecarDir: sidecar)
    }

    // MARK: - Internals

    private func resolveSession(id: String) async throws -> Located {
        if let cached = byId[id] { return cached }
        // Cache miss: rebuild and retry once. Common on first access of a
        // newly-created session or after the watcher signals a change.
        _ = try await listSessionRefs()
        if let refreshed = byId[id] { return refreshed }
        throw AgentSessionSourceError.sessionNotFound(id: id)
    }

    /// The complete lines in the last 64 KB, which is where a loop tick's
    /// closing records sit: 278 of 291 ticks on dgx ended within it (2026-10-06).
    nonisolated private func readTailRecords(from url: URL) throws -> [Data] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let end = try handle.seekToEnd()
        let start = end > 64 * 1024 ? end - 64 * 1024 : 0
        try handle.seek(toOffset: start)
        let chunk = try handle.readToEnd() ?? Data()

        // A read that starts mid-file starts mid-line, so its first piece is
        // dropped; the last is dropped unless newline-terminated, as above.
        var lines = chunk.split(separator: 0x0A, omittingEmptySubsequences: false)
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        if !lines.isEmpty { lines.removeLast() }
        return lines.filter { !$0.isEmpty }.map { Data($0) }
    }

    /// Aggregated fields derived from the header records.
    private struct SummaryFields {
        var aiTitle: String?
        /// The latest `custom-title` record's text; empty once a record cleared it.
        var customTitle: String?
        var firstUserText: String?
        var cwd: String?
        var gitBranch: String?
        var startedAt: Date?
        var messageCount: Int = 0
        /// The name the user gave with `/rename`, unless it was cleared.
        var name: String? {
            guard let customTitle, !customTitle.isEmpty else { return nil }
            return customTitle
        }
        var title: String? {
            if let name { return name }
            if let aiTitle, !aiTitle.isEmpty { return aiTitle }
            if let firstUserText {
                // Truncate to a single line, ~80 chars.
                let firstLine = firstUserText.split(whereSeparator: \.isNewline).first.map(String.init) ?? firstUserText
                return firstLine.count > 80 ? String(firstLine.prefix(80)) + "…" : firstLine
            }
            return nil
        }
    }

    nonisolated private func deriveSummaryFields(from lines: [Data], fallbackId: String) -> SummaryFields {
        var fields = SummaryFields()
        // Counted as the metrics index counts them: one per response, though
        // Claude Code writes a record per content block (B-065).
        var responses = ClaudeResponseCounter()

        for data in lines {
            guard let record = ClaudeTranscriptParser.parseLine(data) else { continue }

            switch record {
            case let .userText(_, text, timestamp, cwd, gitBranch, isSidechain):
                guard !isSidechain else { continue }
                if fields.firstUserText == nil { fields.firstUserText = text }
                if fields.cwd == nil, let cwd { fields.cwd = cwd }
                if fields.gitBranch == nil, let gitBranch { fields.gitBranch = gitBranch }
                if fields.startedAt == nil { fields.startedAt = timestamp }
                fields.messageCount += 1

            case .userToolResults:
                continue

            case let .assistant(_, _, timestamp, isSidechain, _):
                guard !isSidechain else { continue }
                if fields.startedAt == nil { fields.startedAt = timestamp }
                if responses.opensResponse(record) { fields.messageCount += 1 }

            case let .systemNotification(_, _, _, timestamp):
                if fields.startedAt == nil { fields.startedAt = timestamp }

            case .aiTitle(let text):
                fields.aiTitle = text

            case .customTitle(let text):
                fields.customTitle = text

            case .memorySources:
                continue
            }
        }

        return fields
    }
}
