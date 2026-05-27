import AppKit
import CPAStatusCore

private var appDelegateRef: AppDelegate?

@main
enum CPAStatusBarMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        appDelegateRef = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SettingsStore.shared
    private var settings = AppSettings()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let controller = PopoverViewController()
    private var refreshTask: Task<Void, Never>?
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = store.load()
        configureStatusItem()
        configurePopover()
        controller.state.settings = settings
        controller.state.screen = settings.isConfigured ? .dashboard : .settings
        controller.render()

        if settings.isConfigured {
            refresh()
            restartTimer()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.showPopover(screen: .settings, refreshWhenVisible: false)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTask?.cancel()
        timer?.invalidate()
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: "CLIProxyAPI quota")
        button.imagePosition = .imageLeading
        button.title = " CPA"
        button.target = self
        button.action = #selector(togglePopover)
        updateStatusTitle()
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 430, height: 620)
        popover.contentViewController = controller

        controller.onRefresh = { [weak self] in
            self?.refresh()
        }
        controller.onOpenSettings = { [weak self] in
            self?.showPopover(screen: .settings, refreshWhenVisible: false)
        }
        controller.onSaveSettings = { [weak self] newSettings in
            self?.save(newSettings)
        }
        controller.onQuit = {
            NSApp.terminate(nil)
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        showPopover(screen: settings.isConfigured ? .dashboard : .settings, refreshWhenVisible: settings.isConfigured)
    }

    private func showPopover(screen: PopoverScreen, refreshWhenVisible: Bool) {
        controller.state.screen = screen
        controller.state.settings = settings
        controller.render()
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        if refreshWhenVisible {
            refresh()
        }
    }

    private func save(_ newSettings: AppSettings) {
        do {
            let interval = max(60, min(newSettings.refreshIntervalSeconds, 86_400))
            settings = AppSettings(
                baseURL: newSettings.baseURL,
                managementKey: newSettings.managementKey,
                refreshIntervalSeconds: interval
            )
            try store.save(settings)
            controller.state.settings = settings
            controller.state.screen = .dashboard
            controller.state.errorMessage = nil
            controller.render()
            updateStatusTitle()
            restartTimer()
            refresh()
        } catch {
            controller.state.errorMessage = error.localizedDescription
            controller.render()
        }
    }

    private func restartTimer() {
        timer?.invalidate()
        guard settings.isConfigured else { return }
        timer = Timer.scheduledTimer(withTimeInterval: settings.refreshIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    private func refresh() {
        guard settings.isConfigured else {
            controller.state.screen = .settings
            controller.state.errorMessage = "Configure the pool URL and management key first."
            controller.render()
            updateStatusTitle()
            return
        }
        if refreshTask != nil {
            return
        }

        controller.state.isLoading = true
        controller.state.errorMessage = nil
        controller.render()
        updateStatusTitle()

        let client = CLIProxyAPIClient(settings: settings)
        refreshTask = Task {
            do {
                let snapshot = try await client.fetchPoolSnapshot()
                await MainActor.run {
                    self.controller.state.snapshot = snapshot
                    self.controller.state.errorMessage = nil
                    self.controller.state.isLoading = false
                    self.refreshTask = nil
                    self.controller.render()
                    self.updateStatusTitle()
                }
            } catch {
                await MainActor.run {
                    self.controller.state.errorMessage = error.localizedDescription
                    self.controller.state.isLoading = false
                    self.refreshTask = nil
                    self.controller.render()
                    self.updateStatusTitle()
                }
            }
        }
    }

    private func updateStatusTitle() {
        guard let button = statusItem?.button else { return }
        if controller.state.isLoading {
            button.title = " ..."
            return
        }
        if controller.state.errorMessage != nil {
            button.title = " !"
            return
        }
        if let percent = controller.state.snapshot?.summary.primaryAverage {
            button.title = " \(displayPercent(percent))"
            return
        }
        button.title = " CPA"
    }
}

enum PopoverScreen {
    case dashboard
    case settings
}

struct PopoverState {
    var settings = AppSettings()
    var snapshot: PoolSnapshot?
    var screen: PopoverScreen = .dashboard
    var isLoading = false
    var errorMessage: String?
}

@MainActor
final class PopoverViewController: NSViewController {
    var state = PopoverState()
    var onRefresh: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onSaveSettings: ((AppSettings) -> Void)?
    var onQuit: (() -> Void)?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 430, height: 620))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    func render() {
        view.subviews.forEach { $0.removeFromSuperview() }

        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 16, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        switch state.screen {
        case .dashboard:
            renderDashboard(in: root)
        case .settings:
            renderSettings(in: root)
        }
    }

    private func renderDashboard(in root: NSStackView) {
        root.addArrangedSubview(headerView())

        if let error = state.errorMessage {
            root.addArrangedSubview(messageView(text: error, color: .systemRed))
        }

        if let snapshot = state.snapshot {
            root.addArrangedSubview(summaryView(snapshot.summary))
            root.addArrangedSubview(accountList(snapshot.accounts))
        } else {
            root.addArrangedSubview(emptyView(
                title: state.isLoading ? "Refreshing quotas..." : "No quota data yet",
                detail: state.isLoading ? "Fetching account pool state from CLIProxyAPI." : "Use the refresh button after configuration."
            ))
            root.addArrangedSubview(NSView())
        }

        root.addArrangedSubview(footerView())
    }

    private func renderSettings(in root: NSStackView) {
        let title = label("CLIProxyAPI Pool", font: .systemFont(ofSize: 19, weight: .semibold), color: .labelColor)
        let detail = label("Configure the deployed management endpoint and password. The password is stored in macOS Keychain.", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        detail.maximumNumberOfLines = 2
        root.addArrangedSubview(title)
        root.addArrangedSubview(detail)

        let urlField = NSTextField(string: state.settings.baseURL)
        urlField.placeholderString = "https://your-vps.example.com"
        let keyField = NSSecureTextField(frame: .zero)
        keyField.stringValue = state.settings.managementKey
        keyField.placeholderString = "Management password"
        let minutes = max(1, Int((state.settings.refreshIntervalSeconds / 60).rounded()))
        let intervalField = NSTextField(string: String(minutes))
        intervalField.placeholderString = "5"

        root.addArrangedSubview(formRow(title: "Web endpoint", field: urlField))
        root.addArrangedSubview(formRow(title: "Password", field: keyField))
        root.addArrangedSubview(formRow(title: "Refresh minutes", field: intervalField))

        if let error = state.errorMessage {
            root.addArrangedSubview(messageView(text: error, color: .systemRed))
        }

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.distribution = .fillEqually
        buttons.addArrangedSubview(CallbackButton(title: "Save and Refresh") { [weak self, weak urlField, weak keyField, weak intervalField] in
            guard let self else { return }
            let intervalMinutes = Double(intervalField?.stringValue ?? "") ?? 5
            self.onSaveSettings?(AppSettings(
                baseURL: urlField?.stringValue ?? "",
                managementKey: keyField?.stringValue ?? "",
                refreshIntervalSeconds: max(1, intervalMinutes) * 60
            ))
        })
        buttons.addArrangedSubview(CallbackButton(title: "Quit") { [weak self] in
            self?.onQuit?()
        })
        root.addArrangedSubview(buttons)
        root.addArrangedSubview(NSView())
    }

    private func headerView() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let titleStack = NSStackView()
        titleStack.orientation = .vertical
        titleStack.spacing = 2
        titleStack.addArrangedSubview(label("CPA Quota", font: .systemFont(ofSize: 19, weight: .semibold), color: .labelColor))
        titleStack.addArrangedSubview(label(lastUpdatedText(), font: .systemFont(ofSize: 11), color: .secondaryLabelColor))
        row.addArrangedSubview(titleStack)
        row.addArrangedSubview(NSView())

        let refresh = CallbackButton(title: "") { [weak self] in self?.onRefresh?() }
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        refresh.toolTip = "Refresh quotas"
        refresh.bezelStyle = .rounded
        refresh.isEnabled = !state.isLoading
        refresh.widthAnchor.constraint(equalToConstant: 34).isActive = true
        row.addArrangedSubview(refresh)

        let settings = CallbackButton(title: "") { [weak self] in self?.onOpenSettings?() }
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
        settings.toolTip = "Settings"
        settings.bezelStyle = .rounded
        settings.widthAnchor.constraint(equalToConstant: 34).isActive = true
        row.addArrangedSubview(settings)

        return row
    }

    private func summaryView(_ summary: PoolSummary) -> NSView {
        let card = RoundedView(fill: NSColor.controlBackgroundColor, border: NSColor.separatorColor.withAlphaComponent(0.45))
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        row.distribution = .fillEqually
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12)
        ])

        row.addArrangedSubview(statView(title: "Accounts", value: "\(summary.quotaAccounts)/\(summary.totalAccounts)"))
        row.addArrangedSubview(statView(title: "5h avg", value: displayPercent(summary.primaryAverage)))
        row.addArrangedSubview(statView(title: "7d avg", value: displayPercent(summary.weeklyAverage)))
        row.addArrangedSubview(statView(title: "Errors", value: "\(summary.errorAccounts)"))
        return card
    }

    private func statView(title: String, value: String) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.addArrangedSubview(label(value, font: .monospacedDigitSystemFont(ofSize: 17, weight: .semibold), color: .labelColor))
        stack.addArrangedSubview(label(title, font: .systemFont(ofSize: 10, weight: .medium), color: .secondaryLabelColor))
        return stack
    }

    private func accountList(_ accounts: [AccountQuota]) -> NSView {
        guard !accounts.isEmpty else {
            return emptyView(title: "No Codex accounts", detail: "The management API did not return Codex/OpenAI account entries.")
        }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack

        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])

        for account in accounts {
            stack.addArrangedSubview(accountRow(account))
        }

        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 350).isActive = true
        return scroll
    }

    private func accountRow(_ account: AccountQuota) -> NSView {
        let card = RoundedView(fill: NSColor.textBackgroundColor, border: NSColor.separatorColor.withAlphaComponent(0.5))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10)
        ])

        let top = NSStackView()
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 8
        let name = label(account.auth.displayName, font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor)
        name.lineBreakMode = .byTruncatingMiddle
        top.addArrangedSubview(name)
        top.addArrangedSubview(NSView())
        top.addArrangedSubview(pill(text: account.effectivePlanType ?? account.auth.normalizedProvider.uppercased(), color: .systemBlue))
        top.addArrangedSubview(pill(text: account.statusText, color: statusColor(account)))
        stack.addArrangedSubview(top)

        stack.addArrangedSubview(quotaLine(title: "5h", window: account.usage?.primary))
        stack.addArrangedSubview(quotaLine(title: "7d", window: account.usage?.weekly))

        if let error = account.errorMessage, !error.isEmpty {
            let errorLabel = label(error, font: .systemFont(ofSize: 11), color: .systemRed)
            errorLabel.maximumNumberOfLines = 2
            stack.addArrangedSubview(errorLabel)
        }
        return card
    }

    private func quotaLine(title: String, window: QuotaWindow?) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        let titleLabel = label(title, font: .monospacedDigitSystemFont(ofSize: 11, weight: .medium), color: .secondaryLabelColor)
        titleLabel.widthAnchor.constraint(equalToConstant: 24).isActive = true
        row.addArrangedSubview(titleLabel)

        let bar = QuotaBarView()
        bar.value = window?.remainingPercent ?? 0
        bar.isMuted = window?.remainingPercent == nil
        bar.heightAnchor.constraint(equalToConstant: 8).isActive = true
        row.addArrangedSubview(bar)

        let percent = label(displayPercent(window?.remainingPercent), font: .monospacedDigitSystemFont(ofSize: 11, weight: .semibold), color: .labelColor)
        percent.alignment = .right
        percent.widthAnchor.constraint(equalToConstant: 46).isActive = true
        row.addArrangedSubview(percent)

        let reset = label(resetText(window), font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular), color: .secondaryLabelColor)
        reset.alignment = .right
        reset.widthAnchor.constraint(equalToConstant: 58).isActive = true
        row.addArrangedSubview(reset)
        return row
    }

    private func footerView() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        let hint = label("Click refresh for live quota via wham/usage.", font: .systemFont(ofSize: 11), color: .tertiaryLabelColor)
        row.addArrangedSubview(hint)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(CallbackButton(title: "Quit") { [weak self] in self?.onQuit?() })
        return row
    }

    private func formRow(title: String, field: NSTextField) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 6
        stack.addArrangedSubview(label(title, font: .systemFont(ofSize: 11, weight: .medium), color: .secondaryLabelColor))
        field.font = .systemFont(ofSize: 13)
        field.heightAnchor.constraint(equalToConstant: 30).isActive = true
        stack.addArrangedSubview(field)
        return stack
    }

    private func emptyView(title: String, detail: String) -> NSView {
        let box = RoundedView(fill: NSColor.controlBackgroundColor, border: NSColor.separatorColor.withAlphaComponent(0.4))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        stack.addArrangedSubview(label(title, font: .systemFont(ofSize: 14, weight: .semibold), color: .labelColor))
        let detailLabel = label(detail, font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 2
        stack.addArrangedSubview(detailLabel)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -20),
            stack.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            box.heightAnchor.constraint(equalToConstant: 170)
        ])
        return box
    }

    private func messageView(text: String, color: NSColor) -> NSView {
        let box = RoundedView(fill: color.withAlphaComponent(0.10), border: color.withAlphaComponent(0.25))
        let textLabel = label(text, font: .systemFont(ofSize: 12), color: color)
        textLabel.maximumNumberOfLines = 3
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(textLabel)
        NSLayoutConstraint.activate([
            textLabel.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            textLabel.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            textLabel.topAnchor.constraint(equalTo: box.topAnchor, constant: 9),
            textLabel.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -9)
        ])
        return box
    }

    private func pill(text: String, color: NSColor) -> NSView {
        let label = label(text.isEmpty ? "-" : text, font: .systemFont(ofSize: 10, weight: .semibold), color: color)
        label.alignment = .center
        let view = RoundedView(fill: color.withAlphaComponent(0.12), border: color.withAlphaComponent(0.22), radius: 6)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: view.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -3)
        ])
        return view
    }

    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    private func lastUpdatedText() -> String {
        if state.isLoading {
            return "Refreshing live quota..."
        }
        guard let date = state.snapshot?.fetchedAt else {
            return "Not refreshed yet"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Updated \(formatter.localizedString(for: date, relativeTo: Date()))"
    }

    private func resetText(_ window: QuotaWindow?) -> String {
        guard let window else { return "-" }
        if let seconds = window.resetAfterSeconds {
            return displayDuration(seconds: seconds)
        }
        if let resetAt = window.resetAt {
            let remaining = resetAt.timeIntervalSinceNow
            return remaining > 0 ? displayDuration(seconds: remaining) : "now"
        }
        return "-"
    }

    private func statusColor(_ account: AccountQuota) -> NSColor {
        if account.errorMessage != nil {
            return .systemRed
        }
        if account.isUnavailable {
            return .systemGray
        }
        if let remaining = account.primaryRemainingPercent {
            if remaining <= 20 { return .systemRed }
            if remaining <= 60 { return .systemOrange }
            return .systemGreen
        }
        return .systemBlue
    }
}

@MainActor
final class CallbackButton: NSButton {
    private var callback: (() -> Void)?

    init(title: String, callback: @escaping () -> Void) {
        self.callback = callback
        super.init(frame: .zero)
        self.title = title
        self.bezelStyle = .rounded
        self.target = self
        self.action = #selector(runCallback)
        self.font = .systemFont(ofSize: 12, weight: .medium)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    @objc private func runCallback() {
        callback?()
    }
}

final class RoundedView: NSView {
    init(fill: NSColor, border: NSColor, radius: CGFloat = 8) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = fill.cgColor
        layer?.borderColor = border.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = radius
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
}

final class QuotaBarView: NSView {
    var value: Double = 0 {
        didSet { needsDisplay = true }
    }
    var isMuted = false {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 120, height: 8)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0, dy: 1)
        NSColor.separatorColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()

        guard !isMuted else { return }
        let clamped = max(0, min(100, value))
        let fillWidth = rect.width * CGFloat(clamped / 100)
        guard fillWidth > 0 else { return }
        barColor(for: clamped).setFill()
        let fillRect = NSRect(x: rect.minX, y: rect.minY, width: fillWidth, height: rect.height)
        NSBezierPath(roundedRect: fillRect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
    }

    private func barColor(for value: Double) -> NSColor {
        if value <= 20 { return .systemRed }
        if value <= 60 { return .systemOrange }
        return .systemGreen
    }
}
