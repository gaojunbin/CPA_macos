import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var baseURL: String
    public var managementKey: String
    public var refreshIntervalSeconds: TimeInterval

    public init(
        baseURL: String = "http://127.0.0.1:8317",
        managementKey: String = "",
        refreshIntervalSeconds: TimeInterval = 300
    ) {
        self.baseURL = baseURL
        self.managementKey = managementKey
        self.refreshIntervalSeconds = refreshIntervalSeconds
    }

    public var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !managementKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct AuthFilesResponse: Decodable, Sendable {
    public let files: [AuthFile]
}

public struct AuthFile: Decodable, Identifiable, Equatable, Sendable {
    public let id: String
    public let authIndex: String
    public let name: String
    public let provider: String
    public let type: String
    public let label: String?
    public let email: String?
    public let account: String?
    public let accountID: String?
    public let planType: String?
    public let projectID: String?
    public let prefix: String?
    public let priority: Int?
    public let usingAPI: Bool?
    public let proxyURL: String?
    public let note: String?
    public let status: String?
    public let statusMessage: String?
    public let disabled: Bool
    public let unavailable: Bool

    public var displayName: String {
        firstNonEmpty(label, email, account, cleanFileName(name), id) ?? "unknown"
    }

    public var normalizedProvider: String {
        firstNonEmpty(provider, type)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    public var isCodexLike: Bool {
        let provider = normalizedProvider
        guard !provider.hasPrefix("openai-compatible"), provider != "openai-compatibility" else {
            return false
        }
        return provider == "codex" || provider.contains("openai")
    }

    public var isAntigravity: Bool {
        normalizedProvider == "antigravity"
    }

    public var isClaude: Bool {
        normalizedProvider == "claude" || normalizedProvider == "anthropic"
    }

    public var isKimi: Bool {
        normalizedProvider == "kimi" || normalizedProvider == "kimi-ai"
    }

    public var isDevin: Bool {
        normalizedProvider == "devin" || normalizedProvider == "cognition"
    }

    public var isXAI: Bool {
        normalizedProvider == "xai" || normalizedProvider == "x-ai" || normalizedProvider == "grok"
    }

    /// Memberwise init for entries synthesized locally (e.g. config-based channels)
    /// rather than decoded from the management auth-files list.
    public init(
        id: String,
        authIndex: String = "",
        name: String,
        provider: String,
        type: String = "",
        label: String? = nil,
        email: String? = nil,
        account: String? = nil,
        accountID: String? = nil,
        planType: String? = nil,
        projectID: String? = nil,
        prefix: String? = nil,
        priority: Int? = nil,
        usingAPI: Bool? = nil,
        proxyURL: String? = nil,
        note: String? = nil,
        status: String? = nil,
        statusMessage: String? = nil,
        disabled: Bool = false,
        unavailable: Bool = false
    ) {
        self.id = id
        self.authIndex = authIndex
        self.name = name
        self.provider = provider
        self.type = type
        self.label = label
        self.email = email
        self.account = account
        self.accountID = accountID
        self.planType = planType
        self.projectID = projectID
        self.prefix = prefix
        self.priority = priority
        self.usingAPI = usingAPI
        self.proxyURL = proxyURL
        self.note = note
        self.status = status
        self.statusMessage = statusMessage
        self.disabled = disabled
        self.unavailable = unavailable
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case authIndex = "auth_index"
        case authIndexCamel = "authIndex"
        case name
        case provider
        case type
        case label
        case email
        case account
        case chatgptAccountID = "chatgpt_account_id"
        case accountID = "account_id"
        case planType = "plan_type"
        case plan
        case projectID = "project_id"
        case projectIDCamel = "projectId"
        case prefix
        case priority
        case usingAPI = "using_api"
        case usingAPICamel = "usingApi"
        case proxyURL = "proxy_url"
        case proxyURLCamel = "proxyUrl"
        case note
        case status
        case statusMessage = "status_message"
        case disabled
        case unavailable
        case idToken = "id_token"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let token = try container.decodeIfPresent(IDTokenClaims.self, forKey: .idToken)

        let decodedName = container.lossyString(forKey: .name)
        let decodedID = container.lossyString(forKey: .id)
        let fallbackName = firstNonEmpty(decodedName, decodedID) ?? "unknown"

        self.id = decodedID ?? fallbackName
        self.authIndex = firstNonEmpty(
            container.lossyString(forKey: .authIndex),
            container.lossyString(forKey: .authIndexCamel)
        ) ?? ""
        self.name = fallbackName
        self.provider = container.lossyString(forKey: .provider) ?? ""
        self.type = container.lossyString(forKey: .type) ?? ""
        self.label = container.lossyString(forKey: .label)
        self.email = container.lossyString(forKey: .email)
        self.account = container.lossyString(forKey: .account)
        self.accountID = firstNonEmpty(
            token?.chatgptAccountID,
            container.lossyString(forKey: .chatgptAccountID),
            container.lossyString(forKey: .accountID)
        )
        self.planType = firstNonEmpty(
            token?.planType,
            container.lossyString(forKey: .planType),
            container.lossyString(forKey: .plan)
        )
        self.projectID = firstNonEmpty(
            container.lossyString(forKey: .projectID),
            container.lossyString(forKey: .projectIDCamel)
        )
        self.prefix = container.lossyString(forKey: .prefix)
        self.priority = container.lossyInt(forKey: .priority)
        self.usingAPI = container.lossyBool(forKey: .usingAPI) ?? container.lossyBool(forKey: .usingAPICamel)
        self.proxyURL = firstNonEmpty(
            container.lossyString(forKey: .proxyURL),
            container.lossyString(forKey: .proxyURLCamel)
        )
        self.note = container.lossyString(forKey: .note)
        self.status = container.lossyString(forKey: .status)
        self.statusMessage = container.lossyString(forKey: .statusMessage)
        self.disabled = container.lossyBool(forKey: .disabled) ?? false
        self.unavailable = container.lossyBool(forKey: .unavailable) ?? false
    }
}

public struct QuotaWindow: Equatable, Sendable {
    public let id: String
    public let label: String
    public let usedPercent: Double?
    public let remainingPercent: Double?
    public let resetAfterSeconds: Double?
    public let resetAt: Date?
    public let displayValue: String?
    public let amountText: String?
    public let detailText: String?
    public let isUsable: Bool?

    public init(
        id: String,
        label: String,
        usedPercent: Double?,
        remainingPercent: Double?,
        resetAfterSeconds: Double?,
        resetAt: Date?,
        displayValue: String? = nil,
        amountText: String? = nil,
        detailText: String? = nil,
        isUsable: Bool? = nil
    ) {
        self.id = id
        self.label = label
        self.usedPercent = usedPercent
        self.remainingPercent = remainingPercent
        self.resetAfterSeconds = resetAfterSeconds
        self.resetAt = resetAt
        self.displayValue = displayValue
        self.amountText = amountText
        self.detailText = detailText
        self.isUsable = isUsable
    }

    public var isExhausted: Bool {
        if isUsable == false {
            return true
        }
        if let remainingPercent {
            return remainingPercent <= 0.01
        }
        if let usedPercent {
            return usedPercent >= 99.99
        }
        return false
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    public let planType: String?
    public let primary: QuotaWindow?
    public let weekly: QuotaWindow?
    public let additionalWindows: [QuotaWindow]
    public let rawStatus: String?
    public let fetchedAt: Date
    public let observation: QuotaObservation

    public init(
        planType: String?,
        primary: QuotaWindow?,
        weekly: QuotaWindow?,
        additionalWindows: [QuotaWindow] = [],
        rawStatus: String?,
        fetchedAt: Date = Date(),
        observation: QuotaObservation = .live
    ) {
        self.planType = planType
        self.primary = primary
        self.weekly = weekly
        self.additionalWindows = additionalWindows
        self.rawStatus = rawStatus
        self.fetchedAt = fetchedAt
        self.observation = observation
    }

    public var hasQuotaSignal: Bool {
        primary != nil || weekly != nil || !additionalWindows.isEmpty
    }
}

public struct AccountQuota: Identifiable, Equatable, Sendable {
    public let id: String
    public let auth: AuthFile
    public let usage: UsageSnapshot?
    public let errorMessage: String?
    /// Rich per-account runtime data parsed from the auth-files list entry, shown in the detail view.
    public let detail: AccountDetail?
    /// For config-based channels: the models resolved from config at snapshot time.
    /// The detail screen shows these directly (the per-auth models endpoint only
    /// serves file/OAuth credentials).
    public let configModels: [CPAModelDefinition]?

    public init(
        auth: AuthFile,
        usage: UsageSnapshot?,
        errorMessage: String?,
        detail: AccountDetail? = nil,
        configModels: [CPAModelDefinition]? = nil
    ) {
        self.id = auth.id
        self.auth = auth
        self.usage = usage ?? (auth.isDevin ? detail?.devinQuota?.usage() : nil)
        self.errorMessage = errorMessage
        self.detail = detail
        self.configModels = configModels
    }

    public var isDisabled: Bool {
        auth.disabled || (auth.status?.lowercased() == "disabled")
    }

    public var isUnavailable: Bool {
        auth.unavailable || isDisabled || detail?.activeCooldowns.contains(where: { $0.scope == "credential" }) == true
    }

    public var effectivePlanType: String? {
        firstNonEmpty(usage?.planType, auth.planType)
    }

    public var primaryRemainingPercent: Double? {
        usage?.primary?.remainingPercent
    }

    public var weeklyRemainingPercent: Double? {
        usage?.weekly?.remainingPercent
    }

    public var lowestRemainingPercent: Double? {
        let values = quotaWindows.compactMap(\.remainingPercent)
        return values.min()
    }

    public var hasUnusableQuotaWindow: Bool {
        quotaWindows.contains { $0.isUsable == false }
    }

    private var quotaWindows: [QuotaWindow] {
        [
            usage?.primary,
            usage?.weekly
        ].compactMap { $0 } + (usage?.additionalWindows ?? [])
    }

    public var statusText: String {
        if isDisabled {
            return "disabled"
        }
        if let errorMessage, !errorMessage.isEmpty {
            return "error"
        }
        if isUnavailable {
            return "unavailable"
        }
        if usage?.hasQuotaSignal == true {
            return "active"
        }
        return auth.status ?? "unknown"
    }
}

public struct RecentRequestBucket: Equatable, Sendable {
    public let time: String
    public let success: Int
    public let failed: Int
}

public struct AccountModelState: Equatable, Sendable {
    public let status: String?
    public let statusMessage: String?
    public let unavailable: Bool
    public let nextRetryAfter: Date?
    public let lastErrorMessage: String?
    public let quotaExceeded: Bool
}

public struct AccountCredits: Equatable, Sendable {
    public let known: Bool
    public let available: Bool
    public let creditAmount: Double?
    public let minCreditAmount: Double?
    public let paidTierID: String?
}

/// Rich per-account runtime data parsed from a single `/v0/management/auth-files` list entry.
/// Mirrors the fields the iOS detail screen surfaces, parsed leniently from raw JSON.
public struct AccountDetail: Equatable, Sendable {
    public let devinQuota: DevinQuota?
    public let cooldowns: [AccountCooldown]?
    public let success: Int
    public let failed: Int
    public let recentRequests: [RecentRequestBucket]
    public let modelStates: [String: AccountModelState]
    public let quotaExceeded: Bool
    public let quotaReason: String?
    public let nextRecoverAt: Date?
    public let lastRefresh: Date?
    public let nextRefreshAfter: Date?
    public let nextRetryAfter: Date?
    public let lastErrorMessage: String?
    public let accountType: String?
    public let chatgptAccountID: String?
    public let subscriptionActiveStart: Date?
    public let subscriptionActiveUntil: Date?
    public let source: String?
    public let runtimeOnly: Bool
    public let websockets: Bool?
    public let priority: Int?
    public let note: String?
    public let createdAt: Date?
    public let updatedAt: Date?
    public let credits: AccountCredits?

    public init(dict: [String: Any]) {
        let now = Date()
        if let raw = dict["cooldowns"] as? [[String: Any]],
           let data = try? JSONSerialization.data(withJSONObject: raw) {
            cooldowns = try? JSONDecoder().decode([AccountCooldown].self, from: data)
        } else {
            cooldowns = nil
        }
        success = integerValue(firstValue(dict["success"])) ?? 0
        failed = integerValue(firstValue(dict["failed"])) ?? 0
        recentRequests = (firstArray(dict["recent_requests"], dict["recentRequests"]) ?? []).compactMap { item in
            guard let entry = item as? [String: Any] else { return nil }
            return RecentRequestBucket(
                time: firstString(entry["time"]) ?? "",
                success: integerValue(entry["success"]) ?? 0,
                failed: integerValue(entry["failed"]) ?? 0
            )
        }
        var states: [String: AccountModelState] = [:]
        if let raw = firstDictionary(dict["model_states"], dict["modelStates"]) {
            for (key, value) in raw {
                guard let entry = value as? [String: Any] else { continue }
                let quota = firstDictionary(entry["quota"])
                states[key] = AccountModelState(
                    status: firstString(entry["status"]),
                    statusMessage: accountDetailErrorText(firstValue(entry["status_message"], entry["statusMessage"])),
                    unavailable: boolValue(entry["unavailable"]) ?? false,
                    nextRetryAfter: dateValue(firstValue(entry["next_retry_after"], entry["nextRetryAfter"]), now: now),
                    lastErrorMessage: accountDetailErrorText(firstValue(entry["last_error"], entry["lastError"])),
                    quotaExceeded: boolValue(quota?["exceeded"]) ?? false
                )
            }
        }
        modelStates = states
        let quota = firstDictionary(dict["quota"])
        devinQuota = quota.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            .flatMap { try? JSONDecoder().decode(DevinQuota.self, from: $0) }
        quotaExceeded = boolValue(quota?["exceeded"]) ?? false
        quotaReason = accountDetailErrorText(quota?["reason"])
        nextRecoverAt = dateValue(firstValue(quota?["next_recover_at"], quota?["nextRecoverAt"]), now: now)
        lastRefresh = dateValue(firstValue(dict["last_refresh"], dict["lastRefresh"], dict["last_refreshed_at"], dict["lastRefreshedAt"]), now: now)
        nextRefreshAfter = dateValue(firstValue(dict["next_refresh_after"], dict["nextRefreshAfter"]), now: now)
        nextRetryAfter = dateValue(firstValue(dict["next_retry_after"], dict["nextRetryAfter"]), now: now)
        lastErrorMessage = accountDetailErrorText(firstValue(dict["last_error"], dict["lastError"]))
        accountType = firstString(firstValue(dict["account_type"], dict["accountType"]))
        let idToken = firstDictionary(dict["id_token"], dict["idToken"])
        chatgptAccountID = firstString(
            idToken?["chatgpt_account_id"], idToken?["chatgptAccountID"], idToken?["chatgptAccountId"],
            dict["chatgpt_account_id"], dict["chatgptAccountID"], dict["chatgptAccountId"],
            dict["account_id"], dict["accountId"]
        )
        subscriptionActiveStart = dateValue(firstValue(idToken?["chatgpt_subscription_active_start"], idToken?["chatgptSubscriptionActiveStart"]), now: now)
        subscriptionActiveUntil = dateValue(firstValue(idToken?["chatgpt_subscription_active_until"], idToken?["chatgptSubscriptionActiveUntil"]), now: now)
        source = firstString(dict["source"])
        runtimeOnly = boolValue(firstValue(dict["runtime_only"], dict["runtimeOnly"])) ?? false
        websockets = boolValue(firstValue(dict["websockets"], dict["webSockets"]))
        priority = integerValue(firstValue(dict["priority"]))
        note = firstString(dict["note"])
        createdAt = dateValue(firstValue(dict["created_at"], dict["createdAt"]), now: now)
        updatedAt = dateValue(firstValue(dict["updated_at"], dict["updatedAt"], dict["modtime"], dict["modifiedAt"]), now: now)
        if let raw = firstDictionary(dict["antigravity_credits"], dict["antigravityCredits"]) {
            credits = AccountCredits(
                known: boolValue(raw["known"]) ?? false,
                available: boolValue(raw["available"]) ?? false,
                creditAmount: numberValue(firstValue(raw["credit_amount"], raw["creditAmount"])),
                minCreditAmount: numberValue(firstValue(raw["min_credit_amount"], raw["minCreditAmount"], raw["minimumCreditAmountForUsage"])),
                paidTierID: firstString(raw["paid_tier_id"], raw["paidTierID"], raw["paidTierId"])
            )
        } else {
            credits = nil
        }
    }

    public var totalRequests: Int { success + failed }

    public var successRate: Double? {
        guard totalRequests > 0 else { return nil }
        return Double(success) / Double(totalRequests)
    }

    public var activeCooldowns: [AccountCooldown] { (cooldowns ?? []).filter(\.isActive) }

    public var modelRuntimeStates: [String: AccountModelState] {
        guard cooldowns != nil else { return modelStates }
        var states: [String: AccountModelState] = [:]
        for cooldown in activeCooldowns where cooldown.scope == "model" {
            guard let key = cooldown.modelKey, !key.isEmpty else { continue }
            states[key] = AccountModelState(
                status: "cooling", statusMessage: cooldown.reasonDescription, unavailable: true,
                nextRetryAfter: cooldown.retryAt, lastErrorMessage: nil, quotaExceeded: false
            )
        }
        return states
    }

    /// Models currently cooling, exhausted, or in error, sorted by name.
    public var activeModelCooldowns: [(model: String, state: AccountModelState)] {
        let now = Date()
        return modelRuntimeStates
            .filter { _, state in
                let status = (state.status ?? "").lowercased()
                let hasFutureRetry = state.nextRetryAfter.map { $0 > now } == true
                return state.unavailable || state.quotaExceeded || hasFutureRetry ||
                    status.contains("error") || status.contains("fail") || status.contains("limit") ||
                    status.contains("exceeded") || status.contains("cool") || status.contains("quota") ||
                    status.contains("unavailable") ||
                    (state.lastErrorMessage ?? "").isEmpty == false
            }
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { (model: $0.key, state: $0.value) }
    }

    /// Soonest future recovery time across the account quota, retry, and per-model states.
    public var nextRecoveryDate: Date? {
        if cooldowns != nil { return activeCooldowns.compactMap(\.retryAt).min() }
        let now = Date()
        func future(_ date: Date?) -> Date? {
            guard let date, date > now else { return nil }
            return date
        }
        let modelMin = modelStates.values.compactMap { future($0.nextRetryAfter) }.min()
        return [future(nextRecoverAt), future(nextRetryAfter), modelMin].compactMap { $0 }.min()
    }
}

private func accountDetailErrorText(_ value: Any?) -> String? {
    if let string = firstString(value) {
        return string
    }
    guard let dictionary = value as? [String: Any] else {
        return nil
    }
    return firstString(
        dictionary["message"], dictionary["error"], dictionary["detail"],
        dictionary["reason"], dictionary["description"],
        dictionary["status_message"], dictionary["statusMessage"]
    )
}

public struct ModelsResponse: Decodable, Sendable {
    public let models: [CPAModelDefinition]
}

/// One truthful upstream-to-client model mapping used by the routing UI.
/// `name` is the upstream ID sent to the provider, while `alias` is the
/// client-facing ID before an optional credential/channel prefix is applied.
public struct ModelRouteDefinition: Identifiable, Equatable, Sendable {
    public let name: String
    public let alias: String
    public let prefix: String?
    public let source: String
    public let fork: Bool
    public let forceMapping: Bool
    /// Explicit client-facing ID after the global prefix policy has been applied.
    /// Canonical config/OAuth mappings leave this nil; the routing resolver expands
    /// them into one or two concrete public IDs before the UI consumes them.
    private let explicitPublicModelID: String?

    public init(
        name: String,
        alias: String,
        prefix: String? = nil,
        source: String,
        fork: Bool = false,
        forceMapping: Bool = false,
        publicModelID: String? = nil
    ) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        self.prefix = firstNonEmpty(prefix)
        self.source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        self.fork = fork
        self.forceMapping = forceMapping
        self.explicitPublicModelID = firstNonEmpty(publicModelID)
    }

    /// Explicit names for consumers that should not depend on the wire-format
    /// terminology used by config.yaml (`name` / `alias`).
    public var upstreamModelName: String { name }
    public var clientFacingAlias: String { alias }

    /// The concrete public ID exposed by this resolved route. Canonical mappings
    /// fall back to their prefixed form until `ModelRoutingResolver` expands the
    /// global force-prefix policy into explicit client IDs.
    public var publicModelID: String {
        if let explicitPublicModelID {
            return explicitPublicModelID
        }
        guard let prefix else { return alias }
        return "\(prefix)/\(alias)"
    }

    /// Returns a copy bound to one concrete client-facing model ID. Keeping the
    /// configured prefix on the copy lets the UI explain where the variant came
    /// from while `publicModelID` remains the authoritative resolved value.
    public func resolvingPublicModelID(_ id: String) -> ModelRouteDefinition {
        ModelRouteDefinition(
            name: name,
            alias: alias,
            prefix: prefix,
            source: source,
            fork: fork,
            forceMapping: forceMapping,
            publicModelID: id
        )
    }

    /// Stable identity includes both ends of the mapping and its routing flags,
    /// so repeated aliases that target different upstream models remain distinct.
    public var id: String {
        [source, prefix ?? "", name, alias, publicModelID, fork ? "1" : "0", forceMapping ? "1" : "0"]
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
    }
}

public struct CPAModelDefinition: Decodable, Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String?
    public let type: String?
    public let ownedBy: String?
    public let description: String?
    public let contextLength: Int?
    public let maxCompletionTokens: Int?
    public let supportedInputModalities: [String]
    public let supportedOutputModalities: [String]
    public let supportsWebSearch: Bool?
    public let thinking: ModelThinkingCapabilities?

    public init(
        id: String,
        displayName: String? = nil,
        type: String? = nil,
        ownedBy: String? = nil,
        description: String? = nil,
        contextLength: Int? = nil,
        maxCompletionTokens: Int? = nil,
        supportedInputModalities: [String] = [],
        supportedOutputModalities: [String] = [],
        supportsWebSearch: Bool? = nil,
        thinking: ModelThinkingCapabilities? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.type = type
        self.ownedBy = ownedBy
        self.description = description
        self.contextLength = contextLength
        self.maxCompletionTokens = maxCompletionTokens
        self.supportedInputModalities = supportedInputModalities
        self.supportedOutputModalities = supportedOutputModalities
        self.supportsWebSearch = supportsWebSearch
        self.thinking = thinking
    }

    public var inputTokenLimit: Int? { contextLength }
    public var outputTokenLimit: Int? { maxCompletionTokens }

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case description
        case displayName = "display_name"
        case displayNameCamel = "displayName"
        case ownedBy = "owned_by"
        case ownedByCamel = "ownedBy"
        case contextLength = "context_length"
        case contextLengthCamel = "contextLength"
        case inputTokenLimit = "input_token_limit"
        case inputTokenLimitCamel = "inputTokenLimit"
        case maxCompletionTokens = "max_completion_tokens"
        case maxCompletionTokensCamel = "maxCompletionTokens"
        case outputTokenLimit = "output_token_limit"
        case outputTokenLimitCamel = "outputTokenLimit"
        case supportedInputModalities = "supported_input_modalities"
        case supportedInputModalitiesCamel = "supportedInputModalities"
        case inputModalities = "input_modalities"
        case inputModalitiesCamel = "inputModalities"
        case supportedOutputModalities = "supported_output_modalities"
        case supportedOutputModalitiesCamel = "supportedOutputModalities"
        case outputModalities = "output_modalities"
        case outputModalitiesCamel = "outputModalities"
        case supportsWebSearch = "supports_web_search"
        case supportsWebSearchCamel = "supportsWebSearch"
        case thinking
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.lossyString(forKey: .id) ?? "unknown"
        displayName = firstNonEmpty(
            container.lossyString(forKey: .displayName),
            container.lossyString(forKey: .displayNameCamel)
        )
        type = container.lossyString(forKey: .type)
        ownedBy = firstNonEmpty(
            container.lossyString(forKey: .ownedBy),
            container.lossyString(forKey: .ownedByCamel)
        )
        description = container.lossyString(forKey: .description)
        contextLength = container.lossyInt(forKey: .contextLength)
            ?? container.lossyInt(forKey: .contextLengthCamel)
            ?? container.lossyInt(forKey: .inputTokenLimit)
            ?? container.lossyInt(forKey: .inputTokenLimitCamel)
        maxCompletionTokens = container.lossyInt(forKey: .maxCompletionTokens)
            ?? container.lossyInt(forKey: .maxCompletionTokensCamel)
            ?? container.lossyInt(forKey: .outputTokenLimit)
            ?? container.lossyInt(forKey: .outputTokenLimitCamel)
        supportedInputModalities = firstNonEmptyArray(
            container.lossyStringArray(forKey: .supportedInputModalities),
            container.lossyStringArray(forKey: .supportedInputModalitiesCamel),
            container.lossyStringArray(forKey: .inputModalities),
            container.lossyStringArray(forKey: .inputModalitiesCamel)
        )
        supportedOutputModalities = firstNonEmptyArray(
            container.lossyStringArray(forKey: .supportedOutputModalities),
            container.lossyStringArray(forKey: .supportedOutputModalitiesCamel),
            container.lossyStringArray(forKey: .outputModalities),
            container.lossyStringArray(forKey: .outputModalitiesCamel)
        )
        supportsWebSearch = container.lossyBool(forKey: .supportsWebSearch)
            ?? container.lossyBool(forKey: .supportsWebSearchCamel)
        thinking = try? container.decodeIfPresent(ModelThinkingCapabilities.self, forKey: .thinking)
    }
}

public struct ModelThinkingCapabilities: Decodable, Equatable, Sendable {
    public let min: Int?
    public let max: Int?
    public let zeroAllowed: Bool?
    public let dynamicAllowed: Bool?
    public let levels: [String]

    public init(
        min: Int? = nil,
        max: Int? = nil,
        zeroAllowed: Bool? = nil,
        dynamicAllowed: Bool? = nil,
        levels: [String] = []
    ) {
        self.min = min
        self.max = max
        self.zeroAllowed = zeroAllowed
        self.dynamicAllowed = dynamicAllowed
        self.levels = levels
    }

    public var minimumTokens: Int? { min }
    public var maximumTokens: Int? { max }

    fileprivate func mergingMissingMetadata(from other: ModelThinkingCapabilities?) -> ModelThinkingCapabilities {
        guard let other else { return self }
        return ModelThinkingCapabilities(
            min: min ?? other.min,
            max: max ?? other.max,
            zeroAllowed: zeroAllowed ?? other.zeroAllowed,
            dynamicAllowed: dynamicAllowed ?? other.dynamicAllowed,
            levels: mergeUniqueStrings(levels, other.levels)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case min
        case max
        case minimum
        case maximum
        case minTokens = "min_tokens"
        case minTokensCamel = "minTokens"
        case maxTokens = "max_tokens"
        case maxTokensCamel = "maxTokens"
        case zeroAllowed = "zero_allowed"
        case zeroAllowedCamel = "zeroAllowed"
        case dynamicAllowed = "dynamic_allowed"
        case dynamicAllowedCamel = "dynamicAllowed"
        case levels
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        min = container.lossyInt(forKey: .min)
            ?? container.lossyInt(forKey: .minimum)
            ?? container.lossyInt(forKey: .minTokens)
            ?? container.lossyInt(forKey: .minTokensCamel)
        max = container.lossyInt(forKey: .max)
            ?? container.lossyInt(forKey: .maximum)
            ?? container.lossyInt(forKey: .maxTokens)
            ?? container.lossyInt(forKey: .maxTokensCamel)
        zeroAllowed = container.lossyBool(forKey: .zeroAllowed)
            ?? container.lossyBool(forKey: .zeroAllowedCamel)
        dynamicAllowed = container.lossyBool(forKey: .dynamicAllowed)
            ?? container.lossyBool(forKey: .dynamicAllowedCamel)
        levels = container.lossyStringArray(forKey: .levels)
    }
}

// MARK: - Service-wide model pool

/// The per-account result of a `/v0/management/auth-files/models` query.
/// `models == nil` means the query failed for that account (vs. an empty list).
public struct AuthModelsResult: Sendable {
    public let auth: AuthFile
    public let models: [CPAModelDefinition]?

    public init(auth: AuthFile, models: [CPAModelDefinition]?) {
        self.auth = auth
        self.models = models
    }
}

/// One model within a provider group, with how many of that provider's accounts serve it.
public struct PoolModelEntry: Identifiable, Equatable, Sendable {
    public let model: CPAModelDefinition
    public let accountCount: Int

    public var id: String { model.id }

    public init(model: CPAModelDefinition, accountCount: Int) {
        self.model = model
        self.accountCount = accountCount
    }

    public var displayName: String {
        firstNonEmpty(model.displayName, model.id) ?? model.id
    }
}

/// The deduplicated model list served by one provider's accounts.
public struct ProviderModelGroup: Identifiable, Equatable, Sendable {
    public let provider: ProviderInfo
    public let models: [PoolModelEntry]
    /// Accounts of this provider whose model list was fetched successfully.
    public let accountCount: Int

    public var id: String { provider.key }

    public init(provider: ProviderInfo, models: [PoolModelEntry], accountCount: Int) {
        self.provider = provider
        self.models = models
        self.accountCount = accountCount
    }
}

/// Aggregated "what can this service serve right now" snapshot, grouped by provider.
public struct ModelPoolSnapshot: Equatable, Sendable {
    public let providers: [ProviderModelGroup]
    /// Accounts whose model list was fetched successfully.
    public let queriedAccounts: Int
    /// Accounts whose model list query failed (results may be incomplete).
    public let failedAccounts: Int
    public let fetchedAt: Date

    public init(providers: [ProviderModelGroup], queriedAccounts: Int, failedAccounts: Int, fetchedAt: Date = Date()) {
        self.providers = providers
        self.queriedAccounts = queriedAccounts
        self.failedAccounts = failedAccounts
        self.fetchedAt = fetchedAt
    }

    /// Distinct model IDs across every provider (case-insensitive).
    public var distinctModelCount: Int {
        var ids = Set<String>()
        for group in providers {
            for entry in group.models {
                ids.insert(entry.model.id.lowercased())
            }
        }
        return ids.count
    }
}

/// Merges per-account model lists into per-provider deduplicated groups.
/// Pure so it can be unit-tested; the client feeds it live query results.
public enum ModelPoolAggregator {
    public static func aggregate(_ results: [AuthModelsResult], fetchedAt: Date = Date()) -> ModelPoolSnapshot {
        let grouped = Dictionary(grouping: results) { result in
            ProviderCatalog.info(for: result.auth.normalizedProvider).key
        }

        var providers: [ProviderModelGroup] = []
        var failedAccounts = 0
        var queriedAccounts = 0

        for (providerKey, providerResults) in grouped {
            let info = ProviderCatalog.info(for: providerKey)
            var order: [String] = []
            var merged: [String: (model: CPAModelDefinition, count: Int)] = [:]
            var successCount = 0

            // Concurrent fetches return in arbitrary order; sort so the kept id
            // casing / metadata precedence is deterministic across refreshes.
            let orderedResults = providerResults.sorted {
                $0.auth.id.localizedCaseInsensitiveCompare($1.auth.id) == .orderedAscending
            }
            for result in orderedResults {
                guard let models = result.models else {
                    failedAccounts += 1
                    continue
                }
                successCount += 1
                // The same account may list one id twice (alias + upstream); count it once.
                var seenForAccount = Set<String>()
                for model in models {
                    let key = model.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    guard !key.isEmpty else { continue }
                    if seenForAccount.contains(key) {
                        if let existing = merged[key] {
                            merged[key] = (mergeDefinitions(existing.model, model), existing.count)
                        }
                        continue
                    }
                    seenForAccount.insert(key)
                    if let existing = merged[key] {
                        merged[key] = (mergeDefinitions(existing.model, model), existing.count + 1)
                    } else {
                        merged[key] = (model, 1)
                        order.append(key)
                    }
                }
            }

            queriedAccounts += successCount
            guard !merged.isEmpty else { continue }

            let entries = order
                .compactMap { merged[$0] }
                .map { PoolModelEntry(model: $0.model, accountCount: $0.count) }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            providers.append(ProviderModelGroup(provider: info, models: entries, accountCount: successCount))
        }

        providers.sort { lhs, rhs in
            if lhs.provider.priority != rhs.provider.priority {
                return lhs.provider.priority < rhs.provider.priority
            }
            return lhs.provider.displayName.localizedCaseInsensitiveCompare(rhs.provider.displayName) == .orderedAscending
        }

        return ModelPoolSnapshot(
            providers: providers,
            queriedAccounts: queriedAccounts,
            failedAccounts: failedAccounts,
            fetchedAt: fetchedAt
        )
    }

    /// Keeps the first-seen id casing and fills in missing metadata from later duplicates.
    private static func mergeDefinitions(_ base: CPAModelDefinition, _ other: CPAModelDefinition) -> CPAModelDefinition {
        CPAModelDefinition(
            id: base.id,
            displayName: firstNonEmpty(base.displayName, other.displayName),
            type: firstNonEmpty(base.type, other.type),
            ownedBy: firstNonEmpty(base.ownedBy, other.ownedBy),
            description: firstNonEmpty(base.description, other.description),
            contextLength: base.contextLength ?? other.contextLength,
            maxCompletionTokens: base.maxCompletionTokens ?? other.maxCompletionTokens,
            supportedInputModalities: mergeUniqueStrings(
                base.supportedInputModalities,
                other.supportedInputModalities
            ),
            supportedOutputModalities: mergeUniqueStrings(
                base.supportedOutputModalities,
                other.supportedOutputModalities
            ),
            supportsWebSearch: base.supportsWebSearch ?? other.supportsWebSearch,
            thinking: base.thinking?.mergingMissingMetadata(from: other.thinking) ?? other.thinking
        )
    }
}

public struct PoolSummary: Equatable, Sendable {
    public let totalAccounts: Int
    public let quotaAccounts: Int
    public let errorAccounts: Int
    public let disabledAccounts: Int
    /// Number of Codex (5h/7d window) accounts the primary/weekly averages are based on.
    public let codexAccounts: Int
    /// Average remaining percent of the Codex 5-hour window across Codex accounts only.
    public let primaryAverage: Double?
    /// Average remaining percent of the Codex 7-day window across Codex accounts only.
    public let weeklyAverage: Double?
    public let fetchedAt: Date

    public init(accounts: [AccountQuota], fetchedAt: Date = Date()) {
        self.totalAccounts = accounts.count
        self.quotaAccounts = accounts.filter { $0.usage?.hasQuotaSignal == true }.count
        self.errorAccounts = accounts.filter { ($0.errorMessage ?? "").isEmpty == false }.count
        self.disabledAccounts = accounts.filter(\.isDisabled).count
        // These legacy summary fields remain Codex-specific. Provider-aware
        // dashboard averages for Claude, Antigravity, and Grok live in
        // DashboardMetrics.swift and never mix incompatible quota shapes.
        let codexAccounts = accounts.filter { $0.auth.isCodexLike }
        self.codexAccounts = codexAccounts.count
        self.primaryAverage = PoolSummary.average(codexAccounts.compactMap(\.primaryRemainingPercent))
        self.weeklyAverage = PoolSummary.average(codexAccounts.compactMap(\.weeklyRemainingPercent))
        self.fetchedAt = fetchedAt
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}

public struct ProviderInfo: Equatable, Sendable {
    public let key: String
    public let displayName: String
    public let symbolName: String
    public let accentName: String
    public let priority: Int
    public let supportsUsage: Bool

    public init(
        key: String,
        displayName: String,
        symbolName: String,
        accentName: String,
        priority: Int,
        supportsUsage: Bool
    ) {
        self.key = key
        self.displayName = displayName
        self.symbolName = symbolName
        self.accentName = accentName
        self.priority = priority
        self.supportsUsage = supportsUsage
    }
}

public enum ProviderCatalog {
    private static let table: [String: ProviderInfo] = [
        "codex": ProviderInfo(key: "codex", displayName: "Codex", symbolName: "chevron.left.forwardslash.chevron.right", accentName: "teal", priority: 0, supportsUsage: true),
        "openai": ProviderInfo(key: "openai", displayName: "OpenAI", symbolName: "o.circle.fill", accentName: "mint", priority: 1, supportsUsage: true),
        "claude": ProviderInfo(key: "claude", displayName: "Claude", symbolName: "c.circle.fill", accentName: "orange", priority: 2, supportsUsage: true),
        "anthropic": ProviderInfo(key: "anthropic", displayName: "Claude", symbolName: "c.circle.fill", accentName: "orange", priority: 2, supportsUsage: true),
        "gemini": ProviderInfo(key: "gemini", displayName: "Gemini", symbolName: "g.circle.fill", accentName: "blue", priority: 3, supportsUsage: false),
        "gemini-cli": ProviderInfo(key: "gemini-cli", displayName: "Gemini CLI", symbolName: "g.circle", accentName: "blue", priority: 4, supportsUsage: false),
        "vertex": ProviderInfo(key: "vertex", displayName: "Vertex AI", symbolName: "cloud.fill", accentName: "indigo", priority: 5, supportsUsage: false),
        "antigravity": ProviderInfo(key: "antigravity", displayName: "Antigravity", symbolName: "paperplane.fill", accentName: "purple", priority: 6, supportsUsage: true),
        "xai": ProviderInfo(key: "xai", displayName: "Grok", symbolName: "x.circle.fill", accentName: "gray", priority: 7, supportsUsage: true),
        "kimi": ProviderInfo(key: "kimi", displayName: "Kimi", symbolName: "k.circle.fill", accentName: "pink", priority: 8, supportsUsage: true),
        "devin": ProviderInfo(key: "devin", displayName: "Devin", symbolName: "d.circle.fill", accentName: "blue", priority: 9, supportsUsage: true),
        "meta": ProviderInfo(key: "meta", displayName: "Meta", symbolName: "infinity", accentName: "blue", priority: 10, supportsUsage: false),
        "kimi-ai": ProviderInfo(key: "kimi-ai", displayName: "Kimi.ai", symbolName: "k.circle", accentName: "pink", priority: 11, supportsUsage: true),
        "xai-api-key": ProviderInfo(key: "xai-api-key", displayName: "Grok API Key", symbolName: "key.fill", accentName: "gray", priority: 46, supportsUsage: false),
        "meta-api-key": ProviderInfo(key: "meta-api-key", displayName: "Meta API Key", symbolName: "key.fill", accentName: "blue", priority: 45, supportsUsage: false),
        // Config-based API-key channels (config.yaml sections, not OAuth accounts).
        "codex-api-key": ProviderInfo(key: "codex-api-key", displayName: "Codex API Key", symbolName: "key.fill", accentName: "teal", priority: 40, supportsUsage: false),
        "claude-api-key": ProviderInfo(key: "claude-api-key", displayName: "Claude API Key", symbolName: "key.fill", accentName: "orange", priority: 41, supportsUsage: false),
        "gemini-api-key": ProviderInfo(key: "gemini-api-key", displayName: "Gemini API Key", symbolName: "key.fill", accentName: "blue", priority: 42, supportsUsage: false),
        "interactions-api-key": ProviderInfo(key: "interactions-api-key", displayName: "Interactions API Key", symbolName: "key.fill", accentName: "blue", priority: 43, supportsUsage: false),
        "vertex-api-key": ProviderInfo(key: "vertex-api-key", displayName: "Vertex API Key", symbolName: "key.fill", accentName: "indigo", priority: 44, supportsUsage: false)
    ]

    private static let openAICompatiblePrefix = "openai-compatible-"

    public static func info(for rawKey: String) -> ProviderInfo {
        let normalized = normalizeProviderKey(rawKey)
        if let exact = table[normalized] {
            return exact
        }
        // "openai-compatible-<name>" is the server's internal key for an
        // openai-compatibility channel; surface the channel's own name.
        if normalized.hasPrefix(openAICompatiblePrefix) {
            let channel = String(normalized.dropFirst(openAICompatiblePrefix.count))
            return ProviderInfo(
                key: normalized,
                displayName: channel.isEmpty ? "OpenAI Compat" : channel,
                symbolName: "circle.hexagongrid.fill",
                accentName: "mint",
                priority: 50,
                supportsUsage: false
            )
        }
        if normalized.contains("openai") {
            return ProviderInfo(key: normalized, displayName: "OpenAI Compat", symbolName: "circle.hexagongrid.fill", accentName: "mint", priority: 50, supportsUsage: false)
        }
        let display = normalized.isEmpty
            ? "Other"
            : normalized.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return ProviderInfo(key: normalized.isEmpty ? "other" : normalized, displayName: display, symbolName: "circle.dotted", accentName: "gray", priority: 200, supportsUsage: false)
    }

    private static func normalizeProviderKey(_ rawKey: String) -> String {
        let normalized = rawKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        if normalized == "cognition" { return "devin" }
        if normalized == "x-ai" || normalized == "grok" {
            return "xai"
        }
        return normalized
    }
}

public struct ProviderPool: Identifiable, Equatable, Sendable {
    public let provider: ProviderInfo
    public let accounts: [AccountQuota]
    public let summary: PoolSummary

    public var id: String { provider.key }

    public init(provider: ProviderInfo, accounts: [AccountQuota], fetchedAt: Date = Date()) {
        self.provider = provider
        self.accounts = accounts
        self.summary = PoolSummary(accounts: accounts, fetchedAt: fetchedAt)
    }
}

public struct PoolSnapshot: Equatable, Sendable {
    public let providers: [ProviderPool]
    public let summary: PoolSummary
    public let fetchedAt: Date

    public init(providers: [ProviderPool], fetchedAt: Date = Date()) {
        self.providers = providers
        let allAccounts = providers.flatMap(\.accounts)
        self.summary = PoolSummary(accounts: allAccounts, fetchedAt: fetchedAt)
        self.fetchedAt = fetchedAt
    }

    public var accounts: [AccountQuota] {
        providers.flatMap(\.accounts)
    }
}

struct IDTokenClaims: Decodable, Equatable, Sendable {
    let chatgptAccountID: String?
    let planType: String?

    private enum CodingKeys: String, CodingKey {
        case chatgptAccountID = "chatgpt_account_id"
        case planType = "plan_type"
    }
}

public func firstNonEmpty(_ values: String?...) -> String? {
    for value in values {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return trimmed
        }
    }
    return nil
}

public func displayPercent(_ value: Double?) -> String {
    guard let value, value.isFinite else {
        return "--"
    }
    if value >= 99.95 {
        return "100%"
    }
    if value < 10 {
        return String(format: "%.1f%%", max(0, value))
    }
    return String(format: "%.0f%%", max(0, value))
}

public func displayDuration(seconds: Double?) -> String {
    guard let seconds, seconds.isFinite, seconds > 0 else {
        return "-"
    }
    let totalMinutes = Int((seconds / 60).rounded(.up))
    if totalMinutes < 60 {
        return "\(totalMinutes)m"
    }
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if hours < 24 {
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }
    let days = hours / 24
    let remainingHours = hours % 24
    return remainingHours == 0 ? "\(days)d" : "\(days)d \(remainingHours)h"
}

public func displayCredits(_ value: Double?) -> String {
    guard let value, value.isFinite else {
        return "--"
    }
    let clamped = max(0, value)
    if clamped >= 1_000_000 {
        let millions = clamped / 1_000_000
        return millions >= 10 ? String(format: "%.0fM", millions) : String(format: "%.1fM", millions)
    }
    if clamped >= 1_000 {
        let thousands = clamped / 1_000
        return thousands >= 10 ? String(format: "%.0fK", thousands) : String(format: "%.1fK", thousands)
    }
    if clamped.rounded(.towardZero) == clamped {
        return String(format: "%.0f", clamped)
    }
    return clamped < 10 ? String(format: "%.1f", clamped) : String(format: "%.0f", clamped)
}

private func cleanFileName(_ value: String?) -> String? {
    guard let value = value else { return nil }
    var result = value
    if result.lowercased().hasSuffix(".json") {
        result.removeLast(5)
    }
    if result.lowercased().hasPrefix("codex-") {
        result.removeFirst(6)
    }
    return result
}

private func firstNonEmptyArray(_ values: [String]...) -> [String] {
    values.first(where: { !$0.isEmpty }) ?? []
}

private func mergeUniqueStrings(_ first: [String], _ second: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for value in first + second {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = trimmed.lowercased()
        guard !key.isEmpty, seen.insert(key).inserted else { continue }
        result.append(trimmed)
    }
    return result
}

private extension KeyedDecodingContainer {
    func lossyString(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value ? "true" : "false"
        }
        return nil
    }

    func lossyBool(forKey key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value != 0
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    func lossyInt(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key), value.isFinite {
            return Int(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    func lossyStringArray(forKey key: Key) -> [String] {
        if let values = try? decodeIfPresent([String].self, forKey: key) {
            return mergeUniqueStrings(values, [])
        }
        if let values = try? decodeIfPresent([Int].self, forKey: key) {
            return values.map(String.init)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            let parts = value
                .split(separator: ",", omittingEmptySubsequences: true)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            return mergeUniqueStrings(parts, [])
        }
        return []
    }
}
