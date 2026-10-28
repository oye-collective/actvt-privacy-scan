//
//  LoggerShim.swift
//  ActvtSessionsKit
//

// Minimal `os.Logger` stand-in for platforms without the `os` module (Linux
// CLI builds). Accepts the same call shapes the package uses — including the
// `privacy:` interpolation argument — and discards the privacy annotation,
// writing nothing (the CLI reports errors on stderr through its own path).
// Kept deliberately tiny: the alternative was threading a logging abstraction
// through every source file or taking a swift-log dependency for a binary
// whose only job is to print JSON.
#if !canImport(os)

import Foundation

struct LogPrivacy: Sendable {
    static let `public` = LogPrivacy()
    static let `private` = LogPrivacy()
    static let auto = LogPrivacy()
}

struct LogMessage: ExpressibleByStringInterpolation, ExpressibleByStringLiteral, Sendable {
    struct Interpolation: StringInterpolationProtocol {
        init(literalCapacity: Int, interpolationCount: Int) {}
        mutating func appendLiteral(_ literal: String) {}
        mutating func appendInterpolation<T>(_ value: @autoclosure () -> T) {}
        mutating func appendInterpolation<T>(_ value: @autoclosure () -> T, privacy: LogPrivacy) {}
    }

    init(stringLiteral value: String) {}
    init(stringInterpolation: Interpolation) {}
}

struct Logger: Sendable {
    init(subsystem: String, category: String) {}

    func debug(_ message: LogMessage) {}
    func info(_ message: LogMessage) {}
    func notice(_ message: LogMessage) {}
    func warning(_ message: LogMessage) {}
    func error(_ message: LogMessage) {}
}

#endif
