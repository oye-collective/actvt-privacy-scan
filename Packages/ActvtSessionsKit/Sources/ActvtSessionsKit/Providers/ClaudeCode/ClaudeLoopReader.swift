//
//  ClaudeLoopReader.swift
//  ActvtSessionsKit
//

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A loop agent's last tick, read back from its transcript: what it said
/// when it went to sleep, and whether it has woken since.
struct ClaudeLoopTick: Equatable, Sendable {
    /// When the agent called `ScheduleWakeup`.
    let scheduledAt: Date
    /// When it said it would be back.
    let wakesAt: Date
    let reason: String?
    /// The agent's own word on whether the tick did anything.
    let noop: Bool?
    /// A turn is open: the agent is awake and working, or it died or hung
    /// mid-turn, which only a time limit can tell apart.
    let turnInProgress: Bool
    /// The newest record's own timestamp, never the file's mtime: a file can
    /// keep changing after its agent has stopped writing records.
    let lastActivityAt: Date
}

/// Reads a Claude Code transcript as a loop: the last `ScheduleWakeup` call
/// and what has happened since.
///
/// A loop ends each tick with the call, closes the turn (`end_turn`) and
/// writes nothing until it is woken (`scheduled_task_fire`, then its prompt).
/// The call can sit megabytes back: a tick that reads large files writes them
/// into the transcript, so mid-tick the last call is often far beyond a
/// fixed tail (11 MB between two calls on dgx, 2026-10-12). The file is
/// therefore searched backwards for it.
enum ClaudeLoopReader {

    /// The call as it appears in a record. Inside a string (a command that
    /// mentions it, a tool result quoting it) the quotes are escaped, so
    /// those never match; each match is still parsed before it counts.
    private static let callMarker = Array(#""name":"ScheduleWakeup""#.utf8)
    static let chunkSize = 1 << 20

    /// The last tick of the transcript at `url`, or nil when it never
    /// scheduled a wake or its last call ended the loop (`stop`).
    static func lastTick(fileURL url: URL) throws -> ClaudeLoopTick? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let start = try lastCallLineStart(in: handle) else { return nil }
        try handle.seek(toOffset: start)
        let rest = try handle.readToEnd() ?? Data()
        let lines = rest.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
        return lastTick(in: lines)
    }

    /// The last tick in `lines`, read in order. The same rule as the
    /// session summary's `wakesAt`: the latest call wins whatever follows it,
    /// a `stop` ends the loop, and a user turn in between keeps the schedule.
    static func lastTick(in lines: [Data]) -> ClaudeLoopTick? {
        var tick: ClaudeLoopTick?
        var turnInProgress = false
        var lastActivityAt: Date?

        for data in lines {
            if let timestamp = recordTimestamp(data) {
                lastActivityAt = max(lastActivityAt ?? timestamp, timestamp)
            }
            switch ClaudeTranscriptParser.parseLine(data) {
            case let .assistant(_, blocks, timestamp, false, meta)?:
                for case let .toolUse(_, name, input) in blocks where name == "ScheduleWakeup" {
                    let arguments = (try? JSONSerialization.jsonObject(with: Data(input.utf8))) as? [String: Any]
                    if arguments?["stop"] as? Bool == true {
                        tick = nil
                    } else if let delay = arguments?["delaySeconds"] as? NSNumber {
                        // NSNumber, not Double: on Linux an integral JSON number
                        // does not bridge to Double, and the CLI runs there.
                        tick = ClaudeLoopTick(
                            scheduledAt: timestamp,
                            wakesAt: timestamp.addingTimeInterval(delay.doubleValue),
                            reason: arguments?["reason"] as? String,
                            noop: (arguments?["noop"] as? NSNumber)?.boolValue,
                            turnInProgress: false,
                            lastActivityAt: timestamp
                        )
                    }
                }
                turnInProgress = meta.stopReason != "end_turn"
            case .userText(_, _, _, _, _, false)?, .userToolResults(_, _, _, false)?:
                turnInProgress = true
            default:
                break
            }
        }

        guard let tick else { return nil }
        return ClaudeLoopTick(
            scheduledAt: tick.scheduledAt, wakesAt: tick.wakesAt, reason: tick.reason, noop: tick.noop,
            turnInProgress: turnInProgress, lastActivityAt: lastActivityAt ?? tick.scheduledAt
        )
    }

    // MARK: - Finding the call

    /// The offset of the line holding the last real `ScheduleWakeup` call,
    /// searching backwards a chunk at a time. A session that never scheduled
    /// is read whole, which costs about 0.5 s for all of a busy host's
    /// transcripts (1.8 GB on dgx, 1.2 GB on mac-bar, 2026-10-12).
    private static func lastCallLineStart(in handle: FileHandle) throws -> UInt64? {
        let size = try handle.seekToEnd()
        var end = size
        while end > 0 {
            // Overlap by the marker's length so a match across chunks is found.
            let start = end > UInt64(chunkSize) ? end - UInt64(chunkSize) : 0
            try handle.seek(toOffset: start)
            let chunk = [UInt8](try handle.read(upToCount: Int(end - start)) ?? Data())
            for offset in matchOffsets(in: chunk).reversed() {
                let lineStart = try lineStartOffset(before: start + UInt64(offset), in: handle)
                if try isCall(lineAt: lineStart, in: handle) { return lineStart }
            }
            guard start > 0 else { break }
            end = start + UInt64(callMarker.count - 1)
            if end >= size { break }
        }
        return nil
    }

    private static func matchOffsets(in chunk: [UInt8]) -> [Int] {
        var offsets: [Int] = []
        chunk.withUnsafeBytes { buffer in
            callMarker.withUnsafeBytes { marker in
                // Glibc's memmem takes non-optional pointers, Darwin's optionals.
                guard let base = buffer.baseAddress, let markerBase = marker.baseAddress else { return }
                var from = 0
                while from < buffer.count,
                      let hit = memmem(base + from, buffer.count - from, markerBase, marker.count) {
                    let offset = base.distance(to: UnsafeRawPointer(hit))
                    offsets.append(offset)
                    from = offset + 1
                }
            }
        }
        return offsets
    }

    /// Records holding the call are small, so the newline before it is near.
    private static func lineStartOffset(before position: UInt64, in handle: FileHandle) throws -> UInt64 {
        var end = position
        while end > 0 {
            let start = end > 4096 ? end - 4096 : 0
            try handle.seek(toOffset: start)
            let window = [UInt8](try handle.read(upToCount: Int(end - start)) ?? Data())
            if let newline = window.lastIndex(of: 0x0A) { return start + UInt64(newline) + 1 }
            end = start
        }
        return 0
    }

    private static func isCall(lineAt offset: UInt64, in handle: FileHandle) throws -> Bool {
        try handle.seek(toOffset: offset)
        var line = Data()
        while let piece = try handle.read(upToCount: 64 * 1024), !piece.isEmpty {
            if let newline = piece.firstIndex(of: 0x0A) {
                line += piece[piece.startIndex..<newline]
                break
            }
            line += piece
        }
        guard case let .assistant(_, blocks, _, false, _)? = ClaudeTranscriptParser.parseLine(line) else { return false }
        return blocks.contains { if case let .toolUse(_, name, _) = $0 { return name == "ScheduleWakeup" } else { return false } }
    }

    /// Any record's own `timestamp`, including the ones the transcript
    /// parser skips (queue operations, attachments, turn durations).
    private static func recordTimestamp(_ data: Data) -> Date? {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return ClaudeTranscriptParser.parseTimestamp(object?["timestamp"])
    }
}
