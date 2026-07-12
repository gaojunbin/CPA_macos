import XCTest
@testable import CPAStatusCore

final class DashboardMetricsTests: XCTestCase {
    func testHealthRatiosOnlyReflectConnectionHealth() {
        let healthyButEmpty = account(
            id: "healthy-empty",
            provider: "codex",
            primary: window(id: "code-5h", label: "5h", remaining: 0, usable: false)
        )
        let configChannel = account(id: "config", provider: "codex-api-key")
        let failed = account(id: "failed", provider: "claude", error: "HTTP 401")
        let disabled = account(id: "disabled", provider: "xai", disabled: true)
        let codexPool = ProviderPool(
            provider: ProviderCatalog.info(for: "codex"),
            accounts: [healthyButEmpty]
        )
        let configPool = ProviderPool(
            provider: ProviderCatalog.info(for: "codex-api-key"),
            accounts: [configChannel]
        )
        let failedPool = ProviderPool(
            provider: ProviderCatalog.info(for: "claude"),
            accounts: [failed]
        )
        let disabledPool = ProviderPool(
            provider: ProviderCatalog.info(for: "xai"),
            accounts: [disabled]
        )

        let snapshot = PoolSnapshot(providers: [codexPool, configPool, failedPool, disabledPool])
        XCTAssertEqual(snapshot.healthRatio, AccountHealthRatio(healthy: 2, total: 4))
        XCTAssertEqual(codexPool.healthRatio.displayValue, "1/1")
        XCTAssertTrue(healthyButEmpty.isHealthy, "Low or exhausted quota is not a connection-health warning")
    }

    func testCodexPoolAveragesFiveHourAndSevenDayAcrossAccounts() throws {
        let first = account(
            id: "codex-a",
            provider: "codex",
            primary: window(id: "code-5h", label: "5h", remaining: 80),
            weekly: window(id: "code-7d", label: "7d", remaining: 60)
        )
        let second = account(
            id: "codex-b",
            provider: "codex",
            primary: window(id: "code-5h", label: "5h", remaining: 40),
            weekly: window(id: "code-7d", label: "7d", remaining: 20)
        )
        let monthlyOnly = account(
            id: "codex-monthly",
            provider: "codex",
            weekly: window(id: "code-monthly", label: "月度限额", remaining: 90)
        )
        let pool = ProviderPool(
            provider: ProviderCatalog.info(for: "codex"),
            accounts: [first, second, monthlyOnly]
        )

        let fiveHour = try XCTUnwrap(pool.quotaAverages.first { $0.kind == .codexFiveHour })
        let sevenDay = try XCTUnwrap(pool.quotaAverages.first { $0.kind == .codexSevenDay })
        XCTAssertEqual(fiveHour.remainingPercent, 60)
        XCTAssertEqual(fiveHour.contributingAccounts, 2)
        XCTAssertEqual(sevenDay.remainingPercent, 40)
        XCTAssertEqual(sevenDay.contributingAccounts, 2)
    }

    func testAntigravityAveragesEachAccountBeforeThePool() throws {
        let first = account(
            id: "ag-a",
            provider: "antigravity",
            additional: [
                window(id: "antigravity-gemini-pro-5h", label: "Gemini Pro · 5 hour", remaining: 80),
                window(id: "antigravity-gemini-flash-5h", label: "Gemini Flash · 5h", remaining: 60),
                window(id: "antigravity-gemini-weekly", label: "Gemini · Weekly", remaining: 50),
                window(id: "antigravity-claude-gpt-5h", label: "Claude and GPT Models · 5 hour", remaining: 40),
                window(id: "antigravity-claude-gpt-weekly", label: "Claude and GPT Models · Weekly", remaining: 30)
            ]
        )
        let second = account(
            id: "ag-b",
            provider: "antigravity",
            additional: [
                window(id: "antigravity-gemini-pro-5h", label: "Gemini · 5h", remaining: 100),
                window(id: "antigravity-claude-gpt-5h", label: "Claude/GPT · 5h", remaining: 80),
                window(id: "antigravity-claude-gpt-weekly", label: "Claude/GPT · Weekly", remaining: 70)
            ]
        )
        let pool = ProviderPool(
            provider: ProviderCatalog.info(for: "antigravity"),
            accounts: [first, second]
        )

        func metric(_ kind: ProviderQuotaMetricKind) throws -> ProviderQuotaAverage {
            try XCTUnwrap(pool.quotaAverages.first { $0.kind == kind })
        }

        XCTAssertEqual(try metric(.antigravityGeminiFiveHour).remainingPercent, 85)
        XCTAssertEqual(try metric(.antigravityGeminiFiveHour).contributingAccounts, 2)
        XCTAssertEqual(try metric(.antigravityGeminiSevenDay).remainingPercent, 50)
        XCTAssertEqual(try metric(.antigravityGeminiSevenDay).contributingAccounts, 1)
        XCTAssertEqual(try metric(.antigravityClaudeGPTFiveHour).remainingPercent, 60)
        XCTAssertEqual(try metric(.antigravityClaudeGPTSevenDay).remainingPercent, 50)
    }

    func testClaudeAndGrokUseOnlyRequestedHeadlineWindows() throws {
        let claude = account(
            id: "claude",
            provider: "claude",
            additional: [
                window(id: "claude-five-hour", label: "5 小时限额", remaining: 90),
                window(id: "claude-seven-day", label: "7 天限额", remaining: 70),
                window(id: "claude-seven-day-opus", label: "7 天 Opus", remaining: 10)
            ]
        )
        let grok = account(
            id: "grok",
            provider: "xai",
            additional: [
                window(id: "xai-weekly-credits", label: "周积分", remaining: 65),
                window(id: "xai-product-grok-code", label: "Grok Code 使用", remaining: 5),
                window(id: "xai-pay-as-you-go", label: "按量付费", remaining: 80),
                window(id: "xai-monthly-credits", label: "月度积分", remaining: 75)
            ]
        )
        let claudePool = ProviderPool(provider: ProviderCatalog.info(for: "claude"), accounts: [claude])
        let grokPool = ProviderPool(provider: ProviderCatalog.info(for: "xai"), accounts: [grok])

        XCTAssertEqual(
            claudePool.quotaAverages.compactMap(\.remainingPercent),
            [90, 70]
        )
        XCTAssertEqual(
            grokPool.quotaAverages.compactMap(\.remainingPercent),
            [65, 75]
        )
        XCTAssertEqual(
            ProviderQuotaMetricKind.xaiMonthly.averagedWindow(in: grok)?.label,
            "月积分"
        )
    }

    private func account(
        id: String,
        provider: String,
        primary: QuotaWindow? = nil,
        weekly: QuotaWindow? = nil,
        additional: [QuotaWindow] = [],
        error: String? = nil,
        disabled: Bool = false,
        unavailable: Bool = false
    ) -> AccountQuota {
        let auth = AuthFile(
            id: id,
            authIndex: "idx-\(id)",
            name: "\(id).json",
            provider: provider,
            type: provider,
            disabled: disabled,
            unavailable: unavailable
        )
        let usage: UsageSnapshot? = (primary != nil || weekly != nil || !additional.isEmpty)
            ? UsageSnapshot(
                planType: nil,
                primary: primary,
                weekly: weekly,
                additionalWindows: additional,
                rawStatus: "test"
            )
            : nil
        return AccountQuota(auth: auth, usage: usage, errorMessage: error)
    }

    private func window(
        id: String,
        label: String,
        remaining: Double,
        usable: Bool? = true
    ) -> QuotaWindow {
        QuotaWindow(
            id: id,
            label: label,
            usedPercent: 100 - remaining,
            remainingPercent: remaining,
            resetAfterSeconds: nil,
            resetAt: nil,
            displayValue: displayPercent(remaining),
            amountText: nil,
            detailText: nil,
            isUsable: usable
        )
    }
}
