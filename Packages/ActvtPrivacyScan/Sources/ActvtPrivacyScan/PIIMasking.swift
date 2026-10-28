//
//  PIIMasking.swift
//  ActvtPrivacyScan
//

import Foundation

/// Pure text-splitting + braille masking for PII spans, factored out of the
/// renderer so it's unit-testable without a SwiftUI host.
///
/// The renderer (`HighlightedMessageView`) builds its `AttributedString` from
/// `segments(text:spans:)`, substituting `brailleMask(...)` for span text when
/// masking is on. Tests use `maskedPlainText(...)` to assert that a hidden value
/// never survives in the rendered string.
public enum PIIMasking {

    /// One run of the source text: either a plain gap (`span == nil`) or a
    /// detected PII region (`span != nil`). Concatenating `text` over all
    /// segments reproduces the original string.
    public struct PIISegment: Equatable {
        public let text: String
        public let span: PIISpan?
    }

    /// The braille glyph used to redact a character. U+28FF (all dots set) reads
    /// as a solid block, so a masked span looks like a redaction bar.
    public static let maskGlyph: Character = "⣿"

    /// Split `text` into ordered plain/span segments. Spans are expected
    /// non-overlapping and sorted (what `RegexPIIDetector` returns); we sort and
    /// skip any that overlap an already-emitted span defensively.
    public static func segments(text: String, spans: [PIISpan]) -> [PIISegment] {
        guard !spans.isEmpty else {
            return text.isEmpty ? [] : [PIISegment(text: text, span: nil)]
        }

        let sorted = spans.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var result: [PIISegment] = []
        var cursor = text.startIndex

        for span in sorted {
            // Skip malformed or overlapping spans (lower before cursor).
            guard span.range.lowerBound >= cursor,
                  span.range.lowerBound <= text.endIndex,
                  span.range.upperBound <= text.endIndex,
                  span.range.lowerBound < span.range.upperBound
            else { continue }

            if span.range.lowerBound > cursor {
                result.append(PIISegment(text: String(text[cursor..<span.range.lowerBound]), span: nil))
            }
            result.append(PIISegment(text: String(text[span.range]), span: span))
            cursor = span.range.upperBound
        }

        if cursor < text.endIndex {
            result.append(PIISegment(text: String(text[cursor...]), span: nil))
        }
        return result
    }

    /// `n` mask glyphs — length-matched to the hidden value so layout/wrapping
    /// is preserved. Returns "" for non-positive counts.
    public static func brailleMask(forCharacterCount n: Int) -> String {
        guard n > 0 else { return "" }
        return String(repeating: maskGlyph, count: n)
    }

    /// The plain string as it renders when masked: every span replaced by a
    /// braille run of matching length. Used by tests as the security assertion
    /// (the original value must not appear).
    public static func maskedPlainText(text: String, spans: [PIISpan]) -> String {
        segments(text: text, spans: spans).map { segment in
            guard segment.span != nil else { return segment.text }
            return brailleMask(forCharacterCount: segment.text.count)
        }.joined()
    }
}
