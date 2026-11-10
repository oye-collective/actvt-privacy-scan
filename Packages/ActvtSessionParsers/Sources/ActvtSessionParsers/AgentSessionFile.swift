//
//  AgentSessionFile.swift
//  ActvtSessionParsers
//

import Foundation

/// Which agent wrote a transcript file, told from its records rather than
/// from where it sits, so a copy or an export is recognized as readily as a
/// file in the agent's own folder.
public enum AgentSessionFile {

    /// The agent whose format the file at `url` is in, from its first records
    /// the parsers recognize; nil when none of the first `maxLines` lines is
    /// one. Codex records carry a `payload`, a pi session opens with its
    /// `session` header, and Claude Code records are typed `user`,
    /// `assistant` and so on, so no line passes two parsers.
    public static func kind(ofFileAt url: URL, maxLines: Int = 64) -> AgentKind? {
        var kind: AgentKind?
        var seen = 0
        try? AgentTranscriptLineReader.forEachLine(in: url) { data in
            seen += 1
            if CodexTranscriptParser.parseLine(data) != nil {
                kind = .codexCLI
            } else if case .header = PiTranscriptParser.parseLine(data) {
                kind = .pi
            } else if ClaudeTranscriptParser.parse(data) != nil {
                kind = .claudeCode
            }
            if kind != nil || seen >= maxLines { throw Stop() }
        }
        return kind
    }

    private struct Stop: Error {}
}
