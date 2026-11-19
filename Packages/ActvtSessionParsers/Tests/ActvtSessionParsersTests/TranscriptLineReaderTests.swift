//
//  TranscriptLineReaderTests.swift
//  ActvtSessionParsersTests
//

import XCTest
@testable import ActvtSessionParsers

/// The ranged reader that long transcripts are read through in windows (S-004):
/// every line whole, with its offset, and adjacent ranges joining exactly.
final class TranscriptLineReaderTests: XCTestCase {

    private var url: URL!

    override func setUp() {
        super.setUp()
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("actvt-lines-\(UUID().uuidString).jsonl")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        super.tearDown()
    }

    private struct Line: Equatable {
        let text: String
        let offset: UInt64
    }

    private func write(_ text: String) {
        try! Data(text.utf8).write(to: url)
    }

    private func lines(_ range: Range<UInt64>) throws -> [Line] {
        var out: [Line] = []
        try AgentTranscriptLineReader.forEachLine(in: url, startingIn: range) { data, offset in
            out.append(Line(text: String(decoding: data, as: UTF8.self), offset: offset))
        }
        return out
    }

    /// What a reader must produce: every non-empty line, split on `\n` only,
    /// with the offset of its first byte. Split as bytes: as Characters, `\r\n`
    /// is one grapheme and would never split.
    private func expected(_ text: String) -> [Line] {
        var out: [Line] = []
        var offset: UInt64 = 0
        for part in Array(text.utf8).split(separator: 0x0A, omittingEmptySubsequences: false) {
            if !part.isEmpty { out.append(Line(text: String(decoding: part, as: UTF8.self), offset: offset)) }
            offset += UInt64(part.count) + 1
        }
        return out
    }

    func testTheWholeFileGivesEveryLineWithItsOffset() throws {
        let text = "{\"a\":1}\n\n{\"b\":\"é\"}\r\n{\"c\":3}"
        write(text)
        XCTAssertEqual(try lines(0..<UInt64.max), expected(text))

        var plain: [String] = []
        try AgentTranscriptLineReader.forEachLine(in: url) { plain.append(String(decoding: $0, as: UTF8.self)) }
        XCTAssertEqual(plain, ["{\"a\":1}", "{\"b\":\"é\"}\r", "{\"c\":3}"])
    }

    func testARangeKeepsOnlyLinesThatStartInIt() throws {
        write("aaaa\nbbbb\ncccc\n")   // lines at 0, 5, 10
        XCTAssertEqual(try lines(5..<10).map(\.text), ["bbbb"], "starts exactly on a line")
        XCTAssertEqual(try lines(4..<10).map(\.text), ["bbbb"], "starts on the newline before a line")
        XCTAssertEqual(try lines(2..<10).map(\.text), ["bbbb"], "starts mid-line: that line belongs to the window before")
        XCTAssertEqual(try lines(6..<11).map(\.text), ["cccc"], "a line that starts inside is read whole")
        XCTAssertEqual(try lines(11..<12).map(\.text), [])
        XCTAssertEqual(try lines(40..<50).map(\.text), [], "past the end")
    }

    /// Every cut point, on a file small enough to try them all.
    func testAdjacentRangesJoinWithoutGapsOrRepeats() throws {
        let text = "{\"t\":\"user\"}\n\n{\"t\":\"assistant\",\"x\":\"ü\"}\n{\"t\":\"tool\"}\n{\"t\":\"user\"}"
        write(text)
        let all = expected(text)
        for cut in 0...UInt64(text.utf8.count + 1) {
            XCTAssertEqual(try lines(0..<cut) + lines(cut..<UInt64.max), all, "cut at \(cut)")
        }
    }

    /// Windows walked backwards from the end, the way a long session pages up,
    /// across the reader's 256 KiB chunk boundaries.
    func testWindowsWalkedBackFromTheEndReadTheWholeFile() throws {
        var text = ""
        var i = 0
        while text.utf8.count < 700_000 {
            text += "{\"n\":\(i),\"pad\":\"\(String(repeating: "x", count: (i * 37) % 900))\"}\n"
            i += 1
        }
        write(text)
        let all = expected(text)
        XCTAssertEqual(try lines(0..<UInt64.max), all)

        for budget: UInt64 in [262_144, 100_003, 4_096] {
            var windows: [[Line]] = []
            var cursor = UInt64(text.utf8.count)
            while cursor > 0 {
                let start = cursor > budget ? cursor - budget : 0
                let window = try lines(start..<cursor)
                windows.insert(window, at: 0)
                // The next window ends where this one's first line starts.
                cursor = window.first?.offset ?? start
            }
            XCTAssertEqual(windows.flatMap { $0 }, all, "budget \(budget)")
        }
    }

    /// Lines longer than a 256 KiB chunk (a tool result with a big file in it):
    /// each read whole, once, from the whole file and from ranges that start
    /// before, inside and right after one.
    func testLinesLongerThanAChunkAreReadWhole() throws {
        let long = String(repeating: "y", count: 600_000)
        let longer = String(repeating: "z", count: 1_100_000)
        let text = "{\"a\":1}\n{\"big\":\"\(long)\"}\n{\"b\":2}\n{\"huge\":\"\(longer)\"}\n\n{\"c\":3}"
        write(text)
        let all = expected(text)
        XCTAssertEqual(all.count, 5)
        XCTAssertEqual(try lines(0..<UInt64.max), all)
        let bigStart = all[1].offset
        for cut in [bigStart - 1, bigStart, bigStart + 1, bigStart + 300_000, all[2].offset, all[3].offset + 1] {
            XCTAssertEqual(try lines(0..<cut) + lines(cut..<UInt64.max), all, "cut at \(cut)")
        }
    }
}
