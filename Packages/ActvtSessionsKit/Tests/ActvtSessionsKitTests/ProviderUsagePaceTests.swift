//
//  ProviderUsagePaceTests.swift
//  ActvtSessionsKitTests
//

import XCTest
@testable import ActvtSessionsKit

/// The even-pace reading on a plan-limit window (T-019): how much of the
/// window's time has gone, and whether the allowance is going faster. A
/// measurement of the clock, so every case pins `now`.
final class ProviderUsagePaceTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let fiveHours: Double = 5 * 3_600

    private func window(used: Double, resetsIn: Double?, length: Double?) -> ProviderUsageSnapshot.Window {
        ProviderUsageSnapshot.Window(
            usedFraction: used,
            resetsAt: resetsIn.map { now.addingTimeInterval($0) },
            windowSeconds: length)
    }

    func testElapsedShareIsTheTimeGoneInTheWindow() throws {
        // 4 hours left of 5: a fifth of the window has gone.
        let elapsed = try XCTUnwrap(window(used: 0.1, resetsIn: 4 * 3_600, length: fiveHours).elapsedFraction(at: now))
        XCTAssertEqual(elapsed, 0.2, accuracy: 1e-9)
    }

    func testNoReadingWithoutAResetTimeOrALength() {
        XCTAssertNil(window(used: 0.6, resetsIn: nil, length: fiveHours).elapsedFraction(at: now))
        XCTAssertNil(window(used: 0.6, resetsIn: 3_600, length: nil).elapsedFraction(at: now))
        XCTAssertNil(window(used: 0.6, resetsIn: 3_600, length: 0).elapsedFraction(at: now))
        XCTAssertNil(window(used: 0.6, resetsIn: nil, length: fiveHours).pace(at: now))
    }

    func testElapsedShareStaysWithinTheBar() {
        // A reset time already passed (a stale snapshot), or further away than the window is long.
        XCTAssertEqual(window(used: 0.3, resetsIn: -600, length: fiveHours).elapsedFraction(at: now), 1)
        XCTAssertEqual(window(used: 0.3, resetsIn: 6 * 3_600, length: fiveHours).elapsedFraction(at: now), 0)
    }

    /// The issue's own example: 62% used with 30 minutes gone is too fast,
    /// 62% with 4 hours gone is fine.
    func testSixtyTwoPercentEarlyIsAheadAndLateIsOnPace() {
        XCTAssertEqual(window(used: 0.62, resetsIn: 4.5 * 3_600, length: fiveHours).pace(at: now), .ahead)
        XCTAssertEqual(window(used: 0.62, resetsIn: 1 * 3_600, length: fiveHours).pace(at: now), .onPace)
    }

    func testNoWarningWhileMoreThanHalfIsLeft() {
        // 40% used with a tenth of the time gone: past the tick, but most of the allowance remains.
        XCTAssertEqual(window(used: 0.4, resetsIn: 4.5 * 3_600, length: fiveHours).pace(at: now), .onPace)
        XCTAssertEqual(window(used: 0.5, resetsIn: 4.5 * 3_600, length: fiveHours).pace(at: now), .onPace)
    }

    func testASpentAllowanceHasNoPaceWord() {
        XCTAssertNil(window(used: 1, resetsIn: 4 * 3_600, length: fiveHours).pace(at: now))
    }
}
