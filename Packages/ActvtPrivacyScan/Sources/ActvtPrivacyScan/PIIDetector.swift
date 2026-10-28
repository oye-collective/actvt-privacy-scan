//
//  PIIDetector.swift
//  ActvtPrivacyScan
//

import Foundation

/// Pluggable PII detection backend. The UI (`HighlightedMessageView`,
/// `PIIScanCoordinator`) depends only on this protocol, so the cheap
/// regex backend can ship first and a heavier ML backend can drop in later
/// with no view-side changes.
///
/// `scan` returns spans anchored to the exact `text` passed in (the caller
/// must keep that string alive — see `PIISpan`). Implementations must be
/// safe to call from any isolation domain (`Sendable`).
public protocol PIIDetector: Sendable {
    /// Whether the backend can produce results right now. The regex backend
    /// is always ready; an ML backend reports `false` until its model loads.
    var isReady: Bool { get }

    /// Whether the backend emits a meaningful spread of confidences. The regex
    /// backend hard-codes `1.0` for every span, so the user confidence
    /// threshold can never filter anything — the settings sensitivity slider is
    /// hidden while this is `false`. The ML backend (issue #16) sets it `true`.
    var emitsVariableConfidence: Bool { get }

    /// Detect PII spans in `text`. Returns non-overlapping spans sorted by
    /// position. Confidence filtering (the user threshold) is applied by the
    /// caller, not here — backends emit their raw confidence.
    ///
    /// Throws when the backend could not scan (e.g. the ML model failed to load
    /// or run). A failure is never "no PII": callers must not cache or persist it.
    func scan(_ text: String) throws -> [PIISpan]

    /// Detect PII in each of `texts`, exactly as `scan(_:)` would read each one
    /// on its own; one result per text, in order. A backend whose every call
    /// pays a fixed cost (the ML model) reads them in shared passes.
    func scan(_ texts: [String]) throws -> [[PIISpan]]
}

public extension PIIDetector {
    /// Default: backends emit a flat confidence (no threshold gating) unless
    /// they opt in. Keeps existing conformers unchanged.
    var emitsVariableConfidence: Bool { false }

    /// Default: one text at a time.
    func scan(_ texts: [String]) throws -> [[PIISpan]] {
        try texts.map { try scan($0) }
    }
}
