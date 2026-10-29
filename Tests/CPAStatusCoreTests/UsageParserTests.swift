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

    func testParsesCodexCreditBalanceOnlyForPlainDecimalsOrUnlimited() throws {
        func creditWindow(_ credits: String) throws -> QuotaWindow? {
            let body = #"{"rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":18000}},"credits":"# + credits + "}"
            return try XCTUnwrap(UsageParser.parse(body)).additionalWindows.first { $0.id == "codex-credit-balance" }
        }
        XCTAssertEqual(try creditWindow(#"{"has_credits":true,"balance":"12.50"}"#)?.displayValue, "12.50")
        XCTAssertEqual(try creditWindow(#"{"balance":7}"#)?.displayValue, "7")
        XCTAssertEqual(try creditWindow(#"{"unlimited":true,"balance":null}"#)?.displayValue, "无限额")
        XCTAssertNil(try creditWindow(#"{"balance":"-1"}"#))
        XCTAssertNil(try creditWindow(#"{"balance":"abc"}"#))
        XCTAssertNil(try creditWindow(#"{"has_credits":false}"#))
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

    func testParsesAntigravityRetrieveUserQuotaSummaryAtRoot() throws {
        let body = """
        {
          "groups": [
            {
              "displayName": "Agent Models",
              "description": "Models within this group: Claude, GPT",
              "buckets": [
                {
                  "bucketId": "five-hour",
                  "displayName": "5 hour",
                  "window": "5h",
                  "remainingFraction": 0.625,
                  "resetTime": "2026-07-12T05:00:00Z",
                  "description": "Shared agent quota"
                },
                {
                  "bucket_id": "weekly",
                  "display_name": "Weekly",
                  "window": "weekly",
                  "remaining_fraction": "80%"
                }
              ]
            }
          ]
        }
        """

        let snapshot = try XCTUnwrap(UsageParser.parse(body))
        XCTAssertNil(snapshot.planType)
        XCTAssertEqual(snapshot.additionalWindows.map(\.label), [
            "Agent Models · 5 hour",
            "Agent Models · Weekly"
        ])
        XCTAssertEqual(snapshot.additionalWindows[0].remainingPercent, 62.5)
        XCTAssertEqual(snapshot.additionalWindows[0].usedPercent, 37.5)
        XCTAssertNotNil(snapshot.additionalWindows[0].resetAt)
        XCTAssertTrue(snapshot.additionalWindows[0].detailText?.contains("5h") == true)
        XCTAssertFalse(snapshot.additionalWindows[0].detailText?.contains("Models within this group") == true)
        XCTAssertFalse(snapshot.additionalWindows[0].detailText?.contains("Shared agent quota") == true)
        XCTAssertEqual(snapshot.additionalWindows[1].remainingPercent, 80)
    }

    func testParsesWrappedAntigravityQuotaAndSubscription() throws {
        let body = """
        {
          "_provider": "antigravity",
          "quota": {
            "groups": [
              {
                "display_name": "Gemini",
                "buckets": [
                  {
                    "bucket_id": "daily",
                    "display_name": "Daily",
                    "remaining_fraction": 0.4,
                    "window": "24h"
                  }
                ]
              }
            ]
          },
          "subscription": {
            "plan": "ultra",
            "tierName": "Google AI Ultra",
            "tierId": "g1-ultra-tier",
            "paidTier": {
              "availableCredits": [{
                "creditType": "GOOGLE_ONE_AI",
                "creditAmount": 12,
                "minimumCreditAmountForUsage": 5
              }]
            }
          }
        }
        """

        let snapshot = try XCTUnwrap(UsageParser.parse(body))
        XCTAssertEqual(snapshot.planType, "ultra")
        XCTAssertEqual(snapshot.additionalWindows.count, 2)
        XCTAssertEqual(snapshot.additionalWindows[0].label, "Gemini · Daily")
        XCTAssertEqual(snapshot.additionalWindows[0].remainingPercent, 40)
        XCTAssertEqual(snapshot.additionalWindows[0].detailText, "24h")
        XCTAssertEqual(snapshot.additionalWindows[1].label, "Google One AI")
        XCTAssertEqual(snapshot.additionalWindows[1].displayValue, "12")
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
        XCTAssertEqual(snapshot.additionalWindows.last?.displayValue, "已启用")
        XCTAssertEqual(snapshot.additionalWindows.last?.amountText, "已花费 $1.23 / 限额 $10.00")
    }

    func testParsesClaudeFableCreditPoolsDollarBalancesAndTeamPlan() throws {
        let body = """
        {
          "_provider": "claude",
          "profile": {
            "account": { "has_claude_max": true, "has_claude_pro": false },
            "organization": { "organization_type": "claude_team", "subscription_status": "active" }
          },
          "usage": {
            "seven_day": { "utilization": 10, "resets_at": "2026-05-27T17:31:04Z" },
            "iguana_necktie": { "utilization": 99, "resets_at": "2026-05-27T17:31:04Z" },
            "limits": [
              { "kind": "weekly_scoped", "percent": 40, "is_active": false, "scope": { "model": { "display_name": "Fable" } } },
              { "kind": "weekly_scoped", "percent": 30, "is_active": true, "resets_at": "2026-05-29T17:31:04Z", "scope": { "model": { "display_name": "Fable 5" } } }
            ],
            "workspace_spend": {
              "limit_dollars": 50, "used_dollars": 12.5, "remaining_dollars": 37.5,
              "utilization": 25, "resets_at": null
            },
            "extra_usage": {
              "is_enabled": false, "used_credits": 0, "monthly_limit": 2000,
              "utilization": 0, "currency": "EUR", "user_disabled": true
            }
          }
        }
        """

        let snapshot = try XCTUnwrap(UsageParser.parse(body))
        XCTAssertEqual(snapshot.planType, "团队版")
        XCTAssertEqual(snapshot.additionalWindows.map(\.id), [
            "claude-seven-day",
            "claude-seven-day-fable",
            "claude-balance-workspace-spend",
            "claude-extra-usage"
        ])
        let fable = snapshot.additionalWindows[1]
        XCTAssertEqual(fable.label, "7 天 Fable 5")
        XCTAssertEqual(fable.remainingPercent, 70)
        XCTAssertEqual(fable.detailText, "05-30 01:31")
        let balance = snapshot.additionalWindows[2]
        XCTAssertEqual(balance.label, "workspace_spend")
        XCTAssertEqual(balance.displayValue, "剩余 $37.50")
        XCTAssertEqual(balance.amountText, "已花费 $12.50 / 限额 $50.00")
        XCTAssertEqual(balance.detailText, "重置时间未提供")
        let extra = snapshot.additionalWindows[3]
        XCTAssertEqual(extra.displayValue, "已禁用")
        XCTAssertEqual(extra.amountText, "已花费 0.00 EUR / 限额 20.00 EUR")
        XCTAssertEqual(extra.detailText, "已使用 0% · 用户已禁用")

        let creditPool = try XCTUnwrap(UsageParser.parse("""
        {
          "_provider": "claude",
          "usage": {
            "iguana_necktie": {
              "utilization": 40, "resets_at": "2026-05-27T17:31:04Z",
              "limit_dollars": 20, "used_dollars": 8, "remaining_dollars": 12
            }
          }
        }
        """))
        XCTAssertEqual(creditPool.additionalWindows.map(\.id), ["claude-cloud-session-credits"])
        XCTAssertEqual(creditPool.additionalWindows.first?.label, "云端会话额度")
        XCTAssertEqual(creditPool.additionalWindows.first?.remainingPercent, 60)
        XCTAssertEqual(creditPool.additionalWindows.first?.amountText, "已花费 $8.00 / 限额 $20.00")

        let legacyFable = try XCTUnwrap(UsageParser.parse("""
        {"_provider":"claude","usage":{"iguana_necktie":{"utilization":25,"resets_at":"2026-05-27T17:31:04Z"}}}
        """))
        XCTAssertEqual(legacyFable.additionalWindows.map(\.label), ["7 天 Fable 5"])
        XCTAssertEqual(legacyFable.additionalWindows.first?.remainingPercent, 75)
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
        XCTAssertEqual(snapshot.additionalWindows.map(\.label), ["7天限额", "周限额"])
        XCTAssertEqual(snapshot.additionalWindows.first?.remainingPercent, 90)
        XCTAssertEqual(snapshot.additionalWindows.last?.remainingPercent, 60)
        XCTAssertEqual(snapshot.additionalWindows.last?.amountText, "40 / 100")
        XCTAssertEqual(snapshot.additionalWindows.last?.detailText, "1h后重置")
    }

    func testParsesKimiProtobufTimeUnitsAndMonthlyTotal() throws {
        let body = """
        {
          "limits": [
            {
              "detail": { "limit": "100", "used": "5", "remaining": "95", "resetTime": "2099-09-27T00:30:34.136523Z" },
              "window": { "duration": 300, "timeUnit": "TIME_UNIT_MINUTE" }
            },
            {
              "detail": { "limit": "10", "used": "1" },
              "window": { "duration": 90 }
            },
            {
              "detail": { "limit": "10", "used": "1" },
              "window": { "duration": 2, "timeUnit": "TIME_UNIT_WEEK" }
            }
          ],
          "usages": { "limit_month_total": { "used_ratio": 0.2529, "reset_time": "2099-10-22T00:00:00Z" } }
        }
        """

        let snapshot = try XCTUnwrap(UsageParser.parse(body))
        XCTAssertEqual(snapshot.additionalWindows.map(\.label), ["5小时限额", "90分钟限额", "2周限额", "月限额"])
        XCTAssertEqual(snapshot.additionalWindows.first?.remainingPercent, 95)
        XCTAssertEqual(snapshot.additionalWindows.first?.detailText?.hasSuffix("后重置"), true)
        let monthly = try XCTUnwrap(snapshot.additionalWindows.last)
        XCTAssertEqual(monthly.id, "kimi-monthly")
        XCTAssertEqual(monthly.usedPercent, 25)
        XCTAssertEqual(monthly.remainingPercent, 75)
        XCTAssertEqual(monthly.detailText?.hasSuffix("后重置"), true)

        let monthlyOnly = try XCTUnwrap(UsageParser.parse(#"{"usages":{"limit_month_total":{"used_ratio":"0.5"}}}"#))
        XCTAssertEqual(monthlyOnly.additionalWindows.map(\.label), ["月限额"])
        XCTAssertNil(UsageParser.parse(#"{"usages":{}}"#)?.additionalWindows.first { $0.id == "kimi-monthly" })
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

    func testParsesWrappedXAIWeeklyMonthlyAndProductUsage() throws {
        let body = """
        {
          "_provider": "xai",
          "weekly": {
            "config": {
              "currentPeriod": {
                "type": "weekly",
                "start": "2026-07-06T00:00:00Z",
                "end": "2026-07-13T00:00:00Z"
              },
              "creditUsagePercent": 35,
              "productUsage": [
                { "product": "Grok 4 Fast", "usagePercent": 80 },
                { "product": "Grok Code", "usage_percent": "12.5" }
              ]
            }
          },
          "monthly": {
            "config": {
              "monthlyLimit": { "val": 10000 },
              "used": { "val": 2500 },
              "onDemandCap": { "val": 5000 },
              "onDemandUsed": { "val": 1000 },
              "billingPeriodEnd": "2026-08-01T00:00:00Z"
            }
          }
        }
        """

        let snapshot = try XCTUnwrap(UsageParser.parse(body))
        XCTAssertEqual(snapshot.additionalWindows.map(\.label), [
            "周积分",
            "Grok 4 Fast 使用",
            "Grok Code 使用",
            "按量付费",
            "月度积分"
        ])
        XCTAssertEqual(snapshot.additionalWindows[0].remainingPercent, 65)
        // Product rows break down the shared weekly credits instead of acting as separate allowances.
        XCTAssertEqual(snapshot.additionalWindows[1].usedPercent, 80)
        XCTAssertNil(snapshot.additionalWindows[1].remainingPercent)
        XCTAssertNil(snapshot.additionalWindows[1].isUsable)
        XCTAssertEqual(snapshot.additionalWindows[1].displayValue, "已用 80%")
        XCTAssertEqual(snapshot.additionalWindows[1].detailText, "共享配额明细")
        XCTAssertEqual(snapshot.additionalWindows[2].usedPercent, 12.5)
        XCTAssertNil(snapshot.additionalWindows[2].remainingPercent)
        XCTAssertEqual(snapshot.additionalWindows[3].remainingPercent, 80)
        XCTAssertEqual(snapshot.additionalWindows[3].amountText, "已用 $10.00 / 封顶 $50.00")
        XCTAssertEqual(snapshot.additionalWindows[4].remainingPercent, 75)
        XCTAssertEqual(snapshot.additionalWindows[4].amountText, "$25.00 / $100.00")
    }

    func testParsesCodexCodeReviewMonthlyAdditionalAndResetCredits() throws {
        let body = """
        {
          "plan_type": "team",
          "rate_limit": {
            "primary_window": {
              "used_percent": 10,
              "limit_window_seconds": 18000
            },
            "secondary_window": {
              "used_percent": 20,
              "limit_window_seconds": 2678400
            }
          },
          "code_review_rate_limit": {
            "primary_window": {
              "used_percent": 30,
              "limit_window_seconds": 18000
            },
            "secondary_window": {
              "used_percent": 40,
              "limit_window_seconds": 2419200
            }
          },
          "additional_rate_limits": [
            {
              "limit_name": "deep-research",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 50,
                  "limit_window_seconds": 18000
                },
                "secondary_window": {
                  "used_percent": 60,
                  "limit_window_seconds": 604800
                }
              }
            }
          ],
          "rate_limit_reset_credits": {
            "available_count": 3
          }
        }
        """

        let snapshot = try XCTUnwrap(UsageParser.parse(body))
        XCTAssertEqual(snapshot.planType, "team")
        XCTAssertEqual(snapshot.primary?.remainingPercent, 90)
        XCTAssertEqual(snapshot.weekly?.label, "月度限额")
        XCTAssertEqual(snapshot.weekly?.remainingPercent, 80)
        XCTAssertEqual(snapshot.additionalWindows.map(\.label), [
            "代码审查 5h",
            "代码审查月度限额",
            "deep-research 5h",
            "deep-research 7d",
            "主动重置次数"
        ])
        XCTAssertEqual(snapshot.additionalWindows[0].remainingPercent, 70)
        XCTAssertEqual(snapshot.additionalWindows[1].remainingPercent, 60)
        XCTAssertEqual(snapshot.additionalWindows[3].remainingPercent, 40)
        XCTAssertNil(snapshot.additionalWindows[4].remainingPercent)
        XCTAssertNil(snapshot.additionalWindows[4].usedPercent)
        XCTAssertEqual(snapshot.additionalWindows[4].displayValue, "3")
    }

    func testParsesCodexResetCreditDetailsAndFiltersUnavailableOrWrongType() throws {
        let body = """
        {
          "rate_limit_reset_credits": {
            "available_count": "4",
            "credits": [
              {
                "id": "credit-a",
                "status": "available",
                "reset_type": "codex_rate_limits",
                "granted_at": "2026-07-01T00:00:00Z",
                "expires_at": "2026-08-01T00:00:00Z"
              },
              {
                "id": "credit-b",
                "status": "AVAILABLE",
                "resetType": "codex_rate_limits",
                "grantedAt": "2026-07-02T00:00:00Z",
                "expiresAt": "2026-08-02T00:00:00Z"
              },
              {
                "id": "credit-consumed",
                "status": "consumed",
                "reset_type": "codex_rate_limits",
                "expires_at": "2026-08-03T00:00:00Z"
              },
              {
                "id": "credit-other",
                "status": "available",
                "reset_type": "other_product",
                "expires_at": "2026-08-04T00:00:00Z"
              },
              {
                "id": "credit-no-expiry",
                "status": "available",
                "reset_type": "codex_rate_limits"
              }
            ]
          }
        }
        """

        let snapshot = try XCTUnwrap(UsageParser.parse(body))
        XCTAssertEqual(snapshot.additionalWindows.map(\.label), [
            "主动重置次数",
            "主动重置券 #1",
            "主动重置券 #2"
        ])
        XCTAssertEqual(snapshot.additionalWindows[0].displayValue, "4")

        let firstCredit = snapshot.additionalWindows[1]
        XCTAssertEqual(firstCredit.id, "code-reset-credit-credit-a")
        XCTAssertEqual(firstCredit.displayValue, "可用")
        XCTAssertEqual(
            firstCredit.resetAt,
            ISO8601DateFormatter().date(from: "2026-08-01T00:00:00Z")
        )
        XCTAssertTrue(firstCredit.detailText?.hasPrefix("到期 ") == true)

        let secondCredit = snapshot.additionalWindows[2]
        XCTAssertEqual(secondCredit.id, "code-reset-credit-credit-b")
        XCTAssertEqual(
            secondCredit.resetAt,
            ISO8601DateFormatter().date(from: "2026-08-02T00:00:00Z")
        )
        XCTAssertFalse(snapshot.additionalWindows.contains { $0.id.contains("consumed") })
        XCTAssertFalse(snapshot.additionalWindows.contains { $0.id.contains("other") })
        XCTAssertFalse(snapshot.additionalWindows.contains { $0.id.contains("no-expiry") })
    }

    func testBuildsManagementURLWithExistingPath() throws {
        let url = try CLIProxyAPIClient.managementURL(
            baseURL: "https://example.com/proxy/",
            path: "/v0/management/auth-files"
        )
        XCTAssertEqual(url.absoluteString, "https://example.com/proxy/v0/management/auth-files")
    }
}
