//
//  ClaudeUsageFetcher.swift
//  ActvtSessionsKit
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `GET https://api.anthropic.com/api/oauth/usage` — the endpoint Claude
/// Code's own `/usage` command reads. It is unofficial and unversioned, so
/// every field is optional and unknown keys are ignored: shape drift degrades
/// to missing bars, never a throw. Windows carry `utilization` (percent used)
/// and `resets_at` (ISO8601).
public enum ClaudeUsageFetcher {

    public struct Parsed: Equatable, Sendable {
        public var session: ProviderUsageSnapshot.Window?
        public var weekly: ProviderUsageSnapshot.Window?
        public var perModel: [ProviderUsageSnapshot.Window]
        public var credits: ProviderUsageSnapshot.Credits?
    }

    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    public static func request(accessToken: String) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // The endpoint currently requires the OAuth beta header.
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        // Expects a Claude Code client UA; identify ourselves alongside.
        request.setValue("claude-cli/2.1.0 (external, actvt)", forHTTPHeaderField: "User-Agent")
        return request
    }

    public static func fetch(accessToken: String, session: URLSession) async throws -> Parsed {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request(accessToken: accessToken))
        } catch {
            throw ProviderUsageError.transport
        }
        guard let http = response as? HTTPURLResponse else { throw ProviderUsageError.transport }
        switch http.statusCode {
        case 200...299:
            return try parse(data)
        case 401, 403:
            if let required = scopeRequirement(data) {
                throw ProviderUsageError.insufficientScope(requiredScopes: required)
            }
            throw ProviderUsageError.needsAuth
        case 429:
            throw ProviderUsageError.rateLimited(retryAfter: ProviderUsageHTTP.retryAfterDate(from: http))
        default:
            throw ProviderUsageError.transport
        }
    }

    // MARK: - Parsing (pure, fixture-testable)

    /// The scopes a 403 says the token is missing, or `nil` when the rejection
    /// is anything else.
    ///
    /// The endpoint answers a scope-poor token with
    /// `{"error":{"details":{"error_code":"oauth_scope_insufficient",
    /// "required_scopes":["user:profile"]}}}`. Recognising it is what separates
    /// "your token expired" from "this token can never read usage": advice that
    /// points in opposite directions.
    public static func scopeRequirement(_ data: Data) -> [String]? {
        guard let root = try? JSONDecoder().decode(ScopeErrorRoot.self, from: data),
              let details = root.error?.details,
              details.errorCode == "oauth_scope_insufficient"
        else { return nil }
        return details.requiredScopes ?? []
    }

    private struct ScopeErrorRoot: Decodable {
        let error: ErrorBody?

        struct ErrorBody: Decodable {
            let details: Details?

            struct Details: Decodable {
                let errorCode: String?
                let requiredScopes: [String]?

                private enum CodingKeys: String, CodingKey {
                    case errorCode = "error_code"
                    case requiredScopes = "required_scopes"
                }
            }
        }
    }

    public static func parse(_ data: Data) throws -> Parsed {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let root = try? decoder.decode(Root.self, from: data) else {
            throw ProviderUsageError.transport
        }
        let legacyPerModel: [ProviderUsageSnapshot.Window] = [
            window(root.sevenDayOpus, label: "Opus", windowSeconds: Self.sevenDays),
            window(root.sevenDaySonnet, label: "Sonnet", windowSeconds: Self.sevenDays),
        ].compactMap { $0 }
        let fromLimits = limitWindows(root.limits)

        // `limits` is the newer representation and the only one that still
        // carries per-model usage: the flat `seven_day_opus`/`seven_day_sonnet`
        // keys are now returned as null. Prefer it per lane rather than
        // wholesale, so a payload that drops the array keeps working.
        return Parsed(
            session: fromLimits.session ?? window(root.fiveHour, windowSeconds: 5 * 3_600),
            weekly: fromLimits.weekly ?? window(root.sevenDay, windowSeconds: Self.sevenDays),
            perModel: fromLimits.perModel.isEmpty ? legacyPerModel : fromLimits.perModel,
            credits: credits(spend: root.spend, extraUsage: root.extraUsage)
        )
    }

    private static let sevenDays = 7.0 * 86_400

    // MARK: - `limits`

    private struct LimitWindows {
        var session: ProviderUsageSnapshot.Window?
        var weekly: ProviderUsageSnapshot.Window?
        var perModel: [ProviderUsageSnapshot.Window] = []
    }

    /// Fan the `limits` array out into the three lanes the app draws.
    ///
    /// Entries are matched on `kind`, with `group` as the fallback for a
    /// session lane whose kind we don't recognise. A `weekly_scoped` entry is
    /// only useful when it names the model it scopes to, so unnamed ones are
    /// dropped rather than drawn as an anonymous bar.
    private static func limitWindows(_ limits: [LimitDTO]?) -> LimitWindows {
        guard let limits else { return LimitWindows() }
        var result = LimitWindows()
        for limit in limits {
            guard let fraction = ProviderUsageHTTP.fraction(fromPercent: limit.percent) else { continue }
            let resetsAt = ProviderUsageHTTP.parseISO8601(limit.resetsAt)

            switch limit.kind {
            case "session":
                result.session = .init(label: nil, usedFraction: fraction,
                                       resetsAt: resetsAt, windowSeconds: 5 * 3_600)
            case "weekly_all":
                result.weekly = .init(label: nil, usedFraction: fraction,
                                      resetsAt: resetsAt, windowSeconds: sevenDays)
            case "weekly_scoped":
                guard let name = limit.scope?.model?.displayName?
                    .trimmingCharacters(in: .whitespaces), !name.isEmpty
                else { continue }
                result.perModel.append(.init(label: name, usedFraction: fraction,
                                             resetsAt: resetsAt, windowSeconds: sevenDays))
            default:
                // An unknown kind in the session group is still a session bar.
                if limit.group == "session", result.session == nil {
                    result.session = .init(label: nil, usedFraction: fraction,
                                           resetsAt: resetsAt, windowSeconds: 5 * 3_600)
                }
            }
        }
        return result
    }

    // MARK: - Credits

    /// `spend` is the modern block and carries currency and exponent, so it
    /// wins. `extra_usage` is its older twin reporting the same numbers as
    /// bare USD cents, and only stands in when `spend` is absent.
    private static func credits(
        spend: SpendDTO?, extraUsage: ExtraUsageDTO?
    ) -> ProviderUsageSnapshot.Credits? {
        if let spend, let used = spend.used, let limit = spend.limit,
           let usedMinor = used.amountMinor, let limitMinor = limit.amountMinor {
            return .init(
                usedMinor: usedMinor,
                limitMinor: limitMinor,
                currency: used.currency ?? "USD",
                exponent: used.exponent ?? 2,
                enabled: spend.enabled ?? true,
                limitReached: extraUsage?.spendLimitReached ?? false
            )
        }
        guard let extraUsage,
              let limit = extraUsage.monthlyLimit,
              let used = extraUsage.usedCredits
        else { return nil }
        return .init(
            usedMinor: Int(used.rounded()),
            limitMinor: Int(limit.rounded()),
            currency: extraUsage.currency ?? "USD",
            exponent: extraUsage.decimalPlaces ?? 2,
            enabled: extraUsage.isEnabled ?? true,
            limitReached: extraUsage.spendLimitReached ?? false
        )
    }

    private static func window(
        _ dto: WindowDTO?, label: String? = nil, windowSeconds: Double
    ) -> ProviderUsageSnapshot.Window? {
        guard let dto, let fraction = ProviderUsageHTTP.fraction(fromPercent: dto.utilization)
        else { return nil }
        return ProviderUsageSnapshot.Window(
            label: label,
            usedFraction: fraction,
            resetsAt: ProviderUsageHTTP.parseISO8601(dto.resetsAt),
            windowSeconds: windowSeconds
        )
    }

    /// One malformed window must not discard its valid siblings, hence the
    /// per-key `try?` instead of synthesized decoding.
    private struct Root: Decodable {
        let fiveHour: WindowDTO?
        let sevenDay: WindowDTO?
        let sevenDayOpus: WindowDTO?
        let sevenDaySonnet: WindowDTO?
        let limits: [LimitDTO]?
        let spend: SpendDTO?
        let extraUsage: ExtraUsageDTO?

        private enum CodingKeys: String, CodingKey {
            case fiveHour, sevenDay, sevenDayOpus, sevenDaySonnet
            case limits, spend, extraUsage
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            fiveHour = try? container.decodeIfPresent(WindowDTO.self, forKey: .fiveHour)
            sevenDay = try? container.decodeIfPresent(WindowDTO.self, forKey: .sevenDay)
            sevenDayOpus = try? container.decodeIfPresent(WindowDTO.self, forKey: .sevenDayOpus)
            sevenDaySonnet = try? container.decodeIfPresent(WindowDTO.self, forKey: .sevenDaySonnet)
            limits = try? container.decodeIfPresent([LimitDTO].self, forKey: .limits)
            spend = try? container.decodeIfPresent(SpendDTO.self, forKey: .spend)
            extraUsage = try? container.decodeIfPresent(ExtraUsageDTO.self, forKey: .extraUsage)
        }
    }

    private struct WindowDTO: Decodable {
        let utilization: Double?
        let resetsAt: String?
    }

    private struct LimitDTO: Decodable {
        let kind: String?
        let group: String?
        let percent: Double?
        let resetsAt: String?
        let scope: Scope?

        struct Scope: Decodable {
            let model: Model?

            struct Model: Decodable {
                let id: String?
                let displayName: String?
            }
        }
    }

    private struct SpendDTO: Decodable {
        let used: Money?
        let limit: Money?
        let enabled: Bool?

        struct Money: Decodable {
            let amountMinor: Int?
            let currency: String?
            let exponent: Int?
        }
    }

    private struct ExtraUsageDTO: Decodable {
        let isEnabled: Bool?
        let monthlyLimit: Double?
        let usedCredits: Double?
        let currency: String?
        let decimalPlaces: Int?
        let spendLimitReached: Bool?
    }
}
