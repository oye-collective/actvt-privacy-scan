//
//  RegexPIIDetector.swift
//  ActvtPrivacyScan
//

import Foundation

/// The regex pattern strings behind `RegexPIIDetector`. The network identifiers
/// (IPv4/IPv6/URL/hostname/port) are kept for reference; the detector doesn't use
/// them (see its rule list).
public enum PIIRegexPatterns {
    public static let ipv4 = #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#
    public static let ipv6 = #"\b(?:[0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}\b"#
    /// Key-value hostname, e.g. `host=example.com`, `hostname: example.com`.
    public static let hostnameKeyValue = #"(?:host|server|hostname|domain)(?:name)?[:\s=]+([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)*[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?"#
    /// Standalone hostname (3+ dot-separated components, e.g. `server.example.com`).
    public static let standaloneHostname = #"\b(?:[a-zA-Z0-9](?:[a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.){2,}[a-zA-Z]{2,}\b"#
    public static let port = #"(?:port|PORT)[:\s=]+\d{1,5}"#
    public static let url = #"\b(?:wss?|https?)://[^\s]+"#

    // MARK: - Curated PII catalog (Backend A)

    /// Email addresses.
    public static let email = #"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,63}\b"#
    /// Payment-card numbers (13–19 digits, optional space/hyphen separators).
    /// Anchored on a digit at both ends so a trailing separator isn't captured.
    /// Gated by an issuer prefix and Luhn (`PIIValidators.paymentCard`).
    public static let creditCard = #"(?<!\d)\d(?:[ -]?\d){12,18}(?!\d)"#
    /// International Bank Account Number — compact or canonical 4-char groups.
    /// Grouping (rather than `[ ]?[A-Z0-9]` repeated) stops the match from
    /// swallowing a trailing word after a space. Gated by MOD97-10.
    public static let iban = #"(?i)\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]{4}){2,7}(?:[ ]?[A-Z0-9]{1,3})?\b"#
    /// US Social Security Number — separated form only (dash/space) to limit FPs.
    public static let ssn = #"(?<!\d)(?!000|666|9\d{2})\d{3}[- ](?!00)\d{2}[- ](?!0000)\d{4}(?!\d)"#
    /// US Individual Taxpayer Identification Number.
    public static let itin = #"(?<!\d)9\d{2}[- ](?:7[0-9]|8[0-8]|9[0-2]|9[4-9])[- ]\d{4}(?!\d)"#
    /// UK National Insurance number.
    public static let ukNINO = #"(?i)(?<![A-Z0-9])(?!BG|GB|KN|NK|NT|TN|ZZ)[A-CEGHJ-PR-TW-Z][A-CEGHJ-NPR-TW-Z]\s?\d{2}\s?\d{2}\s?\d{2}\s?[A-D](?![A-Z0-9])"#
    /// JSON Web Tokens.
    public static let jwt = #"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"#
    /// AWS access key IDs.
    public static let awsAccessKeyID = #"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"#
    /// Provider tokens recognisable by their prefix alone, the way they get pasted
    /// bare into a prompt: Anthropic/OpenAI (`sk-…`), Stripe (`sk_live_…`, `rk_test_…`),
    /// GitHub (`ghp_…`, `github_pat_…`), Slack (`xoxb-…`), Google (`AIza…`), GitLab
    /// (`glpat-…`), Hugging Face (`hf_…`) and npm (`npm_…`).
    public static let prefixedToken = #"\b(?:sk-[A-Za-z0-9_-]{20,}|[sr]k_(?:live|test)_[A-Za-z0-9]{16,}|gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,}|xox[abprs]-[A-Za-z0-9-]{10,}|AIza[A-Za-z0-9_-]{35}|glpat-[A-Za-z0-9_-]{20,}|hf_[A-Za-z0-9]{30,}|npm_[A-Za-z0-9]{36})"#
    // The two assignment rules below catch the keyword at the end of a longer
    // name, the way secrets are actually written: `DB_PASSWORD=…`,
    // `aws_secret_access_key = …`, `"apiKey": "…"`. So the keyword may follow `_`
    // or a quote (a lookbehind for letters and digits only, where `\b` would fail
    // after `_`), and the closing quote of a JSON key may sit before the `:`.
    // A value starting with `$` is a reference, not a secret. A key is named by
    // what kind of key it is (`SECRET_KEY`, `STRIPE_SECRET_KEY`, `SIGNING_KEY`),
    // so those kinds are matched with their `key`; a bare `_KEY` isn't, since
    // `PRIMARY_KEY` and `SORT_KEY` name columns, not secrets.
    /// API key / token assignments — the value is in capture group 1.
    public static let apiKeyContextual = #"(?i)(?<![A-Z0-9])(?:api[_ -]?key|secret(?:[_ -]?key)?|(?:private|signing|encryption|master)[_ -]?key|access[_-]?key|access[_ -]?token|auth[_ -]?token|token)["']?\s*[:=]\s*["']?(?!\$)([A-Z0-9._~+/=-]{16,})"#
    /// Password assignments — the value is in capture group 1.
    public static let passwordAssignment = #"(?i)(?<![A-Z0-9])(?:password|passwd|pwd|pass)["']?\s*[:=]\s*["']?(?!\$)([^"'\s]{8,})"#
    /// `Authorization: Bearer <token>` — the token is in capture group 1.
    public static let bearerToken = #"(?i)\bbearer\s+(?!\$)([A-Z0-9._~+/=-]{16,})"#
    /// The password in a connection string, `scheme://user:PASSWORD@host` — group 1.
    public static let urlPassword = #"://[^\s:/@]+:(?!\$)([^\s:/@]+)@"#
    /// A PEM private key block, through its END line, or to the end of its
    /// base64 body when the output was cut off before it.
    public static let pemPrivateKey = #"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----(?:[\s\S]*?-----END (?:[A-Z0-9]+ )*PRIVATE KEY-----|[A-Za-z0-9+/=\s]*)"#
}

/// Backend A (C.3): the dependency-free PII detector. Reuses the log
/// redactor's regex patterns to emit spans for the network identifiers we
/// can recognise without a model — URLs, IPs, and hostnames. Also serves as
/// the fallback while a future ML backend (C.4) loads.
///
/// Matches are resolved into **non-overlapping** spans by category precedence
/// (URL first, since a URL can contain an IP/host/port), so the renderer never
/// sees nested highlights.
public final class RegexPIIDetector: PIIDetector {

    /// Bump when the patterns or category mapping change so the metrics
    /// indexer (which stores this in `SessionMetrics.piiScanVersion`) re-scans
    /// stale rows on the next reconcile.
    public static let rulesetVersion = 7

    public let isReady = true

    /// One detection rule. `captureGroup` selects which part of the match
    /// becomes the span (0 = whole match; 1 = the value of a contextual pattern
    /// like `password=…`, so only the secret is highlighted/masked, not the
    /// label). `validator`, when present, is a go/no-go gate — the matched
    /// substring must pass for the span to be emitted.
    private struct PIIRule {
        let regex: NSRegularExpression
        let category: PIICategory
        let captureGroup: Int
        let validator: (@Sendable (String) -> Bool)?
    }

    /// Patterns in precedence order: earlier entries win when ranges overlap.
    private let rules: [PIIRule]

    public init() {
        func make(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression? {
            try? NSRegularExpression(pattern: pattern, options: options)
        }
        func rule(_ pattern: String,
                  _ category: PIICategory,
                  options: NSRegularExpression.Options = [],
                  group: Int = 0,
                  validator: (@Sendable (String) -> Bool)? = nil) -> PIIRule? {
            make(pattern, options).map {
                PIIRule(regex: $0, category: category, captureGroup: group, validator: validator)
            }
        }

        let P = PIIRegexPatterns.self
        // Precedence: most specific / validated first. Secrets lead, then
        // structured identifiers (cards/IBAN/national IDs). Network identifiers (URL/IP/host),
        // MAC, UUID, and GPS are intentionally NOT detected here — they're weak
        // PII signals and produced too much noise in transcripts. (The log
        // redactor still scrubs URLs/IPs/hostnames from logs via the shared
        // `PIIRegexPatterns` strings — that path is unchanged.)
        let candidates: [PIIRule?] = [
            rule(P.pemPrivateKey, .secret),
            rule(P.jwt, .secret),
            rule(P.awsAccessKeyID, .secret),
            rule(P.prefixedToken, .secret),
            rule(P.apiKeyContextual, .secret, group: 1, validator: PIIValidators.notPlaceholder),
            rule(P.passwordAssignment, .secret, group: 1, validator: PIIValidators.notPlaceholder),
            rule(P.bearerToken, .secret, group: 1, validator: PIIValidators.notPlaceholder),
            // Before email: `user:pass@host` would otherwise read as an address.
            rule(P.urlPassword, .secret, group: 1, validator: PIIValidators.notPlaceholder),
            rule(P.email, .privateEmail),
            rule(P.creditCard, .creditCard, validator: PIIValidators.paymentCard),
            rule(P.iban, .bankAccount, validator: PIIValidators.ibanMod97),
            rule(P.ssn, .nationalID),
            rule(P.itin, .nationalID),
            rule(P.ukNINO, .nationalID),
        ]
        rules = candidates.compactMap { $0 }
    }

    public func scan(_ text: String) -> [PIISpan] {
        guard !text.isEmpty else { return [] }
        let fullRange = NSRange(text.startIndex..., in: text)

        var accepted: [PIISpan] = []
        var takenNSRanges: [NSRange] = []

        for rule in rules {
            for match in rule.regex.matches(in: text, options: [], range: fullRange) {
                let ns = match.range(at: rule.captureGroup)
                guard ns.location != NSNotFound, ns.length > 0 else { continue }
                // Skip anything overlapping a higher-precedence span.
                if takenNSRanges.contains(where: { NSIntersectionRange($0, ns).length > 0 }) { continue }
                // UTF-16-safe conversion back to String.Index. Skip if it fails.
                guard let range = Range(ns, in: text) else { continue }
                // Go/no-go validator (Luhn, MOD97, date validity).
                if let validator = rule.validator, !validator(String(text[range])) { continue }
                accepted.append(PIISpan(range: range, category: rule.category, confidence: 1.0))
                takenNSRanges.append(ns)
            }
        }

        return accepted.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
}
