//
//  ProviderUsageDecodingTests.swift
//  ActvtSessionsKitTests
//

import XCTest
@testable import ActvtSessionsKit

/// Fixture-driven tests for the provider usage-endpoint parsers. Both
/// endpoints are unofficial, so the contract under test is leniency: unknown
/// keys are ignored, missing windows yield nil (never a throw), and one
/// malformed branch can't discard its valid siblings.
final class ProviderUsageDecodingTests: XCTestCase {

    // MARK: - Claude

    func testClaudeFullResponse() throws {
        let json = """
        {
          "five_hour": { "utilization": 2.0, "resets_at": "2026-07-17T18:00:00.123Z" },
          "seven_day": { "utilization": 3, "resets_at": "2026-07-21T09:00:00Z" },
          "seven_day_opus": { "utilization": 12.5, "resets_at": "2026-07-21T09:00:00Z" },
          "seven_day_sonnet": { "utilization": 0, "resets_at": "2026-07-21T09:00:00Z" },
          "extra_usage": { "unknown_shape": true },
          "limits": [ { "scope": { "model": { "display_name": "Fable" } } } ]
        }
        """
        let parsed = try ClaudeUsageFetcher.parse(Data(json.utf8))

        let session = try XCTUnwrap(parsed.session)
        XCTAssertEqual(session.usedFraction, 0.02, accuracy: 0.0001)
        let expectedReset = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-17T18:00:00Z"))
        // Fractional-seconds variant parses; compare with float tolerance.
        XCTAssertEqual(
            try XCTUnwrap(session.resetsAt).timeIntervalSince1970,
            expectedReset.timeIntervalSince1970 + 0.123,
            accuracy: 0.01)

        // Integer utilization decodes like a Double.
        XCTAssertEqual(try XCTUnwrap(parsed.weekly).usedFraction, 0.03, accuracy: 0.0001)

        XCTAssertEqual(parsed.perModel.map(\.label), ["Opus", "Sonnet"])
        XCTAssertEqual(parsed.perModel[0].usedFraction, 0.125, accuracy: 0.0001)
        // 0% is a real window, not an absent one.
        XCTAssertEqual(parsed.perModel[1].usedFraction, 0)
    }

    func testClaudeMinimalResponse() throws {
        let parsed = try ClaudeUsageFetcher.parse(
            Data(#"{ "five_hour": { "utilization": 50, "resets_at": null } }"#.utf8))
        XCTAssertEqual(parsed.session?.usedFraction, 0.5)
        XCTAssertNil(parsed.session?.resetsAt)
        XCTAssertNil(parsed.weekly)
        XCTAssertTrue(parsed.perModel.isEmpty)
    }

    func testClaudeEmptyObjectYieldsNoWindows() throws {
        let parsed = try ClaudeUsageFetcher.parse(Data("{}".utf8))
        XCTAssertNil(parsed.session)
        XCTAssertNil(parsed.weekly)
        XCTAssertTrue(parsed.perModel.isEmpty)
    }

    func testClaudeMalformedWindowKeepsSiblings() throws {
        let json = """
        {
          "five_hour": "not an object",
          "seven_day": { "utilization": 10, "resets_at": "2026-07-21T09:00:00Z" }
        }
        """
        let parsed = try ClaudeUsageFetcher.parse(Data(json.utf8))
        XCTAssertNil(parsed.session)
        XCTAssertEqual(parsed.weekly?.usedFraction, 0.1)
    }

    func testClaudeUtilizationClamped() throws {
        let parsed = try ClaudeUsageFetcher.parse(
            Data(#"{ "five_hour": { "utilization": 250 } }"#.utf8))
        XCTAssertEqual(parsed.session?.usedFraction, 1.0)
    }

    func testClaudeNonJSONThrows() {
        XCTAssertThrowsError(try ClaudeUsageFetcher.parse(Data("<html>".utf8)))
    }

    // MARK: - Codex

    func testCodexFullResponse() throws {
        let json = """
        {
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": { "used_percent": 2, "reset_at": 1750014780, "limit_window_seconds": 18000 },
            "secondary_window": { "used_percent": 3.5, "reset_at": 1750291200, "limit_window_seconds": 604800 }
          },
          "credits": { "balance": "unknown shape" },
          "additional_rate_limits": [
            {
              "limit_name": "GPT-5.3-Codex-Spark",
              "metered_feature": "spark",
              "rate_limit": { "primary_window": { "used_percent": 40, "reset_at": 1750014780 } }
            }
          ]
        }
        """
        let parsed = try CodexUsageFetcher.parse(Data(json.utf8))

        XCTAssertEqual(parsed.planLabel, "Pro")
        let session = try XCTUnwrap(parsed.session)
        XCTAssertEqual(session.usedFraction, 0.02, accuracy: 0.0001)
        XCTAssertEqual(session.resetsAt, Date(timeIntervalSince1970: 1_750_014_780))
        XCTAssertEqual(session.cadence, .session)
        // Fractional used_percent decodes too.
        let weekly = try XCTUnwrap(parsed.weekly)
        XCTAssertEqual(weekly.usedFraction, 0.035, accuracy: 0.0001)
        XCTAssertEqual(weekly.cadence, .weekly)

        XCTAssertEqual(parsed.perModel.count, 1)
        XCTAssertEqual(parsed.perModel[0].label, "GPT-5.3-Codex-Spark")
        XCTAssertEqual(parsed.perModel[0].usedFraction, 0.4, accuracy: 0.0001)
    }

    func testCodexFreePlanMonthlyPrimaryWindow() throws {
        // Live-verified shape (2026-07): the free plan reports a single
        // 30-day primary window and no secondary — the row must read
        // "Monthly", not "Session".
        let json = """
        {
          "plan_type": "free",
          "rate_limit": {
            "primary_window": { "used_percent": 88, "reset_at": 1784973093, "limit_window_seconds": 2592000 }
          }
        }
        """
        let parsed = try CodexUsageFetcher.parse(Data(json.utf8))
        XCTAssertEqual(parsed.planLabel, "Free")
        XCTAssertEqual(parsed.session?.cadence, .monthly)
        XCTAssertNil(parsed.weekly)
    }

    func testCodexMissingSecondaryWindow() throws {
        let json = """
        { "rate_limit": { "primary_window": { "used_percent": 9 } } }
        """
        let parsed = try CodexUsageFetcher.parse(Data(json.utf8))
        XCTAssertEqual(parsed.session?.usedFraction, 0.09)
        XCTAssertNil(parsed.session?.resetsAt)
        XCTAssertNil(parsed.weekly)
        XCTAssertNil(parsed.planLabel)
    }

    func testCodexPlanLabelFormatting() throws {
        let parsed = try CodexUsageFetcher.parse(
            Data(#"{ "plan_type": "free_workspace" }"#.utf8))
        XCTAssertEqual(parsed.planLabel, "Free workspace")
    }

    func testCodexRunTogetherPlanNameIsSpelledOut() throws {
        let parsed = try CodexUsageFetcher.parse(Data(#"{ "plan_type": "prolite" }"#.utf8))
        XCTAssertEqual(parsed.planLabel, "Pro Lite")
    }

    func testCodexEmptyObjectYieldsNothing() throws {
        let parsed = try CodexUsageFetcher.parse(Data("{}".utf8))
        XCTAssertNil(parsed.session)
        XCTAssertNil(parsed.weekly)
        XCTAssertNil(parsed.planLabel)
        XCTAssertTrue(parsed.perModel.isEmpty)
    }

    func testCodexMalformedAdditionalLimitsKeepPrimary() throws {
        let json = """
        {
          "rate_limit": { "primary_window": { "used_percent": 5 } },
          "additional_rate_limits": "not an array"
        }
        """
        let parsed = try CodexUsageFetcher.parse(Data(json.utf8))
        XCTAssertEqual(parsed.session?.usedFraction, 0.05)
        XCTAssertTrue(parsed.perModel.isEmpty)
    }

    // MARK: - Snapshot cache round-trip

    func testSnapshotCacheRoundTrip() throws {
        let snapshot = ProviderUsageSnapshot(
            providerRaw: "claudeCode",
            state: .rateLimited,
            planLabel: "Pro",
            session: .init(label: nil, usedFraction: 0.02,
                           resetsAt: Date(timeIntervalSince1970: 1_750_014_780),
                           windowSeconds: 5 * 3_600),
            weekly: .init(label: nil, usedFraction: 0.03, resetsAt: nil,
                          windowSeconds: 7 * 86_400),
            perModel: [.init(label: "Opus", usedFraction: 0.125, resetsAt: nil)],
            fetchedAt: Date(timeIntervalSince1970: 1_750_000_000))
        let data = try JSONEncoder().encode([snapshot])
        let decoded = try JSONDecoder().decode([ProviderUsageSnapshot].self, from: data)
        XCTAssertEqual(decoded, [snapshot])
        XCTAssertEqual(decoded[0].kind, .claudeCode)
    }
}
