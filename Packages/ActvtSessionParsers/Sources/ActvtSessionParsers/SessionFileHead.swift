//
//  SessionFileHead.swift
//  ActvtSessionParsers
//

import Foundation

/// The first lines of a session file, which is all a summary reads.
///
/// A summary needs only the head (the first prompt, the cwd, the branch), so
/// it reads at most `byteLimit` content bytes and `maxLines` lines, and never
/// a whole multi-megabyte transcript. `isWholeFile` says whether `lines` are
/// every line the file holds: only then is a count taken over them the
/// session's count rather than its head's (B-065). A long session's full
/// count is the metrics index's.
public struct SessionFileHead: Sendable {
    public static let byteLimit = 256 * 1024

    /// The head's complete lines, empty ones skipped. A last piece with no
    /// newline yet, a record still being written, is left out.
    public let lines: [Data]

    /// True when the read reached the end of the file and no line was left
    /// out for `maxLines`.
    public let isWholeFile: Bool

    public init(url: URL, maxLines: Int) throws {
        let stream = try SessionFileStream(url: url)
        var chunk = Data()
        var ended = false
        // A compressed file decodes in batches, so one read can stop short of
        // the limit before the end: read until either.
        while chunk.count < Self.byteLimit {
            guard let more = try stream.read(upToCount: Self.byteLimit - chunk.count) else {
                ended = true
                break
            }
            chunk.append(more)
        }
        if !ended { ended = try stream.read(upToCount: 1) == nil }

        var lines: [Data] = []
        lines.reserveCapacity(min(maxLines, 64))
        var start = chunk.startIndex
        var cutShort = false
        for i in chunk.indices where chunk[i] == 0x0A {
            if lines.count == maxLines {
                cutShort = true
                break
            }
            if start < i { lines.append(chunk.subdata(in: start..<i)) }
            start = chunk.index(after: i)
        }
        self.lines = lines
        self.isWholeFile = ended && !cutShort
    }
}
