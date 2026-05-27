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

    func testBuildsManagementURLWithExistingPath() throws {
        let url = try CLIProxyAPIClient.managementURL(
            baseURL: "https://example.com/proxy/",
            path: "/v0/management/auth-files"
        )
        XCTAssertEqual(url.absoluteString, "https://example.com/proxy/v0/management/auth-files")
    }
}
