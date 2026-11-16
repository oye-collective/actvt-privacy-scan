//
//  CodexSessionSource.swift
//  Actvt
//

import Foundation
#if canImport(os)
import os.log
#endif

/// `AgentSessionSource` for the Codex CLI.
///
/// Mirrors `ClaudeCodeSessionSource`: owns a `[sessionId: DiscoveredSession]`
/// cache rebuilt on every `listSessionRefs()` (the cold-path walk is stat-only).
/// Codex has no per-session sidecar directory. A sub-agent is a rollout of its
/// own that names its parent in its first record; it is listed as part of that
/// parent, as Claude Code's `subagents/` are (`CodexSessionsLocator.group`), and
/// `indexableFile` hands its file to the parent's metrics.
public actor CodexSessionSource: AgentSessionSource {
    public nonisolated let kind: AgentKind = .codexCLI
    private nonisolated let logger = Logger(subsystem: "com.actvt.io", category: "CodexSessionSource")

    private let rootURL: URL
    private var byId: [String: CodexSessionsLocator.DiscoveredSession] = [:]
    /// Each listed session's sub-agents, by the root session's id.
    private var subagentsOf: [String: [CodexSessionsLocator.DiscoveredSession]] = [:]
    /// The parent each rollout names, by file path ("" for none). Read once per
    /// file: a rollout's first record never changes, so later walks stay stat-only.
    private var parentByPath: [String: String] = [:]

    /// Wall-clock of the last full tree walk. Drives the live-path heuristic
    /// below: rapid back-to-back calls (FS-event bursts during an active write)
    /// take the cheap recent-bucket path; spaced calls (cold start, focus
    /// refresh) re-walk the whole tree.
    private var lastFullWalkAt: Date?

    /// Within this window of the last full walk, `listSessionRefs()` refreshes
    /// only the newest day buckets and merges over the retained map instead of
    /// re-stat-ing the entire `~/.codex/sessions` tree. Tuned to absorb the
    /// watcher's ~2 Hz event churn while staying well below focus-refresh spacing.
    private static let incrementalWalkWindow: TimeInterval = 5
    /// How many `YYYY/MM/DD` buckets the incremental path inspects (today plus a
    /// margin for sessions created on prior days that are still being appended).
    private static let recentDayBucketLimit = 3

    /// A single line past this (embedded base64, a runaway record) is skipped
    /// rather than materialized. A whole transcript is bounded by its window
    /// (`TranscriptWindow.budget`).
    private static let maxLineBytes = 8 * 1024 * 1024          // 8 MB per line

    public init(rootURL: URL = CodexSessionsLocator.defaultSessionsURL) {
        self.rootURL = rootURL
    }

    public nonisolated var isAvailable: Bool {
        get async {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    // MARK: - Listing (Tier 1)

    public func listSessionRefs() async throws -> [AgentSessionRef] {
        // During FS-event bursts (each append to an active session fires the
        // watcher), refresh only the newest day buckets and merge over the
        // retained map rather than re-walking the whole tree; a spaced call
        // (cold start / focus) does the full walk and reconciles everything.
        let now = Date()
        let incremental = lastFullWalkAt.map { now.timeIntervalSince($0) < Self.incrementalWalkWindow } ?? false

        var map: [String: CodexSessionsLocator.DiscoveredSession]
        if incremental {
            let recent = (try? CodexSessionsLocator.discoverRecentSessions(
                at: rootURL, dayBucketLimit: Self.recentDayBucketLimit
            )) ?? []
            // Start from the last full walk so older sessions are never dropped;
            // overlay refreshed recent rows (new sessions, updated mtimes).
            map = self.byId
            for entry in recent { map[entry.sessionId] = entry }
        } else {
            let discovered: [CodexSessionsLocator.DiscoveredSession]
            do {
                discovered = try CodexSessionsLocator.discoverSessions(at: rootURL)
            } catch {
                logger.warning("Failed to enumerate \(self.rootURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return []
            }
            map = [:]
            map.reserveCapacity(discovered.count)
            for entry in discovered { map[entry.sessionId] = entry }
            self.lastFullWalkAt = now
        }
        self.byId = map
        let listed = Set(map.values.map(\.fileURL.path))
        parentByPath = parentByPath.filter { listed.contains($0.key) }
        let groups = CodexSessionsLocator.group(map) { parent(of: $0) }
        self.subagentsOf = groups

        // A session was last updated when it or any of its sub-agents was.
        return groups.compactMap { id, subagents -> AgentSessionRef? in
            guard let session = map[id] else { return nil }
            let updated = subagents.map(\.lastUpdatedAt).reduce(session.lastUpdatedAt, max)
            return AgentSessionRef(id: id, agentKind: .codexCLI, lastUpdatedAt: updated)
        }
        .sorted { $0.lastUpdatedAt > $1.lastUpdatedAt }
    }

    private func parent(of session: CodexSessionsLocator.DiscoveredSession) -> String? {
        let path = session.fileURL.path
        if let known = parentByPath[path] { return known.isEmpty ? nil : known }
        let found = CodexSessionsLocator.parentThreadId(ofRolloutAt: session.fileURL)
        if found.final { parentByPath[path] = found.id ?? "" }
        return found.id
    }

    // MARK: - Enrichment (Tier 2)

    public func loadSummary(id: String) async throws -> AgentSessionSummary {
        let session = try await resolveSession(id: id)
        let header = try readHeaderRecords(from: session.fileURL, maxLines: 200)
        let derived = deriveSummaryFields(from: header)
        let subagents = subagentsOf[id] ?? []
        // As its ref says: last updated when it or one of its sub-agents was.
        let updated = subagents.map(\.lastUpdatedAt).reduce(session.lastUpdatedAt, max)

        return AgentSessionSummary(
            id: id,
            agentKind: .codexCLI,
            projectPath: derived.cwd ?? "(unknown)",
            title: derived.title ?? id,
            aiTitle: nil,                       // Codex has no server-generated title
            startedAt: derived.startedAt ?? session.lastUpdatedAt,
            lastUpdatedAt: updated,
            messageCount: derived.messageCount,
            gitBranch: derived.gitBranch,
            subagentCount: subagents.count
        )
    }

    // MARK: - Full transcript

    public func loadTranscript(id: String, window request: TranscriptWindowRequest) async throws -> AgentTranscript {
        let session = try await resolveSession(id: id)
        // Parse off the actor's isolation domain: the builder mutates several
        // locals across the chunked-read closure and a nested `flushAssistant`,
        // which region-based isolation would otherwise flag as a data race
        // against the post-loop uses. A `nonisolated` helper keeps that state
        // purely local (and the heavy parse off the actor's critical section).
        return try parseTranscript(fileURL: session.fileURL, id: id, window: request)
    }

    public func loadTranscript(fileAt url: URL, window request: TranscriptWindowRequest) async throws -> AgentTranscript {
        try parseTranscript(fileURL: url, id: CodexSessionsLocator.transcriptStem(of: url.lastPathComponent), window: request)
    }

    private nonisolated func parseTranscript(fileURL: URL, id: String, window request: TranscriptWindowRequest) throws -> AgentTranscript {
        var turns: [AgentTurn] = []
        var cwd: String?
        var toolResultsByID: [String: ToolResult] = [:]

        // Consecutive assistant-side records (reasoning / message text / tool
        // calls) between two user prompts are grouped into one assistant turn,
        // mirroring Claude's block-bearing assistant records.
        var pendingBlocks: [AssistantBlock] = []
        var pendingTimestamp: Date?
        var pendingOffset: UInt64 = 0
        let window: TranscriptWindow

        // Codex records carry no ids of their own, so a turn is named by the
        // byte offset of its first record: the same id from wherever the file
        // is read, which windowed reads of long sessions rely on (S-004).
        func flushAssistant() {
            guard !pendingBlocks.isEmpty else { return }
            turns.append(.assistant(
                recordUUID: "a@\(pendingOffset)",
                blocks: pendingBlocks,
                timestamp: pendingTimestamp ?? Date()
            ))
            pendingBlocks = []
            pendingTimestamp = nil
        }

        do {
            window = try TranscriptWindow(request, fileAt: fileURL)
            // Buffered chunked read instead of byte-at-a-time `URL.lines`.
            try AgentTranscriptLineReader.forEachLine(in: fileURL, startingIn: window.start..<window.end) { data, offset in
                // Skip individual oversized lines rather than buffering them.
                let lineBytes = data.count
                if lineBytes > Self.maxLineBytes {
                    logger.warning("Skipping oversized transcript line (\(lineBytes, privacy: .public) bytes) in session \(id, privacy: .public)")
                    return
                }
                guard let record = CodexTranscriptParser.parseLine(data) else { return }

                switch record {
                case let .sessionMeta(recordCwd, _, _, _, _, _, _):
                    if cwd == nil, let recordCwd { cwd = recordCwd }

                case let .userMessage(text, timestamp):
                    flushAssistant()
                    turns.append(.user(recordUUID: "u@\(offset)", text: text, timestamp: timestamp))

                case let .assistantMessage(text, timestamp):
                    if pendingBlocks.isEmpty { pendingOffset = offset }
                    if pendingTimestamp == nil { pendingTimestamp = timestamp }
                    pendingBlocks.append(.text(text))

                case let .reasoning(text, timestamp):
                    if pendingBlocks.isEmpty { pendingOffset = offset }
                    if pendingTimestamp == nil { pendingTimestamp = timestamp }
                    pendingBlocks.append(.thinking(text))

                case let .toolCall(callId, name, input, timestamp):
                    if pendingBlocks.isEmpty { pendingOffset = offset }
                    if pendingTimestamp == nil { pendingTimestamp = timestamp }
                    pendingBlocks.append(.toolUse(id: callId, name: name, input: input))

                case let .toolOutput(callId, output, isError, _):
                    toolResultsByID[callId] = ToolResult(content: output, isError: isError)

                case .turnContext, .tokenCount, .toolRun:
                    return
                }
            }
        } catch {
            throw AgentSessionSourceError.transcriptUnreadable(id: id, underlying: error)
        }
        flushAssistant()

        return AgentTranscript(
            sessionId: id,
            agentKind: .codexCLI,
            projectPath: cwd ?? "(unknown)",
            turns: turns,
            toolResultsByID: toolResultsByID,
            window: window
        )
    }

    // MARK: - Watcher

    public func makeWatcher() async -> AgentSessionWatcher? {
        // No FSEvents off-macOS (the CLI lists on demand and needs no watcher).
        #if canImport(CoreServices)
        DirectoryFSWatcher(root: rootURL)
        #else
        nil
        #endif
    }

    // MARK: - Metrics indexing

    public func indexableFile(for id: String) async -> IndexableFile? {
        guard let session = try? await resolveSession(id: id) else { return nil }
        let url = session.fileURL
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let own = values?.contentModificationDate ?? session.lastUpdatedAt
        let size = Int64(values?.fileSize ?? 0)
        let subagents = subagentsOf[id] ?? []
        // The newest of the session and its sub-agents, as its ref says, so a
        // sub-agent's write re-reads the session.
        let mtime = subagents.map(\.lastUpdatedAt).reduce(own, max)
        return IndexableFile(url: url, mtime: mtime, fileSize: size, sidecarDir: nil,
                             subagents: Dictionary(subagents.map { ($0.sessionId, $0.fileURL) },
                                                   uniquingKeysWith: { a, _ in a }))
    }

    // MARK: - Internals

    private func resolveSession(id: String) async throws -> CodexSessionsLocator.DiscoveredSession {
        if let cached = byId[id] { return cached }
        _ = try await listSessionRefs()
        if let refreshed = byId[id] { return refreshed }
        throw AgentSessionSourceError.sessionNotFound(id: id)
    }

    /// Read up to `maxLines` lines from the head of the file — enough for the
    /// `session_meta` (line 1) and the first real user message (title). Token
    /// totals live at the tail and are left to the metrics indexer.
    nonisolated private func readHeaderRecords(from url: URL, maxLines: Int) throws -> [Data] {
        let chunk = try SessionFileStream(url: url).read(upToCount: 256 * 1024) ?? Data()
        guard !chunk.isEmpty else { return [] }

        var lines: [Data] = []
        lines.reserveCapacity(min(maxLines, 64))
        var start = chunk.startIndex
        let newline: UInt8 = 0x0A
        for i in chunk.indices {
            if chunk[i] == newline {
                if start < i { lines.append(chunk.subdata(in: start..<i)) }
                start = chunk.index(after: i)
                if lines.count >= maxLines { break }
            }
        }
        return lines
    }

    private struct SummaryFields {
        var firstUserText: String?
        var cwd: String?
        var gitBranch: String?
        var startedAt: Date?
        var messageCount: Int = 0
        var title: String? {
            guard let firstUserText else { return nil }
            let firstLine = firstUserText.split(whereSeparator: \.isNewline).first.map(String.init) ?? firstUserText
            return firstLine.count > 80 ? String(firstLine.prefix(80)) + "…" : firstLine
        }
    }

    nonisolated private func deriveSummaryFields(from lines: [Data]) -> SummaryFields {
        var fields = SummaryFields()
        for data in lines {
            guard let record = CodexTranscriptParser.parseLine(data) else { continue }
            switch record {
            case let .sessionMeta(cwd, _, _, _, _, gitBranch, timestamp):
                if fields.cwd == nil, let cwd { fields.cwd = cwd }
                if fields.gitBranch == nil, let gitBranch { fields.gitBranch = gitBranch }
                if fields.startedAt == nil { fields.startedAt = timestamp }
            case let .userMessage(text, timestamp):
                if fields.firstUserText == nil { fields.firstUserText = text }
                if fields.startedAt == nil { fields.startedAt = timestamp }
                fields.messageCount += 1
            case let .assistantMessage(_, timestamp):
                if fields.startedAt == nil { fields.startedAt = timestamp }
                fields.messageCount += 1
            case .reasoning, .toolCall, .toolOutput, .turnContext, .tokenCount, .toolRun:
                continue
            }
        }
        return fields
    }
}
