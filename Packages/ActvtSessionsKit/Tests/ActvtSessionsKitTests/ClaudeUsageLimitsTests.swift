//
//  ClaudeUsageLimitsTests.swift
//  ActvtSessionsKitTests
//

import XCTest
@testable import ActvtSessionsKit

/// The Claude usage endpoint's newer `limits` array, its `spend` block, and
/// the plan name that only the credential blob knows.
///
/// The endpoint grew a second representation without removing the first: the
/// flat `seven_day_opus`/`seven_day_sonnet` keys are still present but now
/// return null, and per-model usage moved into `limits` as `weekly_scoped`
/// entries. These pin that migration, including the fallback that keeps the
/// old shape working if the array ever disappears again.
final class ClaudeUsageLimitsTests: XCTestCase {

    /// Trimmed from a real response, with the null legacy keys kept exactly as
    /// the endpoint returns them.
    private let liveShape = """
    {
      "five_hour": { "utilization": 8.0, "resets_at": "2026-08-05T20:10:00.478647+00:00" },
      "seven_day": { "utilization": 62.0, "resets_at": "2026-08-09T20:00:00.478719+00:00" },
      "seven_day_opus": null,
      "seven_day_sonnet": null,
      "tangelo": null,
      "extra_usage": {
        "is_enabled": true, "monthly_limit": 15000, "used_credits": 0.0,
        "currency": "USD", "decimal_places": 2, "spend_limit_reached": false
      },
      "limits": [
        { "kind": "session", "group": "session", "percent": 8,
          "resets_at": "2026-08-05T20:10:00.478647+00:00", "scope": null },
        { "kind": "weekly_all", "group": "weekly", "percent": 62,
          "resets_at": "2026-08-09T20:00:00.478719+00:00", "scope": null },
        { "kind": "weekly_scoped", "group": "weekly", "percent": 40,
          "resets_at": "2026-08-09T19:59:59.479108+00:00",
          "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null } }
      ],
      "spend": {
        "used": { "amount_minor": 250, "currency": "USD", "exponent": 2 },
        "limit": { "amount_minor": 15000, "currency": "USD", "exponent": 2 },
        "enabled": true
      }
    }
    """

    // MARK: - limits

    func testFableArrivesAsAPerModelWindow() throws {
        let parsed = try ClaudeUsageFetcher.parse(Data(liveShape.utf8))
        XCTAssertEqual(parsed.perModel.map(\.label), ["Fable"])
        XCTAssertEqual(parsed.perModel[0].usedFraction, 0.40, accuracy: 0.0001)
        XCTAssertEqual(parsed.perModel[0].windowSeconds, 7 * 86_400)
    }

    /// The legacy per-model keys are null in the live response, so without the
    /// `limits` path there would be no per-model bars at all.
    func testNullLegacyModelKeysNoLongerProduceWindows() throws {
        let json = """
        { "seven_day_opus": null, "seven_day_sonnet": null }
        """
        let parsed = try ClaudeUsageFetcher.parse(Data(json.utf8))
        XCTAssertTrue(parsed.perModel.isEmpty)
    }

    func testSessionAndWeeklyComeFromLimits() throws {
        let parsed = try ClaudeUsageFetcher.parse(Data(liveShape.utf8))
        XCTAssertEqual(try XCTUnwrap(parsed.session).usedFraction, 0.08, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(parsed.session).windowSeconds, 5 * 3_600)
        XCTAssertEqual(try XCTUnwrap(parsed.weekly).usedFraction, 0.62, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(parsed.weekly).windowSeconds, 7 * 86_400)
    }

    /// `limits` wins per lane, not wholesale: a response carrying only the old
    /// keys must still draw its bars.
    func testFlatKeysStillWorkWhenLimitsIsAbsent() throws {
        let json = """
        {
          "five_hour": { "utilization": 10, "resets_at": "2026-08-05T20:10:00Z" },
          "seven_day": { "utilization": 20, "resets_at": "2026-08-09T20:00:00Z" },
          "seven_day_opus": { "utilization": 30, "resets_at": "2026-08-09T20:00:00Z" }
        }
        """
        let parsed = try ClaudeUsageFetcher.parse(Data(json.utf8))
        XCTAssertEqual(try XCTUnwrap(parsed.session).usedFraction, 0.10, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(parsed.weekly).usedFraction, 0.20, accuracy: 0.0001)
        XCTAssertEqual(parsed.perModel.map(\.label), ["Opus"])
    }

    /// An empty array must not shadow usable flat keys.
    func testAnEmptyLimitsArrayFallsBackToFlatKeys() throws {
        let json = """
        {
          "five_hour": { "utilization": 10, "resets_at": "2026-08-05T20:10:00Z" },
          "seven_day_sonnet": { "utilization": 5, "resets_at": "2026-08-09T20:00:00Z" },
          "limits": []
        }
        """
        let parsed = try ClaudeUsageFetcher.parse(Data(json.utf8))
        XCTAssertEqual(try XCTUnwrap(parsed.session).usedFraction, 0.10, accuracy: 0.0001)
        XCTAssertEqual(parsed.perModel.map(\.label), ["Sonnet"])
    }

    /// A scoped limit with no model name can't be labelled, and an unlabelled
    /// per-model bar tells the user nothing.
    func testAnUnnamedScopedLimitIsDropped() throws {
        let json = """
        { "limits": [
            { "kind": "weekly_scoped", "group": "weekly", "percent": 12, "scope": null },
            { "kind": "weekly_scoped", "group": "weekly", "percent": 13,
              "scope": { "model": { "display_name": "  " } } }
        ] }
        """
        let parsed = try ClaudeUsageFetcher.parse(Data(json.utf8))
        XCTAssertTrue(parsed.perModel.isEmpty)
    }

    func testALimitWithNoPercentIsSkipped() throws {
        let json = """
        { "limits": [ { "kind": "weekly_scoped", "scope": { "model": { "display_name": "Fable" } } } ] }
        """
        let parsed = try ClaudeUsageFetcher.parse(Data(json.utf8))
        XCTAssertTrue(parsed.perModel.isEmpty)
    }

    /// A kind we don't know yet, in the session group, is still a session bar.
    func testAnUnknownKindInTheSessionGroupStillFillsTheSessionLane() throws {
        let json = """
        { "limits": [ { "kind": "five_hour_v2", "group": "session", "percent": 44 } ] }
        """
        let parsed = try ClaudeUsageFetcher.parse(Data(json.utf8))
        XCTAssertEqual(try XCTUnwrap(parsed.session).usedFraction, 0.44, accuracy: 0.0001)
    }

    func testSeveralScopedModelsAllAppear() throws {
        let json = """
        { "limits": [
            { "kind": "weekly_scoped", "percent": 10, "scope": { "model": { "display_name": "Fable" } } },
            { "kind": "weekly_scoped", "percent": 20, "scope": { "model": { "display_name": "Opus" } } }
        ] }
        """
        let parsed = try ClaudeUsageFetcher.parse(Data(json.utf8))
        XCTAssertEqual(parsed.perModel.map(\.label), ["Fable", "Opus"])
    }

    // MARK: - Credits

    func testSpendBecomesCredits() throws {
        let parsed = try ClaudeUsageFetcher.parse(Data(liveShape.utf8))
        let credits = try XCTUnwrap(parsed.credits)
        XCTAssertEqual(credits.usedMinor, 250)
        XCTAssertEqual(credits.limitMinor, 15_000)
        XCTAssertEqual(credits.currency, "USD")
        XCTAssertTrue(credits.enabled)
        XCTAssertFalse(credits.limitReached)
        XCTAssertEqual(credits.usedFraction, 250.0 / 15_000, accuracy: 0.0001)
        XCTAssertEqual(credits.usedMajor, Decimal(string: "2.50"))
        XCTAssertEqual(credits.limitMajor, Decimal(string: "150"))
    }

    /// `extra_usage` is the older twin of `spend` and stands in when the newer
    /// block is missing.
    func testExtraUsageStandsInWhenSpendIsAbsent() throws {
        let json = """
        { "extra_usage": {
            "is_enabled": true, "monthly_limit": 15000, "used_credits": 500.0,
            "currency": "USD", "decimal_places": 2, "spend_limit_reached": true
        } }
        """
        let parsed = try ClaudeUsageFetcher.parse(Data(json.utf8))
        let credits = try XCTUnwrap(parsed.credits)
        XCTAssertEqual(credits.usedMinor, 500)
        XCTAssertEqual(credits.limitMinor, 15_000)
        XCTAssertTrue(credits.limitReached)
    }

    func testNoSpendBlockMeansNoCredits() throws {
        let parsed = try ClaudeUsageFetcher.parse(Data(#"{ "five_hour": null }"#.utf8))
        XCTAssertNil(parsed.credits)
    }

    /// A zero limit must not divide by zero when the bar is drawn.
    func testAZeroLimitIsNotADivideByZero() {
        let credits = ProviderUsageSnapshot.Credits(
            usedMinor: 0, limitMinor: 0, currency: "USD",
            exponent: 2, enabled: true, limitReached: false)
        XCTAssertEqual(credits.usedFraction, 0)
    }

    // MARK: - Cache compatibility

    /// Every existing install has a snapshot cache written before `credits`
    /// existed. Decoding must not throw, or the Overview loses its bars on
    /// first launch after the update.
    func testACacheWrittenBeforeCreditsStillDecodes() throws {
        let json = """
        [{
          "providerRaw": "claudeCode",
          "state": "ok",
          "session": { "windowSeconds": 18000, "resetsAt": 807653400.641, "usedFraction": 0.08 },
          "weekly": { "windowSeconds": 604800, "resetsAt": 807998400.641, "usedFraction": 0.62 },
          "perModel": [],
          "fetchedAt": 807638597.282736
        }]
        """
        let decoded = try JSONDecoder().decode([ProviderUsageSnapshot].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertNil(decoded[0].credits)
        XCTAssertEqual(try XCTUnwrap(decoded[0].session).usedFraction, 0.08, accuracy: 0.0001)
    }

    func testACacheCarryingCreditsRoundTrips() throws {
        let snapshot = ProviderUsageSnapshot(
            providerRaw: "claudeCode",
            state: .ok,
            planLabel: "Max 20x",
            credits: .init(usedMinor: 250, limitMinor: 15_000, currency: "USD",
                           exponent: 2, enabled: true, limitReached: false),
            fetchedAt: Date(timeIntervalSince1970: 1_750_000_000))
        let data = try JSONEncoder().encode([snapshot])
        XCTAssertEqual(try JSONDecoder().decode([ProviderUsageSnapshot].self, from: data), [snapshot])
    }

    // MARK: - Plan label

    /// The one the user actually reported: Max showing as nothing (and the
    /// Codex card's "Free" being mistaken for Claude's).
    func testMaxPlanIsNamedWithItsMultiplier() {
        XCTAssertEqual(
            ClaudeUsageCredentials.planLabel(
                subscriptionType: "max", rateLimitTier: "default_claude_max_20x"),
            "Max 20x")
    }

    func testPlanWithoutAMultiplierIsJustItsName() {
        XCTAssertEqual(
            ClaudeUsageCredentials.planLabel(subscriptionType: "pro", rateLimitTier: nil),
            "Pro")
        XCTAssertEqual(
            ClaudeUsageCredentials.planLabel(
                subscriptionType: "pro", rateLimitTier: "default_claude_pro"),
            "Pro")
    }

    func testNoSubscriptionTypeMeansNoLabel() {
        XCTAssertNil(ClaudeUsageCredentials.planLabel(subscriptionType: nil, rateLimitTier: nil))
        XCTAssertNil(ClaudeUsageCredentials.planLabel(
            subscriptionType: "  ", rateLimitTier: "default_claude_max_20x"))
    }

    func testPlanLabelIsReadFromTheCredentialBlob() throws {
        let json = """
        { "claudeAiOauth": {
            "accessToken": "tok", "expiresAt": 1785973233943,
            "subscriptionType": "max", "rateLimitTier": "default_claude_max_20x"
        } }
        """
        let credentials = try XCTUnwrap(ClaudeUsageCredentials.parse(Data(json.utf8)))
        XCTAssertEqual(credentials.planLabel, "Max 20x")
    }

    func testACredentialBlobWithoutAPlanStillParses() throws {
        let json = #"{ "claudeAiOauth": { "accessToken": "tok" } }"#
        let credentials = try XCTUnwrap(ClaudeUsageCredentials.parse(Data(json.utf8)))
        XCTAssertNil(credentials.planLabel)
    }

    // MARK: - Scope rejection

    /// Verbatim body the endpoint returns for a `claude setup-token` value
    /// (captured from a real 403 on 2026-09-01). A setup token authenticates
    /// fine and drives the CLI, but carries `user:inference` without
    /// `user:profile`, so it can never read usage.
    func testSetupTokenScopeRejectionIsRecognised() throws {
        let body = """
        {"type":"error","error":{"type":"permission_error","message":"OAuth token does not \
        meet scope requirement user:profile","details":{"required_scopes":["user:profile"],\
        "match":"any","error_visibility":"user_facing","error_code":"oauth_scope_insufficient"}},\
        "request_id":"req_test"}
        """
        let required = try XCTUnwrap(ClaudeUsageFetcher.scopeRequirement(Data(body.utf8)))
        XCTAssertEqual(required, ["user:profile"])
    }

    func testOrdinaryAuthFailureIsNotMistakenForAScopeProblem() {
        // Re-authenticating fixes an expired token and does nothing for a scope
        // gap, so conflating the two would send the user in the wrong direction.
        let body = #"{"type":"error","error":{"type":"authentication_error","message":"invalid"}}"#
        XCTAssertNil(ClaudeUsageFetcher.scopeRequirement(Data(body.utf8)))
        XCTAssertNil(ClaudeUsageFetcher.scopeRequirement(Data("not json".utf8)))
    }
}
