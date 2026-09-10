import Foundation

/// Reads model metadata from config entries without retaining credential payloads.
enum ConfiguredModelMetadata {
    static func definitions(
        _ mappings: [Any]?,
        type: String,
        ownedBy: String,
        useUpstreamName: Bool
    ) -> [CPAModelDefinition] {
        (mappings ?? []).compactMap { raw in
            guard let model = raw as? [String: Any],
                  let name = firstString(model["name"])
            else { return nil }
            let alias = firstString(model["alias"]) ?? name
            var payload: [String: Any] = [
                "id": alias,
                "type": type,
                "owned_by": ownedBy,
                "display_name": firstString(model["display-name"], model["display_name"], model["displayName"])
                    ?? (useUpstreamName ? name : alias)
            ]
            if let length = integerValue(model["max-context-length"]), length > 0 {
                payload["context_length"] = length
            }
            if let thinking = firstDictionary(model["thinking"]) {
                payload["thinking"] = thinking
            }
            for (configKey, responseKey) in [
                ("input-modalities", "supported_input_modalities"),
                ("output-modalities", "supported_output_modalities")
            ] {
                if let modalities = firstArray(model[configKey]) {
                    payload[responseKey] = modalities.compactMap { firstString($0)?.lowercased() }
                }
            }
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
            return try? JSONDecoder().decode(CPAModelDefinition.self, from: data)
        }
    }
}

extension CPAModelDefinition {
    /// Prefix registration changes the ID while preserving all capability metadata.
    func withID(_ id: String) -> CPAModelDefinition {
        CPAModelDefinition(
            id: id,
            displayName: displayName,
            type: type,
            ownedBy: ownedBy,
            description: description,
            contextLength: contextLength,
            maxCompletionTokens: maxCompletionTokens,
            supportedInputModalities: supportedInputModalities,
            supportedOutputModalities: supportedOutputModalities,
            supportsWebSearch: supportsWebSearch,
            thinking: thinking
        )
    }
}
