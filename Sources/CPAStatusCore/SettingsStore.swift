import Foundation
import Security

public final class SettingsStore {
    public static let shared = SettingsStore()

    private let defaults: UserDefaults
    private let keychain: KeychainStore

    private enum Keys {
        static let baseURL = "baseURL"
        static let refreshIntervalSeconds = "refreshIntervalSeconds"
    }

    public init(
        defaults: UserDefaults = .standard,
        keychain: KeychainStore = KeychainStore(service: "com.local.CPAStatusBar", account: "management-key")
    ) {
        self.defaults = defaults
        self.keychain = keychain
    }

    public func load() -> AppSettings {
        let baseURL = defaults.string(forKey: Keys.baseURL) ?? "http://127.0.0.1:8317"
        let interval = defaults.double(forKey: Keys.refreshIntervalSeconds)
        let key = (try? keychain.read()) ?? ""
        return AppSettings(
            baseURL: baseURL,
            managementKey: key,
            refreshIntervalSeconds: interval > 0 ? interval : 300
        )
    }

    public func save(_ settings: AppSettings) throws {
        defaults.set(settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Keys.baseURL)
        defaults.set(settings.refreshIntervalSeconds, forKey: Keys.refreshIntervalSeconds)
        try keychain.save(settings.managementKey.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

public struct KeychainStore {
    public let service: String
    public let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    public func read() throws -> String {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return ""
        }
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
        guard let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            return ""
        }
        return value
    }

    public func save(_ value: String) throws {
        if value.isEmpty {
            try delete()
            return
        }

        let data = Data(value.utf8)
        let query = baseQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError(status: updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError(status: addStatus)
        }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            return
        }
        throw KeychainError(status: status)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

public struct KeychainError: LocalizedError {
    public let status: OSStatus

    public var errorDescription: String? {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return message
        }
        return "Keychain error \(status)"
    }
}
