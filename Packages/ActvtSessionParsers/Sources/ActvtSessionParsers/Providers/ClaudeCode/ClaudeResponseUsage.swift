//
//  ClaudeResponseUsage.swift
//  ActvtSessionParsers
//
//  What one Claude Code API response used, counted once per session. This is
//  the single definition behind the app's spend index (`ClaudeMetricsExtractor`)
//  and `actvt-cli usage-records`, which carries the same records from a remote
//  host to the Mac. Tokens only: pricing stays in the app.
//

import Foundation

public struct ClaudeResponseUsage: Sendable, Hashable, Codable {
    /// The API response (`message.id`). `nil` on older transcripts, whose
    /// records each count as they come.
    public let responseID: String?
    /// The record that opened the response.
    public let recordUUID: String
    public let timestamp: Date
    /// `nil` when the transcript names no model, or names a placeholder such as
    /// `<synthetic>` (a locally generated turn, e.g. an API-error notice).
    public let model: String?
    /// The work of a subagent: a record in `subagents/*.jsonl`, or one Claude
    /// Code marked `isSidechain` in the session's own file.
    public let subagent: Bool
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let cacheCreate5m: Int64
    public let cacheCreate1h: Int64
    public let cacheRead: Int64
    public let webSearchRequests: Int64
    public let webFetchRequests: Int64
    public let serviceTier: String?

    public init(
        responseID: String?, recordUUID: String, timestamp: Date, model: String?, subagent: Bool,
        inputTokens: Int64, outputTokens: Int64, cacheCreate5m: Int64, cacheCreate1h: Int64, cacheRead: Int64,
        webSearchRequests: Int64 = 0, webFetchRequests: Int64 = 0, serviceTier: String? = nil
    ) {
        self.responseID = responseID
        self.recordUUID = recordUUID
        self.timestamp = timestamp
        self.model = model
        self.subagent = subagent
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreate5m = cacheCreate5m
        self.cacheCreate1h = cacheCreate1h
        self.cacheRead = cacheRead
        self.webSearchRequests = webSearchRequests
        self.webFetchRequests = webFetchRequests
        self.serviceTier = serviceTier
    }

    /// Whether a model name is a Claude Code placeholder rather than a model
    /// that was called.
    public static func isPlaceholderModel(_ model: String) -> Bool {
        model.hasPrefix("<") && model.hasSuffix(">")
    }
}

/// Counts each response once across every file of one session. Claude Code
/// writes one record per content block of a response, each repeating the
/// response's usage, and a subagent's transcript opens by replaying the
/// parent's Task call under the parent's message id: that response was spent
/// once.
public struct ClaudeResponseCounter: Sendable {
    /// Responses counted so far in this session.
    public private(set) var counted: Set<String> = []

    public init() {}

    /// Whether this record opens a response not yet counted. Records with no
    /// response id (older transcripts, non-assistant records) count as they come.
    public mutating func opensResponse(_ record: ClaudeTranscriptParser.ParsedRecord) -> Bool {
        guard let id = record.responseID else { return true }
        return counted.insert(id).inserted
    }

    /// The usage a record contributes: present only on the assistant record
    /// that opens its response and carries `usage`. Call once per record, in
    /// file order; `subagentTranscript` is true for a file under `subagents/`.
    public mutating func usage(
        of record: ClaudeTranscriptParser.ParsedRecord, subagentTranscript: Bool
    ) -> ClaudeResponseUsage? {
        let opens = opensResponse(record)
        return opens ? Self.usage(of: record, subagentTranscript: subagentTranscript) : nil
    }

    /// The record's usage, without counting it: for a caller that already
    /// decided, through `opensResponse`, that this record opens its response.
    public static func usage(
        of record: ClaudeTranscriptParser.ParsedRecord, subagentTranscript: Bool
    ) -> ClaudeResponseUsage? {
        guard case let .assistant(uuid, _, timestamp, isSidechain, meta) = record,
              let usage = meta.usage else { return nil }
        return ClaudeResponseUsage(
            responseID: meta.messageID,
            recordUUID: uuid,
            timestamp: timestamp,
            model: meta.model.flatMap { ClaudeResponseUsage.isPlaceholderModel($0) ? nil : $0 },
            subagent: subagentTranscript || isSidechain,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            cacheCreate5m: usage.cacheCreate5m,
            cacheCreate1h: usage.cacheCreate1h,
            cacheRead: usage.cacheRead,
            webSearchRequests: usage.webSearchRequests,
            webFetchRequests: usage.webFetchRequests,
            serviceTier: usage.serviceTier
        )
    }
}

extension ClaudeTranscriptParser.ParsedRecord {
    /// Whether Claude Code marked this record as a subagent's.
    public var isSidechain: Bool {
        switch self {
        case let .userText(_, _, _, _, _, isSidechain),
             let .userToolResults(_, _, _, isSidechain),
             let .assistant(_, _, _, isSidechain, _),
             let .memorySources(_, _, _, isSidechain):
            return isSidechain
        case .systemNotification, .aiTitle:
            return false
        }
    }

    /// The API response an assistant record is part of.
    public var responseID: String? {
        guard case let .assistant(_, _, _, _, meta) = self else { return nil }
        return meta.messageID
    }
}

extension ClaudeProjectsLocator {
    /// A session's transcript files in the order its usage is counted: its own
    /// file, then each subagent transcript under `<sessionId>/subagents/`.
    public static func usageFiles(of session: DiscoveredSession, root: URL = defaultProjectsURL)
        -> (main: URL, subagents: [URL])
    {
        let dir = sidecarDirectory(for: session, root: root).appendingPathComponent("subagents", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []
        return (session.fileURL, entries.filter { $0.pathExtension == "jsonl" })
    }

    /// Every response a session used, each once, in file order.
    ///
    /// Only assistant records carry a response or its usage, and every other
    /// record leaves the counter as it was, so a line without the bytes
    /// `"assistant"` is skipped before it is decoded. The quoted word can't
    /// occur inside an escaped JSON string, so no assistant record is missed.
    /// Tool results and attachments are ~90% of a transcript's bytes (dgx,
    /// T-045), and decoding them was most of the cost.
    public static func responseUsage(of session: DiscoveredSession, root: URL = defaultProjectsURL) throws
        -> [ClaudeResponseUsage]
    {
        let files = usageFiles(of: session, root: root)
        var counter = ClaudeResponseCounter()
        var out: [ClaudeResponseUsage] = []
        for (url, subagent) in [(files.main, false)] + files.subagents.map({ ($0, true) }) {
            do {
                try AgentTranscriptLineReader.forEachLine(in: url) { data in
                    guard data.range(of: assistantMarker) != nil,
                          let line = ClaudeTranscriptParser.parse(data),
                          let usage = counter.usage(of: line.record, subagentTranscript: subagent) else { return }
                    out.append(usage)
                }
            } catch where subagent {
                continue   // as the index does: an unreadable subagent file adds nothing
            }
        }
        return out
    }

    private static let assistantMarker = Data(#""assistant""#.utf8)
}
