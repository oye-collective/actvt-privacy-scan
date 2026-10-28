//
//  DirectoryFSWatcher.swift
//  Actvt
//

#if canImport(CoreServices)

import Foundation
import CoreServices
import os.log

/// Recursive FSEvents watcher over an arbitrary directory root, so new sessions
/// and appended turns surface without waiting for the next app-focus refresh.
/// Shared by every file-backed `AgentSessionSource` (Claude Code, Codex, …) —
/// the logic is root-agnostic.
///
/// Concurrency: an `actor` owns all mutable state (the stream, the callback). The
/// FSEvents C callback can't capture context, so it recovers the watcher from the
/// `context.info` pointer — a **retained** `Unmanaged` reference (released in
/// `stopStream()`), which keeps the actor alive for the stream's lifetime and
/// avoids a dangling pointer without `nonisolated(unsafe)`. FSEvents' own
/// `latency` coalesces bursts, so no hand-rolled debounce is needed; each batched
/// callback hops back onto the actor to invoke `onChange`.
public actor DirectoryFSWatcher: AgentSessionWatcher {
    private let root: URL
    private let queue = DispatchQueue(label: "com.actvt.io.DirectoryFSWatcher", qos: .utility)
    private nonisolated let logger = Logger(subsystem: "com.actvt.io", category: "DirectoryFSWatcher")

    private var stream: FSEventStreamRef?
    private var onChange: (@Sendable () -> Void)?
    private var selfPtr: UnsafeMutableRawPointer?

    /// Coalescing window (seconds). A burst of writes within this window yields a
    /// single callback — matches the `AgentSessionWatcher` debounce contract.
    private static let latency: CFTimeInterval = 0.5

    public init(root: URL) {
        self.root = root
    }

    public func start(onChange: @Sendable @escaping () -> Void) async {
        // Re-`start` replaces the callback and restarts the stream.
        stopStream()
        self.onChange = onChange

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            logger.debug("watch root missing; not starting: \(self.root.path, privacy: .public)")
            return
        }

        let ptr = Unmanaged.passRetained(self).toOpaque()
        selfPtr = ptr
        var context = FSEventStreamContext(
            version: 0, info: ptr, retain: nil, release: nil, copyDescription: nil
        )

        // Capture-free closure → convertible to the C function pointer. Recovers
        // the actor from `info` and hops back onto it to fire the callback.
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryFSWatcher>.fromOpaque(info).takeUnretainedValue()
            Task { await watcher.fire() }
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        ) else {
            logger.error("FSEventStreamCreate failed for \(self.root.path, privacy: .public)")
            Unmanaged<DirectoryFSWatcher>.fromOpaque(ptr).release()
            selfPtr = nil
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    public func stop() async {
        stopStream()
    }

    // MARK: - Internals

    private func stopStream() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        if let ptr = selfPtr {
            Unmanaged<DirectoryFSWatcher>.fromOpaque(ptr).release()
            selfPtr = nil
        }
        onChange = nil
    }

    /// Invoked (on the actor) for each coalesced FSEvents batch.
    private func fire() {
        onChange?()
    }
}

#endif
