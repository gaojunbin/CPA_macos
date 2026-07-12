import XCTest
@testable import CPAStatusCore

final class RoutingModelTests: XCTestCase {
    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testAuthFileDecodesRoutingMetadataAndExcludesCompatFromCodex() throws {
        let snakeCase = try JSONDecoder().decode(
            AuthFile.self,
            from: Data("""
            {
              "id":"compat-1",
              "name":"compat.json",
              "provider":"openai-compatible-opencode",
              "prefix":"team",
              "priority":"9",
              "using_api":"true",
              "proxy_url":"http://proxy.example",
              "note":"primary route"
            }
            """.utf8)
        )

        XCTAssertEqual(snakeCase.prefix, "team")
        XCTAssertEqual(snakeCase.priority, 9)
        XCTAssertEqual(snakeCase.usingAPI, true)
        XCTAssertEqual(snakeCase.proxyURL, "http://proxy.example")
        XCTAssertEqual(snakeCase.note, "primary route")
        XCTAssertFalse(snakeCase.isCodexLike)

        let camelCase = try JSONDecoder().decode(
            AuthFile.self,
            from: Data("""
            {
              "id":"grok-1",
              "name":"grok.json",
              "provider":"grok",
              "usingApi":false,
              "proxyUrl":"https://gateway.example"
            }
            """.utf8)
        )
        XCTAssertEqual(camelCase.usingAPI, false)
        XCTAssertEqual(camelCase.proxyURL, "https://gateway.example")

        XCTAssertTrue(AuthFile(id: "codex", name: "codex", provider: "codex").isCodexLike)
        XCTAssertTrue(AuthFile(id: "openai", name: "openai", provider: "openai").isCodexLike)
    }

    func testModelRouteDefinitionExposesPrefixedPublicIDAndStableIdentity() {
        let first = ModelRouteDefinition(
            name: "upstream-a",
            alias: "client-model",
            prefix: "team",
            source: "openai-compatible-demo",
            forceMapping: true
        )
        let second = ModelRouteDefinition(
            name: "upstream-b",
            alias: "client-model",
            prefix: "team",
            source: "openai-compatible-demo"
        )
        let duplicate = ModelRouteDefinition(
            name: "upstream-a",
            alias: "client-model",
            prefix: "team",
            source: "openai-compatible-demo",
            forceMapping: true
        )

        XCTAssertEqual(first.upstreamModelName, "upstream-a")
        XCTAssertEqual(first.clientFacingAlias, "client-model")
        XCTAssertEqual(first.publicModelID, "team/client-model")
        XCTAssertEqual(first.id, duplicate.id)
        XCTAssertNotEqual(first.id, second.id)
    }

    func testRouteExpansionMirrorsForceModelPrefixPolicy() {
        let route = ModelRouteDefinition(
            name: "upstream-model",
            alias: "client-model",
            prefix: "team",
            source: "codex-api-key"
        )

        let compatible = ModelRoutingResolver.expand(route, forceModelPrefix: false)
        XCTAssertEqual(compatible.map(\.publicModelID), ["client-model", "team/client-model"])
        XCTAssertEqual(Set(compatible.map(\.id)).count, 2)

        let forced = ModelRoutingResolver.expand(route, forceModelPrefix: true)
        XCTAssertEqual(forced.map(\.publicModelID), ["team/client-model"])
    }

    func testOAuthRoutingParserKeepsDuplicateAliasesAndParsesExclusions() throws {
        let aliasRoot = try json("""
        {"oauth-model-alias": {
          "codex": [
            {"name": "gpt-upstream-a", "alias": "gpt-client", "fork": true},
            {"name": "gpt-upstream-b", "alias": "gpt-client", "force-mapping": true}
          ],
          "claude": [
            {"name": "claude-opus-upstream", "alias": "claude-opus", "forceMapping": "true"}
          ]
        }}
        """)
        let aliases = OAuthModelRoutingParser.aliases(root: aliasRoot)

        XCTAssertEqual(aliases["codex"]?.count, 2)
        XCTAssertEqual(aliases["codex"]?.map(\.alias), ["gpt-client", "gpt-client"])
        XCTAssertEqual(aliases["codex"]?.map(\.name), ["gpt-upstream-a", "gpt-upstream-b"])
        XCTAssertEqual(aliases["codex"]?.first?.fork, true)
        XCTAssertEqual(aliases["codex"]?.last?.forceMapping, true)
        XCTAssertEqual(aliases["claude"]?.first?.forceMapping, true)
        XCTAssertEqual(aliases["codex"]?.first?.routeDefinition(prefix: "team").publicModelID, "team/gpt-client")

        let excludedRoot = try json("""
        {"oauth-excluded-models": {
          "codex": ["gpt-legacy", "*-preview"],
          "antigravity": ["gemini-2.*"]
        }}
        """)
        let excluded = OAuthModelRoutingParser.excludedModels(root: excludedRoot)
        XCTAssertEqual(excluded["codex"], ["gpt-legacy", "*-preview"])
        XCTAssertEqual(excluded["antigravity"], ["gemini-2.*"])
    }

    func testOAuthAliasesUseAuthPrefixesAndForkKeepsOriginalRoute() throws {
        let aliasRoot = try json("""
        {"oauth-model-alias": {
          "codex": [
            {"name": "gpt-upstream", "alias": "gpt-client", "fork": true}
          ]
        }}
        """)
        let entry = try XCTUnwrap(OAuthModelRoutingParser.aliases(root: aliasRoot)["codex"]?.first)
        let auths = [
            AuthFile(id: "codex-a", name: "codex-a.json", provider: "codex", prefix: "team"),
            // A second credential with the same prefix must not duplicate routes.
            AuthFile(id: "codex-b", name: "codex-b.json", provider: "codex", prefix: "team")
        ]

        let compatible = ModelRoutingResolver.oauthRoutes(
            entries: [entry],
            auths: auths,
            forceModelPrefix: false
        )
        XCTAssertEqual(Set(compatible.map(\.publicModelID)), [
            "gpt-client", "team/gpt-client",
            "gpt-upstream", "team/gpt-upstream"
        ])
        XCTAssertEqual(compatible.filter { $0.upstreamModelName == "gpt-upstream" }.count, 4)
        XCTAssertTrue(compatible.contains {
            $0.publicModelID == "gpt-upstream" &&
                $0.clientFacingAlias == "gpt-upstream" &&
                $0.fork
        })

        let forced = ModelRoutingResolver.oauthRoutes(
            entries: [entry],
            auths: auths,
            forceModelPrefix: true
        )
        XCTAssertEqual(Set(forced.map(\.publicModelID)), [
            "team/gpt-client", "team/gpt-upstream"
        ])
        XCTAssertFalse(forced.contains { $0.publicModelID == "gpt-client" })
        XCTAssertFalse(forced.contains { $0.publicModelID == "gpt-upstream" })
    }

    func testOAuthAliasUsesEveryDistinctProviderPrefix() {
        let entry = OAuthModelAliasEntry(
            provider: "claude",
            name: "claude-upstream",
            alias: "claude-client"
        )
        let auths = [
            AuthFile(id: "a", name: "a.json", provider: "claude", prefix: "team"),
            AuthFile(id: "b", name: "b.json", provider: "claude", prefix: "org")
        ]

        let routes = ModelRoutingResolver.oauthRoutes(
            entries: [entry],
            auths: auths,
            forceModelPrefix: true
        )
        XCTAssertEqual(Set(routes.map(\.publicModelID)), ["team/claude-client", "org/claude-client"])
    }

    func testAuthFileRoutingParserRetainsOnlySafeRoutingFields() throws {
        let payload = Data("""
        {
          "access_token": "super-secret-access-token",
          "refresh_token": "super-secret-refresh-token",
          "email": "private@example.com",
          "prefix": "account-prefix",
          "priority": "17",
          "using_api": true,
          "proxy_url": "http://proxy-user:proxy-pass@proxy.example:8080/tunnel?token=hidden#fragment",
          "note": "Primary OAuth route",
          "model_aliases": [
            {"name": " account-upstream ", "alias": " shared-client ", "fork": true},
            {"name": "duplicate-upstream", "alias": "SHARED-CLIENT"},
            {"name": "same", "alias": "same"},
            {"name": "other-upstream", "alias": "other-client", "force_mapping": true}
          ],
          "excluded-models": ["private-*", "PRIVATE-*", "legacy-model"]
        }
        """.utf8)

        let parsed = try XCTUnwrap(OAuthAuthFileRoutingParser.parse(data: payload, provider: "codex"))
        XCTAssertEqual(parsed.aliases.map(\.name), ["account-upstream", "other-upstream"])
        XCTAssertEqual(parsed.aliases.map(\.alias), ["shared-client", "other-client"])
        XCTAssertTrue(parsed.aliases[0].fork)
        XCTAssertTrue(parsed.aliases[1].forceMapping)
        XCTAssertEqual(parsed.excludedModels, ["private-*", "legacy-model"])
        XCTAssertEqual(parsed.prefix, "account-prefix")
        XCTAssertEqual(parsed.priority, 17)
        XCTAssertEqual(parsed.usingAPI, true)
        XCTAssertEqual(parsed.proxyURL, "http://proxy.example:8080/tunnel")
        XCTAssertEqual(parsed.note, "Primary OAuth route")
        XCTAssertFalse(String(describing: parsed).contains("super-secret"))
        XCTAssertFalse(String(describing: parsed).contains("proxy-user"))
        XCTAssertFalse(String(describing: parsed).contains("proxy-pass"))
        XCTAssertFalse(String(describing: parsed).contains("token=hidden"))
        XCTAssertEqual(
            Set(Mirror(reflecting: parsed).children.compactMap(\.label)),
            ["aliases", "excludedModels", "prefix", "priority", "usingAPI", "proxyURL", "note"]
        )
    }

    func testAuthFileRoutingParserAcceptsKebabAndCamelEndpointKeys() throws {
        let variants: [(using: String, proxy: String)] = [
            ("using_api", "proxy_url"),
            ("using-api", "proxy-url"),
            ("usingAPI", "proxyURL")
        ]
        for variant in variants {
            let object: [String: Any] = [
                variant.using: true,
                variant.proxy: "socks5://user:pass@127.0.0.1:1080?secret=value"
            ]
            let data = try JSONSerialization.data(withJSONObject: object)
            let parsed = try XCTUnwrap(OAuthAuthFileRoutingParser.parse(data: data, provider: "claude"))
            XCTAssertEqual(parsed.usingAPI, true)
            XCTAssertEqual(parsed.proxyURL, "socks5://127.0.0.1:1080")
        }
    }

    func testAccountAliasesOverrideSameGlobalAliasButKeepOtherGlobals() {
        let auths = [
            AuthFile(id: "account-a", name: "account-a.json", provider: "codex", prefix: "team"),
            AuthFile(id: "account-b", name: "account-b.json", provider: "codex", prefix: "org")
        ]
        let global = [
            OAuthModelAliasEntry(provider: "codex", name: "global-upstream", alias: "shared-client"),
            OAuthModelAliasEntry(provider: "codex", name: "global-other", alias: "other-client")
        ]
        let overrides = [
            "account-a": OAuthAccountRoutingOverride(
                aliases: [
                    OAuthModelAliasEntry(provider: "codex", name: "account-upstream", alias: "SHARED-CLIENT")
                ],
                excludedModels: ["private-*", "GLOBAL-*"],
                prefix: "override-team",
                priority: 99,
                usingAPI: true,
                proxyURL: "http://user:pass@proxy.example:8080/path?token=secret",
                note: "Account override"
            )
        ]

        let routes = ModelRoutingResolver.oauthRoutes(
            globalEntries: global,
            auths: auths,
            accountOverrides: overrides,
            forceModelPrefix: true
        )
        XCTAssertTrue(routes.contains {
            $0.publicModelID == "override-team/SHARED-CLIENT" && $0.upstreamModelName == "account-upstream"
        })
        XCTAssertFalse(routes.contains {
            $0.publicModelID.lowercased() == "override-team/shared-client" && $0.upstreamModelName == "global-upstream"
        })
        XCTAssertTrue(routes.contains {
            $0.publicModelID == "override-team/other-client" && $0.upstreamModelName == "global-other"
        })
        XCTAssertTrue(routes.contains {
            $0.publicModelID == "org/shared-client" && $0.upstreamModelName == "global-upstream"
        })

        XCTAssertEqual(
            ModelRoutingResolver.mergedExcludedModels(
                global: ["global-*", "common-model"],
                auths: auths,
                accountOverrides: overrides
            ),
            ["global-*", "common-model", "private-*"]
        )
        XCTAssertEqual(ModelRoutingResolver.effectivePrefix(for: auths[0], accountOverrides: overrides), "override-team")
        XCTAssertEqual(ModelRoutingResolver.effectivePriority(for: auths[0], accountOverrides: overrides), 99)
        XCTAssertEqual(ModelRoutingResolver.effectiveUsingAPI(for: auths[0], accountOverrides: overrides), true)
        XCTAssertEqual(
            ModelRoutingResolver.effectiveProxyURL(for: auths[0], accountOverrides: overrides),
            "http://proxy.example:8080/path"
        )
        XCTAssertEqual(ModelRoutingResolver.effectiveNote(for: auths[0], accountOverrides: overrides), "Account override")
    }
}
