//
//  RemoteLoopPayload+Local.swift
//  ActvtSessionsKit
//

import Foundation

extension RemoteLoopPayload {
    /// The CLI version that introduced `loops`. A host answering the sessions
    /// poll with an older CLI can't list its loops, and is told to update
    /// rather than read as unreachable.
    public static let minimumCLIVersion = "0.7.0"

    /// This machine's loops, read in-process the way `actvt-cli loops --json`
    /// reads them on a remote host, with the CLI's default grace. The app uses
    /// it for "this Mac", so both sides of the Overview's Loops card come from
    /// the same reader and the same rules.
    public static func local(now: Date = Date()) async -> RemoteLoopPayload {
        await CLIRunner.collectLoops(
            source: ClaudeCodeSessionSource(), now: now, grace: CLIRunner.defaultLoopGrace
        )
    }
}
