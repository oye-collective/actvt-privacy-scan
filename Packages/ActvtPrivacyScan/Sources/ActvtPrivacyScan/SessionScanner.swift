//
//  SessionScanner.swift
//  ActvtPrivacyScan
//

import ActvtSessionParsers
import Foundation

/// Where in a session a text sits.
public enum TranscriptTextKind: String, Sendable, Hashable, Codable {
    case user
    case assistant
    case thinking
    case toolInput = "tool-input"
    case toolResult = "tool-result"
}

/// One text a person reads in a transcript.
public struct TranscriptText: Sendable, Hashable {
    public let kind: TranscriptTextKind
    /// When the turn holding it was written; nil for a tool result, which
    /// belongs to the tool call rather than to a turn of its own.
    public let timestamp: Date?
    /// The tool's name, for a tool input.
    public let tool: String?
    public let text: String
}

public extension AgentTranscript {
    /// Every text in this transcript a person reads: prompts, replies,
    /// thinking, what each tool was asked to do, and what it returned. System
    /// notifications are scaffolding, not user data (`participatesInPIIScan`).
    /// Record ids, signatures and attached image data are not text, so they
    /// are never read.
    var scannableTexts: [TranscriptText] {
        var texts: [TranscriptText] = []
        for turn in turns where turn.participatesInPIIScan {
            switch turn {
            case let .user(_, text, timestamp):
                texts.append(TranscriptText(kind: .user, timestamp: timestamp, tool: nil, text: text))
            case let .assistant(_, blocks, timestamp):
                for block in blocks {
                    switch block {
                    case let .text(text):
                        texts.append(TranscriptText(kind: .assistant, timestamp: timestamp, tool: nil, text: text))
                    case let .thinking(text):
                        texts.append(TranscriptText(kind: .thinking, timestamp: timestamp, tool: nil, text: text))
                    case let .toolUse(_, name, input):
                        texts.append(TranscriptText(kind: .toolInput, timestamp: timestamp, tool: name, text: input))
                    }
                }
            case .systemNotification:
                break
            }
        }
        for id in toolResultsByID.keys.sorted() {
            texts.append(TranscriptText(kind: .toolResult, timestamp: nil, tool: nil, text: toolResultsByID[id]!.content))
        }
        return texts.filter { !$0.text.isEmpty }
    }
}

/// One detection in a session. It never carries the detected value: only
/// where it is, what kind it is, and a preview too short to use.
public struct SessionFinding: Sendable, Hashable {
    public let agent: AgentKind
    public let sessionId: String
    public let projectPath: String
    /// The subagent whose transcript holds it; nil for the session's own thread.
    public let subagent: AgentSubagentRef?
    public let kind: TranscriptTextKind
    public let timestamp: Date?
    public let tool: String?
    public let category: PIICategory
    /// Length of the detected value, in characters.
    public let length: Int
    public let preview: String
    /// Hash of the detected value, so repeats of one secret can be counted
    /// without keeping it. Random per process; never printed.
    public let valueHash: Int
}

/// Scans agent sessions through the same providers and parsers the app uses,
/// a window at a time, so memory stays bounded however long a session is.
public struct SessionScanner: Sendable {

    private let detector: any PIIDetector

    public init(detector: any PIIDetector = RegexPIIDetector()) {
        self.detector = detector
    }

    /// Every finding in one session: its own thread, then each subagent's
    /// transcript, a person reads both.
    public func scan(_ ref: AgentSessionRef, from source: any AgentSessionSource) async throws -> [SessionFinding] {
        var findings = try await scan(agent: ref.agentKind, sessionId: ref.id, subagent: nil) {
            try await source.loadTranscript(id: ref.id, window: $0)
        }
        for subagent in try await source.listSubagents(of: ref.id) {
            findings += try await scan(agent: ref.agentKind, sessionId: ref.id, subagent: subagent) {
                try await source.loadTranscript(of: subagent, window: $0)
            }
        }
        return findings
    }

    /// Every finding in one transcript file wherever it lies, read by
    /// `source`, the agent whose format it is in (`AgentSessionFile`). The
    /// file stands alone, so its findings carry its name as the session.
    public func scan(fileAt url: URL, from source: any AgentSessionSource) async throws -> [SessionFinding] {
        try await scan(agent: source.kind, sessionId: url.deletingPathExtension().lastPathComponent, subagent: nil) {
            try await source.loadTranscript(fileAt: url, window: $0)
        }
    }

    /// One transcript's findings, newest window first. A record read in two
    /// windows is scanned once.
    private func scan(agent: AgentKind, sessionId: String, subagent: AgentSubagentRef?,
                      load: (TranscriptWindowRequest) async throws -> AgentTranscript) async throws -> [SessionFinding] {
        var findings: [SessionFinding] = []
        var seenRecords = Set<String>()
        var request = TranscriptWindowRequest.latest
        while true {
            let transcript = try await load(request)
            let fresh = AgentTranscript(
                sessionId: transcript.sessionId, agentKind: transcript.agentKind,
                projectPath: transcript.projectPath,
                turns: transcript.turns.filter { seenRecords.insert($0.recordUUID).inserted },
                toolResultsByID: transcript.toolResultsByID.filter { seenRecords.insert("result:" + $0.key).inserted })
            for text in fresh.scannableTexts {
                for span in try detector.scan(text.text) {
                    let value = String(text.text[span.range])
                    findings.append(SessionFinding(
                        agent: agent, sessionId: sessionId, projectPath: transcript.projectPath,
                        subagent: subagent, kind: text.kind, timestamp: text.timestamp, tool: text.tool, category: span.category,
                        length: value.count, preview: Self.preview(of: value), valueHash: value.hashValue))
                }
            }
            guard let window = transcript.window, window.hasEarlier else { break }
            request = .before(window.start)
        }
        return findings
    }

    /// What a finding shows of its value: the first four characters of a long
    /// value (enough to tell `sk-a` from `ghp_`), nothing of a short one, and
    /// never its end.
    public static func preview(of value: String) -> String {
        value.count >= 16 ? "\(value.prefix(4))… (\(value.count) chars)" : "… (\(value.count) chars)"
    }
}
