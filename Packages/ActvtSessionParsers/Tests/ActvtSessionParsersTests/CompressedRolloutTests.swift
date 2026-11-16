//
//  CompressedRolloutTests.swift
//  ActvtSessionParsersTests
//

import XCTest
@testable import ActvtSessionParsers

/// The Codex desktop app compresses old rollouts to `.jsonl.zst` (T-024,
/// oye-collective/actvt-macos#53). A compressed rollout reads exactly like the
/// plain one, offsets included, and is the same session.
final class CompressedRolloutTests: XCTestCase {

    private var dir: URL!
    private let id = "019a1b2c-3d4e-7f50-8a6b-7c8d9e0f1a2b"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("actvt-zst-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// ~1.3 MB of JSONL: crosses the reader's 256 KiB chunks and zstd's blocks.
    private func transcript() -> Data {
        var text = ""
        for i in 0..<6_000 {
            let pad = String(repeating: "x", count: (i * 37) % 300)
            text += #"{"type":"response_item","n":\#(i),"text":"line \#(i) \#(pad)"}"# + "\n"
        }
        return Data(text.utf8)
    }

    /// `transcript()` as zstd, made with zstd's CLI (`zstd -19`; the 3-frame
    /// file is three parts compressed alone and concatenated, which a decoder
    /// must read on past the end of the first). `Fixtures/`, committed.
    private func compressed(frames: Int = 1) throws -> Data {
        let name = frames == 1 ? "transcript" : "transcript-\(frames)-frames"
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "jsonl.zst", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func lines(_ url: URL, _ range: Range<UInt64> = 0..<UInt64.max) throws -> [(Data, UInt64)] {
        var out: [(Data, UInt64)] = []
        try AgentTranscriptLineReader.forEachLine(in: url, startingIn: range) { out.append(($0, $1)) }
        return out
    }

    private func write(_ data: Data, _ name: String, in folder: URL? = nil) throws -> URL {
        let url = (folder ?? dir).appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testACompressedTranscriptReadsLikeThePlainOneOffsetsIncluded() throws {
        let data = transcript()
        let plain = try write(data, "rollout-a-\(id).jsonl")
        for frames in [1, 3] {
            let packed = try write(compressed(frames: frames), "rollout-b\(frames)-\(id).jsonl.zst")
            let a = try lines(plain), b = try lines(packed)
            XCTAssertEqual(a.count, 6_000)
            XCTAssertEqual(b.map(\.0), a.map(\.0), "\(frames) frame(s)")
            XCTAssertEqual(b.map(\.1), a.map(\.1))
            XCTAssertEqual(try SessionFileStream.contentSize(of: packed), UInt64(data.count))
        }
    }

    func testWindowsOfACompressedTranscriptMatchThePlainOnes() throws {
        let data = transcript()
        let plain = try write(data, "rollout-a-\(id).jsonl")
        let packed = try write(compressed(), "rollout-b-\(id).jsonl.zst")
        let size = UInt64(data.count)
        for range in [0..<300_000, 300_000..<700_001, 700_001..<size, (size - 1)..<size] as [Range<UInt64>] {
            XCTAssertEqual(try lines(packed, range).map(\.1), try lines(plain, range).map(\.1), "\(range)")
        }
        let window = try TranscriptWindow(.latest, fileAt: packed)
        XCTAssertEqual(window.fileSize, size, "a window counts decoded bytes, not the file on disk")
    }

    func testACorruptFileFailsInsteadOfReadingAsEmpty() throws {
        let packed = try write(Data(repeating: 0x41, count: 4_096), "rollout-c-\(id).jsonl.zst")
        XCTAssertThrowsError(try lines(packed))
    }

    func testACompressedRolloutKeepsItsSessionId() {
        XCTAssertEqual(CodexSessionsLocator.sessionId(fromFileName: "rollout-2026-11-01T10-00-00-\(id).jsonl.zst"), id)
        XCTAssertEqual(CodexSessionsLocator.sessionId(fromFileName: "rollout-2026-11-01T10-00-00-\(id).jsonl"), id)
        XCTAssertFalse(CodexSessionsLocator.isRollout("rollout-x.json"))
        XCTAssertFalse(CodexSessionsLocator.isRollout("notes.jsonl.zst"))
    }

    func testTheWalkListsACompressedRolloutOnceAndPrefersThePlainFileWhileBothExist() throws {
        let day = dir.appendingPathComponent("2026/11/01", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let data = transcript()
        let name = "rollout-2026-11-01T10-00-00-\(id)"
        _ = try write(compressed(), name + ".jsonl.zst", in: day)

        var found = try CodexSessionsLocator.discoverSessions(at: dir)
        XCTAssertEqual(found.map(\.sessionId), [id])
        XCTAssertEqual(found.first?.fileURL.pathExtension, "zst")

        _ = try write(data, name + ".jsonl", in: day)   // mid-compression: both on disk
        found = try CodexSessionsLocator.discoverSessions(at: dir)
        XCTAssertEqual(found.map(\.fileURL.lastPathComponent), [name + ".jsonl"])
        let recent = try CodexSessionsLocator.discoverRecentSessions(at: dir, dayBucketLimit: 3)
        XCTAssertEqual(recent.map(\.fileURL.lastPathComponent), [name + ".jsonl"])
    }
}
