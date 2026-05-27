import Foundation

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

    public init(settings: AppSettings, session: URLSession = .shared, timeout: TimeInterval = 45) {
        self.settings = settings
        self.session = session
        self.timeout = timeout
    }

    public func fetchPoolSnapshot() async throws -> PoolSnapshot {
        let authFiles = try await fetchAuthFiles()
            .filter(\.isCodexLike)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        let accounts = await fetchAccountQuotas(authFiles)
        return PoolSnapshot(accounts: accounts, fetchedAt: Date())
    }

    public func fetchAuthFiles() async throws -> [AuthFile] {
        guard settings.isConfigured else {
            throw PoolClientError.notConfigured
        }

        let url = try Self.managementURL(baseURL: settings.baseURL, path: "/v0/management/auth-files")
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        applyManagementHeaders(to: &request)

        let data = try await data(for: request)
        let decoder = JSONDecoder()
        return try decoder.decode(AuthFilesResponse.self, from: data).files
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

    private func fetchAccountQuotas(_ authFiles: [AuthFile]) async -> [AccountQuota] {
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
                    group.addTask {
                        await quota(for: auth)
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

    private func quota(for auth: AuthFile) async -> AccountQuota {
        if auth.authIndex.isEmpty {
            return AccountQuota(auth: auth, usage: nil, errorMessage: "missing auth_index")
        }
        if auth.disabled {
            return AccountQuota(auth: auth, usage: nil, errorMessage: nil)
        }

        do {
            let usage = try await fetchWhamUsage(auth: auth)
            return AccountQuota(auth: auth, usage: usage, errorMessage: nil)
        } catch {
            return AccountQuota(auth: auth, usage: nil, errorMessage: error.localizedDescription)
        }
    }

    private func fetchWhamUsage(auth: AuthFile) async throws -> UsageSnapshot {
        var request = URLRequest(
            url: try Self.managementURL(baseURL: settings.baseURL, path: "/v0/management/api-call"),
            timeoutInterval: timeout
        )
        request.httpMethod = "POST"
        applyManagementHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

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
        request.httpBody = try JSONEncoder().encode(payload)

        var lastError: Error?
        for attempt in 1...2 {
            do {
                let data = try await data(for: request)
                let envelope = try decodeAPICallEnvelope(data)
                if (200..<300).contains(envelope.statusCode),
                   let snapshot = UsageParser.parse(envelope.body) {
                    return snapshot
                }
                if let snapshot = UsageParser.parse(envelope.body) {
                    return snapshot
                }
                throw PoolClientError.httpStatus(envelope.statusCode, envelope.body)
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
