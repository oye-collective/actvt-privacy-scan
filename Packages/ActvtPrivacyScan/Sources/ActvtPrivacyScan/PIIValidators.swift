//
//  PIIValidators.swift
//  ActvtPrivacyScan
//

import Foundation

/// Dependency-free checksum / sanity validators used by `RegexPIIDetector` to
/// reject regex matches that *look* like a credit card / IBAN / date but can't
/// actually be one. A rule with a validator only emits a span when the matched
/// substring passes — confidence stays flat (1.0); these are go/no-go gates,
/// not a scoring signal.
public enum PIIValidators {

    /// Luhn (mod-10) checksum for payment-card numbers. Strips spaces and
    /// hyphens first, then requires a plausible 13–19 digit length before
    /// running the checksum. Rejects anything with non-digit/non-separator
    /// characters.
    public static let luhn: @Sendable (String) -> Bool = { raw in
        var digits: [Int] = []
        for ch in raw {
            if ch == " " || ch == "-" { continue }
            guard let d = ch.wholeNumberValue, ch.isNumber else { return false }
            digits.append(d)
        }
        guard (13...19).contains(digits.count) else { return false }

        var sum = 0
        // Double every second digit from the right.
        for (offset, digit) in digits.reversed().enumerated() {
            if offset % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }

    /// A value from a `name = value` secret rule that is an instruction, not a
    /// key: `your-secret-key-here`, `changeme123`, `replace-with-your-api-key`,
    /// `xxxxxxxx` (B-046). The value is cut into word pieces at separators,
    /// camelCase humps and letter/digit edges; a placeholder has one of the
    /// filler words below as a whole piece. A random key only cuts into short
    /// mixed-case fragments, and a passphrase (`correct-horse-battery-staple`)
    /// has none of these words, so both still count.
    public static let notPlaceholder: @Sendable (String) -> Bool = { raw in
        !wordPieces(raw).contains { piece in
            placeholderWords.contains(piece) || (piece.count >= 3 && piece.allSatisfy { $0 == "x" })
        }
    }

    private static let placeholderWords: Set<String> = [
        "your", "here", "change", "changeme", "replace", "example", "sample",
        "placeholder", "generate", "insert", "dummy", "redacted", "todo",
    ]

    /// Lowercased word pieces: runs of letters (a capital after a lowercase
    /// letter starts a new piece) and runs of digits.
    static func wordPieces(_ raw: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        var previous: Character?
        for ch in raw {
            let edge: Bool
            if let p = previous, ch.isLetter || ch.isNumber {
                edge = !(p.isLetter || p.isNumber)
                    || (p.isLetter != ch.isLetter)
                    || (p.isLowercase && ch.isUppercase)
            } else {
                edge = true
            }
            if edge, !current.isEmpty { pieces.append(current.lowercased()); current = "" }
            if ch.isLetter || ch.isNumber { current.append(ch) }
            previous = ch
        }
        if !current.isEmpty { pieces.append(current.lowercased()) }
        return pieces
    }

    /// A payment-card number: an issuer's prefix at a length that issuer uses,
    /// and Luhn. Luhn alone passes one random digit run in ten, so ids and
    /// millisecond timestamps (13 digits, starting `17…`) read as cards
    /// without the prefix check (B-034).
    public static let paymentCard: @Sendable (String) -> Bool = { raw in
        let digits = raw.filter { $0 != " " && $0 != "-" }
        guard digits.allSatisfy(\.isASCII) else { return false }
        return cardIssuers.contains { issuer in
            issuer.lengths.contains(digits.count)
                && Int(digits.prefix(issuer.prefixDigits)).map(issuer.prefixes.contains) == true
        } && luhn(raw)
    }

    /// IIN ranges of the major card networks, with the lengths each issues.
    private static let cardIssuers: [(prefixDigits: Int, prefixes: ClosedRange<Int>, lengths: Set<Int>)] = [
        (1, 4...4, [13, 16, 19]),               // Visa
        (2, 51...55, [16]),                     // Mastercard
        (4, 2221...2720, [16]),                 // Mastercard 2-series
        (2, 34...34, [15]), (2, 37...37, [15]), // American Express
        (4, 6011...6011, Set(16...19)),         // Discover
        (3, 644...649, Set(16...19)),
        (2, 65...65, Set(16...19)),
        (2, 62...62, Set(16...19)),             // UnionPay
        (4, 3528...3589, Set(16...19)),         // JCB
        (2, 36...36, Set(14...19)),             // Diners Club
        (3, 300...305, Set(16...19)), (2, 38...39, Set(16...19)),
        (4, 2200...2204, Set(16...19)),         // Mir
        (4, 5018...5018, Set(13...19)),         // Maestro
        (4, 5020...5020, Set(13...19)), (4, 5038...5038, Set(13...19)),
        (4, 5893...5893, Set(13...19)), (4, 6304...6304, Set(13...19)),
        (4, 6759...6759, Set(13...19)), (4, 6761...6763, Set(13...19)),
    ]

    /// ISO 13616 IBAN check using the MOD97-10 algorithm. Strips spaces, moves
    /// the first four characters (country code + check digits) to the end, maps
    /// letters A–Z → 10–35, and verifies the resulting integer ≡ 1 (mod 97).
    /// The big integer is reduced in chunks to avoid overflow.
    public static let ibanMod97: @Sendable (String) -> Bool = { raw in
        let compact = raw.replacingOccurrences(of: " ", with: "").uppercased()
        guard (15...34).contains(compact.count) else { return false }
        // Country code (2 letters) + 2 check digits, then the BBAN.
        let chars = Array(compact)
        guard chars[0].isLetter, chars[1].isLetter,
              chars[2].isNumber, chars[3].isNumber else { return false }

        let rearranged = String(chars[4...]) + String(chars[0..<4])

        var remainder = 0
        for ch in rearranged {
            let value: Int
            if let d = ch.wholeNumberValue, ch.isNumber {
                value = d
            } else if ch.isLetter, let ascii = ch.asciiValue {
                value = Int(ascii) - 55 // 'A'(65) → 10
            } else {
                return false
            }
            // Append one (or two) decimal digits, reducing as we go.
            remainder = (remainder * (value > 9 ? 100 : 10) + value) % 97
        }
        return remainder == 1
    }
}
