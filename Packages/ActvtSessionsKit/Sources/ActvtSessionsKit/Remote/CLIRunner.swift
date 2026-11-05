//
//  CLIRunner.swift
//  ActvtSessionsKit
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The `actvt-cli` command logic, kept in the library so the two executables
/// (the xcodeproj-built binary embedded in Actvt.app and the SwiftPM-built
/// Linux binary) are both 3-line `@main` shims over the same code.
///
/// Surface:
///   actvt-cli sessions --json [--limit N] [--claude-root PATH] [--codex-root PATH] [--pi-root PATH]
///   actvt-cli transcript --json --id <id> [--kind <raw>] [--first | --before BYTE | --after BYTE] [--claude-root PATH] [--codex-root PATH] [--pi-root PATH]
///   actvt-cli notify --message <text> [--kind <raw>] [--project NAME]
///   actvt-cli usage --json
///   actvt-cli loops --json [--grace-minutes N] [--include-ended] [--claude-root PATH]
///   actvt-cli --version
///
/// Argument parsing is hand-rolled — a handful of flags don't justify a
/// dependency in a static binary.
public enum CLIRunner {

    public static let version = "0.10.1"
    private static let defaultLimit = 50

    public struct ExitStatus: Sendable {
        public let code: Int32
        public init(code: Int32) { self.code = code }
        public static let ok = ExitStatus(code: 0)
        public static let failure = ExitStatus(code: 1)
        public static let usage = ExitStatus(code: 64)   // EX_USAGE
    }

    /// Run with CLI arguments (excluding argv[0]). Output lands on the
    /// provided streams so tests can capture it.
    public static func run(
        arguments: [String],
        stdout: (String) -> Void = { print($0) },
        stderr: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) async -> ExitStatus {
        var args = arguments[...]

        switch args.popFirst() {
        case "--version", "-v":
            stdout(version)
            return .ok
        case "sessions":
            return await runSessions(Array(args), stdout: stdout, stderr: stderr)
        case "transcript":
            return await runTranscript(Array(args), stdout: stdout, stderr: stderr)
        case "notify":
            return runNotify(Array(args), stdout: stdout, stderr: stderr)
        case "usage":
            return await runUsage(Array(args), stdout: stdout, stderr: stderr)
        case "loops":
            return await runLoops(Array(args), stdout: stdout, stderr: stderr)
        case nil, "--help", "-h":
            stdout(usageText)
            return args.isEmpty ? .usage : .ok
        case .some(let other):
            stderr("unknown command: \(other)")
            stderr(usageText)
            return .usage
        }
    }

    // MARK: - sessions

    private static func runSessions(
        _ arguments: [String],
        stdout: (String) -> Void,
        stderr: (String) -> Void
    ) async -> ExitStatus {
        var json = false
        var limit = defaultLimit
        var claudeRoot: URL?
        var codexRoot: URL?
        var piRoot: URL?

        var iterator = arguments.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--json":
                json = true
            case "--limit":
                guard let raw = iterator.next(), let value = Int(raw), value > 0 else {
                    stderr("--limit requires a positive integer")
                    return .usage
                }
                limit = value
            case "--claude-root":
                guard let raw = iterator.next() else {
                    stderr("--claude-root requires a path")
                    return .usage
                }
                claudeRoot = URL(fileURLWithPath: raw, isDirectory: true)
            case "--codex-root":
                guard let raw = iterator.next() else {
                    stderr("--codex-root requires a path")
                    return .usage
                }
                codexRoot = URL(fileURLWithPath: raw, isDirectory: true)
            case "--pi-root":
                guard let raw = iterator.next() else {
                    stderr("--pi-root requires a path")
                    return .usage
                }
                piRoot = URL(fileURLWithPath: raw, isDirectory: true)
            default:
                stderr("unknown option: \(arg)")
                return .usage
            }
        }
        guard json else {
            stderr("only --json output is supported in this version")
            return .usage
        }

        let registry = makeRegistry(claudeRoot: claudeRoot, codexRoot: codexRoot, piRoot: piRoot)
        let payload = await collectSessions(registry: registry, limit: limit)

        do {
            let data = try RemoteSessionPayload.makeEncoder().encode(payload)
            stdout(String(decoding: data, as: UTF8.self))
            return .ok
        } catch {
            stderr("failed to encode payload: \(error)")
            return .failure
        }
    }

    // MARK: - loops

    static let defaultLoopGrace: TimeInterval = 10 * 60
    /// How long a loop whose process has gone stays listed (as `ended`), so a
    /// stop shows for a day and a retired loop drops off by itself.
    static let endedLoopRetention: TimeInterval = 24 * 60 * 60

    /// `actvt-cli loops --json`: each loop agent on this host and whether it
    /// is keeping to its own schedule. Read-only: it never starts, stops or
    /// writes anything.
    static func runLoops(
        _ arguments: [String],
        now: Date = Date(),
        stdout: (String) -> Void,
        stderr: (String) -> Void
    ) async -> ExitStatus {
        var json = false
        var grace = defaultLoopGrace
        var includeEnded = false
        var claudeRoot: URL?

        var iterator = arguments.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--json":
                json = true
            case "--grace-minutes":
                guard let raw = iterator.next(), let value = Int(raw), value >= 0 else {
                    stderr("--grace-minutes requires a non-negative integer")
                    return .usage
                }
                grace = TimeInterval(value * 60)
            case "--include-ended":
                includeEnded = true
            case "--claude-root":
                guard let raw = iterator.next() else {
                    stderr("--claude-root requires a path")
                    return .usage
                }
                claudeRoot = URL(fileURLWithPath: raw, isDirectory: true)
            default:
                stderr("unknown option: \(arg)")
                return .usage
            }
        }
        guard json else {
            stderr("only --json output is supported in this version")
            return .usage
        }

        let source = claudeRoot.map { ClaudeCodeSessionSource(rootURL: $0) } ?? ClaudeCodeSessionSource()
        let payload = await collectLoops(source: source, now: now, grace: grace, includeEnded: includeEnded)
        do {
            let data = try RemoteLoopPayload.makeEncoder().encode(payload)
            stdout(String(decoding: data, as: UTF8.self))
            return .ok
        } catch {
            stderr("failed to encode payload: \(error)")
            return .failure
        }
    }

    /// Only Claude Code schedules wakes. Sessions are walked newest first, and
    /// each project keeps its newest loop, so a loop restarted in a fresh
    /// session replaces the dead one rather than sitting beside it.
    ///
    /// Whether each loop's process still runs comes from the process registry
    /// beside the root its session was found under, read once per root. A
    /// loop that ended over `endedLoopRetention` ago is left out unless
    /// `includeEnded`.
    ///
    /// That rule is applied before a transcript is read wherever it can be: a
    /// session whose process has exited and whose file was last written before
    /// the retention window can only be such a loop (its newest record is no
    /// newer than its file), so it is skipped unread. Finding the last call
    /// reads a session that never scheduled one whole, so without this every
    /// sweep read the host's entire history (5.5 GB on dgx, 2026-10-26).
    static func collectLoops(
        source: ClaudeCodeSessionSource, now: Date, grace: TimeInterval, includeEnded: Bool = false,
        registry: (URL) -> ClaudeProcessRegistry? = { ClaudeProcessRegistry(projectsRoot: $0) }
    ) async -> RemoteLoopPayload {
        let refs = (try? await source.listSessionRefs()) ?? []
        var projects = Set<String>()
        var registries: [String: ClaudeProcessRegistry?] = [:]
        var loops: [RemoteAgentLoop] = []
        for ref in refs {
            var live: Bool?
            if let root = try? await source.projectsRoot(id: ref.id) {
                if registries[root.path] == nil { registries[root.path] = .some(registry(root)) }
                live = registries[root.path]!.map { $0.liveSessionIds.contains(ref.id) }
            }
            if live == false, !includeEnded,
               now.timeIntervalSince(ref.lastUpdatedAt) > endedLoopRetention { continue }
            guard let tick = try? await source.loadLoopTick(id: ref.id) else { continue }
            let projectPath = (try? await source.loadSummary(id: ref.id))?.projectPath ?? "(unknown)"
            guard projects.insert(projectPath).inserted else { continue }
            let loop = RemoteAgentLoop(tick, projectPath: projectPath, sessionId: ref.id, live: live, now: now, grace: grace)
            if loop.state == RemoteAgentLoop.State.ended.rawValue, !includeEnded,
               now.timeIntervalSince(loop.lastActivityAt) > endedLoopRetention { continue }
            loops.append(loop)
        }
        return RemoteLoopPayload(
            cliVersion: version,
            hostname: ProcessInfo.processInfo.hostName,
            generatedAt: now,
            graceSeconds: Int(grace),
            loops: loops
        )
    }

    // MARK: - usage

    /// `actvt-cli usage --json`: the Claude and Codex plan usage of the
    /// accounts the agent CLIs are signed in to on this host.
    ///
    /// Reads only the CLIs' own credential files and never refreshes or writes
    /// them. A refresh that rotated a token without writing the new pair back
    /// where the CLI reads it would sign the user out of Claude Code or Codex,
    /// and an expired token is the CLI's to renew the next time it runs.
    static func runUsage(
        _ arguments: [String],
        stdout: (String) -> Void,
        stderr: (String) -> Void,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowKeychain: Bool = true,
        session: URLSession = usageSession,
        now: Date = Date()
    ) async -> ExitStatus {
        var json = false
        for arg in arguments {
            switch arg {
            case "--json":
                json = true
            default:
                stderr("unknown option: \(arg)")
                return .usage
            }
        }
        guard json else {
            stderr("only --json output is supported in this version")
            return .usage
        }

        let payload = await collectUsage(
            home: home, environment: environment, allowKeychain: allowKeychain,
            session: session, now: now)
        do {
            let data = try RemoteSessionPayload.makeEncoder().encode(payload)
            stdout(String(decoding: data, as: UTF8.self))
            return .ok
        } catch {
            stderr("failed to encode payload: \(error)")
            return .failure
        }
    }

    /// Ephemeral with no URL cache: responses fetched with a bearer token
    /// must never land in a disk cache.
    ///
    /// One session for the life of the process, like `URLSession.shared`, and
    /// never released. On Linux, freeing a session while curl still holds a
    /// kept-alive connection crashes in FoundationNetworking's `_MultiHandle`
    /// deinit (`deallocated with non-zero retain count`), and the output is
    /// lost; the static musl build hit it on most runs under load.
    static let usageSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    static func collectUsage(
        home: URL, environment: [String: String], allowKeychain: Bool,
        session: URLSession, now: Date
    ) async -> RemoteUsagePayload {
        var providers: [RemoteProviderUsage] = []
        if let claude = await claudeUsage(
            home: home, environment: environment, allowKeychain: allowKeychain,
            session: session, now: now) {
            providers.append(claude)
        }
        if let codex = await codexUsage(home: home, environment: environment, session: session, now: now) {
            providers.append(codex)
        }
        return RemoteUsagePayload(
            cliVersion: version,
            hostname: ProcessInfo.processInfo.hostName,
            generatedAt: now,
            providers: providers
        )
    }

    /// nil when Claude Code was never set up on this host. Reads the
    /// credential Claude Code would use in this environment, through the
    /// reader the app shares.
    private static func claudeUsage(
        home: URL, environment: [String: String], allowKeychain: Bool,
        session: URLSession, now: Date
    ) async -> RemoteProviderUsage? {
        let claude = AgentKind.claudeCode.rawValue
        let credentials: ClaudeUsageCredentials.Credentials
        switch ClaudeUsageCredentials.read(allowKeychain: allowKeychain, env: environment, home: home) {
        case .found(let found, _):
            credentials = found
        case .setupToken(let token):
            return await claudeUsage(setupToken: token, session: session, now: now)
        case .stale:
            return RemoteProviderUsage(
                usage: .init(providerRaw: claude, state: .needsAuth, fetchedAt: now),
                authHint: .staleStoredToken)
        case .accessDenied:
            // Over ssh the login keychain is locked, so this is the usual
            // answer from a Mac reached remotely: the user may well be signed
            // in, and "sign in again" would be the wrong advice.
            return RemoteProviderUsage(
                usage: .init(providerRaw: claude, state: .needsAuth, fetchedAt: now),
                authHint: RemoteProviderUsage.keychainUnavailable)
        case .notPresent:
            guard FileManager.default.fileExists(
                atPath: home.appendingPathComponent(".claude").path)
            else { return nil }
            return RemoteProviderUsage(
                usage: .init(providerRaw: claude, state: .needsAuth, fetchedAt: now))
        }

        do {
            let parsed = try await ClaudeUsageFetcher.fetch(
                accessToken: credentials.accessToken, session: session)
            return RemoteProviderUsage(usage: .init(
                providerRaw: claude,
                state: .ok,
                // The usage endpoint never names the plan for Claude; the
                // credential blob does, so it is the only source.
                planLabel: credentials.planLabel,
                session: parsed.session,
                weekly: parsed.weekly,
                perModel: parsed.perModel,
                credits: parsed.credits,
                fetchedAt: now))
        } catch {
            return RemoteProviderUsage(
                usage: .init(providerRaw: claude, state: .init(failure: error),
                             planLabel: credentials.planLabel, fetchedAt: now),
                authHint: ClaudeAuthHint(failure: error),
                retryAfter: (error as? ProviderUsageError)?.retryAfter)
        }
    }

    /// A setup token reads its plan from rate-limit headers: the session and
    /// weekly windows, with no plan name or per-model lanes.
    private static func claudeUsage(
        setupToken: String, session: URLSession, now: Date
    ) async -> RemoteProviderUsage {
        let claude = AgentKind.claudeCode.rawValue
        do {
            let parsed = try await ClaudeRateLimitHeaders.fetch(setupToken: setupToken, session: session)
            return RemoteProviderUsage(usage: .init(
                providerRaw: claude, state: .ok,
                session: parsed.session, weekly: parsed.weekly, fetchedAt: now))
        } catch {
            return RemoteProviderUsage(
                usage: .init(providerRaw: claude, state: .init(failure: error), fetchedAt: now),
                retryAfter: (error as? ProviderUsageError)?.retryAfter)
        }
    }

    /// nil when Codex was never set up on this host.
    private static func codexUsage(
        home: URL, environment: [String: String], session: URLSession, now: Date
    ) async -> RemoteProviderUsage? {
        let authFile = CodexUsageCredentials.authFileURL(env: environment, home: home)
        guard FileManager.default.fileExists(atPath: authFile.deletingLastPathComponent().path)
        else { return nil }

        guard let credentials = CodexUsageCredentials.read(env: environment, home: home),
              !credentials.isExpired(now: now)
        else {
            return RemoteProviderUsage(usage: .init(
                providerRaw: AgentKind.codexCLI.rawValue, state: .needsAuth, fetchedAt: now))
        }
        do {
            let parsed = try await CodexUsageFetcher.fetch(
                accessToken: credentials.accessToken,
                accountId: credentials.accountId,
                session: session)
            return RemoteProviderUsage(usage: .init(
                providerRaw: AgentKind.codexCLI.rawValue,
                state: .ok,
                planLabel: parsed.planLabel,
                session: parsed.session,
                weekly: parsed.weekly,
                perModel: parsed.perModel,
                fetchedAt: now))
        } catch {
            return RemoteProviderUsage(
                usage: .init(providerRaw: AgentKind.codexCLI.rawValue,
                             state: .init(failure: error), fetchedAt: now),
                retryAfter: (error as? ProviderUsageError)?.retryAfter)
        }
    }

    // MARK: - notify

    /// `actvt-cli notify --kind needsInput --message "..." [--project NAME]`
    ///
    /// Writes to the spool and returns immediately. It deliberately does not
    /// wait for, or report, delivery: the agent is stopping, the Mac may be
    /// asleep, and blocking an agent's exit on a laptop lid is not a trade
    /// worth making. Exit 0 means "recorded", not "seen".
    static func runNotify(
        _ arguments: [String],
        stdout: (String) -> Void,
        stderr: (String) -> Void,
        spool: NotificationSpool = NotificationSpool(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) -> ExitStatus {
        var kind: String?
        var message: String?
        var project: String?

        var iterator = arguments.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--kind":
                guard let raw = iterator.next() else {
                    stderr("--kind requires a value")
                    return .usage
                }
                kind = raw
            case "--message", "-m":
                guard let raw = iterator.next() else {
                    stderr("--message requires text")
                    return .usage
                }
                message = raw
            case "--project":
                guard let raw = iterator.next() else {
                    stderr("--project requires a name")
                    return .usage
                }
                project = raw
            default:
                stderr("unknown option: \(arg)")
                return .usage
            }
        }

        let resolvedKind = kind ?? Self.defaultNotifyKind
        guard Self.notifyKinds.contains(resolvedKind) else {
            stderr("--kind must be one of: \(Self.notifyKinds.joined(separator: ", "))")
            return .usage
        }
        let text = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            stderr("--message is required")
            return .usage
        }
        // A notification is a banner, not a transcript. Truncating here keeps a
        // runaway agent from filling the spool with something nobody can read.
        let trimmed = String(text.prefix(Self.notifyMessageLimit))

        let caller = callingSession(environment: environment)
        do {
            let entry = try spool.append(
                kind: resolvedKind,
                message: trimmed,
                project: project?.trimmingCharacters(in: .whitespaces),
                sessionId: caller?.id,
                agentKind: caller?.agentKind.rawValue,
                now: now
            )
            stdout("recorded #\(entry.id)")
            return .ok
        } catch {
            stderr("could not write the notification spool: \(error)")
            return .failure
        }
    }

    /// Mirrors `AgentNotification.Kind` in the app. Raw strings rather than a
    /// shared enum: the CLI must keep working against an app that knows a kind
    /// it does not, and vice versa.
    public static let notifyKinds = ["needsInput", "finished", "failed"]
    public static let defaultNotifyKind = "needsInput"
    public static let notifyMessageLimit = 500

    /// The variable each agent sets, in the environment its tools run in, to
    /// its own session id: the same id its transcript is listed under.
    static let sessionEnvironment: [(name: String, agentKind: AgentKind)] = [
        ("CLAUDE_CODE_SESSION_ID", .claudeCode),
        ("CODEX_THREAD_ID", .codexCLI),
        ("PI_SESSION_ID", .pi),
    ]

    /// The agent session running this command. nil outside an agent, and when
    /// more than one agent's variable is set: an agent started from another
    /// agent's shell inherits the outer one's id as well, and nothing says
    /// which of them is calling. A banner that opens nothing beats one that
    /// opens the wrong session.
    static func callingSession(environment: [String: String]) -> (id: String, agentKind: AgentKind)? {
        let found = sessionEnvironment.compactMap { variable -> (id: String, agentKind: AgentKind)? in
            guard let id = environment[variable.name]?.trimmingCharacters(in: .whitespaces),
                  !id.isEmpty else { return nil }
            return (id, variable.agentKind)
        }
        return found.count == 1 ? found[0] : nil
    }

    // MARK: - transcript

    private static func runTranscript(
        _ arguments: [String],
        stdout: (String) -> Void,
        stderr: (String) -> Void
    ) async -> ExitStatus {
        var json = false
        var sessionId: String?
        var kindRaw: String?
        var window: TranscriptWindowRequest?
        var claudeRoot: URL?
        var codexRoot: URL?
        var piRoot: URL?

        var iterator = arguments.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--json":
                json = true
            case "--first", "--before", "--after":
                guard window == nil else {
                    stderr("only one of --first, --before and --after")
                    return .usage
                }
                if arg == "--first" {
                    window = .first
                    continue
                }
                guard let raw = iterator.next(), let cursor = UInt64(raw) else {
                    stderr("\(arg) requires a byte offset (a window's start or end)")
                    return .usage
                }
                window = arg == "--before" ? .before(cursor) : .after(cursor)
            case "--id":
                guard let raw = iterator.next(), !raw.isEmpty else {
                    stderr("--id requires a session id")
                    return .usage
                }
                sessionId = raw
            case "--kind":
                guard let raw = iterator.next(), !raw.isEmpty else {
                    stderr("--kind requires an agent kind")
                    return .usage
                }
                kindRaw = raw
            case "--claude-root":
                guard let raw = iterator.next() else {
                    stderr("--claude-root requires a path")
                    return .usage
                }
                claudeRoot = URL(fileURLWithPath: raw, isDirectory: true)
            case "--codex-root":
                guard let raw = iterator.next() else {
                    stderr("--codex-root requires a path")
                    return .usage
                }
                codexRoot = URL(fileURLWithPath: raw, isDirectory: true)
            case "--pi-root":
                guard let raw = iterator.next() else {
                    stderr("--pi-root requires a path")
                    return .usage
                }
                piRoot = URL(fileURLWithPath: raw, isDirectory: true)
            default:
                stderr("unknown option: \(arg)")
                return .usage
            }
        }
        guard json else {
            stderr("only --json output is supported in this version")
            return .usage
        }
        guard let sessionId else {
            stderr("--id is required")
            return .usage
        }

        let registry = makeRegistry(claudeRoot: claudeRoot, codexRoot: codexRoot, piRoot: piRoot)
        guard let transcript = await loadTranscript(
            registry: registry, sessionId: sessionId, kindRaw: kindRaw, window: window ?? .latest
        ) else {
            stderr("session not found: \(sessionId)")
            return .failure
        }

        let payload = RemoteTranscriptPayload(
            cliVersion: version,
            hostname: ProcessInfo.processInfo.hostName,
            generatedAt: Date(),
            transcript: RemoteTranscript(transcript)
        )
        do {
            let data = try RemoteSessionPayload.makeEncoder().encode(payload)
            stdout(String(decoding: data, as: UTF8.self))
            return .ok
        } catch {
            stderr("failed to encode payload: \(error)")
            return .failure
        }
    }

    /// Known `--kind` dispatches straight to its provider. Absent or unknown
    /// kind (hand-run CLI) tries each available provider — wrong providers
    /// fail fast on file-not-found, so the sweep is cheap.
    static func loadTranscript(
        registry: AgentSessionRegistry, sessionId: String, kindRaw: String?,
        window: TranscriptWindowRequest = .latest
    ) async -> AgentTranscript? {
        if let kindRaw, let kind = AgentKind(rawValue: kindRaw) {
            guard let provider = registry.provider(for: kind) else { return nil }
            return try? await provider.loadTranscript(id: sessionId, window: window)
        }
        for provider in await registry.availableProviders() {
            if let transcript = try? await provider.loadTranscript(id: sessionId, window: window) {
                return transcript
            }
        }
        return nil
    }

    private static func makeRegistry(claudeRoot: URL?, codexRoot: URL?, piRoot: URL?) -> AgentSessionRegistry {
        if claudeRoot == nil && codexRoot == nil && piRoot == nil {
            return .makeDefault()
        }
        // Explicit roots (tests/fixtures): only the overridden providers, so a
        // fixture run never touches the real home directory.
        var providers: [any AgentSessionSource] = []
        if let claudeRoot { providers.append(ClaudeCodeSessionSource(rootURL: claudeRoot)) }
        if let codexRoot { providers.append(CodexSessionSource(rootURL: codexRoot)) }
        if let piRoot { providers.append(PiSessionSource(rootURL: piRoot)) }
        return AgentSessionRegistry(providers: providers)
    }

    /// Refs walk first (cheap), newest first, then summaries for only the top
    /// `limit` — a host with thousands of transcripts answers fast. A session
    /// whose summary fails to parse degrades to id-as-title; never dropped.
    static func collectSessions(registry: AgentSessionRegistry, limit: Int) async -> RemoteSessionPayload {
        var refs: [AgentSessionRef] = []
        for provider in await registry.availableProviders() {
            refs.append(contentsOf: (try? await provider.listSessionRefs()) ?? [])
        }
        refs.sort { $0.lastUpdatedAt > $1.lastUpdatedAt }

        let notified = lastNotified()
        var sessions: [RemoteAgentSession] = []
        sessions.reserveCapacity(min(refs.count, limit))
        for ref in refs.prefix(limit) {
            if let provider = registry.provider(for: ref.agentKind),
               let summary = try? await provider.loadSummary(id: ref.id) {
                sessions.append(RemoteAgentSession(summary, lastNotifiedAt: notified[ref.id]))
            } else {
                sessions.append(RemoteAgentSession(
                    id: ref.id, agentKind: ref.agentKind.rawValue, projectPath: "(unknown)",
                    title: ref.id, aiTitle: nil, startedAt: ref.lastUpdatedAt,
                    lastUpdatedAt: ref.lastUpdatedAt, messageCount: 0,
                    gitBranch: nil, subagentCount: 0, lastNotifiedAt: notified[ref.id]
                ))
            }
        }

        let spool = NotificationSpool()
        return RemoteSessionPayload(
            cliVersion: version,
            hostname: ProcessInfo.processInfo.hostName,
            generatedAt: Date(),
            sessions: sessions,
            pendingNotifications: drainSpool(spool: spool),
            notificationSequence: try? spool.sequence()
        )
    }

    /// Drain whatever agents on this host left behind, acknowledging up to the
    /// id the app reports in `ACTVT_NOTIFY_SINCE`.
    ///
    /// A spool that cannot be read must never take the session list down with
    /// it: remote sessions worked long before notifications did, and a locked
    /// or corrupt file is not a reason to report the host as unreachable.
    static func drainSpool(
        spool: NotificationSpool = NotificationSpool(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [RemoteAgentNotification] {
        let since = environment["ACTVT_NOTIFY_SINCE"].flatMap(Int.init)
        return (try? spool.drain(since: since)) ?? []
    }

    /// When each session last notified, under the same rule as `drainSpool`:
    /// an unreadable spool means none have, never a failed listing.
    static func lastNotified(spool: NotificationSpool = NotificationSpool()) -> [String: Date] {
        (try? spool.lastNotified()) ?? [:]
    }

    private static let usageText = """
    usage: actvt-cli <command> [options]

    commands:
      sessions --json [--limit N] [--claude-root PATH] [--codex-root PATH] [--pi-root PATH]
          List agent sessions (Claude Code, Codex CLI, pi) as JSON, newest first.
      transcript --json --id <id> [--kind <agentKind>] [--first | --before BYTE | --after BYTE]
                 [--claude-root PATH] [--codex-root PATH] [--pi-root PATH]
          Print one session's transcript as JSON, a window of at most 25 MB of
          its file: the latest by default, the first with --first, or the one
          ending (starting) at a byte another window started (ended) at. The
          payload's "window" gives the range read and the file's size.
      notify --message <text> [--kind needsInput|finished|failed] [--project NAME]
          Tell the user you have stopped. The message is picked up by Actvt on
          its next poll of this host and shown as a notification on their Mac.
          Call it once per stop, when their attention is actually worth having.
          Run from Claude Code, Codex or pi, it records which session sent it,
          so clicking the notification opens that session.
      usage --json
          Print the Claude and Codex plan usage (session and weekly windows,
          percent used and reset times) of the accounts the agent CLIs are
          signed in to on this host. Reads only the agent CLIs' own credential
          stores, never refreshes them, and never prints a token.
      loops --json [--grace-minutes N] [--include-ended] [--claude-root PATH]
          List the loop agents on this host: Claude Code sessions that
          reschedule themselves with ScheduleWakeup. Each reads ended (Claude
          Code's process registry has no live process for it), working (a turn
          is open), asleep (before its wake plus N minutes, default 10) or
          overdue (its process runs, but it is past its wake with no turn
          started). Loops that ended over a day ago are left out unless
          --include-ended. Without a registry (an older Claude Code), liveness
          is "unknown" and the transcript alone decides. Read-only.
      --version
          Print the CLI version.
    """
}
