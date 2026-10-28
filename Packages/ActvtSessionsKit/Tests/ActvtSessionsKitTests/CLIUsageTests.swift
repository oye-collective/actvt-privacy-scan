//
//  CLIUsageTests.swift
//  ActvtSessionsKitTests
//

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ActvtSessionsKit

final class CLIUsageTests: XCTestCase {

    private var home: URL!
    // The shared reader judges expiry against the real clock, as the app does.
    private let now = Date()
    private let token = "sk-ant-oat01-test-token-never-printed"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        StubURLProtocol.reset()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: - Helpers

    private func run(
        _ args: [String] = ["--json"], environment: [String: String] = [:]
    ) async -> (status: Int32, stdout: String, stderr: String) {
        var out = "", err = ""
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let status = await CLIRunner.runUsage(
            args,
            stdout: { out += $0 }, stderr: { err += $0 },
            home: home, environment: environment, allowKeychain: false,
            session: URLSession(configuration: config), now: now)
        return (status.code, out, err)
    }

    private func payload(_ stdout: String) throws -> RemoteUsagePayload {
        try RemoteSessionPayload.makeDecoder().decode(RemoteUsagePayload.self, from: Data(stdout.utf8))
    }

    private func writeClaude(accessToken: String, expiresAtMs: Double) throws {
        let dir = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
        {"claudeAiOauth":{"accessToken":"\(accessToken)","refreshToken":"","expiresAt":\(expiresAtMs),
         "scopes":["user:inference","user:profile"],"subscriptionType":"max",
         "rateLimitTier":"default_claude_max_20x"}}
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent(".credentials.json"))
    }

    private func firstProvider() async throws -> RemoteProviderUsage? {
        try payload(await run().stdout).providers.first
    }

    private var validUntilMs: Double { (now.timeIntervalSince1970 + 3_600) * 1_000 }

    // MARK: - Which providers appear

    func testAHostWithNeitherCLISetUpReportsNoProviders() async throws {
        let result = await run()
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(try payload(result.stdout).providers.isEmpty)
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    func testOnlyJSONOutputIsSupported() async {
        let result = await run([])
        XCTAssertEqual(result.status, 64)
        let unknown = await run(["--json", "--nope"])
        XCTAssertEqual(unknown.status, 64)
    }

    // MARK: - Claude, without a request

    /// What a signed-out Claude Code leaves on disk: scopes and plan intact,
    /// tokens blanked. It is signed out, not a token to try.
    func testABlankedClaudeLoginIsSignedOutWithoutARequest() async throws {
        try writeClaude(accessToken: "", expiresAtMs: 0)
        let first = try await firstProvider()
        let claude = try XCTUnwrap(first)
        XCTAssertEqual(claude.usage.providerRaw, "claudeCode")
        XCTAssertEqual(claude.usage.state, .needsAuth)
        XCTAssertNil(claude.authHint)
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    func testAClaudeDirectoryWithNoCredentialsFileIsSignedOut() async throws {
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let first = try await firstProvider()
        let claude = try XCTUnwrap(first)
        XCTAssertEqual(claude.usage.state, .needsAuth)
        XCTAssertNil(claude.authHint)
    }

    func testAnExpiredStoredTokenIsStaleNotSignedOut() async throws {
        try writeClaude(accessToken: token, expiresAtMs: (now.timeIntervalSince1970 - 60) * 1_000)
        let first = try await firstProvider()
        let claude = try XCTUnwrap(first)
        XCTAssertEqual(claude.usage.state, .needsAuth)
        XCTAssertEqual(claude.authHint, "staleStoredToken")
        XCTAssertEqual(StubURLProtocol.requestCount, 0, "an expired token is never sent")
    }

    // MARK: - Claude, against the endpoint

    func testClaudeUsageWindowsAndPlan() async throws {
        try writeClaude(accessToken: token, expiresAtMs: validUntilMs)
        StubURLProtocol.respond(status: 200, body: """
        {"five_hour":{"utilization":42.0,"resets_at":"2026-10-05T18:00:00Z"},
         "seven_day":{"utilization":17,"resets_at":"2026-10-09T10:00:00.123Z"}}
        """)
        let result = await run()
        let claude = try XCTUnwrap(try payload(result.stdout).providers.first)
        XCTAssertEqual(claude.usage.state, .ok)
        XCTAssertEqual(claude.usage.planLabel, "Max 20x")
        XCTAssertEqual(try XCTUnwrap(claude.usage.session?.usedFraction), 0.42, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(claude.usage.weekly?.usedFraction), 0.17, accuracy: 1e-9)
        XCTAssertNotNil(claude.usage.session?.resetsAt)
        XCTAssertNil(claude.authHint)

        XCTAssertEqual(StubURLProtocol.lastRequest?.url, ClaudeUsageFetcher.endpoint)
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"),
                       "Bearer \(token)")
        XCTAssertFalse(result.stdout.contains(token), "the token must never be printed")
        XCTAssertFalse(result.stderr.contains(token))
    }

    /// A setup token authenticates but lacks `user:profile`. Signing in the
    /// same way again changes nothing, so it must not read as "sign in again".
    func testAScopeRefusalIsDistinctFromSignedOut() async throws {
        try writeClaude(accessToken: token, expiresAtMs: validUntilMs)
        StubURLProtocol.respond(status: 403, body: """
        {"error":{"type":"permission_error","details":{"error_code":"oauth_scope_insufficient",
         "required_scopes":["user:profile"]}}}
        """)
        let first = try await firstProvider()
        let claude = try XCTUnwrap(first)
        XCTAssertEqual(claude.usage.state, .needsAuth)
        XCTAssertEqual(claude.authHint, "insufficientScope")
        XCTAssertEqual(claude.requiredScopes, ["user:profile"])
    }

    func testARevokedTokenIsSignedOut() async throws {
        try writeClaude(accessToken: token, expiresAtMs: validUntilMs)
        StubURLProtocol.respond(status: 401, body: #"{"type":"error","error":{"type":"authentication_error"}}"#)
        let first = try await firstProvider()
        let claude = try XCTUnwrap(first)
        XCTAssertEqual(claude.usage.state, .needsAuth)
        XCTAssertNil(claude.authHint)
    }

    func testARateLimitCarriesItsRetryAfter() async throws {
        try writeClaude(accessToken: token, expiresAtMs: validUntilMs)
        StubURLProtocol.respond(status: 429, body: "{}", headers: ["Retry-After": "120"])
        let result = await run()
        XCTAssertEqual(result.status, 0, "a degraded provider is a result, not a failure")
        let claude = try XCTUnwrap(try payload(result.stdout).providers.first)
        XCTAssertEqual(claude.usage.state, .rateLimited)
        XCTAssertNotNil(claude.retryAfter)
    }

    func testADriftedShapeGivesMissingWindowsNotAFailure() async throws {
        try writeClaude(accessToken: token, expiresAtMs: validUntilMs)
        StubURLProtocol.respond(status: 200, body: #"{"something_new":{"x":1}}"#)
        let first = try await firstProvider()
        let claude = try XCTUnwrap(first)
        XCTAssertEqual(claude.usage.state, .ok)
        XCTAssertNil(claude.usage.session)
        XCTAssertNil(claude.usage.weekly)
    }

    // MARK: - Codex

    // MARK: - Setup token (oye-collective/actvt-macos#38)

    private let setupToken = "sk-ant-oat01-setup-token-never-printed"

    private let planHeaders = [
        "anthropic-ratelimit-unified-5h-utilization": "0.2",
        "anthropic-ratelimit-unified-5h-reset": "1791379200",
        "anthropic-ratelimit-unified-7d-utilization": "0.62",
        "anthropic-ratelimit-unified-7d-reset": "1791748800",
    ]

    private let messageBody = #"{"type":"message","content":[{"type":"text","text":"."}]}"#

    /// Claude Code runs on the setup token whatever the stores hold, so the
    /// reading is that account's, from the rate-limit headers.
    func testASetupTokenWinsOverTheStoredLogin() async throws {
        try writeClaude(accessToken: token, expiresAtMs: validUntilMs)
        StubURLProtocol.respond(status: 200, body: messageBody, headers: planHeaders)
        let result = await run(environment: ["CLAUDE_CODE_OAUTH_TOKEN": setupToken])
        let claude = try XCTUnwrap(try payload(result.stdout).providers.first)

        XCTAssertEqual(claude.usage.state, .ok)
        XCTAssertEqual(claude.usage.session?.usedFraction, 0.2)
        XCTAssertEqual(claude.usage.session?.resetsAt, Date(timeIntervalSince1970: 1_791_379_200))
        XCTAssertEqual(claude.usage.session?.windowSeconds, 18_000)
        XCTAssertEqual(claude.usage.weekly?.usedFraction, 0.62)
        XCTAssertEqual(claude.usage.weekly?.windowSeconds, 604_800)
        XCTAssertNil(claude.usage.planLabel, "headers name no plan, and the stored login's isn't this account's")
        XCTAssertEqual(claude.usage.perModel, [])

        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
        XCTAssertEqual(request.url, ClaudeRateLimitHeaders.endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(setupToken)")
        XCTAssertFalse(result.stdout.contains(setupToken), "the token must never be printed")
        XCTAssertFalse(result.stderr.contains(setupToken))
    }

    /// How the user's `claude()` passes it: on a pipe, never in the environment.
    func testASetupTokenOnADescriptorIsRead() async throws {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data((setupToken + "\n").utf8))
        try pipe.fileHandleForWriting.close()
        StubURLProtocol.respond(status: 200, body: messageBody, headers: planHeaders)

        let fd = pipe.fileHandleForReading.fileDescriptor
        let result = await run(environment: ["CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR": "\(fd)"])
        let claude = try XCTUnwrap(try payload(result.stdout).providers.first)
        XCTAssertEqual(claude.usage.state, .ok)
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"),
                       "Bearer \(setupToken)")
    }

    /// An agent's shell inherits the variable after `claude` consumed the
    /// token: a closed or drained descriptor means the stores, as for Claude Code.
    func testADeadDescriptorFallsBackToTheStoredLogin() async throws {
        try writeClaude(accessToken: token, expiresAtMs: validUntilMs)
        let pipe = Pipe()
        try pipe.fileHandleForWriting.close()

        for fd in ["\(pipe.fileHandleForReading.fileDescriptor)", "9876", "x"] {
            StubURLProtocol.reset()
            StubURLProtocol.respond(status: 200, body: #"{"five_hour":{"utilization":42.0}}"#)
            let result = await run(environment: ["CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR": fd])
            let claude = try XCTUnwrap(try payload(result.stdout).providers.first)
            XCTAssertEqual(claude.usage.state, .ok, fd)
            XCTAssertEqual(StubURLProtocol.lastRequest?.url, ClaudeUsageFetcher.endpoint, fd)
        }
    }

    /// At the limit the call is refused, and the headers still report it.
    func testASetupTokenAtTheLimitStillReportsItsWindow() async throws {
        var headers = planHeaders
        headers["anthropic-ratelimit-unified-5h-utilization"] = "1.0"
        StubURLProtocol.respond(status: 429, body: "{}", headers: headers)
        let result = await run(environment: ["CLAUDE_CODE_OAUTH_TOKEN": setupToken])
        let claude = try XCTUnwrap(try payload(result.stdout).providers.first)
        XCTAssertEqual(claude.usage.state, .ok)
        XCTAssertEqual(claude.usage.session?.usedFraction, 1.0)
    }

    func testARevokedSetupTokenIsSignedOut() async throws {
        StubURLProtocol.respond(status: 401, body: #"{"type":"error"}"#)
        let result = await run(environment: ["CLAUDE_CODE_OAUTH_TOKEN": setupToken])
        let claude = try XCTUnwrap(try payload(result.stdout).providers.first)
        XCTAssertEqual(claude.usage.state, .needsAuth)
        XCTAssertNil(claude.usage.session)
    }

    /// No headers means no reading: never invented numbers.
    func testAnAnswerWithoutPlanHeadersIsNoReading() async throws {
        StubURLProtocol.respond(status: 200, body: messageBody)
        let result = await run(environment: ["CLAUDE_CODE_OAUTH_TOKEN": setupToken])
        let claude = try XCTUnwrap(try payload(result.stdout).providers.first)
        XCTAssertNotEqual(claude.usage.state, .ok)
        XCTAssertNil(claude.usage.session)
        XCTAssertNil(claude.usage.weekly)
    }

    func testCodexUsage() async throws {
        let dir = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"tokens":{"access_token":"codex-opaque-token","account_id":"acct-1"}}"#.utf8)
            .write(to: dir.appendingPathComponent("auth.json"))
        StubURLProtocol.respond(status: 200, body: """
        {"plan_type":"plus","rate_limit":{
          "primary_window":{"used_percent":12,"reset_at":1791210000,"limit_window_seconds":18000},
          "secondary_window":{"used_percent":55.5,"reset_at":1791700000,"limit_window_seconds":604800}}}
        """)
        let result = await run()
        let codex = try XCTUnwrap(try payload(result.stdout).providers.first)
        XCTAssertEqual(codex.usage.providerRaw, "codexCLI")
        XCTAssertEqual(codex.usage.state, .ok)
        XCTAssertEqual(codex.usage.planLabel, "Plus")
        XCTAssertEqual(try XCTUnwrap(codex.usage.weekly?.usedFraction), 0.555, accuracy: 1e-9)
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "acct-1")
        XCTAssertFalse(result.stdout.contains("codex-opaque-token"))
    }

    func testACodexHomeWithoutAuthIsSignedOut() async throws {
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        let first = try await firstProvider()
        let codex = try XCTUnwrap(first)
        XCTAssertEqual(codex.usage.providerRaw, "codexCLI")
        XCTAssertEqual(codex.usage.state, .needsAuth)
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }
}

/// Answers every request with one canned response and records what was asked.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private struct State {
        var status = 500
        var body = Data()
        var headers: [String: String] = [:]
        var requests: [URLRequest] = []
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = State()

    static func reset() { lock.withLock { state = State() } }

    static func respond(status: Int, body: String, headers: [String: String] = [:]) {
        lock.withLock {
            state.status = status
            state.body = Data(body.utf8)
            state.headers = headers
        }
    }

    static var requestCount: Int { lock.withLock { state.requests.count } }
    static var lastRequest: URLRequest? { lock.withLock { state.requests.last } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, body, headers) = Self.lock.withLock { () -> (Int, Data, [String: String]) in
            Self.state.requests.append(request)
            return (Self.state.status, Self.state.body, Self.state.headers)
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
