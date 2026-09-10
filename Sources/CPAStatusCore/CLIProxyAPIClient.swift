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
    private static let antigravityQuotaURLs = [
        "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
        "https://daily-cloudcode-pa.sandbox.googleapis.com/v1internal:retrieveUserQuotaSummary",
        "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
    ]
    private static let antigravityLegacyModelURLs = [
        "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels",
        "https://daily-cloudcode-pa.sandbox.googleapis.com/v1internal:fetchAvailableModels",
        "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels"
    ]
    private static let antigravitySubscriptionURL =
        "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
    private static let antigravityUserAgent =
        "antigravity/cli/1.0.13 (aidev_client; os_type=darwin; arch=arm64)"
    private static let xaiClientVersion = "0.2.93"
    private static let xaiBillingWeeklyURL = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
    private static let xaiBillingMonthlyURL = "https://cli-chat-proxy.grok.com/v1/billing"

    public init(settings: AppSettings, session: URLSession = .shared, timeout: TimeInterval = 45) {
        self.settings = settings
        self.session = session
        self.timeout = timeout
    }

    public func fetchPoolSnapshot() async throws -> PoolSnapshot {
        // Config-based channels (openai-compatibility / api-key sections) never
        // appear in auth-files; fetch them concurrently and add their own sections.
        async let configChannels = fetchConfigChannelAccounts()
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

        let groupedConfig = Dictionary(grouping: await configChannels.accounts) { account in
            ProviderCatalog.info(for: account.auth.normalizedProvider).key
        }
        for (providerKey, channelAccounts) in groupedConfig {
            let providerInfo = ProviderCatalog.info(for: providerKey)
            let accounts = channelAccounts.map { account in
                AccountQuota(
                    auth: account.auth,
                    usage: nil,
                    errorMessage: nil,
                    detail: AccountDetail(dict: Self.configDetailDict(for: account)),
                    configModels: account.models
                )
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

    /// Minimal detail payload for a config-channel credential so the detail
    /// screen's 账号信息 card has something truthful to show.
    private static func configDetailDict(for account: ConfigChannelAccount) -> [String: Any] {
        var dict: [String: Any] = ["source": "config"]
        if let baseURL = account.baseURL, !baseURL.isEmpty {
            dict["note"] = baseURL
        }
        return dict
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
        // Multiple virtual accounts can share a filename; the server also accepts the unique auth ID.
        let queryName = auth.id.isEmpty ? auth.name : auth.id
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

    /// Aggregates the models every enabled account can serve into a per-provider snapshot —
    /// the menu bar equivalent of the proxy's `/v1/models`, but reachable with just the
    /// management key. Disabled accounts are skipped because the server drops them from
    /// rotation (their registry model list is empty anyway). Config-based channels
    /// (openai-compatibility and the api-key sections) never appear in the auth-files
    /// list, so they are read from their own config endpoints and merged in.
    public func fetchModelPool() async throws -> ModelPoolSnapshot {
        async let configChannels = fetchConfigChannelAccounts()
        async let forcePrefixRoot = fetchOptionalManagementJSON(path: "/v0/management/force-model-prefix")
        let authFiles = try await fetchAuthFiles().filter { !$0.disabled && !$0.unavailable }

        var results: [AuthModelsResult] = []
        let batchSize = 8
        var start = 0
        while start < authFiles.count {
            let batch = Array(authFiles[start..<Swift.min(start + batchSize, authFiles.count)])
            let batchResults = await withTaskGroup(of: AuthModelsResult.self, returning: [AuthModelsResult].self) { group in
                for auth in batch {
                    group.addTask {
                        do {
                            return AuthModelsResult(auth: auth, models: try await self.fetchModels(for: auth))
                        } catch {
                            return AuthModelsResult(auth: auth, models: nil)
                        }
                    }
                }
                var values: [AuthModelsResult] = []
                for await value in group {
                    values.append(value)
                }
                return values
            }
            results.append(contentsOf: batchResults)
            start += batchSize
        }

        let config = await configChannels
        let forceModelPrefix = boolValue((await forcePrefixRoot)?["force-model-prefix"]) ?? false
        results.append(contentsOf: config.accounts.map { account in
            let models: [CPAModelDefinition]
            if forceModelPrefix, let prefix = account.auth.prefix, !prefix.isEmpty {
                let requiredPrefix = prefix.lowercased() + "/"
                models = account.models.filter { $0.id.lowercased().hasPrefix(requiredPrefix) }
            } else {
                models = account.models
            }
            return AuthModelsResult(auth: account.auth, models: models)
        })
        results.append(contentsOf: config.failedSections.map { ConfigChannelSynthesizer.failureResult(providerKey: $0) })
        return ModelPoolAggregator.aggregate(results)
    }

    /// Reads routing strategy, prefix policy, OAuth aliases/exclusions, config-channel
    /// mappings, and the currently advertised model catalog into a compact snapshot.
    public func fetchModelRoutingSnapshot() async throws -> ModelRoutingSnapshot {
        async let authTask = fetchAuthFilesAndDetails()
        async let configTask = fetchConfigChannelAccounts()
        async let modelPoolTask = fetchModelPool()
        async let aliasesTask = fetchOptionalManagementJSON(path: "/v0/management/oauth-model-alias")
        async let excludedTask = fetchOptionalManagementJSON(path: "/v0/management/oauth-excluded-models")
        async let strategyTask = fetchOptionalManagementJSON(path: "/v0/management/routing/strategy")
        async let forcePrefixTask = fetchOptionalManagementJSON(path: "/v0/management/force-model-prefix")

        let authResult = try await authTask
        let authFiles = authResult.files
        let routingAuthFiles = authFiles.filter { !$0.disabled }
        let downloadableRoutingAuthFiles = routingAuthFiles.filter {
            authResult.details[$0.id]?.runtimeOnly != true
        }
        async let accountOverridesTask = fetchOAuthAccountRoutingOverrides(downloadableRoutingAuthFiles)
        let config = await configTask
        let modelPool = try await modelPoolTask
        let aliasesRoot = await aliasesTask ?? [:]
        let excludedRoot = await excludedTask ?? [:]
        let strategyRoot = await strategyTask ?? [:]
        let forcePrefixRoot = await forcePrefixTask ?? [:]
        let forceModelPrefix = boolValue(forcePrefixRoot["force-model-prefix"]) ?? false
        let accountOverrides = await accountOverridesTask

        let aliases = OAuthModelRoutingParser.aliases(root: aliasesRoot)
        let excluded = OAuthModelRoutingParser.excludedModels(root: excludedRoot)
        var allKeys = Set<String>()
        var authByKey: [String: [AuthFile]] = [:]
        var configByKey: [String: [ConfigChannelAccount]] = [:]
        var routesByKey: [String: [ModelRouteDefinition]] = [:]
        var excludedByKey: [String: [String]] = [:]
        var advertisedByKey: [String: Int] = [:]
        var globalAliasesByKey: [String: [OAuthModelAliasEntry]] = [:]

        for auth in routingAuthFiles {
            let key = Self.canonicalRoutingKey(auth.normalizedProvider)
            authByKey[key, default: []].append(auth)
            allKeys.insert(key)
        }
        for account in config.accounts {
            let key = Self.canonicalRoutingKey(account.auth.normalizedProvider)
            configByKey[key, default: []].append(account)
            allKeys.insert(key)
        }
        for (key, accounts) in configByKey {
            routesByKey[key, default: []].append(contentsOf: ModelRoutingResolver.configRoutes(
                accounts: accounts,
                forceModelPrefix: forceModelPrefix
            ))
        }
        for (rawProvider, entries) in aliases {
            let key = Self.canonicalRoutingKey(rawProvider)
            globalAliasesByKey[key, default: []].append(contentsOf: entries)
            allKeys.insert(key)
        }
        for key in Set(authByKey.keys).union(globalAliasesByKey.keys) {
            routesByKey[key, default: []].append(contentsOf: ModelRoutingResolver.oauthRoutes(
                globalEntries: globalAliasesByKey[key] ?? [],
                auths: authByKey[key] ?? [],
                accountOverrides: accountOverrides,
                forceModelPrefix: forceModelPrefix
            ))
        }
        for (rawProvider, patterns) in excluded {
            let key = Self.canonicalRoutingKey(rawProvider)
            excludedByKey[key, default: []].append(contentsOf: patterns)
            allKeys.insert(key)
        }
        for group in modelPool.providers {
            let key = Self.canonicalRoutingKey(group.provider.key)
            advertisedByKey[key, default: 0] += group.models.count
            allKeys.insert(key)
        }

        let providers = allKeys.compactMap { key -> ProviderRoutingGroup? in
            let auths = authByKey[key] ?? []
            let configs = configByKey[key] ?? []
            let routes = ModelRoutingResolver.deduplicated(routesByKey[key] ?? []).sorted { lhs, rhs in
                let aliasOrder = lhs.publicModelID.localizedCaseInsensitiveCompare(rhs.publicModelID)
                if aliasOrder != .orderedSame { return aliasOrder == .orderedAscending }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            let prefixes = Self.uniqueStrings(
                auths.compactMap {
                    ModelRoutingResolver.effectivePrefix(for: $0, accountOverrides: accountOverrides)
                } + configs.compactMap { $0.auth.prefix }
            )
            let priorities = Array(Set(
                auths.compactMap {
                    ModelRoutingResolver.effectivePriority(for: $0, accountOverrides: accountOverrides)
                } + configs.compactMap { $0.auth.priority }
            )).sorted(by: >)
            let baseURLs = Self.uniqueStrings(configs.compactMap(\.baseURL))
            let proxyURLs = Self.uniqueStrings(
                auths.compactMap {
                    ModelRoutingResolver.effectiveProxyURL(for: $0, accountOverrides: accountOverrides)
                } + configs.compactMap { ModelRoutingResolver.sanitizedEndpoint($0.auth.proxyURL) }
            )
            let notes = Self.uniqueStrings(auths.compactMap {
                ModelRoutingResolver.effectiveNote(for: $0, accountOverrides: accountOverrides)
            })
            let mergedExcludedModels = ModelRoutingResolver.mergedExcludedModels(
                global: excludedByKey[key] ?? [],
                auths: auths,
                accountOverrides: accountOverrides
            )
            return ProviderRoutingGroup(
                provider: ProviderCatalog.info(for: key),
                accountCount: auths.count + configs.count,
                advertisedModelCount: advertisedByKey[key] ?? 0,
                routes: routes,
                excludedModels: mergedExcludedModels,
                prefixes: prefixes,
                priorities: priorities,
                baseURLs: baseURLs,
                proxyURLs: proxyURLs,
                notes: notes,
                officialAPIAccounts: auths.filter {
                    ModelRoutingResolver.effectiveUsingAPI(for: $0, accountOverrides: accountOverrides) == true
                }.count
            )
        }.sorted { lhs, rhs in
            if lhs.provider.priority != rhs.provider.priority {
                return lhs.provider.priority < rhs.provider.priority
            }
            return lhs.provider.displayName.localizedCaseInsensitiveCompare(rhs.provider.displayName) == .orderedAscending
        }

        return ModelRoutingSnapshot(
            strategy: firstString(strategyRoot["strategy"]) ?? "round-robin",
            forceModelPrefix: forceModelPrefix,
            providers: providers,
            failedSections: config.failedSections
        )
    }

    /// Reads the config-based channels (openai-compatibility plus the claude / codex /
    /// gemini / interactions / vertex api-key sections) and synthesizes one account per credential.
    /// Failed sections are reported by name; a 404 (endpoint absent on older servers)
    /// counts as "no such channels".
    public func fetchConfigChannelAccounts() async -> ConfigChannelFetch {
        await withTaskGroup(
            of: (accounts: [ConfigChannelAccount], failedSection: String?).self,
            returning: ConfigChannelFetch.self
        ) { group in
            group.addTask { await self.compatChannelAccounts() }
            for kind in APIKeyChannelKind.allCases {
                group.addTask { await self.apiKeyChannelAccounts(kind: kind) }
            }
            var accounts: [ConfigChannelAccount] = []
            var failedSections: [String] = []
            for await value in group {
                accounts.append(contentsOf: value.accounts)
                if let failed = value.failedSection {
                    failedSections.append(failed)
                }
            }
            return ConfigChannelFetch(accounts: accounts, failedSections: failedSections.sorted())
        }
    }

    private func compatChannelAccounts() async -> (accounts: [ConfigChannelAccount], failedSection: String?) {
        do {
            let root = try await fetchManagementJSON(path: "/v0/management/openai-compatibility")
            return (ConfigChannelSynthesizer.compatAccounts(root: root), nil)
        } catch {
            return ([], Self.isNotFound(error) ? nil : "openai-compatibility")
        }
    }

    private func apiKeyChannelAccounts(kind: APIKeyChannelKind) async -> (accounts: [ConfigChannelAccount], failedSection: String?) {
        do {
            let root = try await fetchManagementJSON(path: kind.managementPath)
            let entries = ConfigChannelSynthesizer.apiKeyEntries(kind: kind, root: root)
            guard !entries.isEmpty else { return ([], nil) }
            var staticModels: [CPAModelDefinition] = []
            if entries.contains(where: { $0.overrideModelIDs.isEmpty }) {
                staticModels = (try? await fetchStaticModelDefinitions(channel: kind.definitionsChannel)) ?? []
            }
            return (ConfigChannelSynthesizer.apiKeyAccounts(kind: kind, entries: entries, staticModels: staticModels), nil)
        } catch {
            return ([], Self.isNotFound(error) ? nil : kind.rawValue)
        }
    }

    /// Static default models for a channel (`GET /v0/management/model-definitions/:channel`),
    /// used for api-key entries that don't override `models`.
    public func fetchStaticModelDefinitions(channel: String) async throws -> [CPAModelDefinition] {
        let url = try Self.managementURL(baseURL: settings.baseURL, path: "/v0/management/model-definitions/\(channel)")
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        applyManagementHeaders(to: &request)
        let data = try await data(for: request)
        return try JSONDecoder().decode(ModelsResponse.self, from: data).models
    }

    private func fetchManagementJSON(path: String) async throws -> [String: Any] {
        let url = try Self.managementURL(baseURL: settings.baseURL, path: path)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        applyManagementHeaders(to: &request)
        let data = try await data(for: request)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PoolClientError.invalidResponse("\(path) did not return a JSON object")
        }
        return object
    }

    private func fetchOptionalManagementJSON(path: String) async -> [String: Any]? {
        try? await fetchManagementJSON(path: path)
    }

    private static func canonicalRoutingKey(_ raw: String) -> String {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        switch normalized {
        case "anthropic": return "claude"
        case "grok", "x-ai": return "xai"
        default: return ProviderCatalog.info(for: normalized).key
        }
    }

    private static func uniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return trimmed
        }
    }

    /// Downloads only route metadata for file-backed OAuth accounts. Each raw
    /// payload is parsed and discarded inside its task; failures are intentionally
    /// omitted so callers fall back to provider-global routing configuration.
    private func fetchOAuthAccountRoutingOverrides(
        _ authFiles: [AuthFile]
    ) async -> [String: OAuthAccountRoutingOverride] {
        let candidates = authFiles.filter { Self.downloadableAuthJSONName(for: $0) != nil }
        guard !candidates.isEmpty else { return [:] }

        var overrides: [String: OAuthAccountRoutingOverride] = [:]
        let batchSize = 8
        var start = 0
        while start < candidates.count {
            let batch = Array(candidates[start..<Swift.min(start + batchSize, candidates.count)])
            let results = await withTaskGroup(
                of: (String, OAuthAccountRoutingOverride?).self,
                returning: [(String, OAuthAccountRoutingOverride?)].self
            ) { group in
                for auth in batch {
                    group.addTask {
                        (auth.id, await self.fetchOAuthAccountRoutingOverride(for: auth))
                    }
                }
                var values: [(String, OAuthAccountRoutingOverride?)] = []
                for await value in group {
                    values.append(value)
                }
                return values
            }
            for (authID, override) in results {
                if let override {
                    overrides[authID] = override
                }
            }
            start += batchSize
        }
        return overrides
    }

    private func fetchOAuthAccountRoutingOverride(
        for auth: AuthFile
    ) async -> OAuthAccountRoutingOverride? {
        guard let name = Self.downloadableAuthJSONName(for: auth) else { return nil }
        do {
            let url = try Self.authFileDownloadURL(baseURL: settings.baseURL, name: name)
            var request = URLRequest(url: url, timeoutInterval: timeout)
            request.httpMethod = "GET"
            applyManagementHeaders(to: &request)
            let payload = try await data(for: request)
            return OAuthAuthFileRoutingParser.parse(
                data: payload,
                provider: Self.canonicalRoutingKey(auth.normalizedProvider)
            )
        } catch {
            return nil
        }
    }

    private static func downloadableAuthJSONName(for auth: AuthFile) -> String? {
        let name = auth.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.lowercased().hasSuffix(".json"),
              !name.contains("/"),
              !name.contains("\\")
        else {
            return nil
        }
        return name
    }

    private static func authFileDownloadURL(baseURL: String, name: String) throws -> URL {
        var components = URLComponents(
            url: try managementURL(baseURL: baseURL, path: "/v0/management/auth-files/download"),
            resolvingAgainstBaseURL: false
        )
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        guard let encodedName = name.addingPercentEncoding(withAllowedCharacters: unreserved) else {
            throw PoolClientError.invalidResponse("invalid auth-file download name")
        }
        components?.percentEncodedQuery = "name=\(encodedName)"
        guard let url = components?.url else {
            throw PoolClientError.invalidResponse("invalid auth-file download URL")
        }
        return url
    }

    private static func isNotFound(_ error: Error) -> Bool {
        if case let PoolClientError.httpStatus(status, _) = error {
            return status == 404
        }
        return false
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

        let usagePayload = APICallRequest(
            authIndex: auth.authIndex,
            method: "GET",
            url: "https://chatgpt.com/backend-api/wham/usage",
            header: headers,
            data: nil
        )
        var resetHeaders = headers
        resetHeaders["OpenAI-Beta"] = "codex-1"
        resetHeaders["Originator"] = "Codex Desktop"
        let resetPayload = APICallRequest(
            authIndex: auth.authIndex,
            method: "GET",
            url: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits",
            header: resetHeaders,
            data: nil
        )

        async let usageTask = fetchAPICallEnvelope(payload: usagePayload)
        async let resetTask = fetchOptionalAPICallEnvelope(payload: resetPayload)
        let usageEnvelope = try await usageTask
        let resetEnvelope = await resetTask

        guard (200..<300).contains(usageEnvelope.statusCode) else {
            throw PoolClientError.httpStatus(usageEnvelope.statusCode, usageEnvelope.body)
        }
        var usageObject = Self.jsonObject(from: usageEnvelope.body) ?? [:]
        if let resetEnvelope,
           (200..<300).contains(resetEnvelope.statusCode),
           let resetObject = Self.jsonObject(from: resetEnvelope.body) {
            usageObject["rate_limit_reset_credits"] = resetObject
        }
        if let snapshot = UsageParser.parse(try jsonString(usageObject)) {
            return snapshot
        }
        throw PoolClientError.invalidResponse("empty Codex quota")
    }

    private func fetchAntigravityUsage(auth: AuthFile) async throws -> UsageSnapshot {
        guard let projectID = await antigravityProjectID(for: auth) else {
            throw PoolClientError.invalidResponse("missing Antigravity project_id")
        }
        let payloadBody = try jsonString(["project": projectID])
        let headers = [
            "Authorization": "Bearer $TOKEN$",
            "Content-Type": "application/json",
            "User-Agent": Self.antigravityUserAgent
        ]

        async let subscriptionTask = fetchAntigravitySubscription(auth: auth, headers: headers)
        var lastError: Error?
        var emptySnapshot: UsageSnapshot?
        var sawSuccessfulResponse = false

        for url in Self.antigravityQuotaURLs {
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
                let quotaObject = Self.jsonObject(from: envelope.body) ?? [:]
                let subscriptionObject = await subscriptionTask ?? [:]
                let combined: [String: Any] = [
                    "_provider": "antigravity",
                    "quota": quotaObject,
                    "subscription": subscriptionObject
                ]
                if let snapshot = UsageParser.parse(try jsonString(combined)) {
                    if snapshot.hasQuotaSignal {
                        return snapshot
                    }
                    emptySnapshot = snapshot
                } else {
                    lastError = PoolClientError.invalidResponse("empty Antigravity quota summary")
                }
            } catch {
                lastError = error
            }
        }

        // Older CLIProxyAPI deployments and cached management panels still use the
        // model-map endpoint. Keep it as a compatibility fallback after the current
        // summary endpoint has been attempted.
        for url in Self.antigravityLegacyModelURLs {
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
                if let snapshot = UsageParser.parse(envelope.body), snapshot.hasQuotaSignal {
                    return snapshot
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

    private func fetchAntigravitySubscription(
        auth: AuthFile,
        headers: [String: String]
    ) async -> [String: Any]? {
        let body = try? jsonString(["metadata": ["ideType": "ANTIGRAVITY"]])
        let payload = APICallRequest(
            authIndex: auth.authIndex,
            method: "POST",
            url: Self.antigravitySubscriptionURL,
            header: headers,
            data: body
        )
        guard let envelope = try? await fetchAPICallEnvelope(payload: payload),
              (200..<300).contains(envelope.statusCode)
        else {
            return nil
        }
        guard let root = Self.jsonObject(from: envelope.body) else { return nil }
        let paidTier = firstDictionary(root["paidTier"], root["paid_tier"])
        let currentTier = firstDictionary(root["currentTier"], root["current_tier"])
        let tier = (firstString(paidTier?["id"]) == nil ? currentTier : paidTier) ?? [:]
        let tierID = firstString(tier["id"])
        let plan: String
        switch tierID?.lowercased() {
        case "free-tier": plan = "free"
        case "g1-pro-tier": plan = "pro"
        case "g1-ultra-tier": plan = "ultra"
        case "g1-ultra-lite-tier": plan = "ultra-lite"
        default: plan = "unknown"
        }
        var normalized: [String: Any] = ["plan": plan]
        if let tierID { normalized["tierId"] = tierID }
        if let tierName = firstString(tier["name"]) { normalized["tierName"] = tierName }
        if let paidTier { normalized["paidTier"] = paidTier }
        return normalized
    }

    private func fetchClaudeUsage(auth: AuthFile) async throws -> UsageSnapshot {
        let headers = [
            "Authorization": "Bearer $TOKEN$",
            "Content-Type": "application/json",
            "anthropic-beta": "oauth-2025-04-20"
        ]
        let usagePayload = APICallRequest(
            authIndex: auth.authIndex,
            method: "GET",
            url: "https://api.anthropic.com/api/oauth/usage",
            header: headers,
            data: nil
        )
        let profilePayload = APICallRequest(
            authIndex: auth.authIndex,
            method: "GET",
            url: "https://api.anthropic.com/api/oauth/profile",
            header: headers,
            data: nil
        )
        async let usageTask = fetchAPICallEnvelope(payload: usagePayload)
        async let profileTask = fetchOptionalAPICallEnvelope(payload: profilePayload)
        let usageEnvelope = try await usageTask
        let profileEnvelope = await profileTask
        guard (200..<300).contains(usageEnvelope.statusCode) else {
            throw PoolClientError.httpStatus(usageEnvelope.statusCode, usageEnvelope.body)
        }

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
        var headers = [
            "Authorization": "Bearer $TOKEN$",
            "x-xai-token-auth": "xai-grok-cli",
            "x-grok-client-version": Self.xaiClientVersion,
            "Accept": "*/*",
            "User-Agent": "grok-pager/\(Self.xaiClientVersion) grok-shell/\(Self.xaiClientVersion) (macos; aarch64)"
        ]
        if let userID = await xaiUserID(for: auth) {
            headers["x-userid"] = userID
        }

        let weeklyPayload = APICallRequest(
            authIndex: auth.authIndex,
            method: "GET",
            url: Self.xaiBillingWeeklyURL,
            header: headers,
            data: nil
        )
        let monthlyPayload = APICallRequest(
            authIndex: auth.authIndex,
            method: "GET",
            url: Self.xaiBillingMonthlyURL,
            header: headers,
            data: nil
        )
        async let weeklyTask = fetchOptionalAPICallEnvelope(payload: weeklyPayload)
        async let monthlyTask = fetchOptionalAPICallEnvelope(payload: monthlyPayload)
        let weeklyEnvelope = await weeklyTask
        let monthlyEnvelope = await monthlyTask

        let weeklyObject = weeklyEnvelope.flatMap { envelope in
            (200..<300).contains(envelope.statusCode) ? Self.jsonObject(from: envelope.body) : nil
        }
        let monthlyObject = monthlyEnvelope.flatMap { envelope in
            (200..<300).contains(envelope.statusCode) ? Self.jsonObject(from: envelope.body) : nil
        }
        guard weeklyObject != nil || monthlyObject != nil else {
            let failed = weeklyEnvelope ?? monthlyEnvelope
            throw PoolClientError.httpStatus(failed?.statusCode ?? 502, failed?.body ?? "empty Grok billing response")
        }
        let combined: [String: Any] = [
            "_provider": "xai",
            "weekly": weeklyObject ?? [:],
            "monthly": monthlyObject ?? [:]
        ]
        if let snapshot = UsageParser.parse(try jsonString(combined)), snapshot.hasQuotaSignal {
            return snapshot
        }
        throw PoolClientError.invalidResponse("empty Grok quota")
    }

    private func fetchOptionalAPICallEnvelope(payload: APICallRequest) async -> APICallEnvelope? {
        try? await fetchAPICallEnvelope(payload: payload)
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

    private func antigravityProjectID(for auth: AuthFile) async -> String? {
        if let projectID = auth.projectID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !projectID.isEmpty {
            return projectID
        }
        if let body = try? await downloadAuthFile(named: auth.name),
           let projectID = Self.projectID(fromAuthFileBody: body) {
            return projectID
        }
        return nil
    }

    private func xaiUserID(for auth: AuthFile) async -> String? {
        guard let body = try? await downloadAuthFile(named: auth.name),
              let data = body.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return firstNonEmpty(
            firstString(root["sub"]),
            firstString(root["subject"]),
            firstString(root["user_id"]),
            firstString(root["userId"]),
            firstString(nested(root, "oauth", "sub")),
            firstString(nested(root, "user", "sub")),
            firstString(nested(root, "user", "id"))
        )
    }

    private func downloadAuthFile(named name: String) async throws -> String {
        let url = try Self.authFileDownloadURL(baseURL: settings.baseURL, name: name)
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
// token exchange and persistence; the client polls every flow and only relays callbacks for
// redirect-based providers.
public extension CLIProxyAPIClient {
    /// Requests an authorization URL and opaque session state for the given provider.
    /// Note: `is_webui` is intentionally omitted — the server would otherwise spin up its own
    /// loopback forwarder. Redirect providers are completed by a manually pasted callback URL,
    /// while device providers are completed by server-side polling.
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
        return OAuthAuthURL(
            url: authURL,
            state: firstString(object["state"]) ?? "",
            flow: firstString(object["flow"]),
            userCode: firstString(firstValue(object["user_code"], object["userCode"])),
            expiresIn: intValue(firstValue(object["expires_in"], object["expiresIn"]))
        )
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
