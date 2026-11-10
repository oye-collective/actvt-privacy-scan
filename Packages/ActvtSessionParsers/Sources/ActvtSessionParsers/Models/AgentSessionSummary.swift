//
//  AgentSessionSummary.swift
//  ActvtSessionParsers
//

import Foundation

/// Cheap, listing-tier identifier returned by `AgentSessionSource.listSessionRefs()`.
///
/// Derived from filesystem walk + stat only (no file content reads). Sorting and
/// dedup happens at this tier — actual transcript metadata (title, cwd,
/// messageCount) is enriched on demand via `AgentSessionSource.loadSummary(id:)`.
///
/// The composite `(agentKind, id)` is unique across providers; raw `id` is only
/// unique within a provider.
public struct AgentSessionRef: Identifiable, Sendable, Hashable {
    public let id: String
    public let agentKind: AgentKind
    public let lastUpdatedAt: Date

    public init(id: String, agentKind: AgentKind, lastUpdatedAt: Date) {
        self.id = id
        self.agentKind = agentKind
        self.lastUpdatedAt = lastUpdatedAt
    }

    /// Stable identity across providers.
    public var compositeKey: String { "\(agentKind.rawValue):\(id)" }
}

/// Enriched per-session metadata used by the session list UI.
///
/// Built from a small set of header records inside the JSONL — most fields come
/// from the first 5–20 lines. `title` derivation order:
///   1. Latest `ai-title` record (`aiTitle` field) — server-generated, preferred
///   2. First non-CLI-echo user message text, truncated
///   3. Session id (filename) as last resort
///
/// A user-set title, when one exists, takes precedence over all three. Providers
/// never see it: the app's session store applies it on read via `renamed(to:)`,
/// so `aiTitle` always keeps the server-generated value.
public struct AgentSessionSummary: Identifiable, Sendable, Hashable {
    public let id: String
    public let agentKind: AgentKind

    /// Project working directory, read from the transcript itself (`cwd` field
    /// on user records) rather than the encoded directory name. More robust
    /// because Claude's `<encoded-cwd>` scheme uses an opaque substitution
    /// that can collide on dashes vs slashes.
    public let projectPath: String

    /// Display title for the row. See type doc for derivation order.
    public let title: String

    /// Server-generated title (`ai-title` record) when present. Distinct from
    /// `title` so the UI can show it preferentially if `highlightAiTitles` UX
    /// is added later.
    public let aiTitle: String?

    /// Timestamp of the first record in the transcript.
    public let startedAt: Date

    /// File modification time — used for "last updated" sort + change detection.
    public let lastUpdatedAt: Date

    /// Number of visible turns (user + assistant). Sidechain / echo / system
    /// records do NOT count toward this.
    public let messageCount: Int

    /// Git branch captured on user records (if present).
    public let gitBranch: String?

    /// Number of subagent transcripts found in the session's sidecar directory.
    /// Cheap to compute via globbing `<sessionId>/subagents/*.meta.json`.
    public let subagentCount: Int

    /// When the agent scheduled itself to resume, if its last act was to put
    /// itself to sleep (a loop agent's `ScheduleWakeup`). Until then its
    /// silence is a pause it announced, not a stop. Nil for every provider
    /// without such a tool, and for a session whose last schedule was a stop.
    public let wakesAt: Date?

    public init(
        id: String,
        agentKind: AgentKind,
        projectPath: String,
        title: String,
        aiTitle: String?,
        startedAt: Date,
        lastUpdatedAt: Date,
        messageCount: Int,
        gitBranch: String?,
        subagentCount: Int,
        wakesAt: Date? = nil
    ) {
        self.id = id
        self.agentKind = agentKind
        self.projectPath = projectPath
        self.title = title
        self.aiTitle = aiTitle
        self.startedAt = startedAt
        self.lastUpdatedAt = lastUpdatedAt
        self.messageCount = messageCount
        self.gitBranch = gitBranch
        self.subagentCount = subagentCount
        self.wakesAt = wakesAt
    }

    public var compositeKey: String { "\(agentKind.rawValue):\(id)" }

    /// A copy with only `title` replaced. `aiTitle` and every other field are
    /// kept, so the server-generated title stays inspectable after a rename.
    public func renamed(to title: String) -> AgentSessionSummary {
        AgentSessionSummary(
            id: id,
            agentKind: agentKind,
            projectPath: projectPath,
            title: title,
            aiTitle: aiTitle,
            startedAt: startedAt,
            lastUpdatedAt: lastUpdatedAt,
            messageCount: messageCount,
            gitBranch: gitBranch,
            subagentCount: subagentCount,
            wakesAt: wakesAt
        )
    }
}
