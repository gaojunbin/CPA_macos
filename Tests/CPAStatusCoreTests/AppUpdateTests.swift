import CryptoKit
import XCTest
@testable import CPAStatusCore

final class AppUpdateTests: XCTestCase {
    func testGitHubChecksNeverSendManagementCredentialsAndHandleMissingReleases() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReleaseURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); ReleaseURLProtocol.status = 404 }
        let client = AppUpdateClient(session: session)
        let update = try await client.check(currentVersion: version("1.4.0"))
        XCTAssertNil(update)
        ReleaseURLProtocol.status = 403
        do {
            _ = try await client.check(currentVersion: version("1.4.0"))
            XCTFail("Rate limiting must not look like a successful check")
        } catch AppUpdateError.http(let status) {
            XCTAssertEqual(status, 403)
        }
    }

    func testStableVersionOrderingRejectsPrereleaseAndInvalidTags() throws {
        XCTAssertLessThan(try XCTUnwrap(AppVersion("1.9.9")), try XCTUnwrap(AppVersion("v1.10.0")))
        XCTAssertEqual(AppVersion("v1.4.0"), AppVersion("1.4.0"))
        for value in ["1.4", "1.4.0-beta.1", "01.4.0", "1.4.0+build", "1.4.-1", "latest", "１.4.0"] {
            XCTAssertNil(AppVersion(value), value)
        }
    }

    func testReleaseSelectionAndNoDowngrades() throws {
        let release = try fixture()
        XCTAssertEqual(try release.update(after: version("1.3.1"))?.version, version("1.4.0"))
        XCTAssertNil(try release.update(after: version("1.4.0")))
        XCTAssertNil(try release.update(after: version("2.0.0")))
        XCTAssertNil(try fixture(draft: true).update(after: version("1.3.1")))
        XCTAssertNil(try fixture(prerelease: true).update(after: version("1.3.1")))
    }

    func testRejectsUnverifiedOrForeignAssets() throws {
        for digest in [nil, "", "sha256:bad", "md5:" + String(repeating: "a", count: 64)] as [String?] {
            XCTAssertThrowsError(try fixture(digest: digest).update(after: version("1.3.1")))
        }
        for url in [
            "http://github.com/gaojunbin/CPA_macos/releases/download/v1.4.0/CPA-1.4.0-macOS.zip",
            "https://github.com/other/CPA_macos/releases/download/v1.4.0/CPA-1.4.0-macOS.zip",
            "https://example.com/CPA-1.4.0-macOS.zip",
            "https://github.com/gaojunbin/CPA_macos/releases/download/v1.4.0/CPA-1.4.0-macOS.zip?redirect=other"
        ] {
            XCTAssertThrowsError(try fixture(url: url).update(after: version("1.3.1")))
        }
        XCTAssertThrowsError(try fixture(size: 0).update(after: version("1.3.1")))
        XCTAssertThrowsError(try fixture(size: 300_000_000).update(after: version("1.3.1")))
    }

    func testArchiveDigestAndSizeAreBothRequired() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("archive.zip")
            let data = Data("synthetic archive".utf8)
            try data.write(to: file)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertNoThrow(try AppUpdateClient.verifyArchive(file, size: Int64(data.count), sha256: digest))
            XCTAssertThrowsError(try AppUpdateClient.verifyArchive(file, size: 1, sha256: digest))
            XCTAssertThrowsError(try AppUpdateClient.verifyArchive(file, size: Int64(data.count), sha256: String(repeating: "0", count: 64)))
        }
    }

    func testRejectsArchiveTraversalAndUnrelatedFiles() {
        for path in ["/CPA.app", "CPA.app/../other", "../CPA.app", "other.app/Contents", "CPA.app/./file"] {
            XCTAssertFalse(AppUpdateInstaller.isSafeArchivePath(path), path)
        }
        XCTAssertTrue(AppUpdateInstaller.isSafeArchivePath("CPA.app/Contents/MacOS/CPA"))
        XCTAssertTrue(AppUpdateInstaller.isSafeArchivePath("__MACOSX/CPA.app/._Contents"))
    }

    func testReplacementPreservesOldBundleUntilNewLaunchSucceeds() throws {
        try withBundles { current, staged in
            try AppUpdateInstaller.replace(current: current, staged: staged) { installed in
                XCTAssertEqual(try String(contentsOf: installed.appendingPathComponent("marker")), "new")
                XCTAssertTrue(FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().appendingPathComponent("Previous.app").path))
            }
            XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("marker")), "new")
        }
    }

    func testFailedLaunchRollsBackToOldBundle() throws {
        try withBundles { current, staged in
            XCTAssertThrowsError(try AppUpdateInstaller.replace(current: current, staged: staged) { _ in
                throw AppUpdateError.installerFailed
            })
            XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("marker")), "old")
        }
    }

    func testMissingStagedBundleRollsBackWithoutLaunching() throws {
        try withBundles { current, staged in
            try FileManager.default.removeItem(at: staged)
            XCTAssertThrowsError(try AppUpdateInstaller.replace(current: current, staged: staged) { _ in XCTFail("Unexpected launch") })
            XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("marker")), "old")
        }
    }

    private func version(_ value: String) -> AppVersion { AppVersion(value)! }

    private func fixture(draft: Bool = false, prerelease: Bool = false,
                         digest: String? = "sha256:" + String(repeating: "a", count: 64),
                         url: String = "https://github.com/gaojunbin/CPA_macos/releases/download/v1.4.0/CPA-1.4.0-macOS.zip",
                         size: Int = 1_000) throws -> AppRelease {
        var asset: [String: Any] = ["name": "CPA-1.4.0-macOS.zip", "size": size, "browser_download_url": url]
        if let digest { asset["digest"] = digest }
        let object: [String: Any] = ["tag_name": "v1.4.0", "draft": draft, "prerelease": prerelease, "assets": [asset]]
        return try JSONDecoder().decode(AppRelease.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func withBundles(_ body: (URL, URL) throws -> Void) throws {
        try withDirectory { directory in
            let current = directory.appendingPathComponent("CPA.app")
            let staged = directory.appendingPathComponent("stage/CPA.app")
            for (url, marker) in [(current, "old"), (staged, "new")] {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try marker.write(to: url.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
            }
            try body(current, staged)
        }
    }
}

private final class ReleaseURLProtocol: URLProtocol {
    static var status = 404
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.url, AppUpdateClient.latestURL)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
