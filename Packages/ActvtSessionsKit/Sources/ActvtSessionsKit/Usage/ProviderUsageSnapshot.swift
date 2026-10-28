//
//  ProviderUsageSnapshot.swift
//  ActvtSessionsKit
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Last-known usage-quota state for one agent provider (Claude Code / Codex
/// CLI), fetched read-only from the provider's usage endpoint with the CLI's
/// own stored credentials. Codable so the latest snapshots survive relaunch
/// via a small JSON cache — the cache holds percentages and dates only,
/// never tokens.
public struct ProviderUsageSnapshot: Codable, Equatable, Sendable {

    public enum State: String, Codable, Sendable {
        /// Windows are current as of `fetchedAt`.
        case ok
        /// Stored credentials are missing, expired, or rejected — the user
        /// must re-authenticate in the CLI. Cached windows render dimmed.
        case needsAuth
        /// The usage endpoint returned 429; polling backs off until the
        /// provider's Retry-After elapses.
        case rateLimited
        /// Network or decoding failure; cached windows remain, just stale.
        case error
    }

    /// One quota window ("Session", "Weekly", or a named per-model limit).
    public struct Window: Codable, Equatable, Sendable {
        /// nil for the standard session/weekly lanes; a model or limit name
        /// ("Opus", "GPT-5.3-Codex-Spark") for per-model extras.
        public var label: String?
        /// 0…1 share of the window already consumed.
        public var usedFraction: Double
        public var resetsAt: Date?
        /// The window's span in seconds, when the provider reports one.
        /// Drives the row label: Codex's `primary_window` is 5h on paid plans
        /// but 30 days on free — slot position alone would mislabel it.
        public var windowSeconds: Double?

        public init(
            label: String? = nil, usedFraction: Double,
            resetsAt: Date? = nil, windowSeconds: Double? = nil
        ) {
            self.label = label
            self.usedFraction = usedFraction
            self.resetsAt = resetsAt
            self.windowSeconds = windowSeconds
        }

        public enum Cadence: Sendable {
            case session, weekly, monthly
        }

        /// Bucketed by duration with slack for provider drift; nil when the
        /// span is unknown or unbucketable (caller falls back to the slot's
        /// default name).
        public var cadence: Cadence? {
            guard let windowSeconds else { return nil }
            switch windowSeconds {
            case ...(6 * 3_600): return .session
            case ...(8 * 86_400): return .weekly
            case ...(32 * 86_400): return .monthly
            default: return nil
            }
        }

        /// How much of the window's time has gone by `now`, 0…1: where an
        /// even pace would have used the allowance to. A reading of the clock,
        /// never a forecast. nil without both a reset time and a length.
        public func elapsedFraction(at now: Date) -> Double? {
            guard let resetsAt, let windowSeconds, windowSeconds > 0 else { return nil }
            return min(1, max(0, 1 - resetsAt.timeIntervalSince(now) / windowSeconds))
        }

        public enum Pace: Equatable, Sendable {
            case onPace, ahead
        }

        /// `.ahead` when more of the allowance is used than of the time, and
        /// less than half of it is left: an early burst in a fresh window is
        /// not worth a warning. nil when the elapsed share is unknown, or the
        /// allowance is spent (the limit itself is then the news).
        public func pace(at now: Date) -> Pace? {
            guard usedFraction < 1, let elapsed = elapsedFraction(at: now) else { return nil }
            return usedFraction > elapsed && usedFraction > 0.5 ? .ahead : .onPace
        }
    }

    /// Pay-as-you-go credits: what the provider charges once plan limits are
    /// exhausted.
    ///
    /// Unlike every other money figure in Actvt, this is not an estimate from
    /// token counts at API list prices. It is money the provider has actually
    /// billed, which is why it is reported separately rather than folded into
    /// the cost totals.
    public struct Credits: Codable, Equatable, Sendable {
        /// Minor units (cents for USD), matching the provider's own encoding
        /// so no precision is lost rounding through a Double.
        public var usedMinor: Int
        public var limitMinor: Int
        /// ISO 4217, e.g. "USD".
        public var currency: String
        /// Minor units per major unit, as a power of ten: 2 → cents.
        public var exponent: Int
        /// The user has credits switched on. Off means the card stays hidden
        /// rather than showing a meaningless $0.00.
        public var enabled: Bool
        /// Spending is capped out, so agents will start failing on limits.
        public var limitReached: Bool

        public init(
            usedMinor: Int, limitMinor: Int, currency: String,
            exponent: Int, enabled: Bool, limitReached: Bool
        ) {
            self.usedMinor = usedMinor
            self.limitMinor = limitMinor
            self.currency = currency
            self.exponent = exponent
            self.enabled = enabled
            self.limitReached = limitReached
        }

        public var usedFraction: Double {
            guard limitMinor > 0 else { return 0 }
            return min(1, Double(usedMinor) / Double(limitMinor))
        }

        private func major(_ minor: Int) -> Decimal {
            Decimal(minor) / pow(Decimal(10), exponent)
        }

        public var usedMajor: Decimal { major(usedMinor) }
        public var limitMajor: Decimal { major(limitMinor) }
    }

    /// `AgentKind.rawValue` — stored raw so cache decoding survives kinds
    /// this build doesn't know about.
    public var providerRaw: String
    public var state: State
    /// Provider-reported plan ("Pro", "Plus"); nil when the endpoint doesn't
    /// say.
    public var planLabel: String?
    public var session: Window?
    public var weekly: Window?
    public var perModel: [Window]
    /// nil when the provider doesn't report credits at all. Optional with a
    /// default so cached snapshots written before this existed still decode.
    public var credits: Credits?
    public var fetchedAt: Date

    public init(
        providerRaw: String,
        state: State,
        planLabel: String? = nil,
        session: Window? = nil,
        weekly: Window? = nil,
        perModel: [Window] = [],
        credits: Credits? = nil,
        fetchedAt: Date
    ) {
        self.providerRaw = providerRaw
        self.state = state
        self.planLabel = planLabel
        self.session = session
        self.weekly = weekly
        self.perModel = perModel
        self.credits = credits
        self.fetchedAt = fetchedAt
    }

    public var kind: AgentKind? { AgentKind(rawValue: providerRaw) }

    public var hasAnyWindow: Bool { session != nil || weekly != nil || !perModel.isEmpty }
}

/// Failure modes shared by both provider usage fetchers. Mapped onto
/// `ProviderUsageSnapshot.State` by the service; cached windows survive all
/// of them.
public enum ProviderUsageError: Error, Equatable, Sendable {
    case needsAuth
    /// The token authenticated fine but lacks a scope the usage endpoint
    /// requires. Distinct from `needsAuth` because re-authenticating changes
    /// nothing: it is the wrong *kind* of token, not an expired one. A Claude
    /// Code setup token is the case that matters: it carries `user:inference`
    /// but not `user:profile`, so it can drive the CLI yet can never read usage.
    case insufficientScope(requiredScopes: [String])
    case rateLimited(retryAfter: Date?)
    case transport
}

/// Why Claude usage could not be read, when the answer is more specific than
/// "re-authenticate". Drives one line of card copy, so the cases are the ones
/// that lead to genuinely different user actions.
public enum ClaudeAuthHint: Equatable, Sendable {
    /// Nothing to add beyond the state itself.
    case none
    /// The CLI credential store is readable but its access token has expired
    /// and nothing is refreshing it. This is the fingerprint of a Claude Code
    /// signed in some other way (a `CLAUDE_CODE_OAUTH_TOKEN` setup token, say):
    /// the CLI keeps working while the store Actvt reads quietly goes stale, so
    /// "run /login" would be advice to someone who is already signed in.
    case staleStoredToken
    /// The token works but lacks a scope the usage endpoint requires, most
    /// often a setup token. Re-authenticating cannot fix it.
    case insufficientScope(requiredScopes: [String])
}

extension ProviderUsageSnapshot.State {
    /// The state a failed fetch leaves the provider in. A scope refusal is
    /// still an auth failure as far as the bars are concerned: dim them and
    /// explain. Only the explanation (`ClaudeAuthHint`) differs.
    public init(failure error: Error) {
        switch error {
        case ProviderUsageError.needsAuth, ProviderUsageError.insufficientScope: self = .needsAuth
        case ProviderUsageError.rateLimited: self = .rateLimited
        default: self = .error
        }
    }
}

extension ClaudeAuthHint {
    /// The reason behind a fetch failure, when it is more than "sign in again".
    public init(failure error: Error) {
        guard case ProviderUsageError.insufficientScope(let required) = error else {
            self = .none
            return
        }
        self = .insufficientScope(requiredScopes: required)
    }
}

extension ProviderUsageError {
    /// From a 429's Retry-After, the earliest a retry is worth making.
    public var retryAfter: Date? {
        guard case .rateLimited(let date) = self else { return nil }
        return date
    }
}

/// HTTP helpers shared by the provider fetchers.
public enum ProviderUsageHTTP {

    /// `Retry-After` as a future date: either delta-seconds or an HTTP-date.
    public static func retryAfterDate(from response: HTTPURLResponse, now: Date = Date()) -> Date? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty
        else { return nil }
        if let seconds = TimeInterval(raw), seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return formatter.date(from: raw)
    }

    /// ISO8601 with or without fractional seconds (the Claude endpoint emits
    /// both over time).
    public static func parseISO8601(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    /// Percent (0…100, possibly out of range from a quirky backend) → 0…1.
    public static func fraction(fromPercent percent: Double?) -> Double? {
        guard let percent else { return nil }
        return min(100, max(0, percent)) / 100
    }
}
