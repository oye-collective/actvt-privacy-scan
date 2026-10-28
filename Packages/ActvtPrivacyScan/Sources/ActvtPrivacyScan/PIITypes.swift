//
//  PIITypes.swift
//  ActvtPrivacyScan
//

import Foundation

/// A single detected PII span anchored to its source string.
///
/// `range` is a `String.Index` range so callers can map directly into
/// `AttributedString` without re-tokenising. The string the range is
/// anchored to must outlive the span — pass the source `text` alongside
/// when storing.
///
/// Phase 4 defines this shape but doesn't yet populate it. Phase 3 adds
/// the `PIIDetector` protocol + concrete backends that emit `[PIISpan]`.
public struct PIISpan: Sendable, Hashable {
    public let range: Range<String.Index>
    public let category: PIICategory
    /// Detector confidence, 0...1. Regex backends typically emit 1.0;
    /// ML backends emit calibrated probabilities. The UI threshold filter
    /// (Phase 3 setting) applies here.
    public let confidence: Float

    public init(range: Range<String.Index>, category: PIICategory, confidence: Float) {
        self.range = range
        self.category = category
        self.confidence = confidence
    }
}

/// Categories the OpenAI Privacy Filter taxonomy plus a few regex-only
/// categories (IPs, hostnames) that the regex fallback can emit before
/// the model loads. Phase 3 reduces this to the model's actual labels;
/// keep additions backward-compatible (the UI maps unknown categories
/// to a fallback color).
public enum PIICategory: String, Codable, Sendable, Hashable, CaseIterable {
    case privatePerson
    case privateAddress
    case privateEmail
    case accountNumber
    case secret
    // Curated regex categories (emitted by `RegexPIIDetector`):
    case creditCard
    case bankAccount
    case nationalID
}
