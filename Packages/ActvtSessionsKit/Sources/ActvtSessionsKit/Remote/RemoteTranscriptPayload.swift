//
//  RemoteTranscriptPayload.swift
//  ActvtSessionsKit
//

import Foundation

/// Versioned wire format emitted by `actvt-cli transcript --json` and decoded
/// by the app's remote-transcript fetcher. Versioned independently of the
/// sessions payload: a CLI too old to answer `transcript` still lists sessions
/// fine, and the app's "CLI update available" nudge covers the gap.
///
/// `AgentTranscript` itself is deliberately not Codable — this DTO layer keeps
/// the internal model free to evolve while old CLIs on remote boxes keep
/// producing decodable payloads (unknown roles/block types are skipped by the
/// mapper, never a decode failure).
public struct RemoteTranscriptPayload: Codable, Sendable, Equatable {
    /// Bump on breaking wire changes; the app can then nudge "CLI outdated".
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let cliVersion: String
    public let hostname: String
    public let generatedAt: Date
    public let transcript: RemoteTranscript

    public init(
        schemaVersion: Int = RemoteTranscriptPayload.currentSchemaVersion,
        cliVersion: String,
        hostname: String,
        generatedAt: Date,
        transcript: RemoteTranscript
    ) {
        self.schemaVersion = schemaVersion
        self.cliVersion = cliVersion
        self.hostname = hostname
        self.generatedAt = generatedAt
        self.transcript = transcript
    }
}

/// Wire shape of one full transcript. The transcript rides raw (unmasked) —
/// PII masking is a display-time transform on the Mac, where the ML detector
/// lives; the SSH hop is already the user's own key-authenticated channel.
public struct RemoteTranscript: Codable, Sendable, Equatable {
    public let sessionId: String
    /// `AgentKind.rawValue`, raw String for forward compat like `RemoteAgentSession`.
    public let agentKind: String
    public let projectPath: String
    public let turns: [RemoteTranscriptTurn]
    public let toolResults: [String: RemoteToolResult]
    /// Absent from CLIs before 0.6.1, which read as "loaded nothing".
    public let memorySources: [RemoteMemorySource]?
    /// The bytes of the session file the turns came from. Absent from CLIs
    /// that read a session from its start, which read as "not a window".
    public let window: RemoteTranscriptWindow?

    public init(
        sessionId: String, agentKind: String, projectPath: String,
        turns: [RemoteTranscriptTurn], toolResults: [String: RemoteToolResult],
        memorySources: [RemoteMemorySource]? = nil,
        window: RemoteTranscriptWindow? = nil
    ) {
        self.sessionId = sessionId
        self.agentKind = agentKind
        self.projectPath = projectPath
        self.turns = turns
        self.toolResults = toolResults
        self.memorySources = memorySources
        self.window = window
    }

    /// CLI-side mapper: internal model → wire.
    public init(_ transcript: AgentTranscript) {
        self.init(
            sessionId: transcript.sessionId,
            agentKind: transcript.agentKind.rawValue,
            projectPath: transcript.projectPath,
            turns: transcript.turns.map(RemoteTranscriptTurn.init),
            toolResults: transcript.toolResultsByID.mapValues {
                RemoteToolResult(content: $0.content, isError: $0.isError)
            },
            memorySources: transcript.memorySources.map(RemoteMemorySource.init),
            window: transcript.window.map {
                RemoteTranscriptWindow(start: $0.start, end: $0.end, fileSize: $0.fileSize)
            }
        )
    }

    /// App-side mapper: wire → internal model. `nil` when the agent kind is
    /// unknown to this app (newer remote provider). Turns/blocks with unknown
    /// roles/types are skipped — a newer CLI's extra content degrades to an
    /// incomplete transcript, never a failure.
    public func agentTranscript() -> AgentTranscript? {
        guard let kind = AgentKind(rawValue: agentKind) else { return nil }
        return AgentTranscript(
            sessionId: sessionId,
            agentKind: kind,
            projectPath: projectPath,
            turns: turns.compactMap { $0.agentTurn() },
            toolResultsByID: toolResults.mapValues {
                ToolResult(content: $0.content, isError: $0.isError)
            },
            memorySources: (memorySources ?? []).map { $0.memorySource() },
            window: window.map { TranscriptWindow(start: $0.start, end: $0.end, fileSize: $0.fileSize) }
        )
    }
}

/// `TranscriptWindow` on the wire.
public struct RemoteTranscriptWindow: Codable, Sendable, Equatable {
    public let start: UInt64
    public let end: UInt64
    public let fileSize: UInt64

    public init(start: UInt64, end: UInt64, fileSize: UInt64) {
        self.start = start
        self.end = end
        self.fileSize = fileSize
    }
}

/// One turn on the wire. Exactly one of `text` (user/system) or `blocks`
/// (assistant) is populated per role.
public struct RemoteTranscriptTurn: Codable, Sendable, Equatable {
    public let role: String
    public let recordUUID: String
    public let timestamp: Date
    public let text: String?
    public let blocks: [RemoteAssistantBlock]?

    public init(role: String, recordUUID: String, timestamp: Date,
                text: String?, blocks: [RemoteAssistantBlock]?) {
        self.role = role
        self.recordUUID = recordUUID
        self.timestamp = timestamp
        self.text = text
        self.blocks = blocks
    }

    public init(_ turn: AgentTurn) {
        switch turn {
        case .user(let uuid, let text, let timestamp):
            self.init(role: "user", recordUUID: uuid, timestamp: timestamp,
                      text: text, blocks: nil)
        case .assistant(let uuid, let blocks, let timestamp):
            self.init(role: "assistant", recordUUID: uuid, timestamp: timestamp,
                      text: nil, blocks: blocks.map(RemoteAssistantBlock.init))
        case .systemNotification(let uuid, let text, let timestamp):
            self.init(role: "system", recordUUID: uuid, timestamp: timestamp,
                      text: text, blocks: nil)
        }
    }

    /// `nil` for roles this app doesn't know (skipped by the mapper).
    public func agentTurn() -> AgentTurn? {
        switch role {
        case "user":
            return .user(recordUUID: recordUUID, text: text ?? "", timestamp: timestamp)
        case "assistant":
            return .assistant(
                recordUUID: recordUUID,
                blocks: (blocks ?? []).compactMap { $0.assistantBlock() },
                timestamp: timestamp
            )
        case "system":
            return .systemNotification(recordUUID: recordUUID, text: text ?? "", timestamp: timestamp)
        default:
            return nil
        }
    }
}

/// One assistant content block on the wire.
public struct RemoteAssistantBlock: Codable, Sendable, Equatable {
    public let type: String
    public let text: String?
    public let id: String?
    public let name: String?
    public let input: String?

    public init(type: String, text: String? = nil,
                id: String? = nil, name: String? = nil, input: String? = nil) {
        self.type = type
        self.text = text
        self.id = id
        self.name = name
        self.input = input
    }

    public init(_ block: AssistantBlock) {
        switch block {
        case .text(let text):
            self.init(type: "text", text: text)
        case .thinking(let text):
            self.init(type: "thinking", text: text)
        case .toolUse(let id, let name, let input):
            self.init(type: "toolUse", id: id, name: name, input: input)
        }
    }

    /// `nil` for block types this app doesn't know (skipped by the mapper).
    public func assistantBlock() -> AssistantBlock? {
        switch type {
        case "text": return .text(text ?? "")
        case "thinking": return .thinking(text ?? "")
        case "toolUse": return .toolUse(id: id ?? "", name: name ?? "", input: input ?? "")
        default: return nil
        }
    }
}

/// One loaded memory source on the wire. `kind` is a raw string, so a kind
/// a newer CLI knows and this app doesn't reads as `.other`.
public struct RemoteMemorySource: Codable, Sendable, Equatable {
    public let path: String
    public let kind: String
    public let loadedAt: Date
    public let byteCount: Int
    public let entries: [Entry]?

    public struct Entry: Codable, Sendable, Equatable {
        public let title: String
        public let file: String
        public let hook: String?
        public let listedAt: Date
    }

    public init(_ source: MemorySource) {
        path = source.path
        kind = source.kind.rawValue
        loadedAt = source.loadedAt
        byteCount = source.byteCount
        entries = source.entries.isEmpty ? nil
            : source.entries.map { Entry(title: $0.title, file: $0.file, hook: $0.hook, listedAt: $0.listedAt) }
    }

    public func memorySource() -> MemorySource {
        MemorySource(
            path: path, kind: MemorySource.Kind(rawValue: kind) ?? .other,
            loadedAt: loadedAt, byteCount: byteCount,
            entries: (entries ?? []).map { .init(title: $0.title, file: $0.file, hook: $0.hook, listedAt: $0.listedAt) })
    }
}

public struct RemoteToolResult: Codable, Sendable, Equatable {
    public let content: String
    public let isError: Bool

    public init(content: String, isError: Bool) {
        self.content = content
        self.isError = isError
    }
}

public extension RemoteAgentSession {
    /// This remote row's fields as an `AgentSessionSummary`, so the detail
    /// view's header renders a remote session exactly like a local one.
    /// `nil` when the agent kind is unknown to this app.
    var sessionSummary: AgentSessionSummary? {
        guard let kind else { return nil }
        return AgentSessionSummary(
            id: id,
            agentKind: kind,
            projectPath: projectPath,
            title: title,
            aiTitle: aiTitle,
            startedAt: startedAt,
            lastUpdatedAt: lastUpdatedAt,
            messageCount: messageCount,
            gitBranch: gitBranch,
            subagentCount: subagentCount
        )
    }
}
