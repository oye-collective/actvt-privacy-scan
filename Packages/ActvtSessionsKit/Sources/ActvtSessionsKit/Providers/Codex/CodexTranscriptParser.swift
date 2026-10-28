//
//  CodexTranscriptParser.swift
//  Actvt
//

import Foundation

/// Stateless line-by-line parser for the Codex CLI's JSONL session transcripts.
///
/// Codex records carry a top-level `type` (`session_meta` / `turn_context` /
/// `response_item` / `event_msg`) wrapping a `payload` with its own `type`.
/// Unlike Claude, the human-visible conversation lives on the **`event_msg`
/// channel** (`user_message` / `agent_message` / `agent_reasoning`), which is
/// already free of the injected preamble (`<permissions instructions>`,
/// `AGENTS.md`, `<environment_context>`, …) that pollutes the `response_item`
/// `message` records. We therefore drive display/metrics off `event_msg` for
/// messages + reasoning and off `response_item` for tool calls/outputs:
///
/// - `event_msg/user_message`     → user turn (clean prompt text)
/// - `event_msg/agent_message`    → assistant text block
/// - `event_msg/agent_reasoning`  → assistant thinking block (plaintext;
///   `response_item/reasoning` is encrypted, so it's ignored)
/// - `event_msg/item_completed`   → the same three, as newer Codex builds
///   (0.155, the CLI bundled in ChatGPT.app) write them: an `item` of type
///   `UserMessage` / `AgentMessage` / `Reasoning` instead of the records above,
///   plus one item per tool that ran (`CommandExecution`, `FileChange`,
///   `McpToolCall`, …) → tool run
/// - `response_item/function_call` + `custom_tool_call`        → tool call
/// - `response_item/function_call_output` + `custom_tool_call_output` → tool result
/// - `event_msg/token_count`      → cumulative usage (see `CodexUsage`)
/// - `session_meta` / `turn_context` → cwd / cli version / model metadata
///
/// Narrow-at-the-seam: every field is type-checked; unknown record types and
/// malformed lines return `nil` and are skipped silently.
public enum CodexTranscriptParser {

    // MARK: - Public parsed record type

    public enum ParsedRecord: Sendable {
        case sessionMeta(cwd: String?, cliVersion: String?, sessionId: String?,
                         originator: String?, source: String?, timestamp: Date)
        case turnContext(model: String?, timestamp: Date)
        case userMessage(text: String, timestamp: Date)
        case assistantMessage(text: String, timestamp: Date)
        case reasoning(text: String, timestamp: Date)
        case toolCall(callId: String, name: String, input: String, timestamp: Date)
        case toolOutput(callId: String, output: String, isError: Bool, timestamp: Date)
        case tokenCount(usage: CodexUsage, context: CodexContext?, timestamp: Date)
        /// A tool that ran, as newer Codex builds record it, with the paths it
        /// created, changed, moved or deleted. A `toolCall` is what the model
        /// sent Codex's tool host; in code mode that is one `exec` script, which
        /// runs many tools, each recorded here.
        case toolRun(name: String, isError: Bool, paths: [String], timestamp: Date)
    }

    /// The live context-window reading a `token_count` record carries alongside
    /// its cumulative totals.
    ///
    /// Unlike every other size figure in this app, `limitTokens` is **reported
    /// by the provider** (`model_context_window`) rather than derived from a
    /// table we maintain, so a Codex context meter cannot drift out of date
    /// when a model's window changes.
    ///
    /// `usedTokens` comes from `last_token_usage.total_tokens` — the size of the
    /// most recent request, i.e. the conversation as it currently stands. This
    /// is a *point-in-time* reading, not an accumulation: the extractor keeps
    /// the last one seen, never a sum.
    public struct CodexContext: Sendable, Hashable {
        public var usedTokens: Int64
        /// nil on older Codex builds that don't report the window.
        public var limitTokens: Int64?

        public init(usedTokens: Int64, limitTokens: Int64?) {
            self.usedTokens = usedTokens
            self.limitTokens = limitTokens
        }
    }

    /// Cumulative token totals from a `token_count` record's `total_token_usage`.
    /// These are **running session totals** (verified strictly monotonic across a
    /// session, no compaction resets), so the extractor keeps the *last* one seen
    /// rather than summing. Counts reach 10^8, so every field is `Int64`.
    ///
    /// Field algebra (verified): `total = input + output`; `cachedInput ⊆ input`;
    /// `reasoningOutput ⊆ output`. So billable uncached input is
    /// `input - cachedInput`, and `output` already includes reasoning.
    public struct CodexUsage: Sendable, Hashable {
        public var inputTokens: Int64
        public var cachedInputTokens: Int64
        public var outputTokens: Int64
        public var reasoningOutputTokens: Int64
        public var totalTokens: Int64
    }

    // MARK: - Parsing entry point

    /// Parse a single JSONL line. Returns `nil` for malformed lines and record
    /// types we don't surface (`response_item/message`, encrypted `reasoning`,
    /// duplicate echo events, …) — caller skips silently.
    public static func parseLine(_ data: Data) -> ParsedRecord? {
        guard let raw = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = raw as? [String: Any],
              let type = dict["type"] as? String,
              let payload = dict["payload"] as? [String: Any]
        else {
            return nil
        }
        let timestamp = parseTimestamp(dict["timestamp"]) ?? Date()

        switch type {
        case "session_meta":
            return .sessionMeta(
                cwd: payload["cwd"] as? String,
                cliVersion: payload["cli_version"] as? String,
                sessionId: payload["id"] as? String,
                originator: payload["originator"] as? String,
                source: payload["source"] as? String,
                timestamp: timestamp
            )
        case "turn_context":
            return .turnContext(model: payload["model"] as? String, timestamp: timestamp)
        case "event_msg":
            return parseEventMsg(payload, timestamp: timestamp)
        case "response_item":
            return parseResponseItem(payload, timestamp: timestamp)
        default:
            return nil
        }
    }

    // MARK: - Channel parsers

    private static func parseEventMsg(_ payload: [String: Any], timestamp: Date) -> ParsedRecord? {
        guard let pt = payload["type"] as? String else { return nil }
        switch pt {
        case "user_message":
            guard let text = (payload["message"] as? String), !text.isEmpty else { return nil }
            return .userMessage(text: text, timestamp: timestamp)
        case "agent_message":
            guard let text = (payload["message"] as? String), !text.isEmpty else { return nil }
            return .assistantMessage(text: text, timestamp: timestamp)
        case "agent_reasoning":
            guard let text = (payload["text"] as? String), !text.isEmpty else { return nil }
            return .reasoning(text: text, timestamp: timestamp)
        case "item_completed":
            guard let item = payload["item"] as? [String: Any] else { return nil }
            return parseCompletedItem(item, timestamp: timestamp)
        case "token_count":
            guard let info = payload["info"] as? [String: Any],
                  let usage = parseUsage(info["total_token_usage"])
            else {
                return nil   // rate-limit-only token_count records carry no usage
            }
            return .tokenCount(
                usage: usage,
                context: parseContext(info),
                timestamp: timestamp
            )
        default:
            return nil
        }
    }

    /// A finished conversation item on the newer `item_completed` channel.
    /// A tool item is named the way the tool is called elsewhere (Codex's own
    /// `exec_command` / `apply_patch`, Claude Code's `mcp__<server>__<tool>`),
    /// so the same filter finds it in every agent's sessions.
    private static func parseCompletedItem(_ item: [String: Any], timestamp: Date) -> ParsedRecord? {
        func joinedText(_ parts: Any?) -> String {
            ((parts as? [Any]) ?? []).compactMap { part in
                (part as? String) ?? ((part as? [String: Any])?["text"] as? String)
            }.joined(separator: "\n")
        }
        let failed = (item["status"] as? String) == "failed"
        switch item["type"] as? String {
        case "UserMessage":
            let text = userRequest(in: joinedText(item["content"]))
            return text.isEmpty ? nil : .userMessage(text: text, timestamp: timestamp)
        case "AgentMessage":
            let text = joinedText(item["content"])
            return text.isEmpty ? nil : .assistantMessage(text: text, timestamp: timestamp)
        case "Reasoning":
            let text = joinedText(item["summary_text"])
            return text.isEmpty ? nil : .reasoning(text: text, timestamp: timestamp)
        case "CommandExecution":
            return .toolRun(name: "exec_command", isError: failed, paths: [], timestamp: timestamp)
        case "FileChange":
            // `changes` is keyed by path; a rename also names where it went.
            let changes = item["changes"] as? [String: Any] ?? [:]
            let moved = changes.values.compactMap { ($0 as? [String: Any])?["move_path"] as? String }
            return .toolRun(name: "apply_patch", isError: failed,
                            paths: (Array(changes.keys) + moved).sorted(), timestamp: timestamp)
        case "McpToolCall":
            guard let server = item["server"] as? String, let tool = item["tool"] as? String else { return nil }
            return .toolRun(name: "mcp__\(server)__\(tool)", isError: failed, paths: [], timestamp: timestamp)
        case "ImageView":
            return .toolRun(name: "view_image", isError: failed, paths: [], timestamp: timestamp)
        case "Extension":
            // Codex's built-in tools, named by kind (`web.search`, `clock.sleep`).
            guard let kind = item["kind"] as? String else { return nil }
            return .toolRun(name: kind, isError: failed, paths: [], timestamp: timestamp)
        default:
            return nil
        }
    }

    /// What the user typed, without the page context ChatGPT's in-app browser
    /// puts in front of it: a `<in-app-browser-context>` block that says of
    /// itself it is "not part of the user's request", then "## My request:"
    /// and the request. Left as is when the block isn't closed, so a prompt
    /// that merely mentions the tag is never cut.
    static func userRequest(in text: String) -> String {
        let opening = "<in-app-browser-context", closing = "</in-app-browser-context>"
        let trimmed = text.drop { $0.isWhitespace }
        guard trimmed.hasPrefix(opening), let end = trimmed.range(of: closing) else { return text }
        var request = trimmed[end.upperBound...].drop { $0.isWhitespace }
        if request.hasPrefix("## My request:") { request = request.dropFirst("## My request:".count) }
        return request.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseResponseItem(_ payload: [String: Any], timestamp: Date) -> ParsedRecord? {
        guard let pt = payload["type"] as? String else { return nil }
        switch pt {
        case "function_call":
            guard let callId = payload["call_id"] as? String,
                  let name = payload["name"] as? String
            else { return nil }
            let input = (payload["arguments"] as? String) ?? stringify(payload["arguments"])
            return .toolCall(callId: callId, name: name, input: input, timestamp: timestamp)

        case "custom_tool_call":
            guard let callId = payload["call_id"] as? String,
                  let name = payload["name"] as? String
            else { return nil }
            let input = (payload["input"] as? String) ?? stringify(payload["input"])
            return .toolCall(callId: callId, name: name, input: input, timestamp: timestamp)

        case "function_call_output":
            guard let callId = payload["call_id"] as? String else { return nil }
            let output = stringifyOutput(payload["output"])
            return .toolOutput(callId: callId, output: output,
                               isError: isFunctionError(output), timestamp: timestamp)

        case "custom_tool_call_output":
            guard let callId = payload["call_id"] as? String else { return nil }
            let raw = stringifyOutput(payload["output"])
            let (text, isError) = unwrapCustomOutput(raw, status: payload["status"] as? String)
            return .toolOutput(callId: callId, output: text, isError: isError, timestamp: timestamp)

        default:
            // message (preamble / duplicate of event_msg), reasoning (encrypted),
            // and future item types are dropped.
            return nil
        }
    }

    // MARK: - Usage

    private static func parseUsage(_ raw: Any?) -> CodexUsage? {
        guard let u = raw as? [String: Any] else { return nil }
        func int64(_ value: Any?) -> Int64 {
            if let n = value as? Int64 { return n }
            if let n = value as? Int { return Int64(n) }
            if let n = value as? NSNumber { return n.int64Value }
            return 0
        }
        return CodexUsage(
            inputTokens: int64(u["input_tokens"]),
            cachedInputTokens: int64(u["cached_input_tokens"]),
            outputTokens: int64(u["output_tokens"]),
            reasoningOutputTokens: int64(u["reasoning_output_tokens"]),
            totalTokens: int64(u["total_tokens"])
        )
    }

    /// Pull the live context reading out of a `token_count` info block.
    ///
    /// Returns nil when `last_token_usage` is absent (older Codex builds), which
    /// the caller must treat as "no reading this record" rather than zero — a
    /// zero would render as an empty context window on a busy session.
    private static func parseContext(_ info: [String: Any]) -> CodexContext? {
        func int64(_ value: Any?) -> Int64? {
            if let n = value as? Int64 { return n }
            if let n = value as? Int { return Int64(n) }
            if let n = value as? NSNumber { return n.int64Value }
            return nil
        }
        guard let last = info["last_token_usage"] as? [String: Any],
              let used = int64(last["total_tokens"])
        else { return nil }

        // A non-positive window is not a usable denominator; drop it rather
        // than let a divide produce an absurd percentage.
        let limit = int64(info["model_context_window"]).flatMap { $0 > 0 ? $0 : nil }
        return CodexContext(usedTokens: used, limitTokens: limit)
    }

    // MARK: - Tool error detection

    /// A shell `function_call_output` carries a `Process exited with code N`
    /// line. Treat a non-zero code as an error; absence of the line (or code 0)
    /// is success.
    private static func isFunctionError(_ output: String) -> Bool {
        guard let range = output.range(of: #"exited with code (\d+)"#, options: .regularExpression) else {
            return false
        }
        let codeDigits = output[range].drop { !$0.isNumber }
        return Int(codeDigits) != 0
    }

    /// A `custom_tool_call_output` (e.g. `apply_patch`) is JSON:
    /// `{"output": "...", "metadata": {"exit_code": N, ...}}`. Unwrap to the
    /// human-readable `output` and flag an error on non-zero `exit_code` (or a
    /// `failed` call status). Falls back to the raw string if it isn't JSON.
    private static func unwrapCustomOutput(_ raw: String, status: String?) -> (text: String, isError: Bool) {
        let statusError = (status == "failed")
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return (raw, statusError)
        }
        let text = (obj["output"] as? String) ?? raw
        if let meta = obj["metadata"] as? [String: Any],
           let code = (meta["exit_code"] as? NSNumber)?.intValue {
            return (text, code != 0 || statusError)
        }
        return (text, statusError)
    }

    // MARK: - Helpers

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

    /// Tool `output` is usually a plain string but tolerate an array of text
    /// blocks or a structured value.
    private static func stringifyOutput(_ raw: Any?) -> String {
        if let s = raw as? String { return s }
        if let blocks = raw as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return stringify(raw)
    }
}
