import Foundation

/// Only the public quota observation is retained; refresh responses may also contain credentials.
public struct DevinQuota: Decodable, Equatable, Sendable {
    public let observedAt: Date?
    public let plan: String?
    public let planStart: Date?
    public let planEnd: Date?
    private let dailyRemaining: Double?
    private let weeklyRemaining: Double?
    private let dailyReset: Date?
    private let weeklyReset: Date?

    private enum CodingKeys: String, CodingKey { case signals, observedAt = "observed_at" }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let signals = (try? container.decode([String: String].self, forKey: .signals)) ?? [:]
        observedAt = Self.date(try? container.decode(String.self, forKey: .observedAt))
        plan = signals["plan"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        planStart = Self.date(signals["plan_start"])
        planEnd = Self.date(signals["plan_end"])
        dailyRemaining = Self.percent(signals["daily_quota_remaining_percent"])
        weeklyRemaining = Self.percent(signals["weekly_quota_remaining_percent"])
        dailyReset = Self.date(signals["daily_quota_reset_at"])
        weeklyReset = Self.date(signals["weekly_quota_reset_at"])
    }

    public func usage(now: Date = Date()) -> UsageSnapshot {
        UsageSnapshot(
            planType: plan,
            primary: window(id: "devin-daily", label: "每日额度", remaining: dailyRemaining, reset: dailyReset, now: now),
            weekly: window(id: "devin-weekly", label: "每周额度", remaining: weeklyRemaining, reset: weeklyReset, now: now),
            rawStatus: "server_observation",
            fetchedAt: observedAt ?? now,
            observation: .server(observedAt)
        )
    }

    private func window(id: String, label: String, remaining: Double?, reset: Date?, now: Date) -> QuotaWindow? {
        guard let remaining else { return nil }
        if let reset, reset <= now { return nil }
        return QuotaWindow(
            id: id, label: label, usedPercent: 100 - remaining, remainingPercent: remaining,
            resetAfterSeconds: nil, resetAt: reset
        )
    }

    private static func percent(_ value: String?) -> Double? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = trimmed.hasSuffix("%") ? String(trimmed.dropLast()) : trimmed
        guard let result = Double(number), result.isFinite, (0...100).contains(result) else { return nil }
        return result
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        return date.flatMap { $0.timeIntervalSince1970 > 0 ? $0 : nil }
    }
}

public enum QuotaObservation: Equatable, Sendable {
    case live
    case server(Date?)
}

struct DevinRefreshResponse: Decodable, Sendable {
    let ok: Bool
    let auth: RefreshedAccount

    struct RefreshedAccount: Decodable, Sendable {
        let quota: DevinQuota
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
