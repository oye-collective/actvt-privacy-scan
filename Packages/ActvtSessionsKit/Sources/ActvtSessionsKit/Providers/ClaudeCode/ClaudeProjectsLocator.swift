//
//  ClaudeProjectsLocator.swift
//  Actvt
//

import Foundation

/// Filesystem walk for `~/.claude/projects/` — the directory Claude Code uses
/// to persist session transcripts.
///
/// On-disk layout (verified empirically — neither the agent SDK reference nor
/// the VS Code reference exposes this; both delegate to the bundled CLI):
///
/// ```
/// ~/.claude/projects/
///   └── <encoded-cwd>/                 ← one dir per project working directory
///        ├── <sessionId>.jsonl         ← main session transcript
///        ├── <sessionId>/              ← sibling sidecar (NOT a separate session)
///        │    ├── subagents/
///        │    │    ├── agent-<id>.jsonl
///        │    │    └── agent-<id>.meta.json
///        │    └── tool-results/
///        │         └── <id>.txt        ← spillover for large tool outputs
///        └── <sessionId-2>.jsonl
/// ```
///
/// The locator only surfaces top-level `<sessionId>.jsonl` files. Sidecar
/// directories are inspected lazily by `subagentCount(for:)` so the cold-path
/// listing stays cheap.
///
/// Encoded-cwd directory names are opaque — we never decode them. The real
/// `cwd` lives inside the JSONL on user records and is read by the parser.
public enum ClaudeProjectsLocator {

    /// Default location: `~/.claude/projects/`.
    public static var defaultProjectsURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// Alternate config roots: `~/.claude-<something>/projects`.
    ///
    /// Claude Code honours `CLAUDE_CONFIG_DIR`, and people running more than one
    /// account — consultants, or anyone splitting work and personal — point it
    /// at directories beside the default. Without this, those sessions are
    /// simply missing, and the app shows a partial picture *without saying so*,
    /// which is the worst kind of wrong: the totals look complete.
    ///
    /// Only directories that actually contain a `projects` subdirectory are
    /// returned, so unrelated `~/.claude-*` files (a backup tarball, an editor
    /// swap file) never become roots. Sorted for deterministic ordering.
    public static func discoverAlternateProjectsURLs(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        let fm = FileManager.default
        // Enumerated by name rather than by URL: the URL-based API's
        // `.skipsHiddenFiles` would drop every dot-directory, which is all of them.
        guard let names = try? fm.contentsOfDirectory(atPath: home.path) else { return [] }
        return names
            .filter { $0.hasPrefix(".claude-") }
            .sorted()
            .map { home.appendingPathComponent($0, isDirectory: true)
                       .appendingPathComponent("projects", isDirectory: true) }
            .filter { url in
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
            }
    }

    /// One row per top-level `<sessionId>.jsonl` file. Lightweight — no file
    /// content reads, only directory enumeration + `stat`.
    public struct DiscoveredSession: Sendable, Hashable {
        public let sessionId: String
        public let fileURL: URL
        public let lastUpdatedAt: Date
        /// The opaque encoded-cwd directory name. Kept only as a stable key
        /// for the sidecar directory; not used for display.
        public let projectDirName: String
    }

    /// Walk the projects directory and return one row per `*.jsonl`.
    /// Returns `[]` if the directory doesn't exist (Claude Code not installed).
    public static func discoverSessions(at root: URL = defaultProjectsURL) throws -> [DiscoveredSession] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        // One level of subdirectories — each is an encoded cwd.
        let projectDirs = try fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )

        var results: [DiscoveredSession] = []
        results.reserveCapacity(projectDirs.count * 4)

        for projectDir in projectDirs {
            let dirIsDir = (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard dirIsDir else { continue }

            let files: [URL]
            do {
                files = try fm.contentsOfDirectory(
                    at: projectDir,
                    includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
                )
            } catch {
                continue
            }

            for file in files {
                guard file.pathExtension == "jsonl" else { continue }
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values?.isRegularFile == true else { continue }
                let mtime = values?.contentModificationDate ?? Date.distantPast

                let sessionId = file.deletingPathExtension().lastPathComponent
                results.append(DiscoveredSession(
                    sessionId: sessionId,
                    fileURL: file,
                    lastUpdatedAt: mtime,
                    projectDirName: projectDir.lastPathComponent
                ))
            }
        }

        return results
    }

    /// The sidecar directory for a session — used to enumerate subagent
    /// transcripts. Returns the URL even when the directory doesn't exist;
    /// callers check existence themselves.
    public static func sidecarDirectory(for session: DiscoveredSession, root: URL = defaultProjectsURL) -> URL {
        root
            .appendingPathComponent(session.projectDirName, isDirectory: true)
            .appendingPathComponent(session.sessionId, isDirectory: true)
    }

    /// Cheap count of subagent transcripts for a session. Globs
    /// `<sessionId>/subagents/*.meta.json` — no file content reads.
    public static func subagentCount(for session: DiscoveredSession, root: URL = defaultProjectsURL) -> Int {
        let subagentsDir = sidecarDirectory(for: session, root: root)
            .appendingPathComponent("subagents", isDirectory: true)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: subagentsDir.path, isDirectory: &isDir), isDir.boolValue else {
            return 0
        }
        let files = (try? fm.contentsOfDirectory(
            at: subagentsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []
        return files.reduce(0) { $0 + ($1.pathExtension == "json" && $1.lastPathComponent.hasSuffix(".meta.json") ? 1 : 0) }
    }
}
