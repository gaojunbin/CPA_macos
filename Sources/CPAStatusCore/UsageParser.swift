import Foundation

public enum UsageParser {
    public static func parse(_ body: String, now: Date = Date()) -> UsageSnapshot? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data)
        else {
            return nil
        }

        guard let root = json as? [String: Any] else {
            return parseGeneric(json, now: now)
        }

        if let snapshot = parseWhamPayload(root, now: now) {
            return snapshot
        }

        return parseGeneric(json, now: now)
    }

    private static func parseWhamPayload(_ root: [String: Any], now: Date) -> UsageSnapshot? {
        guard let rateLimit = firstDictionary(
            root["rate_limit"],
            root["rateLimit"],
            findFirstDictionary(named: "rate_limit", in: root),
            findFirstDictionary(named: "rateLimit", in: root)
        ) else {
            return nil
        }

        let planType = firstString(
            root["plan_type"],
            root["planType"],
            nested(root, "account_plan", "plan_type"),
            nested(root, "accountPlan", "planType")
        )
        let limitReached = boolValue(firstValue(rateLimit["limit_reached"], rateLimit["limitReached"]))
        let allowed = boolValue(firstValue(rateLimit["allowed"]))
        let exhaustedHint = limitReached == true || allowed == false
        let primaryRaw = firstDictionary(rateLimit["primary_window"], rateLimit["primaryWindow"])
        let secondaryRaw = firstDictionary(rateLimit["secondary_window"], rateLimit["secondaryWindow"])
        let windows = pickPrimaryAndWeekly(primaryRaw, secondaryRaw, exhaustedHint: exhaustedHint, now: now)
        let additional = parseAdditionalWindows(root, now: now)
        let status = firstString(root["status"], root["code"], nested(root, "error", "code"))

        let snapshot = UsageSnapshot(
            planType: planType,
            primary: windows.primary,
            weekly: windows.weekly,
            additionalWindows: additional,
            rawStatus: status,
            fetchedAt: now
        )
        return snapshot.hasQuotaSignal ? snapshot : nil
    }

    private static func pickPrimaryAndWeekly(
        _ first: [String: Any]?,
        _ second: [String: Any]?,
        exhaustedHint: Bool,
        now: Date
    ) -> (primary: QuotaWindow?, weekly: QuotaWindow?) {
        let candidates = [first, second].compactMap { $0 }
        var fiveHour: [String: Any]?
        var weekly: [String: Any]?

        for candidate in candidates {
            let duration = numberValue(firstValue(candidate["limit_window_seconds"], candidate["limitWindowSeconds"]))
            if duration == 18_000, fiveHour == nil {
                fiveHour = candidate
            } else if duration == 604_800, weekly == nil {
                weekly = candidate
            }
        }

        if fiveHour == nil {
            fiveHour = first
        }
        if weekly == nil {
            weekly = second
        }

        return (
            primary: buildWindow(id: "code-5h", label: "5h", raw: fiveHour, exhaustedHint: exhaustedHint, now: now),
            weekly: buildWindow(id: "code-7d", label: "7d", raw: weekly, exhaustedHint: exhaustedHint, now: now)
        )
    }

    private static func parseAdditionalWindows(_ root: [String: Any], now: Date) -> [QuotaWindow] {
        guard let items = firstValue(root["additional_rate_limits"], root["additionalRateLimits"]) as? [Any] else {
            return []
        }

        var result: [QuotaWindow] = []
        for (index, item) in items.enumerated() {
            guard let itemDict = item as? [String: Any],
                  let rateLimit = firstDictionary(itemDict["rate_limit"], itemDict["rateLimit"])
            else {
                continue
            }
            let name = firstString(itemDict["limit_name"], itemDict["limitName"], itemDict["metered_feature"], itemDict["meteredFeature"]) ?? "extra-\(index + 1)"
            let exhaustedHint = boolValue(firstValue(rateLimit["limit_reached"], rateLimit["limitReached"])) == true ||
                boolValue(firstValue(rateLimit["allowed"])) == false
            if let primary = buildWindow(
                id: "\(name)-5h",
                label: "\(name) 5h",
                raw: firstDictionary(rateLimit["primary_window"], rateLimit["primaryWindow"]),
                exhaustedHint: exhaustedHint,
                now: now
            ) {
                result.append(primary)
            }
            if let weekly = buildWindow(
                id: "\(name)-7d",
                label: "\(name) 7d",
                raw: firstDictionary(rateLimit["secondary_window"], rateLimit["secondaryWindow"]),
                exhaustedHint: exhaustedHint,
                now: now
            ) {
                result.append(weekly)
            }
        }
        return result
    }

    private static func buildWindow(
        id: String,
        label: String,
        raw: [String: Any]?,
        exhaustedHint: Bool,
        now: Date
    ) -> QuotaWindow? {
        guard let raw else {
            return nil
        }

        var used = numberValue(firstValue(raw["used_percent"], raw["usedPercent"]))
        let resetAfter = numberValue(firstValue(raw["reset_after_seconds"], raw["resetAfterSeconds"]))
        let resetAt = dateValue(firstValue(raw["reset_at"], raw["resetAt"]), now: now)
        if used == nil, exhaustedHint, resetAfter != nil || resetAt != nil {
            used = 100
        }
        let normalizedUsed = used.map { clamp($0, min: 0, max: 100) }
        let remaining = normalizedUsed.map { clamp(100 - $0, min: 0, max: 100) }
        return QuotaWindow(
            id: id,
            label: label,
            usedPercent: normalizedUsed,
            remainingPercent: remaining,
            resetAfterSeconds: resetAfter,
            resetAt: resetAt
        )
    }

    private static func parseGeneric(_ json: Any, now: Date) -> UsageSnapshot? {
        let pairs = flatten(json)
        let used = firstNumberInPairs(pairs, matching: [
            "used_percent", "usedpercent", "usage_percent", "usagepercent"
        ])
        let resetSeconds = firstNumberInPairs(pairs, matching: [
            "reset_after_seconds", "resetafterseconds", "retry_after", "retryafter"
        ])
        let resetAtRaw = firstNumberInPairs(pairs, matching: ["reset_at", "resetat", "reset_time", "resettime"])
        let status = firstStringInPairs(pairs, matching: ["status", "code", "message", "error"])
        let lowerStatus = status?.lowercased() ?? ""
        let limitSignal = ["rate limit", "quota", "usage limit", "insufficient_quota", "limit_reached"].contains { lowerStatus.contains($0) }

        var primaryUsed = used
        if primaryUsed == nil, limitSignal, resetSeconds != nil || resetAtRaw != nil {
            primaryUsed = 100
        }

        guard primaryUsed != nil || resetSeconds != nil || resetAtRaw != nil else {
            return nil
        }

        let normalizedUsed = primaryUsed.map { clamp($0, min: 0, max: 100) }
        let window = QuotaWindow(
            id: "generic",
            label: "quota",
            usedPercent: normalizedUsed,
            remainingPercent: normalizedUsed.map { clamp(100 - $0, min: 0, max: 100) },
            resetAfterSeconds: resetSeconds,
            resetAt: resetAtRaw.flatMap { dateValue($0, now: now) }
        )
        return UsageSnapshot(
            planType: firstStringInPairs(pairs, matching: ["plan_type", "plantype", "plan"]),
            primary: window,
            weekly: nil,
            rawStatus: status,
            fetchedAt: now
        )
    }

    private static func flatten(_ value: Any, path: String = "") -> [(String, Any)] {
        if let dictionary = value as? [String: Any] {
            return dictionary.flatMap { key, nested in
                flatten(nested, path: path.isEmpty ? key : "\(path).\(key)")
            }
        }
        if let array = value as? [Any] {
            return array.enumerated().flatMap { index, nested in
                flatten(nested, path: "\(path)[\(index)]")
            }
        }
        return [(path.lowercased(), value)]
    }

    private static func firstNumberInPairs(_ pairs: [(String, Any)], matching keys: [String]) -> Double? {
        for key in keys {
            if let match = pairs.first(where: { path, _ in pathComponent(path, matches: key) }),
               let number = numberValue(match.1) {
                return number
            }
        }
        return nil
    }

    private static func firstStringInPairs(_ pairs: [(String, Any)], matching keys: [String]) -> String? {
        for key in keys {
            if let match = pairs.first(where: { path, _ in pathComponent(path, matches: key) }),
               let string = firstString(match.1) {
                return string
            }
        }
        return nil
    }

    private static func pathComponent(_ path: String, matches key: String) -> Bool {
        let normalizedKey = key.lowercased()
        let components = path
            .replacingOccurrences(of: "[", with: ".")
            .replacingOccurrences(of: "]", with: "")
            .split(separator: ".")
            .map { String($0).lowercased() }
        return components.contains { component in
            component == normalizedKey || component.replacingOccurrences(of: "_", with: "") == normalizedKey
        }
    }
}

func firstValue(_ values: Any?...) -> Any? {
    for value in values {
        if let value, !(value is NSNull) {
            return value
        }
    }
    return nil
}

func nested(_ dictionary: [String: Any], _ first: String, _ second: String) -> Any? {
    guard let nested = dictionary[first] as? [String: Any] else {
        return nil
    }
    return nested[second]
}

func firstString(_ values: Any?...) -> String? {
    for value in values {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        } else if let number = value as? NSNumber {
            return number.stringValue
        }
    }
    return nil
}

func firstDictionary(_ values: Any?...) -> [String: Any]? {
    for value in values {
        if let dictionary = value as? [String: Any] {
            return dictionary
        }
    }
    return nil
}

func findFirstDictionary(named target: String, in value: Any) -> [String: Any]? {
    if let dictionary = value as? [String: Any] {
        for (key, nestedValue) in dictionary {
            if key == target, let result = nestedValue as? [String: Any] {
                return result
            }
            if let result = findFirstDictionary(named: target, in: nestedValue) {
                return result
            }
        }
    } else if let array = value as? [Any] {
        for nestedValue in array {
            if let result = findFirstDictionary(named: target, in: nestedValue) {
                return result
            }
        }
    }
    return nil
}

func numberValue(_ value: Any?) -> Double? {
    switch value {
    case let value as Double:
        return value.isFinite ? value : nil
    case let value as Float:
        let double = Double(value)
        return double.isFinite ? double : nil
    case let value as Int:
        return Double(value)
    case let value as Int64:
        return Double(value)
    case let value as NSNumber:
        let double = value.doubleValue
        return double.isFinite ? double : nil
    case let value as String:
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(trimmed)
    default:
        return nil
    }
}

func boolValue(_ value: Any?) -> Bool? {
    switch value {
    case let value as Bool:
        return value
    case let value as NSNumber:
        return value.boolValue
    case let value as String:
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    default:
        return nil
    }
}

func dateValue(_ value: Any?, now: Date) -> Date? {
    if let seconds = numberValue(value) {
        if seconds > 4_000_000_000 {
            return Date(timeIntervalSince1970: seconds / 1_000)
        }
        return Date(timeIntervalSince1970: seconds)
    }
    if let string = firstString(value) {
        if let seconds = Double(string) {
            return dateValue(seconds, now: now)
        }
        if let date = ISO8601DateParsers.fractional.date(from: string) ?? ISO8601DateParsers.standard.date(from: string) {
            return date
        }
    }
    return nil
}

func clamp(_ value: Double, min: Double, max: Double) -> Double {
    Swift.max(min, Swift.min(max, value))
}

private enum ISO8601DateParsers {
    static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let standard: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
