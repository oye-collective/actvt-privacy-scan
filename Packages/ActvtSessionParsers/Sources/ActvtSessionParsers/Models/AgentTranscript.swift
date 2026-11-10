//
//  AgentTranscript.swift
//  ActvtSessionParsers
//

import Foundation

/// Full session transcript materialized into the provider-agnostic shape.
///
/// PII detection + UI rendering only ever see this shape — provider-specific
/// JSONL parsing stays inside each `AgentSessionSource`.
public struct AgentTranscript: Sendable, Hashable {
    public let sessionId: String
    public let agentKind: AgentKind
    public let projectPath: String
    public let turns: [AgentTurn]
    /// Tool results keyed by `tool_use_id`, gathered across all user envelopes.
    /// A tool_use announced on one assistant turn can have its matching
    /// result arrive on a later user envelope — keeping a flat map avoids
    /// per-render searches in the UI.
    public let toolResultsByID: [String: ToolResult]
    /// Instruction files and memory indexes the agent loaded, in load order,
    /// each path once. Empty for agents that don't record them.
    public let memorySources: [MemorySource]
    /// The bytes of the session file these turns were read from. nil when the
    /// transcript is not a window onto a file (a remote host whose CLI predates
    /// windows).
    public let window: TranscriptWindow?

    public init(
        sessionId: String,
        agentKind: AgentKind,
        projectPath: String,
        turns: [AgentTurn],
        toolResultsByID: [String: ToolResult],
        memorySources: [MemorySource] = [],
        window: TranscriptWindow? = nil
    ) {
        self.sessionId = sessionId
        self.agentKind = agentKind
        self.projectPath = projectPath
        self.turns = turns
        self.toolResultsByID = toolResultsByID
        self.memorySources = memorySources
        self.window = window
    }

    /// Adjacent windows of one session, oldest first, as one transcript. A
    /// record read twice (a turn id seen in an earlier window) appears once.
    public static func joining(_ windows: [AgentTranscript]) -> AgentTranscript? {
        guard let first = windows.first, let last = windows.last else { return nil }
        var seen: Set<String> = []
        var turns: [AgentTurn] = []
        var toolResults: [String: ToolResult] = [:]
        var memorySources: [MemorySource] = []
        for window in windows {
            for turn in window.turns where seen.insert(turn.recordUUID).inserted {
                turns.append(turn)
            }
            toolResults.merge(window.toolResultsByID) { _, later in later }
            for source in window.memorySources {
                if let index = memorySources.firstIndex(where: { $0.path == source.path }) {
                    memorySources[index].absorb(source)
                } else {
                    memorySources.append(source)
                }
            }
        }
        var range: TranscriptWindow?
        if let start = first.window, let end = last.window {
            range = TranscriptWindow(start: start.start, end: end.end, fileSize: end.fileSize)
        }
        return AgentTranscript(
            sessionId: first.sessionId,
            agentKind: first.agentKind,
            projectPath: first.projectPath,
            turns: turns,
            toolResultsByID: toolResults,
            memorySources: memorySources,
            window: range
        )
    }
}

/// A byte range of a session file. A long session is read a window at a time
/// (S-004): each holds the records whose first byte lies in `start..<end`, so
/// the window before it is `.before(start)` and they join with no gap and no
/// record read twice.
public struct TranscriptWindow: Sendable, Hashable {
    public let start: UInt64
    public let end: UInt64
    /// The file's size when the window was read.
    public let fileSize: UInt64

    /// The most a window reads. Two of them are the 50 MB a transcript on
    /// screen was always held to.
    public static let budget: UInt64 = 25 * 1024 * 1024

    public init(start: UInt64, end: UInt64, fileSize: UInt64) {
        self.start = start
        self.end = end
        self.fileSize = fileSize
    }

    public var hasEarlier: Bool { start > 0 }
    public var hasLater: Bool { end < fileSize }

    /// The window `request` names in the file at `url`, as it is now.
    public init(_ request: TranscriptWindowRequest, fileAt url: URL) throws {
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        self.init(request, fileSize: size?.uint64Value ?? 0)
    }

    /// The window `request` names in a file of `fileSize` bytes.
    public init(_ request: TranscriptWindowRequest, fileSize: UInt64) {
        let budget = Self.budget
        switch request {
        case .latest:
            self.init(start: fileSize > budget ? fileSize - budget : 0, end: fileSize, fileSize: fileSize)
        case .first:
            self.init(start: 0, end: min(fileSize, budget), fileSize: fileSize)
        case .before(let cursor):
            let end = min(cursor, fileSize)
            self.init(start: end > budget ? end - budget : 0, end: end, fileSize: fileSize)
        case .after(let cursor):
            let start = min(cursor, fileSize)
            self.init(start: start, end: min(fileSize, start + budget), fileSize: fileSize)
        }
    }
}

/// Which window of a session to read.
public enum TranscriptWindowRequest: Sendable, Hashable {
    /// The newest bytes: what a session opens on.
    case latest
    /// The oldest bytes: where a session starts.
    case first
    /// The window that ends where an earlier read started.
    case before(UInt64)
    /// The window that starts where an earlier read ended.
    case after(UInt64)
}

/// The content of a tool_result, normalized for display + PII scanning.
public struct ToolResult: Sendable, Hashable {
    public let content: String
    public let isError: Bool

    public init(content: String, isError: Bool) {
        self.content = content
        self.isError = isError
    }
}

/// A single turn in a transcript.
///
/// `recordUUID` is the provider-side record identifier (Claude calls it `uuid`).
/// Kept on the turn so the watcher can diff-load (append-only transcripts mean
/// "new turns since the last seen uuid" is the natural refresh primitive).
public enum AgentTurn: Sendable, Hashable {
    case user(recordUUID: String, text: String, timestamp: Date)
    case assistant(recordUUID: String, blocks: [AssistantBlock], timestamp: Date)
    case systemNotification(recordUUID: String, text: String, timestamp: Date)

    public var recordUUID: String {
        switch self {
        case .user(let u, _, _),
             .assistant(let u, _, _),
             .systemNotification(let u, _, _):
            return u
        }
    }

    public var timestamp: Date {
        switch self {
        case .user(_, _, let t),
             .assistant(_, _, let t),
             .systemNotification(_, _, let t):
            return t
        }
    }

    /// True for turns whose text content should be subject to PII scanning.
    /// System notifications are skipped (they're scaffolding, not user data).
    public var participatesInPIIScan: Bool {
        switch self {
        case .user, .assistant: return true
        case .systemNotification: return false
        }
    }
}

/// Content inside an assistant turn. Mirrors Claude's block-level discriminated
/// union but generic enough to extend to other agents.
public enum AssistantBlock: Sendable, Hashable {
    case text(String)
    case thinking(String)
    case toolUse(id: String, name: String, input: String)
}
