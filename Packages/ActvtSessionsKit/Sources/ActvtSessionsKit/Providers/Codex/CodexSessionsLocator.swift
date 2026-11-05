//
//  CodexSessionsLocator.swift
//  Actvt
//

import Foundation

/// Filesystem walk for `~/.codex/sessions/` — the directory the Codex CLI uses
/// to persist session transcripts.
///
/// On-disk layout (verified empirically):
///
/// ```
/// ~/.codex/sessions/
///   └── <YYYY>/<MM>/<DD>/
///        └── rollout-<ISO-ts>-<sessionUUID>.jsonl   ← one session transcript
/// ```
///
/// The session id is the trailing UUIDv7 in the filename (it also appears as
/// `session_meta.id` inside the file, but Tier-1 listing is stat-only and never
/// opens the file). Legacy flat `~/.codex/sessions/rollout-<date>-<uuid>.json`
/// files (a single `{session, items}` object, pre late-2025) are intentionally
/// skipped — they carry no per-record timestamps, so metrics would be degraded.
public enum CodexSessionsLocator {

    /// Default location: `~/.codex/sessions/`.
    public static var defaultSessionsURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    /// One row per `rollout-*.jsonl` file. Lightweight — directory enumeration
    /// + `stat` only, no file content reads. Mirrors
    /// `ClaudeProjectsLocator.DiscoveredSession` (minus the sidecar key, which
    /// Codex doesn't have).
    struct DiscoveredSession: Sendable, Hashable {
        let sessionId: String
        let fileURL: URL
        let lastUpdatedAt: Date
    }

    /// Trailing-UUID matcher for `rollout-<ts>-<uuid>.jsonl` filenames.
    private static let uuidSuffix = try! NSRegularExpression(
        pattern: #"([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$"#
    )

    /// Walk the date-bucketed sessions tree and return one row per
    /// `rollout-*.jsonl`. Returns `[]` if the directory doesn't exist (Codex not
    /// installed). A single `enumerator` pass handles the `YYYY/MM/DD` nesting.
    static func discoverSessions(at root: URL = defaultSessionsURL) throws -> [DiscoveredSession] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var results: [DiscoveredSession] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            // Current format only: `rollout-*.jsonl`. Skips legacy flat `.json`
            // and any non-session files that share the tree.
            guard url.pathExtension == "jsonl", name.hasPrefix("rollout-") else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            guard let sessionId = sessionId(fromFileName: name) else { continue }
            let mtime = values?.contentModificationDate ?? Date.distantPast
            results.append(DiscoveredSession(sessionId: sessionId, fileURL: url, lastUpdatedAt: mtime))
        }
        return results
    }

    /// Cheaper, scoped variant of `discoverSessions` for the live FS-event path:
    /// walk only the newest `dayBucketLimit` `YYYY/MM/DD` directories instead of
    /// re-stat-ing the entire multi-year tree on every coalesced event. New
    /// sessions and appends to recently-created sessions land in these buckets;
    /// the caller merges the result over its retained full-walk map, and the
    /// periodic/focus full walk reconciles anything older (stale mtime, deletes).
    /// Resilient: returns whatever it can read, `[]` on a missing root.
    static func discoverRecentSessions(at root: URL = defaultSessionsURL,
                                       dayBucketLimit: Int) throws -> [DiscoveredSession] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        var results: [DiscoveredSession] = []
        for bucket in recentDayBuckets(at: root, limit: dayBucketLimit, fm: fm) {
            guard let entries = try? fm.contentsOfDirectory(
                at: bucket, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            ) else { continue }
            for url in entries {
                let name = url.lastPathComponent
                guard url.pathExtension == "jsonl", name.hasPrefix("rollout-") else { continue }
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard values?.isRegularFile == true else { continue }
                guard let sessionId = sessionId(fromFileName: name) else { continue }
                let mtime = values?.contentModificationDate ?? Date.distantPast
                results.append(DiscoveredSession(sessionId: sessionId, fileURL: url, lastUpdatedAt: mtime))
            }
        }
        return results
    }

    /// The newest `limit` day-leaf directories (`root/YYYY/MM/DD`), found via
    /// directory listings only (no per-file stat). Descends newest-name-first at
    /// each level and stops early once `limit` buckets are collected; the fixed
    /// zero-padded `YYYY/MM/DD` layout makes lexical order chronological.
    private static func recentDayBuckets(at root: URL, limit: Int, fm: FileManager) -> [URL] {
        func sortedSubdirs(_ dir: URL) -> [URL] {
            guard let items = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { return [] }
            return items
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
        }

        var days: [URL] = []
        for year in sortedSubdirs(root) {
            for month in sortedSubdirs(year) {
                for day in sortedSubdirs(month) {
                    days.append(day)
                    if days.count >= limit { return days }
                }
            }
        }
        return days
    }

    // MARK: - Sub-agents

    /// A sub-agent's rollout names the session that spawned it in its first
    /// record: `session_meta.payload.parent_thread_id` (Codex 0.163; also under
    /// `source.subagent.thread_spawn`). The field comes before the long
    /// `instructions`, within the first few hundred bytes of a ~19 KB line, so a
    /// bounded prefix answers without reading or parsing the whole record.
    private static let parentThreadPattern = try! NSRegularExpression(
        pattern: #""parent_thread_id"\s*:\s*"([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})""#
    )
    static let headerPrefixBytes = 4096

    /// The id of the session that spawned the rollout at `url` (nil for a
    /// session a person started), and whether that is final. A rollout's first
    /// record never changes, so a final answer holds for as long as the file
    /// exists. One read before Codex has finished writing that record (a file
    /// just created, or unreadable) is not final.
    static func parentThreadId(ofRolloutAt url: URL) -> (id: String?, final: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (nil, false) }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: headerPrefixBytes) else { return (nil, false) }
        let head = data.prefix { $0 != 0x0A }           // the first record only
        let final = head.count < data.count || data.count >= headerPrefixBytes
        let text = String(decoding: head, as: UTF8.self)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = parentThreadPattern.firstMatch(in: text, range: range),
              let r = Range(match.range(at: 1), in: text)
        else { return (nil, final) }
        return (String(text[r]), true)
    }

    /// The listed sessions, each with the sub-agents it spawned, nested ones
    /// included. A rollout whose parent is listed belongs to that parent's root
    /// and is not a session of its own. One whose parent isn't listed (pruned,
    /// or on another machine) stands as its own session, so its work is never
    /// lost. `parentOf` gives the spawning session's id, if any.
    static func group(_ sessions: [String: DiscoveredSession],
                      parentOf: (DiscoveredSession) -> String?) -> [String: [DiscoveredSession]] {
        func root(of session: DiscoveredSession) -> String {
            var id = session.sessionId
            var seen: Set<String> = [id]
            while let next = sessions[id].flatMap(parentOf), sessions[next] != nil {
                // Parents that name each other in a loop can't come from Codex;
                // each then stands as its own session rather than vanishing.
                guard seen.insert(next).inserted else { return session.sessionId }
                id = next
            }
            return id
        }
        var groups: [String: [DiscoveredSession]] = [:]
        for session in sessions.values {
            let top = root(of: session)
            if top == session.sessionId {
                groups[top, default: []] += []
            } else {
                groups[top, default: []].append(session)
            }
        }
        return groups
    }

    /// Extract the trailing session UUID from a `rollout-<ts>-<uuid>.jsonl`
    /// filename. Returns `nil` if the name doesn't end in a UUID (e.g. a
    /// malformed or legacy file), so the caller skips it.
    static func sessionId(fromFileName name: String) -> String? {
        let stem = (name as NSString).deletingPathExtension
        let range = NSRange(stem.startIndex..<stem.endIndex, in: stem)
        guard let match = uuidSuffix.firstMatch(in: stem, range: range),
              let r = Range(match.range(at: 1), in: stem)
        else {
            return nil
        }
        return String(stem[r])
    }
}
