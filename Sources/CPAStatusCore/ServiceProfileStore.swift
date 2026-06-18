import Foundation

/// Persisted metadata for one CLIProxyAPI service ("号池"). The management key is kept in
/// the Keychain (keyed by `id`), never in this struct.
public struct ServiceProfile: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var baseURL: String
    public var refreshIntervalSeconds: TimeInterval

    public init(
        id: UUID = UUID(),
        name: String,
        baseURL: String,
        refreshIntervalSeconds: TimeInterval = 300
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.refreshIntervalSeconds = refreshIntervalSeconds
    }

    public var displayHost: String {
        let raw = baseURL.contains("://") ? baseURL : "https://\(baseURL)"
        return URL(string: raw)?.host ?? baseURL
    }
}

/// Manages the list of services, the current selection, and each service's Keychain key.
/// Migrates a pre-multi-service install (single `baseURL` + one key) into one profile.
public final class ServiceProfileStore {
    public static let shared = ServiceProfileStore()

    private let defaults: UserDefaults
    private let keychainService: String

    private enum Keys {
        static let profiles = "services.v1"
        static let selectedID = "services.selectedID"
        // Legacy single-service storage.
        static let legacyBaseURL = "baseURL"
        static let legacyRefreshInterval = "refreshIntervalSeconds"
        static let legacyKeychainAccount = "management-key"
    }

    public init(defaults: UserDefaults = .standard, keychainService: String = "com.local.CPAStatusBar") {
        self.defaults = defaults
        self.keychainService = keychainService
    }

    // MARK: Keychain (one entry per profile)

    private func keychain(for id: UUID) -> KeychainStore {
        KeychainStore(service: keychainService, account: id.uuidString)
    }

    public func managementKey(for id: UUID) -> String {
        (try? keychain(for: id).read()) ?? ""
    }

    public func saveManagementKey(_ value: String, for id: UUID) throws {
        try keychain(for: id).save(value)
    }

    public func deleteManagementKey(for id: UUID) {
        try? keychain(for: id).delete()
    }

    // MARK: Profiles

    public func loadProfiles() -> [ServiceProfile] {
        migrateLegacyIfNeeded()
        guard let data = defaults.data(forKey: Keys.profiles),
              let profiles = try? JSONDecoder().decode([ServiceProfile].self, from: data) else {
            return []
        }
        return profiles
    }

    public func saveProfiles(_ profiles: [ServiceProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else {
            return
        }
        defaults.set(data, forKey: Keys.profiles)
    }

    public func selectedID() -> UUID? {
        guard let raw = defaults.string(forKey: Keys.selectedID) else {
            return nil
        }
        return UUID(uuidString: raw)
    }

    public func setSelectedID(_ id: UUID?) {
        if let id {
            defaults.set(id.uuidString, forKey: Keys.selectedID)
        } else {
            defaults.removeObject(forKey: Keys.selectedID)
        }
    }

    // MARK: Resolve

    public func settings(for profile: ServiceProfile) -> AppSettings {
        AppSettings(
            baseURL: profile.baseURL,
            managementKey: managementKey(for: profile.id),
            refreshIntervalSeconds: profile.refreshIntervalSeconds
        )
    }

    // MARK: Migration

    /// Idempotent: once `profiles` exists this is a no-op.
    public func migrateLegacyIfNeeded() {
        guard defaults.data(forKey: Keys.profiles) == nil else {
            return
        }
        let legacyURL = (defaults.string(forKey: Keys.legacyBaseURL) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let legacyKey = (try? KeychainStore(service: keychainService, account: Keys.legacyKeychainAccount).read()) ?? ""
        guard !legacyURL.isEmpty, !legacyKey.isEmpty else {
            // Nothing usable; record an empty list so this only runs once.
            saveProfiles([])
            return
        }

        let interval = defaults.double(forKey: Keys.legacyRefreshInterval)
        let raw = legacyURL.contains("://") ? legacyURL : "https://\(legacyURL)"
        let host = URL(string: raw)?.host ?? legacyURL
        let profile = ServiceProfile(
            name: host,
            baseURL: legacyURL,
            refreshIntervalSeconds: interval > 0 ? interval : 300
        )

        do {
            try saveManagementKey(legacyKey, for: profile.id)
        } catch {
            // Leave legacy data intact and retry on next launch.
            return
        }
        saveProfiles([profile])
        setSelectedID(profile.id)

        try? KeychainStore(service: keychainService, account: Keys.legacyKeychainAccount).delete()
        defaults.removeObject(forKey: Keys.legacyBaseURL)
        defaults.removeObject(forKey: Keys.legacyRefreshInterval)
    }
}
