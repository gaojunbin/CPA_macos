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
             {"name": "big-upstream-v2", "alias": "big-model"},
             {"name": "other-upstream", "alias": "big-model"},
             {"name": "plain-model"}
           ]}
        ]}
        """)

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
    }

    func testWildcardExclusionMatching() {
        XCTAssertTrue(ConfigChannelSynthesizer.matchesExcluded("gpt-5.2-preview", patterns: ["*-preview"]))
        XCTAssertTrue(ConfigChannelSynthesizer.matchesExcluded("GPT-5.2", patterns: ["gpt-*"]))
        XCTAssertTrue(ConfigChannelSynthesizer.matchesExcluded("abc-mid-xyz", patterns: ["abc*mid*xyz"]))
        XCTAssertTrue(ConfigChannelSynthesizer.matchesExcluded("exact-model", patterns: ["Exact-Model"]))
        XCTAssertFalse(ConfigChannelSynthesizer.matchesExcluded("gpt-5.2", patterns: ["*-preview", "claude-*"]))
        XCTAssertFalse(ConfigChannelSynthesizer.matchesExcluded("model", patterns: []))
    }

    // MARK: provider catalog

    func testProviderCatalogShowsCompatChannelName() {
        let info = ProviderCatalog.info(for: "openai-compatible-opencode")
        XCTAssertEqual(info.displayName, "opencode")
        XCTAssertEqual(info.key, "openai-compatible-opencode")

        let generic = ProviderCatalog.info(for: "openai-compatibility")
        XCTAssertEqual(generic.displayName, "OpenAI Compat")
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
