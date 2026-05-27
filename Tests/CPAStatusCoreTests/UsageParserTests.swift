import XCTest
@testable import CPAStatusCore

final class UsageParserTests: XCTestCase {
    func testParsesWhamPrimaryAndWeeklyWindows() throws {
        let body = """
        {
          "plan_type": "plus",
          "rate_limit": {
            "primary_window": {
              "used_percent": 25.5,
              "reset_after_seconds": 1200,
              "limit_window_seconds": 18000
            },
            "secondary_window": {
              "used_percent": 70,
              "reset_after_seconds": 86400,
              "limit_window_seconds": 604800
            },
            "allowed": true,
            "limit_reached": false
          }
        }
        """

        let snapshot = try XCTUnwrap(UsageParser.parse(body))
        XCTAssertEqual(snapshot.planType, "plus")
        XCTAssertEqual(snapshot.primary?.remainingPercent, 74.5)
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 30)
        XCTAssertEqual(snapshot.primary?.resetAfterSeconds, 1200)
    }

    func testParsesQuotaLimitResponseWithResetSignal() throws {
        let body = """
        {
          "error": {
            "code": "rate_limit_exceeded",
            "message": "usage limit"
          },
          "rate_limit": {
            "primary_window": {
              "reset_after_seconds": 600,
              "limit_window_seconds": 18000
            },
            "allowed": false,
            "limit_reached": true
          }
        }
        """

        let snapshot = try XCTUnwrap(UsageParser.parse(body))
        XCTAssertEqual(snapshot.primary?.remainingPercent, 0)
        XCTAssertEqual(snapshot.primary?.usedPercent, 100)
        XCTAssertEqual(snapshot.rawStatus, "rate_limit_exceeded")
    }

    func testParsesAntigravityModelQuotaRowsLikeWebUI() throws {
        let body = """
        {
          "models": {
            "claude-sonnet-4-6": {
              "displayName": "Claude Sonnet 4.6",
              "quotaInfo": {
                "remainingFraction": 1,
                "resetTime": "2026-05-27T17:09:00Z"
              }
            },
            "gemini-3.1-pro-high": {
              "displayName": "Gemini 3.1 Pro High",
              "quotaInfo": {
                "remainingFraction": 1,
                "resetTime": "2026-05-27T17:09:00Z"
              }
            },
            "gemini-2.5-flash": {
              "displayName": "Gemini 2.5 Flash",
              "quotaInfo": {
                "remainingFraction": "100%",
                "resetTime": "2026-05-27T17:09:00Z"
              }
            },
            "gemini-2.5-flash-lite": {
              "displayName": "Gemini 2.5 Flash Lite",
              "quotaInfo": {
                "remainingFraction": 1,
                "resetTime": "2026-05-27T17:09:00Z"
              }
            },
            "gemini-3-flash": {
              "displayName": "Gemini 3 Flash",
              "quotaInfo": {
                "remainingFraction": 1,
                "resetTime": "2026-05-27T17:09:00Z"
              }
            },
            "gemini-3.1-flash-image": {
              "displayName": "Gemini 3.1 Flash Image",
              "quotaInfo": {
                "remainingFraction": 1
              }
            }
          }
        }
        """

        let snapshot = try XCTUnwrap(UsageParser.parse(body))
        XCTAssertNil(snapshot.primary)
        XCTAssertNil(snapshot.weekly)
        XCTAssertEqual(snapshot.additionalWindows.map(\.label), [
            "Claude/GPT",
            "Gemini 3.1 Pro Series",
            "Gemini 2.5 Flash",
            "Gemini 2.5 Flash Lite",
            "Gemini 3 Flash",
            "Gemini 3.1 Flash Image"
        ])
        XCTAssertEqual(snapshot.additionalWindows.compactMap(\.displayValue), Array(repeating: "100%", count: 6))
        XCTAssertEqual(snapshot.additionalWindows.first?.remainingPercent, 100)
        XCTAssertEqual(snapshot.additionalWindows.last?.detailText, "05-28 01:09")
    }

    func testParsesClaudeQuotaRowsLikeWebUI() throws {
        let body = """
        {
          "_provider": "claude",
          "profile": {
            "account": {
              "has_claude_pro": true,
              "has_claude_max": false
            }
          },
          "usage": {
            "five_hour": {
              "utilization": 25,
              "resets_at": "2026-05-27T17:31:04Z"
            },
            "seven_day_opus": {
              "utilization": 80,
              "resets_at": "2026-05-27T17:31:04Z"
            },
            "extra_usage": {
              "is_enabled": true,
              "used_credits": 123,
              "monthly_limit": 1000
            }
          }
        }
        """

        let snapshot = try XCTUnwrap(UsageParser.parse(body))
        XCTAssertEqual(snapshot.planType, "专业版")
        XCTAssertEqual(snapshot.additionalWindows.map(\.label), ["5 小时限额", "7 天 Opus", "额外用量"])
        XCTAssertEqual(snapshot.additionalWindows.first?.remainingPercent, 75)
        XCTAssertEqual(snapshot.additionalWindows.first?.detailText, "05-28 01:31")
        XCTAssertEqual(snapshot.additionalWindows.last?.amountText, "$1.23 / $10.00")
    }

    func testParsesKimiQuotaRowsLikeWebUI() throws {
        let body = """
        {
          "usage": {
            "limit": 100,
            "used": 40,
            "reset_in": 3600
          },
          "limits": [
            {
              "window": {
                "duration": 7,
                "timeUnit": "DAYS"
              },
              "detail": {
                "limit": 1000,
                "remaining": 900,
                "reset_time": "2026-05-27T17:31:04Z"
              }
            }
          ]
        }
        """

        let snapshot = try XCTUnwrap(UsageParser.parse(body))
        XCTAssertEqual(snapshot.additionalWindows.map(\.label), ["周限额", "7d 限额"])
        XCTAssertEqual(snapshot.additionalWindows.first?.remainingPercent, 60)
        XCTAssertEqual(snapshot.additionalWindows.first?.amountText, "40 / 100")
        XCTAssertEqual(snapshot.additionalWindows.first?.detailText, "1h 后重置")
        XCTAssertEqual(snapshot.additionalWindows.last?.remainingPercent, 90)
    }

    func testParsesXAIQuotaRowsLikeWebUI() throws {
        let body = """
        {
          "config": {
            "monthlyLimit": { "val": 10000 },
            "used": { "val": 2500 },
            "onDemandCap": { "val": 5000 },
            "billingPeriodEnd": "2026-05-27T17:31:04Z"
          }
        }
        """

        let snapshot = try XCTUnwrap(UsageParser.parse(body))
        XCTAssertEqual(snapshot.additionalWindows.map(\.label), ["按量付费", "月度积分"])
        XCTAssertEqual(snapshot.additionalWindows.first?.displayValue, "已启用")
        XCTAssertEqual(snapshot.additionalWindows.first?.amountText, "封顶 $50.00")
        XCTAssertEqual(snapshot.additionalWindows.last?.remainingPercent, 75)
        XCTAssertEqual(snapshot.additionalWindows.last?.amountText, "$25.00 / $100.00")
        XCTAssertEqual(snapshot.additionalWindows.last?.detailText, "05-28 01:31")
    }

    func testBuildsManagementURLWithExistingPath() throws {
        let url = try CLIProxyAPIClient.managementURL(
            baseURL: "https://example.com/proxy/",
            path: "/v0/management/auth-files"
        )
        XCTAssertEqual(url.absoluteString, "https://example.com/proxy/v0/management/auth-files")
    }
}
