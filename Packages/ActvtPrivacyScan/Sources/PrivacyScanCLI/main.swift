//
//  main.swift
//  privacy-scan
//

import ActvtPrivacyScan
import ActvtSessionParsers
import Foundation

let usage = """
    usage: privacy-scan [--json] [path ...]

    Scans your Claude Code, Codex and Pi sessions for secrets and personal
    data: prompts, replies, thinking, tool calls and tool output, the
    subagents' as well as the session's own. Nothing is sent anywhere, and no
    detected value is ever printed.

    With no path, it scans the agents' own folders on this machine, archived
    Codex sessions included. With paths, it scans those files and folders
    instead: every .jsonl (or Codex's compressed .jsonl.zst) in them written by
    Claude Code, Codex or Pi, told
    apart by its records, so a copy or an export you are about to share can be
    checked first.

      --json   one JSON object per finding on stdout (the summary goes to stderr)

    Exit status: 0 nothing found, 1 something found, 2 an error.
    """

var json = false
var paths: [String] = []
for argument in CommandLine.arguments.dropFirst() {
    switch argument {
    case "--json": json = true
    case "-h", "--help":
        print(usage)
        exit(0)
    case _ where argument.hasPrefix("-"):
        FileHandle.standardError.write(Data("privacy-scan: unknown argument \(argument)\n\n\(usage)\n".utf8))
        exit(2)
    default:
        paths.append(argument)
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

var scannedCount = 0
var failures = 0
var findingCount = 0
var distinct = Set<Int>()
var byCategory: [PIICategory: Int] = [:]

@MainActor func fail(_ what: String, _ error: Error) {
    FileHandle.standardError.write(Data("privacy-scan: \(what): \(error.localizedDescription)\n".utf8))
    failures += 1
}

@MainActor func report(_ findings: [SessionFinding]) {
    scannedCount += 1
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

let noun: String
var skipped = 0
if paths.isEmpty {
    // The agents' own folders, read as the app reads them, plus the sessions
    // Codex has archived, which the app doesn't list.
    noun = "sessions"
    var sources = await registry.availableProviders()
    let archived = CodexSessionSource(rootURL: CodexSessionsLocator.archivedSessionsURL)
    if await archived.isAvailable { sources.append(archived) }
    for source in sources {
        let refs: [AgentSessionRef]
        do { refs = try await source.listSessionRefs() } catch {
            fail(source.kind.rawValue, error)
            continue
        }
        for ref in refs {
            do { report(try await scanner.scan(ref, from: source)) } catch { fail(ref.compositeKey, error) }
        }
    }
} else {
    noun = "session files"
    var files: [URL] = []
    for path in paths {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            FileHandle.standardError.write(Data("privacy-scan: \(path): no such file or folder\n".utf8))
            exit(2)
        }
        if !isDirectory.boolValue {
            files.append(url)
            continue
        }
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])
        while let file = walker?.nextObject() as? URL {
            if file.pathExtension == "jsonl" || file.lastPathComponent.hasSuffix(".jsonl.zst"), (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                files.append(file)
            }
        }
    }
    for file in files.sorted(by: { $0.path < $1.path }) {
        guard let kind = AgentSessionFile.kind(ofFileAt: file), let source = registry.provider(for: kind) else {
            skipped += 1
            continue
        }
        do { report(try await scanner.scan(fileAt: file, from: source)) } catch { fail(file.path, error) }
    }
}

let breakdown = byCategory.sorted { $0.key.rawValue < $1.key.rawValue }
    .map { "\($0.key.rawValue) \($0.value)" }.joined(separator: ", ")
var summary = "\(scannedCount) \(noun) scanned, \(findingCount) findings (\(distinct.count) distinct values)"
    + (breakdown.isEmpty ? "" : ": \(breakdown)")
if skipped > 0 { summary += "; \(skipped) \(skipped == 1 ? "file" : "files") skipped, not written by Claude Code, Codex or Pi" }
if failures > 0 { summary += "; \(failures) could not be read" }
FileHandle.standardError.write(Data((summary + "\n").utf8))
exit(failures > 0 ? 2 : (findingCount == 0 ? 0 : 1))
