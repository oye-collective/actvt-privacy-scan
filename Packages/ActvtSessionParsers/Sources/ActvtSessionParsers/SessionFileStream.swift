//
//  SessionFileStream.swift
//  ActvtSessionParsers
//

import Foundation
import CZstd

/// A session file's content, read front to back in chunks.
///
/// Most transcripts are plain `.jsonl`. The Codex desktop app compresses
/// rollouts older than about a week into `.jsonl.zst` (T-024,
/// oye-collective/actvt-macos#53), so a `.zst` file is decoded as it is read,
/// with bounded buffers. Every byte count and offset here is in content
/// (decoded) bytes, which is what the line reader and transcript windows
/// mean by a position in the file. Decode only.
public final class SessionFileStream {

    public enum Failure: Error, CustomStringConvertible {
        case decoder(String)
        public var description: String {
            switch self {
            case .decoder(let message): "zstd: \(message)"
            }
        }
    }

    /// Whether `url` names a compressed transcript.
    public static func isCompressed(_ url: URL) -> Bool {
        url.pathExtension == "zst"
    }

    private let handle: FileHandle
    private let dstream: OpaquePointer?
    private var input: [UInt8] = []
    private var inputPosition = 0
    private var inputEnded = false

    public init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        guard Self.isCompressed(url) else {
            dstream = nil
            return
        }
        guard let stream = ZSTD_createDStream() else {
            try? handle.close()
            throw Failure.decoder("could not create a decoder")
        }
        ZSTD_initDStream(stream)
        dstream = stream
    }

    deinit {
        if let dstream { ZSTD_freeDStream(dstream) }
        try? handle.close()
    }

    /// Up to `count` content bytes, or nil at the end.
    public func read(upToCount count: Int) throws -> Data? {
        guard let dstream else {
            let chunk = try handle.read(upToCount: count)
            return chunk?.isEmpty == false ? chunk : nil
        }
        var output = Data(count: count)
        while true {
            var produced = 0
            let position = inputPosition
            var consumed = position
            let result = input.withUnsafeBytes { source in
                output.withUnsafeMutableBytes { destination in
                    var inBuffer = ZSTD_inBuffer(src: source.baseAddress, size: source.count, pos: position)
                    var outBuffer = ZSTD_outBuffer(dst: destination.baseAddress, size: count, pos: 0)
                    let result = ZSTD_decompressStream(dstream, &outBuffer, &inBuffer)
                    consumed = inBuffer.pos
                    produced = outBuffer.pos
                    return result
                }
            }
            inputPosition = consumed
            if ZSTD_isError(result) != 0 {
                throw Failure.decoder(String(cString: ZSTD_getErrorName(result)))
            }
            if produced > 0 { return output.prefix(produced) }
            if inputPosition < input.count { continue }
            // The decoder holds nothing more for this input: read the next
            // compressed chunk, or stop at the end of the file. A file cut
            // short ends where its data does.
            if inputEnded { return nil }
            let chunk = try handle.read(upToCount: ZSTD_DStreamInSize()) ?? Data()
            if chunk.isEmpty {
                inputEnded = true
            } else {
                input = [UInt8](chunk)
                inputPosition = 0
            }
        }
    }

    /// Move to content offset `offset`, from the start of a stream not yet
    /// read. A compressed file is decoded up to it.
    public func seek(toOffset offset: UInt64) throws {
        guard dstream != nil else {
            try handle.seek(toOffset: offset)
            return
        }
        var remaining = offset
        while remaining > 0 {
            guard let chunk = try read(upToCount: Int(min(remaining, 256 * 1024))) else { return }
            remaining -= UInt64(chunk.count)
        }
    }

    /// The number of content bytes in the file at `url`: its size on disk,
    /// or, compressed, the size it decodes to.
    public static func contentSize(of url: URL) throws -> UInt64 {
        guard isCompressed(url) else {
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
            return size?.uint64Value ?? 0
        }
        let stream = try SessionFileStream(url: url)
        var total: UInt64 = 0
        while let chunk = try stream.read(upToCount: 1024 * 1024) { total += UInt64(chunk.count) }
        return total
    }
}
