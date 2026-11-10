//
//  PiTranscriptParser.swift
//  ActvtSessionParsers
//

import Foundation

/// Stateless line-by-line parser for the pi coding agent's JSONL session files
/// (format version 3, pi 0.85.x).
///
/// A file is a header line followed by tree entries. Every entry carries `id`,
/// `parentId` and an ISO `timestamp`; `parentId` links entries into a tree so
/// pi can branch a conversation inside one file. The conversation the user
/// actually saw is the path from the last entry back to the root; see
/// `activePath(_:)`.
///
/// Entry types and what is kept:
///
/// - `message`                → `.message` with a role-specific payload
/// - `model_change`           → provider + model id
/// - `thinking_level_change`  → level
/// - `compaction`             → summary size, tokens summarized, optional usage
/// - `branch_summary`         → summary, optional usage
/// - `session_info`           → user-set display name
/// - `custom_message`         → extension text, with its TUI visibility flag
/// - `label`, `custom`, anything unknown → `.other`, kept only for tree walks
///
/// Image blocks (inline base64 on `user` and `toolResult` messages) are
/// replaced by an `[image]` marker at parse time so the bytes never reach the
/// transcript, the search index or the metrics extractor.
///
/// Narrow-at-the-seam: every field is type-checked; malformed lines return
/// `nil` and are skipped silently by callers.
public enum PiTranscriptParser {

    // MARK: - Parsed shapes

    public struct Header: Sendable, Hashable {
        public var sessionId: String
        public var cwd: String?
        public var timestamp: Date
        public var version: Int?
        /// Path of the session this one was forked from, when pi recorded it.
        public var parentSession: String?

        public init(sessionId: String, cwd: String?, timestamp: Date, version: Int?, parentSession: String?) {
            self.sessionId = sessionId
            self.cwd = cwd
            self.timestamp = timestamp
            self.version = version
            self.parentSession = parentSession
        }
    }

    public struct Entry: Sendable {
        public var id: String
        public var parentId: String?
        public var timestamp: Date
        public var kind: Kind

        public init(id: String, parentId: String?, timestamp: Date, kind: Kind) {
            self.id = id
            self.parentId = parentId
            self.timestamp = timestamp
            self.kind = kind
        }
    }

    public enum Kind: Sendable {
        case message(Message)
        case modelChange(provider: String, modelId: String)
        case thinkingLevelChange(level: String)
        case compaction(summary: String, tokensBefore: Int64, usage: Usage?)
        case branchSummary(summary: String, usage: Usage?)
        case sessionInfo(name: String?)
        case customMessage(text: String, display: Bool)
        case other(type: String)
    }

    public enum Message: Sendable {
        case user(text: String)
        case assistant(AssistantMessage)
        case toolResult(toolCallId: String, toolName: String, text: String, isError: Bool)
        /// The `!` shell escape run by the user inside pi.
        case bashExecution(command: String, output: String, exitCode: Int?)
        /// Extension-injected message; `display` mirrors pi's TUI visibility.
        case custom(text: String, display: Bool)
        case other(role: String)
    }

    public struct AssistantMessage: Sendable {
        public var blocks: [Block]
        public var provider: String?
        public var model: String?
        /// `stop`, `length`, `toolUse`, `error`, `aborted`, `pending`, `deferred`.
        public var stopReason: String?
        public var errorMessage: String?
        public var usage: Usage?

        public init(blocks: [Block], provider: String?, model: String?,
                    stopReason: String?, errorMessage: String?, usage: Usage?) {
            self.blocks = blocks
            self.provider = provider
            self.model = model
            self.stopReason = stopReason
            self.errorMessage = errorMessage
            self.usage = usage
        }
    }

    public enum Block: Sendable {
        case text(String)
        case thinking(String)
        /// `arguments` is the JSON object rendered with sorted keys. `filePath`
        /// is the `path` argument when the tool took one (pi's `read`, `edit`,
        /// `write`), pulled out here so consumers never re-parse the JSON.
        case toolCall(id: String, name: String, arguments: String, filePath: String?)
    }

    /// Per-response usage as pi records it. Never cumulative. `output` already
    /// includes `reasoning`; `cacheWrite1h` is a subset of `cacheWrite` that
    /// only Anthropic reports. `costTotal` is pi's own estimate from its model
    /// registry, `0` for models it has no rates for (local servers).
    public struct Usage: Sendable, Hashable {
        public var input: Int64
        public var output: Int64
        public var cacheRead: Int64
        public var cacheWrite: Int64
        public var cacheWrite1h: Int64?
        public var reasoning: Int64?
        public var totalTokens: Int64
        public var costTotal: Double?

        public init(input: Int64, output: Int64, cacheRead: Int64, cacheWrite: Int64,
                    cacheWrite1h: Int64?, reasoning: Int64?, totalTokens: Int64, costTotal: Double?) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
            self.cacheWrite1h = cacheWrite1h
            self.reasoning = reasoning
            self.totalTokens = totalTokens
            self.costTotal = costTotal
        }
    }

    public enum ParsedLine: Sendable {
        case header(Header)
        case entry(Entry)
    }

    /// Marker substituted for inline image data.
    public static let imagePlaceholder = "[image]"

    // MARK: - Entry point

    public static func parseLine(_ data: Data) -> ParsedLine? {
        guard let raw = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = raw as? [String: Any],
              let type = dict["type"] as? String
        else { return nil }

        if type == "session" {
            guard let id = dict["id"] as? String else { return nil }
            return .header(Header(
                sessionId: id,
                cwd: dict["cwd"] as? String,
                timestamp: parseTimestamp(dict["timestamp"]) ?? Date(),
                version: intValue(dict["version"]).map(Int.init),
                parentSession: dict["parentSession"] as? String
            ))
        }

        guard let id = dict["id"] as? String else { return nil }
        let entry = Entry(
            id: id,
            parentId: dict["parentId"] as? String,
            timestamp: parseTimestamp(dict["timestamp"]) ?? Date(),
            kind: parseKind(type: type, dict)
        )
        return .entry(entry)
    }

    /// The conversation as the user saw it: the chain from the last entry in
    /// the file back to the root, in file order. Entries on abandoned branches
    /// are left out. An entry whose parent is missing ends the walk there, so
    /// a truncated file still yields its readable tail.
    public static func activePath(_ entries: [Entry]) -> [Entry] {
        var parents: [String: String] = [:]
        parents.reserveCapacity(entries.count)
        for entry in entries { parents[entry.id] = entry.parentId ?? "" }
        let onPath = activeIDs(leaf: entries.last?.id, parents: parents)
        return entries.filter { onPath.contains($0.id) }
    }

    /// The ids on that chain, from each entry's id to its parent's (`""` for
    /// a root). Enough to pick the branch of a file too long to hold whole:
    /// collect `parents` over the file, then keep only the entries a window
    /// reads whose id is on it.
    public static func activeIDs(leaf: String?, parents: [String: String]) -> Set<String> {
        var path: Set<String> = []
        var cursor = leaf
        while let id = cursor, let parent = parents[id], path.insert(id).inserted {
            cursor = parent
        }
        return path
    }

    // MARK: - Entry kinds

    private static func parseKind(type: String, _ dict: [String: Any]) -> Kind {
        switch type {
        case "message":
            guard let message = dict["message"] as? [String: Any] else { return .other(type: type) }
            return .message(parseMessage(message))
        case "model_change":
            return .modelChange(
                provider: (dict["provider"] as? String) ?? "",
                modelId: (dict["modelId"] as? String) ?? ""
            )
        case "thinking_level_change":
            return .thinkingLevelChange(level: (dict["thinkingLevel"] as? String) ?? "")
        case "compaction":
            return .compaction(
                summary: (dict["summary"] as? String) ?? "",
                tokensBefore: intValue(dict["tokensBefore"]) ?? 0,
                usage: parseUsage(dict["usage"])
            )
        case "branch_summary":
            return .branchSummary(
                summary: (dict["summary"] as? String) ?? "",
                usage: parseUsage(dict["usage"])
            )
        case "session_info":
            return .sessionInfo(name: dict["name"] as? String)
        case "custom_message":
            return .customMessage(
                text: contentText(dict["content"]),
                display: (dict["display"] as? Bool) ?? false
            )
        default:
            return .other(type: type)
        }
    }

    private static func parseMessage(_ message: [String: Any]) -> Message {
        let role = (message["role"] as? String) ?? ""
        switch role {
        case "user":
            return .user(text: contentText(message["content"]))
        case "assistant":
            return .assistant(AssistantMessage(
                blocks: assistantBlocks(message["content"]),
                provider: message["provider"] as? String,
                model: message["model"] as? String,
                stopReason: message["stopReason"] as? String,
                errorMessage: message["errorMessage"] as? String,
                usage: parseUsage(message["usage"])
            ))
        case "toolResult":
            return .toolResult(
                toolCallId: (message["toolCallId"] as? String) ?? "",
                toolName: (message["toolName"] as? String) ?? "",
                text: contentText(message["content"]),
                isError: (message["isError"] as? Bool) ?? false
            )
        case "bashExecution":
            return .bashExecution(
                command: (message["command"] as? String) ?? "",
                output: (message["output"] as? String) ?? "",
                exitCode: intValue(message["exitCode"]).map(Int.init)
            )
        case "custom":
            return .custom(
                text: contentText(message["content"]),
                display: (message["display"] as? Bool) ?? false
            )
        default:
            return .other(role: role)
        }
    }

    private static func assistantBlocks(_ raw: Any?) -> [Block] {
        guard let blocks = raw as? [[String: Any]] else { return [] }
        var result: [Block] = []
        result.reserveCapacity(blocks.count)
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty { result.append(.text(text)) }
            case "thinking":
                if let text = block["thinking"] as? String, !text.isEmpty { result.append(.thinking(text)) }
            case "toolCall":
                guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                let args = block["arguments"]
                let filePath = (args as? [String: Any])?["path"] as? String
                result.append(.toolCall(id: id, name: name, arguments: stringify(args), filePath: filePath))
            default:
                continue
            }
        }
        return result
    }

    // MARK: - Content

    /// Flatten a `content` value (string or block array) to display text.
    /// Image blocks contribute the placeholder, never their bytes.
    private static func contentText(_ raw: Any?) -> String {
        if let s = raw as? String { return s }
        guard let blocks = raw as? [[String: Any]] else { return "" }
        var parts: [String] = []
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty { parts.append(text) }
            case "image":
                parts.append(imagePlaceholder)
            default:
                continue
            }
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Usage

    private static func parseUsage(_ raw: Any?) -> Usage? {
        guard let u = raw as? [String: Any] else { return nil }
        let cost = (u["cost"] as? [String: Any]).flatMap { doubleValue($0["total"]) }
        return Usage(
            input: intValue(u["input"]) ?? 0,
            output: intValue(u["output"]) ?? 0,
            cacheRead: intValue(u["cacheRead"]) ?? 0,
            cacheWrite: intValue(u["cacheWrite"]) ?? 0,
            cacheWrite1h: intValue(u["cacheWrite1h"]),
            reasoning: intValue(u["reasoning"]),
            totalTokens: intValue(u["totalTokens"]) ?? 0,
            costTotal: cost
        )
    }

    // MARK: - Helpers

    private static func intValue(_ value: Any?) -> Int64? {
        if let n = value as? Int64 { return n }
        if let n = value as? Int { return Int64(n) }
        if let n = value as? NSNumber { return n.int64Value }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let n = value as? Double { return n }
        if let n = value as? Int { return Double(n) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func parseTimestamp(_ raw: Any?) -> Date? {
        guard let s = raw as? String else { return nil }
        if let d = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s) {
            return d
        }
        return try? Date.ISO8601FormatStyle().parse(s)
    }

    /// Render an arbitrary JSON value to a stable string (sorted keys).
    private static func stringify(_ raw: Any?) -> String {
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
