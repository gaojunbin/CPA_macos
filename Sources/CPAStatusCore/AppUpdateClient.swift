import CryptoKit
import Foundation

public struct AppUpdateClient: Sendable {
    public static let releasesURL = URL(string: "https://github.com/gaojunbin/CPA_macos/releases")!
    public static let latestURL = URL(string: "https://api.github.com/repos/gaojunbin/CPA_macos/releases/latest")!
    private let session: URLSession

    public init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    public func check(currentVersion: AppVersion) async throws -> AppUpdate? {
        var request = URLRequest(url: Self.latestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("CPA/\(currentVersion.description)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
        try Self.validate(response)
        return try JSONDecoder().decode(AppRelease.self, from: data).update(after: currentVersion)
    }

    public func download(_ update: AppUpdate, to destination: URL) async throws {
        let request = URLRequest(url: update.asset.browserDownloadURL, timeoutInterval: 120)
        let (file, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }
        try Self.validate(response)
        try Self.verifyArchive(file, size: update.asset.size, sha256: update.sha256)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: file, to: destination)
    }

    public static func verifyArchive(_ file: URL, size: Int64, sha256: String) throws {
        let actualSize = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard actualSize.map(Int64.init) == size else { throw AppUpdateError.checksumMismatch }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        let actualHash = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actualHash == sha256.lowercased() else { throw AppUpdateError.checksumMismatch }
    }

    private static func validate(_ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw AppUpdateError.http(status) }
        guard response.url?.scheme == "https" else { throw AppUpdateError.invalidRelease }
    }
}
