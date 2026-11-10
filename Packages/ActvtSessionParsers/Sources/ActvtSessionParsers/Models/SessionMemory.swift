//
//  SessionMemory.swift
//  ActvtSessionParsers
//

import Foundation

/// An instruction file or memory index the agent loaded into its context:
/// Claude Code's `instructions` record at session start, or a
/// `nested_memory` record when it reaches a subfolder's CLAUDE.md.
///
/// Only what the memory view draws is kept (path, size, the index's
/// entries), never a file's content: a user CLAUDE.md alone runs to tens of
/// KB, and every transcript load would carry it.
public struct MemorySource: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        /// `~/.claude/CLAUDE.md`.
        case user
        /// A CLAUDE.md in the project.
        case project
        /// `CLAUDE.local.md`.
        case local
        /// The auto-memory index, `projects/<project>/memory/MEMORY.md`.
        case memoryIndex
        /// A subfolder's CLAUDE.md, loaded when the agent reached it.
        case nested
        /// Any kind this version doesn't know.
        case other

        /// Claude Code's own name for the kind (`"User"`, `"AutoMem"`, …).
        init(claudeType: String?) {
            switch claudeType {
            case "User": self = .user
            case "Project": self = .project
            case "Local": self = .local
            case "AutoMem": self = .memoryIndex
            default: self = .other
            }
        }
    }

    /// One line of the memory index: `- [Title](file.md) — hook`.
    public struct IndexEntry: Sendable, Hashable {
        public let title: String
        public let file: String
        public let hook: String?
        /// When the agent was first given this entry. The index loads again
        /// after every compaction, and a later load can list a memory the
        /// first one didn't.
        public let listedAt: Date

        public init(title: String, file: String, hook: String?, listedAt: Date) {
            self.title = title
            self.file = file
            self.hook = hook
            self.listedAt = listedAt
        }
    }

    public let path: String
    public let kind: Kind
    public let loadedAt: Date
    public let byteCount: Int
    /// The memories the index listed over the session, each once, in the
    /// order first listed; empty for every other kind.
    public private(set) var entries: [IndexEntry]

    public init(path: String, kind: Kind, loadedAt: Date, byteCount: Int, entries: [IndexEntry] = []) {
        self.path = path
        self.kind = kind
        self.loadedAt = loadedAt
        self.byteCount = byteCount
        self.entries = entries
    }

    /// The same source loaded again: the first load stands, and an index
    /// gains the entries it didn't list before, at the time they appeared.
    public mutating func absorb(_ reload: MemorySource) {
        for entry in reload.entries where !entries.contains(where: { $0.file == entry.file }) {
            entries.append(entry)
        }
    }

    /// The index's entries, from its Markdown. Lines that aren't entries
    /// (headings, prose) are skipped.
    public static func indexEntries(in markdown: String, listedAt: Date) -> [IndexEntry] {
        markdown.split(whereSeparator: \.isNewline).compactMap { line in
            let text = String(line)
            let range = NSRange(text.startIndex..., in: text)
            guard let match = indexLine.firstMatch(in: text, range: range),
                  let title = Range(match.range(at: 1), in: text),
                  let file = Range(match.range(at: 2), in: text)
            else { return nil }
            let hook = Range(match.range(at: 3), in: text)
                .map { text[$0].trimmingCharacters(in: .whitespaces) }
                .flatMap { $0.isEmpty ? nil : $0 }
            return IndexEntry(title: String(text[title]), file: String(text[file]), hook: hook, listedAt: listedAt)
        }
    }

    // Force-unwrap is safe: the pattern is a compile-time constant.
    private static let indexLine = try! NSRegularExpression(
        pattern: #"^\s*[-*]\s*\[(.+?)\]\(([^)\s]+)\)\s*(?:[—–:-]+\s*(.*))?$"#
    )
}

/// What a session's agent knew, used and learned from memory, derived from
/// its transcript alone: the sources it loaded, and every memory file it
/// opened, created or updated with its file tools. It shows memory as that
/// session saw it, so it works the same for an old session, a remote one, or
/// one whose memories have since changed.
public struct SessionMemory: Sendable, Hashable {

    public struct Event: Sendable, Hashable {
        public enum Kind: Sendable, Hashable {
            case opened, created, updated
        }

        public let kind: Kind
        public let at: Date
        /// The assistant turn that made the call: where "jump to moment" lands.
        public let turnUUID: String
        public let toolUseID: String
        /// What the session wrote: the whole file for a create or a rewrite,
        /// the new text for an edit. nil for an open.
        public let written: String?
        /// The text an edit replaced.
        public let replaced: String?
    }

    public struct Memory: Sendable, Hashable, Identifiable {
        public var id: String { path }
        public let path: String
        public var title: String
        public var hook: String?
        /// `user`, `feedback`, `project` or `reference`, when the session saw
        /// the file's frontmatter.
        public var type: String?
        /// When the index first listed it, if that was before this session
        /// created it: the agent had it in memory from then on. nil for a
        /// memory the session created, or only ever touched.
        public var knownSince: Date?
        public var events: [Event]

        public var wasKnown: Bool { knownSince != nil }

        public var wasOpened: Bool { events.contains { $0.kind == .opened } }
        public var wasCreated: Bool { events.contains { $0.kind == .created } }
        public var wasChanged: Bool { events.contains { $0.kind != .opened } }
    }

    /// Instruction files and indexes, in load order.
    public let sources: [MemorySource]
    /// The index's memories in its order, then those first seen mid-session.
    public let memories: [Memory]

    public var isEmpty: Bool { sources.isEmpty && memories.isEmpty }
    public var knownCount: Int { memories.count { $0.wasKnown } }
    public var openedCount: Int { memories.count { $0.wasOpened } }
    public var createdCount: Int { memories.count { $0.wasCreated } }
    public var updatedCount: Int { memories.count { $0.wasChanged && !$0.wasCreated } }

    /// The memory and event a tool call made, for the transcript's marker.
    public func event(forToolUseID id: String) -> (memory: Memory, event: Event)? {
        for memory in memories {
            if let event = memory.events.first(where: { $0.toolUseID == id }) { return (memory, event) }
        }
        return nil
    }

    public init(_ transcript: AgentTranscript) {
        sources = transcript.memorySources
        var memories: [Memory] = []
        var position: [String: Int] = [:]

        // What the index listed is what the agent had in memory.
        for index in transcript.memorySources where index.kind == .memoryIndex {
            let folder = (index.path as NSString).deletingLastPathComponent
            for entry in index.entries {
                let path = (folder as NSString).appendingPathComponent(entry.file)
                guard position[path] == nil else { continue }
                position[path] = memories.count
                memories.append(Memory(path: path, title: entry.title, hook: entry.hook,
                                       knownSince: entry.listedAt, events: []))
            }
        }

        for turn in transcript.turns {
            guard case let .assistant(turnUUID, blocks, timestamp) = turn else { continue }
            for case let .toolUse(id, name, input) in blocks {
                guard let call = FileCall(name: name, input: input), Self.isMemoryFile(call.path) else { continue }
                let result = transcript.toolResultsByID[id]
                guard result?.isError != true else { continue }

                let index: Int
                if let known = position[call.path] {
                    index = known
                } else {
                    index = memories.count
                    position[call.path] = index
                    let name = ((call.path as NSString).lastPathComponent as NSString).deletingPathExtension
                    memories.append(Memory(path: call.path, title: name, knownSince: nil, events: []))
                }

                let kind: Event.Kind
                switch call.action {
                case .read: kind = .opened
                case .edit: kind = .updated
                case .write:
                    // Claude Code answers a new file with "File created
                    // successfully"; before the result lands, a file nobody
                    // has seen yet is new.
                    let seenBefore = memories[index].knownSince.map { $0 <= timestamp }
                        ?? !memories[index].events.isEmpty
                    let isNew = result.map { $0.content.contains("created successfully") } ?? !seenBefore
                    kind = isNew ? .created : .updated
                    // Listed only after this session wrote it: learned here.
                    if isNew, let since = memories[index].knownSince, since >= timestamp {
                        memories[index].knownSince = nil
                    }
                }
                memories[index].events.append(Event(
                    kind: kind, at: timestamp, turnUUID: turnUUID, toolUseID: id,
                    written: call.written, replaced: call.replaced))

                let text = call.action == .read ? result.map { Self.stripLineNumbers($0.content) } : call.written
                if let text, call.action != .edit {
                    let front = Self.frontmatter(text)
                    if !memories[index].wasKnown, let name = front.name { memories[index].title = name }
                    if memories[index].hook == nil { memories[index].hook = front.description }
                    if let type = front.type { memories[index].type = type }
                }
            }
        }
        self.memories = memories
    }

    // MARK: - Recognising memory files

    /// Claude Code keeps auto-memory at
    /// `<config dir>/projects/<project>/memory/<name>.md`, with the index as
    /// `MEMORY.md` beside the memories. The index itself is bookkeeping, not
    /// a memory.
    public static func isMemoryFile(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        guard parts.count >= 4,
              parts[parts.count - 2] == "memory",
              parts[parts.count - 4] == "projects",
              parts.last.map({ $0.hasSuffix(".md") && $0 != "MEMORY.md" }) == true
        else { return false }
        return true
    }

    private struct FileCall {
        enum Action { case read, write, edit }
        let action: Action
        let path: String
        let written: String?
        let replaced: String?

        init?(name: String, input: String) {
            guard ["Read", "Write", "Edit", "MultiEdit"].contains(name),
                  let object = (try? JSONSerialization.jsonObject(with: Data(input.utf8))) as? [String: Any],
                  let path = object["file_path"] as? String
            else { return nil }
            self.path = path
            switch name {
            case "Read":
                action = .read
                written = nil
                replaced = nil
            case "Write":
                action = .write
                written = object["content"] as? String
                replaced = nil
            case "Edit":
                action = .edit
                written = object["new_string"] as? String
                replaced = object["old_string"] as? String
            case "MultiEdit":
                action = .edit
                let edits = object["edits"] as? [[String: Any]] ?? []
                written = edits.compactMap { $0["new_string"] as? String }.joined(separator: "\n…\n")
                replaced = edits.compactMap { $0["old_string"] as? String }.joined(separator: "\n…\n")
            default:
                return nil
            }
        }
    }

    // MARK: - Frontmatter

    struct Frontmatter: Equatable {
        var name: String?
        var description: String?
        var type: String?
    }

    /// `name`, `description` and `type` from a memory file's leading
    /// `---` block, at any indentation (`type` sits under `metadata:`).
    static func frontmatter(_ text: String) -> Frontmatter {
        var result = Frontmatter()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return result }
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colon]
            var value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            guard !value.isEmpty else { continue }
            switch key {
            case "name" where result.name == nil: result.name = value
            case "description" where result.description == nil: result.description = value
            case "type" where result.type == nil: result.type = value
            default: break
            }
        }
        return result
    }

    /// The file inside a Read result. The tool numbers each line of the file
    /// (`1\t---`) and may put notes of its own around them (a
    /// `<system-reminder>` saying how old the memory is), so the file is the
    /// numbered lines, without their numbers.
    static func stripLineNumbers(_ text: String) -> String {
        let numbered = text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line -> Substring? in
            guard let tab = line.firstIndex(of: "\t") else { return nil }
            let number = line[..<tab].trimmingCharacters(in: .whitespaces)
            guard !number.isEmpty, number.allSatisfy(\.isNumber) else { return nil }
            return line[line.index(after: tab)...]
        }
        return numbered.isEmpty ? text : numbered.joined(separator: "\n")
    }
}
