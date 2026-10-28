//
//  RemoteUsagePayload.swift
//  ActvtSessionsKit
//

import Foundation

/// Versioned wire format emitted by `actvt-cli usage --json`: the plan usage
/// of the agent CLIs signed in on the host it runs on.
///
/// Each provider carries the same `ProviderUsageSnapshot` the app draws its
/// usage cards from, so a window means the same thing on both sides. It holds
/// percentages, reset times and plan names only. Never a token.
public struct RemoteUsagePayload: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let cliVersion: String
    public let hostname: String
    public let generatedAt: Date
    /// One entry per agent CLI set up on this host. A provider whose CLI has
    /// never been set up here (no `~/.claude`, no Codex home) is absent rather
    /// than reported as signed out.
    public let providers: [RemoteProviderUsage]

    public init(
        schemaVersion: Int = RemoteUsagePayload.currentSchemaVersion,
        cliVersion: String,
        hostname: String,
        generatedAt: Date,
        providers: [RemoteProviderUsage]
    ) {
        self.schemaVersion = schemaVersion
        self.cliVersion = cliVersion
        self.hostname = hostname
        self.generatedAt = generatedAt
        self.providers = providers
    }
}

public struct RemoteProviderUsage: Codable, Sendable, Equatable {
    /// `usage.state` says whether the windows are current. When it is
    /// `needsAuth`, `authHint` says which of the different fixes applies:
    /// - absent: sign in again;
    /// - `staleStoredToken`: the stored token has aged out, and running the
    ///   agent CLI refreshes it;
    /// - `insufficientScope`: the token is the wrong kind (a setup token), so
    ///   signing in the same way again changes nothing;
    /// - `keychainUnavailable`: on a Mac, the login keychain could not be read
    ///   (it is locked over ssh), so nothing is known about the sign-in.
    public let usage: ProviderUsageSnapshot
    public let authHint: String?
    public let requiredScopes: [String]?
    /// After a 429, the earliest a retry is worth making.
    public let retryAfter: Date?

    public static let keychainUnavailable = "keychainUnavailable"

    public init(
        usage: ProviderUsageSnapshot,
        authHint: String?,
        requiredScopes: [String]? = nil,
        retryAfter: Date? = nil
    ) {
        self.usage = usage
        self.authHint = authHint
        self.requiredScopes = requiredScopes
        self.retryAfter = retryAfter
    }

    public init(
        usage: ProviderUsageSnapshot,
        authHint: ClaudeAuthHint = .none,
        retryAfter: Date? = nil
    ) {
        switch authHint {
        case .none:
            self.init(usage: usage, authHint: nil, retryAfter: retryAfter)
        case .staleStoredToken:
            self.init(usage: usage, authHint: "staleStoredToken", retryAfter: retryAfter)
        case .insufficientScope(let required):
            self.init(usage: usage, authHint: "insufficientScope",
                      requiredScopes: required, retryAfter: retryAfter)
        }
    }
}
