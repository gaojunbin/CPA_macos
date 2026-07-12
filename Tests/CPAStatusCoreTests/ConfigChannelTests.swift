import XCTest
@testable import CPAStatusCore

final class ConfigChannelTests: XCTestCase {
    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    // MARK: openai-compatibility

    func testCompatChannelSynthesizesAliasesPerAPIKey() throws {
        let root = try json("""
        {"openai-compatibility": [
          {"name": "opencode",
           "base-url": "https://api.opencode.example/v1",
           "api-key-entries": [{"api-key": "sk-1"}, {"api-key": "sk-2"}],
           "models": [
             {"name": "big-upstream-v2", "alias": "big-model", "force-mapping": true},
             {"name": "other-upstream", "alias": "big-model"},
             {"name": "plain-model"}
           ]}
        ]}
        """)

        let accounts = ConfigChannelSynthesizer.compatAccounts(root: root)
        XCTAssertEqual(accounts.count, 2)
        XCTAssertEqual(accounts[0].routes.map(\.name), ["big-upstream-v2", "other-upstream", "plain-model"])
        XCTAssertEqual(accounts[0].routes.map(\.alias), ["big-model", "big-model", "plain-model"])
        XCTAssertTrue(accounts[0].routes[0].forceMapping)
        XCTAssertEqual(accounts[0].models.map(\.id), ["big-model", "plain-model"])

        let routing = ModelRoutingResolver.configRoutes(accounts: accounts, forceModelPrefix: false)
        // Two API keys provide credential redundancy, not duplicate upstream targets.
        XCTAssertEqual(routing.count, 3)
        XCTAssertEqual(
            routing.filter { $0.publicModelID == "big-model" }.map(\.upstreamModelName),
            ["big-upstream-v2", "other-upstream"]
        )

        let results = ConfigChannelSynthesizer.compatResults(root: root)
        XCTAssertEqual(results.count, 2)   // one per api key
        for result in results {
            XCTAssertEqual(result.auth.provider, "openai-compatible-opencode")
            // Repeated alias = round-robin pool: clients still see one id.
            XCTAssertEqual(result.models?.map(\.id), ["big-model", "plain-model"])
            XCTAssertEqual(result.models?.first?.ownedBy, "opencode")
        }

        let snapshot = ModelPoolAggregator.aggregate(results)
        let group = try XCTUnwrap(snapshot.providers.first)
        XCTAssertEqual(group.provider.displayName, "opencode")
        XCTAssertEqual(group.accountCount, 2)
        XCTAssertEqual(group.models.map(\.id), ["big-model", "plain-model"])
        XCTAssertEqual(group.models.first?.accountCount, 2)
    }

    func testCompatChannelSkipsDisabledAndHandlesKeylessAndPrefix() throws {
        let root = try json("""
        {"openai-compatibility": [
          {"name": "off-channel", "disabled": true,
           "models": [{"name": "x", "alias": "y"}]},
          {"name": "keyless", "prefix": "team",
           "models": [{"name": "m1"}]}
        ]}
        """)

        let results = ConfigChannelSynthesizer.compatResults(root: root)
        XCTAssertEqual(results.count, 1)   // disabled skipped; keyless still yields one entry
        XCTAssertEqual(results.first?.auth.provider, "openai-compatible-keyless")
        // With a prefix the server registers both the plain and prefixed ids.
        XCTAssertEqual(results.first?.models?.map(\.id), ["m1", "team/m1"])

        let accounts = ConfigChannelSynthesizer.compatAccounts(root: root)
        XCTAssertEqual(
            ModelRoutingResolver.configRoutes(accounts: accounts, forceModelPrefix: false).map(\.publicModelID),
            ["m1", "team/m1"]
        )
        XCTAssertEqual(
            ModelRoutingResolver.configRoutes(accounts: accounts, forceModelPrefix: true).map(\.publicModelID),
            ["team/m1"]
        )
    }

    // MARK: api-key sections

    func testAPIKeyEntriesUseOverridesOrStaticDefaultsMinusExcluded() throws {
        let root = try json("""
        {"claude-api-key": [
          {"api-key": "sk-a",
           "models": [{"name": "claude-fable-5-internal", "alias": "claude-fable-5"}]},
          {"api-key": "sk-b",
           "excluded-models": ["*-preview", "claude-legacy"]}
        ]}
        """)

        let entries = ConfigChannelSynthesizer.apiKeyEntries(kind: .claude, root: root)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].overrideModelIDs, ["claude-fable-5"])
        XCTAssertTrue(entries[1].overrideModelIDs.isEmpty)

        let staticModels = [
            CPAModelDefinition(id: "claude-fable-5"),
            CPAModelDefinition(id: "claude-test-PREVIEW"),
            CPAModelDefinition(id: "claude-legacy")
        ]
        let results = ConfigChannelSynthesizer.apiKeyResults(kind: .claude, entries: entries, staticModels: staticModels)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].models?.map(\.id), ["claude-fable-5"])
        // Static defaults minus wildcard/exact exclusions (case-insensitive).
        XCTAssertEqual(results[1].models?.map(\.id), ["claude-fable-5"])

        let snapshot = ModelPoolAggregator.aggregate(results)
        let group = try XCTUnwrap(snapshot.providers.first)
        XCTAssertEqual(group.provider.key, "claude-api-key")
        XCTAssertEqual(group.provider.displayName, "Claude API Key")
        XCTAssertEqual(group.models.map(\.id), ["claude-fable-5"])
        XCTAssertEqual(group.models.first?.accountCount, 2)

        let accounts = ConfigChannelSynthesizer.apiKeyAccounts(kind: .claude, entries: entries, staticModels: staticModels)
        XCTAssertEqual(accounts[0].routes.map(\.name), ["claude-fable-5-internal"])
        XCTAssertEqual(accounts[0].routes.map(\.alias), ["claude-fable-5"])
        // No override: static catalog entries become truthful identity routes.
        XCTAssertEqual(accounts[1].routes.map(\.name), ["claude-fable-5"])
        XCTAssertEqual(accounts[1].routes.map(\.alias), ["claude-fable-5"])
    }

    func testAPIKeyMappingsKeepDuplicateAliasesWhileModelsStayDeduplicated() throws {
        let root = try json("""
        {"codex-api-key": [{
          "api-key": "sk-codex",
          "prefix": "team",
          "priority": "12",
          "proxy-url": "http://proxy.example",
          "models": [
            {"name": "gpt-upstream-a", "alias": "gpt-client"},
            {"name": "gpt-upstream-b", "alias": "gpt-client", "forceMapping": true}
          ]
        }]}
        """)

        let entries = ConfigChannelSynthesizer.apiKeyEntries(kind: .codex, root: root)
        XCTAssertEqual(entries.first?.overrideModelIDs, ["gpt-client"])
        XCTAssertEqual(entries.first?.overrideRoutes.map(\.name), ["gpt-upstream-a", "gpt-upstream-b"])

        let account = try XCTUnwrap(
            ConfigChannelSynthesizer.apiKeyAccounts(kind: .codex, entries: entries, staticModels: []).first
        )
        XCTAssertEqual(account.models.map(\.id), ["gpt-client", "team/gpt-client"])
        XCTAssertEqual(account.routes.map(\.alias), ["gpt-client", "gpt-client"])
        XCTAssertEqual(account.routes.map(\.publicModelID), ["team/gpt-client", "team/gpt-client"])
        XCTAssertEqual(
            ModelRoutingResolver.configRoutes(accounts: [account], forceModelPrefix: false).map(\.publicModelID),
            ["gpt-client", "team/gpt-client", "gpt-client", "team/gpt-client"]
        )
        XCTAssertEqual(
            ModelRoutingResolver.configRoutes(accounts: [account], forceModelPrefix: true).map(\.publicModelID),
            ["team/gpt-client", "team/gpt-client"]
        )
        XCTAssertTrue(account.routes[1].forceMapping)
        XCTAssertEqual(account.auth.prefix, "team")
        XCTAssertEqual(account.auth.priority, 12)
        XCTAssertEqual(account.auth.proxyURL, "http://proxy.example")
    }

    func testInteractionsAPIKeyReusesGeminiDefinitions() throws {
        XCTAssertEqual(APIKeyChannelKind.interactions.managementPath, "/v0/management/interactions-api-key")
        XCTAssertEqual(APIKeyChannelKind.interactions.definitionsChannel, "gemini")

        let root = try json("""
        {"interactions-api-key": [{"api-key": "interaction-key"}]}
        """)
        let entries = ConfigChannelSynthesizer.apiKeyEntries(kind: .interactions, root: root)
        let account = try XCTUnwrap(
            ConfigChannelSynthesizer.apiKeyAccounts(
                kind: .interactions,
                entries: entries,
                staticModels: [CPAModelDefinition(id: "gemini-3-pro")]
            ).first
        )
        XCTAssertEqual(account.models.map(\.id), ["gemini-3-pro"])
        XCTAssertEqual(account.routes.first?.name, "gemini-3-pro")
        XCTAssertEqual(account.auth.provider, "interactions-api-key")
    }

    func testWildcardExclusionMatching() {
        XCTAssertTrue(ConfigChannelSynthesizer.matchesExcluded("gpt-5.2-preview", patterns: ["*-preview"]))
        XCTAssertTrue(ConfigChannelSynthesizer.matchesExcluded("GPT-5.2", patterns: ["gpt-*"]))
        XCTAssertTrue(ConfigChannelSynthesizer.matchesExcluded("abc-mid-xyz", patterns: ["abc*mid*xyz"]))
        XCTAssertTrue(ConfigChannelSynthesizer.matchesExcluded("exact-model", patterns: ["Exact-Model"]))
        XCTAssertFalse(ConfigChannelSynthesizer.matchesExcluded("gpt-5.2", patterns: ["*-preview", "claude-*"]))
        XCTAssertFalse(ConfigChannelSynthesizer.matchesExcluded("model", patterns: []))
    }

    // MARK: dashboard accounts

    func testCompatAccountsCarryMaskedKeysAndBaseURL() throws {
        let root = try json("""
        {"openai-compatibility": [
          {"name": "opencode",
           "base-url": "https://api.opencode.example/v1",
           "api-key-entries": [{"api-key": "sk-opencode-1234567890"}, {"api-key": "sk-2"}],
           "models": [{"name": "m", "alias": "a"}]}
        ]}
        """)

        let accounts = ConfigChannelSynthesizer.compatAccounts(root: root)
        XCTAssertEqual(accounts.count, 2)
        XCTAssertEqual(accounts[0].baseURL, "https://api.opencode.example/v1")
        // Labels are masked keys, never the full secret.
        XCTAssertEqual(accounts[0].auth.displayName, "sk-ope••••••7890")
        XCTAssertFalse(accounts[0].auth.displayName.contains("sk-opencode-1234567890"))
        XCTAssertEqual(accounts[1].auth.displayName, "sk-2")
        XCTAssertEqual(accounts[0].models.map(\.id), ["a"])
    }

    func testKeylessCompatAccountFallsBackToChannelName() throws {
        let root = try json("""
        {"openai-compatibility": [{"name": "keyless", "models": [{"name": "m1"}]}]}
        """)
        let accounts = ConfigChannelSynthesizer.compatAccounts(root: root)
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.auth.displayName, "keyless")
    }

    func testAPIKeyAccountsUseMaskedKeyLabels() throws {
        let root = try json("""
        {"claude-api-key": [{"api-key": "sk-ant-abcdefghijklmn", "models": [{"name": "n", "alias": "c1"}]}]}
        """)
        let entries = ConfigChannelSynthesizer.apiKeyEntries(kind: .claude, root: root)
        let accounts = ConfigChannelSynthesizer.apiKeyAccounts(kind: .claude, entries: entries, staticModels: [])
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.auth.displayName, "sk-ant••••••klmn")
        XCTAssertEqual(accounts.first?.auth.provider, "claude-api-key")
        XCTAssertEqual(accounts.first?.models.map(\.id), ["c1"])
    }

    func testIsConfigChannelKey() {
        XCTAssertTrue(isConfigChannelKey("openai-compatible-opencode"))
        XCTAssertTrue(isConfigChannelKey("claude-api-key"))
        XCTAssertTrue(isConfigChannelKey("openai-compatibility"))
        XCTAssertFalse(isConfigChannelKey("codex"))
        XCTAssertFalse(isConfigChannelKey("claude"))
    }

    // MARK: provider catalog

    func testProviderCatalogShowsCompatChannelName() {
        let info = ProviderCatalog.info(for: "openai-compatible-opencode")
        XCTAssertEqual(info.displayName, "opencode")
        XCTAssertEqual(info.key, "openai-compatible-opencode")

        let generic = ProviderCatalog.info(for: "openai-compatibility")
        XCTAssertEqual(generic.displayName, "OpenAI Compat")

        let interactions = ProviderCatalog.info(for: "interactions-api-key")
        XCTAssertEqual(interactions.displayName, "Interactions API Key")
    }

    func testConfigChannelsSortAfterOAuthProviders() throws {
        let codexAuth = try JSONDecoder().decode(
            AuthFile.self,
            from: Data(#"{"id": "codex-a.json", "name": "codex-a.json", "provider": "codex"}"#.utf8)
        )
        let compat = ConfigChannelSynthesizer.compatResults(root: try json("""
        {"openai-compatibility": [{"name": "opencode", "models": [{"name": "big", "alias": "big"}]}]}
        """))
        let snapshot = ModelPoolAggregator.aggregate(
            [AuthModelsResult(auth: codexAuth, models: [CPAModelDefinition(id: "gpt-5.2")])] + compat
        )
        XCTAssertEqual(snapshot.providers.map(\.provider.displayName), ["Codex", "opencode"])
        XCTAssertEqual(snapshot.distinctModelCount, 2)
    }
}
