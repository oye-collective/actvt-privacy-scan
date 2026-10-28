//
//  PIIMaskingTests.swift
//  ActvtPrivacyScanTests
//

import XCTest
@testable import ActvtPrivacyScan

/// Pure-function coverage for the braille masking. The `maskedPlainText` test is
/// the security-critical one: a hidden value must never survive in the rendered
/// string.
final class PIIMaskingTests: XCTestCase {

    private func span(in text: String, _ sub: String, _ category: PIICategory = .secret) -> PIISpan {
        PIISpan(range: text.range(of: sub)!, category: category, confidence: 1.0)
    }

    // MARK: - segments

    func testSegmentsReconstructOriginalText() {
        let text = "key sk-abc123 and ssn 123-45-6789 end"
        let spans = [span(in: text, "sk-abc123"), span(in: text, "123-45-6789", .nationalID)]
        let joined = PIIMasking.segments(text: text, spans: spans).map(\.text).joined()
        XCTAssertEqual(joined, text)
    }

    func testSegmentsAlternateGapAndSpan() {
        let text = "a SECRET b"
        let segs = PIIMasking.segments(text: text, spans: [span(in: text, "SECRET")])
        XCTAssertEqual(segs.count, 3)
        XCTAssertNil(segs[0].span);  XCTAssertEqual(segs[0].text, "a ")
        XCTAssertNotNil(segs[1].span); XCTAssertEqual(segs[1].text, "SECRET")
        XCTAssertNil(segs[2].span);  XCTAssertEqual(segs[2].text, " b")
    }

    func testSegmentsNoSpansIsSinglePlainSegment() {
        let segs = PIIMasking.segments(text: "plain text", spans: [])
        XCTAssertEqual(segs.count, 1)
        XCTAssertNil(segs[0].span)
        XCTAssertEqual(segs[0].text, "plain text")
    }

    func testSegmentsEmptyText() {
        XCTAssertTrue(PIIMasking.segments(text: "", spans: []).isEmpty)
    }

    func testSegmentsSpanAtStartAndEnd() {
        let text = "AAA mid ZZZ"
        let segs = PIIMasking.segments(text: text, spans: [span(in: text, "AAA"), span(in: text, "ZZZ")])
        XCTAssertNotNil(segs.first?.span)
        XCTAssertNotNil(segs.last?.span)
        XCTAssertEqual(segs.map(\.text).joined(), text)
    }

    // MARK: - brailleMask

    func testBrailleMaskLengthMatches() {
        XCTAssertEqual(PIIMasking.brailleMask(forCharacterCount: 5).count, 5)
        XCTAssertEqual(PIIMasking.brailleMask(forCharacterCount: 0), "")
        XCTAssertEqual(PIIMasking.brailleMask(forCharacterCount: -3), "")
    }

    func testBrailleMaskIsAllBrailleScalars() {
        let mask = PIIMasking.brailleMask(forCharacterCount: 8)
        for scalar in mask.unicodeScalars {
            XCTAssert((0x2800...0x28FF).contains(Int(scalar.value)),
                      "scalar \(scalar) is outside the braille block")
        }
    }

    // MARK: - maskedPlainText (security)

    func testMaskedTextHidesSecretsAndKeepsLength() {
        let text = "email a@b.com card 4111111111111111"
        let spans = [span(in: text, "a@b.com", .privateEmail), span(in: text, "4111111111111111", .creditCard)]
        let masked = PIIMasking.maskedPlainText(text: text, spans: spans)

        XCTAssertFalse(masked.contains("a@b.com"))
        XCTAssertFalse(masked.contains("4111111111111111"))
        // Same overall length (braille runs match the hidden lengths).
        XCTAssertEqual(masked.count, text.count)
        // Plain text between spans is untouched.
        XCTAssertTrue(masked.hasPrefix("email "))
        XCTAssertTrue(masked.contains(" card "))
    }

    func testMaskedTextNoSpansUnchanged() {
        XCTAssertEqual(PIIMasking.maskedPlainText(text: "nothing here", spans: []), "nothing here")
    }
}
