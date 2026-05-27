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
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(togglePopover)
        button.imageHugsTitle = true
        updateStatusTitle()
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 380, height: 560)
        popover.contentViewController = controller

        controller.onRefresh = { [weak self] in
            self?.refresh()
        }
        controller.onOpenSettings = { [weak self] in
            self?.showPopover(screen: .settings, refreshWhenVisible: false)
        }
        controller.onCloseSettings = { [weak self] in
            guard let self else { return }
            if self.settings.isConfigured {
                self.controller.state.screen = .dashboard
                self.controller.state.errorMessage = nil
                self.controller.render()
            }
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
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)

        if !settings.isConfigured {
            button.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Configure")?
                .withSymbolConfiguration(config)
            button.image?.isTemplate = true
            button.contentTintColor = nil
            button.attributedTitle = NSAttributedString(string: "")
            return
        }

        let percent = controller.state.snapshot?.summary.primaryAverage
        let symbolName = gaugeSymbol(for: percent)
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "CLIProxyAPI quota")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = nil

        let isInitialLoad = controller.state.isLoading && controller.state.snapshot == nil
        let hasError = controller.state.errorMessage != nil && controller.state.snapshot == nil

        if isInitialLoad {
            button.attributedTitle = menuBarTitle("  ⋯", color: .secondaryLabelColor)
            return
        }
        if hasError {
            button.attributedTitle = menuBarTitle("  !", color: .systemRed)
            return
        }
        if let percent {
            button.attributedTitle = menuBarTitle("  \(displayPercent(percent))", color: menuBarColor(for: percent))
            return
        }
        button.attributedTitle = NSAttributedString(string: "")
    }

    private func menuBarTitle(_ text: String, color: NSColor) -> NSAttributedString {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: color
        ]
        return NSAttributedString(string: text, attributes: attributes)
    }

    private func gaugeSymbol(for percent: Double?) -> String {
        guard let percent else { return "gauge.with.dots.needle.50percent" }
        if percent >= 67 { return "gauge.with.dots.needle.67percent" }
        if percent >= 33 { return "gauge.with.dots.needle.50percent" }
        if percent >= 1 { return "gauge.with.dots.needle.33percent" }
        return "gauge.with.dots.needle.0percent"
    }

    private func menuBarColor(for percent: Double) -> NSColor {
        if percent <= 15 { return .systemRed }
        if percent <= 35 { return .systemOrange }
        return .labelColor
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
    var onCloseSettings: (() -> Void)?
    var onSaveSettings: ((AppSettings) -> Void)?
    var onQuit: (() -> Void)?

    private let popoverWidth: CGFloat = 380
    private let popoverHeight: CGFloat = 560

    override func loadView() {
        let frame = NSRect(x: 0, y: 0, width: popoverWidth, height: popoverHeight)
        let container = NSView(frame: frame)

        let vibrancy = NSVisualEffectView(frame: frame)
        vibrancy.material = .popover
        vibrancy.blendingMode = .behindWindow
        vibrancy.state = .active
        vibrancy.autoresizingMask = [.width, .height]
        container.addSubview(vibrancy)

        view = container
    }

    func render() {
        view.subviews
            .filter { !($0 is NSVisualEffectView) }
            .forEach { $0.removeFromSuperview() }

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 14, right: 16)
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

    private func addFullWidth(_ subview: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(subview)
        let inset: CGFloat = (stack.edgeInsets.left + stack.edgeInsets.right)
        subview.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -inset).isActive = true
    }

    private func renderDashboard(in root: NSStackView) {
        addFullWidth(headerView(), to: root)

        if let error = state.errorMessage {
            addFullWidth(messageView(text: error), to: root)
        }

        if let snapshot = state.snapshot {
            addFullWidth(summaryView(snapshot.summary), to: root)
            addFullWidth(providerSections(snapshot.providers), to: root)
        } else {
            addFullWidth(emptyDashboardView(), to: root)
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
            root.addArrangedSubview(spacer)
        }
    }

    private func renderSettings(in root: NSStackView) {
        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .top
        titleRow.spacing = 8

        let titleStack = NSStackView()
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2
        titleStack.addArrangedSubview(label("Settings", font: .systemFont(ofSize: 18, weight: .semibold), color: .labelColor))
        titleStack.addArrangedSubview(label("Where to reach your pool.", font: .systemFont(ofSize: 12), color: .secondaryLabelColor))
        titleRow.addArrangedSubview(titleStack)
        titleRow.addArrangedSubview(NSView())

        if state.settings.isConfigured {
            titleRow.addArrangedSubview(circularIconButton(symbol: "xmark", tooltip: "Close") { [weak self] in
                self?.onCloseSettings?()
            })
        }
        addFullWidth(titleRow, to: root)

        let urlField = NSTextField(string: state.settings.baseURL)
        urlField.placeholderString = "https://your-vps.example.com"
        let keyField = NSSecureTextField(frame: .zero)
        keyField.stringValue = state.settings.managementKey
        keyField.placeholderString = "Management password"
        let minutes = max(1, Int((state.settings.refreshIntervalSeconds / 60).rounded()))
        let intervalField = NSTextField(string: String(minutes))
        intervalField.placeholderString = "5"

        let formCard = cardView()
        let formStack = NSStackView()
        formStack.orientation = .vertical
        formStack.alignment = .leading
        formStack.spacing = 16
        formStack.translatesAutoresizingMaskIntoConstraints = false
        formCard.addSubview(formStack)
        NSLayoutConstraint.activate([
            formStack.leadingAnchor.constraint(equalTo: formCard.leadingAnchor, constant: 14),
            formStack.trailingAnchor.constraint(equalTo: formCard.trailingAnchor, constant: -14),
            formStack.topAnchor.constraint(equalTo: formCard.topAnchor, constant: 14),
            formStack.bottomAnchor.constraint(equalTo: formCard.bottomAnchor, constant: -14)
        ])

        let endpointRow = settingRow(
            symbol: "network",
            title: "Endpoint",
            field: urlField,
            stretch: true
        )
        let passwordRow = settingRow(
            symbol: "lock.fill",
            title: "Password",
            field: keyField,
            stretch: true
        )
        let refreshRow = settingRow(
            symbol: "arrow.triangle.2.circlepath",
            title: "Refresh interval",
            field: intervalField,
            stretch: false,
            fieldWidth: 64,
            suffix: "minutes"
        )

        [endpointRow, passwordRow, refreshRow].forEach { row in
            formStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: formStack.widthAnchor).isActive = true
        }

        addFullWidth(formCard, to: root)

        if let error = state.errorMessage {
            addFullWidth(messageView(text: error), to: root)
        }

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        root.addArrangedSubview(spacer)

        let saveButton = primaryButton(title: "Save") { [weak urlField, weak keyField, weak intervalField, weak self] in
            guard let self else { return }
            let intervalMinutes = Double(intervalField?.stringValue ?? "") ?? 5
            self.onSaveSettings?(AppSettings(
                baseURL: urlField?.stringValue ?? "",
                managementKey: keyField?.stringValue ?? "",
                refreshIntervalSeconds: max(1, intervalMinutes) * 60
            ))
        }

        let quitLink = linkButton(title: "Quit") { [weak self] in
            self?.onQuit?()
        }

        let buttonRow = NSView()
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        quitLink.translatesAutoresizingMaskIntoConstraints = false
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.addSubview(quitLink)
        buttonRow.addSubview(saveButton)
        NSLayoutConstraint.activate([
            quitLink.leadingAnchor.constraint(equalTo: buttonRow.leadingAnchor),
            quitLink.centerYAnchor.constraint(equalTo: buttonRow.centerYAnchor),
            saveButton.trailingAnchor.constraint(equalTo: buttonRow.trailingAnchor),
            saveButton.centerYAnchor.constraint(equalTo: buttonRow.centerYAnchor),
            buttonRow.heightAnchor.constraint(equalTo: saveButton.heightAnchor)
        ])

        addFullWidth(buttonRow, to: root)
    }

    private func settingRow(
        symbol: String,
        title: String,
        field: NSTextField,
        stretch: Bool,
        fieldWidth: CGFloat? = nil,
        suffix: String? = nil
    ) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        header.addArrangedSubview(icon)

        let titleLabel = label(title, font: .systemFont(ofSize: 11, weight: .semibold), color: .secondaryLabelColor)
        header.addArrangedSubview(titleLabel)

        container.addSubview(header)

        field.font = .systemFont(ofSize: 13)
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        field.translatesAutoresizingMaskIntoConstraints = false

        if let suffix {
            let inputRow = NSStackView()
            inputRow.orientation = .horizontal
            inputRow.alignment = .centerY
            inputRow.spacing = 8
            inputRow.translatesAutoresizingMaskIntoConstraints = false

            if let fieldWidth {
                field.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
            }
            field.heightAnchor.constraint(equalToConstant: 26).isActive = true
            inputRow.addArrangedSubview(field)
            inputRow.addArrangedSubview(label(suffix, font: .systemFont(ofSize: 12), color: .secondaryLabelColor))
            if stretch {
                inputRow.addArrangedSubview(NSView())
            }

            container.addSubview(inputRow)
            NSLayoutConstraint.activate([
                header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                header.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
                header.topAnchor.constraint(equalTo: container.topAnchor),
                inputRow.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                inputRow.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                inputRow.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
                inputRow.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
        } else {
            field.heightAnchor.constraint(equalToConstant: 28).isActive = true
            container.addSubview(field)
            NSLayoutConstraint.activate([
                header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                header.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
                header.topAnchor.constraint(equalTo: container.topAnchor),
                field.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                field.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
                field.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
        }

        return container
    }

    private func headerView() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6

        let titleStack = NSStackView()
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 1
        titleStack.addArrangedSubview(label("AI Usage", font: .systemFont(ofSize: 18, weight: .semibold), color: .labelColor))
        titleStack.addArrangedSubview(label(subtitleText(), font: .systemFont(ofSize: 11), color: .secondaryLabelColor))
        row.addArrangedSubview(titleStack)
        row.addArrangedSubview(NSView())

        let refresh = circularIconButton(symbol: "arrow.clockwise", tooltip: "Refresh") { [weak self] in
            self?.onRefresh?()
        }
        refresh.isEnabled = !state.isLoading
        row.addArrangedSubview(refresh)

        let settings = circularIconButton(symbol: "gearshape", tooltip: "Settings") { [weak self] in
            self?.onOpenSettings?()
        }
        row.addArrangedSubview(settings)

        return row
    }

    private func summaryView(_ summary: PoolSummary) -> NSView {
        let card = cardView()
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 0
        row.alignment = .centerY
        row.distribution = .fillEqually
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14)
        ])

        row.addArrangedSubview(statView(
            value: displayPercent(summary.primaryAverage),
            label: "5h",
            color: summaryColor(summary.primaryAverage)
        ))
        row.addArrangedSubview(statView(
            value: displayPercent(summary.weeklyAverage),
            label: "7d",
            color: summaryColor(summary.weeklyAverage)
        ))
        let accountText = (summary.quotaAccounts == summary.totalAccounts || summary.quotaAccounts == 0)
            ? "\(summary.totalAccounts)"
            : "\(summary.quotaAccounts)/\(summary.totalAccounts)"
        row.addArrangedSubview(statView(
            value: accountText,
            label: summary.totalAccounts == 1 ? "Account" : "Accounts",
            color: .labelColor
        ))
        return card
    }

    private func statView(value: String, label labelText: String, color: NSColor) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        let valueLabel = label(value, font: .monospacedDigitSystemFont(ofSize: 22, weight: .semibold), color: color)
        valueLabel.alignment = .center
        stack.addArrangedSubview(valueLabel)
        let descLabel = label(labelText, font: .systemFont(ofSize: 11, weight: .medium), color: .secondaryLabelColor)
        descLabel.alignment = .center
        stack.addArrangedSubview(descLabel)
        return stack
    }

    private func providerSections(_ providers: [ProviderPool]) -> NSView {
        let populated = providers.filter { !$0.accounts.isEmpty }
        guard !populated.isEmpty else {
            return placeholderCard(
                symbol: "tray",
                title: "No accounts",
                detail: "The pool didn’t return any accounts."
            )
        }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        let stack = TopAlignedStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 4, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack

        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])

        for pool in populated {
            let section = providerSection(pool)
            stack.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        return scroll
    }

    private func providerSection(_ pool: ProviderPool) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let header = providerHeader(pool)
        let cards = TopAlignedStackView()
        cards.orientation = .vertical
        cards.alignment = .leading
        cards.spacing = 6
        cards.translatesAutoresizingMaskIntoConstraints = false

        for account in pool.accounts {
            let row = accountRow(account, supportsUsage: pool.provider.supportsUsage)
            cards.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: cards.widthAnchor).isActive = true
        }

        container.addSubview(header)
        container.addSubview(cards)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.topAnchor.constraint(equalTo: container.topAnchor),
            cards.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            cards.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            cards.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            cards.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    private func providerHeader(_ pool: ProviderPool) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let accent = providerAccentColor(pool.provider.accentName)

        let badge = RoundedView(
            fill: accent.withAlphaComponent(0.16),
            border: .clear,
            radius: 6
        )
        badge.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 22),
            badge.heightAnchor.constraint(equalToConstant: 22)
        ])

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        let icon = NSImageView(image: NSImage(systemSymbolName: pool.provider.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig) ?? NSImage())
        icon.contentTintColor = accent
        icon.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: badge.centerYAnchor)
        ])

        row.addArrangedSubview(badge)

        let title = label(pool.provider.displayName, font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor)
        row.addArrangedSubview(title)

        if !pool.provider.supportsUsage {
            let hint = label("identity only", font: .systemFont(ofSize: 10, weight: .regular), color: .tertiaryLabelColor)
            row.addArrangedSubview(hint)
        }

        row.addArrangedSubview(NSView())

        let countPill = RoundedView(
            fill: NSColor.tertiaryLabelColor.withAlphaComponent(0.12),
            border: .clear,
            radius: 8
        )
        let countLabel = label("\(pool.accounts.count)", font: .monospacedDigitSystemFont(ofSize: 11, weight: .semibold), color: .secondaryLabelColor)
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countPill.addSubview(countLabel)
        NSLayoutConstraint.activate([
            countLabel.centerXAnchor.constraint(equalTo: countPill.centerXAnchor),
            countLabel.centerYAnchor.constraint(equalTo: countPill.centerYAnchor),
            countPill.widthAnchor.constraint(greaterThanOrEqualToConstant: 22),
            countPill.heightAnchor.constraint(equalToConstant: 18),
            countLabel.leadingAnchor.constraint(equalTo: countPill.leadingAnchor, constant: 6),
            countLabel.trailingAnchor.constraint(equalTo: countPill.trailingAnchor, constant: -6)
        ])
        row.addArrangedSubview(countPill)
        return row
    }

    private func providerAccentColor(_ name: String) -> NSColor {
        switch name {
        case "teal": return .systemTeal
        case "mint": return .systemMint
        case "orange": return .systemOrange
        case "blue": return .systemBlue
        case "indigo": return .systemIndigo
        case "purple": return .systemPurple
        case "gray": return .systemGray
        case "pink": return .systemPink
        case "red": return .systemRed
        case "green": return .systemGreen
        case "yellow": return .systemYellow
        default: return .secondaryLabelColor
        }
    }

    private func accountRow(_ account: AccountQuota, supportsUsage: Bool = true) -> NSView {
        if !supportsUsage {
            return compactAccountRow(account)
        }
        let card = cardView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
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
        top.translatesAutoresizingMaskIntoConstraints = false

        top.addArrangedSubview(statusDot(account))

        let name = label(account.auth.displayName, font: .systemFont(ofSize: 13, weight: .medium), color: .labelColor)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        top.addArrangedSubview(name)
        top.addArrangedSubview(NSView())

        if let plan = account.effectivePlanType, !plan.isEmpty {
            top.addArrangedSubview(planPill(text: plan))
        }
        stack.addArrangedSubview(top)
        top.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        if account.isDisabled {
            stack.addArrangedSubview(noteLabel(text: "Paused"))
        } else if let error = account.errorMessage, !error.isEmpty {
            stack.addArrangedSubview(noteLabel(text: trimError(error), color: .systemRed))
        } else if account.isUnavailable {
            stack.addArrangedSubview(noteLabel(text: "Unavailable"))
        } else if account.usage?.hasQuotaSignal == true {
            for (labelText, window) in quotaRows(for: account.usage) {
                let row = quotaLine(label: labelText, window: window)
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        } else {
            stack.addArrangedSubview(noteLabel(text: "No quota signal yet"))
        }
        return card
    }

    private func quotaRows(for usage: UsageSnapshot?) -> [(String, QuotaWindow?)] {
        guard let usage else { return [] }
        var rows: [(String, QuotaWindow?)] = []
        if usage.primary != nil || usage.weekly != nil {
            rows.append(("5h", usage.primary))
            rows.append(("7d", usage.weekly))
        }
        rows.append(contentsOf: usage.additionalWindows.map { ($0.label, Optional($0)) })
        return rows
    }

    private func compactAccountRow(_ account: AccountQuota) -> NSView {
        let card = cardView()
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8)
        ])

        row.addArrangedSubview(statusDot(account))

        let name = label(account.auth.displayName, font: .systemFont(ofSize: 13, weight: .medium), color: .labelColor)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(name)
        row.addArrangedSubview(NSView())

        if let plan = account.effectivePlanType, !plan.isEmpty {
            row.addArrangedSubview(planPill(text: plan))
        }

        let (statusText, statusColor) = compactStatus(for: account)
        let statusLabel = label(statusText, font: .systemFont(ofSize: 11, weight: .medium), color: statusColor)
        row.addArrangedSubview(statusLabel)
        return card
    }

    private func compactStatus(for account: AccountQuota) -> (String, NSColor) {
        if account.errorMessage?.isEmpty == false {
            return ("Error", .systemRed)
        }
        if account.isDisabled {
            return ("Paused", .tertiaryLabelColor)
        }
        if account.isUnavailable {
            return ("Unavailable", .tertiaryLabelColor)
        }
        return ("Ready", .secondaryLabelColor)
    }

    private func quotaLine(label labelText: String, window: QuotaWindow?) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 4

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 8
        container.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true

        let titleLabel = label(labelText, font: .systemFont(ofSize: 11, weight: .semibold), color: .secondaryLabelColor)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        header.addArrangedSubview(titleLabel)
        header.addArrangedSubview(NSView())

        let meta = NSStackView()
        meta.orientation = .horizontal
        meta.alignment = .firstBaseline
        meta.spacing = 8
        header.addArrangedSubview(meta)

        let percent = label(window?.displayValue ?? displayPercent(window?.remainingPercent), font: .monospacedDigitSystemFont(ofSize: 11, weight: .semibold), color: .labelColor)
        percent.alignment = .right
        percent.widthAnchor.constraint(equalToConstant: 42).isActive = true
        meta.addArrangedSubview(percent)

        if let amountText = window?.amountText, !amountText.isEmpty {
            let amount = label(amountText, font: .monospacedDigitSystemFont(ofSize: 10, weight: .regular), color: .secondaryLabelColor)
            amount.alignment = .right
            amount.lineBreakMode = .byTruncatingMiddle
            amount.widthAnchor.constraint(equalToConstant: 92).isActive = true
            meta.addArrangedSubview(amount)
        }

        let reset = label(resetText(window), font: .monospacedDigitSystemFont(ofSize: 10, weight: .regular), color: .tertiaryLabelColor)
        reset.alignment = .right
        reset.widthAnchor.constraint(equalToConstant: 70).isActive = true
        meta.addArrangedSubview(reset)

        let bar = QuotaBarView()
        bar.value = window?.remainingPercent ?? 0
        bar.isMuted = window?.remainingPercent == nil
        bar.isUnavailable = window?.isUsable == false
        bar.heightAnchor.constraint(equalToConstant: 6).isActive = true
        container.addArrangedSubview(bar)
        bar.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        return container
    }

    private func emptyDashboardView() -> NSView {
        if state.isLoading {
            return placeholderCard(
                symbol: "arrow.triangle.2.circlepath",
                title: "Refreshing",
                detail: "Just a moment."
            )
        }
        return placeholderCard(
            symbol: "tray",
            title: "No data",
            detail: "Tap refresh to load quota."
        )
    }

    private func placeholderCard(symbol: String, title: String, detail: String) -> NSView {
        let card = cardView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        let config = NSImage.SymbolConfiguration(pointSize: 28, weight: .light)
        let symbolImage = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage()
        let imageView = NSImageView(image: symbolImage)
        imageView.contentTintColor = NSColor.tertiaryLabelColor
        stack.addArrangedSubview(imageView)

        let titleLabel = label(title, font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor)
        titleLabel.alignment = .center
        stack.addArrangedSubview(titleLabel)

        let detailLabel = label(detail, font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 2
        stack.addArrangedSubview(detailLabel)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 180)
        ])
        return card
    }

    private func messageView(text: String) -> NSView {
        let card = RoundedView(
            fill: NSColor.systemRed.withAlphaComponent(0.10),
            border: NSColor.systemRed.withAlphaComponent(0.20),
            radius: 10
        )
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)

        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage())
        icon.contentTintColor = .systemRed
        row.addArrangedSubview(icon)

        let textLabel = label(text, font: .systemFont(ofSize: 12), color: .labelColor)
        textLabel.maximumNumberOfLines = 4
        textLabel.preferredMaxLayoutWidth = popoverWidth - 80
        row.addArrangedSubview(textLabel)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10)
        ])
        return card
    }

    private func noteLabel(text: String, color: NSColor = .secondaryLabelColor) -> NSView {
        let textLabel = label(text, font: .systemFont(ofSize: 11), color: color)
        textLabel.maximumNumberOfLines = 2
        textLabel.preferredMaxLayoutWidth = popoverWidth - 60
        return textLabel
    }

    private func planPill(text: String) -> NSView {
        let formatted = text.lowercased().capitalized
        let textLabel = label(formatted, font: .systemFont(ofSize: 10, weight: .semibold), color: .secondaryLabelColor)
        textLabel.alignment = .center
        let view = RoundedView(
            fill: NSColor.tertiaryLabelColor.withAlphaComponent(0.14),
            border: .clear,
            radius: 5
        )
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textLabel)
        NSLayoutConstraint.activate([
            textLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 7),
            textLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -7),
            textLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 2),
            textLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -2)
        ])
        return view
    }

    private func statusDot(_ account: AccountQuota) -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = statusColor(account).cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8)
        ])
        return dot
    }

    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    private func cardView() -> RoundedView {
        return RoundedView(
            fill: NSColor.controlBackgroundColor.withAlphaComponent(0.55),
            border: NSColor.separatorColor.withAlphaComponent(0.18),
            radius: 12
        )
    }

    private func circularIconButton(symbol: String, tooltip: String, action: @escaping () -> Void) -> NSButton {
        let button = CallbackButton(title: "", callback: action)
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(config)
        button.image = image
        button.toolTip = tooltip
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = .secondaryLabelColor
        button.imageScaling = .scaleProportionallyDown
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }

    private func primaryButton(title: String, action: @escaping () -> Void) -> NSButton {
        let button = CallbackButton(title: title, callback: action)
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        button.font = .systemFont(ofSize: 13, weight: .medium)
        return button
    }

    private func linkButton(title: String, action: @escaping () -> Void) -> NSButton {
        let button = CallbackButton(title: title, callback: action)
        button.isBordered = false
        button.font = .systemFont(ofSize: 11, weight: .regular)
        button.contentTintColor = .secondaryLabelColor
        return button
    }

    private func subtitleText() -> String {
        if state.isLoading && state.snapshot == nil {
            return "Refreshing…"
        }
        guard let date = state.snapshot?.fetchedAt else {
            return "Not refreshed"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return "Updated \(formatter.localizedString(for: date, relativeTo: Date()))"
    }

    private func resetText(_ window: QuotaWindow?) -> String {
        guard let window else { return "" }
        if let detail = window.detailText, !detail.isEmpty {
            return detail
        }
        if let seconds = window.resetAfterSeconds {
            return displayDuration(seconds: seconds)
        }
        if let resetAt = window.resetAt {
            let remaining = resetAt.timeIntervalSinceNow
            return remaining > 0 ? displayDuration(seconds: remaining) : "now"
        }
        return ""
    }

    private func statusColor(_ account: AccountQuota) -> NSColor {
        if account.errorMessage != nil {
            return .systemRed
        }
        if account.isDisabled || account.isUnavailable {
            return .tertiaryLabelColor
        }
        if account.hasUnusableQuotaWindow {
            return .systemRed
        }
        if let remaining = account.lowestRemainingPercent {
            if remaining <= 15 { return .systemRed }
            if remaining <= 35 { return .systemOrange }
            return .systemGreen
        }
        return .systemBlue
    }

    private func summaryColor(_ percent: Double?) -> NSColor {
        guard let percent else { return .tertiaryLabelColor }
        if percent <= 15 { return .systemRed }
        if percent <= 35 { return .systemOrange }
        return .labelColor
    }

    private func trimError(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 96 { return trimmed }
        return String(trimmed.prefix(95)) + "…"
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

final class TopAlignedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

final class RoundedView: NSView {
    init(fill: NSColor, border: NSColor, radius: CGFloat = 10) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = fill.cgColor
        let isTransparentBorder = border.alphaComponent <= 0.001
        layer?.borderColor = isTransparentBorder ? NSColor.clear.cgColor : border.cgColor
        layer?.borderWidth = isTransparentBorder ? 0 : 0.5
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
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
    var isUnavailable = false {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 120, height: 6)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds
        let radius = rect.height / 2
        NSColor.tertiaryLabelColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()

        guard !isMuted else { return }
        let clamped = max(0, min(100, value))
        let fillWidth = rect.width * CGFloat(clamped / 100)
        guard fillWidth > 0 else { return }
        barColor(for: clamped).setFill()
        let fillRect = NSRect(x: rect.minX, y: rect.minY, width: fillWidth, height: rect.height)
        NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius).fill()
    }

    private func barColor(for value: Double) -> NSColor {
        if isUnavailable { return .systemRed }
        if value <= 15 { return .systemRed }
        if value <= 35 { return .systemOrange }
        return .systemGreen
    }
}
