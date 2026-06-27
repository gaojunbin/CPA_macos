import Foundation
import Security

/// Generates a cryptographically random API key suitable for CLIProxyAPI's `api-keys` list.
/// Format: `<prefix>` + URL-safe base64 of `byteCount` random bytes (e.g. `sk-cpa-…`).
public func generateAPIKey(prefix: String = "sk-cpa-", byteCount: Int = 24) -> String {
    var bytes = [UInt8](repeating: 0, count: max(16, byteCount))
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    let data = status == errSecSuccess ? Data(bytes) : Data(UUID().uuidString.utf8)
    let token = data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return prefix + token
}

public enum PoolClientError: LocalizedError, Sendable {
    case notConfigured
    case invalidBaseURL(String)
    case httpStatus(Int, String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Pool URL and management key are required."
        case let .invalidBaseURL(value):
            return "Invalid pool URL: \(value)"
        case let .httpStatus(status, body):
            return "HTTP \(status): \(body.prefix(180))"
        case let .invalidResponse(message):
            return "Invalid response: \(message)"
        }
    }
}

public struct CLIProxyAPIClient: Sendable {
    public let settings: AppSettings
    public let timeout: TimeInterval
    private let session: URLSession
    private static let antigravityDefaultProjectID = "bamboo-precept-lgxtn"
    private static let antigravityModelURLs = [
        "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels",
        "https://daily-cloudcode-pa.sandbox.googleapis.com/v1internal:fetchAvailableModels",
        "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels"
    ]

    public init(settings: AppSettings, session: URLSession = .shared, timeout: TimeInterval = 45) {
        self.settings = settings
        self.session = session
        self.timeout = timeout
    }

    public func fetchPoolSnapshot() async throws -> PoolSnapshot {
        let (allAuthFiles, details) = try await fetchAuthFilesAndDetails()
        let now = Date()

        let grouped = Dictionary(grouping: allAuthFiles) { auth -> String in
            let info = ProviderCatalog.info(for: auth.normalizedProvider)
            return info.key
        }

        var pools: [ProviderPool] = []
        for (providerKey, files) in grouped {
            let providerInfo = ProviderCatalog.info(for: providerKey)
            let sortedFiles = files.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            let accounts: [AccountQuota]
            if providerInfo.supportsUsage {
                accounts = await fetchAccountQuotas(sortedFiles, details: details)
            } else {
                accounts = sortedFiles.map { AccountQuota(auth: $0, usage: nil, errorMessage: nil, detail: details[$0.id]) }
            }
            pools.append(ProviderPool(provider: providerInfo, accounts: accounts, fetchedAt: now))
        }

        pools.sort { lhs, rhs in
            if lhs.provider.priority != rhs.provider.priority {
                return lhs.provider.priority < rhs.provider.priority
            }
            return lhs.provider.displayName.localizedCaseInsensitiveCompare(rhs.provider.displayName) == .orderedAscending
        }

        return PoolSnapshot(providers: pools, fetchedAt: now)
    }

    public func fetchAuthFiles() async throws -> [AuthFile] {
        try await fetchAuthFilesAndDetails().files
    }

    /// Fetches the auth-files list once, decoding both the typed `AuthFile` list (for the
    /// dashboard) and a lenient `AccountDetail` per account (for the detail view), paired by index.
    private func fetchAuthFilesAndDetails() async throws -> (files: [AuthFile], details: [String: AccountDetail]) {
        guard settings.isConfigured else {
            throw PoolClientError.notConfigured
        }

        let url = try Self.managementURL(baseURL: settings.baseURL, path: "/v0/management/auth-files")
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        applyManagementHeaders(to: &request)

        let data = try await data(for: request)
        let files = try JSONDecoder().decode(AuthFilesResponse.self, from: data).files

        var details: [String: AccountDetail] = [:]
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rawFiles = root["files"] as? [Any] {
            for (index, raw) in rawFiles.enumerated() where index < files.count {
                guard let dict = raw as? [String: Any] else { continue }
                details[files[index].id] = AccountDetail(dict: dict)
            }
        }
        return (files, details)
    }

    public func fetchModels(for auth: AuthFile) async throws -> [CPAModelDefinition] {
        guard settings.isConfigured else {
            throw PoolClientError.notConfigured
        }
        let queryName = auth.name.isEmpty ? auth.id : auth.name
        var components = URLComponents(
            url: try Self.managementURL(baseURL: settings.baseURL, path: "/v0/management/auth-files/models"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "name", value: queryName)]
        guard let url = components?.url else {
            throw PoolClientError.invalidResponse("invalid models URL")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        applyManagementHeaders(to: &request)
        let data = try await data(for: request)
        return try JSONDecoder().decode(ModelsResponse.self, from: data).models
    }

    /// Re-fetches live quota for a single account (used by the detail screen's refresh button).
    /// Carries the previously parsed `detail` through unchanged.
    public func refreshUsage(for auth: AuthFile, detail: AccountDetail? = nil) async -> AccountQuota {
        guard ProviderCatalog.info(for: auth.normalizedProvider).supportsUsage else {
            return AccountQuota(auth: auth, usage: nil, errorMessage: nil, detail: detail)
        }
        return await quota(for: auth, detail: detail)
    }

    public static func managementURL(baseURL: String, path: String) throws -> URL {
        let raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            throw PoolClientError.invalidBaseURL(baseURL)
        }

        let candidate = raw.contains("://") ? raw : "https://\(raw)"
        guard var components = URLComponents(string: candidate),
              components.scheme != nil,
              components.host != nil
        else {
            throw PoolClientError.invalidBaseURL(baseURL)
        }

        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let suffix = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, suffix].filter { !$0.isEmpty }.joined(separator: "/")
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw PoolClientError.invalidBaseURL(baseURL)
        }
        return url
    }

    private func fetchAccountQuotas(_ authFiles: [AuthFile], details: [String: AccountDetail]) async -> [AccountQuota] {
        guard !authFiles.isEmpty else {
            return []
        }

        var output: [AccountQuota] = []
        let batchSize = 8
        var start = 0
        while start < authFiles.count {
            let batch = Array(authFiles[start..<Swift.min(start + batchSize, authFiles.count)])
            let results = await withTaskGroup(of: AccountQuota.self, returning: [AccountQuota].self) { group in
                for auth in batch {
                    let detail = details[auth.id]
                    group.addTask {
                        await quota(for: auth, detail: detail)
                    }
                }
                var values: [AccountQuota] = []
                for await value in group {
                    values.append(value)
                }
                return values
            }
            output.append(contentsOf: results)
            start += batchSize
        }

        return output.sorted {
            $0.auth.displayName.localizedCaseInsensitiveCompare($1.auth.displayName) == .orderedAscending
        }
    }

    private func quota(for auth: AuthFile, detail: AccountDetail? = nil) async -> AccountQuota {
        if auth.authIndex.isEmpty {
            return AccountQuota(auth: auth, usage: nil, errorMessage: "missing auth_index", detail: detail)
        }
        if auth.disabled {
            return AccountQuota(auth: auth, usage: nil, errorMessage: nil, detail: detail)
        }

        do {
            let usage = try await fetchUsage(auth: auth)
            return AccountQuota(auth: auth, usage: usage, errorMessage: nil, detail: detail)
        } catch {
            return AccountQuota(auth: auth, usage: nil, errorMessage: error.localizedDescription, detail: detail)
        }
    }

    private func fetchUsage(auth: AuthFile) async throws -> UsageSnapshot {
        if auth.isAntigravity {
            return try await fetchAntigravityUsage(auth: auth)
        }
        if auth.isClaude {
            return try await fetchClaudeUsage(auth: auth)
        }
        if auth.isKimi {
            return try await fetchKimiUsage(auth: auth)
        }
        if auth.isXAI {
            return try await fetchXAIUsage(auth: auth)
        }
        return try await fetchWhamUsage(auth: auth)
    }

    private func fetchWhamUsage(auth: AuthFile) async throws -> UsageSnapshot {
        var headers = [
            "Authorization": "Bearer $TOKEN$",
            "Accept": "application/json",
            "Content-Type": "application/json",
            "User-Agent": "codex_cli_rs/0.76.0 (Macintosh; arm64) CPAStatusBar/1.0"
        ]
        if let accountID = auth.accountID, !accountID.isEmpty {
            headers["ChatGPT-Account-Id"] = accountID
        }

        let payload = APICallRequest(
            authIndex: auth.authIndex,
            method: "GET",
            url: "https://chatgpt.com/backend-api/wham/usage",
            header: headers,
            data: nil
        )
        return try await fetchUsageViaAPICall(payload: payload)
    }

    private func fetchAntigravityUsage(auth: AuthFile) async throws -> UsageSnapshot {
        let projectID = await antigravityProjectID(for: auth)
        let payloadBody = try jsonString(["project": projectID])
        let headers = [
            "Authorization": "Bearer $TOKEN$",
            "Content-Type": "application/json",
            "User-Agent": "antigravity/1.21.9 darwin/arm64"
        ]

        var lastError: Error?
        var emptySnapshot: UsageSnapshot?
        var sawSuccessfulResponse = false

        for url in Self.antigravityModelURLs {
            let payload = APICallRequest(
                authIndex: auth.authIndex,
                method: "POST",
                url: url,
                header: headers,
                data: payloadBody
            )

            do {
                let envelope = try await fetchAPICallEnvelope(payload: payload)
                guard (200..<300).contains(envelope.statusCode) else {
                    lastError = PoolClientError.httpStatus(envelope.statusCode, envelope.body)
                    continue
                }

                sawSuccessfulResponse = true
                if let snapshot = UsageParser.parse(envelope.body) {
                    if snapshot.hasQuotaSignal {
                        return snapshot
                    }
                    emptySnapshot = snapshot
                } else {
                    lastError = PoolClientError.invalidResponse("empty Antigravity model quota")
                }
            } catch {
                lastError = error
            }
        }

        if sawSuccessfulResponse {
            return emptySnapshot ?? UsageSnapshot(
                planType: nil,
                primary: nil,
                weekly: nil,
                rawStatus: "empty_models"
            )
        }

        throw lastError ?? PoolClientError.invalidResponse("empty Antigravity model quota")
    }

    private func fetchClaudeUsage(auth: AuthFile) async throws -> UsageSnapshot {
        let headers = [
            "Authorization": "Bearer $TOKEN$",
            "Content-Type": "application/json",
            "anthropic-beta": "oauth-2025-04-20"
        ]
        let usageEnvelope = try await fetchAPICallEnvelope(payload: APICallRequest(
            authIndex: auth.authIndex,
            method: "GET",
            url: "https://api.anthropic.com/api/oauth/usage",
            header: headers,
            data: nil
        ))
        guard (200..<300).contains(usageEnvelope.statusCode) else {
            throw PoolClientError.httpStatus(usageEnvelope.statusCode, usageEnvelope.body)
        }

        let profileEnvelope = try? await fetchAPICallEnvelope(payload: APICallRequest(
            authIndex: auth.authIndex,
            method: "GET",
            url: "https://api.anthropic.com/api/oauth/profile",
            header: headers,
            data: nil
        ))
        let usageObject = Self.jsonObject(from: usageEnvelope.body) ?? [:]
        let profileObject = profileEnvelope.flatMap { envelope -> [String: Any]? in
            guard (200..<300).contains(envelope.statusCode) else {
                return nil
            }
            return Self.jsonObject(from: envelope.body)
        }
        let body = try jsonString([
            "_provider": "claude",
            "usage": usageObject,
            "profile": profileObject ?? [:]
        ])
        if let snapshot = UsageParser.parse(body) {
            return snapshot
        }
        throw PoolClientError.invalidResponse("empty Claude quota")
    }

    private func fetchKimiUsage(auth: AuthFile) async throws -> UsageSnapshot {
        let payload = APICallRequest(
            authIndex: auth.authIndex,
            method: "GET",
            url: "https://api.kimi.com/coding/v1/usages",
            header: ["Authorization": "Bearer $TOKEN$"],
            data: nil
        )
        return try await fetchUsageViaAPICall(payload: payload)
    }

    private func fetchXAIUsage(auth: AuthFile) async throws -> UsageSnapshot {
        let payload = APICallRequest(
            authIndex: auth.authIndex,
            method: "GET",
            url: "https://cli-chat-proxy.grok.com/v1/billing",
            header: ["Authorization": "Bearer $TOKEN$"],
            data: nil
        )
        return try await fetchUsageViaAPICall(payload: payload)
    }

    private func fetchUsageViaAPICall(payload: APICallRequest) async throws -> UsageSnapshot {
        let envelope = try await fetchAPICallEnvelope(payload: payload)
        if (200..<300).contains(envelope.statusCode),
           let snapshot = UsageParser.parse(envelope.body) {
            return snapshot
        }
        if let snapshot = UsageParser.parse(envelope.body) {
            return snapshot
        }
        throw PoolClientError.httpStatus(envelope.statusCode, envelope.body)
    }

    private func fetchAPICallEnvelope(payload: APICallRequest) async throws -> APICallEnvelope {
        var request = URLRequest(
            url: try Self.managementURL(baseURL: settings.baseURL, path: "/v0/management/api-call"),
            timeoutInterval: timeout
        )
        request.httpMethod = "POST"
        applyManagementHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        var lastError: Error?
        for attempt in 1...2 {
            do {
                let data = try await data(for: request)
                return try decodeAPICallEnvelope(data)
            } catch {
                lastError = error
                if attempt == 2 || !shouldRetry(error: error) {
                    break
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
        throw lastError ?? PoolClientError.invalidResponse("empty quota response")
    }

    private func antigravityProjectID(for auth: AuthFile) async -> String {
        if let projectID = auth.projectID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !projectID.isEmpty {
            return projectID
        }
        if let body = try? await downloadAuthFile(named: auth.name),
           let projectID = Self.projectID(fromAuthFileBody: body) {
            return projectID
        }
        return Self.antigravityDefaultProjectID
    }

    private func downloadAuthFile(named name: String) async throws -> String {
        var components = URLComponents(
            url: try Self.managementURL(baseURL: settings.baseURL, path: "/v0/management/auth-files/download"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "name", value: name)]
        guard let url = components?.url else {
            throw PoolClientError.invalidResponse("invalid auth-file download URL")
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        applyManagementHeaders(to: &request)
        let data = try await data(for: request)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func projectID(fromAuthFileBody body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return firstNonEmpty(
            firstString(root["project_id"]),
            firstString(root["projectId"]),
            firstString(nested(root, "installed", "project_id")),
            firstString(nested(root, "installed", "projectId")),
            firstString(nested(root, "web", "project_id")),
            firstString(nested(root, "web", "projectId"))
        )
    }

    private static func jsonObject(from body: String) -> [String: Any]? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }

    private func jsonString(_ object: [String: String]) throws -> String {
        try jsonString(object as [String: Any])
    }

    private func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let string = String(data: data, encoding: .utf8) else {
            throw PoolClientError.invalidResponse("failed to encode JSON payload")
        }
        return string
    }

    private func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PoolClientError.invalidResponse("missing HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw PoolClientError.httpStatus(http.statusCode, body)
        }
        return data
    }

    private func applyManagementHeaders(to request: inout URLRequest) {
        request.setValue("Bearer \(settings.managementKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("CPAStatusBar/1.0", forHTTPHeaderField: "User-Agent")
    }

    private func shouldRetry(error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return [
            "timed out",
            "timeout",
            "request failed",
            "bad gateway",
            "service unavailable",
            "gateway timeout",
            "connection reset",
            "network connection was lost"
        ].contains { message.contains($0) }
    }

    private func decodeAPICallEnvelope(_ data: Data) throws -> APICallEnvelope {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PoolClientError.invalidResponse("api-call did not return a JSON object")
        }
        guard let statusCode = intValue(firstValue(object["status_code"], object["statusCode"])) else {
            throw PoolClientError.invalidResponse("api-call response missing status_code")
        }
        let body = bodyString(firstValue(object["body"], object["data"]) ?? "")
        return APICallEnvelope(statusCode: statusCode, body: body)
    }

    private func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        if let value = value as? String {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private func bodyString(_ value: Any) -> String {
        if let value = value as? String {
            return value
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return String(describing: value)
    }
}

private struct APICallRequest: Encodable {
    let authIndex: String
    let method: String
    let url: String
    let header: [String: String]
    let data: String?

    private enum CodingKeys: String, CodingKey {
        case authIndex = "auth_index"
        case method
        case url
        case header
        case data
    }
}

private struct APICallEnvelope {
    let statusCode: Int
    let body: String
}

// MARK: - OAuth login & API key management
//
// These live in the same file as `CLIProxyAPIClient` so they can reuse its private request
// helpers (`applyManagementHeaders`, `data(for:)`). The management server performs the actual
// token exchange and persistence; the client only relays callbacks and polls for completion.
public extension CLIProxyAPIClient {
    /// Requests an authorization URL and opaque session state for the given provider.
    /// Note: `is_webui` is intentionally omitted — the server would otherwise spin up its own
    /// loopback forwarder; this app captures the redirect locally instead.
    func requestOAuthURL(for provider: OAuthProvider) async throws -> OAuthAuthURL {
        guard settings.isConfigured else { throw PoolClientError.notConfigured }
        let url = try Self.managementURL(baseURL: settings.baseURL, path: provider.authPath)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        applyManagementHeaders(to: &request)
        let data = try await data(for: request)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PoolClientError.invalidResponse("auth-url response was not JSON")
        }
        guard let authURL = firstString(object["url"]), !authURL.isEmpty else {
            throw PoolClientError.invalidResponse(firstString(object["error"]) ?? "auth-url response missing url")
        }
        return OAuthAuthURL(url: authURL, state: firstString(object["state"]) ?? "")
    }

    /// Relays a captured authorization `code` + `state` to the management server.
    func submitOAuthCallback(provider: String, code: String, state: String) async throws {
        try await postOAuthCallback(body: ["provider": provider, "code": code, "state": state])
    }

    /// Relays a full redirect URL (manual paste fallback); the server extracts `code`/`state`.
    func submitOAuthCallback(provider: String, redirectURL: String, state: String) async throws {
        var body: [String: Any] = ["provider": provider, "redirect_url": redirectURL]
        if !state.isEmpty { body["state"] = state }
        try await postOAuthCallback(body: body)
    }

    private func postOAuthCallback(body: [String: Any]) async throws {
        let url = try Self.managementURL(baseURL: settings.baseURL, path: "/v0/management/oauth-callback")
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        applyManagementHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await data(for: request)
    }

    /// Polls `/v0/management/get-auth-status` for one tick.
    func pollOAuthStatus(state: String) async throws -> OAuthStatus {
        var components = URLComponents(
            url: try Self.managementURL(baseURL: settings.baseURL, path: "/v0/management/get-auth-status"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "state", value: state)]
        guard let url = components?.url else {
            throw PoolClientError.invalidResponse("invalid get-auth-status URL")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        applyManagementHeaders(to: &request)
        let data = try await data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        switch (firstString(object["status"]) ?? "").lowercased() {
        case "ok":
            return .ok
        case "error":
            return .error(firstString(object["error"]) ?? "授权失败")
        default:
            return .wait
        }
    }

    /// Returns the configured API key list (`GET /v0/management/api-keys`).
    func fetchAPIKeys() async throws -> [String] {
        guard settings.isConfigured else { throw PoolClientError.notConfigured }
        let url = try Self.managementURL(baseURL: settings.baseURL, path: "/v0/management/api-keys")
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        applyManagementHeaders(to: &request)
        let data = try await data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let raw = firstArray(object?["api-keys"], object?["api_keys"], object?["apiKeys"]) ?? []
        return raw.compactMap { firstString($0) }
    }

    /// Appends an API key. The server's PATCH appends `new` when `old` is not found, so sending
    /// `old == new == key` adds the key (and is a no-op if it already exists).
    func addAPIKey(_ key: String) async throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PoolClientError.invalidResponse("API key cannot be empty")
        }
        let url = try Self.managementURL(baseURL: settings.baseURL, path: "/v0/management/api-keys")
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "PATCH"
        applyManagementHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["old": trimmed, "new": trimmed])
        _ = try await data(for: request)
    }

    /// Deletes an API key by exact value (`DELETE /v0/management/api-keys?value=…`).
    func deleteAPIKey(_ key: String) async throws {
        var components = URLComponents(
            url: try Self.managementURL(baseURL: settings.baseURL, path: "/v0/management/api-keys"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "value", value: key)]
        guard let url = components?.url else {
            throw PoolClientError.invalidResponse("invalid api-keys URL")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "DELETE"
        applyManagementHeaders(to: &request)
        _ = try await data(for: request)
    }
}
