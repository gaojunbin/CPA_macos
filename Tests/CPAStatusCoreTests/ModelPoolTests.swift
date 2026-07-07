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
                CPAModelDefinition(id: "gpt-5.2"),
                CPAModelDefinition(id: "gpt-5.2")
            ])
        ])

        let group = try XCTUnwrap(snapshot.providers.first)
        XCTAssertEqual(group.models.count, 1)
        XCTAssertEqual(group.models.first?.accountCount, 1)
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
}
