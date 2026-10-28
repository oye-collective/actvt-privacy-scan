//
//  ClaudeRateLimitHeadersTests.swift
//  ActvtSessionsKitTests
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ActvtSessionsKit

/// The plan windows read from a subscription response's rate-limit headers
/// (oye-collective/actvt-macos#38).
final class ClaudeRateLimitHeadersTests: XCTestCase {

    /// The block captured on dgx on 2026-10-07 with a setup token.
    private let captured: [String: String] = [
        "anthropic-ratelimit-unified-status": "allowed",
        "anthropic-ratelimit-unified-representative-claim": "five_hour",
        "anthropic-ratelimit-unified-reset": "1791379200",
        "anthropic-ratelimit-unified-5h-status": "allowed",
        "anthropic-ratelimit-unified-5h-utilization": "0.2",
        "anthropic-ratelimit-unified-5h-reset": "1791379200",
        "anthropic-ratelimit-unified-7d-status": "allowed",
        "anthropic-ratelimit-unified-7d-utilization": "0.62",
        "anthropic-ratelimit-unified-7d-reset": "1791748800",
        "anthropic-ratelimit-unified-fallback-percentage": "0.5",
        "anthropic-ratelimit-unified-overage-status": "rejected",
        "anthropic-ratelimit-unified-overage-disabled-reason": "org_level_disabled",
    ]

    private func response(_ headers: [String: String], status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.anthropic.com/v1/messages")!,
                        statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    func testTheCapturedBlockGivesBothWindows() throws {
        let parsed = try XCTUnwrap(ClaudeRateLimitHeaders.parse(response(captured)))
        XCTAssertEqual(parsed.session, .init(usedFraction: 0.2,
                                             resetsAt: Date(timeIntervalSince1970: 1_791_379_200),
                                             windowSeconds: 18_000))
        XCTAssertEqual(parsed.weekly, .init(usedFraction: 0.62,
                                            resetsAt: Date(timeIntervalSince1970: 1_791_748_800),
                                            windowSeconds: 604_800))
    }

    /// HTTP header names are case-insensitive, and proxies change case.
    func testHeaderCaseDoesNotMatter() throws {
        let upper = Dictionary(uniqueKeysWithValues: captured.map { ($0.key.uppercased(), $0.value) })
        XCTAssertEqual(ClaudeRateLimitHeaders.parse(response(upper)),
                       ClaudeRateLimitHeaders.parse(response(captured)))
    }

    func testAResponseWithoutTheHeadersIsNoReading() {
        XCTAssertNil(ClaudeRateLimitHeaders.parse(response(["content-type": "application/json"])))
    }

    /// One malformed window leaves its sibling intact.
    func testAMalformedWindowIsDroppedAlone() throws {
        var headers = captured
        headers["anthropic-ratelimit-unified-5h-utilization"] = "twenty"
        let parsed = try XCTUnwrap(ClaudeRateLimitHeaders.parse(response(headers)))
        XCTAssertNil(parsed.session)
        XCTAssertEqual(parsed.weekly?.usedFraction, 0.62)
    }

    func testAWindowWithoutAResetKeepsItsReading() throws {
        var headers = captured
        headers["anthropic-ratelimit-unified-7d-reset"] = nil
        let parsed = try XCTUnwrap(ClaudeRateLimitHeaders.parse(response(headers)))
        XCTAssertEqual(parsed.weekly?.usedFraction, 0.62)
        XCTAssertNil(parsed.weekly?.resetsAt)
    }

    /// At the limit the call itself is refused, and the headers still say
    /// how full the window is: the reading a pause decision needs most.
    func testARefusedCallStillReportsTheFullWindow() throws {
        var headers = captured
        headers["anthropic-ratelimit-unified-5h-status"] = "rejected"
        headers["anthropic-ratelimit-unified-5h-utilization"] = "1.0"
        let parsed = try XCTUnwrap(ClaudeRateLimitHeaders.parse(response(headers, status: 429)))
        XCTAssertEqual(parsed.session?.usedFraction, 1.0)
    }
}
