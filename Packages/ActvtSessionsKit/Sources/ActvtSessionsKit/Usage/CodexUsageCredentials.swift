//
//  CodexUsageCredentials.swift
//  ActvtSessionsKit
//

import Foundation

/// Read-only access to the Codex CLI's stored OAuth credentials
/// (`$CODEX_HOME/auth.json`, default `~/.codex/auth.json`), used solely to
/// call the usage endpoint. We never refresh or write back — the CLI owns
/// the credential lifecycle; an expired token surfaces as "re-authenticate".
public enum CodexUsageCredentials {

    public struct Credentials: Equatable, Sendable {
        public let accessToken: String
        public let accountId: String?
        /// From the JWT `exp` claim when parseable; nil lets the 401 decide.
        public let expiresAt: Date?

        public func isExpired(now: Date = Date()) -> Bool {
            guard let expiresAt else { return false }
            return expiresAt.timeIntervalSince(now) <= 30
        }
    }

    public static func authFileURL(
        env: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let codexHome = env["CODEX_HOME"]?.trimmingCharacters(in: .whitespaces)
        let root = (codexHome?.isEmpty == false)
            ? URL(fileURLWithPath: codexHome!)
            : home.appendingPathComponent(".codex")
        return root.appendingPathComponent("auth.json")
    }

    /// nil when the file is missing or holds no usable token — the provider
    /// then simply has no card.
    public static func read(
        env: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Credentials? {
        guard let data = try? Data(contentsOf: authFileURL(env: env, home: home)) else { return nil }
        return parse(data)
    }

    // MARK: - Parsing (pure, fixture-testable)

    /// Decodes `{ "tokens": { "access_token": …, "account_id": … } }`,
    /// tolerating the camelCase variants older CLI versions wrote.
    public static func parse(_ data: Data) -> Credentials? {
        guard let blob = try? JSONDecoder().decode(Blob.self, from: data),
              let token = blob.tokens?.accessToken ?? blob.tokens?.accessTokenCamel,
              !token.isEmpty
        else { return nil }
        return Credentials(
            accessToken: token,
            accountId: blob.tokens?.accountId ?? blob.tokens?.accountIdCamel,
            expiresAt: jwtExpiry(token)
        )
    }

    /// The access token is a JWT; its `exp` claim lets us skip a guaranteed
    /// 401 round-trip. Purely best-effort — any parse failure returns nil.
    public static func jwtExpiry(_ token: String) -> Date? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONDecoder().decode(JWTPayload.self, from: data),
              let exp = payload.exp
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    private struct JWTPayload: Decodable {
        let exp: Double?
    }

    private struct Blob: Decodable {
        let tokens: Tokens?

        struct Tokens: Decodable {
            let accessToken: String?
            let accessTokenCamel: String?
            let accountId: String?
            let accountIdCamel: String?

            private enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case accessTokenCamel = "accessToken"
                case accountId = "account_id"
                case accountIdCamel = "accountId"
            }
        }
    }
}
