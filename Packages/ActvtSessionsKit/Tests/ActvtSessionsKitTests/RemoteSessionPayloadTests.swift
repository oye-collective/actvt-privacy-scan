//
//  RemoteSessionPayloadTests.swift
//  ActvtSessionsKitTests
//

import XCTest
@testable import ActvtSessionsKit

/// Wire-format guarantees: the payload must round-trip, pin its date format
/// (ISO-8601 fractional), and tolerate unknown agent kinds from newer CLIs.
final class RemoteSessionPayloadTests: XCTestCase {

    private func samplePayload() -> RemoteSessionPayload {
        // .5 is exactly representable in binary; .123 would truncate to .122
        // and the wire format is millisecond-precision anyway.
        RemoteSessionPayload(
            cliVersion: "0.1.0",
            hostname: "dgx-spark",
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000.5),
            sessions: [
                RemoteAgentSession(
                    id: "abc-123", agentKind: "claudeCode", projectPath: "/home/u/proj",
                    title: "Fix the tests", aiTitle: nil,
                    startedAt: Date(timeIntervalSince1970: 1_799_990_000),
                    lastUpdatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                    messageCount: 12, gitBranch: "main", subagentCount: 1
                ),
            ]
        )
    }

    func testRoundTrip() throws {
        let payload = samplePayload()
        let data = try RemoteSessionPayload.makeEncoder().encode(payload)
        let decoded = try RemoteSessionPayload.makeDecoder().decode(RemoteSessionPayload.self, from: data)
        XCTAssertEqual(decoded, payload)
    }

    func testDateFormatIsPinnedISO8601Fractional() throws {
        let data = try RemoteSessionPayload.makeEncoder().encode(samplePayload())
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains(#""generatedAt":"2027-01-15T08:00:00.500Z""#),
                      "date format drifted: \(json.prefix(300))")
    }

    func testDecoderToleratesNonFractionalDates() throws {
        let json = """
        {"schemaVersion":1,"cliVersion":"0.0.9","hostname":"h","generatedAt":"2027-01-15T08:00:00Z","sessions":[]}
        """
        let payload = try RemoteSessionPayload.makeDecoder().decode(RemoteSessionPayload.self, from: Data(json.utf8))
        XCTAssertEqual(payload.cliVersion, "0.0.9")
    }

    /// Every remote host in the wild runs 0.2.0, whose payload has no
    /// `pendingNotifications` key. If that failed to decode, shipping the
    /// feature would take remote sessions down on every host that hadn't
    /// updated the CLI yet.
    func testAPayloadFromACLIWithoutNotificationsStillDecodes() throws {
        let json = """
        {"schemaVersion":1,"cliVersion":"0.2.0","hostname":"h","generatedAt":"2027-01-15T08:00:00Z","sessions":[]}
        """
        let payload = try RemoteSessionPayload.makeDecoder()
            .decode(RemoteSessionPayload.self, from: Data(json.utf8))
        XCTAssertEqual(payload.cliVersion, "0.2.0")
        XCTAssertTrue(payload.pendingNotifications.isEmpty)
    }

    func testNotificationsRoundTripThroughThePayload() throws {
        let payload = RemoteSessionPayload(
            cliVersion: "0.3.0", hostname: "dgx", generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            sessions: [],
            pendingNotifications: [
                RemoteAgentNotification(
                    id: 7, kind: "needsInput", message: "Which branch?",
                    project: "actvt", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
            ])
        let data = try RemoteSessionPayload.makeEncoder().encode(payload)
        let decoded = try RemoteSessionPayload.makeDecoder()
            .decode(RemoteSessionPayload.self, from: data)
        XCTAssertEqual(decoded.pendingNotifications, payload.pendingNotifications)
    }

    /// The spool's sequence travels with the payload; a CLI that predates it
    /// sends none, which decodes as nil rather than failing the host (B-026).
    func testNotificationSequenceRoundTripsAndIsAbsentFromOlderCLIs() throws {
        let payload = RemoteSessionPayload(
            cliVersion: "0.8.0", hostname: "dgx", generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            sessions: [], notificationSequence: 12)
        let decoded = try RemoteSessionPayload.makeDecoder()
            .decode(RemoteSessionPayload.self, from: RemoteSessionPayload.makeEncoder().encode(payload))
        XCTAssertEqual(decoded.notificationSequence, 12)

        let json = """
        {"schemaVersion":1,"cliVersion":"0.7.0","hostname":"h","generatedAt":"2027-01-15T08:00:00Z","sessions":[]}
        """
        XCTAssertNil(try RemoteSessionPayload.makeDecoder()
            .decode(RemoteSessionPayload.self, from: Data(json.utf8)).notificationSequence)
    }

    /// A 0.4.0 CLI sends neither a session's `lastNotifiedAt` nor a
    /// notification's sender. Both must decode as absent, not fail the host.
    func testFieldsFromBefore050DecodeAsAbsent() throws {
        let json = """
        {"schemaVersion":1,"cliVersion":"0.4.0","hostname":"h","generatedAt":"2027-01-15T08:00:00Z",
         "sessions":[{"id":"s","agentKind":"claudeCode","projectPath":"/p","title":"t",
                      "startedAt":"2027-01-15T07:00:00Z","lastUpdatedAt":"2027-01-15T07:59:00Z",
                      "messageCount":3,"subagentCount":0}],
         "pendingNotifications":[{"id":1,"kind":"finished","message":"done",
                                  "createdAt":"2027-01-15T07:59:00Z"}]}
        """
        let payload = try RemoteSessionPayload.makeDecoder()
            .decode(RemoteSessionPayload.self, from: Data(json.utf8))
        XCTAssertNil(payload.sessions.first?.lastNotifiedAt)
        XCTAssertNil(payload.pendingNotifications.first?.sessionId)
        XCTAssertNil(payload.pendingNotifications.first?.agentKind)
    }

    func testSenderAndLastNotifiedRoundTrip() throws {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let payload = RemoteSessionPayload(
            cliVersion: "0.5.0", hostname: "dgx", generatedAt: at,
            sessions: [RemoteAgentSession(
                id: "s", agentKind: "pi", projectPath: "/p", title: "t", aiTitle: nil,
                startedAt: at, lastUpdatedAt: at, messageCount: 1, gitBranch: nil,
                subagentCount: 0, lastNotifiedAt: at)],
            pendingNotifications: [RemoteAgentNotification(
                id: 1, kind: "finished", message: "done", project: nil, createdAt: at,
                sessionId: "s", agentKind: "pi")])
        let data = try RemoteSessionPayload.makeEncoder().encode(payload)
        XCTAssertEqual(try RemoteSessionPayload.makeDecoder().decode(RemoteSessionPayload.self, from: data), payload)
    }

    func testUnknownAgentKindDecodesWithNilKind() throws {
        let session = RemoteAgentSession(
            id: "x", agentKind: "futureAgent2030", projectPath: "/p", title: "t",
            aiTitle: nil, startedAt: Date(), lastUpdatedAt: Date(),
            messageCount: 0, gitBranch: nil, subagentCount: 0
        )
        XCTAssertNil(session.kind, "unknown kinds must not fail decode — they render generic")
    }
}
