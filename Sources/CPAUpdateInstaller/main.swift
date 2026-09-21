import AppKit
import CPAStatusCore

@main
enum UpdateInstallerMain {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count == 5, let pid = Int32(args[1]), pid > 1,
              let version = AppVersion(args[4]) else { exit(1) }
        let current = URL(fileURLWithPath: args[2]).standardizedFileURL
        let directory = URL(fileURLWithPath: args[3]).standardizedFileURL
        guard directory.lastPathComponent.hasPrefix(".cpa-update-"),
              directory.deletingLastPathComponent() == current.deletingLastPathComponent() else { exit(1) }
        let staged = directory.appendingPathComponent("CPA.app")
        let receipt = directory.appendingPathComponent("launched")
        do {
            try AppUpdateInstaller.validateLocation(current)
            try AppUpdateInstaller.validateApplication(staged, current: current, version: version)
            try Data().write(to: directory.appendingPathComponent("ready"))
            for _ in 0..<300 {
                if kill(pid, 0) != 0 { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard kill(pid, 0) != 0 else { throw AppUpdateError.installerFailed }
            try AppUpdateInstaller.replace(current: current, staged: staged) { app in
                // LaunchServices starts the new bundle; the application acknowledges didFinishLaunching.
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = ["-n", app.path, "--args", "--cpa-update-receipt", receipt.path]
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw AppUpdateError.installerFailed }
                let deadline = Date().addingTimeInterval(30)
                while !FileManager.default.fileExists(atPath: receipt.path), Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.1)
                }
                guard FileManager.default.fileExists(atPath: receipt.path) else {
                    NSRunningApplication.runningApplications(withBundleIdentifier: "local.cpa.statusbar")
                        .filter { $0.bundleURL?.standardizedFileURL == current }.forEach { $0.terminate() }
                    throw AppUpdateError.installerFailed
                }
            }
            try? FileManager.default.removeItem(at: directory)
        } catch {
            // Keep recovery artifacts if restoration itself failed; never delete the only backup.
            if !FileManager.default.fileExists(atPath: directory.appendingPathComponent("Previous.app").path) {
                try? FileManager.default.removeItem(at: directory)
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [current.path, "--args", "--cpa-update-failed"]
            try? process.run()
            exit(1)
        }
    }
}
