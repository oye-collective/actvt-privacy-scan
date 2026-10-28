//
//  RemoteTranscriptPayloadTests.swift
//  ActvtSessionsKitTests
//

import XCTest
@testable import ActvtSessionsKit

/// Wire-format round-trip for the transcript payload: the CLI-side mapper,
/// JSON encode/decode, and the app-side mapper must reproduce the original
/// `AgentTranscript` exactly — and degrade (skip, never fail) on content from
/// a newer CLI.
final class RemoteTranscriptPayloadTests: XCTestCase {

    private let ts = Date(timeIntervalSince1970: 1_800_000_000.5)

    private var fullTranscript: AgentTranscript {
        AgentTranscript(
            sessionId: "sess-1",
            agentKind: .claudeCode,
            projectPath: "/Users/x/proj",
            turns: [
                .user(recordUUID: "u1", text: "hello", timestamp: ts),
                .assistant(recordUUID: "a1", blocks: [
                    .text("hi there"),
                    .thinking("pondering…"),
                    .toolUse(id: "t1", name: "Bash", input: "{\"command\":\"ls\"}"),
                ], timestamp: ts.addingTimeInterval(1)),
                .systemNotification(recordUUID: "actvt-transcript-truncated",
                                    text: "truncated", timestamp: ts.addingTimeInterval(2)),
            ],
            toolResultsByID: [
                "t1": ToolResult(content: "file.txt", isError: false),
                "t2": ToolResult(content: "boom", isError: true),
            ]
        )
    }

    func testFullRoundTrip() throws {
        let payload = RemoteTranscriptPayload(
            cliVersion: CLIRunner.version, hostname: "box",
            generatedAt: ts, transcript: RemoteTranscript(fullTranscript)
        )
        let data = try RemoteSessionPayload.makeEncoder().encode(payload)
        let decoded = try RemoteSessionPayload.makeDecoder()
            .decode(RemoteTranscriptPayload.self, from: data)

        XCTAssertEqual(decoded, payload, "wire representation must survive encode/decode")
        XCTAssertEqual(decoded.transcript.agentTranscript(), fullTranscript,
                       "mapped-back transcript must equal the original, fractional dates included")
    }

    func testUnknownRoleAndBlockTypeAreSkippedNotFailed() throws {
        // A newer CLI adds a role and a block type this app doesn't know.
        let wire = RemoteTranscript(
            sessionId: "s", agentKind: "claudeCode", projectPath: "/p",
            turns: [
                RemoteTranscriptTurn(role: "user", recordUUID: "u1", timestamp: ts,
                                     text: "kept", blocks: nil),
                RemoteTranscriptTurn(role: "hologram", recordUUID: "h1", timestamp: ts,
                                     text: "dropped", blocks: nil),
                RemoteTranscriptTurn(role: "assistant", recordUUID: "a1", timestamp: ts,
                                     text: nil, blocks: [
                                         RemoteAssistantBlock(type: "text", text: "kept block"),
                                         RemoteAssistantBlock(type: "quantumUse", text: "dropped block"),
                                     ]),
            ],
            toolResults: [:]
        )
        let transcript = try XCTUnwrap(wire.agentTranscript())
        XCTAssertEqual(transcript.turns.count, 2, "unknown role is skipped")
        guard case .assistant(_, let blocks, _) = transcript.turns[1] else {
            return XCTFail("expected assistant turn")
        }
        XCTAssertEqual(blocks, [.text("kept block")], "unknown block type is skipped")
    }

    func testUnknownAgentKindMapsToNil() {
        let wire = RemoteTranscript(
            sessionId: "s", agentKind: "futureAgent", projectPath: "/p",
            turns: [], toolResults: [:]
        )
        XCTAssertNil(wire.agentTranscript())
    }

    func testSessionSummaryMapping() {
        let session = RemoteAgentSession(
            id: "sess-1", agentKind: "claudeCode", projectPath: "/p", title: "T",
            aiTitle: "AI T", startedAt: ts, lastUpdatedAt: ts.addingTimeInterval(9),
            messageCount: 4, gitBranch: "main", subagentCount: 2
        )
        let summary = session.sessionSummary
        XCTAssertEqual(summary?.agentKind, .claudeCode)
        XCTAssertEqual(summary?.title, "T")
        XCTAssertEqual(summary?.aiTitle, "AI T")
        XCTAssertEqual(summary?.gitBranch, "main")
        XCTAssertEqual(summary?.subagentCount, 2)

        let unknown = RemoteAgentSession(
            id: "x", agentKind: "futureAgent", projectPath: "/p", title: "t",
            aiTitle: nil, startedAt: ts, lastUpdatedAt: ts,
            messageCount: 0, gitBranch: nil, subagentCount: 0
        )
        XCTAssertNil(unknown.sessionSummary)
    }
}
