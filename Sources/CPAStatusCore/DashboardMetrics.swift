import Foundation

/// A compact health signal for the menu bar. Quota percentages deliberately do
/// not affect this ratio: low balance is not a connection-health failure.
public struct AccountHealthRatio: Equatable, Sendable {
    public let healthy: Int
    public let total: Int

    public init(healthy: Int, total: Int) {
        self.healthy = healthy
        self.total = total
    }

    public var displayValue: String { "\(healthy)/\(total)" }
    public var isFullyHealthy: Bool { total > 0 && healthy == total }
}

public extension AccountQuota {
    var isHealthy: Bool {
        let status = auth.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return !isDisabled && !isUnavailable && (errorMessage ?? "").isEmpty
            && status != "error" && status != "failed"
            && (detail?.lastErrorMessage ?? "").isEmpty
    }
}

public extension ProviderPool {
    var healthRatio: AccountHealthRatio {
        AccountHealthRatio(healthy: accounts.filter(\.isHealthy).count, total: accounts.count)
    }
}

public extension PoolSnapshot {
    var healthRatio: AccountHealthRatio {
        AccountHealthRatio(healthy: accounts.filter(\.isHealthy).count, total: accounts.count)
    }
}

/// Provider-specific quota slots used by both pool averages and compact account
/// cards. Antigravity matches the current groups/buckets contract and averages
/// multiple matching buckets inside one account before the account-pool average.
public enum ProviderQuotaMetricKind: String, CaseIterable, Equatable, Hashable, Sendable {
    case codexFiveHour
    case codexSevenDay
    case claudeFiveHour
    case claudeSevenDay
    case antigravityGeminiFiveHour
    case antigravityGeminiSevenDay
    case antigravityClaudeGPTFiveHour
    case antigravityClaudeGPTSevenDay
    case xaiWeekly
    case xaiMonthly

    public var cardLabel: String {
        switch self {
        case .codexFiveHour, .claudeFiveHour: return "5h"
        case .codexSevenDay, .claudeSevenDay: return "7d"
        case .antigravityGeminiFiveHour: return "Gemini 5h"
        case .antigravityGeminiSevenDay: return "Gemini 7d"
        case .antigravityClaudeGPTFiveHour: return "Claude/GPT 5h"
        case .antigravityClaudeGPTSevenDay: return "Claude/GPT 7d"
        case .xaiWeekly: return "周积分"
        case .xaiMonthly: return "月积分"
        }
    }

    public static func metrics(for providerKey: String) -> [ProviderQuotaMetricKind] {
        switch providerKey.lowercased() {
        case "codex", "openai":
            return [.codexFiveHour, .codexSevenDay]
        case "claude", "anthropic":
            return [.claudeFiveHour, .claudeSevenDay]
        case "antigravity":
            return [
                .antigravityGeminiFiveHour,
                .antigravityGeminiSevenDay,
                .antigravityClaudeGPTFiveHour,
                .antigravityClaudeGPTSevenDay
            ]
        case "xai", "x-ai", "grok":
            return [.xaiWeekly, .xaiMonthly]
        default:
            return []
        }
    }

    public func matchingWindows(in account: AccountQuota) -> [QuotaWindow] {
        guard let usage = account.usage else { return [] }
        let providerKey = ProviderCatalog.info(for: account.auth.normalizedProvider).key
        guard Self.metrics(for: providerKey).contains(self) else { return [] }

        switch self {
        case .codexFiveHour:
            return usage.primary.map { [$0] } ?? []
        case .codexSevenDay:
            guard let weekly = usage.weekly, !Self.isMonthly(weekly) else { return [] }
            return [weekly]
        case .claudeFiveHour:
            return usage.additionalWindows.filter { $0.id == "claude-five-hour" }
        case .claudeSevenDay:
            return usage.additionalWindows.filter { $0.id == "claude-seven-day" }
        case .xaiWeekly:
            return usage.additionalWindows.filter { $0.id == "xai-weekly-credits" }
        case .xaiMonthly:
            return usage.additionalWindows.filter { $0.id == "xai-monthly-credits" }
        case .antigravityGeminiFiveHour:
            return Self.antigravityWindows(in: usage, family: .gemini, period: .fiveHour)
        case .antigravityGeminiSevenDay:
            return Self.antigravityWindows(in: usage, family: .gemini, period: .sevenDay)
        case .antigravityClaudeGPTFiveHour:
            return Self.antigravityWindows(in: usage, family: .claudeGPT, period: .fiveHour)
        case .antigravityClaudeGPTSevenDay:
            return Self.antigravityWindows(in: usage, family: .claudeGPT, period: .sevenDay)
        }
    }

    /// One account contributes one value to its provider pool, even when the
    /// upstream returns several matching Antigravity groups.
    public func remainingPercent(in account: AccountQuota) -> Double? {
        let values = matchingWindows(in: account).compactMap(\.remainingPercent)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// A compact account-card window. Multiple matching buckets are represented
    /// by their account-local average and the earliest reset time.
    public func averagedWindow(in account: AccountQuota) -> QuotaWindow? {
        let windows = matchingWindows(in: account)
        guard let remainingPercent = remainingPercent(in: account) else { return nil }
        let resetAt = windows.compactMap(\.resetAt).min()
        let resetAfter = windows.compactMap(\.resetAfterSeconds).min()
        let details = uniqueStrings(windows.compactMap(\.detailText))
        return QuotaWindow(
            id: "dashboard-\(rawValue)",
            label: cardLabel,
            usedPercent: max(0, min(100, 100 - remainingPercent)),
            remainingPercent: max(0, min(100, remainingPercent)),
            resetAfterSeconds: resetAfter,
            resetAt: resetAt,
            displayValue: displayPercent(remainingPercent),
            amountText: nil,
            detailText: details.count == 1 ? details[0] : nil,
            isUsable: remainingPercent > 0
        )
    }

    private enum AntigravityFamily {
        case gemini
        case claudeGPT
    }

    private enum QuotaPeriod {
        case fiveHour
        case sevenDay
    }

    private static func antigravityWindows(
        in usage: UsageSnapshot,
        family: AntigravityFamily,
        period: QuotaPeriod
    ) -> [QuotaWindow] {
        usage.additionalWindows.filter { window in
            let text = [window.id, window.label, window.detailText ?? ""]
                .joined(separator: " ")
                .lowercased()
                .replacingOccurrences(of: "_", with: "-")
            guard text.contains("antigravity") else { return false }

            let familyMatches: Bool
            switch family {
            case .gemini:
                familyMatches = text.contains("gemini")
            case .claudeGPT:
                familyMatches = text.contains("claude") || text.contains("gpt")
            }
            guard familyMatches else { return false }

            switch period {
            case .fiveHour:
                return ["5h", "5 hour", "5-hour", "five hour", "five-hour"]
                    .contains { text.contains($0) }
            case .sevenDay:
                return ["7d", "7 day", "7-day", "seven day", "seven-day", "weekly", "week"]
                    .contains { text.contains($0) }
            }
        }
    }

    private static func isMonthly(_ window: QuotaWindow) -> Bool {
        let text = "\(window.id) \(window.label)".lowercased()
        return text.contains("month") || text.contains("月")
    }

    private func uniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return trimmed
        }
    }
}

public struct ProviderQuotaAverage: Equatable, Sendable {
    public let kind: ProviderQuotaMetricKind
    public let remainingPercent: Double?
    public let contributingAccounts: Int

    public init(kind: ProviderQuotaMetricKind, remainingPercent: Double?, contributingAccounts: Int) {
        self.kind = kind
        self.remainingPercent = remainingPercent
        self.contributingAccounts = contributingAccounts
    }
}

public extension ProviderPool {
    var quotaAverages: [ProviderQuotaAverage] {
        ProviderQuotaMetricKind.metrics(for: provider.key).map { kind in
            let values = accounts.compactMap { kind.remainingPercent(in: $0) }
            return ProviderQuotaAverage(
                kind: kind,
                remainingPercent: values.isEmpty ? nil : values.reduce(0, +) / Double(values.count),
                contributingAccounts: values.count
            )
        }
    }
}
