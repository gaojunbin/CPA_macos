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

    public init(
        id: String,
        label: String,
        usedPercent: Double?,
        remainingPercent: Double?,
        resetAfterSeconds: Double?,
        resetAt: Date?
    ) {
        self.id = id
        self.label = label
        self.usedPercent = usedPercent
        self.remainingPercent = remainingPercent
        self.resetAfterSeconds = resetAfterSeconds
        self.resetAt = resetAt
    }

    public var isExhausted: Bool {
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

    public init(auth: AuthFile, usage: UsageSnapshot?, errorMessage: String?) {
        self.id = auth.id
        self.auth = auth
        self.usage = usage
        self.errorMessage = errorMessage
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

public struct PoolSummary: Equatable, Sendable {
    public let totalAccounts: Int
    public let quotaAccounts: Int
    public let errorAccounts: Int
    public let disabledAccounts: Int
    public let primaryAverage: Double?
    public let weeklyAverage: Double?
    public let fetchedAt: Date

    public init(accounts: [AccountQuota], fetchedAt: Date = Date()) {
        self.totalAccounts = accounts.count
        self.quotaAccounts = accounts.filter { $0.usage?.hasQuotaSignal == true }.count
        self.errorAccounts = accounts.filter { ($0.errorMessage ?? "").isEmpty == false }.count
        self.disabledAccounts = accounts.filter(\.isDisabled).count
        self.primaryAverage = PoolSummary.average(accounts.compactMap(\.primaryRemainingPercent))
        self.weeklyAverage = PoolSummary.average(accounts.compactMap(\.weeklyRemainingPercent))
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
        "claude": ProviderInfo(key: "claude", displayName: "Claude", symbolName: "c.circle.fill", accentName: "orange", priority: 2, supportsUsage: false),
        "anthropic": ProviderInfo(key: "anthropic", displayName: "Claude", symbolName: "c.circle.fill", accentName: "orange", priority: 2, supportsUsage: false),
        "gemini": ProviderInfo(key: "gemini", displayName: "Gemini", symbolName: "g.circle.fill", accentName: "blue", priority: 3, supportsUsage: false),
        "gemini-cli": ProviderInfo(key: "gemini-cli", displayName: "Gemini CLI", symbolName: "g.circle", accentName: "blue", priority: 4, supportsUsage: false),
        "vertex": ProviderInfo(key: "vertex", displayName: "Vertex AI", symbolName: "cloud.fill", accentName: "indigo", priority: 5, supportsUsage: false),
        "antigravity": ProviderInfo(key: "antigravity", displayName: "Antigravity", symbolName: "paperplane.fill", accentName: "purple", priority: 6, supportsUsage: false),
        "xai": ProviderInfo(key: "xai", displayName: "xAI", symbolName: "x.circle.fill", accentName: "gray", priority: 7, supportsUsage: false),
        "kimi": ProviderInfo(key: "kimi", displayName: "Kimi", symbolName: "k.circle.fill", accentName: "pink", priority: 8, supportsUsage: false)
    ]

    public static func info(for rawKey: String) -> ProviderInfo {
        let normalized = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
