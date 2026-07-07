import Foundation

/// The four config.yaml api-key sections that serve models but never appear in
/// `/v0/management/auth-files` (the server lists file/OAuth credentials only).
public enum APIKeyChannelKind: String, CaseIterable, Sendable {
    case codex = "codex-api-key"
    case claude = "claude-api-key"
    case gemini = "gemini-api-key"
    case vertex = "vertex-api-key"

    public var managementPath: String { "/v0/management/\(rawValue)" }

    /// Channel key for `/v0/management/model-definitions/:channel`, used when an
    /// entry has no per-key `models` override (the server then serves the channel's
    /// static default models).
    public var definitionsChannel: String {
        switch self {
        case .codex: return "codex"
        case .claude: return "claude"
        case .gemini: return "gemini"
        case .vertex: return "vertex"
        }
    }
}

/// One api-key entry parsed from a config section.
public struct APIKeyChannelEntry: Equatable, Sendable {
    /// Client-facing model IDs from the entry's `models` override (alias, falling
    /// back to name). Empty means "serve the channel's static default models".
    public let overrideModelIDs: [String]
    /// `excluded-models` patterns (may contain `*` wildcards).
    public let excludedPatterns: [String]
    /// Optional model prefix; when set the server also registers `prefix/<id>`.
    public let prefix: String?

    public init(overrideModelIDs: [String], excludedPatterns: [String], prefix: String?) {
        self.overrideModelIDs = overrideModelIDs
        self.excludedPatterns = excludedPatterns
        self.prefix = prefix
    }
}

/// Converts management config-section payloads into the same per-credential
/// `AuthModelsResult` shape the account queries produce, so the existing
/// `ModelPoolAggregator` handles config channels for free.
public enum ConfigChannelSynthesizer {
    // MARK: openai-compatibility

    /// Parses `GET /v0/management/openai-compatibility` and returns one result per
    /// api-key entry (or one for keyless channels). Disabled channels are skipped.
    public static func compatResults(root: [String: Any]) -> [AuthModelsResult] {
        let entries = firstArray(root["openai-compatibility"], root["openai_compatibility"]) ?? []
        var results: [AuthModelsResult] = []
        for (index, raw) in entries.enumerated() {
            guard let dict = raw as? [String: Any] else { continue }
            if boolValue(dict["disabled"]) == true { continue }

            let name = firstString(dict["name"]) ?? "openai-compatibility"
            let providerKey = compatProviderKey(name: name)
            let prefix = firstString(dict["prefix"])
            let modelIDs = mappingModelIDs(firstArray(dict["models"]))
            let models = modelIDs
                .flatMap { withPrefixVariants($0, prefix: prefix) }
                .map { CPAModelDefinition(id: $0, displayName: nil, type: "openai-compatibility", ownedBy: name) }

            let keyCount = max(1, (firstArray(dict["api-key-entries"], dict["apiKeyEntries"]) ?? []).count)
            for keyIndex in 0..<keyCount {
                let auth = AuthFile(
                    id: "\(providerKey)#\(index)-\(keyIndex)",
                    name: name,
                    provider: providerKey,
                    type: providerKey,
                    label: name
                )
                results.append(AuthModelsResult(auth: auth, models: models))
            }
        }
        return results
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

    // MARK: api-key sections (claude / codex / gemini / vertex)

    /// Parses one api-key section payload (`{"<section>": [...]}`)
    public static func apiKeyEntries(kind: APIKeyChannelKind, root: [String: Any]) -> [APIKeyChannelEntry] {
        let rawEntries = firstArray(root[kind.rawValue]) ?? []
        return rawEntries.compactMap { raw in
            guard let dict = raw as? [String: Any] else { return nil }
            let excluded = (firstArray(dict["excluded-models"], dict["excludedModels"]) ?? [])
                .compactMap { firstString($0) }
            return APIKeyChannelEntry(
                overrideModelIDs: mappingModelIDs(firstArray(dict["models"])),
                excludedPatterns: excluded,
                prefix: firstString(dict["prefix"])
            )
        }
    }

    /// Turns parsed entries into per-credential results. Entries without model
    /// overrides serve `staticModels` (the channel defaults) minus their
    /// excluded patterns — the same resolution the server applies when
    /// registering config api-key credentials.
    public static func apiKeyResults(
        kind: APIKeyChannelKind,
        entries: [APIKeyChannelEntry],
        staticModels: [CPAModelDefinition]
    ) -> [AuthModelsResult] {
        entries.enumerated().map { index, entry in
            let base: [CPAModelDefinition]
            if entry.overrideModelIDs.isEmpty {
                base = staticModels.filter { !matchesExcluded($0.id, patterns: entry.excludedPatterns) }
            } else {
                base = entry.overrideModelIDs.map {
                    CPAModelDefinition(id: $0, displayName: nil, type: nil, ownedBy: kind.definitionsChannel)
                }
            }
            let models = base.flatMap { model -> [CPAModelDefinition] in
                withPrefixVariants(model.id, prefix: entry.prefix).map { id in
                    CPAModelDefinition(id: id, displayName: id == model.id ? model.displayName : nil, type: model.type, ownedBy: model.ownedBy)
                }
            }
            let auth = AuthFile(
                id: "\(kind.rawValue)#\(index)",
                name: kind.rawValue,
                provider: kind.rawValue,
                type: kind.rawValue,
                label: kind.rawValue
            )
            return AuthModelsResult(auth: auth, models: models)
        }
    }

    /// A models==nil result so a failed section fetch surfaces in `failedAccounts`.
    public static func failureResult(providerKey: String) -> AuthModelsResult {
        AuthModelsResult(
            auth: AuthFile(id: "\(providerKey)#error", name: providerKey, provider: providerKey, type: providerKey),
            models: nil
        )
    }

    // MARK: helpers

    /// Resolves `models: [{name, alias}]` mappings to the client-facing IDs
    /// (alias, falling back to name), deduplicated case-insensitively in order.
    private static func mappingModelIDs(_ rawMappings: [Any]?) -> [String] {
        var seen = Set<String>()
        var ids: [String] = []
        for raw in rawMappings ?? [] {
            guard let dict = raw as? [String: Any] else { continue }
            guard let id = firstNonEmpty(firstString(dict["alias"]), firstString(dict["name"])) else { continue }
            let key = id.lowercased()
            if seen.insert(key).inserted {
                ids.append(id)
            }
        }
        return ids
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
