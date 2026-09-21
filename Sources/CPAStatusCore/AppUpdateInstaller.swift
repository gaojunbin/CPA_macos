import Foundation
import Security

public enum AppUpdateInstaller {
    public static func validateLocation(_ app: URL) throws {
        let manager = FileManager.default
        let parent = app.deletingLastPathComponent()
        guard app.pathExtension == "app", app == app.resolvingSymlinksInPath(),
              !app.path.contains("/AppTranslocation/"), !app.path.hasPrefix("/Volumes/"),
              manager.isWritableFile(atPath: app.path), manager.isWritableFile(atPath: parent.path) else {
            throw AppUpdateError.unsupportedInstallation
        }
    }

    public static func unpack(archive: URL, into directory: URL) throws -> URL {
        let listing = try run("/usr/bin/unzip", ["-Z1", archive.path])
        let paths = listing.split(whereSeparator: \.isNewline).map(String.init)
        guard !paths.isEmpty, paths.allSatisfy(isSafeArchivePath) else { throw AppUpdateError.invalidArchive }
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, directory.path])
        return directory.appendingPathComponent("CPA.app")
    }

    public static func isSafeArchivePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.hasPrefix("/") && !parts.contains("..") && !parts.contains(".") &&
            (parts.first == "CPA.app" || parts.first == "__MACOSX")
    }

    public static func validateApplication(_ app: URL, current: URL, version: AppVersion) throws {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: plist)
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "local.cpa.statusbar",
              info["CFBundleExecutable"] as? String == "CPA",
              info["CFBundleShortVersionString"] as? String == version.description,
              info["CPAUpdateProtocol"] as? Int == 1 else { throw AppUpdateError.invalidApplication }
        guard let minimum = info["LSMinimumSystemVersion"] as? String,
              isSupportedSystem(minimum) else { throw AppUpdateError.unsupportedSystem }
        let binary = app.appendingPathComponent("Contents/MacOS/CPA")
        let architectures = try run("/usr/bin/lipo", ["-archs", binary.path]).split(whereSeparator: \.isWhitespace)
        #if arch(arm64)
        let requiredArchitecture = "arm64"
        #else
        let requiredArchitecture = "x86_64"
        #endif
        guard architectures.contains(Substring(requiredArchitecture)) else {
            throw AppUpdateError.unsupportedArchitecture
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        let newIdentity = try signingIdentity(app)
        let currentIdentity = try signingIdentity(current)
        guard newIdentity.identifier == "local.cpa.statusbar",
              currentIdentity.team == nil || currentIdentity.team == newIdentity.team else {
            throw AppUpdateError.invalidApplication
        }
        let helper = app.appendingPathComponent("Contents/Helpers/CPAUpdateInstaller")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw AppUpdateError.invalidApplication }
    }

    /// Stage on the destination volume before asking the running application to exit.
    public static func stage(_ app: URL, beside current: URL) throws -> URL {
        try validateLocation(current)
        let directory = current.deletingLastPathComponent().appendingPathComponent(".cpa-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        do {
            try FileManager.default.copyItem(at: app, to: directory.appendingPathComponent("CPA.app"))
            return directory
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// Restore the previous bundle if replacement or the first launch fails.
    public static func replace(current: URL, staged: URL, launch: (URL) throws -> Void) throws {
        let manager = FileManager.default
        let backup = staged.deletingLastPathComponent().appendingPathComponent("Previous.app")
        try manager.moveItem(at: current, to: backup)
        do {
            try manager.moveItem(at: staged, to: current)
            try launch(current)
        } catch {
            if manager.fileExists(atPath: current.path) { try manager.removeItem(at: current) }
            try manager.moveItem(at: backup, to: current)
            throw AppUpdateError.installerFailed
        }
    }

    private static func isSupportedSystem(_ minimum: String) -> Bool {
        let rawParts = minimum.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(rawParts.count),
              rawParts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else { return false }
        let parts = rawParts.compactMap { Int($0) }
        guard parts.count == rawParts.count else { return false }
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(
            majorVersion: parts[0], minorVersion: parts.count > 1 ? parts[1] : 0,
            patchVersion: parts.count > 2 ? parts[2] : 0
        ))
    }

    private static func signingIdentity(_ app: URL) throws -> (identifier: String?, team: String?) {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw AppUpdateError.invalidApplication
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any] else { throw AppUpdateError.invalidApplication }
        return (values[kSecCodeInfoIdentifier as String] as? String, values[kSecCodeInfoTeamIdentifier as String] as? String)
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AppUpdateError.invalidApplication }
        return String(decoding: data, as: UTF8.self)
    }
}
