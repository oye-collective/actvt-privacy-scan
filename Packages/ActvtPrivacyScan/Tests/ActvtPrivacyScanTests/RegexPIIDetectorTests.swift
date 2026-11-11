//
//  RegexPIIDetectorTests.swift
//  ActvtPrivacyScanTests
//

import XCTest
@testable import ActvtPrivacyScan

/// Backend A (C.3) correctness. The offset-mapping tests are the critical ones:
/// `HighlightedMessageView` silently drops spans whose `String.Index` range
/// can't be lifted into the rendered text, so a wrong range = invisible bug.
final class RegexPIIDetectorTests: XCTestCase {

    private let detector = RegexPIIDetector()

    /// Helper: scan and return the (category, slicedText) pairs.
    private func hits(_ text: String) -> [(PIICategory, String)] {
        detector.scan(text).map { ($0.category, String(text[$0.range])) }
    }

    // MARK: - Offset mapping (critical)

    /// Every returned span's range must slice the *expected* substring out of
    /// the source text — the guard against the silent-drop wiring bug.
    func testSpanRangesSliceExpectedSubstrings() {
        let text = "Email a@b.com, SSN 123-45-6789, card 4111 1111 1111 1111"
        for span in detector.scan(text) {
            let sliced = String(text[span.range])
            switch span.category {
            case .privateEmail: XCTAssertEqual(sliced, "a@b.com")
            case .nationalID:   XCTAssertEqual(sliced, "123-45-6789")
            case .creditCard:   XCTAssertEqual(sliced, "4111 1111 1111 1111")
            default:            XCTFail("unexpected category \(span.category) for \(sliced)")
            }
        }
    }

    /// Ranges must stay valid across multibyte (emoji) text — exercises the
    /// UTF-16 `NSRange` → `String.Index` conversion.
    func testRangesValidWithMultibytePrefix() {
        let text = "🔐 reach me at jane@example.org today"
        let spans = detector.scan(text)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(String(text[spans[0].range]), "jane@example.org")
        XCTAssertEqual(spans[0].category, .privateEmail)
    }

    // MARK: - Curated catalog

    func testDetectsEmail() {
        let text = "ping me at jane.doe+test@mail.example.org tomorrow"
        let h = hits(text)
        XCTAssertEqual(h.first?.0, .privateEmail)
        XCTAssertEqual(h.first?.1, "jane.doe+test@mail.example.org")
    }

    func testDetectsValidCreditCardAndRejectsBadLuhn() {
        let valid = hits("card 4111 1111 1111 1111 on file")
        XCTAssertEqual(valid.first?.0, .creditCard)
        XCTAssertEqual(valid.first?.1, "4111 1111 1111 1111")
        // Same shape, bad check digit → no span.
        XCTAssertTrue(detector.scan("card 4111 1111 1111 1112 on file")
            .allSatisfy { $0.category != .creditCard })
    }

    /// Tool output is full of ids and timestamps that pass Luhn; none is a card (B-034).
    func testLuhnValidIdsAndTimestampsAreNotCards() {
        let text = #"{"createdAt": 1760885123453, "id": "7666123456789012348"}"#
        XCTAssertTrue(detector.scan(text).allSatisfy { $0.category != .creditCard })
    }

    func testDetectsValidIBANAndRejectsBadChecksum() {
        let valid = hits("IBAN GB82WEST12345698765432 confirmed")
        XCTAssertEqual(valid.first?.0, .bankAccount)
        XCTAssertTrue(detector.scan("IBAN GB82WEST12345698765433 confirmed")
            .allSatisfy { $0.category != .bankAccount })
    }

    func testDetectsNationalIDs() {
        XCTAssertEqual(hits("SSN 123-45-6789 here").first?.0, .nationalID)
        XCTAssertEqual(hits("NINO AB123456C on form").first?.0, .nationalID)
    }

    /// Weak-signal network/technical identifiers (URL, IP, hostname, MAC, UUID,
    /// GPS) are intentionally NOT detected — they were dropped as too noisy.
    func testIgnoresWeakSignalIdentifiers() {
        XCTAssertTrue(detector.scan("see https://example.com/docs now").isEmpty)
        XCTAssertTrue(detector.scan("ssh 10.0.0.1 then 2001:db8::1").isEmpty)
        XCTAssertTrue(detector.scan("deployed to api.staging.example.com").isEmpty)
        XCTAssertTrue(detector.scan("dev 00:1A:2B:3C:4D:5E online").isEmpty)
        XCTAssertTrue(detector.scan("id 550e8400-e29b-41d4-a716-446655440000").isEmpty)
        XCTAssertTrue(detector.scan("at 37.7749, -122.4194 now").isEmpty)
    }

    func testDetectsSecrets() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dQw4w9WgXcQabcdefg"
        XCTAssertEqual(hits("token \(jwt) ok").first?.0, .secret)
        XCTAssertEqual(hits("key AKIAIOSFODNN7EXAMPLE rotated").first?.0, .secret)
    }

    /// Provider tokens are caught bare, with no `api_key=` label in front, since
    /// that is how they usually get pasted into a prompt.
    func testDetectsBareProviderTokens() {
        let tokens = [
            "sk-ant-api03-Zq8vT2mK9pL4xR7nW1bY6cJ3hF5dG0sA",
            "sk-proj-4fGh7JkL9mN2pQ5rS8tV1wX3yZ6aB0cD",
            "sk_live_51Hx9QaK2mN7pR4tV8wY1zB3",
            "ghp_Zq8vT2mK9pL4xR7nW1bY6cJ3hF5dG0sA1234",
            "github_pat_11ABCDEFG0123456789_abcdefghijklmnop",
            "xoxb-1234567890-abcdefghijkl",
            "AIzaSyD4fGh7JkL9mN2pQ5rS8tV1wX3yZ6aB0cE",
        ]
        for token in tokens {
            let h = hits("use \(token) for the mailer")
            XCTAssertEqual(h.count, 1, token)
            XCTAssertEqual(h.first?.0, .secret, token)
            XCTAssertEqual(h.first?.1, token)
        }
    }

    /// Service tokens and webhook URLs that ruleset 7 missed when pasted bare (B-062).
    /// Made-up values in each format's real shape and length.
    func testDetectsBareServiceTokensAndWebhooks() {
        let tokens = [
            "ya29.a0Ab3dEf6hIj9kLm2nOp5qRs8tUv1wXy4zAB7CD0EFgh3IJkl6MNop9qRs2",
            "https://hooks.slack.com/services/T01234567/B01234567/Ab3dEf6hIj9kLm2nOp5qRs8t",
            "https://discord.com/api/webhooks/123456789012345678/Ab3dEf6hIj9kLm2nOp5qRs8tUv1wXy4zAB7CD0EFgh3IJkl6MNop9qRs2tUv5wXy8z",
            "https://discordapp.com/api/webhooks/123456789012345678/Ab3dEf6hIj9kLm2nOp5qRs8tUv1wXy4zAB7CD0EFgh3IJkl6MNop9qRs2tUv5wXy8z",
            "pypi-AgEIcHlwaS5vcmcCJAb3dEf6hIj9kLm2nOp5qRs8tUv1wXy4zAB7CD0EFgh3IJkl6MN",
            "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",
            "SK0123456789abcdef0123456789abcdef",
            "123456789:AAAb3dEf6hIj9kLm2nOp5qRs8tUv1wXy4zA",
            "ops_eyJzaWduSW5BZGRyZXNzIjoibXkuMXBhc3N3b3JkLmNvbSJ9",
        ]
        for token in tokens {
            let h = hits("use \(token) for the mailer")
            XCTAssertEqual(h.count, 1, token)
            XCTAssertEqual(h.first?.0, .secret, token)
            XCTAssertEqual(h.first?.1, token)
        }
    }

    /// Hashes, ids, versions and the documented webhook endpoints share these
    /// formats' alphabets but carry no credential.
    func testServiceTokenLookalikesAreNotSecrets() {
        let text = """
        commit 3f786850e387550fdab836ed7e6dc881de23001b, image sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08,
        request 550e8400-e29b-41d4-a716-446655440000, release v1.4.13, build 1762851120:done.
        Post to https://hooks.slack.com/services/ or https://discord.com/api/webhooks/ once configured.
        The SKU0123456789ABCDEF0123456789ABCDEF table, SK0123456789abcdef0123456789abcdef01 hash, SG.example, pypi-upload.
        """
        XCTAssertEqual(hits(text).map(\.1), [])
    }

    func testBearerHeaderValueIsCaughtByItsPrefix() {
        let h = hits("Authorization: Bearer sk-ant-api03-Zq8vT2mK9pL4xR7nW1bY6cJ3")
        XCTAssertEqual(h.map(\.1), ["sk-ant-api03-Zq8vT2mK9pL4xR7nW1bY6cJ3"])
    }

    func testPrefixLookalikesInProseAreNotSecrets() {
        XCTAssertTrue(detector.scan("run the sk-learn task, then ask ghp_ about it").isEmpty)
        XCTAssertTrue(detector.scan("the risk-management-and-compliance-review doc").isEmpty)
    }

    /// Contextual secrets highlight only the value (capture group 1), not the label.
    func testContextualSecretMasksValueOnly() {
        let text = "password: hunter2pass"
        let h = hits(text)
        XCTAssertEqual(h.first?.0, .secret)
        XCTAssertEqual(h.first?.1, "hunter2pass")
    }

    /// Secrets the way they actually appear in transcripts: `.env` names that end
    /// in the keyword, JSON fields, Bearer headers, connection strings. Each one
    /// yields exactly its value as a secret.
    func testDetectsSecretsAsTheyAppearInTranscripts() {
        let cases: [(String, String)] = [
            ("DB_PASSWORD=hunter2hunter2", "hunter2hunter2"),
            ("export ANTHROPIC_API_KEY=abcd1234efgh5678ijkl9999", "abcd1234efgh5678ijkl9999"),
            ("aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"),
            ("GITHUB_TOKEN=abcd1234efgh5678ijkl9999", "abcd1234efgh5678ijkl9999"),
            (#"{"apiKey": "abcd1234efgh5678ijkl9999"}"#, "abcd1234efgh5678ijkl9999"),
            (#"{"password": "hunter2hunter2"}"#, "hunter2hunter2"),
            (#"{"client_secret":"abcd1234efgh5678ijkl9999"}"#, "abcd1234efgh5678ijkl9999"),
            ("Authorization: Bearer abcd1234efgh5678ijkl9999mnop", "abcd1234efgh5678ijkl9999mnop"),
            ("postgres://admin:S3cretPassw0rd@db.internal:5432/app", "S3cretPassw0rd"),
            ("export GITLAB_TOKEN=glpat-abcdefghij0123456789", "glpat-abcdefghij0123456789"),
            ("HF_TOKEN=hf_abcdefghijklmnopqrstuvwxyz123456", "hf_abcdefghijklmnopqrstuvwxyz123456"),
            ("//registry.npmjs.org/:_authToken=npm_abcdefghijklmnopqrstuvwxyz0123456789", "npm_abcdefghijklmnopqrstuvwxyz0123456789"),
            // A key named by its kind: Django's SECRET_KEY and the like.
            ("SECRET_KEY=abcd1234efgh5678ijkl9999", "abcd1234efgh5678ijkl9999"),
            ("STRIPE_SECRET_KEY=abcd1234efgh5678ijkl9999", "abcd1234efgh5678ijkl9999"),
            ("JWT_SECRET_KEY: abcd1234efgh5678ijkl9999", "abcd1234efgh5678ijkl9999"),
            ("PRIVATE_KEY=abcd1234efgh5678ijkl9999", "abcd1234efgh5678ijkl9999"),
            ("ENCRYPTION_KEY=abcd1234efgh5678ijkl9999", "abcd1234efgh5678ijkl9999"),
            (#"{"signingKey": "abcd1234efgh5678ijkl9999"}"#, "abcd1234efgh5678ijkl9999"),
            ("MASTER_KEY=abcd1234efgh5678ijkl9999", "abcd1234efgh5678ijkl9999"),
        ]
        for (text, value) in cases {
            let h = hits(text)
            XCTAssertEqual(h.count, 1, text)
            XCTAssertEqual(h.first?.0, .secret, text)
            XCTAssertEqual(h.first?.1, value, text)
        }
    }

    func testPrivateKeyBlockIsOneSecret() {
        let key = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQ\nAAAAAAAAAABAAAAMwAAAAtzc2gtZW\n-----END OPENSSH PRIVATE KEY-----"
        XCTAssertEqual(hits("cat ~/.ssh/id_ed25519\n\(key)\ndone").map(\.1), [key])
        // Output cut off before the END line still hides the body.
        let cut = "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA1x2y3z"
        XCTAssertEqual(hits(cut).map(\.1), [cut])
    }

    /// Names that only contain a keyword, references to a secret, and ordinary
    /// counts are not secrets.
    func testSecretLookalikesAreNotSecrets() {
        let clean = [
            "password_reset_url=https://example.com/reset",
            "token_count=12345678901234567890",
            #""max_tokens": 4096, "input_tokens": 123456789012345678"#,
            "DB_PASSWORD=${DB_PASSWORD}",
            "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY",
            "Authorization: Bearer $TOKEN",
            "postgres://admin:$PGPASSWORD@db.internal/app",
            "the password field must be at least eight characters",
            // A bare `_KEY` names a column, and prose about a key isn't one.
            "PRIMARY_KEY=order_id_and_created_at",
            "SORT_KEY=created_at_descending_order",
            "The secret key point is that rotation happens weekly.",
            "PRIVATE=abcd1234efgh5678ijkl9999",
        ]
        for text in clean {
            XCTAssertTrue(detector.scan(text).allSatisfy { $0.category != .secret }, text)
        }
    }

    /// Example config files are full of instructions where a key goes; they are
    /// not secrets (B-046). Each sits where a real key would be caught.
    func testPlaceholderValuesAreNotSecrets() {
        let placeholders = [
            "SECRET_KEY=your-secret-key-here-change-in-production",
            "client_secret: your-client-secret-value",
            "JWT_SECRET=strong-random-string-here",
            "API_KEY=replace-with-your-api-key",
            "password=changeme123",
            "AUTH_TOKEN=xxxxxxxxxxxxxxxxxxxxxxxx",
            "ACCESS_TOKEN=yourAccessTokenGoesHere",
            "ENCRYPTION_KEY=generate-a-32-byte-key",
            "Authorization: Bearer your-token-here-please",
            "postgres://admin:changeme@db.internal/app",
        ]
        for text in placeholders {
            XCTAssertTrue(detector.scan(text).allSatisfy { $0.category != .secret }, text)
        }
    }

    /// The placeholder check must not cost real keys: random values, including
    /// ones that begin with a filler word's letters, and passphrases.
    func testRealValuesBesidePlaceholderWordsStillCount() {
        let secrets = [
            "STRIPE_SECRET_KEY=Qm8vT2xkZ0hYcFZ3bnRrYk1aNw",
            "db_password=correct-horse-battery-staple",
            "api_key=ExaJ7qPz2LwX9vRt4Kd8Ys1N",
            "token=YourbQ7xP2mZ9kLw4Rt8vN3s",
            "aws_secret_access_key=k3Rq9ZtV/7mWb2Xp+4LnHc8Ys1GdJf6Ta0Ue5Ki",
        ]
        for text in secrets {
            XCTAssertEqual(detector.scan(text).filter { $0.category == .secret }.count, 1, text)
        }
    }

    func testWordPieces() {
        XCTAssertEqual(PIIValidators.wordPieces("yourAccessTokenGoesHere"), ["your", "access", "token", "goes", "here"])
        XCTAssertEqual(PIIValidators.wordPieces("changeme123"), ["changeme", "123"])
        XCTAssertEqual(PIIValidators.wordPieces("your-secret_key.here"), ["your", "secret", "key", "here"])
    }

    // MARK: - Overlap / shape

    /// A validated credit-card number yields a single span and is not also
    /// double-reported by a looser numeric rule — the renderer must never see
    /// overlap.
    func testNoNestedOverlap() {
        let spans = detector.scan("pay with 4111 1111 1111 1111 today")
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].category, .creditCard)
    }

    func testNoFalsePositivesOnPlainText() {
        XCTAssertTrue(detector.scan("Just some ordinary prose with no identifiers.").isEmpty)
        XCTAssertTrue(detector.scan("").isEmpty)
    }

    func testSpansSortedByPosition() {
        let text = "mail a@b.com then ssn 123-45-6789 then card 4111 1111 1111 1111"
        let spans = detector.scan(text)
        let lowers = spans.map { $0.range.lowerBound }
        XCTAssertEqual(lowers, lowers.sorted())
    }

    func testConfidenceIsOneForRegex() {
        for span in detector.scan("mail a@b.com") {
            XCTAssertEqual(span.confidence, 1.0)
        }
    }

    func testReady() {
        XCTAssertTrue(detector.isReady)
    }
}
