import Foundation

/// Compact provider-level model routing information for the menu bar UI.
public struct ProviderRoutingGroup: Identifiable, Equatable, Sendable {
    public let provider: ProviderInfo
    public let accountCount: Int
    public let advertisedModelCount: Int
    public let routes: [ModelRouteDefinition]
    public let excludedModels: [String]
    public let prefixes: [String]
    public let priorities: [Int]
    public let baseURLs: [String]
    /// Display-safe outbound proxy endpoints, kept separate from upstream Base URLs.
    public let proxyURLs: [String]
    public let notes: [String]
    public let officialAPIAccounts: Int

    public var id: String { provider.key }

    public init(
        provider: ProviderInfo,
        accountCount: Int,
        advertisedModelCount: Int,
        routes: [ModelRouteDefinition],
        excludedModels: [String],
        prefixes: [String],
        priorities: [Int],
        baseURLs: [String],
        proxyURLs: [String],
        notes: [String],
        officialAPIAccounts: Int
    ) {
        self.provider = provider
        self.accountCount = accountCount
        self.advertisedModelCount = advertisedModelCount
        self.routes = routes
        self.excludedModels = excludedModels
        self.prefixes = prefixes
        self.priorities = priorities
        self.baseURLs = baseURLs
        self.proxyURLs = proxyURLs
        self.notes = notes
        self.officialAPIAccounts = officialAPIAccounts
    }

    public var distinctClientModelCount: Int {
        Set(routes.map { $0.publicModelID.lowercased() }).count
    }
}

public struct ModelRoutingSnapshot: Equatable, Sendable {
    public let strategy: String
    public let forceModelPrefix: Bool
    public let providers: [ProviderRoutingGroup]
    public let failedSections: [String]
    public let fetchedAt: Date

    public init(
        strategy: String,
        forceModelPrefix: Bool,
        providers: [ProviderRoutingGroup],
        failedSections: [String] = [],
        fetchedAt: Date = Date()
    ) {
        self.strategy = strategy
        self.forceModelPrefix = forceModelPrefix
        self.providers = providers
        self.failedSections = failedSections
        self.fetchedAt = fetchedAt
    }

    public var routeCount: Int { providers.reduce(0) { $0 + $1.routes.count } }
    public var accountCount: Int { providers.reduce(0) { $0 + $1.accountCount } }
}

/// Resolves canonical model mappings into the concrete client IDs exposed by
/// CLIProxyAPI. Keeping this logic pure makes prefix/fork behavior testable
/// without a live management server.
public enum ModelRoutingResolver {
    /// Expands one canonical mapping according to the global prefix policy.
    ///
    /// - no configured prefix: the alias is exposed once;
    /// - prefix + force=false: both `alias` and `prefix/alias` are exposed;
    /// - prefix + force=true: only `prefix/alias` is exposed.
    public static func expand(
        _ route: ModelRouteDefinition,
        forceModelPrefix: Bool
    ) -> [ModelRouteDefinition] {
        guard let prefix = firstNonEmpty(route.prefix) else {
            return [route.resolvingPublicModelID(route.alias)]
        }

        let prefixedID = "\(prefix)/\(route.alias)"
        if forceModelPrefix {
            return [route.resolvingPublicModelID(prefixedID)]
        }
        return [
            route.resolvingPublicModelID(route.alias),
            route.resolvingPublicModelID(prefixedID)
        ]
    }

    /// Expands all config-channel mappings and collapses identical mappings that
    /// are repeated only because a channel has multiple credentials. Distinct
    /// upstream names sharing one client alias remain separate routing targets.
    public static func configRoutes(
        accounts: [ConfigChannelAccount],
        forceModelPrefix: Bool
    ) -> [ModelRouteDefinition] {
        deduplicated(accounts.flatMap { account in
            account.routes.flatMap { expand($0, forceModelPrefix: forceModelPrefix) }
        })
    }

    /// Applies global OAuth aliases to every distinct prefix shape used by the
    /// provider's corresponding auth accounts. `fork=true` additionally emits an
    /// identity mapping for the original model, matching server registration.
    public static func oauthRoutes(
        entries: [OAuthModelAliasEntry],
        auths: [AuthFile],
        forceModelPrefix: Bool
    ) -> [ModelRouteDefinition] {
        oauthRoutes(
            globalEntries: entries,
            auths: auths,
            accountOverrides: [:],
            forceModelPrefix: forceModelPrefix
        )
    }

    /// Resolves global aliases together with account-local auth JSON overrides.
    /// Account aliases are considered first, then global aliases are appended
    /// while deduplicating by client alias (case-insensitive). Thus a local alias
    /// overrides the same global alias while unrelated global aliases remain.
    public static func oauthRoutes(
        globalEntries: [OAuthModelAliasEntry],
        auths: [AuthFile],
        accountOverrides: [String: OAuthAccountRoutingOverride],
        forceModelPrefix: Bool
    ) -> [ModelRouteDefinition] {
        guard !auths.isEmpty else {
            return deduplicated(globalEntries.flatMap {
                $0.routeDefinitions(prefix: nil, forceModelPrefix: forceModelPrefix)
            })
        }

        let routes = auths.flatMap { auth -> [ModelRouteDefinition] in
            let accountAliases = accountOverrides[auth.id]?.aliases ?? []
            let effectiveAliases = mergedOAuthAliases(account: accountAliases, global: globalEntries)
            return effectiveAliases.flatMap { entry in
                entry.routeDefinitions(
                    prefix: effectivePrefix(for: auth, accountOverrides: accountOverrides),
                    forceModelPrefix: forceModelPrefix
                )
            }
        }
        return deduplicated(routes)
    }

    /// Flattens provider-global and account-local exclusions for the provider
    /// card. Matching remains account-specific in the server; the compact menu
    /// representation shows the union without duplicate patterns.
    public static func mergedExcludedModels(
        global: [String],
        auths: [AuthFile],
        accountOverrides: [String: OAuthAccountRoutingOverride]
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        let values = global + auths.flatMap { accountOverrides[$0.id]?.excludedModels ?? [] }
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    public static func effectivePrefix(
        for auth: AuthFile,
        accountOverrides: [String: OAuthAccountRoutingOverride]
    ) -> String? {
        firstNonEmpty(accountOverrides[auth.id]?.prefix, auth.prefix)
    }

    public static func effectivePriority(
        for auth: AuthFile,
        accountOverrides: [String: OAuthAccountRoutingOverride]
    ) -> Int? {
        accountOverrides[auth.id]?.priority ?? auth.priority
    }

    public static func effectiveUsingAPI(
        for auth: AuthFile,
        accountOverrides: [String: OAuthAccountRoutingOverride]
    ) -> Bool? {
        accountOverrides[auth.id]?.usingAPI ?? auth.usingAPI
    }

    public static func effectiveProxyURL(
        for auth: AuthFile,
        accountOverrides: [String: OAuthAccountRoutingOverride]
    ) -> String? {
        sanitizedEndpoint(accountOverrides[auth.id]?.proxyURL ?? auth.proxyURL)
    }

    public static func effectiveNote(
        for auth: AuthFile,
        accountOverrides: [String: OAuthAccountRoutingOverride]
    ) -> String? {
        firstNonEmpty(accountOverrides[auth.id]?.note, auth.note)
    }

    /// Produces a display-only endpoint. Userinfo, query parameters, and fragments
    /// are removed so routing snapshots never retain proxy credentials or tokens.
    public static func sanitizedEndpoint(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let explicitScheme = trimmed.range(
            of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#,
            options: .regularExpression
        ) != nil
        let schemeRelative = !explicitScheme && trimmed.hasPrefix("//")
        let candidate: String
        if explicitScheme {
            candidate = trimmed
        } else if schemeRelative {
            candidate = "https:\(trimmed)"
        } else {
            candidate = "https://\(trimmed)"
        }

        guard var components = URLComponents(string: candidate),
              let host = components.host,
              !host.isEmpty
        else {
            return "已配置（地址已隐藏）"
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        guard let sanitized = components.string else {
            return "已配置（地址已隐藏）"
        }
        if explicitScheme { return sanitized }
        if schemeRelative { return String(sanitized.dropFirst("https:".count)) }
        return String(sanitized.dropFirst("https://".count))
    }

    /// Removes repeated semantic routes while preserving stable server/config
    /// order. The configured prefix itself is deliberately not part of the key:
    /// two credentials that both expose the same public ID to the same upstream
    /// are account redundancy, not a larger upstream routing pool.
    public static func deduplicated(_ routes: [ModelRouteDefinition]) -> [ModelRouteDefinition] {
        var seen = Set<String>()
        return routes.filter { route in
            seen.insert(semanticKey(route)).inserted
        }
    }

    private static func mergedOAuthAliases(
        account: [OAuthModelAliasEntry],
        global: [OAuthModelAliasEntry]
    ) -> [OAuthModelAliasEntry] {
        var seenAliases = Set<String>()
        var result: [OAuthModelAliasEntry] = []
        for entry in account + global {
            let alias = entry.alias.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = alias.lowercased()
            guard !key.isEmpty, seenAliases.insert(key).inserted else { continue }
            result.append(entry)
        }
        return result
    }

    private static func semanticKey(_ route: ModelRouteDefinition) -> String {
        [
            route.publicModelID.lowercased(),
            route.upstreamModelName.lowercased(),
            route.fork ? "fork" : "replace",
            route.forceMapping ? "force" : "passthrough"
        ]
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
    }
}
