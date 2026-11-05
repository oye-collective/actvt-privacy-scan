//
//  AgentSessionSource.swift
//  Actvt
//

import Foundation

/// A provider that surfaces sessions from one agent CLI (Claude Code, Codex,
/// Cursor, …) as the generic `AgentSession*` types.
///
/// Implementations are typically actors so the `@MainActor` `AgentSessionStore`
/// can call them with `await`. The two-tier listing API mirrors the Claude
/// Agent SDK's `SessionStore` contract:
///
/// - `listSessionRefs()` — cheap: filesystem walk + stat only, no file opens.
///   Callable on the cold path of a session-list reload.
/// - `loadSummary(id:)` — per-session: reads a small slice of the transcript
///   (typically the first 5–20 lines, plus the tail where it matters) to
///   derive title / cwd / messageCount / wakesAt.
///   Called lazily for the visible window in the UI.
/// - `loadTranscript(id:window:)` — one window of the transcript (all of it
///   when the file fits one window), used by the detail view + PII scanner.
///
/// A single failing provider must not poison the registry; callers (the store)
/// catch and log per-provider errors rather than propagating.
public protocol AgentSessionSource: Sendable {
    var kind: AgentKind { get }

    /// Whether the provider's data directory exists. Allows the registry to
    /// quietly skip providers that aren't installed on this machine.
    var isAvailable: Bool { get async }

    /// Tier 1 listing — cheap directory walk + stat. No file content reads.
    func listSessionRefs() async throws -> [AgentSessionRef]

    /// Tier 2 enrichment — reads enough of the transcript to populate the
    /// summary. Implementations should read the head, plus a bounded tail for
    /// state that only the end records (Claude's scheduled wake-up); full
    /// transcripts belong in `loadTranscript`.
    func loadSummary(id: String) async throws -> AgentSessionSummary

    /// Transcript load: the records in `window` (`TranscriptWindow`), so memory
    /// stays bounded however long the session runs. Implementations should
    /// stream-parse and tolerate malformed records (skip + log) rather than
    /// throwing mid-file.
    func loadTranscript(id: String, window: TranscriptWindowRequest) async throws -> AgentTranscript

    /// The subagents a session spawned, each with a transcript of its own.
    /// Empty — the default — for agents that don't write them.
    func listSubagents(of id: String) async throws -> [AgentSubagentRef]

    /// One window of a subagent's transcript, read like a session's.
    func loadTranscript(of subagent: AgentSubagentRef, window: TranscriptWindowRequest) async throws -> AgentTranscript

    /// Optional change-notification primitive. Returning `nil` is fine — the
    /// store falls back to on-focus refresh.
    func makeWatcher() async -> AgentSessionWatcher?

    /// Resolve a session id to its on-disk transcript + stat, for the metrics
    /// indexer. Returning `nil` means "not indexable" — the default. Providers
    /// that own real files override this.
    func indexableFile(for id: String) async -> IndexableFile?
}

public extension AgentSessionSource {
    func indexableFile(for id: String) async -> IndexableFile? { nil }

    func listSubagents(of id: String) async throws -> [AgentSubagentRef] { [] }

    /// Never reached for a provider that lists no subagents.
    func loadTranscript(of subagent: AgentSubagentRef, window: TranscriptWindowRequest) async throws -> AgentTranscript {
        throw AgentSessionSourceError.sessionNotFound(id: subagent.agentId)
    }

    /// The newest window: what a session opens on.
    func loadTranscript(id: String) async throws -> AgentTranscript {
        try await loadTranscript(id: id, window: .latest)
    }
}

/// A subagent a session spawned (Claude Code's `<session>/subagents/agent-<id>.jsonl`).
public struct AgentSubagentRef: Sendable, Hashable {
    public let sessionId: String
    public let agentId: String
    /// The kind of subagent (`general-purpose`, `Explore`, …) and the task it
    /// was given, when the agent recorded them.
    public let agentType: String?
    public let description: String?

    public init(sessionId: String, agentId: String, agentType: String?, description: String?) {
        self.sessionId = sessionId
        self.agentId = agentId
        self.agentType = agentType
        self.description = description
    }
}

/// A resolved on-disk transcript plus the stat used as the metrics index's
/// invalidation key. Produced by a provider so the indexer can locate and
/// fingerprint a session's file(s) without duplicating provider path logic.
/// `sidecarDir` is the per-session directory holding `subagents/` etc. (Claude
/// Code), or `nil` for providers without sidecars. `subagents` are the session's
/// sub-agent transcripts that live outside it, as their own files (Codex: a
/// rollout that names this session as its parent), keyed by the session id each
/// would have had; they are part of this session, and `mtime` is the newest of
/// them all.
public struct IndexableFile: Sendable, Hashable {
    public let url: URL
    public let mtime: Date
    public let fileSize: Int64
    public let sidecarDir: URL?
    public let subagents: [String: URL]

    public init(url: URL, mtime: Date, fileSize: Int64, sidecarDir: URL?, subagents: [String: URL] = [:]) {
        self.url = url
        self.mtime = mtime
        self.fileSize = fileSize
        self.sidecarDir = sidecarDir
        self.subagents = subagents
    }
}

/// Coalesced change notification for a provider's data directory.
///
/// Implementations own a `DispatchSource.makeFileSystemObjectSource` or an
/// `FSEventStream` and are responsible for debouncing rapid bursts (a
/// 200 ms window is typical) before invoking `onChange`.
///
/// `Sendable` so it can be held by both the actor provider and the
/// `@MainActor` store; `AnyObject` because callers expect identity semantics
/// (one watcher per provider, started once).
public protocol AgentSessionWatcher: AnyObject, Sendable {
    /// Begin watching. Safe to call multiple times — subsequent calls replace
    /// the callback rather than starting additional sources.
    func start(onChange: @Sendable @escaping () -> Void) async

    /// Stop watching and release any held filesystem handles.
    func stop() async
}

/// Errors surfaced by providers. Kept narrow so the store can render
/// per-provider failure states without leaking provider internals.
public enum AgentSessionSourceError: Error, LocalizedError {
    case sessionNotFound(id: String)
    case transcriptUnreadable(id: String, underlying: Error)
    case providerUnavailable

    public var errorDescription: String? {
        switch self {
        case .sessionNotFound(let id):
            return "Session \(id) was not found."
        case .transcriptUnreadable(let id, let underlying):
            return "Could not read transcript \(id): \(underlying.localizedDescription)"
        case .providerUnavailable:
            return "Agent provider is not installed on this machine."
        }
    }
}
