import XCTest
@testable import CPAStatusCore

final class GrokQuotaTests: XCTestCase {
    func testExplicitZeroUsageRetainsFullRemainingQuota() throws {
        for zero in ["0", "\"0\"", "\"0%\""] {
            let usage = try XCTUnwrap(UsageParser.parse("""
            {"_provider":"xai","weekly":{"config":{"creditUsagePercent":\(zero)}},
             "monthly":{"config":{"monthlyLimit":{"val":10000},"used":{"val":0}}}}
            """))
            for id in ["xai-weekly-credits", "xai-monthly-credits"] {
                let window = try XCTUnwrap(usage.additionalWindows.first { $0.id == id })
                XCTAssertEqual(window.usedPercent, 0)
                XCTAssertEqual(window.remainingPercent, 100)
                XCTAssertEqual(window.displayValue, "100%")
                XCTAssertFalse(window.isExhausted)
            }
        }
    }

    func testProtoJSONOmittedScalarsAndEmptyCentsRepresentZero() throws {
        let usage = try XCTUnwrap(UsageParser.parse(#"{"_provider":"xai","weekly":{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2099-01-08T00:00:00Z"},"productUsage":[{"product":"Grok Code"}]}},"monthly":{"config":{"monthlyLimit":{"val":10000},"used":{},"onDemandCap":{"val":5000},"onDemandUsed":{}}}}"#))
        for window in usage.additionalWindows {
            XCTAssertEqual(window.usedPercent, 0, window.id)
            // Product rows only break down the shared weekly usage.
            XCTAssertEqual(window.remainingPercent, window.id == "xai-product-grok-code" ? nil : 100, window.id)
        }
        XCTAssertEqual(usage.additionalWindows.first { $0.id == "xai-product-grok-code" }?.displayValue, "已用 0.0%")
        XCTAssertEqual(usage.additionalWindows.first?.amountText, "已用 0.0%")
        XCTAssertEqual(usage.additionalWindows.last?.amountText, "$0.00 / $100.00")
    }

    func testZeroMonthlyBudgetPreservesUsageWithoutInventingRemainingQuota() throws {
        for zero in ["{}", "{\"val\":0}"] {
            let usage = try XCTUnwrap(UsageParser.parse("""
            {"_provider":"xai","weekly":{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2099-01-08T00:00:00Z"}}},
             "monthly":{"config":{"monthlyLimit":\(zero),"used":\(zero),"onDemandCap":\(zero)}}}
            """))
            let account = AccountQuota(
                auth: AuthFile(id: "grok", authIndex: "grok-index", name: "grok.json", provider: "xai"),
                usage: usage,
                errorMessage: nil
            )
            let weekly = try XCTUnwrap(ProviderQuotaMetricKind.xaiWeekly.averagedWindow(in: account))
            XCTAssertEqual(weekly.remainingPercent, 100)
            XCTAssertEqual(weekly.amountText, "已用 0.0%")
            XCTAssertNotNil(weekly.resetAt)
            let monthly = try XCTUnwrap(ProviderQuotaMetricKind.xaiMonthly.averagedWindow(in: account))
            XCTAssertEqual(monthly.usedPercent, 0)
            XCTAssertEqual(monthly.displayValue, "已用 0.0%")
            XCTAssertEqual(monthly.amountText, "$0.00 / $0.00")
            XCTAssertNil(monthly.remainingPercent)
            XCTAssertNil(monthly.isUsable)
            XCTAssertFalse(monthly.isExhausted)
            XCTAssertTrue(account.isHealthy)
            XCTAssertNil(ProviderQuotaMetricKind.xaiMonthly.remainingPercent(in: account))
        }
    }

    func testMissingAndInvalidBillingValuesRemainUnknown() throws {
        for body in [
            #"{"_provider":"xai","weekly":{},"monthly":{}}"#,
            #"{"_provider":"xai","weekly":{"config":null},"monthly":{"config":null}}"#,
            #"{"_provider":"xai","weekly":{"config":{"creditUsagePercent":false,"currentPeriod":{"type":"weekly"}}},"monthly":{"config":{"monthlyLimit":{"val":10000},"used":{"val":null}}}}"#,
            #"{"_provider":"xai","weekly":{"config":{"creditUsagePercent":"invalid","currentPeriod":{"type":"weekly"}}},"monthly":{"config":{"monthlyLimit":{"val":0}}}}"#,
            #"{"_provider":"xai","weekly":{"config":{"creditUsagePercent":null,"currentPeriod":{"type":"weekly"}}},"monthly":{"config":{"monthlyLimit":{"val":10000},"used":{"unexpected":0}}}}"#
        ] {
            let windows = UsageParser.parse(body)?.additionalWindows ?? []
            XCTAssertTrue(windows.allSatisfy { $0.usedPercent == nil && $0.remainingPercent == nil })
        }
    }

    func testExhaustedQuotaStillShowsZeroRemaining() throws {
        let usage = try XCTUnwrap(UsageParser.parse(#"{"_provider":"xai","weekly":{"config":{"creditUsagePercent":100}},"monthly":{"config":{"monthlyLimit":10000,"used":10000}}}"#))
        for window in usage.additionalWindows where window.id != "xai-pay-as-you-go" {
            XCTAssertEqual(window.usedPercent, 100)
            XCTAssertEqual(window.remainingPercent, 0)
            XCTAssertEqual(window.displayValue, "0.0%")
            XCTAssertTrue(window.isExhausted)
        }
    }
}
