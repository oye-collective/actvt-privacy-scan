//
//  RemoteSessionPayload.swift
//  ActvtSessionsKit
//

import Foundation

/// Versioned wire format emitted by `actvt-cli sessions --json` and decoded by
/// the app's remote-sessions fetcher. A dedicated DTO (rather than making the
/// internal models Codable) keeps the app free to evolve its types while old
/// CLIs on remote boxes keep working: `agentKind` stays a raw `String`, and
/// unknown fields on either side are ignored by Codable.
public struct RemoteSessionPayload: Codable, Sendable, Equatable {
    /// Bump on breaking wire changes; the app can then nudge "CLI outdated".
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let cliVersion: String
    /// Informational only — the app labels hosts by how IT reached them.
    public let hostname: String
    /// Stamped at emit time so the app can correct clock skew: liveness math
    /// uses `receivedAt − generatedAt` as the offset (subsumes fetch latency).
    public let generatedAt: Date
    public let sessions: [RemoteAgentSession]
    /// Messages agents on this host left for the user since the app last
    /// acknowledged. Empty from any CLI older than 0.3.0, which is why it
    /// decodes as absent rather than failing the whole payload.
    public let pendingNotifications: [RemoteAgentNotification]
    /// The highest notification id this host's spool has issued. A watermark
    /// above it belongs to a spool that started over, so the app drops it
    /// (B-026). nil from a CLI that predates it.
    public let notificationSequence: Int?

    public init(
        schemaVersion: Int = RemoteSessionPayload.currentSchemaVersion,
        cliVersion: String,
        hostname: String,
        generatedAt: Date,
        sessions: [RemoteAgentSession],
        pendingNotifications: [RemoteAgentNotification] = [],
        notificationSequence: Int? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.cliVersion = cliVersion
        self.hostname = hostname
        self.generatedAt = generatedAt
        self.sessions = sessions
        self.pendingNotifications = pendingNotifications
        self.notificationSequence = notificationSequence
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, cliVersion, hostname, generatedAt, sessions, pendingNotifications
        case notificationSequence
    }

    /// Hand-written so a 0.2.0 payload, which has no `pendingNotifications`
    /// key at all, still decodes. Encoding stays synthesized.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        cliVersion = try container.decode(String.self, forKey: .cliVersion)
        hostname = try container.decode(String.self, forKey: .hostname)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        sessions = try container.decode([RemoteAgentSession].self, forKey: .sessions)
        pendingNotifications = try container.decodeIfPresent(
            [RemoteAgentNotification].self, forKey: .pendingNotifications) ?? []
        notificationSequence = try container.decodeIfPresent(Int.self, forKey: .notificationSequence)
    }

    /// ISO-8601 with fractional seconds, sorted keys — pinned so payloads are
    /// stable across platforms and diffs in tests stay readable.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, enc in
            var container = enc.singleValueContainer()
            try container.encode(Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let container = try dec.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(raw) {
                return date
            }
            if let date = try? Date.ISO8601FormatStyle().parse(raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unparseable ISO-8601 date: \(raw)"
            )
        }
        return decoder
    }
}

/// One session, refs+summary tier only — no token/cost metrics (those would
/// drag GRDB + pricing into the CLI and belong to each machine's own index).
public struct RemoteAgentSession: Codable, Sendable, Hashable {
    public let id: String
    /// `AgentKind.rawValue`; a raw String so a newer remote CLI with a provider
    /// this app doesn't know yet still decodes (the row just renders generic).
    public let agentKind: String
    public let projectPath: String
    public let title: String
    public let aiTitle: String?
    public let startedAt: Date
    public let lastUpdatedAt: Date
    public let messageCount: Int
    public let gitBranch: String?
    public let subagentCount: Int
    /// When this session's agent last ran `actvt-cli notify`, on the host's
    /// clock like `lastUpdatedAt`. nil when it hasn't in the spool's retention,
    /// and always from a CLI older than 0.5.0.
    public let lastNotifiedAt: Date?
    /// When the session's agent scheduled itself to resume (a loop agent
    /// asleep between ticks), on the host's clock. Absent from any CLI older
    /// than 0.6.1, which the app reads as "never scheduled".
    public let wakesAt: Date?

    public init(
        id: String, agentKind: String, projectPath: String, title: String,
        aiTitle: String?, startedAt: Date, lastUpdatedAt: Date,
        messageCount: Int, gitBranch: String?, subagentCount: Int,
        lastNotifiedAt: Date? = nil,
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
        self.lastNotifiedAt = lastNotifiedAt
        self.wakesAt = wakesAt
    }

    public init(_ summary: AgentSessionSummary, lastNotifiedAt: Date? = nil) {
        self.init(
            id: summary.id,
            agentKind: summary.agentKind.rawValue,
            projectPath: summary.projectPath,
            title: summary.title,
            aiTitle: summary.aiTitle,
            startedAt: summary.startedAt,
            lastUpdatedAt: summary.lastUpdatedAt,
            messageCount: summary.messageCount,
            gitBranch: summary.gitBranch,
            subagentCount: summary.subagentCount,
            lastNotifiedAt: lastNotifiedAt,
            wakesAt: summary.wakesAt
        )
    }

    public var kind: AgentKind? { AgentKind(rawValue: agentKind) }
}
