//
//  RemoteAgentNotification.swift
//  ActvtSessionsKit
//

import Foundation

// `open`, `flock` and the O_/LOCK_ constants come from the platform C library.
// Darwin re-exports them through Foundation; Glibc and Musl do not, and the
// Linux build is the one that matters most here since that is where headless
// remote agents run. The shipped Linux CLI is built against the Static Linux
// SDK, whose C library module is Musl; a native glibc build still works.
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A notification an agent on a remote host asked Actvt to deliver.
///
/// Remote agents cannot reach Actvt's MCP server: it binds to loopback on the
/// Mac and peers never connect inward. They do not need to. Actvt already
/// SSHes out to every host on a poll, so the agent leaves its message in a
/// spool file and the poll it was already making carries it home.
///
/// `id` is monotonic per host and is how delivery stays exactly-once without
/// risking loss: the app reports the highest id it has taken delivery of, and
/// only then does the CLI stop handing it over. A poll that dies mid-transfer
/// re-delivers rather than swallowing the message.
public struct RemoteAgentNotification: Codable, Sendable, Hashable {
    public let id: Int
    /// `AgentNotification.Kind.rawValue` ("needsInput" / "finished" /
    /// "failed"), raw so a newer CLI kind decodes on an older app.
    public let kind: String
    /// The agent's own words. The app owns the title.
    public let message: String
    /// Project folder name, so the app can group and mute by it like any other
    /// notification. nil when the agent did not say.
    public let project: String?
    /// Remote clock. Used for retention and for `lastNotifiedAt`, never for
    /// pacing: pacing is about interrupting the user here, so the app stamps
    /// arrival itself.
    public let createdAt: Date
    /// The agent session that sent it, so its banner can open that session.
    /// nil when the CLI ran outside an agent, or when it can't tell which of
    /// several agents called it (`CLIRunner.callingSession`).
    public let sessionId: String?
    /// `AgentKind.rawValue` of that session, raw for the same reason as `kind`.
    public let agentKind: String?

    public init(
        id: Int, kind: String, message: String, project: String?, createdAt: Date,
        sessionId: String? = nil, agentKind: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.message = message
        self.project = project
        self.createdAt = createdAt
        self.sessionId = sessionId
        self.agentKind = agentKind
    }
}

/// The on-disk spool `actvt-cli notify` writes and `actvt-cli sessions` drains.
///
/// One JSON object per line, appended under an exclusive lock so two agents
/// stopping at the same moment cannot interleave a line or reuse an id. The
/// file stays small: every entry leaves once it is older than `retention`, so
/// an unreachable Mac cannot grow it without bound. An acknowledged entry is
/// only no longer handed over; it stays until then because it is also the
/// record of which sessions announced a stop (`lastNotified`).
public struct NotificationSpool: Sendable {

    /// Long enough to survive a lunch break or a closed laptop, short enough
    /// that a message which outlived its usefulness does not surface days
    /// later as a mystery.
    public static let defaultRetention: TimeInterval = 60 * 60

    public let url: URL
    public let retention: TimeInterval

    public init(url: URL? = nil, retention: TimeInterval = NotificationSpool.defaultRetention) {
        self.url = url ?? Self.defaultURL()
        self.retention = retention
    }

    /// `$HOME` rather than `homeDirectoryForCurrentUser`, which on macOS reads
    /// the passwd entry and ignores the environment. A CLI invoked over SSH,
    /// or under a test harness, should land wherever HOME says.
    public static func defaultURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let home = environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".actvt", isDirectory: true)
            .appendingPathComponent("notifications.jsonl")
    }

    // MARK: - Writing

    /// Append one notification, returning it with the id it was given.
    public func append(
        kind: String,
        message: String,
        project: String?,
        sessionId: String? = nil,
        agentKind: String? = nil,
        now: Date = Date()
    ) throws -> RemoteAgentNotification {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        return try withLock { handle in
            let existing = Self.decodeLines(try Self.readAll(handle))
            let entry = RemoteAgentNotification(
                id: nextID(after: existing), kind: kind, message: message,
                project: project, createdAt: now,
                sessionId: sessionId, agentKind: agentKind)
            // Rewrite rather than append: the same lock already pruned nothing,
            // but keeping one write path means the file can never hold a line
            // the read path would choke on.
            try Self.write(existing + [entry], to: handle)
            try? Data("\(entry.id)".utf8).write(to: sequenceURL)
            return entry
        }
    }

    /// Ids must never be reused, and the entries alone cannot guarantee that:
    /// once the app acknowledges everything the file is empty, and counting
    /// from the entries would restart at 1. The app's watermark would then be
    /// *ahead* of a genuinely new notification and silently drop it, which is
    /// precisely the loss this design exists to prevent. So the high-water mark
    /// outlives the entries in a sidecar, with the entries as a fallback for a
    /// spool written before the sidecar existed.
    private func nextID(after existing: [RemoteAgentNotification]) -> Int {
        highestID(in: existing) + 1
    }

    private func highestID(in entries: [RemoteAgentNotification]) -> Int {
        let fromEntries = entries.map(\.id).max() ?? 0
        let fromSidecar = (try? String(contentsOf: sequenceURL, encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        return max(fromEntries, fromSidecar)
    }

    /// The highest id this spool has issued. The app sends it nothing above
    /// this unless the spool started over (both files removed, or a new machine
    /// under the same name), which is how it tells (B-026).
    public func sequence(now: Date = Date()) throws -> Int {
        highestID(in: try retained(now: now))
    }

    private var sequenceURL: URL {
        url.deletingPathExtension().appendingPathExtension("seq")
    }

    // MARK: - Draining

    /// Everything not yet acknowledged, dropping what has aged out.
    ///
    /// - Parameter since: highest id the app has already delivered, from the
    ///   `ACTVT_NOTIFY_SINCE` environment variable. nil acknowledges nothing,
    ///   which is what an app too old to send it deserves. Neither does an id
    ///   this spool never issued: it was acknowledged to a spool that has since
    ///   started over, and taken at its word it would hide every new entry.
    public func drain(since: Int?, now: Date = Date()) throws -> [RemoteAgentNotification] {
        let entries = try retained(now: now)
        let acknowledged = since.flatMap { $0 <= highestID(in: entries) ? $0 : nil } ?? 0
        return entries.filter { $0.id > acknowledged }
    }

    /// When each agent session last notified, by session id, over every entry
    /// still retained, delivered or not. The app holds back its own "went
    /// quiet" guess for a stop the agent announced; because this lives on the
    /// host, that holds across an app relaunch too.
    public func lastNotified(now: Date = Date()) throws -> [String: Date] {
        var latest: [String: Date] = [:]
        for entry in try retained(now: now) {
            guard let sessionId = entry.sessionId else { continue }
            latest[sessionId] = max(latest[sessionId] ?? entry.createdAt, entry.createdAt)
        }
        return latest
    }

    /// Every entry younger than `retention`, oldest first, pruning the rest
    /// from disk.
    private func retained(now: Date) throws -> [RemoteAgentNotification] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try withLock { handle in
            let all = Self.decodeLines(try Self.readAll(handle))
            let cutoff = now.addingTimeInterval(-retention)
            let survivors = all.filter { $0.createdAt >= cutoff }
            if survivors.count != all.count {
                try Self.write(survivors, to: handle)
            }
            return survivors.sorted { $0.id < $1.id }
        }
    }

    // MARK: - File plumbing

    private func withLock<T>(_ body: (FileHandle) throws -> T) throws -> T {
        // O_CREAT without O_TRUNC, rather than a fileExists check followed by
        // FileManager.createFile: that check-then-create is not atomic, and a
        // writer that lost the race would truncate a file another had already
        // written under the lock. 0o600 because an agent's message is the
        // user's business and nobody else's.
        let descriptor = open(url.path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        guard flock(handle.fileDescriptor, LOCK_EX) == 0 else {
            throw CocoaError(.fileLocking)
        }
        defer { flock(handle.fileDescriptor, LOCK_UN) }
        return try body(handle)
    }

    private static func readAll(_ handle: FileHandle) throws -> Data {
        try handle.seek(toOffset: 0)
        return try handle.readToEnd() ?? Data()
    }

    private static func write(_ entries: [RemoteAgentNotification], to handle: FileHandle) throws {
        let encoder = RemoteSessionPayload.makeEncoder()
        var out = Data()
        for entry in entries {
            out.append(try encoder.encode(entry))
            out.append(0x0A)
        }
        try handle.seek(toOffset: 0)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: out)
    }

    /// One unparseable line must not discard the rest: the file is written by
    /// whatever CLI version happened to be installed when the agent stopped.
    private static func decodeLines(_ data: Data) -> [RemoteAgentNotification] {
        let decoder = RemoteSessionPayload.makeDecoder()
        return data.split(separator: 0x0A).compactMap { line in
            try? decoder.decode(RemoteAgentNotification.self, from: Data(line))
        }
    }
}
