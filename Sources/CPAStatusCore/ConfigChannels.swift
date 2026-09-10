import Foundation

/// The config.yaml api-key sections that serve models but never appear in
/// `/v0/management/auth-files` (the server lists file/OAuth credentials only).
public enum APIKeyChannelKind: String, CaseIterable, Sendable {
    case codex = "codex-api-key"
    case claude = "claude-api-key"
    case gemini = "gemini-api-key"
    case interactions = "interactions-api-key"
    case vertex = "vertex-api-key"

    var modelType: String {
        self == .codex ? "openai" : definitionsChannel
    }

    var modelOwner: String {
        switch self {
        case .codex: return "openai"
        case .claude: return "anthropic"
        case .gemini, .interactions, .vertex: return "google"
        }
    }

    public var managementPath: String { "/v0/management/\(rawValue)" }

    /// Channel key for `/v0/management/model-definitions/:channel`, used when an
    /// entry has no per-key `models` override (the server then serves the channel's
    /// static default models).
    public var definitionsChannel: String {
        switch self {
        case .codex: return "codex"
        case .claude: return "claude"
        case .gemini, .interactions: return "gemini"
        case .vertex: return "vertex"
        }
    }
}

/// One api-key entry parsed from a config section.
public struct APIKeyChannelEntry: Equatable, Sendable {
    /// Client-facing model IDs from the entry's `models` override (alias, falling
    /// back to name). Empty means "serve the channel's static default models".
    public let overrideModelIDs: [String]
    /// Full upstream-to-alias mappings. Unlike `overrideModelIDs`, repeated
    /// aliases are intentionally retained because they form a routing pool.
    public let overrideRoutes: [ModelRouteDefinition]
    public let overrideModels: [CPAModelDefinition]
    /// `excluded-models` patterns (may contain `*` wildcards).
    public let excludedPatterns: [String]
    /// Optional model prefix; when set the server also registers `prefix/<id>`.
    public let prefix: String?
    /// Masked form of the entry's api-key (never the full secret).
    public let maskedKey: String?
    /// Optional per-entry base-url override.
    public let baseURL: String?
    /// Optional routing priority; higher values are selected first by the proxy.
    public let priority: Int?
    /// Optional per-entry outbound proxy override.
    public let proxyURL: String?

    public init(
        overrideModelIDs: [String],
        excludedPatterns: [String],
        prefix: String?,
        maskedKey: String? = nil,
        baseURL: String? = nil,
        overrideRoutes: [ModelRouteDefinition] = [],
        overrideModels: [CPAModelDefinition] = [],
        priority: Int? = nil,
        proxyURL: String? = nil
    ) {
        self.overrideModelIDs = overrideModelIDs
        self.overrideRoutes = overrideRoutes
        self.overrideModels = overrideModels
        self.excludedPatterns = excludedPatterns
        self.prefix = prefix
        self.maskedKey = maskedKey
        self.baseURL = baseURL
        self.priority = priority
        self.proxyURL = proxyURL
    }
}

/// One credential of a config-based channel, shaped for both the dashboard
/// (synthesized `AuthFile` + channel metadata) and the model pool (`models`).
public struct ConfigChannelAccount: Equatable, Sendable {
    public let auth: AuthFile
    public let models: [CPAModelDefinition]
    public let baseURL: String?
    /// Complete mapping list for routing display. This is deliberately not
    /// deduplicated by alias, unlike the public `models` list.
    public let routes: [ModelRouteDefinition]

    public init(
        auth: AuthFile,
        models: [CPAModelDefinition],
        baseURL: String?,
        routes: [ModelRouteDefinition] = []
    ) {
        self.auth = auth
        self.models = models
        self.baseURL = baseURL
        self.routes = routes
    }
}

/// Result of reading every config-channel section: the synthesized credentials
/// plus the names of sections whose fetch failed (results may be incomplete).
public struct ConfigChannelFetch: Equatable, Sendable {
    public let accounts: [ConfigChannelAccount]
    public let failedSections: [String]

    public init(accounts: [ConfigChannelAccount], failedSections: [String]) {
        self.accounts = accounts
        self.failedSections = failedSections
    }
}

/// One global OAuth model alias from `/v0/management/oauth-model-alias`.
/// Entries are kept in server order and are never deduplicated by alias.
public struct OAuthModelAliasEntry: Identifiable, Equatable, Sendable {
    public let provider: String
    public let name: String
    public let alias: String
    public let fork: Bool
    public let forceMapping: Bool

    public init(
        provider: String,
        name: String,
        alias: String,
        fork: Bool = false,
        forceMapping: Bool = false
    ) {
        self.provider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fork = fork
        self.forceMapping = forceMapping
    }

    public var id: String {
        routeDefinition().id
    }

    public func routeDefinition(prefix: String? = nil) -> ModelRouteDefinition {
        ModelRouteDefinition(
            name: name,
            alias: alias,
            prefix: prefix,
            source: provider,
            fork: fork,
            forceMapping: forceMapping
        )
    }

    /// Concrete routes registered for one OAuth account prefix. A forked alias
    /// keeps the original model in addition to exposing the alias; both routes
    /// follow the same global prefix policy.
    public func routeDefinitions(
        prefix: String? = nil,
        forceModelPrefix: Bool
    ) -> [ModelRouteDefinition] {
        var canonical = [routeDefinition(prefix: prefix)]
        if fork, name.caseInsensitiveCompare(alias) != .orderedSame {
            canonical.append(ModelRouteDefinition(
                name: name,
                alias: name,
                prefix: prefix,
                source: provider,
                fork: true
            ))
        }
        return canonical.flatMap {
            ModelRoutingResolver.expand($0, forceModelPrefix: forceModelPrefix)
        }
    }
}

/// The only data retained from a downloaded OAuth auth JSON file. Access tokens,
/// refresh tokens, identity claims, and every unrelated field are intentionally
/// absent from this type and never leave the parser.
public struct OAuthAccountRoutingOverride: Equatable, Sendable {
    public let aliases: [OAuthModelAliasEntry]
    public let excludedModels: [String]
    public let prefix: String?
    public let priority: Int?
    public let usingAPI: Bool?
    /// Sanitized display-only outbound proxy; credentials, query, and fragment
    /// are removed before this value leaves the auth-file parser.
    public let proxyURL: String?
    public let note: String?

    public init(
        aliases: [OAuthModelAliasEntry],
        excludedModels: [String],
        prefix: String? = nil,
        priority: Int? = nil,
        usingAPI: Bool? = nil,
        proxyURL: String? = nil,
        note: String? = nil
    ) {
        self.aliases = aliases
        self.excludedModels = excludedModels
        self.prefix = firstNonEmpty(prefix)
        self.priority = priority
        self.usingAPI = usingAPI
        self.proxyURL = ModelRoutingResolver.sanitizedEndpoint(proxyURL)
        self.note = firstNonEmpty(note)
    }
}

/// Selectively parses account-local routing metadata from auth JSON bytes. The
/// raw object is scoped to this call and the returned value contains no secret or
/// identity fields from the credential file.
public enum OAuthAuthFileRoutingParser {
    public static func parse(data: Data, provider: String) -> OAuthAccountRoutingOverride? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let rawAliases = firstArray(root["model_aliases"], root["model-aliases"]) ?? []
        var aliases: [OAuthModelAliasEntry] = []
        var seenAliases = Set<String>()
        for raw in rawAliases {
            guard let item = raw as? [String: Any],
                  let name = firstString(item["name"]),
                  let alias = firstString(item["alias"]),
                  name.caseInsensitiveCompare(alias) != .orderedSame
            else {
                continue
            }
            guard seenAliases.insert(alias.lowercased()).inserted else {
                continue
            }
            aliases.append(OAuthModelAliasEntry(
                provider: provider,
                name: name,
                alias: alias,
                fork: boolValue(item["fork"]) ?? false,
                forceMapping: boolValue(
                    firstValue(item["force-mapping"], item["force_mapping"], item["forceMapping"])
                ) ?? false
            ))
        }

        let rawExcluded = firstArray(root["excluded_models"], root["excluded-models"]) ?? []
        var excludedModels: [String] = []
        var seenExcluded = Set<String>()
        for raw in rawExcluded {
            guard let value = firstString(raw) else { continue }
            let key = value.lowercased()
            guard seenExcluded.insert(key).inserted else { continue }
            excludedModels.append(value)
        }

        return OAuthAccountRoutingOverride(
            aliases: aliases,
            excludedModels: excludedModels,
            prefix: firstString(root["prefix"]),
            priority: integerValue(root["priority"]),
            usingAPI: boolValue(firstValue(root["using_api"], root["using-api"], root["usingAPI"])),
            proxyURL: firstString(root["proxy_url"], root["proxy-url"], root["proxyURL"]),
            note: firstString(root["note"])
        )
    }
}

/// Pure, side-effect-free parsing for the two OAuth routing management payloads.
public enum OAuthModelRoutingParser {
    public static func aliases(root: [String: Any]) -> [String: [OAuthModelAliasEntry]] {
        guard let providers = firstDictionary(
            root["oauth-model-alias"],
            root["oauth_model_alias"],
            root["oauthModelAlias"]
        ) else {
            return [:]
        }

        var parsed: [String: [OAuthModelAliasEntry]] = [:]
        for (rawProvider, value) in providers {
            guard let provider = firstNonEmpty(rawProvider), let items = value as? [Any] else { continue }
            let entries = items.compactMap { raw -> OAuthModelAliasEntry? in
                guard let dict = raw as? [String: Any],
                      let name = firstString(dict["name"]),
                      let alias = firstString(dict["alias"])
                else { return nil }
                return OAuthModelAliasEntry(
                    provider: provider,
                    name: name,
                    alias: alias,
                    fork: boolValue(dict["fork"]) ?? false,
                    forceMapping: boolValue(
                        firstValue(dict["force-mapping"], dict["force_mapping"], dict["forceMapping"])
                    ) ?? false
                )
            }
            if !entries.isEmpty {
                parsed[provider] = entries
            }
        }
        return parsed
    }

    public static func excludedModels(root: [String: Any]) -> [String: [String]] {
        guard let providers = firstDictionary(
            root["oauth-excluded-models"],
            root["oauth_excluded_models"],
            root["oauthExcludedModels"]
        ) else {
            return [:]
        }

        var parsed: [String: [String]] = [:]
        for (rawProvider, value) in providers {
            guard let provider = firstNonEmpty(rawProvider), let items = value as? [Any] else { continue }
            let patterns = items.compactMap { firstString($0) }
            if !patterns.isEmpty {
                parsed[provider] = patterns
            }
        }
        return parsed
    }
}

/// True for provider keys that represent config.yaml channels (key credentials)
/// rather than file/OAuth accounts.
public func isConfigChannelKey(_ providerKey: String) -> Bool {
    let normalized = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized.hasSuffix("-api-key") ||
        normalized.hasPrefix("openai-compatible-") ||
        normalized == "openai-compatibility"
}

/// Masks a secret for display: keeps a short prefix/suffix, hides the middle.
public func maskedSecret(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.count <= 4 {
        return trimmed
    }
    if trimmed.count <= 12 {
        return String(trimmed.prefix(2)) + "••••" + String(trimmed.suffix(2))
    }
    return String(trimmed.prefix(6)) + "••••••" + String(trimmed.suffix(4))
}

/// Converts management config-section payloads into the same per-credential
/// `AuthModelsResult` shape the account queries produce, so the existing
/// `ModelPoolAggregator` handles config channels for free.
public enum ConfigChannelSynthesizer {
    // MARK: openai-compatibility

    /// Parses `GET /v0/management/openai-compatibility` and returns one account per
    /// api-key entry (or one for keyless channels). Disabled channels are skipped.
    public static func compatAccounts(root: [String: Any]) -> [ConfigChannelAccount] {
        let entries = firstArray(root["openai-compatibility"], root["openai_compatibility"]) ?? []
        var accounts: [ConfigChannelAccount] = []
        for (index, raw) in entries.enumerated() {
            guard let dict = raw as? [String: Any] else { continue }
            if boolValue(dict["disabled"]) == true { continue }

            let name = firstString(dict["name"]) ?? "openai-compatibility"
            let providerKey = compatProviderKey(name: name)
            let prefix = firstString(dict["prefix"])
            let baseURL = firstString(dict["base-url"], dict["baseURL"], dict["baseUrl"])
            let priority = integerValue(dict["priority"])
            let routes = mappingRoutes(
                firstArray(dict["models"]),
                prefix: prefix,
                source: providerKey
            )
            let models = deduplicatedModelDefinitions(
                ConfiguredModelMetadata.definitions(
                    firstArray(dict["models"]),
                    type: "openai-compatibility",
                    ownedBy: name,
                    useUpstreamName: false
                ).flatMap { model in
                    withPrefixVariants(model.id, prefix: prefix).map { model.withID($0) }
                }
            )

            let keyEntries = firstArray(dict["api-key-entries"], dict["apiKeyEntries"]) ?? []
            let credentials: [(maskedKey: String?, proxyURL: String?)] = keyEntries.isEmpty
                ? [(nil, nil)]
                : keyEntries.map { entry in
                    guard let entryDict = entry as? [String: Any] else { return (nil, nil) }
                    return (
                        firstString(entryDict["api-key"], entryDict["apiKey"]).map(maskedSecret),
                        firstString(entryDict["proxy-url"], entryDict["proxyURL"], entryDict["proxyUrl"])
                    )
                }
            for (keyIndex, credential) in credentials.enumerated() {
                let auth = AuthFile(
                    id: "\(providerKey)#\(index)-\(keyIndex)",
                    name: name,
                    provider: providerKey,
                    type: providerKey,
                    label: credential.maskedKey ?? name,
                    prefix: prefix,
                    priority: priority,
                    proxyURL: credential.proxyURL
                )
                accounts.append(
                    ConfigChannelAccount(
                        auth: auth,
                        models: models,
                        baseURL: baseURL,
                        routes: routes
                    )
                )
            }
        }
        return accounts
    }

    /// Model-pool shaped view of `compatAccounts`.
    public static func compatResults(root: [String: Any]) -> [AuthModelsResult] {
        compatAccounts(root: root).map { AuthModelsResult(auth: $0.auth, models: $0.models) }
    }

    /// Mirrors the server's internal provider key for a compat channel
    /// (`util.OpenAICompatibleProviderKey`).
    public static func compatProviderKey(name: String) -> String {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty || normalized == "openai-compatibility" || normalized.hasPrefix("openai-compatible-") {
            return normalized.isEmpty ? "openai-compatibility" : normalized
        }
        return "openai-compatible-" + normalized
    }

    // MARK: api-key sections (claude / codex / gemini / interactions / vertex)

    /// Parses one api-key section payload (`{"<section>": [...]}`)
    public static func apiKeyEntries(kind: APIKeyChannelKind, root: [String: Any]) -> [APIKeyChannelEntry] {
        let rawEntries = firstArray(root[kind.rawValue]) ?? []
        return rawEntries.compactMap { raw in
            guard let dict = raw as? [String: Any] else { return nil }
            let excluded = (firstArray(dict["excluded-models"], dict["excludedModels"]) ?? [])
                .compactMap { firstString($0) }
            let prefix = firstString(dict["prefix"])
            let routes = mappingRoutes(
                firstArray(dict["models"]),
                prefix: prefix,
                source: kind.rawValue
            )
            return APIKeyChannelEntry(
                overrideModelIDs: deduplicatedIDs(routes.map(\.alias)),
                excludedPatterns: excluded,
                prefix: prefix,
                maskedKey: firstString(dict["api-key"], dict["apiKey"]).map(maskedSecret),
                baseURL: firstString(dict["base-url"], dict["baseURL"], dict["baseUrl"]),
                overrideRoutes: routes,
                overrideModels: ConfiguredModelMetadata.definitions(
                    firstArray(dict["models"]),
                    type: kind.modelType,
                    ownedBy: kind.modelOwner,
                    useUpstreamName: true
                ),
                priority: integerValue(dict["priority"]),
                proxyURL: firstString(dict["proxy-url"], dict["proxyURL"], dict["proxyUrl"])
            )
        }
    }

    /// Turns parsed entries into per-credential accounts. Entries without model
    /// overrides serve `staticModels` (the channel defaults) minus their
    /// excluded patterns — the same resolution the server applies when
    /// registering config api-key credentials.
    public static func apiKeyAccounts(
        kind: APIKeyChannelKind,
        entries: [APIKeyChannelEntry],
        staticModels: [CPAModelDefinition]
    ) -> [ConfigChannelAccount] {
        entries.enumerated().map { index, entry in
            let hasOverrides = !entry.overrideRoutes.isEmpty || !entry.overrideModelIDs.isEmpty
            let routes: [ModelRouteDefinition]
            let baseModels: [CPAModelDefinition]
            if hasOverrides {
                let configuredRoutes = entry.overrideRoutes.isEmpty
                    ? entry.overrideModelIDs.map {
                        ModelRouteDefinition(name: $0, alias: $0, prefix: entry.prefix, source: kind.rawValue)
                    }
                    : entry.overrideRoutes
                routes = configuredRoutes.filter { !matchesExcluded($0.alias, patterns: entry.excludedPatterns) }
                let configuredModels = entry.overrideModels.isEmpty
                    ? deduplicatedIDs(configuredRoutes.map(\.alias)).map {
                        CPAModelDefinition(id: $0, ownedBy: kind.definitionsChannel)
                    }
                    : entry.overrideModels
                baseModels = configuredModels.filter { !matchesExcluded($0.id, patterns: entry.excludedPatterns) }
            } else {
                baseModels = staticModels.filter { !matchesExcluded($0.id, patterns: entry.excludedPatterns) }
                routes = baseModels.map {
                    ModelRouteDefinition(name: $0.id, alias: $0.id, prefix: entry.prefix, source: kind.rawValue)
                }
            }
            let models = deduplicatedModelDefinitions(baseModels.flatMap { model in
                withPrefixVariants(model.id, prefix: entry.prefix).map { model.withID($0) }
            })
            let auth = AuthFile(
                id: "\(kind.rawValue)#\(index)",
                name: kind.rawValue,
                provider: kind.rawValue,
                type: kind.rawValue,
                label: entry.maskedKey ?? kind.rawValue,
                prefix: entry.prefix,
                priority: entry.priority,
                proxyURL: entry.proxyURL
            )
            return ConfigChannelAccount(auth: auth, models: models, baseURL: entry.baseURL, routes: routes)
        }
    }

    /// Model-pool shaped view of `apiKeyAccounts`.
    public static func apiKeyResults(
        kind: APIKeyChannelKind,
        entries: [APIKeyChannelEntry],
        staticModels: [CPAModelDefinition]
    ) -> [AuthModelsResult] {
        apiKeyAccounts(kind: kind, entries: entries, staticModels: staticModels)
            .map { AuthModelsResult(auth: $0.auth, models: $0.models) }
    }

    /// A models==nil result so a failed section fetch surfaces in `failedAccounts`.
    public static func failureResult(providerKey: String) -> AuthModelsResult {
        AuthModelsResult(
            auth: AuthFile(id: "\(providerKey)#error", name: providerKey, provider: providerKey, type: providerKey),
            models: nil
        )
    }

    // MARK: helpers

    /// Parses every `models: [{name, alias}]` mapping. Repeated aliases must not
    /// be dropped: multiple upstream names sharing one alias form a routing pool.
    private static func mappingRoutes(
        _ rawMappings: [Any]?,
        prefix: String?,
        source: String
    ) -> [ModelRouteDefinition] {
        var routes: [ModelRouteDefinition] = []
        for raw in rawMappings ?? [] {
            guard let dict = raw as? [String: Any] else { continue }
            guard let name = firstString(dict["name"]) else { continue }
            let alias = firstNonEmpty(firstString(dict["alias"]), name) ?? name
            routes.append(
                ModelRouteDefinition(
                    name: name,
                    alias: alias,
                    prefix: prefix,
                    source: source,
                    fork: boolValue(dict["fork"]) ?? false,
                    forceMapping: boolValue(
                        firstValue(dict["force-mapping"], dict["force_mapping"], dict["forceMapping"])
                    ) ?? false
                )
            )
        }
        return routes
    }

    /// Case-insensitive, order-preserving IDs for the existing public model pool.
    private static func deduplicatedIDs(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var ids: [String] = []
        for value in values {
            let id = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = id.lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            ids.append(id)
        }
        return ids
    }

    private static func deduplicatedModelDefinitions(_ values: [CPAModelDefinition]) -> [CPAModelDefinition] {
        var seen = Set<String>()
        return values.filter { model in
            let key = model.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !key.isEmpty && seen.insert(key).inserted
        }
    }

    /// When a prefix is configured the server registers both `<id>` and
    /// `prefix/<id>` (only the prefixed one under force-model-prefix); list both.
    private static func withPrefixVariants(_ id: String, prefix: String?) -> [String] {
        guard let prefix = firstNonEmpty(prefix) else { return [id] }
        return [id, "\(prefix)/\(id)"]
    }

    /// Case-insensitive `excluded-models` matching with `*` wildcards, mirroring
    /// the server's `matchWildcard` (prefix / suffix / ordered middle segments).
    public static func matchesExcluded(_ modelID: String, patterns: [String]) -> Bool {
        let value = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for rawPattern in patterns {
            let pattern = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if pattern.isEmpty { continue }
            if matchWildcard(pattern: pattern, value: value) {
                return true
            }
        }
        return false
    }

    private static func matchWildcard(pattern: String, value: String) -> Bool {
        if !pattern.contains("*") {
            return pattern == value
        }
        let parts = pattern.components(separatedBy: "*")
        var remaining = Substring(value)
        if let prefix = parts.first, !prefix.isEmpty {
            guard remaining.hasPrefix(prefix) else { return false }
            remaining = remaining.dropFirst(prefix.count)
        }
        if let suffix = parts.last, parts.count > 1, !suffix.isEmpty {
            guard remaining.hasSuffix(suffix) else { return false }
            remaining = remaining.dropLast(suffix.count)
        }
        for segment in parts.dropFirst().dropLast() where !segment.isEmpty {
            guard let range = remaining.range(of: segment) else { return false }
            remaining = remaining[range.upperBound...]
        }
        return true
    }
}
