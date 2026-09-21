import AppKit
import CPAStatusCore

@MainActor
final class AppUpdateController {
    private let defaults: UserDefaults
    private let client = AppUpdateClient()
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var pending: (directory: URL, version: AppVersion)?
    private var installing = false
    private var manualInstall = false
    var canRestart: () -> Bool = { true }
    private(set) var status = "尚未检查更新"

    var automaticallyUpdates: Bool {
        defaults.bool(forKey: "automaticallyUpdatesCPA")
    }

    var actionTitle: String { pending == nil ? "检查更新…" : "安装更新并重启…" }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["automaticallyUpdatesCPA": true])
    }

    func start() {
        acknowledgeLaunch()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    func stop() {
        timer?.invalidate()
        task?.cancel()
        if !installing, let pending { try? FileManager.default.removeItem(at: pending.directory) }
    }

    func toggleAutomaticUpdates() {
        defaults.set(!automaticallyUpdates, forKey: "automaticallyUpdatesCPA")
        if automaticallyUpdates { tick() }
    }

    func checkManually() {
        if pending != nil { installPending(); return }
        check(manual: true)
    }

    private func tick() {
        if pending != nil {
            if (automaticallyUpdates || manualInstall), canRestart() { installPending() }
            return
        }
        guard automaticallyUpdates else { return }
        let lastAttempt = defaults.object(forKey: "lastCPAUpdateAttempt") as? Date ?? .distantPast
        if Date().timeIntervalSince(lastAttempt) >= 6 * 60 * 60 { check(manual: false) }
    }

    private func check(manual: Bool) {
        guard task == nil, !installing else { return }
        let current = Bundle.main.bundleURL
        guard let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let version = AppVersion(value) else {
            status = "源码运行不支持自动更新"
            if manual { showMessage(status, detail: "请使用已安装的 CPA.app。") }
            return
        }
        defaults.set(Date(), forKey: "lastCPAUpdateAttempt")
        manualInstall = manual
        status = "正在检查更新…"
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil }
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("cpa-download-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temporary) }
            do {
                guard let update = try await client.check(currentVersion: version) else {
                    status = "当前已是最新版本 \(version.description)"
                    if manual { showMessage("没有可用更新", detail: status) }
                    return
                }
                try AppUpdateInstaller.validateLocation(current)
                try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                status = "正在下载 \(update.version.description)…"
                let archive = temporary.appendingPathComponent("update.zip")
                try await client.download(update, to: archive)
                status = "正在验证更新…"
                let directory = try await Task.detached {
                    let app = try AppUpdateInstaller.unpack(archive: archive, into: temporary.appendingPathComponent("expanded"))
                    try AppUpdateInstaller.validateApplication(app, current: current, version: update.version)
                    return try AppUpdateInstaller.stage(app, beside: current)
                }.value
                if Task.isCancelled {
                    try? FileManager.default.removeItem(at: directory)
                    return
                }
                pending = (directory, update.version)
                status = "\(update.version.description) 已就绪，关闭面板后自动安装"
                if (automaticallyUpdates || manual), canRestart() { installPending() }
            } catch is CancellationError {
                status = "更新已取消"
            } catch {
                status = "更新失败，可重新检查"
                if manual { showMessage("更新未完成", detail: error.localizedDescription) }
            }
        }
    }

    private func installPending() {
        guard let pending, !installing else { return }
        installing = true
        status = "正在安装并重启…"
        Task {
            do {
                let process = Process()
                process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/CPAUpdateInstaller")
                process.arguments = [String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path,
                                     pending.directory.path, pending.version.description]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                let ready = pending.directory.appendingPathComponent("ready")
                for _ in 0..<300 {
                    if FileManager.default.fileExists(atPath: ready.path) { break }
                    guard process.isRunning else { throw AppUpdateError.installerFailed }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                guard process.isRunning, FileManager.default.fileExists(atPath: ready.path) else {
                    if process.isRunning { process.terminate() }
                    throw AppUpdateError.installerFailed
                }
                NSApp.terminate(nil)
            } catch {
                installing = false
                self.pending = nil
                try? FileManager.default.removeItem(at: pending.directory)
                status = "安装失败，当前版本保持不变"
                showMessage("更新未完成", detail: error.localizedDescription)
            }
        }
    }

    private func acknowledgeLaunch() {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--cpa-update-receipt"), args.indices.contains(index + 1) {
            let receipt = URL(fileURLWithPath: args[index + 1]).standardizedFileURL
            let directory = receipt.deletingLastPathComponent()
            if receipt.lastPathComponent == "launched", directory.lastPathComponent.hasPrefix(".cpa-update-"),
               directory.deletingLastPathComponent() == Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL {
                try? Data().write(to: receipt)
            }
        }
        if args.contains("--cpa-update-failed") {
            defaults.set(Date(), forKey: "lastCPAUpdateAttempt")
            status = "更新失败，已恢复旧版本"
            showMessage(status, detail: "可重新检查更新，或从 GitHub Release 下载安装。")
        }
    }

    private func showMessage(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
