//
//  ClaudeDesktopProjectsLocator.swift
//  Actvt
//

import Foundation

/// Discovers Claude *Desktop* transcript roots under
/// `~/Library/Application Support/Claude/`. The desktop app's local agent mode
/// keeps session stores in per-workspace trees whose exact nesting varies by
/// version, so we BFS a bounded depth looking for directories named `projects`
/// (the same layout `~/.claude/projects` uses) rather than hardcoding one path.
/// Approach ported from CodexBar.
///
/// Cheap by construction: the two base directories get a single existence
/// check first (most users have neither), the walk is depth-capped, and big
/// build/dependency trees are skipped by name.
public enum ClaudeDesktopProjectsLocator {

    /// Session-store containers observed under Application Support/Claude.
    private static let sessionDirectoryNames = [
        "local-agent-mode-sessions",
        "claude-code-sessions",
    ]

    /// Directory names never worth descending into — dependency/build trees
    /// that can be enormous and cannot contain a session store.
    private static let skippedDirectoryNames: Set<String> = [
        ".build",
        ".git",
        ".next",
        "build",
        "DerivedData",
        "dist",
        "node_modules",
        "outputs",
        "target",
    ]

    /// BFS depth bound. Observed desktop layouts nest at most
    /// account/workspace → session → agent → local_agent; 4 covers them without
    /// descending into arbitrary checked-out workspaces.
    private static let maxDepth = 4

    /// All `projects` directories under the desktop app's session stores.
    /// Returns `[]` when the desktop app isn't installed / has no local
    /// sessions (the common case, decided by two stat calls).
    public static func discoverRoots(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [URL] {
        let claudeApplicationSupport = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Claude", isDirectory: true)
        return sessionDirectoryNames.flatMap {
            discoverRoots(
                under: claudeApplicationSupport.appendingPathComponent($0, isDirectory: true),
                fileManager: fileManager
            )
        }
    }

    /// BFS one session-store base for embedded `projects` directories.
    /// Exposed for tests (temp-dir fixtures).
    public static func discoverRoots(under base: URL, fileManager: FileManager = .default) -> [URL] {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: base.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        var roots: [URL] = []
        var queue: [(url: URL, depth: Int)] = [(base, 0)]
        var nextIndex = 0

        while nextIndex < queue.count {
            let (url, depth) = queue[nextIndex]
            nextIndex += 1

            for child in childDirectories(of: url, fileManager: fileManager) {
                let name = child.lastPathComponent
                if name == "projects" {
                    roots.append(child)
                    continue     // a projects root's own children are session dirs
                }
                guard depth + 1 < maxDepth, !skippedDirectoryNames.contains(name) else { continue }
                queue.append((child, depth + 1))
            }
        }

        return roots
    }

    private static func childDirectories(of url: URL, fileManager: FileManager) -> [URL] {
        let children = (try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )) ?? []
        return children.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        }
    }
}
