//
//  CodexUsageFetcher.swift
//  ActvtSessionsKit
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `GET https://chatgpt.com/backend-api/wham/usage` — the endpoint the Codex
/// CLI's own usage display reads. Unofficial and unversioned: every field is
/// optional and unknown keys are ignored, so shape drift degrades to missing
/// bars, never a throw. `primary_window` is the 5-hour session lane,
/// `secondary_window` the weekly one; windows carry `used_percent` and
/// `reset_at` (unix seconds).
public enum CodexUsageFetcher {

    public struct Parsed: Equatable, Sendable {
        public var planLabel: String?
        public var session: ProviderUsageSnapshot.Window?
        public var weekly: ProviderUsageSnapshot.Window?
        public var perModel: [ProviderUsageSnapshot.Window]
    }

    public static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    public static func request(accessToken: String, accountId: String?) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Actvt", forHTTPHeaderField: "User-Agent")
        if let accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        return request
    }

    public static func fetch(
        accessToken: String, accountId: String?, session: URLSession
    ) async throws -> Parsed {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(
                for: request(accessToken: accessToken, accountId: accountId))
        } catch {
            throw ProviderUsageError.transport
        }
        guard let http = response as? HTTPURLResponse else { throw ProviderUsageError.transport }
        switch http.statusCode {
        case 200...299:
            return try parse(data)
        case 401, 403:
            throw ProviderUsageError.needsAuth
        case 429:
            throw ProviderUsageError.rateLimited(retryAfter: ProviderUsageHTTP.retryAfterDate(from: http))
        default:
            throw ProviderUsageError.transport
        }
    }

    // MARK: - Parsing (pure, fixture-testable)

    public static func parse(_ data: Data) throws -> Parsed {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let root = try? decoder.decode(Root.self, from: data) else {
            throw ProviderUsageError.transport
        }
        // A named limit surfaces as one bar: its session (primary) window,
        // falling back to weekly, labeled with the limit's own name.
        let perModel: [ProviderUsageSnapshot.Window] = (root.additionalRateLimits ?? [])
            .compactMap { extra in
                guard let name = extra.limitName, !name.isEmpty else { return nil }
                let dto = extra.rateLimit?.primaryWindow ?? extra.rateLimit?.secondaryWindow
                return window(dto, label: name)
            }
        return Parsed(
            planLabel: planLabel(root.planType),
            session: window(root.rateLimit?.primaryWindow),
            weekly: window(root.rateLimit?.secondaryWindow),
            perModel: perModel
        )
    }

    /// Plan names the API runs together, which no formatting rule can split.
    private static let planNames = ["prolite": "Pro Lite"]

    /// "plus" → "Plus", "free_workspace" → "Free workspace", "prolite" →
    /// "Pro Lite"; nil/empty → nil.
    private static func planLabel(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        return planNames[raw.lowercased()]
            ?? raw.replacingOccurrences(of: "_", with: " ").capitalizedFirst
    }

    private static func window(
        _ dto: WindowDTO?, label: String? = nil
    ) -> ProviderUsageSnapshot.Window? {
        guard let dto, let fraction = ProviderUsageHTTP.fraction(fromPercent: dto.usedPercent)
        else { return nil }
        return ProviderUsageSnapshot.Window(
            label: label,
            usedFraction: fraction,
            resetsAt: dto.resetAt.map { Date(timeIntervalSince1970: $0) },
            windowSeconds: dto.limitWindowSeconds
        )
    }

    /// One malformed branch must not discard its valid siblings, hence the
    /// per-key `try?` instead of synthesized decoding.
    private struct Root: Decodable {
        let planType: String?
        let rateLimit: RateLimitDTO?
        let additionalRateLimits: [AdditionalRateLimitDTO]?

        private enum CodingKeys: String, CodingKey {
            case planType, rateLimit, additionalRateLimits
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            planType = try? container.decodeIfPresent(String.self, forKey: .planType)
            rateLimit = try? container.decodeIfPresent(RateLimitDTO.self, forKey: .rateLimit)
            additionalRateLimits = try? container.decodeIfPresent(
                [AdditionalRateLimitDTO].self, forKey: .additionalRateLimits)
        }
    }

    private struct RateLimitDTO: Decodable {
        let primaryWindow: WindowDTO?
        let secondaryWindow: WindowDTO?

        private enum CodingKeys: String, CodingKey {
            case primaryWindow, secondaryWindow
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            primaryWindow = try? container.decodeIfPresent(WindowDTO.self, forKey: .primaryWindow)
            secondaryWindow = try? container.decodeIfPresent(WindowDTO.self, forKey: .secondaryWindow)
        }
    }

    private struct AdditionalRateLimitDTO: Decodable {
        let limitName: String?
        let rateLimit: RateLimitDTO?

        private enum CodingKeys: String, CodingKey {
            case limitName, rateLimit
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            limitName = try? container.decodeIfPresent(String.self, forKey: .limitName)
            rateLimit = try? container.decodeIfPresent(RateLimitDTO.self, forKey: .rateLimit)
        }
    }

    /// `used_percent` arrives as Int or Double depending on backend version;
    /// JSON numbers decode into `Double?` either way.
    private struct WindowDTO: Decodable {
        let usedPercent: Double?
        let resetAt: Double?
        let limitWindowSeconds: Double?
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first = first else { return self }
        return first.uppercased() + dropFirst()
    }
}
