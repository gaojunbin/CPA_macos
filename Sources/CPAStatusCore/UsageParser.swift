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

        if let snapshot = parseAntigravityModelsPayload(root, now: now) {
            return snapshot
        }

        if let snapshot = parseAntigravityCreditsPayload(root, now: now) {
            return snapshot
        }

        if let snapshot = parseClaudePayload(root, now: now) {
            return snapshot
        }

        if let snapshot = parseKimiPayload(root, now: now) {
            return snapshot
        }

        if let snapshot = parseXAIPayload(root, now: now) {
            return snapshot
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

    private static let antigravityModelGroups: [AntigravityModelGroup] = [
        AntigravityModelGroup(id: "claude-gpt", label: "Claude/GPT", identifiers: ["claude-sonnet-4-6", "claude-opus-4-6-thinking", "gpt-oss-120b-medium"]),
        AntigravityModelGroup(id: "gemini-3-pro", label: "Gemini 3 Pro", identifiers: ["gemini-3-pro-high", "gemini-3-pro-low"]),
        AntigravityModelGroup(id: "gemini-3-1-pro-series", label: "Gemini 3.1 Pro Series", identifiers: ["gemini-3.1-pro-high", "gemini-3.1-pro-low"]),
        AntigravityModelGroup(id: "gemini-2-5-flash", label: "Gemini 2.5 Flash", identifiers: ["gemini-2.5-flash", "gemini-2.5-flash-thinking"]),
        AntigravityModelGroup(id: "gemini-2-5-flash-lite", label: "Gemini 2.5 Flash Lite", identifiers: ["gemini-2.5-flash-lite"]),
        AntigravityModelGroup(id: "gemini-2-5-cu", label: "Gemini 2.5 CU", identifiers: ["rev19-uic3-1p"]),
        AntigravityModelGroup(id: "gemini-3-flash", label: "Gemini 3 Flash", identifiers: ["gemini-3-flash"]),
        AntigravityModelGroup(id: "gemini-image", label: "gemini-3.1-flash-image", identifiers: ["gemini-3.1-flash-image"], labelFromModel: true)
    ]

    private static func parseAntigravityModelsPayload(_ root: [String: Any], now: Date) -> UsageSnapshot? {
        guard let models = firstDictionary(root["models"], root["modelQuotas"], root["model_quotas"]) else {
            return nil
        }

        let windows = buildAntigravityModelWindows(models, now: now)
        return UsageSnapshot(
            planType: nil,
            primary: nil,
            weekly: nil,
            additionalWindows: windows,
            rawStatus: windows.isEmpty ? "empty_models" : "models_available",
            fetchedAt: now
        )
    }

    private static func buildAntigravityModelWindows(_ models: [String: Any], now: Date) -> [QuotaWindow] {
        let groupByID = Dictionary(uniqueKeysWithValues: antigravityModelGroups.map { ($0.id, $0) })
        var windows: [QuotaWindow] = []

        @discardableResult
        func appendGroup(_ id: String, resetTimeOverride: String? = nil) -> AntigravityParsedGroup? {
            guard let group = groupByID[id],
                  let parsed = parseAntigravityModelGroup(group, models: models, resetTimeOverride: resetTimeOverride, now: now)
            else {
                return nil
            }
            windows.append(parsed.window)
            return parsed
        }

        appendGroup("claude-gpt")
        let gemini31Pro = appendGroup("gemini-3-1-pro-series")
        let gemini3Pro = appendGroup("gemini-3-pro")
        let imageResetTime = gemini31Pro?.resetTime ?? gemini3Pro?.resetTime
        appendGroup("gemini-2-5-flash")
        appendGroup("gemini-2-5-flash-lite")
        appendGroup("gemini-2-5-cu")
        appendGroup("gemini-3-flash")
        appendGroup("gemini-image", resetTimeOverride: imageResetTime)

        return windows
    }

    private static func parseAntigravityModelGroup(
        _ group: AntigravityModelGroup,
        models: [String: Any],
        resetTimeOverride: String?,
        now: Date
    ) -> AntigravityParsedGroup? {
        let entries = group.identifiers.compactMap { identifier -> AntigravityModelQuota? in
            guard let match = antigravityModelEntry(in: models, identifier: identifier) else {
                return nil
            }
            let quota = firstDictionary(match.entry["quotaInfo"], match.entry["quota_info"]) ?? [:]
            let remaining = fractionOrPercentFractionValue(firstValue(quota["remainingFraction"], quota["remaining_fraction"]))
                ?? percentNumberValue(firstValue(
                    quota["remainingPercent"],
                    quota["remaining_percent"],
                    quota["remainingPercentage"],
                    quota["remaining_percentage"]
                )).map { $0 / 100 }
                ?? fractionOrPercentFractionValue(quota["remaining"])
            let resetTime = firstString(quota["resetTime"], quota["reset_time"])
            let displayName = firstString(match.entry["displayName"], match.entry["display_name"])
            let effectiveRemaining = remaining ?? (resetTime == nil ? nil : 0)
            guard let effectiveRemaining else {
                return nil
            }
            return AntigravityModelQuota(
                id: match.id,
                remainingFraction: clamp(effectiveRemaining, min: 0, max: 1),
                resetTime: resetTime,
                displayName: displayName
            )
        }

        guard !entries.isEmpty else {
            return nil
        }

        let remainingFraction = entries.map(\.remainingFraction).min() ?? 0
        let percent = clamp(remainingFraction * 100, min: 0, max: 100)
        let resetTime = resetTimeOverride ?? entries.compactMap(\.resetTime).first
        let resetAt = resetTime.flatMap { dateValue($0, now: now) }
        let modelDisplayName = entries.compactMap(\.displayName).first
        let label = group.labelFromModel ? (modelDisplayName ?? group.label) : group.label

        let window = QuotaWindow(
            id: group.id,
            label: label,
            usedPercent: clamp(100 - percent, min: 0, max: 100),
            remainingPercent: percent,
            resetAfterSeconds: nil,
            resetAt: resetAt,
            displayValue: "\(Int(percent.rounded()))%",
            detailText: displayAntigravityReset(resetAt),
            isUsable: percent > 0
        )
        return AntigravityParsedGroup(window: window, resetTime: resetTime)
    }

    private static func antigravityModelEntry(
        in models: [String: Any],
        identifier: String
    ) -> (id: String, entry: [String: Any])? {
        if let entry = firstDictionary(models[identifier]) {
            return (identifier, entry)
        }

        let lowerIdentifier = identifier.lowercased()
        for (id, value) in models {
            guard let entry = value as? [String: Any] else {
                continue
            }
            let displayName = firstString(entry["displayName"], entry["display_name"])?.lowercased()
            if displayName == lowerIdentifier {
                return (id, entry)
            }
        }
        return nil
    }

    private static func displayAntigravityReset(_ date: Date?) -> String? {
        displayShortDate(date)
    }

    private static func displayShortDate(_ date: Date?) -> String? {
        guard let date else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private static func parseAntigravityCreditsPayload(_ root: [String: Any], now: Date) -> UsageSnapshot? {
        guard let paidTier = firstDictionary(
            root["paidTier"],
            root["paid_tier"],
            findFirstDictionary(named: "paidTier", in: root),
            findFirstDictionary(named: "paid_tier", in: root)
        ) else {
            return nil
        }

        let planType = firstString(
            paidTier["id"],
            paidTier["name"],
            root["tier_id"],
            root["tierId"]
        )
        let window = buildAntigravityCreditsWindow(paidTier)
        let status = window.isUsable == true ? "credits_available" : "credits_unavailable"
        return UsageSnapshot(
            planType: planType,
            primary: nil,
            weekly: nil,
            additionalWindows: [window],
            rawStatus: status,
            fetchedAt: now
        )
    }

    private static func buildAntigravityCreditsWindow(_ paidTier: [String: Any]) -> QuotaWindow {
        let credits = firstArray(paidTier["availableCredits"], paidTier["available_credits"]) ?? []
        let credit = credits
            .compactMap { $0 as? [String: Any] }
            .first { item in
                firstString(item["creditType"], item["credit_type"])?.caseInsensitiveCompare("GOOGLE_ONE_AI") == .orderedSame
            }

        let creditAmount = numberValue(firstValue(credit?["creditAmount"], credit?["credit_amount"])) ?? (credit == nil ? 0 : nil)
        let minimumAmount = numberValue(firstValue(credit?["minimumCreditAmountForUsage"], credit?["minimum_credit_amount_for_usage"]))
        let percent = antigravityCreditsProgress(creditAmount: creditAmount, minimumAmount: minimumAmount)
        let isUsable = antigravityCreditsUsable(creditAmount: creditAmount, minimumAmount: minimumAmount)
        return QuotaWindow(
            id: "antigravity-google-one-ai",
            label: "Google One AI",
            usedPercent: percent.map { clamp(100 - $0, min: 0, max: 100) },
            remainingPercent: percent,
            resetAfterSeconds: nil,
            resetAt: nil,
            displayValue: displayCredits(creditAmount),
            amountText: minimumAmount.map { "min \(displayCredits($0))" },
            detailText: nil,
            isUsable: isUsable
        )
    }

    private static func antigravityCreditsProgress(creditAmount: Double?, minimumAmount: Double?) -> Double? {
        guard let creditAmount else {
            return nil
        }
        guard let minimumAmount, minimumAmount > 0 else {
            return creditAmount > 0 ? 100 : 0
        }
        return clamp((creditAmount / minimumAmount) * 100, min: 0, max: 100)
    }

    private static func antigravityCreditsUsable(creditAmount: Double?, minimumAmount: Double?) -> Bool? {
        guard let creditAmount else {
            return nil
        }
        guard let minimumAmount, minimumAmount > 0 else {
            return creditAmount > 0
        }
        return creditAmount >= minimumAmount
    }

    private static let claudeWindows: [(key: String, id: String, label: String)] = [
        ("five_hour", "five-hour", "5 小时限额"),
        ("seven_day", "seven-day", "7 天限额"),
        ("seven_day_oauth_apps", "seven-day-oauth-apps", "7 天 OAuth 应用"),
        ("seven_day_opus", "seven-day-opus", "7 天 Opus"),
        ("seven_day_sonnet", "seven-day-sonnet", "7 天 Sonnet"),
        ("seven_day_cowork", "seven-day-cowork", "7 天 Cowork"),
        ("iguana_necktie", "iguana-necktie", "Iguana Necktie")
    ]

    private static func parseClaudePayload(_ root: [String: Any], now: Date) -> UsageSnapshot? {
        let provider = firstString(root["_provider"])?.lowercased()
        let usage = provider == "claude" ? firstDictionary(root["usage"]) ?? [:] : root

        var windows: [QuotaWindow] = []
        for definition in claudeWindows {
            guard let raw = firstDictionary(usage[definition.key]),
                  raw.keys.contains("utilization") || raw.keys.contains("resets_at") || raw.keys.contains("resetsAt")
            else {
                continue
            }

            let used = numberValue(raw["utilization"]).map { clamp($0, min: 0, max: 100) }
            let resetAt = dateValue(firstValue(raw["resets_at"], raw["resetsAt"]), now: now)
            windows.append(QuotaWindow(
                id: "claude-\(definition.id)",
                label: definition.label,
                usedPercent: used,
                remainingPercent: used.map { clamp(100 - $0, min: 0, max: 100) },
                resetAfterSeconds: nil,
                resetAt: resetAt,
                displayValue: used.map { displayPercent(clamp(100 - $0, min: 0, max: 100)) },
                detailText: displayShortDate(resetAt),
                isUsable: used.map { $0 < 100 }
            ))
        }

        guard !windows.isEmpty || provider == "claude" else {
            return nil
        }

        if let extraUsage = firstDictionary(usage["extra_usage"], usage["extraUsage"]),
           boolValue(firstValue(extraUsage["is_enabled"], extraUsage["isEnabled"])) == true {
            let used = centsValue(firstValue(extraUsage["used_credits"], extraUsage["usedCredits"]))
            let limit = centsValue(firstValue(extraUsage["monthly_limit"], extraUsage["monthlyLimit"]))
            windows.append(QuotaWindow(
                id: "claude-extra-usage",
                label: "额外用量",
                usedPercent: nil,
                remainingPercent: nil,
                resetAfterSeconds: nil,
                resetAt: nil,
                displayValue: "--",
                amountText: extraUsageAmount(usedCents: used, limitCents: limit),
                detailText: nil,
                isUsable: nil
            ))
        }

        let profile = firstDictionary(root["profile"])
        return UsageSnapshot(
            planType: claudePlanType(profile),
            primary: nil,
            weekly: nil,
            additionalWindows: windows,
            rawStatus: windows.isEmpty ? "empty_windows" : "usage_available",
            fetchedAt: now
        )
    }

    private static func claudePlanType(_ profile: [String: Any]?) -> String? {
        guard let profile else {
            return nil
        }
        let account = firstDictionary(profile["account"]) ?? [:]
        if boolValue(account["has_claude_max"]) == true {
            return "Max"
        }
        if boolValue(account["has_claude_pro"]) == true {
            return "专业版"
        }
        let organization = firstDictionary(profile["organization"]) ?? [:]
        let organizationType = firstString(organization["organization_type"])?.lowercased()
        let subscriptionStatus = firstString(organization["subscription_status"])?.lowercased()
        if organizationType == "claude_team", subscriptionStatus == "active" {
            return "团队版"
        }
        if boolValue(account["has_claude_max"]) == false,
           boolValue(account["has_claude_pro"]) == false {
            return "免费版"
        }
        return nil
    }

    private static func extraUsageAmount(usedCents: Double?, limitCents: Double?) -> String? {
        guard usedCents != nil || limitCents != nil else {
            return nil
        }
        let used = displayCurrency(cents: usedCents)
        guard limitCents != nil else {
            return used
        }
        return "\(used) / \(displayCurrency(cents: limitCents))"
    }

    private static func parseKimiPayload(_ root: [String: Any], now: Date) -> UsageSnapshot? {
        guard root["usage"] != nil || root["limits"] != nil else {
            return nil
        }

        var windows: [QuotaWindow] = []
        if let usage = firstDictionary(root["usage"]),
           let window = buildKimiWindow(id: "kimi-summary", raw: usage, fallbackLabel: "周限额", now: now) {
            windows.append(window)
        }

        if let limits = firstArray(root["limits"]) {
            for (index, item) in limits.enumerated() {
                guard let item = item as? [String: Any] else {
                    continue
                }
                let raw = firstDictionary(item["detail"]) ?? item
                let label = kimiLimitLabel(item: item, raw: raw, index: index)
                if let window = buildKimiWindow(id: "kimi-limit-\(index)", raw: raw, fallbackLabel: label, now: now) {
                    windows.append(window)
                }
            }
        }

        return UsageSnapshot(
            planType: nil,
            primary: nil,
            weekly: nil,
            additionalWindows: windows,
            rawStatus: windows.isEmpty ? "empty_data" : "usage_available",
            fetchedAt: now
        )
    }

    private static func buildKimiWindow(id: String, raw: [String: Any], fallbackLabel: String, now: Date) -> QuotaWindow? {
        let limit = integerValue(raw["limit"])
        var used = integerValue(raw["used"])
        if used == nil, let remaining = integerValue(raw["remaining"]), let limit {
            used = Swift.max(0, limit - remaining)
        }
        guard used != nil || limit != nil else {
            return nil
        }

        let usedValue = Double(used ?? 0)
        let limitValue = Double(limit ?? 0)
        let usedPercent: Double?
        let remainingPercent: Double?
        if limitValue > 0 {
            usedPercent = clamp((usedValue / limitValue) * 100, min: 0, max: 100)
            remainingPercent = clamp(((limitValue - usedValue) / limitValue) * 100, min: 0, max: 100)
        } else if usedValue > 0 {
            usedPercent = 100
            remainingPercent = 0
        } else {
            usedPercent = nil
            remainingPercent = nil
        }

        let label = firstString(raw["name"], raw["title"], raw["scope"]) ?? fallbackLabel
        return QuotaWindow(
            id: id,
            label: label,
            usedPercent: usedPercent,
            remainingPercent: remainingPercent,
            resetAfterSeconds: nil,
            resetAt: nil,
            displayValue: displayPercent(remainingPercent),
            amountText: limitValue > 0 ? "\(Int(usedValue)) / \(Int(limitValue))" : nil,
            detailText: kimiResetHint(raw, now: now),
            isUsable: remainingPercent.map { $0 > 0 }
        )
    }

    private static func kimiLimitLabel(item: [String: Any], raw: [String: Any], index: Int) -> String {
        if let label = firstString(item["name"], item["title"], item["scope"], raw["name"], raw["title"], raw["scope"]) {
            return label
        }
        let window = firstDictionary(item["window"]) ?? [:]
        let duration = integerValue(firstValue(window["duration"], item["duration"], raw["duration"]))
        let unit = firstString(firstValue(window["timeUnit"], window["time_unit"], item["timeUnit"], raw["timeUnit"]))
        if let duration, duration > 0 {
            return "\(displayKimiDuration(duration, unit: unit))限额"
        }
        return "限额 #\(index + 1)"
    }

    private static func displayKimiDuration(_ duration: Int, unit: String?) -> String {
        switch unit?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "MINUTES":
            return duration % 60 == 0 ? "\(duration / 60)小时" : "\(duration)分钟"
        case "HOURS":
            return "\(duration)小时"
        case "DAYS":
            return "\(duration)天"
        default:
            return "\(duration)秒"
        }
    }

    private static func kimiResetHint(_ raw: [String: Any], now: Date) -> String? {
        for key in ["reset_at", "resetAt", "reset_time", "resetTime"] {
            if let resetAt = dateValue(raw[key], now: now) {
                let remaining = resetAt.timeIntervalSince(now)
                return remaining > 0 ? "\(displayDuration(seconds: remaining))后重置" : "已重置"
            }
        }
        for key in ["reset_in", "resetIn", "ttl"] {
            if let seconds = numberValue(raw[key]), seconds > 0 {
                return "\(displayDuration(seconds: seconds))后重置"
            }
        }
        return nil
    }

    private static func parseXAIPayload(_ root: [String: Any], now: Date) -> UsageSnapshot? {
        guard let config = firstDictionary(root["config"]) else {
            return nil
        }
        let monthlyLimit = centsValue(firstValue(config["monthlyLimit"], config["monthly_limit"]))
        let used = centsValue(config["used"])
        let onDemandCap = centsValue(firstValue(config["onDemandCap"], config["on_demand_cap"]))
        let billingPeriodEnd = firstString(firstValue(config["billingPeriodEnd"], config["billing_period_end"]))
        guard monthlyLimit != nil || used != nil || onDemandCap != nil || billingPeriodEnd != nil else {
            return nil
        }

        var windows: [QuotaWindow] = []
        let payAsYouGoEnabled = (onDemandCap ?? 0) > 0
        windows.append(QuotaWindow(
            id: "xai-pay-as-you-go",
            label: "按量付费",
            usedPercent: nil,
            remainingPercent: nil,
            resetAfterSeconds: nil,
            resetAt: nil,
            displayValue: payAsYouGoEnabled ? "已启用" : "未启用",
            amountText: payAsYouGoEnabled ? "封顶 \(displayCurrency(cents: onDemandCap))" : nil,
            detailText: nil,
            isUsable: nil
        ))

        let usedPercent: Double?
        let remainingPercent: Double?
        if let monthlyLimit, monthlyLimit > 0, let used {
            usedPercent = clamp((used / monthlyLimit) * 100, min: 0, max: 100)
            remainingPercent = clamp(100 - (usedPercent ?? 0), min: 0, max: 100)
        } else {
            usedPercent = nil
            remainingPercent = nil
        }
        let resetAt = billingPeriodEnd.flatMap { dateValue($0, now: now) }
        windows.append(QuotaWindow(
            id: "xai-monthly-credits",
            label: "月度积分",
            usedPercent: usedPercent,
            remainingPercent: remainingPercent,
            resetAfterSeconds: nil,
            resetAt: resetAt,
            displayValue: displayPercent(remainingPercent),
            amountText: xaiAmount(usedCents: used, limitCents: monthlyLimit),
            detailText: displayShortDate(resetAt),
            isUsable: remainingPercent.map { $0 > 0 }
        ))

        return UsageSnapshot(
            planType: nil,
            primary: nil,
            weekly: nil,
            additionalWindows: windows,
            rawStatus: "billing_available",
            fetchedAt: now
        )
    }

    private static func centsValue(_ value: Any?) -> Double? {
        if let dictionary = value as? [String: Any] {
            return centsValue(dictionary["val"])
        }
        if let currency = currencyCentsValue(value) {
            return currency
        }
        return numberValue(value)
    }

    private static func xaiAmount(usedCents: Double?, limitCents: Double?) -> String? {
        guard usedCents != nil || limitCents != nil else {
            return nil
        }
        let used = displayCurrency(cents: usedCents)
        guard limitCents != nil else {
            return used
        }
        return "\(used) / \(displayCurrency(cents: limitCents))"
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

        var used = percentNumberValue(firstValue(raw["used_percent"], raw["usedPercent"]))
        var remaining = percentNumberValue(firstValue(
            raw["remaining_percent"],
            raw["remainingPercent"],
            raw["remaining_percentage"],
            raw["remainingPercentage"]
        ))
        let resetAfter = numberValue(firstValue(raw["reset_after_seconds"], raw["resetAfterSeconds"]))
        let resetAt = dateValue(firstValue(raw["reset_at"], raw["resetAt"]), now: now)
        if used == nil, remaining == nil, exhaustedHint, resetAfter != nil || resetAt != nil {
            used = 100
        }
        if used == nil, let remaining {
            used = 100 - remaining
        }
        if remaining == nil, let used {
            remaining = 100 - used
        }
        let normalizedUsed = used.map { clamp($0, min: 0, max: 100) }
        let normalizedRemaining = remaining.map { clamp($0, min: 0, max: 100) }
        return QuotaWindow(
            id: id,
            label: label,
            usedPercent: normalizedUsed,
            remainingPercent: normalizedRemaining,
            resetAfterSeconds: resetAfter,
            resetAt: resetAt
        )
    }

    private static func parseGeneric(_ json: Any, now: Date) -> UsageSnapshot? {
        let pairs = flatten(json)
        let used = firstPercentInPairs(pairs, matching: [
            "used_percent", "usedpercent", "usage_percent", "usagepercent"
        ])
        let remaining = firstPercentInPairs(pairs, matching: [
            "remaining_percent", "remainingpercent", "remaining_percentage", "remainingpercentage"
        ])
        let resetSeconds = firstNumberInPairs(pairs, matching: [
            "reset_after_seconds", "resetafterseconds", "retry_after", "retryafter"
        ])
        let resetAt = firstValueInPairs(pairs, matching: ["reset_at", "resetat", "reset_time", "resettime"])
            .flatMap { dateValue($0, now: now) }
        let status = firstStringInPairs(pairs, matching: ["status", "code", "message", "error"])
        let lowerStatus = status?.lowercased() ?? ""
        let limitSignal = ["rate limit", "quota", "usage limit", "insufficient_quota", "limit_reached"].contains { lowerStatus.contains($0) }

        var primaryUsed = used
        var primaryRemaining = remaining
        if primaryUsed == nil, primaryRemaining == nil, limitSignal, resetSeconds != nil || resetAt != nil {
            primaryUsed = 100
        }
        if primaryUsed == nil, let primaryRemaining {
            primaryUsed = 100 - primaryRemaining
        }
        if primaryRemaining == nil, let primaryUsed {
            primaryRemaining = 100 - primaryUsed
        }

        guard primaryUsed != nil || primaryRemaining != nil || resetSeconds != nil || resetAt != nil else {
            return nil
        }

        let normalizedUsed = primaryUsed.map { clamp($0, min: 0, max: 100) }
        let normalizedRemaining = primaryRemaining.map { clamp($0, min: 0, max: 100) }
        let window = QuotaWindow(
            id: "generic",
            label: "quota",
            usedPercent: normalizedUsed,
            remainingPercent: normalizedRemaining,
            resetAfterSeconds: resetSeconds,
            resetAt: resetAt
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

    private static func firstPercentInPairs(_ pairs: [(String, Any)], matching keys: [String]) -> Double? {
        for key in keys {
            if let match = pairs.first(where: { path, _ in pathComponent(path, matches: key) }),
               let number = percentNumberValue(match.1) {
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

    private static func firstValueInPairs(_ pairs: [(String, Any)], matching keys: [String]) -> Any? {
        for key in keys {
            if let match = pairs.first(where: { path, _ in pathComponent(path, matches: key) }) {
                return match.1
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

private func displayCurrency(cents: Double?) -> String {
    guard let cents, cents.isFinite else {
        return "--"
    }
    return String(format: "$%.2f", cents / 100)
}

private struct AntigravityModelGroup {
    let id: String
    let label: String
    let identifiers: [String]
    let labelFromModel: Bool

    init(id: String, label: String, identifiers: [String], labelFromModel: Bool = false) {
        self.id = id
        self.label = label
        self.identifiers = identifiers
        self.labelFromModel = labelFromModel
    }
}

private struct AntigravityModelQuota {
    let id: String
    let remainingFraction: Double
    let resetTime: String?
    let displayName: String?
}

private struct AntigravityParsedGroup {
    let window: QuotaWindow
    let resetTime: String?
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
            if isBooleanNumber(number) {
                return number.boolValue ? "true" : "false"
            }
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

func firstArray(_ values: Any?...) -> [Any]? {
    for value in values {
        if let array = value as? [Any] {
            return array
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
    if let number = value as? NSNumber, isBooleanNumber(number) {
        return nil
    }
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
        guard !isBooleanNumber(value) else {
            return nil
        }
        let double = value.doubleValue
        return double.isFinite ? double : nil
    case let value as String:
        guard let numeric = normalizedNumericString(value) else {
            return nil
        }
        return Double(numeric)
    default:
        return nil
    }
}

private func normalizedNumericString(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return nil
    }
    guard !trimmed.hasSuffix("%") else {
        return nil
    }
    let normalized = trimmed.replacingOccurrences(of: ",", with: "")
    guard isPlainDecimalString(normalized) else {
        return nil
    }
    return normalized
}

private func isPlainDecimalString(_ value: String) -> Bool {
    guard !value.isEmpty else {
        return false
    }

    var index = value.startIndex
    if value[index] == "+" || value[index] == "-" {
        index = value.index(after: index)
        guard index < value.endIndex else {
            return false
        }
    }

    var hasDigit = false
    var hasDecimalSeparator = false
    while index < value.endIndex {
        let character = value[index]
        if character == "." {
            guard !hasDecimalSeparator else {
                return false
            }
            hasDecimalSeparator = true
        } else if character.isNumber {
            hasDigit = true
        } else {
            return false
        }
        index = value.index(after: index)
    }
    return hasDigit
}

private func currencyCentsValue(_ value: Any?) -> Double? {
    guard let string = value as? String else {
        return nil
    }
    var trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    let currencySymbols = CharacterSet(charactersIn: "$¥￥€£")
    guard let first = trimmed.unicodeScalars.first, currencySymbols.contains(first) else {
        return nil
    }
    while let first = trimmed.unicodeScalars.first, currencySymbols.contains(first) {
        trimmed.removeFirst()
        trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let number = normalizedNumericString(trimmed).flatMap(Double.init), number.isFinite else {
        return nil
    }
    return number * 100
}

func percentNumberValue(_ value: Any?) -> Double? {
    if let string = value as? String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("%") {
            let raw = String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            if let number = Double(raw), number.isFinite {
                return number
            }
        }
    }
    return numberValue(value)
}

func integerValue(_ value: Any?) -> Int? {
    guard let number = numberValue(value) else {
        return nil
    }
    return Int(number.rounded(.down))
}

func fractionValue(_ value: Any?) -> Double? {
    if let number = numberValue(value) {
        return number
    }
    guard let string = firstString(value) else {
        return nil
    }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasSuffix("%") {
        let raw = String(trimmed.dropLast())
        if let percent = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return percent / 100
        }
    }
    return nil
}

func fractionOrPercentFractionValue(_ value: Any?) -> Double? {
    guard let fraction = fractionValue(value), fraction.isFinite else {
        return nil
    }
    if fraction > 1, fraction <= 100 {
        return fraction / 100
    }
    return fraction
}

func boolValue(_ value: Any?) -> Bool? {
    switch value {
    case let value as NSNumber:
        if isBooleanNumber(value) {
            return value.boolValue
        }
        if value.doubleValue == 1 {
            return true
        }
        if value.doubleValue == 0 {
            return false
        }
        return nil
    case let value as Bool:
        return value
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

private func isBooleanNumber(_ value: NSNumber) -> Bool {
    CFGetTypeID(value) == CFBooleanGetTypeID()
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
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.replacingOccurrences(
            of: #"\.(\d{6})\d+(Z|[+-]\d{2}:?\d{2})$"#,
            with: ".$1$2",
            options: .regularExpression
        )
        if let date = ISO8601DateParsers.fractional.date(from: normalized) ?? ISO8601DateParsers.standard.date(from: normalized) {
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
