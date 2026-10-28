//
//  PiSessionsLocator.swift
//  ActvtSessionsKit
//

import Foundation

/// Filesystem walk for the pi coding agent's session store.
///
/// On-disk layout (verified against pi 0.85.1, session format version 3):
///
/// ```
/// ~/.pi/agent/sessions/
///   └── --<cwd with / and : replaced by ->--/
///        └── <YYYY-MM-DDTHH-mm-ss-SSSZ>_<uuid>.jsonl   ← one session tree
/// ```
///
/// The directory name is a lossy encoding of the working directory (a `-`
/// inside a path component is indistinguishable from a `/`), so it is only
/// ever used as an opaque key. The real `cwd` is read from the session header
/// on line 1, the same posture `ClaudeProjectsLocator` takes.
///
/// The filename carries both the session id and its creation time, which is
/// what lets the stat-only Tier 1 listing report `startedAt` without opening a
/// single file.
public enum PiSessionsLocator {

    /// Default location, honoring pi's own overrides in the order pi applies
    /// them: `PI_CODING_AGENT_SESSION_DIR`, then `PI_CODING_AGENT_DIR/sessions`,
    /// then `~/.pi/agent/sessions`.
    public static var defaultSessionsURL: URL {
        defaultSessionsURL(environment: ProcessInfo.processInfo.environment)
    }

    static func defaultSessionsURL(environment: [String: String]) -> URL {
        if let dir = environment["PI_CODING_AGENT_SESSION_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: expandingTilde(dir), isDirectory: true)
        }
        if let agentDir = environment["PI_CODING_AGENT_DIR"], !agentDir.isEmpty {
            return URL(fileURLWithPath: expandingTilde(agentDir), isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
        }
        return FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/sessions", isDirectory: true)
    }

    private static func expandingTilde(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + path.dropFirst()
    }

    /// One row per session file. Directory enumeration and `stat` only.
    struct DiscoveredSession: Sendable, Hashable {
        let sessionId: String
        let fileURL: URL
        /// Creation time parsed from the filename.
        let startedAt: Date
        let lastUpdatedAt: Date
    }

    /// `<YYYY-MM-DD>T<HH>-<mm>-<ss>-<SSS>Z_<uuid>` filename stem.
    private static let stemPattern = try! NSRegularExpression(
        pattern: #"^(\d{4}-\d{2}-\d{2})T(\d{2})-(\d{2})-(\d{2})-(\d{3})Z_([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$"#
    )

    /// Walk `<root>/<slug>/*.jsonl`. Returns `[]` when the root does not exist
    /// (pi not installed). Files whose name is not a pi session stem are
    /// skipped, not errors.
    static func discoverSessions(at root: URL = defaultSessionsURL) throws -> [DiscoveredSession] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        let slugDirs = try fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }

        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        var results: [DiscoveredSession] = []
        for dir in slugDirs {
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            ) else { continue }
            for url in files {
                guard url.pathExtension == "jsonl" else { continue }
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard values?.isRegularFile == true else { continue }
                guard let parsed = parseFileName(url.lastPathComponent) else { continue }
                results.append(DiscoveredSession(
                    sessionId: parsed.sessionId,
                    fileURL: url,
                    startedAt: parsed.startedAt,
                    lastUpdatedAt: values?.contentModificationDate ?? parsed.startedAt
                ))
            }
        }
        return results
    }

    /// Split a session filename into its id and creation time. `nil` when the
    /// name is not in pi's `<timestamp>_<uuid>.jsonl` form.
    static func parseFileName(_ name: String) -> (sessionId: String, startedAt: Date)? {
        let stem = (name as NSString).deletingPathExtension
        let range = NSRange(stem.startIndex..<stem.endIndex, in: stem)
        guard let match = stemPattern.firstMatch(in: stem, range: range) else { return nil }
        func group(_ i: Int) -> String {
            Range(match.range(at: i), in: stem).map { String(stem[$0]) } ?? ""
        }
        let iso = "\(group(1))T\(group(2)):\(group(3)):\(group(4)).\(group(5))Z"
        guard let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(iso) else {
            return nil
        }
        return (group(6).lowercased(), date)
    }
}
