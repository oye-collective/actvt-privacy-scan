//
//  RemoteLoopPayload.swift
//  ActvtSessionsKit
//

import Foundation

/// Versioned wire format emitted by `actvt-cli loops --json`: the loop agents
/// on a host (Claude Code sessions that reschedule themselves with
/// `ScheduleWakeup`) and whether each is keeping to its own schedule.
public struct RemoteLoopPayload: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let cliVersion: String
    public let hostname: String
    /// The clock every `state` was judged against.
    public let generatedAt: Date
    /// How long past its `wakesAt` an idle loop is still `asleep`.
    public let graceSeconds: Int
    public let loops: [RemoteAgentLoop]

    public init(
        schemaVersion: Int = RemoteLoopPayload.currentSchemaVersion,
        cliVersion: String,
        hostname: String,
        generatedAt: Date,
        graceSeconds: Int,
        loops: [RemoteAgentLoop]
    ) {
        self.schemaVersion = schemaVersion
        self.cliVersion = cliVersion
        self.hostname = hostname
        self.generatedAt = generatedAt
        self.graceSeconds = graceSeconds
        self.loops = loops
    }

    public static func makeEncoder() -> JSONEncoder { RemoteSessionPayload.makeEncoder() }
    public static func makeDecoder() -> JSONDecoder { RemoteSessionPayload.makeDecoder() }
}

/// One loop: the newest session in its project whose last `ScheduleWakeup`
/// didn't stop the loop.
public struct RemoteAgentLoop: Codable, Sendable, Equatable {
    /// `ended`: Claude Code's process registry has no live process running
    /// the session, whatever its transcript says. For a live one, `working`:
    /// a turn is open (the agent woke, or was spoken to, and hasn't
    /// finished). `asleep`: its turn is closed and its wake, plus the grace,
    /// hasn't passed. `overdue`: its wake plus the grace has passed and it
    /// hasn't started a turn, so `overdue` always means a process that missed
    /// its wake.
    ///
    /// Without a registry (`liveness` "unknown") the transcript is all there
    /// is: a process that died mid-turn reads `working`, and one that ended
    /// after scheduling a wake reads `overdue`. A raw `String` on the wire,
    /// like `agentKind`, so a newer CLI's state doesn't break an older app.
    public enum State: String, Sendable {
        case working, asleep, overdue, ended
    }

    /// How `state` was judged: "registry" when Claude Code's process
    /// registry said whether the session's process runs, "unknown" when
    /// there was none to ask. Absent from a CLI older than 0.8.0.
    public enum Liveness: String, Sendable {
        case registry, unknown
    }

    public struct Tick: Codable, Sendable, Equatable {
        public let scheduledAt: Date
        public let reason: String?
        /// The agent's own word: true for a quiet tick, false for one that
        /// did something. Absent when the agent didn't say.
        public let noop: Bool?

        public init(scheduledAt: Date, reason: String?, noop: Bool?) {
            self.scheduledAt = scheduledAt
            self.reason = reason
            self.noop = noop
        }
    }

    public let projectPath: String
    public let sessionId: String
    public let agentKind: String
    public let state: String
    /// The newest record's own timestamp, not the file's mtime.
    public let lastActivityAt: Date
    public let wakesAt: Date
    public let lastTick: Tick
    /// `Liveness.rawValue`.
    public let liveness: String?

    public init(
        projectPath: String, sessionId: String, agentKind: String, state: String,
        lastActivityAt: Date, wakesAt: Date, lastTick: Tick, liveness: String? = nil
    ) {
        self.projectPath = projectPath
        self.sessionId = sessionId
        self.agentKind = agentKind
        self.state = state
        self.lastActivityAt = lastActivityAt
        self.wakesAt = wakesAt
        self.lastTick = lastTick
        self.liveness = liveness
    }

    /// `live` is nil when no process registry could say.
    init(_ tick: ClaudeLoopTick, projectPath: String, sessionId: String, live: Bool?, now: Date, grace: TimeInterval) {
        let state: State
        if live == false {
            state = .ended
        } else if tick.turnInProgress {
            state = .working
        } else {
            state = now < tick.wakesAt.addingTimeInterval(grace) ? .asleep : .overdue
        }
        self.init(
            projectPath: projectPath, sessionId: sessionId, agentKind: AgentKind.claudeCode.rawValue,
            state: state.rawValue, lastActivityAt: tick.lastActivityAt, wakesAt: tick.wakesAt,
            lastTick: Tick(scheduledAt: tick.scheduledAt, reason: tick.reason, noop: tick.noop),
            liveness: (live == nil ? Liveness.unknown : .registry).rawValue
        )
    }
}
