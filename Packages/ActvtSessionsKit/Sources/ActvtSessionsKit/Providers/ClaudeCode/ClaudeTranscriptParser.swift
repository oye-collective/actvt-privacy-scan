//
//  ClaudeTranscriptParser.swift
//  Actvt
//

import Foundation
#if canImport(os)
import os.log
#endif

/// Stateless line-by-line parser for Claude Code's JSONL session transcripts.
///
/// Narrow-at-the-seam: every field is type-checked before use; unknown record
/// types and malformed records are skipped silently. Mirrors VS Code's
/// `claudeReplayMapper.ts` parser semantics (per CONTEXT M7).
///
/// Record types currently surfaced:
/// - `user` / `assistant` / `system` → turns (with `isSidechain == true` filtered)
/// - `ai-title` → metadata only (used for summary title)
/// - `attachment` of type `instructions` / `nested_memory` → the memory
///   sources the agent loaded
/// Other types observed in real transcripts (`permission-mode`,
/// `file-history-snapshot`, other attachments, `last-prompt`, …) are silently
/// skipped.
public enum ClaudeTranscriptParser {

    // MARK: - Public parsed record type

    /// Discriminated union of replay-relevant record shapes. Everything else
    /// returns `nil` from `parseLine` and is dropped.
    public enum ParsedRecord: Sendable {
        case userText(uuid: String, text: String, timestamp: Date, cwd: String?, gitBranch: String?, isSidechain: Bool)
        case userToolResults(uuid: String, results: [UserToolResult], timestamp: Date, isSidechain: Bool)
        case assistant(uuid: String, blocks: [AssistantRawBlock], timestamp: Date, isSidechain: Bool, meta: AssistantMeta)
        case systemNotification(uuid: String, subtype: String, text: String, timestamp: Date)
        case aiTitle(text: String)
        case memorySources(uuid: String, sources: [MemorySource], timestamp: Date, isSidechain: Bool)

        /// Record identity, stable across copies into another session's
        /// transcript. `nil` for `ai-title`, which carries no `uuid`.
        public var uuid: String? {
            switch self {
            case let .userText(uuid, _, _, _, _, _):    return uuid
            case let .userToolResults(uuid, _, _, _):   return uuid
            case let .assistant(uuid, _, _, _, _):      return uuid
            case let .systemNotification(uuid, _, _, _): return uuid
            case .aiTitle:                              return nil
            case let .memorySources(uuid, _, _, _):     return uuid
            }
        }
    }

    /// A parsed record plus the two session-identity fields that sit on the
    /// record envelope rather than in its body. Only the metrics indexer needs
    /// them; display goes through `parseLine`.
    ///
    /// The two are easy to confuse and mean different things:
    /// - `sessionId` is the session whose transcript this line was read from. It
    ///   is **rewritten** when Claude Code copies a record into another
    ///   session's file, so it always matches the containing file.
    /// - `originSessionId` (`session_id` on the wire) is preserved verbatim
    ///   through such a copy, but a resumed session also stamps it onto its own
    ///   brand-new records, so it names a **lineage**, not a copy. On its own it
    ///   cannot tell "this record was duplicated" from "this session continues
    ///   another one"; see `ClaudeMetricsExtractor` for how the two are told apart.
    public struct ParsedLine: Sendable {
        public let record: ParsedRecord
        public let sessionId: String?
        public let originSessionId: String?

        public init(record: ParsedRecord, sessionId: String?, originSessionId: String?) {
            self.record = record
            self.sessionId = sessionId
            self.originSessionId = originSessionId
        }
    }

    public struct UserToolResult: Sendable, Hashable {
        public let toolUseID: String
        public let content: String
        public let isError: Bool
    }

    /// Per-record token usage from `message.usage`. Counts reach 10^8 in a
    /// single session, so every field is `Int64`. Populated for cost/metrics
    /// extraction; display (`loadTranscript`) ignores it.
    public struct Usage: Sendable, Hashable {
        public var inputTokens: Int64
        public var outputTokens: Int64
        public var cacheCreate5m: Int64
        public var cacheCreate1h: Int64
        public var cacheRead: Int64
        public var webSearchRequests: Int64
        public var webFetchRequests: Int64
        public var serviceTier: String?
    }

    /// Metrics-relevant fields attached to an assistant record that the display
    /// pipeline doesn't need but the indexer does. All optional — older
    /// transcripts and token-only records may omit any of them.
    public struct AssistantMeta: Sendable, Hashable {
        public var model: String?
        public var stopReason: String?
        public var cwd: String?
        public var gitBranch: String?
        public var version: String?
        public var usage: Usage?
        /// The API response this record belongs to (`message.id`). Claude Code
        /// writes one record per content block of a response, and every one of
        /// them repeats the response's `usage`, so this is what lets a consumer
        /// count a response once.
        public var messageID: String?
    }

    public enum AssistantRawBlock: Sendable, Hashable {
        case text(String)
        case thinking(String)
        case toolUse(id: String, name: String, input: String)
    }

    // MARK: - Constants

    /// CLI-echo markers the Claude Code CLI writes into the transcript for
    /// replay fidelity — slash-command echoes (`<command-name>`, …) and
    /// stdout/stderr/caveat tags. These envelopes carry `type: "user"` but
    /// are NOT user-authored prompts; they must be dropped on display.
    /// Pattern lifted from VS Code's `CLI_ECHO_MARKER_PATTERN`.
    static let cliEchoPattern: NSRegularExpression = {
        // Force-unwrap is safe — the pattern is a compile-time constant.
        try! NSRegularExpression(
            pattern: #"^<(command-name|command-message|command-args|local-command-stdout|local-command-stderr|local-command-caveat)>"#,
            options: []
        )
    }()

    /// Allowed `system` record subtypes — the rest are dropped per VS Code's
    /// `ALLOWED_SYSTEM_SUBTYPES`.
    static let allowedSystemSubtypes: Set<String> = ["compact_boundary", "notification"]

    // MARK: - Parsing entry points

    /// Parse a single JSONL line. Returns `nil` for malformed lines, unknown
    /// record types, and CLI-echo user records — caller skips silently.
    public static func parseLine(_ data: Data) -> ParsedRecord? {
        parse(data)?.record
    }

    /// As `parseLine`, but also surfacing the envelope's session-identity
    /// fields. Used by the metrics indexer to tell a record this session wrote
    /// from one copied in from another session.
    public static func parse(_ data: Data) -> ParsedLine? {
        guard let raw = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = raw as? [String: Any],
              let type = dict["type"] as? String
        else {
            return nil
        }

        let record: ParsedRecord?
        switch type {
        case "user":      record = parseUserRecord(dict)
        case "assistant": record = parseAssistantRecord(dict)
        case "system":    record = parseSystemRecord(dict)
        case "ai-title":  record = parseAiTitleRecord(dict)
        case "attachment": record = parseAttachmentRecord(dict)
        default:          record = nil
        }
        guard let record else { return nil }

        return ParsedLine(
            record: record,
            sessionId: dict["sessionId"] as? String,
            originSessionId: dict["session_id"] as? String
        )
    }

    /// The record identity of a raw line, without building a `ParsedRecord`.
    /// Cheap enough to run over a whole transcript just to collect its uuids,
    /// and unlike `parse` it also sees record types the parser drops.
    public static func recordUUID(_ data: Data) -> String? {
        guard let raw = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = raw as? [String: Any]
        else {
            return nil
        }
        return dict["uuid"] as? String
    }

    // MARK: - Per-type parsers

    private static func parseUserRecord(_ dict: [String: Any]) -> ParsedRecord? {
        guard let uuid = dict["uuid"] as? String else { return nil }
        let timestamp = parseTimestamp(dict["timestamp"]) ?? Date()
        let isSidechain = dict["isSidechain"] as? Bool ?? false
        let cwd = dict["cwd"] as? String
        let gitBranch = dict["gitBranch"] as? String

        guard let message = dict["message"] as? [String: Any] else { return nil }
        let rawContent = message["content"]

        // Legacy string form: `message.content` is a plain string.
        if let text = rawContent as? String {
            guard !text.isEmpty, !isCliEcho(text) else { return nil }
            return .userText(uuid: uuid, text: text, timestamp: timestamp, cwd: cwd, gitBranch: gitBranch, isSidechain: isSidechain)
        }

        // Array form: blocks of `text` and/or `tool_result`.
        guard let blocks = rawContent as? [[String: Any]] else { return nil }

        var textParts: [String] = []
        var results: [UserToolResult] = []
        for block in blocks {
            guard let blockType = block["type"] as? String else { continue }
            switch blockType {
            case "text":
                if let t = block["text"] as? String { textParts.append(t) }
            case "tool_result":
                guard let toolUseID = block["tool_use_id"] as? String else { continue }
                let isError = block["is_error"] as? Bool ?? false
                let content = stringifyToolResultContent(block["content"])
                results.append(UserToolResult(toolUseID: toolUseID, content: content, isError: isError))
            default:
                continue
            }
        }

        // Text wins when both are present — matches VS Code's behavior
        // (tool_results in a text-bearing envelope are already-delivered).
        if !textParts.isEmpty {
            let combined = textParts.joined(separator: "\n")
            guard !isCliEcho(combined) else { return nil }
            return .userText(uuid: uuid, text: combined, timestamp: timestamp, cwd: cwd, gitBranch: gitBranch, isSidechain: isSidechain)
        }
        if !results.isEmpty {
            return .userToolResults(uuid: uuid, results: results, timestamp: timestamp, isSidechain: isSidechain)
        }
        return nil
    }

    private static func parseAssistantRecord(_ dict: [String: Any]) -> ParsedRecord? {
        guard let uuid = dict["uuid"] as? String else { return nil }
        let timestamp = parseTimestamp(dict["timestamp"]) ?? Date()
        let isSidechain = dict["isSidechain"] as? Bool ?? false

        guard let message = dict["message"] as? [String: Any],
              let rawBlocks = message["content"] as? [[String: Any]]
        else {
            return nil
        }

        var blocks: [AssistantRawBlock] = []
        blocks.reserveCapacity(rawBlocks.count)
        for block in rawBlocks {
            guard let blockType = block["type"] as? String else { continue }
            switch blockType {
            case "text":
                if let t = block["text"] as? String { blocks.append(.text(t)) }
            case "thinking":
                // Skip empty/whitespace-only thinking — Claude can emit
                // `{"type":"thinking","thinking":""}`, which would otherwise
                // render as a "Thinking" disclosure that expands to nothing.
                // (Mirrors the Codex parser's `!text.isEmpty` guard.)
                if let t = block["thinking"] as? String,
                   !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(.thinking(t))
                }
            case "tool_use":
                guard let id = block["id"] as? String,
                      let name = block["name"] as? String
                else { continue }
                let inputString = stringifyToolInput(block["input"])
                blocks.append(.toolUse(id: id, name: name, input: inputString))
            default:
                // `server_tool_use`, `image`, future block types — drop silently.
                continue
            }
        }

        let meta = AssistantMeta(
            model: message["model"] as? String,
            stopReason: message["stop_reason"] as? String,
            cwd: dict["cwd"] as? String,
            gitBranch: dict["gitBranch"] as? String,
            version: dict["version"] as? String,
            usage: parseUsage(message["usage"]),
            messageID: message["id"] as? String
        )

        // Drop empty records *unless* they still carry usage — token-only
        // assistant records (e.g. content was only `server_tool_use`) must
        // still count toward metrics. The display consumer re-checks for
        // empty blocks so no empty bubble is rendered.
        guard !blocks.isEmpty || meta.usage != nil else { return nil }
        return .assistant(uuid: uuid, blocks: blocks, timestamp: timestamp, isSidechain: isSidechain, meta: meta)
    }

    /// Extract `message.usage` into an `Int64` token bundle. Returns `nil` when
    /// no usage object is present. Tolerates the older flat
    /// `cache_creation_input_tokens` form (no `cache_creation` sub-object).
    private static func parseUsage(_ raw: Any?) -> Usage? {
        guard let usage = raw as? [String: Any] else { return nil }

        func int64(_ value: Any?) -> Int64 {
            if let n = value as? Int64 { return n }
            if let n = value as? Int { return Int64(n) }
            if let n = value as? NSNumber { return n.int64Value }
            return 0
        }

        let cacheCreation = usage["cache_creation"] as? [String: Any]
        let cacheCreate5m = int64(cacheCreation?["ephemeral_5m_input_tokens"])
        let cacheCreate1h = int64(cacheCreation?["ephemeral_1h_input_tokens"])
        // Older transcripts: a single flat `cache_creation_input_tokens` with
        // no TTL split. Fold it into the 5m tier so totals stay correct.
        let flatCacheCreate = cacheCreation == nil ? int64(usage["cache_creation_input_tokens"]) : 0

        let serverToolUse = usage["server_tool_use"] as? [String: Any]

        return Usage(
            inputTokens: int64(usage["input_tokens"]),
            outputTokens: int64(usage["output_tokens"]),
            cacheCreate5m: cacheCreate5m + flatCacheCreate,
            cacheCreate1h: cacheCreate1h,
            cacheRead: int64(usage["cache_read_input_tokens"]),
            webSearchRequests: int64(serverToolUse?["web_search_requests"]),
            webFetchRequests: int64(serverToolUse?["web_fetch_requests"]),
            serviceTier: usage["service_tier"] as? String
        )
    }

    private static func parseSystemRecord(_ dict: [String: Any]) -> ParsedRecord? {
        guard let uuid = dict["uuid"] as? String else { return nil }
        let timestamp = parseTimestamp(dict["timestamp"]) ?? Date()

        // System message body lives under `message` (matching `user`/`assistant`).
        let body = dict["message"] as? [String: Any]
        guard let subtype = body?["subtype"] as? String, allowedSystemSubtypes.contains(subtype) else {
            return nil
        }
        let text = (body?["text"] as? String)
            ?? (body?["message"] as? String)
            ?? "[\(subtype)]"
        return .systemNotification(uuid: uuid, subtype: subtype, text: text, timestamp: timestamp)
    }

    private static func parseAiTitleRecord(_ dict: [String: Any]) -> ParsedRecord? {
        guard let title = dict["aiTitle"] as? String, !title.isEmpty else { return nil }
        return .aiTitle(text: title)
    }

    /// The instruction files and memory index Claude Code put into the
    /// agent's context: `instructions` (each file with its kind) at session
    /// start, `nested_memory` (one CLAUDE.md) when the agent reaches a
    /// subfolder. The content is read only to list the index's entries.
    private static func parseAttachmentRecord(_ dict: [String: Any]) -> ParsedRecord? {
        guard let uuid = dict["uuid"] as? String,
              let attachment = dict["attachment"] as? [String: Any]
        else { return nil }
        let files: [[String: Any]]
        let nested: Bool
        switch attachment["type"] as? String {
        case "instructions":
            files = attachment["files"] as? [[String: Any]] ?? []
            nested = false
        case "nested_memory":
            files = (attachment["content"] as? [String: Any]).map { [$0] } ?? []
            nested = true
        default:
            return nil
        }
        let timestamp = parseTimestamp(dict["timestamp"]) ?? Date()
        let sources = files.compactMap { file -> MemorySource? in
            guard let path = file["path"] as? String, !path.isEmpty else { return nil }
            let content = file["content"] as? String ?? ""
            let kind = nested ? .nested : MemorySource.Kind(claudeType: file["type"] as? String)
            return MemorySource(
                path: path, kind: kind, loadedAt: timestamp, byteCount: content.utf8.count,
                entries: kind == .memoryIndex ? MemorySource.indexEntries(in: content, listedAt: timestamp) : [])
        }
        guard !sources.isEmpty else { return nil }
        return .memorySources(uuid: uuid, sources: sources, timestamp: timestamp,
                              isSidechain: dict["isSidechain"] as? Bool ?? false)
    }

    // MARK: - Helpers

    public static func isCliEcho(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return cliEchoPattern.firstMatch(in: text, options: [], range: range) != nil
    }

    static func parseTimestamp(_ raw: Any?) -> Date? {
        guard let s = raw as? String else { return nil }
        // Claude writes timestamps with fractional seconds; tolerate both.
        // `Date.ISO8601FormatStyle` is Sendable, so inline construction is safe.
        if let d = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s) {
            return d
        }
        return try? Date.ISO8601FormatStyle().parse(s)
    }

    /// Render `tool_result.content` to a single string. Accepts either a
    /// plain string or an array of text blocks. Other block types (images,
    /// etc.) are skipped.
    private static func stringifyToolResultContent(_ raw: Any?) -> String {
        if let s = raw as? String { return s }
        guard let blocks = raw as? [[String: Any]] else { return "" }
        var parts: [String] = []
        for block in blocks {
            if (block["type"] as? String) == "text", let t = block["text"] as? String {
                parts.append(t)
            }
        }
        return parts.joined(separator: "\n")
    }

    /// Render `tool_use.input` (an arbitrary JSON value) to a stable string.
    /// Used for display only — full fidelity isn't required.
    private static func stringifyToolInput(_ raw: Any?) -> String {
        guard let raw else { return "" }
        if let s = raw as? String { return s }
        if JSONSerialization.isValidJSONObject(raw),
           let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return String(describing: raw)
    }
}
