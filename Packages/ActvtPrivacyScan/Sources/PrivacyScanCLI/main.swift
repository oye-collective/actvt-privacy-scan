//
//  main.swift
//  privacy-scan
//

import ActvtPrivacyScan
import ActvtSessionsKit
import Foundation

let usage = """
    usage: privacy-scan [--json]

    Scans your Claude Code, Codex and Pi sessions on this machine for secrets
    and personal data: prompts, replies, thinking, tool calls and tool output,
    the subagents' as well as the session's own. Nothing is sent anywhere, and
    no detected value is ever printed.

      --json   one JSON object per finding on stdout (the summary goes to stderr)

    Exit status: 0 nothing found, 1 something found, 2 an error.
    """

var json = false
for argument in CommandLine.arguments.dropFirst() {
    switch argument {
    case "--json": json = true
    case "-h", "--help":
        print(usage)
        exit(0)
    default:
        FileHandle.standardError.write(Data("privacy-scan: unknown argument \(argument)\n\n\(usage)\n".utf8))
        exit(2)
    }
}

// Claude Code's `~/.claude-*` config roots are found by the kit; a
// `CLAUDE_CONFIG_DIR` pointed anywhere else is added here.
let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
let registry = AgentSessionRegistry.makeDefault(
    extraClaudeRoots: configDir.map { [URL(fileURLWithPath: $0).appendingPathComponent("projects")] } ?? [])

let scanner = SessionScanner()
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
encoder.dateEncodingStrategy = .iso8601
let timeFormat = Date.ISO8601FormatStyle()

struct Line: Encodable {
    let agent: String, session: String, subagent: String?, subagentType: String?, project: String
    let kind: String, tool: String?, time: Date?, category: String, length: Int, preview: String
}

var sessionCount = 0
var failures = 0
var findingCount = 0
var distinct = Set<Int>()
var byCategory: [PIICategory: Int] = [:]

for source in await registry.availableProviders() {
    let refs: [AgentSessionRef]
    do { refs = try await source.listSessionRefs() } catch {
        FileHandle.standardError.write(Data("privacy-scan: \(source.kind.rawValue): \(error.localizedDescription)\n".utf8))
        failures += 1
        continue
    }
    for ref in refs {
        let findings: [SessionFinding]
        do { findings = try await scanner.scan(ref, from: source) } catch {
            FileHandle.standardError.write(Data("privacy-scan: \(ref.compositeKey): \(error.localizedDescription)\n".utf8))
            failures += 1
            continue
        }
        sessionCount += 1
        for finding in findings {
            findingCount += 1
            distinct.insert(finding.valueHash)
            byCategory[finding.category, default: 0] += 1
            if json {
                let line = Line(agent: finding.agent.rawValue, session: finding.sessionId,
                                subagent: finding.subagent?.agentId, subagentType: finding.subagent?.agentType,
                                project: finding.projectPath, kind: finding.kind.rawValue, tool: finding.tool,
                                time: finding.timestamp, category: finding.category.rawValue, length: finding.length,
                                preview: finding.preview)
                if let data = try? encoder.encode(line) { print(String(decoding: data, as: UTF8.self)) }
            } else {
                let when = finding.timestamp.map { " \($0.formatted(timeFormat))" } ?? ""
                let kind = finding.tool.map { "\(finding.kind.rawValue) (\($0))" } ?? finding.kind.rawValue
                let place = finding.subagent.map { "\(kind) of subagent \($0.agentType ?? $0.agentId)" } ?? kind
                print("\(finding.agent.rawValue) \(finding.sessionId)\(when)  \(finding.category.rawValue) in \(place)  \(finding.preview)  \(finding.projectPath)")
            }
        }
    }
}

let breakdown = byCategory.sorted { $0.key.rawValue < $1.key.rawValue }
    .map { "\($0.key.rawValue) \($0.value)" }.joined(separator: ", ")
var summary = "\(sessionCount) sessions scanned, \(findingCount) findings (\(distinct.count) distinct values)"
    + (breakdown.isEmpty ? "" : ": \(breakdown)")
if failures > 0 { summary += "; \(failures) could not be read" }
FileHandle.standardError.write(Data((summary + "\n").utf8))
exit(failures > 0 ? 2 : (findingCount == 0 ? 0 : 1))
