import XCTest
@testable import CPAStatusCore

final class ClientContractTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testXAIAuthURLUsesDeviceFlowMetadata() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v0/management/xai-auth-url")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer management-secret")
            return StubURLProtocol.jsonResponse(
                request,
                status: 200,
                object: [
                    "url": "https://accounts.x.ai/device?user_code=ABCD-EFGH",
                    "state": "xai-state",
                    "flow": "device",
                    "user_code": "ABCD-EFGH",
                    "expires_in": 1_800
                ]
            )
        }

        let client = makeClient()
        let response = try await client.requestOAuthURL(for: .xai)
        XCTAssertTrue(OAuthProvider.xai.usesDeviceFlow)
        XCTAssertTrue(response.isDeviceFlow)
        XCTAssertEqual(response.userCode, "ABCD-EFGH")
        XCTAssertEqual(response.expiresIn, 1_800)
    }

    func testGrokQuotaRequestsWeeklyAndMonthlyContracts() async throws {
        let recorder = RequestRecorder()
        StubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/v0/management/auth-files" {
                return StubURLProtocol.jsonResponse(request, status: 200, object: [
                    "files": [[
                        "id": "xai-account",
                        "auth_index": "xai-index",
                        "name": "xai-account.json",
                        "provider": "xai"
                    ]]
                ])
            }
            if path == "/v0/management/auth-files/download" {
                return StubURLProtocol.dataResponse(request, status: 200, data: Data(#"{"sub":"xai-user-123"}"#.utf8))
            }
            if path == "/v0/management/api-call" {
                let payload = try XCTUnwrap(StubURLProtocol.jsonBody(request))
                recorder.append(payload)
                let target = payload["url"] as? String ?? ""
                if target.contains("format=credits") {
                    return StubURLProtocol.apiCallResponse(request, body: #"{"config":{"currentPeriod":{"type":"weekly","end":"2026-08-01T00:00:00Z"},"creditUsagePercent":25,"productUsage":[{"product":"Grok Code","usagePercent":40}]}}"#)
                }
                return StubURLProtocol.apiCallResponse(request, body: #"{"config":{"monthlyLimit":{"val":10000},"used":{"val":2000},"onDemandCap":{"val":5000},"billingPeriodEnd":"2026-08-01T00:00:00Z"}}"#)
            }
            return StubURLProtocol.jsonResponse(request, status: 404, object: ["error": "not found"])
        }

        let snapshot = try await makeClient().fetchPoolSnapshot()
        let account = try XCTUnwrap(snapshot.providers.first { $0.provider.key == "xai" }?.accounts.first)
        XCTAssertEqual(account.usage?.additionalWindows.first?.label, "周积分")
        XCTAssertEqual(account.usage?.additionalWindows.first?.remainingPercent, 75)

        let calls = recorder.values()
        XCTAssertEqual(calls.count, 2)
        let targets = Set(calls.compactMap { $0["url"] as? String })
        XCTAssertTrue(targets.contains("https://cli-chat-proxy.grok.com/v1/billing?format=credits"))
        XCTAssertTrue(targets.contains("https://cli-chat-proxy.grok.com/v1/billing"))
        for call in calls {
            let headers = try XCTUnwrap(call["header"] as? [String: String])
            XCTAssertEqual(headers["x-xai-token-auth"], "xai-grok-cli")
            XCTAssertEqual(headers["x-grok-client-version"], "0.2.93")
            XCTAssertEqual(headers["x-userid"], "xai-user-123")
        }
    }

    func testAntigravityUsesQuotaSummaryAndSubscriptionContracts() async throws {
        let recorder = RequestRecorder()
        StubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/v0/management/auth-files" {
                return StubURLProtocol.jsonResponse(request, status: 200, object: [
                    "files": [[
                        "id": "antigravity-account",
                        "auth_index": "ag-index",
                        "name": "antigravity-account.json",
                        "provider": "antigravity",
                        "project_id": "project-123"
                    ]]
                ])
            }
            if path == "/v0/management/api-call" {
                let payload = try XCTUnwrap(StubURLProtocol.jsonBody(request))
                recorder.append(payload)
                let target = payload["url"] as? String ?? ""
                if target.contains("loadCodeAssist") {
                    return StubURLProtocol.apiCallResponse(request, body: #"{"paidTier":{"id":"g1-pro-tier","name":"Google AI Pro"}}"#)
                }
                return StubURLProtocol.apiCallResponse(request, body: #"{"groups":[{"displayName":"Claude and GPT Models","buckets":[{"bucketId":"weekly","displayName":"Weekly Limit","remainingFraction":0.8,"resetTime":"2026-08-01T00:00:00Z"}]}]}"#)
            }
            return StubURLProtocol.jsonResponse(request, status: 404, object: ["error": "not found"])
        }

        let snapshot = try await makeClient().fetchPoolSnapshot()
        let account = try XCTUnwrap(snapshot.providers.first { $0.provider.key == "antigravity" }?.accounts.first)
        XCTAssertEqual(account.effectivePlanType, "pro")
        XCTAssertEqual(account.usage?.additionalWindows.first?.remainingPercent, 80)

        let calls = recorder.values()
        XCTAssertEqual(calls.count, 2)
        let targets = calls.compactMap { $0["url"] as? String }
        XCTAssertTrue(targets.contains { $0.contains("retrieveUserQuotaSummary") })
        XCTAssertTrue(targets.contains { $0.contains("loadCodeAssist") })
        XCTAssertFalse(targets.contains { $0.contains("fetchAvailableModels") })
        let quotaCall = try XCTUnwrap(calls.first { (($0["url"] as? String) ?? "").contains("retrieveUserQuotaSummary") })
        XCTAssertEqual(quotaCall["data"] as? String, #"{"project":"project-123"}"#)
    }

    func testCodexUsageAlsoRequestsResetCreditsWithoutConsumingThem() async throws {
        let recorder = RequestRecorder()
        StubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/v0/management/auth-files" {
                return StubURLProtocol.jsonResponse(request, status: 200, object: [
                    "files": [[
                        "id": "codex-account",
                        "auth_index": "codex-index",
                        "name": "codex-account.json",
                        "provider": "codex",
                        "account_id": "chatgpt-account"
                    ]]
                ])
            }
            if path == "/v0/management/api-call" {
                let payload = try XCTUnwrap(StubURLProtocol.jsonBody(request))
                recorder.append(payload)
                let target = payload["url"] as? String ?? ""
                if target.hasSuffix("rate-limit-reset-credits") {
                    return StubURLProtocol.apiCallResponse(request, body: #"{"available_count":2,"credits":[]}"#)
                }
                return StubURLProtocol.apiCallResponse(request, body: #"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":20,"limit_window_seconds":18000},"secondary_window":{"used_percent":30,"limit_window_seconds":604800}}}"#)
            }
            return StubURLProtocol.jsonResponse(request, status: 404, object: ["error": "not found"])
        }

        let snapshot = try await makeClient().fetchPoolSnapshot()
        let account = try XCTUnwrap(snapshot.providers.first { $0.provider.key == "codex" }?.accounts.first)
        XCTAssertEqual(account.usage?.additionalWindows.last?.label, "主动重置次数")
        XCTAssertEqual(account.usage?.additionalWindows.last?.displayValue, "2")

        let calls = recorder.values()
        XCTAssertEqual(calls.count, 2)
        XCTAssertFalse(calls.contains { (($0["url"] as? String) ?? "").contains("/consume") })
        let resetCall = try XCTUnwrap(calls.first { (($0["url"] as? String) ?? "").hasSuffix("rate-limit-reset-credits") })
        let headers = try XCTUnwrap(resetCall["header"] as? [String: String])
        XCTAssertEqual(headers["OpenAI-Beta"], "codex-1")
        XCTAssertEqual(headers["Originator"], "Codex Desktop")
        XCTAssertEqual(headers["ChatGPT-Account-Id"], "chatgpt-account")
    }

    func testRoutingSnapshotDownloadsEncodedSafePerAccountOverridesWithFallbacks() async throws {
        let downloadedNames = StringRecorder()
        let downloadURLs = StringRecorder()
        let specialName = "codex account+测试.json"
        StubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            switch path {
            case "/v0/management/auth-files":
                return StubURLProtocol.jsonResponse(request, status: 200, object: [
                    "files": [
                        [
                            "id": "override-account",
                            "auth_index": "override-index",
                            "name": specialName,
                            "provider": "codex",
                            "prefix": "team",
                            "priority": 1,
                            "using_api": false,
                            "proxy_url": "http://fallback-user:fallback-pass@fallback-proxy.example:9000?secret=old",
                            "note": "Auth list fallback"
                        ],
                        [
                            "id": "failed-download-account",
                            "auth_index": "fallback-index",
                            "name": "fallback account.json",
                            "provider": "codex",
                            "prefix": "fallback"
                        ],
                        [
                            "id": "runtime-account",
                            "auth_index": "runtime-index",
                            "name": "runtime account.json",
                            "provider": "codex",
                            "prefix": "runtime",
                            "runtime_only": true
                        ]
                    ]
                ])

            case "/v0/management/auth-files/download":
                let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
                let name = try XCTUnwrap(components.queryItems?.first { $0.name == "name" }?.value)
                downloadedNames.append(name)
                downloadURLs.append(try XCTUnwrap(request.url).absoluteString)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer management-secret")
                if name == specialName {
                    return StubURLProtocol.dataResponse(
                        request,
                        status: 200,
                        data: Data("""
                        {
                          "access_token": "super-secret-access-token",
                          "refresh_token": "super-secret-refresh-token",
                          "prefix": "secure-team",
                          "priority": "42",
                          "using-api": true,
                          "proxyURL": "http://proxy-user:proxy-pass@proxy.example:8080/tunnel?token=proxy-secret#fragment",
                          "note": "Primary OAuth egress",
                          "model-aliases": [
                            {"name": "account-upstream", "alias": "shared-client"},
                            {"name": "account-local", "alias": "local-client", "fork": true}
                          ],
                          "excluded_models": ["account-private-*", "GLOBAL-BLOCKED"]
                        }
                        """.utf8)
                    )
                }
                return StubURLProtocol.jsonResponse(request, status: 503, object: ["error": "temporarily unavailable"])

            case "/v0/management/auth-files/models":
                return StubURLProtocol.jsonResponse(request, status: 200, object: [
                    "models": [["id": "gpt-5"]]
                ])

            case "/v0/management/oauth-model-alias":
                return StubURLProtocol.jsonResponse(request, status: 200, object: [
                    "oauth-model-alias": [
                        "codex": [
                            ["name": "global-upstream", "alias": "shared-client"],
                            ["name": "global-other", "alias": "other-client"]
                        ]
                    ]
                ])

            case "/v0/management/oauth-excluded-models":
                return StubURLProtocol.jsonResponse(request, status: 200, object: [
                    "oauth-excluded-models": ["codex": ["global-blocked", "common-model"]]
                ])

            case "/v0/management/force-model-prefix":
                return StubURLProtocol.jsonResponse(request, status: 200, object: ["force-model-prefix": true])

            case "/v0/management/routing/strategy":
                return StubURLProtocol.jsonResponse(request, status: 200, object: ["strategy": "round-robin"])

            case "/v0/management/openai-compatibility",
                 "/v0/management/claude-api-key",
                 "/v0/management/codex-api-key",
                 "/v0/management/gemini-api-key",
                 "/v0/management/interactions-api-key",
                 "/v0/management/vertex-api-key":
                return StubURLProtocol.jsonResponse(request, status: 404, object: ["error": "not configured"])

            default:
                return StubURLProtocol.jsonResponse(request, status: 404, object: ["error": "not found"])
            }
        }

        let snapshot = try await makeClient().fetchModelRoutingSnapshot()
        let codex = try XCTUnwrap(snapshot.providers.first { $0.provider.key == "codex" })

        XCTAssertTrue(codex.routes.contains {
            $0.publicModelID == "secure-team/shared-client" && $0.upstreamModelName == "account-upstream"
        })
        XCTAssertFalse(codex.routes.contains {
            $0.publicModelID == "secure-team/shared-client" && $0.upstreamModelName == "global-upstream"
        })
        XCTAssertTrue(codex.routes.contains {
            $0.publicModelID == "secure-team/other-client" && $0.upstreamModelName == "global-other"
        })
        XCTAssertTrue(codex.routes.contains {
            $0.publicModelID == "fallback/shared-client" && $0.upstreamModelName == "global-upstream"
        })
        XCTAssertTrue(codex.routes.contains {
            $0.publicModelID == "runtime/shared-client" && $0.upstreamModelName == "global-upstream"
        })
        XCTAssertTrue(codex.routes.contains {
            $0.publicModelID == "secure-team/account-local" && $0.upstreamModelName == "account-local" && $0.fork
        })
        XCTAssertEqual(codex.excludedModels, ["global-blocked", "common-model", "account-private-*"])
        XCTAssertEqual(codex.prefixes, ["secure-team", "fallback", "runtime"])
        XCTAssertEqual(codex.priorities, [42])
        XCTAssertEqual(codex.officialAPIAccounts, 1)
        XCTAssertEqual(codex.proxyURLs, ["http://proxy.example:8080/tunnel"])
        XCTAssertEqual(codex.notes, ["Primary OAuth egress"])
        XCTAssertTrue(codex.baseURLs.isEmpty)
        XCTAssertFalse(String(describing: snapshot).contains("super-secret"))
        XCTAssertFalse(String(describing: snapshot).contains("proxy-user"))
        XCTAssertFalse(String(describing: snapshot).contains("proxy-pass"))
        XCTAssertFalse(String(describing: snapshot).contains("proxy-secret"))
        XCTAssertFalse(String(describing: snapshot).contains("fallback-user"))
        XCTAssertFalse(String(describing: snapshot).contains("fallback-pass"))

        XCTAssertEqual(downloadedNames.values().sorted(), ["fallback account.json", specialName].sorted())
        XCTAssertFalse(downloadedNames.values().contains("runtime account.json"))
        let encodedURL = try XCTUnwrap(downloadURLs.values().first { $0.contains("%2B") })
        XCTAssertTrue(encodedURL.contains("%20"))
        XCTAssertTrue(encodedURL.contains("%E6%B5%8B%E8%AF%95"))
        XCTAssertFalse(encodedURL.contains("测试"))
    }

    private func makeClient() -> CLIProxyAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return CLIProxyAPIClient(
            settings: AppSettings(baseURL: "https://pool.example", managementKey: "management-secret"),
            session: session,
            timeout: 5
        )
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[String: Any]] = []

    func append(_ value: [String: Any]) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    func values() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class StringRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    func values() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else {
                throw URLError(.badServerResponse)
            }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func jsonBody(_ request: URLRequest) -> [String: Any]? {
        let body: Data?
        if let direct = request.httpBody {
            body = direct
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            body = data
        } else {
            body = nil
        }
        guard let body else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    static func apiCallResponse(_ request: URLRequest, body: String) -> (HTTPURLResponse, Data) {
        jsonResponse(request, status: 200, object: ["status_code": 200, "body": body])
    }

    static func jsonResponse(
        _ request: URLRequest,
        status: Int,
        object: Any
    ) -> (HTTPURLResponse, Data) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return dataResponse(request, status: status, data: data, headers: ["Content-Type": "application/json"])
    }

    static func dataResponse(
        _ request: URLRequest,
        status: Int,
        data: Data,
        headers: [String: String] = [:]
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        return (response, data)
    }
}
