//
//  PIIValidatorsTests.swift
//  ActvtPrivacyScanTests
//

import XCTest
@testable import ActvtPrivacyScan

/// Go/no-go checksum + sanity validators that gate the contextual / structured
/// PII rules. A regression here either lets bogus values highlight (false
/// positive) or silently drops real ones.
final class PIIValidatorsTests: XCTestCase {

    // MARK: - Luhn

    func testLuhnAcceptsValidCards() {
        XCTAssertTrue(PIIValidators.luhn("4111111111111111"))      // Visa test
        XCTAssertTrue(PIIValidators.luhn("4111 1111 1111 1111"))   // with spaces
        XCTAssertTrue(PIIValidators.luhn("5500-0000-0000-0004"))   // with hyphens
        XCTAssertTrue(PIIValidators.luhn("378282246310005"))       // Amex (15)
    }

    func testLuhnRejectsInvalid() {
        XCTAssertFalse(PIIValidators.luhn("4111111111111112"))     // bad check digit
        XCTAssertFalse(PIIValidators.luhn("1234567890123"))        // fails Luhn
        XCTAssertFalse(PIIValidators.luhn("4111"))                 // too short
        XCTAssertFalse(PIIValidators.luhn("12345678901234567890")) // too long (20)
        XCTAssertFalse(PIIValidators.luhn("4111-1111-11a1-1111"))  // non-digit
    }

    // MARK: - Payment card (issuer prefix + Luhn)

    func testPaymentCardAcceptsEachNetwork() {
        for number in ["4111111111111111",      // Visa
                       "5555555555554444",      // Mastercard
                       "2223003122003222",      // Mastercard 2-series
                       "378282246310005",       // Amex
                       "6011111111111117",      // Discover
                       "3530111333300000",      // JCB
                       "36227206271667",        // Diners Club (14)
                       "6200000000000005",      // UnionPay
                       "2200000000000004",      // Mir
                       "6759649826438453",      // Maestro
                       "5500-0000-0000-0004",
                       "4111 1111 1111 1111"] {
            XCTAssertTrue(PIIValidators.paymentCard(number), number)
        }
    }

    /// Luhn passes one digit run in ten; these pass it and are not cards (B-034).
    func testPaymentCardRejectsLuhnValidNonCards() {
        XCTAssertTrue(PIIValidators.luhn("1760885123453"))
        XCTAssertFalse(PIIValidators.paymentCard("1760885123453"))        // a millisecond timestamp
        XCTAssertTrue(PIIValidators.luhn("7666123456789012348"))
        XCTAssertFalse(PIIValidators.paymentCard("7666123456789012348"))  // a 19-digit id
        XCTAssertFalse(PIIValidators.paymentCard("37828224631000"))       // Amex prefix, wrong length
        XCTAssertFalse(PIIValidators.paymentCard("4111111111111112"))     // Visa prefix, bad check digit
    }

    // MARK: - IBAN MOD97

    func testIBANAcceptsValid() {
        XCTAssertTrue(PIIValidators.ibanMod97("GB82WEST12345698765432"))
        XCTAssertTrue(PIIValidators.ibanMod97("GB82 WEST 1234 5698 7654 32"))
        XCTAssertTrue(PIIValidators.ibanMod97("DE89370400440532013000"))
        XCTAssertTrue(PIIValidators.ibanMod97("FR1420041010050500013M02606"))
    }

    func testIBANRejectsInvalid() {
        XCTAssertFalse(PIIValidators.ibanMod97("GB82WEST12345698765433")) // bad checksum
        XCTAssertFalse(PIIValidators.ibanMod97("ZZ00"))                   // too short
        XCTAssertFalse(PIIValidators.ibanMod97("1234WEST12345698765432")) // no country letters
    }
}
