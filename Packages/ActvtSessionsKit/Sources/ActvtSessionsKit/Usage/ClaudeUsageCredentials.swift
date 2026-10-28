//
//  ClaudeUsageCredentials.swift
//  ActvtSessionsKit
//

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
#if canImport(Security)
import Security
#endif

/// Read-only access to the credential Claude Code itself uses on this
/// machine, shared by the app and `actvt-cli`. Writing (token refresh) is the
/// app's alone, and only ever touches the stores.
///
/// Claude Code's own order, which this follows exactly:
/// 1. a setup token from the environment: `CLAUDE_CODE_OAUTH_TOKEN`, else the
///    file descriptor named by `CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR`;
/// 2. the login keychain (generic password, service "Claude Code-credentials";
///    macOS only);
/// 3. `~/.claude/.credentials.json`.
/// The keychain is canonical on macOS and the file is often absent there; a
/// Linux host only ever has the file.
///
/// A usage figure claims to be the quota of the account the agents are
/// working in, so the reader is pinned to the credential Claude Code would
/// pick in the same environment, never to some other token that could belong
/// to a different account. Where a setup token is set, Claude Code runs on it
/// whatever the stores hold, so it wins here too.
///
/// A setup token is scoped to `user:inference` and can't read the usage
/// endpoint (`user:profile`), so it is returned as its own case: its reading
/// comes from rate-limit headers instead (`ClaudeRateLimitHeaders`).
public enum ClaudeUsageCredentials {

    public struct Credentials: Equatable, Sendable {
        public let accessToken: String
        public let expiresAt: Date?
        /// Display name for the subscription ("Max 20x", "Pro"), or nil when
        /// the blob doesn't say. The usage endpoint never reports a plan for
        /// Claude, so this is the only place the name exists.
        public let planLabel: String?

        public init(accessToken: String, expiresAt: Date?, planLabel: String? = nil) {
            self.accessToken = accessToken
            self.expiresAt = expiresAt
            self.planLabel = planLabel
        }

        /// 30s of margin so a token that dies mid-request counts as expired.
        /// A source that carries no expiry (a setup token) is never "expired"
        /// here. Only the endpoint can say, via a 401.
        public func isExpired(now: Date = Date()) -> Bool {
            guard let expiresAt else { return false }
            return expiresAt.timeIntervalSince(now) <= 30
        }
    }

    /// Where Claude Code keeps the file copy of its credentials.
    public static func fileURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent(".claude/.credentials.json")
    }

    public enum Source: Equatable, Sendable {
        case keychain
        case file
    }

    public enum ReadResult: Equatable, Sendable {
        /// `source` lets the caller record that keychain consent was granted
        /// (background polls may then read it without an unexpected prompt).
        case found(Credentials, source: Source)
        /// A store was readable but its access token has expired. That is a
        /// refreshable state, not a signed out one, so the caller offers
        /// "Refresh token" rather than telling a signed-in user to run
        /// `/login`.
        ///
        /// It carries its `source` for the same reason `found` does: reaching
        /// the keychain at all means consent was granted, and a caller that
        /// cannot record that will have to ask for it again on the next launch.
        case stale(source: Source)
        /// Claude Code runs on a setup token from its environment. It has no
        /// store, no expiry and no plan name, and nothing may refresh it.
        case setupToken(String)
        /// No store yielded anything, expired or otherwise.
        case notPresent
        /// The keychain item exists but the user declined access (and no
        /// readable fallback exists). Retrying re-prompts, so the caller
        /// persists this and stops asking.
        case accessDenied
    }

    /// The service name Claude Code stores its OAuth blob under.
    public static let keychainService = "Claude Code-credentials"

    /// Resolve a usable access token from the first store that has one.
    ///
    /// `allowKeychain: false` skips the keychain entirely, so callers control
    /// when the one-time system consent prompt can appear.
    public static func read(
        allowKeychain: Bool,
        env: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ReadResult {
        if let token = setupToken(env: env) { return .setupToken(token) }
        let blob = cliBlob(allowKeychain: allowKeychain, home: home)
        if let credentials = blob.credentials, let source = blob.source, !credentials.isExpired() {
            return .found(credentials, source: source)
        }
        if blob.denied { return .accessDenied }
        if let source = blob.source { return .stale(source: source) }
        return .notPresent
    }

    // MARK: - Setup token

    /// The setup token Claude Code would run on in `env`, or nil.
    ///
    /// The descriptor is read only when it is a pipe or a regular file, and at
    /// most 4 KB of it: an agent's shell inherits the variable from the
    /// `claude` that consumed the token at launch, and its fd may by then be
    /// closed, drained, or something else entirely. Anything but a token there
    /// reads as no token, so Claude Code's fallback to the stores applies.
    static func setupToken(env: [String: String]) -> String? {
        if let token = env["CLAUDE_CODE_OAUTH_TOKEN"].flatMap(nonEmpty) { return token }
        guard let raw = env["CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR"],
              let fd = Int32(raw.trimmingCharacters(in: .whitespaces)), fd >= 0
        else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        let type = info.st_mode & mode_t(S_IFMT)
        guard type == mode_t(S_IFIFO) || type == mode_t(S_IFREG) else { return nil }

        var bytes = [UInt8](repeating: 0, count: 4_096)
        var count = 0
        while count < bytes.count {
            let n = bytes.withUnsafeMutableBufferPointer {
                readDescriptor(fd, $0.baseAddress! + count, $0.count - count)
            }
            guard n > 0 else { break }
            count += n
        }
        return nonEmpty(String(decoding: bytes[..<count], as: UTF8.self))
    }

    private static func nonEmpty(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - CLI credential stores

    private struct CLIBlob {
        var credentials: Credentials?
        var source: Source?
        var denied = false
    }

    /// The keychain item, else the credentials file. Returned even when the
    /// token inside has expired, because the blob still carries the plan name
    /// and tells the caller the difference between "stale" and "absent".
    private static func cliBlob(allowKeychain: Bool, home: URL) -> CLIBlob {
        var result = CLIBlob()
        #if canImport(Security)
        if allowKeychain {
            switch readKeychain() {
            case .success(let data):
                if let credentials = parse(data) {
                    result.credentials = credentials
                    result.source = .keychain
                    return result
                }
            case .denied:
                result.denied = true
            case .notFound:
                break
            }
        }
        #endif
        let fileURL = fileURL(home: home)
        if let data = try? Data(contentsOf: fileURL), let credentials = parse(data) {
            result.credentials = credentials
            result.source = .file
        }
        return result
    }

    // MARK: - Keychain (macOS: legacy keychain, foreign service)

    #if canImport(Security)
    public enum KeychainRead: Sendable {
        case success(Data)
        case notFound
        case denied
    }

    /// Deliberately does NOT set `kSecUseDataProtectionKeychain`: Claude
    /// Code's item lives in the legacy file-based keychain, unlike the app's
    /// own `com.actvt.io.*` items. First access triggers the system
    /// "Actvt wants to use your keychain" consent dialog.
    public static func readKeychain() -> KeychainRead {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return .notFound }
            return .success(data)
        case errSecItemNotFound:
            return .notFound
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            return .denied
        default:
            return .notFound
        }
    }
    #endif

    // MARK: - Parsing (pure, fixture-testable)

    /// Decodes `{ "claudeAiOauth": { "accessToken": …, "expiresAt": <epoch ms> } }`.
    /// `expiresAt` is epoch milliseconds; tolerate seconds defensively since
    /// the format is another app's private storage.
    ///
    /// nil when there is no token, including a blob whose token is an empty
    /// string: that is what a signed-out Claude Code leaves behind, scopes and
    /// plan intact, so it must read as signed out rather than as a token.
    public static func parse(_ data: Data) -> Credentials? {
        guard let blob = try? JSONDecoder().decode(Blob.self, from: data),
              let token = blob.claudeAiOauth?.accessToken, !token.isEmpty
        else { return nil }
        return Credentials(
            accessToken: token,
            expiresAt: blob.claudeAiOauth?.expiresAt.map(epochDate),
            planLabel: planLabel(
                subscriptionType: blob.claudeAiOauth?.subscriptionType,
                rateLimitTier: blob.claudeAiOauth?.rateLimitTier
            )
        )
    }

    /// `("max", "default_claude_max_20x")` → `"Max 20x"`; `("pro", nil)` →
    /// `"Pro"`; unknown or absent → nil.
    ///
    /// The subscription type is the name; the rate-limit tier only ever adds
    /// the multiplier Anthropic markets the Max tiers by. Anything the tier
    /// string doesn't match is ignored rather than guessed at, since this is
    /// another app's private storage and unversioned.
    public static func planLabel(subscriptionType: String?, rateLimitTier: String?) -> String? {
        let raw = (subscriptionType ?? "").trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        let name = raw.prefix(1).uppercased() + raw.dropFirst().lowercased()

        guard let tier = rateLimitTier,
              let match = tier.range(of: #"_(\d+)x$"#, options: .regularExpression)
        else { return name }
        let multiplier = tier[match].dropFirst()
        return "\(name) \(multiplier)"
    }

    /// Epoch ms vs s disambiguated by magnitude (1e11 s ≈ year 5138).
    private static func epochDate(_ raw: Double) -> Date {
        Date(timeIntervalSince1970: raw > 1e11 ? raw / 1000 : raw)
    }

    private struct Blob: Decodable {
        let claudeAiOauth: OAuth?

        struct OAuth: Decodable {
            let accessToken: String?
            let expiresAt: Double?
            let subscriptionType: String?
            let rateLimitTier: String?
        }
    }
}

/// `read(2)`, out of reach of `ClaudeUsageCredentials.read`'s shadow.
private func readDescriptor(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
    read(fd, buffer, count)
}
