//
//  PiSessionSource.swift
//  ActvtSessionParsers
//

import Foundation
#if canImport(os)
import os.log
#endif

/// `AgentSessionSource` for the pi coding agent.
///
/// Mirrors `CodexSessionSource`: a `[sessionId: DiscoveredSession]` cache
/// rebuilt on every `listSessionRefs()` (stat-only walk), header-window
/// summaries, and a streamed transcript build. pi has no sidecar directory,
/// so `indexableFile` returns `sidecarDir: nil`. A session's sub-agents
/// (pi-subagents, under the session's own directory) are listed as part of it,
/// never as sessions of their own, and handed to the indexer in
/// `IndexableFile.subagents` (T-042).
///
/// One thing is pi-specific: a session file is a tree (see
/// `PiTranscriptParser.activePath`), so the transcript is built from the
/// active path only. Entries on abandoned branches stay invisible here; the
/// metrics extractor in the app counts them, because their tokens were spent.
public actor PiSessionSource: AgentSessionSource {
    public nonisolated let kind: AgentKind = .pi
    private nonisolated let logger = Logger(subsystem: "com.actvt.io", category: "PiSessionSource")

    private let rootURL: URL
    private var byId: [String: PiSessionsLocator.DiscoveredSession] = [:]

    /// pi tool results can embed screenshots as base64; the parser drops the
    /// bytes, but the raw line still has to be read, so a line past this is
    /// skipped. A whole transcript is bounded by its window
    /// (`TranscriptWindow.budget`).
    private static let maxLineBytes = 8 * 1024 * 1024          // 8 MB per line

    /// Lines read for the summary tier. The header, model change and first
    /// user prompt are always within the first handful; a `session_info`
    /// rename appended later than this is not seen by the summary.
    private static let summaryHeaderLines = 200

    public init(rootURL: URL = PiSessionsLocator.defaultSessionsURL) {
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
        let discovered: [PiSessionsLocator.DiscoveredSession]
        do {
            discovered = try PiSessionsLocator.discoverSessions(at: rootURL)
        } catch {
            logger.warning("Failed to enumerate \(self.rootURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
        var map: [String: PiSessionsLocator.DiscoveredSession] = [:]
        map.reserveCapacity(discovered.count)
        for entry in discovered { map[entry.sessionId] = entry }
        self.byId = map

        return map.values
            .sorted { $0.lastUpdatedAt > $1.lastUpdatedAt }
            .map { AgentSessionRef(id: $0.sessionId, agentKind: .pi, lastUpdatedAt: $0.lastUpdatedAt) }
    }

    // MARK: - Enrichment (Tier 2)

    public func loadSummary(id: String) async throws -> AgentSessionSummary {
        let session = try await resolveSession(id: id)
        let lines = try readHeaderLines(from: session.fileURL, maxLines: Self.summaryHeaderLines)
        let fields = deriveSummaryFields(from: lines)

        return AgentSessionSummary(
            id: id,
            agentKind: .pi,
            projectPath: fields.cwd ?? "(unknown)",
            title: fields.title ?? id,
            aiTitle: nil,                       // pi has no server-generated title
            startedAt: fields.startedAt ?? session.startedAt,
            lastUpdatedAt: session.lastUpdatedAt,
            messageCount: fields.messageCount,
            gitBranch: nil,                     // not recorded by pi
            subagentCount: session.subagents.count
        )
    }

    // MARK: - Full transcript

    public func loadTranscript(id: String, window request: TranscriptWindowRequest) async throws -> AgentTranscript {
        let session = try await resolveSession(id: id)
        return try parseTranscript(fileURL: session.fileURL, id: id, window: request)
    }

    public func loadTranscript(fileAt url: URL, window request: TranscriptWindowRequest) async throws -> AgentTranscript {
        try parseTranscript(fileURL: url, id: url.deletingPathExtension().lastPathComponent, window: request)
    }

    /// The active branch is walked back from the file's last entry, which may
    /// lie past the window, so every line is read for its id and parent; only
    /// the entries inside the window are kept whole.
    private nonisolated func parseTranscript(fileURL: URL, id: String, window request: TranscriptWindowRequest) throws -> AgentTranscript {
        var header: PiTranscriptParser.Header?
        var entries: [PiTranscriptParser.Entry] = []
        var parents: [String: String] = [:]
        var leaf: String?
        let window: TranscriptWindow

        do {
            window = try TranscriptWindow(request, fileAt: fileURL)
            try AgentTranscriptLineReader.forEachLine(in: fileURL, startingIn: 0..<UInt64.max) { data, offset in
                let lineBytes = data.count
                if lineBytes > Self.maxLineBytes {
                    logger.warning("Skipping oversized transcript line (\(lineBytes, privacy: .public) bytes) in session \(id, privacy: .public)")
                    return
                }
                switch PiTranscriptParser.parseLine(data) {
                case .header(let h): if header == nil { header = h }
                case .entry(let e):
                    parents[e.id] = e.parentId ?? ""
                    leaf = e.id
                    if offset >= window.start, offset < window.end { entries.append(e) }
                case nil: return
                }
            }
        } catch {
            throw AgentSessionSourceError.transcriptUnreadable(id: id, underlying: error)
        }

        var turns: [AgentTurn] = []
        var toolResultsByID: [String: ToolResult] = [:]
        let onPath = PiTranscriptParser.activeIDs(leaf: leaf, parents: parents)
        for entry in entries where onPath.contains(entry.id) {
            Self.append(entry, to: &turns, toolResults: &toolResultsByID)
        }

        return AgentTranscript(
            sessionId: id,
            agentKind: .pi,
            projectPath: header?.cwd ?? "(unknown)",
            turns: turns,
            toolResultsByID: toolResultsByID,
            window: window
        )
    }

    /// Map one active-path entry onto the provider-agnostic turn shape. Entries
    /// that carry nothing a reader needs (thinking level, labels, extension
    /// state, hidden custom messages) produce no turn.
    private nonisolated static func append(
        _ entry: PiTranscriptParser.Entry,
        to turns: inout [AgentTurn],
        toolResults: inout [String: ToolResult]
    ) {
        let id = entry.id
        let at = entry.timestamp
        switch entry.kind {
        case .message(let message):
            switch message {
            case .user(let text):
                turns.append(.user(recordUUID: id, text: text, timestamp: at))

            case .assistant(let assistant):
                var blocks: [AssistantBlock] = assistant.blocks.map { block in
                    switch block {
                    case .text(let s): return .text(s)
                    case .thinking(let s): return .thinking(s)
                    case let .toolCall(callId, name, arguments, _): return .toolUse(id: callId, name: name, input: arguments)
                    }
                }
                // A failed response is a turn the user saw fail; keep the reason
                // in the turn rather than dropping an empty assistant record.
                if assistant.stopReason == "error", let message = assistant.errorMessage, !message.isEmpty {
                    blocks.append(.text(message))
                }
                turns.append(.assistant(recordUUID: id, blocks: blocks, timestamp: at))

            case let .toolResult(toolCallId, _, text, isError):
                toolResults[toolCallId] = ToolResult(content: text, isError: isError)

            case let .bashExecution(command, output, _):
                turns.append(.user(recordUUID: id, text: "! \(command)", timestamp: at))
                if !output.isEmpty {
                    turns.append(.systemNotification(recordUUID: id + ":out", text: output, timestamp: at))
                }

            case let .custom(text, display):
                if display, !text.isEmpty {
                    turns.append(.systemNotification(recordUUID: id, text: text, timestamp: at))
                }

            case .other:
                return
            }

        case let .modelChange(provider, modelId):
            turns.append(.systemNotification(recordUUID: id, text: "Model: \(provider)/\(modelId)", timestamp: at))

        case let .compaction(_, tokensBefore, _):
            turns.append(.systemNotification(
                recordUUID: id,
                text: "Context compacted: \(tokensBefore) tokens summarized.",
                timestamp: at
            ))

        case .branchSummary:
            turns.append(.systemNotification(recordUUID: id, text: "Returned from a branch.", timestamp: at))

        case let .customMessage(text, display):
            if display, !text.isEmpty {
                turns.append(.systemNotification(recordUUID: id, text: text, timestamp: at))
            }

        case .thinkingLevelChange, .sessionInfo, .other:
            return
        }
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
        let mtime = values?.contentModificationDate ?? session.lastUpdatedAt
        let size = Int64(values?.fileSize ?? 0)
        // A sub-agent's file changing changes the session, so the newest wins.
        return IndexableFile(url: url, mtime: max(mtime, session.lastUpdatedAt), fileSize: size,
                             sidecarDir: nil, subagents: session.subagents)
    }

    // MARK: - Internals

    private func resolveSession(id: String) async throws -> PiSessionsLocator.DiscoveredSession {
        if let cached = byId[id] { return cached }
        _ = try await listSessionRefs()
        if let refreshed = byId[id] { return refreshed }
        throw AgentSessionSourceError.sessionNotFound(id: id)
    }

    /// Up to `maxLines` lines from the head of the file, read in one bounded
    /// chunk. Enough for the header (line 1) and the first user prompt.
    nonisolated private func readHeaderLines(from url: URL, maxLines: Int) throws -> [Data] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let chunk = try handle.read(upToCount: 256 * 1024) ?? Data()
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
        var cwd: String?
        var startedAt: Date?
        var sessionName: String?
        var firstUserText: String?
        var messageCount = 0

        /// A user-set name wins; otherwise the first line of the first prompt.
        var title: String? {
            if let sessionName, !sessionName.isEmpty { return sessionName }
            guard let firstUserText else { return nil }
            let firstLine = firstUserText.split(whereSeparator: \.isNewline).first.map(String.init) ?? firstUserText
            return firstLine.count > 80 ? String(firstLine.prefix(80)) + "..." : firstLine
        }
    }

    nonisolated private func deriveSummaryFields(from lines: [Data]) -> SummaryFields {
        var fields = SummaryFields()
        for data in lines {
            switch PiTranscriptParser.parseLine(data) {
            case .header(let header):
                if fields.cwd == nil { fields.cwd = header.cwd }
                if fields.startedAt == nil { fields.startedAt = header.timestamp }
            case .entry(let entry):
                switch entry.kind {
                case .message(.user(let text)):
                    if fields.firstUserText == nil, !text.isEmpty { fields.firstUserText = text }
                    fields.messageCount += 1
                case .message(.assistant):
                    fields.messageCount += 1
                case .sessionInfo(let name):
                    fields.sessionName = name   // latest wins; nil clears
                default:
                    continue
                }
            case nil:
                continue
            }
        }
        return fields
    }
}
