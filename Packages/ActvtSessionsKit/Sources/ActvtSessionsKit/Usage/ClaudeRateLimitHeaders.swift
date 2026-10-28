//
//  ClaudeRateLimitHeaders.swift
//  ActvtSessionsKit
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The plan windows a subscription inference response reports in its
/// `anthropic-ratelimit-unified-*` headers: the only usage reading open to a
/// setup token, which can't read the usage endpoint (`user:inference` only).
///
/// The headers are undocumented, so each window is read on its own and a
/// missing or malformed one is nil, never a guess. Utilisation is already a
/// fraction (`0.2` = 20 %) and resets are epoch seconds. Verified on dgx,
/// 2026-10-07 (oye-collective/actvt-macos#38).
public enum ClaudeRateLimitHeaders {

    public struct Parsed: Equatable, Sendable {
        public var session: ProviderUsageSnapshot.Window?
        public var weekly: ProviderUsageSnapshot.Window?
    }

    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// The smallest inference call there is: one short message to the
    /// cheapest model, one output token. It spends a few tokens of the plan
    /// it reports, which is the price of a reading.
    public static func request(setupToken: String) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(setupToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-cli/2.1.0 (external, actvt)", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data("""
            {"model":"claude-haiku-4-5-20251001","max_tokens":1,\
            "messages":[{"role":"user","content":"."}]}
            """.utf8)
        return request
    }

    /// The windows a setup token's plan reports. A refused call at the limit
    /// (429) still carries them, and that is the reading that matters most.
    public static func fetch(setupToken: String, session: URLSession) async throws -> Parsed {
        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request(setupToken: setupToken))
        } catch {
            throw ProviderUsageError.transport
        }
        guard let http = response as? HTTPURLResponse else { throw ProviderUsageError.transport }
        switch http.statusCode {
        case 200...299, 429:
            if let parsed = parse(http) { return parsed }
            if http.statusCode == 429 {
                throw ProviderUsageError.rateLimited(retryAfter: ProviderUsageHTTP.retryAfterDate(from: http))
            }
            // Answered, but not by a subscription: nothing to report.
            throw ProviderUsageError.transport
        case 401, 403:
            throw ProviderUsageError.needsAuth
        default:
            throw ProviderUsageError.transport
        }
    }

    /// nil when the response carries neither window, which means it didn't
    /// come from a subscription at all.
    public static func parse(_ header: (String) -> String?) -> Parsed? {
        let parsed = Parsed(
            session: window(header, prefix: "5h", windowSeconds: 5 * 3_600),
            weekly: window(header, prefix: "7d", windowSeconds: 7 * 86_400)
        )
        guard parsed.session != nil || parsed.weekly != nil else { return nil }
        return parsed
    }

    public static func parse(_ response: HTTPURLResponse) -> Parsed? {
        parse { response.value(forHTTPHeaderField: $0) }
    }

    private static func window(
        _ header: (String) -> String?, prefix: String, windowSeconds: Double
    ) -> ProviderUsageSnapshot.Window? {
        let base = "anthropic-ratelimit-unified-\(prefix)-"
        guard let raw = header(base + "utilization"),
              let fraction = Double(raw.trimmingCharacters(in: .whitespaces)),
              fraction.isFinite, fraction >= 0
        else { return nil }
        let reset = header(base + "reset")
            .flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            .map { Date(timeIntervalSince1970: $0) }
        return ProviderUsageSnapshot.Window(
            label: nil, usedFraction: min(fraction, 1), resetsAt: reset, windowSeconds: windowSeconds)
    }
}
