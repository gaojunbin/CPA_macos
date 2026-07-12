import XCTest
@testable import CPAStatusCore

final class ModelPoolTests: XCTestCase {
    private func authFile(name: String, provider: String) throws -> AuthFile {
        let json = """
        {"id": "\(name)", "auth_index": "idx-\(name)", "name": "\(name)", "provider": "\(provider)", "type": "\(provider)"}
        """
        return try JSONDecoder().decode(AuthFile.self, from: Data(json.utf8))
    }

    func testAggregatesAndDeduplicatesAcrossAccountsOfOneProvider() throws {
        let codexA = try authFile(name: "codex-a.json", provider: "codex")
        let codexB = try authFile(name: "codex-b.json", provider: "codex")
        let snapshot = ModelPoolAggregator.aggregate([
            AuthModelsResult(auth: codexA, models: [
                CPAModelDefinition(id: "gpt-5.2"),
                CPAModelDefinition(id: "gpt-5.2-codex")
            ]),
            AuthModelsResult(auth: codexB, models: [
                CPAModelDefinition(id: "GPT-5.2", displayName: "GPT 5.2")
            ])
        ])

        XCTAssertEqual(snapshot.providers.count, 1)
        XCTAssertEqual(snapshot.queriedAccounts, 2)
        XCTAssertEqual(snapshot.failedAccounts, 0)
        XCTAssertEqual(snapshot.distinctModelCount, 2)

        let group = try XCTUnwrap(snapshot.providers.first)
        XCTAssertEqual(group.provider.key, "codex")
        XCTAssertEqual(group.accountCount, 2)
        XCTAssertEqual(group.models.map(\.id), ["gpt-5.2", "gpt-5.2-codex"])

        // Dedup is case-insensitive, keeps the first-seen id casing, and
        // fills in metadata (display name) discovered on a later account.
        let merged = try XCTUnwrap(group.models.first { $0.id == "gpt-5.2" })
        XCTAssertEqual(merged.accountCount, 2)
        XCTAssertEqual(merged.model.displayName, "GPT 5.2")

        let partial = try XCTUnwrap(group.models.first { $0.id == "gpt-5.2-codex" })
        XCTAssertEqual(partial.accountCount, 1)
    }

    func testGroupsByProviderAndSortsByCatalogPriority() throws {
        let claude = try authFile(name: "claude-a.json", provider: "claude")
        let codex = try authFile(name: "codex-a.json", provider: "codex")
        let snapshot = ModelPoolAggregator.aggregate([
            AuthModelsResult(auth: claude, models: [CPAModelDefinition(id: "claude-fable-5")]),
            AuthModelsResult(auth: codex, models: [CPAModelDefinition(id: "gpt-5.2")])
        ])

        // Codex has a lower catalog priority than Claude, so it sorts first.
        XCTAssertEqual(snapshot.providers.map(\.provider.key), ["codex", "claude"])
        XCTAssertEqual(snapshot.distinctModelCount, 2)
    }

    func testCountsFailedAccountsAndDropsEmptyProviders() throws {
        let codex = try authFile(name: "codex-a.json", provider: "codex")
        let gemini = try authFile(name: "gemini-a.json", provider: "gemini")
        let snapshot = ModelPoolAggregator.aggregate([
            AuthModelsResult(auth: codex, models: [CPAModelDefinition(id: "gpt-5.2")]),
            AuthModelsResult(auth: gemini, models: nil)
        ])

        XCTAssertEqual(snapshot.providers.map(\.provider.key), ["codex"])
        XCTAssertEqual(snapshot.queriedAccounts, 1)
        XCTAssertEqual(snapshot.failedAccounts, 1)
    }

    func testIgnoresDuplicateIdsWithinASingleAccount() throws {
        let codex = try authFile(name: "codex-a.json", provider: "codex")
        let snapshot = ModelPoolAggregator.aggregate([
            AuthModelsResult(auth: codex, models: [
                CPAModelDefinition(id: "gpt-5.2", contextLength: 200_000),
                CPAModelDefinition(id: "gpt-5.2", description: "Merged metadata", maxCompletionTokens: 64_000)
            ])
        ])

        let group = try XCTUnwrap(snapshot.providers.first)
        XCTAssertEqual(group.models.count, 1)
        XCTAssertEqual(group.models.first?.accountCount, 1)
        XCTAssertEqual(group.models.first?.model.description, "Merged metadata")
        XCTAssertEqual(group.models.first?.model.contextLength, 200_000)
        XCTAssertEqual(group.models.first?.model.maxCompletionTokens, 64_000)
    }

    func testSortsModelsByDisplayNameWithinProvider() throws {
        let codex = try authFile(name: "codex-a.json", provider: "codex")
        let snapshot = ModelPoolAggregator.aggregate([
            AuthModelsResult(auth: codex, models: [
                CPAModelDefinition(id: "z-model", displayName: "Alpha"),
                CPAModelDefinition(id: "a-model", displayName: "Beta")
            ])
        ])

        let group = try XCTUnwrap(snapshot.providers.first)
        XCTAssertEqual(group.models.map(\.displayName), ["Alpha", "Beta"])
    }

    func testDecodesSnakeAndCamelCaseModelCapabilities() throws {
        let data = Data("""
        {"models": [
          {
            "id": "claude-capable",
            "description": "Long-context reasoning model",
            "context_length": "200000",
            "max_completion_tokens": 64000,
            "supported_input_modalities": ["text", "image"],
            "supported_output_modalities": ["text"],
            "supports_web_search": "true",
            "thinking": {
              "min": "1024",
              "max": 128000,
              "zero_allowed": true,
              "dynamic_allowed": "false",
              "levels": ["low", "high"]
            }
          },
          {
            "id": "gemini-capable",
            "inputTokenLimit": 1048576,
            "outputTokenLimit": "65536",
            "supportedInputModalities": ["TEXT", "IMAGE", "AUDIO"],
            "supportedOutputModalities": ["TEXT", "IMAGE"],
            "supportsWebSearch": false,
            "thinking": {
              "minTokens": 128,
              "maxTokens": 32768,
              "zeroAllowed": false,
              "dynamicAllowed": true,
              "levels": "minimal, medium, high"
            }
          }
        ]}
        """.utf8)

        let models = try JSONDecoder().decode(ModelsResponse.self, from: data).models
        let claude = try XCTUnwrap(models.first)
        XCTAssertEqual(claude.description, "Long-context reasoning model")
        XCTAssertEqual(claude.contextLength, 200_000)
        XCTAssertEqual(claude.maxCompletionTokens, 64_000)
        XCTAssertEqual(claude.supportedInputModalities, ["text", "image"])
        XCTAssertEqual(claude.supportedOutputModalities, ["text"])
        XCTAssertEqual(claude.supportsWebSearch, true)
        XCTAssertEqual(claude.thinking?.min, 1_024)
        XCTAssertEqual(claude.thinking?.max, 128_000)
        XCTAssertEqual(claude.thinking?.zeroAllowed, true)
        XCTAssertEqual(claude.thinking?.dynamicAllowed, false)
        XCTAssertEqual(claude.thinking?.levels, ["low", "high"])

        let gemini = try XCTUnwrap(models.last)
        XCTAssertEqual(gemini.inputTokenLimit, 1_048_576)
        XCTAssertEqual(gemini.outputTokenLimit, 65_536)
        XCTAssertEqual(gemini.supportedInputModalities, ["TEXT", "IMAGE", "AUDIO"])
        XCTAssertEqual(gemini.supportedOutputModalities, ["TEXT", "IMAGE"])
        XCTAssertEqual(gemini.supportsWebSearch, false)
        XCTAssertEqual(gemini.thinking?.minimumTokens, 128)
        XCTAssertEqual(gemini.thinking?.maximumTokens, 32_768)
        XCTAssertEqual(gemini.thinking?.dynamicAllowed, true)
        XCTAssertEqual(gemini.thinking?.levels, ["minimal", "medium", "high"])
    }

    func testAggregationFillsMissingCapabilityMetadataAcrossAccounts() throws {
        let first = try authFile(name: "codex-a.json", provider: "codex")
        let second = try authFile(name: "codex-b.json", provider: "codex")
        let snapshot = ModelPoolAggregator.aggregate([
            AuthModelsResult(auth: first, models: [
                CPAModelDefinition(
                    id: "gpt-capable",
                    contextLength: 200_000,
                    supportedInputModalities: ["text"],
                    thinking: ModelThinkingCapabilities(min: 1_024, levels: ["low"])
                )
            ]),
            AuthModelsResult(auth: second, models: [
                CPAModelDefinition(
                    id: "GPT-CAPABLE",
                    description: "Capability metadata",
                    maxCompletionTokens: 64_000,
                    supportedInputModalities: ["image"],
                    supportedOutputModalities: ["text", "image"],
                    supportsWebSearch: true,
                    thinking: ModelThinkingCapabilities(max: 128_000, dynamicAllowed: true, levels: ["high"])
                )
            ])
        ])

        let model = try XCTUnwrap(snapshot.providers.first?.models.first?.model)
        XCTAssertEqual(model.id, "gpt-capable")
        XCTAssertEqual(model.description, "Capability metadata")
        XCTAssertEqual(model.contextLength, 200_000)
        XCTAssertEqual(model.maxCompletionTokens, 64_000)
        XCTAssertEqual(model.supportedInputModalities, ["text", "image"])
        XCTAssertEqual(model.supportedOutputModalities, ["text", "image"])
        XCTAssertEqual(model.supportsWebSearch, true)
        XCTAssertEqual(model.thinking?.min, 1_024)
        XCTAssertEqual(model.thinking?.max, 128_000)
        XCTAssertEqual(model.thinking?.dynamicAllowed, true)
        XCTAssertEqual(model.thinking?.levels, ["low", "high"])
    }
}
