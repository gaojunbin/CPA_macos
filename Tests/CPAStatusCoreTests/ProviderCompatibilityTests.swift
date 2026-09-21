import XCTest
@testable import CPAStatusCore

final class ProviderCompatibilityTests: XCTestCase {
    func testDevinQuotaUsesRemainingPercentAndObservationTime() throws {
        let quota = try JSONDecoder().decode(DevinQuota.self, from: Data(#"{"observed_at":"2026-09-21T12:00:00.123Z","signals":{"plan":"Pro","daily_quota_remaining_percent":"0%","weekly_quota_remaining_percent":"73%","daily_quota_reset_at":"2099-01-01T00:00:00Z","weekly_quota_reset_at":"2099-01-07T00:00:00Z","plan_end":"2099-02-01T00:00:00Z"}}"#.utf8))
        let usage = quota.usage()
        XCTAssertEqual(usage.planType, "Pro")
        XCTAssertEqual(usage.primary?.remainingPercent, 0)
        XCTAssertEqual(usage.primary?.usedPercent, 100)
        XCTAssertEqual(usage.weekly?.remainingPercent, 73)
        XCTAssertNotNil(quota.planEnd)
        XCTAssertEqual(usage.observation, .server(quota.observedAt))
        XCTAssertEqual(usage.fetchedAt, quota.observedAt)
    }

    func testMissingInvalidAndExpiredQuotaRemainUnknown() throws {
        for raw in [#"{}"#, #"{"signals":null}"#, #"{"signals":{"daily_quota_remaining_percent":"NaN","weekly_quota_remaining_percent":"101%"}}"#, #"{"signals":{"daily_quota_remaining_percent":"10%","daily_quota_reset_at":"2020-01-01T00:00:00Z"}}"#] {
            let quota = try JSONDecoder().decode(DevinQuota.self, from: Data(raw.utf8))
            XCTAssertFalse(quota.usage().hasQuotaSignal)
            XCTAssertEqual(quota.usage().observation, .server(nil))
        }
    }

    func testProviderFlowsAndRoutingCatalog() {
        XCTAssertFalse(OAuthProvider.devin.usesDeviceFlow)
        XCTAssertNil(OAuthProvider.devin.callbackPort)
        XCTAssertEqual(OAuthProvider.devin.authPath, "/v0/management/devin-auth-url")
        XCTAssertTrue(OAuthProvider.meta.usesDeviceFlow)
        XCTAssertTrue(OAuthProvider.kimiAI.usesDeviceFlow)
        XCTAssertEqual(ProviderCatalog.info(for: "cognition").key, "devin")
        XCTAssertEqual(ProviderCatalog.info(for: "kimi-ai").displayName, "Kimi.ai")
        XCTAssertFalse(ProviderCatalog.info(for: "meta").supportsUsage)
        XCTAssertEqual(APIKeyChannelKind.meta.definitionsChannel, "meta")
    }

    func testCallbackRejectsOtherSessionsAndInvalidURLs() throws {
        try validateOAuthCallback("http://127.0.0.1:18317/callback?code=test&state=session", state: "session")
        try validateOAuthCallback("http://127.0.0.1:8317/callback?error=access_denied&state=session", state: "session")
        for url in ["http://127.0.0.1:8317/callback?code=test&state=other", "https://example.com/?code=test&state=session", "http://localhost/?state=session", "http://localhost/?code=test&state=session&state=other"] {
            XCTAssertThrowsError(try validateOAuthCallback(url, state: "session"))
        }
    }

    func testDevinObservationsDoNotImplySchedulerCooldown() throws {
        let detail = AccountDetail(dict: ["quota": ["signals": ["daily_quota_remaining_percent": "0%", "plan": "Pro"]]])
        let account = AccountQuota(auth: AuthFile(id: "devin", name: "devin.json", provider: "devin"), usage: nil, errorMessage: nil, detail: detail)
        XCTAssertEqual(account.usage?.primary?.remainingPercent, 0)
        XCTAssertFalse(detail.quotaExceeded)
        XCTAssertTrue(detail.activeCooldowns.isEmpty)
        XCTAssertFalse(account.isUnavailable)
        XCTAssertEqual(ProviderQuotaMetricKind.devinDaily.remainingPercent(in: account), 0)
        XCTAssertEqual(ProviderQuotaMetricKind.metrics(for: "devin"), [.devinDaily, .devinWeekly])
    }
}
