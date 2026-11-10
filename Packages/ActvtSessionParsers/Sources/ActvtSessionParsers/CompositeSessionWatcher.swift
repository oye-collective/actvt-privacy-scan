//
//  CompositeSessionWatcher.swift
//  Actvt
//

#if canImport(CoreServices)

import Foundation

/// An `AgentSessionWatcher` fanning one `DirectoryFSWatcher` out per root, for
/// providers that list sessions from multiple directories (Claude Code's
/// `~/.claude/projects` + the desktop app's embedded stores). Keeps the
/// one-watcher-per-provider protocol shape intact — the store neither knows nor
/// cares how many streams are behind it.
actor CompositeSessionWatcher: AgentSessionWatcher {
    private let watchers: [DirectoryFSWatcher]

    init(roots: [URL]) {
        self.watchers = roots.map { DirectoryFSWatcher(root: $0) }
    }

    func start(onChange: @Sendable @escaping () -> Void) async {
        // Each inner watcher coalesces its own bursts (0.5s FSEvents latency);
        // a change under any root fires the shared callback.
        for watcher in watchers {
            await watcher.start(onChange: onChange)
        }
    }

    func stop() async {
        for watcher in watchers {
            await watcher.stop()
        }
    }
}

#endif
