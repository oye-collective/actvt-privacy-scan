//
//  AgentTranscriptLineReader.swift
//  ActvtSessionParsers
//

import Foundation

/// Streams a JSONL transcript line-by-line without slurping the whole file into a
/// single `String`. Reads in fixed-size chunks through a `FileHandle`, yielding
/// each newline-delimited line's UTF-8 bytes as `Data`; only one chunk plus the
/// current partial line is resident at a time, so peak memory stays bounded
/// regardless of transcript size. Splits on `\n` only and skips empty lines —
/// matching the previous `String(contentsOf:).split(separator: "\n",
/// omittingEmptySubsequences: true)` behaviour (any trailing `\r` is preserved
/// in the line bytes, exactly as before). Shared by the agent metrics
/// extractors (app) and the transcript materializers (this package).
public enum AgentTranscriptLineReader {
    /// Buffered read granularity (256 KiB).
    private static let chunkSize = 256 * 1024
    private static let newline: UInt8 = 0x0A

    public static func forEachLine(in fileURL: URL, _ body: (Data) throws -> Void) throws {
        try forEachLine(in: fileURL, startingIn: 0..<UInt64.max) { line, _ in try body(line) }
    }

    /// The lines whose first byte lies in `range`, each with that byte's offset
    /// in the file. A line is always whole: one that starts before
    /// `range.lowerBound` is skipped even if it runs into the range, and one that
    /// starts inside it is read to its end even past `range.upperBound`. So
    /// adjacent ranges (`a..<b`, `b..<c`) read every line exactly once, which is
    /// how a long transcript is read in windows: `range.lowerBound` can be any
    /// byte (a budget back from a cursor) and the window still starts on a line.
    public static func forEachLine(in fileURL: URL, startingIn range: Range<UInt64>,
                                   _ body: (Data, UInt64) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        // Read from the byte before the range: if it ends a line, the range
        // starts on one; otherwise everything up to the next newline belongs to
        // a line that started earlier and is dropped.
        var bufferOffset: UInt64 = range.lowerBound == 0 ? 0 : range.lowerBound - 1
        var skippingPartialLine = range.lowerBound > 0
        if bufferOffset > 0 { try handle.seek(toOffset: bufferOffset) }
        var buffer = Data()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            buffer.append(chunk)
            // Advance a cursor across the buffered chunk emitting each complete
            // line, and compact the consumed prefix only ONCE per chunk. Removing
            // each line from the front individually would memmove the whole
            // remaining tail every line — O(lines²) per chunk for line-dense
            // transcripts. Indices are in Data's 0-based space.
            var lineStart = buffer.startIndex
            var searchStart = lineStart
            while let nl = buffer[searchStart...].firstIndex(of: newline) {
                if skippingPartialLine {
                    skippingPartialLine = false
                } else {
                    let offset = bufferOffset + UInt64(lineStart - buffer.startIndex)
                    guard offset < range.upperBound else { return }
                    if nl > lineStart {
                        try body(buffer.subdata(in: lineStart..<nl), offset)
                    }
                }
                lineStart = buffer.index(after: nl)
                searchStart = lineStart
            }
            if lineStart > buffer.startIndex {
                bufferOffset += UInt64(lineStart - buffer.startIndex)
                buffer.removeSubrange(buffer.startIndex..<lineStart)
            }
        }
        // Trailing line with no terminating newline.
        if !buffer.isEmpty, !skippingPartialLine, bufferOffset < range.upperBound {
            try body(buffer, bufferOffset)
        }
    }
}
