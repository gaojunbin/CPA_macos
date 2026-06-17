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
        normalizedProvider == "codex" || normalizedProvider.contains("openai")
    }

    public var isAntigravity: Bool {
        normalizedProvider == "antigravity"
    }

    public var isClaude: Bool {
        normalizedProvider == "claude" || normalizedProvider == "anthropic"
    }

    public var isKimi: Bool {
        normalizedProvider == "kimi"
    }

    public var isXAI: Bool {
        normalizedProvider == "xai" || normalizedProvider == "x-ai" || normalizedProvider == "grok"
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

    public init(
        planType: String?,
        primary: QuotaWindow?,
        weekly: QuotaWindow?,
        additionalWindows: [QuotaWindow] = [],
        rawStatus: String?,
        fetchedAt: Date = Date()
    ) {
        self.planType = planType
        self.primary = primary
        self.weekly = weekly
        self.additionalWindows = additionalWindows
        self.rawStatus = rawStatus
        self.fetchedAt = fetchedAt
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

    public init(auth: AuthFile, usage: UsageSnapshot?, errorMessage: String?, detail: AccountDetail? = nil) {
        self.id = auth.id
        self.auth = auth
        self.usage = usage
        self.errorMessage = errorMessage
        self.detail = detail
    }

    public var isDisabled: Bool {
        auth.disabled || (auth.status?.lowercased() == "disabled")
    }

    public var isUnavailable: Bool {
        auth.unavailable || isDisabled
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

    /// Models currently cooling, exhausted, or in error, sorted by name.
    public var activeModelCooldowns: [(model: String, state: AccountModelState)] {
        let now = Date()
        return modelStates
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

public struct CPAModelDefinition: Decodable, Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String?
    public let type: String?
    public let ownedBy: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case displayName = "display_name"
        case displayNameCamel = "displayName"
        case ownedBy = "owned_by"
        case ownedByCamel = "ownedBy"
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
        // The 5h/7d headline metric is Codex-specific: only Codex exposes rolling
        // 5-hour and 7-day windows, so the average is scoped to Codex accounts and
        // never polluted by other providers' quota shapes.
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
        "kimi": ProviderInfo(key: "kimi", displayName: "Kimi", symbolName: "k.circle.fill", accentName: "pink", priority: 8, supportsUsage: true)
    ]

    public static func info(for rawKey: String) -> ProviderInfo {
        let normalized = normalizeProviderKey(rawKey)
        if let exact = table[normalized] {
            return exact
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
}
