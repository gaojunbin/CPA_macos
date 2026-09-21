import Foundation

public struct AppVersion: Comparable, Equatable, Sendable {
    public let components: [Int]
    public let description: String

    public init?(_ value: String) {
        let normalized = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              parts.allSatisfy({ $0.count == 1 || !$0.hasPrefix("0") }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        components = numbers
        description = normalized
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

public struct AppRelease: Decodable, Sendable {
    public struct Asset: Decodable, Sendable {
        public let name: String
        public let size: Int64
        public let digest: String?
        public let browserDownloadURL: URL
        enum CodingKeys: String, CodingKey {
            case name, size, digest
            case browserDownloadURL = "browser_download_url"
        }
    }

    public let tagName: String
    public let draft: Bool
    public let prerelease: Bool
    public let assets: [Asset]
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case draft, prerelease, assets
    }

    public func update(after current: AppVersion) throws -> AppUpdate? {
        guard !draft, !prerelease, let version = AppVersion(tagName), version > current else { return nil }
        let name = "CPA-\(version.description)-macOS.zip"
        guard let asset = assets.first(where: { $0.name == name }),
              asset.size > 0, asset.size <= 200 * 1_024 * 1_024,
              let digest = asset.digest, digest.hasPrefix("sha256:") else {
            throw AppUpdateError.invalidRelease
        }
        let hash = String(digest.dropFirst(7)).lowercased()
        guard hash.count == 64, hash.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              Self.isRepositoryAsset(asset.browserDownloadURL, tag: tagName, name: name) else {
            throw AppUpdateError.invalidRelease
        }
        return AppUpdate(version: version, asset: asset, sha256: hash)
    }

    private static func isRepositoryAsset(_ url: URL, tag: String, name: String) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.port == nil &&
        url.user == nil && url.password == nil && url.query == nil && url.fragment == nil &&
        url.path == "/gaojunbin/CPA_macos/releases/download/\(tag)/\(name)"
    }
}

public struct AppUpdate: Sendable {
    public let version: AppVersion
    public let asset: AppRelease.Asset
    public let sha256: String
}

public enum AppUpdateError: Error, LocalizedError {
    case invalidRelease, invalidArchive, invalidApplication, checksumMismatch
    case unsupportedInstallation, unsupportedSystem, unsupportedArchitecture, installerFailed
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidRelease: return "The release does not contain a verified CPA update archive."
        case .invalidArchive: return "The update archive contains invalid paths."
        case .invalidApplication: return "The update application identity, version, or signature is invalid."
        case .checksumMismatch: return "The update archive checksum or size does not match GitHub."
        case .unsupportedInstallation: return "Install CPA in a writable Applications folder before updating."
        case .unsupportedSystem: return "This release requires a newer version of macOS."
        case .unsupportedArchitecture: return "This release does not support this Mac's architecture."
        case .installerFailed: return "The update could not be installed. The previous application was preserved."
        case .http(let status): return "GitHub update request failed (HTTP \(status))."
        }
    }
}
