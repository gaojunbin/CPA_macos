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
    private let store = ServiceProfileStore.shared
    private var profiles: [ServiceProfile] = []
    private var selectedID: UUID?
    private var snapshotCache: [UUID: PoolSnapshot] = [:]
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let controller = PopoverViewController()
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var timer: Timer?

    private var selectedProfile: ServiceProfile? {
        profiles.first { $0.id == selectedID }
    }

    private var settings: AppSettings {
        selectedProfile.map { store.settings(for: $0) } ?? AppSettings(baseURL: "", managementKey: "")
    }

    private var isConfigured: Bool {
        settings.isConfigured
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadProfiles()
        configureStatusItem()
        configurePopover()
        syncControllerState()
        controller.state.screen = isConfigured ? .dashboard : .services
        controller.render()

        if isConfigured {
            refresh()
            restartTimer()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.showPopover(screen: .services, refreshWhenVisible: false)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTask?.cancel()
        timer?.invalidate()
    }

    private func loadProfiles() {
        profiles = store.loadProfiles()
        selectedID = store.selectedID()
        if selectedID == nil || !profiles.contains(where: { $0.id == selectedID }) {
            selectedID = profiles.first?.id
            store.setSelectedID(selectedID)
        }
    }

    private func syncControllerState() {
        controller.state.profiles = profiles
        controller.state.selectedID = selectedID
        controller.state.settings = settings
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
        controller.onOpenServices = { [weak self] in
            self?.showServices()
        }
        controller.onCloseServices = { [weak self] in
            guard let self else { return }
            if self.isConfigured {
                self.controller.state.screen = .dashboard
                self.controller.state.errorMessage = nil
                self.controller.render()
            }
        }
        controller.onSelectProfile = { [weak self] id in
            self?.selectProfile(id)
        }
        controller.onSaveProfile = { [weak self] draft in
            self?.saveProfile(draft)
        }
        controller.onDeleteProfile = { [weak self] id in
            self?.deleteProfile(id)
        }
        controller.onQuit = {
            NSApp.terminate(nil)
        }
        controller.onHoldOpen = { [weak self] hold in
            // `.applicationDefined` keeps the popover up while the user is in the browser;
            // `.transient` restores the normal click-outside-to-close behavior afterwards.
            self?.popover.behavior = hold ? .applicationDefined : .transient
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        showPopover(screen: isConfigured ? .dashboard : .services, refreshWhenVisible: isConfigured)
    }

    private func showPopover(screen: PopoverScreen, refreshWhenVisible: Bool) {
        controller.state.screen = screen
        syncControllerState()
        controller.render()
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        if refreshWhenVisible {
            refresh()
        }
    }

    private func showServices() {
        controller.state.screen = .services
        controller.state.editingProfile = nil
        controller.state.errorMessage = nil
        syncControllerState()
        controller.render()
    }

    private func selectProfile(_ id: UUID) {
        guard id != selectedID, profiles.contains(where: { $0.id == id }) else {
            return
        }
        selectedID = id
        store.setSelectedID(id)
        syncControllerState()
        // Show the newly selected service's cached snapshot instantly, then refresh.
        controller.state.snapshot = snapshotCache[id]
        controller.state.errorMessage = nil
        controller.state.detailAccount = nil
        controller.state.screen = .dashboard
        controller.render()
        updateStatusTitle()
        restartTimer()
        refresh()
    }

    private func saveProfile(_ draft: ServiceDraft) {
        let trimmedURL = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = draft.managementKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            controller.state.errorMessage = "请输入服务器地址"
            controller.render()
            return
        }
        let interval = max(60, min(draft.refreshIntervalSeconds, 86_400))
        let savedID: UUID

        do {
            if let id = draft.id, let index = profiles.firstIndex(where: { $0.id == id }) {
                if !trimmedKey.isEmpty {
                    try store.saveManagementKey(trimmedKey, for: id)
                } else if store.managementKey(for: id).isEmpty {
                    controller.state.errorMessage = "请输入管理密钥"
                    controller.render()
                    return
                }
                var profile = profiles[index]
                profile.name = resolvedName(draft.name, baseURL: trimmedURL)
                profile.baseURL = trimmedURL
                profile.refreshIntervalSeconds = interval
                profiles[index] = profile
                store.saveProfiles(profiles)
                savedID = id
            } else {
                guard !trimmedKey.isEmpty else {
                    controller.state.errorMessage = "请输入管理密钥"
                    controller.render()
                    return
                }
                let profile = ServiceProfile(
                    name: resolvedName(draft.name, baseURL: trimmedURL),
                    baseURL: trimmedURL,
                    refreshIntervalSeconds: interval
                )
                try store.saveManagementKey(trimmedKey, for: profile.id)
                profiles.append(profile)
                store.saveProfiles(profiles)
                savedID = profile.id
                if selectedID == nil {
                    selectedID = profile.id
                    store.setSelectedID(profile.id)
                }
            }
        } catch {
            controller.state.errorMessage = error.localizedDescription
            controller.render()
            return
        }

        syncControllerState()
        controller.state.errorMessage = nil
        controller.state.editingProfile = nil
        restartTimer()
        updateStatusTitle()
        if savedID == selectedID {
            controller.state.snapshot = snapshotCache[savedID]
            controller.state.screen = .dashboard
            controller.render()
            refresh()
        } else {
            controller.state.screen = .services
            controller.render()
        }
    }

    private func deleteProfile(_ id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            return
        }
        let wasSelected = (id == selectedID)
        store.deleteManagementKey(for: id)
        snapshotCache[id] = nil
        profiles.remove(at: index)
        store.saveProfiles(profiles)
        if wasSelected {
            selectedID = profiles.first?.id
            store.setSelectedID(selectedID)
        }

        syncControllerState()
        controller.state.editingProfile = nil
        controller.state.errorMessage = nil
        if wasSelected {
            controller.state.snapshot = selectedID.flatMap { snapshotCache[$0] }
        }
        controller.state.screen = .services
        controller.render()
        updateStatusTitle()
        restartTimer()
        if wasSelected && isConfigured {
            refresh()
        }
    }

    private func resolvedName(_ name: String, baseURL: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        let raw = baseURL.contains("://") ? baseURL : "https://\(baseURL)"
        return URL(string: raw)?.host ?? baseURL
    }

    private func restartTimer() {
        timer?.invalidate()
        guard isConfigured else { return }
        timer = Timer.scheduledTimer(withTimeInterval: settings.refreshIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    private func refresh() {
        guard isConfigured else {
            controller.state.screen = .services
            controller.render()
            updateStatusTitle()
            return
        }

        refreshTask?.cancel()
        refreshGeneration += 1
        let generation = refreshGeneration
        let targetID = selectedID
        let snapshotSettings = settings

        controller.state.isLoading = true
        controller.state.errorMessage = nil
        controller.render()
        updateStatusTitle()

        let client = CLIProxyAPIClient(settings: snapshotSettings)
        refreshTask = Task {
            do {
                let snapshot = try await client.fetchPoolSnapshot()
                await MainActor.run {
                    guard generation == self.refreshGeneration else { return }
                    if let targetID { self.snapshotCache[targetID] = snapshot }
                    self.controller.state.snapshot = snapshot
                    self.controller.state.errorMessage = nil
                    self.controller.state.isLoading = false
                    self.refreshTask = nil
                    self.controller.render()
                    self.updateStatusTitle()
                }
            } catch {
                await MainActor.run {
                    guard generation == self.refreshGeneration else { return }
                    if error is CancellationError {
                        self.controller.state.isLoading = false
                        self.refreshTask = nil
                        return
                    }
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
    case services
    case serviceEditor
    case detail
    case addAccount
    case apiKeys
}

/// Tracks an in-flight OAuth login started from the menu bar.
struct OAuthFlow {
    enum Phase {
        case requesting      // fetching the auth URL
        case waitingBrowser  // browser open, waiting for the loopback redirect
        case authorizing     // device-flow: waiting for the user to approve in the browser
        case finishing       // callback relayed, polling the server for completion
        case failed
    }
    let provider: OAuthProvider
    var phase: Phase
    var authURL: String?
    var sessionState: String?
    var errorMessage: String?
}

/// Form values collected by the service editor and handed back to the app delegate to persist.
struct ServiceDraft {
    var id: UUID?
    var name: String
    var baseURL: String
    var managementKey: String
    var refreshIntervalSeconds: TimeInterval
}

struct PopoverState {
    var settings = AppSettings()
    var profiles: [ServiceProfile] = []
    var selectedID: UUID?
    var editingProfile: ServiceProfile?
    var snapshot: PoolSnapshot?
    var screen: PopoverScreen = .dashboard
    var isLoading = false
    var errorMessage: String?
    var detailAccount: AccountQuota?
    var detailModels: [CPAModelDefinition] = []
    var detailModelsLoading = false
    var detailModelsError: String?
    var detailRefreshing = false
    // OAuth login
    var oauth: OAuthFlow?
    // API keys
    var apiKeys: [String]?
    var apiKeysLoading = false
    var apiKeysError: String?
    var apiKeyAdding = false
    var pendingDeleteKey: String?
    // Transient confirmation toast (e.g. "已复制").
    var toast: String?
}

@MainActor
final class PopoverViewController: NSViewController {
    var state = PopoverState()
    var onRefresh: (() -> Void)?
    var onOpenServices: (() -> Void)?
    var onCloseServices: (() -> Void)?
    var onSelectProfile: ((UUID) -> Void)?
    var onSaveProfile: ((ServiceDraft) -> Void)?
    var onDeleteProfile: ((UUID) -> Void)?
    var onQuit: (() -> Void)?
    /// Asks the app delegate to keep the popover open across the browser hand-off during OAuth.
    var onHoldOpen: ((Bool) -> Void)?

    private let popoverWidth: CGFloat = 380
    private let popoverHeight: CGFloat = 560

    // OAuth flow coordination.
    private var oauthTask: Task<Void, Never>?
    private var oauthGeneration = 0
    private var toastToken = 0

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
        case .services:
            renderServices(in: root)
        case .serviceEditor:
            renderServiceEditor(in: root)
        case .detail:
            renderDetail(in: root)
        case .addAccount:
            renderAddAccount(in: root)
        case .apiKeys:
            renderAPIKeys(in: root)
        }

        if let toast = state.toast {
            addToastOverlay(toast)
        }
    }

    // MARK: - Toast

    /// Shows a brief floating confirmation pinned to the top of the popover, auto-dismissed.
    private func showToast(_ message: String) {
        state.toast = message
        toastToken += 1
        let token = toastToken
        render()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, self.toastToken == token else { return }
            self.state.toast = nil
            self.render()
        }
    }

    private func addToastOverlay(_ message: String) {
        let pill = RoundedView(fill: NSColor.controlAccentColor, border: .clear, radius: 9)
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.shadowBlurRadius = 6
            return shadow
        }()
        pill.wantsLayer = true

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        let icon = NSImageView(image: NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage())
        icon.contentTintColor = .white
        row.addArrangedSubview(icon)
        row.addArrangedSubview(label(message, font: .systemFont(ofSize: 12, weight: .semibold), color: .white))
        pill.addSubview(row)
        view.addSubview(pill)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: pill.topAnchor, constant: 7),
            row.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -7),
            pill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            pill.topAnchor.constraint(equalTo: view.topAnchor, constant: 12)
        ])
    }

    private func copyToClipboard(_ value: String, notice: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(trimmed, forType: .string)
        showToast(notice)
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

    // MARK: - Services list

    private func renderServices(in root: NSStackView) {
        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .top
        titleRow.spacing = 8

        let titleStack = NSStackView()
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2
        titleStack.addArrangedSubview(label("服务", font: .systemFont(ofSize: 18, weight: .semibold), color: .labelColor))
        titleStack.addArrangedSubview(label("管理你的号池，互不交集。", font: .systemFont(ofSize: 12), color: .secondaryLabelColor))
        titleRow.addArrangedSubview(titleStack)
        titleRow.addArrangedSubview(NSView())

        if state.settings.isConfigured {
            titleRow.addArrangedSubview(circularIconButton(symbol: "xmark", tooltip: "Close") { [weak self] in
                self?.onCloseServices?()
            })
        }
        addFullWidth(titleRow, to: root)

        if let error = state.errorMessage {
            addFullWidth(messageView(text: error), to: root)
        }

        if state.profiles.isEmpty {
            addFullWidth(placeholderCard(
                symbol: "tray",
                title: "还没有服务",
                detail: "点击下方添加你的第一个服务。"
            ), to: root)
        } else {
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
            stack.spacing = 6
            stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 4, right: 0)
            stack.translatesAutoresizingMaskIntoConstraints = false
            scroll.documentView = stack
            NSLayoutConstraint.activate([
                stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
            ])

            for profile in state.profiles {
                let row = serviceManageRow(profile)
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }

            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
            addFullWidth(scroll, to: root)
        }

        let addButton = primaryButton(title: "添加服务") { [weak self] in
            self?.beginAddProfile()
        }
        let addRow = NSView()
        addRow.translatesAutoresizingMaskIntoConstraints = false
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addRow.addSubview(addButton)
        NSLayoutConstraint.activate([
            addButton.leadingAnchor.constraint(equalTo: addRow.leadingAnchor),
            addButton.topAnchor.constraint(equalTo: addRow.topAnchor),
            addButton.bottomAnchor.constraint(equalTo: addRow.bottomAnchor)
        ])
        addFullWidth(addRow, to: root)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        root.addArrangedSubview(spacer)

        let quitLink = linkButton(title: "Quit") { [weak self] in
            self?.onQuit?()
        }
        addFullWidth(quitLink, to: root)
    }

    private func serviceManageRow(_ profile: ServiceProfile) -> NSView {
        let card = clickableCardView()
        card.onClick = { [weak self] in self?.beginEditProfile(profile) }
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10)
        ])

        let isSelected = profile.id == state.selectedID
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let markName = isSelected ? "checkmark.circle.fill" : "circle"
        let mark = NSImageView(image: NSImage(systemSymbolName: markName, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig) ?? NSImage())
        mark.contentTintColor = isSelected ? .controlAccentColor : .tertiaryLabelColor
        mark.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(mark)

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        let name = label(profile.name, font: .systemFont(ofSize: 13, weight: .medium), color: .labelColor)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textStack.addArrangedSubview(name)
        let host = label(profile.displayHost, font: .systemFont(ofSize: 11, weight: .regular), color: .secondaryLabelColor)
        host.lineBreakMode = .byTruncatingMiddle
        host.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textStack.addArrangedSubview(host)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(textStack)
        row.addArrangedSubview(NSView())

        if isSelected {
            row.addArrangedSubview(pillLabel("当前", color: .controlAccentColor))
        }

        let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)) ?? NSImage())
        chevron.contentTintColor = .tertiaryLabelColor
        row.addArrangedSubview(chevron)
        return card
    }

    // MARK: - Service editor

    private func renderServiceEditor(in root: NSStackView) {
        let editing = state.editingProfile

        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 8
        headerRow.addArrangedSubview(circularIconButton(symbol: "chevron.left", tooltip: "Back") { [weak self] in
            self?.backToServices()
        })
        headerRow.addArrangedSubview(label(
            editing == nil ? "添加服务" : "编辑服务",
            font: .systemFont(ofSize: 16, weight: .semibold),
            color: .labelColor
        ))
        headerRow.addArrangedSubview(NSView())
        addFullWidth(headerRow, to: root)

        let nameField = NSTextField(string: editing?.name ?? "")
        nameField.placeholderString = "例如：美国号池"
        let urlField = NSTextField(string: editing?.baseURL ?? "")
        urlField.placeholderString = "https://your-vps.example.com"
        let keyField = NSSecureTextField(frame: .zero)
        keyField.stringValue = ""
        keyField.placeholderString = editing == nil ? "Management password" : "留空保持当前密钥"
        let minutes = max(1, Int(((editing?.refreshIntervalSeconds ?? 300) / 60).rounded()))
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

        let rows = [
            settingRow(symbol: "tag", title: "Name", field: nameField, stretch: true),
            settingRow(symbol: "network", title: "Endpoint", field: urlField, stretch: true),
            settingRow(symbol: "lock.fill", title: "Password", field: keyField, stretch: true),
            settingRow(symbol: "arrow.triangle.2.circlepath", title: "Refresh interval", field: intervalField, stretch: false, fieldWidth: 64, suffix: "minutes")
        ]
        rows.forEach { row in
            formStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: formStack.widthAnchor).isActive = true
        }
        addFullWidth(formCard, to: root)

        if let error = state.errorMessage {
            addFullWidth(messageView(text: error), to: root)
        }

        if let editing, editing.id != state.selectedID {
            let selectButton = primaryButton(title: "设为当前服务") { [weak self] in
                self?.onSelectProfile?(editing.id)
            }
            let selectRow = NSView()
            selectRow.translatesAutoresizingMaskIntoConstraints = false
            selectButton.translatesAutoresizingMaskIntoConstraints = false
            selectRow.addSubview(selectButton)
            NSLayoutConstraint.activate([
                selectButton.leadingAnchor.constraint(equalTo: selectRow.leadingAnchor),
                selectButton.topAnchor.constraint(equalTo: selectRow.topAnchor),
                selectButton.bottomAnchor.constraint(equalTo: selectRow.bottomAnchor)
            ])
            addFullWidth(selectRow, to: root)
        }

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        root.addArrangedSubview(spacer)

        let saveButton = primaryButton(title: "保存") { [weak nameField, weak urlField, weak keyField, weak intervalField, weak self] in
            guard let self else { return }
            let intervalMinutes = Double(intervalField?.stringValue ?? "") ?? 5
            self.onSaveProfile?(ServiceDraft(
                id: editing?.id,
                name: nameField?.stringValue ?? "",
                baseURL: urlField?.stringValue ?? "",
                managementKey: keyField?.stringValue ?? "",
                refreshIntervalSeconds: max(1, intervalMinutes) * 60
            ))
        }

        let buttonRow = NSView()
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.addSubview(saveButton)
        NSLayoutConstraint.activate([
            saveButton.trailingAnchor.constraint(equalTo: buttonRow.trailingAnchor),
            saveButton.centerYAnchor.constraint(equalTo: buttonRow.centerYAnchor),
            buttonRow.heightAnchor.constraint(equalTo: saveButton.heightAnchor)
        ])

        if let editing {
            let deleteLink = linkButton(title: "删除服务") { [weak self] in
                self?.onDeleteProfile?(editing.id)
            }
            deleteLink.contentTintColor = .systemRed
            deleteLink.translatesAutoresizingMaskIntoConstraints = false
            buttonRow.addSubview(deleteLink)
            NSLayoutConstraint.activate([
                deleteLink.leadingAnchor.constraint(equalTo: buttonRow.leadingAnchor),
                deleteLink.centerYAnchor.constraint(equalTo: buttonRow.centerYAnchor)
            ])
        }

        addFullWidth(buttonRow, to: root)
    }

    private func beginAddProfile() {
        state.editingProfile = nil
        state.errorMessage = nil
        state.screen = .serviceEditor
        render()
    }

    private func beginEditProfile(_ profile: ServiceProfile) {
        state.editingProfile = profile
        state.errorMessage = nil
        state.screen = .serviceEditor
        render()
    }

    private func backToServices() {
        state.editingProfile = nil
        state.errorMessage = nil
        state.screen = .services
        render()
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
        titleStack.addArrangedSubview(serviceSwitcherButton())
        titleStack.addArrangedSubview(label(subtitleText(), font: .systemFont(ofSize: 11), color: .secondaryLabelColor))
        row.addArrangedSubview(titleStack)
        row.addArrangedSubview(NSView())

        let refresh = circularIconButton(symbol: "arrow.clockwise", tooltip: "Refresh") { [weak self] in
            self?.onRefresh?()
        }
        refresh.isEnabled = !state.isLoading
        row.addArrangedSubview(refresh)

        weak var manageRef: NSButton?
        let manage = circularIconButton(symbol: "ellipsis.circle", tooltip: "管理") { [weak self] in
            guard let self, let anchor = manageRef else { return }
            self.showManageMenu(from: anchor)
        }
        manageRef = manage
        row.addArrangedSubview(manage)

        return row
    }

    private func showManageMenu(from view: NSView) {
        let menu = NSMenu()
        menu.addItem(CallbackMenuItem(title: "添加账号（OAuth 登录）") { [weak self] in
            self?.openAddAccount()
        })
        menu.addItem(CallbackMenuItem(title: "API 密钥…") { [weak self] in
            self?.openAPIKeys()
        })
        menu.addItem(.separator())
        menu.addItem(CallbackMenuItem(title: "管理服务…") { [weak self] in
            self?.onOpenServices?()
        })
        menu.addItem(.separator())
        menu.addItem(CallbackMenuItem(title: "退出 CPA") { [weak self] in
            self?.onQuit?()
        })
        let location = NSPoint(x: 0, y: view.bounds.height + 4)
        menu.popUp(positioning: nil, at: location, in: view)
    }

    private func openAddAccount() {
        oauthGeneration += 1
        cleanupOAuthResources()
        onHoldOpen?(false)
        state.oauth = nil
        state.errorMessage = nil
        state.screen = .addAccount
        render()
    }

    private func openAPIKeys() {
        state.screen = .apiKeys
        state.pendingDeleteKey = nil
        state.apiKeyAdding = false
        state.apiKeys = nil   // avoid flashing another service's keys before the reload lands
        state.apiKeysError = nil
        render()
        loadAPIKeys()
    }

    /// The current-service title that doubles as the switcher: clicking it pops a menu of
    /// every service plus a "管理服务…" entry.
    private func serviceSwitcherButton() -> NSView {
        guard !state.profiles.isEmpty else {
            return label("AI Usage", font: .systemFont(ofSize: 18, weight: .semibold), color: .labelColor)
        }
        let currentName = state.profiles.first(where: { $0.id == state.selectedID })?.name ?? "选择服务"
        let button = CallbackButton(title: currentName, callback: {})
        button.bezelStyle = .texturedRounded
        button.font = .systemFont(ofSize: 15, weight: .semibold)
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
        button.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "切换服务")?
            .withSymbolConfiguration(config)
        button.imagePosition = .imageRight
        button.contentTintColor = .labelColor
        button.toolTip = "切换服务"
        button.onClick = { [weak self, weak button] in
            guard let self, let button else { return }
            self.showServiceMenu(from: button)
        }
        return button
    }

    private func showServiceMenu(from view: NSView) {
        let menu = NSMenu()
        for profile in state.profiles {
            let item = CallbackMenuItem(title: profile.name) { [weak self] in
                self?.onSelectProfile?(profile.id)
            }
            item.state = (profile.id == state.selectedID) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(CallbackMenuItem(title: "管理服务…") { [weak self] in
            self?.onOpenServices?()
        })
        let location = NSPoint(x: 0, y: view.bounds.height + 4)
        menu.popUp(positioning: nil, at: location, in: view)
    }

    private func summaryView(_ summary: PoolSummary) -> NSView {
        let card = cardView()
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            column.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            column.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            column.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12)
        ])

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 0
        row.alignment = .centerY
        row.distribution = .fillEqually
        row.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

        row.addArrangedSubview(statView(
            value: displayPercent(summary.primaryAverage),
            label: "Codex 5h",
            color: summaryColor(summary.primaryAverage)
        ))
        row.addArrangedSubview(statView(
            value: displayPercent(summary.weeklyAverage),
            label: "Codex 7d",
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

        let caption = label(summaryCaption(summary), font: .systemFont(ofSize: 10), color: .tertiaryLabelColor)
        caption.alignment = .center
        caption.maximumNumberOfLines = 2
        caption.lineBreakMode = .byWordWrapping
        caption.preferredMaxLayoutWidth = popoverWidth - 64
        column.addArrangedSubview(caption)
        caption.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return card
    }

    private func summaryCaption(_ summary: PoolSummary) -> String {
        // The 5h / 7d figures are Codex-only rolling windows; other providers report
        // their own quota shapes (credits, balances, per-model limits) shown per card below.
        if summary.codexAccounts == 0 {
            return "5h · 7d 为 Codex 账号平均剩余额度（当前无 Codex 账号）；其他渠道额度见下方各自卡片。"
        }
        let suffix = summary.codexAccounts == 1 ? "" : "，共 \(summary.codexAccounts) 个"
        return "5h · 7d 为 Codex 账号平均剩余额度\(suffix)；其他渠道额度见下方各自卡片。"
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
        let card = clickableCardView()
        card.onClick = { [weak self] in self?.openDetail(account) }
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
        let card = clickableCardView()
        card.onClick = { [weak self] in self?.openDetail(account) }
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

    // MARK: - Add account (OAuth login)

    private func renderAddAccount(in root: NSStackView) {
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.addArrangedSubview(circularIconButton(symbol: "chevron.left", tooltip: "Back") { [weak self] in
            guard let self else { return }
            if self.state.oauth != nil {
                self.cancelOAuth()
            } else {
                self.showDashboard()
            }
        })
        header.addArrangedSubview(label("添加账号", font: .systemFont(ofSize: 16, weight: .semibold), color: .labelColor))
        header.addArrangedSubview(NSView())
        addFullWidth(header, to: root)

        if let flow = state.oauth {
            addFullWidth(oauthProgressCard(flow), to: root)
        } else {
            addFullWidth(label(
                "选择渠道登录，账号会保存到当前服务，无需打开网页后台。",
                font: .systemFont(ofSize: 12),
                color: .secondaryLabelColor
            ), to: root)

            let listStack = TopAlignedStackView()
            listStack.orientation = .vertical
            listStack.alignment = .leading
            listStack.spacing = 6
            listStack.translatesAutoresizingMaskIntoConstraints = false
            for provider in OAuthProvider.allCases {
                let row = oauthProviderRow(provider)
                listStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            }
            addFullWidth(listStack, to: root)
        }

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        root.addArrangedSubview(spacer)
    }

    private func oauthProviderRow(_ provider: OAuthProvider) -> NSView {
        let card = clickableCardView()
        card.onClick = { [weak self] in self?.startOAuth(provider) }
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10)
        ])

        row.addArrangedSubview(oauthProviderBadge(provider, size: 28))

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.addArrangedSubview(label(provider.displayName, font: .systemFont(ofSize: 13, weight: .medium), color: .labelColor))
        textStack.addArrangedSubview(label(provider.hint, font: .systemFont(ofSize: 11), color: .secondaryLabelColor))
        row.addArrangedSubview(textStack)
        row.addArrangedSubview(NSView())

        let plus = NSImageView(image: NSImage(systemSymbolName: "plus.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)) ?? NSImage())
        plus.contentTintColor = .controlAccentColor
        row.addArrangedSubview(plus)
        return card
    }

    private func oauthProgressCard(_ flow: OAuthFlow) -> NSView {
        let card = cardView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14)
        ])

        let top = NSStackView()
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 10
        top.addArrangedSubview(oauthProviderBadge(flow.provider, size: 30))
        let titleStack = NSStackView()
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2
        titleStack.addArrangedSubview(label(flow.provider.displayName, font: .systemFont(ofSize: 14, weight: .semibold), color: .labelColor))
        titleStack.addArrangedSubview(label("OAuth 登录", font: .systemFont(ofSize: 11), color: .secondaryLabelColor))
        top.addArrangedSubview(titleStack)
        top.addArrangedSubview(NSView())
        if flow.phase != .failed {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.translatesAutoresizingMaskIntoConstraints = false
            spinner.startAnimation(nil)
            top.addArrangedSubview(spinner)
        } else {
            top.addArrangedSubview(pillLabel("失败", color: .systemRed))
        }
        stack.addArrangedSubview(top)
        top.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let status = label(oauthPhaseText(flow), font: .systemFont(ofSize: 12, weight: .medium),
                           color: flow.phase == .failed ? .systemRed : .labelColor)
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 4
        status.preferredMaxLayoutWidth = popoverWidth - 88
        stack.addArrangedSubview(status)
        status.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Authorization link: copy is the primary action (the user may use any browser).
        if let url = flow.authURL, !url.isEmpty {
            stack.addArrangedSubview(label("① 授权链接", font: .systemFont(ofSize: 11, weight: .semibold), color: .secondaryLabelColor))

            let urlRow = NSStackView()
            urlRow.orientation = .horizontal
            urlRow.alignment = .centerY
            urlRow.spacing = 8
            urlRow.distribution = .fill
            urlRow.translatesAutoresizingMaskIntoConstraints = false

            let urlField = NSTextField(string: url)
            urlField.isEditable = false
            urlField.isSelectable = true
            urlField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            urlField.bezelStyle = .roundedBezel
            urlField.lineBreakMode = .byTruncatingTail
            urlField.setContentHuggingPriority(.defaultLow, for: .horizontal)
            urlField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            urlField.heightAnchor.constraint(equalToConstant: 26).isActive = true
            urlRow.addArrangedSubview(urlField)

            let copyButton = CallbackButton(title: "复制链接") { [weak self] in
                self?.copyToClipboard(url, notice: "已复制链接")
            }
            copyButton.bezelStyle = .rounded
            copyButton.setContentHuggingPriority(.required, for: .horizontal)
            urlRow.addArrangedSubview(copyButton)
            stack.addArrangedSubview(urlRow)
            urlRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

            let openLink = linkButton(title: "用默认浏览器打开") { [weak self] in
                self?.openURL(url)
            }
            openLink.contentTintColor = .controlAccentColor
            stack.addArrangedSubview(openLink)
        }

        // Redirect providers: the user pastes the redirected localhost URL back here.
        if !flow.provider.usesDeviceFlow && flow.authURL != nil {
            stack.addArrangedSubview(label("② 登录后，把浏览器地址栏的回调链接粘贴到这里", font: .systemFont(ofSize: 11, weight: .semibold), color: .secondaryLabelColor))

            let pasteRow = NSStackView()
            pasteRow.orientation = .horizontal
            pasteRow.alignment = .centerY
            pasteRow.spacing = 8
            pasteRow.distribution = .fill
            pasteRow.translatesAutoresizingMaskIntoConstraints = false
            let field = NSTextField(string: "")
            field.placeholderString = flow.provider.callbackPort.map { "http://localhost:\($0)/…?code=…" } ?? "回调链接"
            field.font = .systemFont(ofSize: 12)
            field.bezelStyle = .roundedBezel
            field.lineBreakMode = .byTruncatingHead
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            field.heightAnchor.constraint(equalToConstant: 26).isActive = true
            pasteRow.addArrangedSubview(field)
            let submit = CallbackButton(title: "提交") { [weak self, weak field] in
                guard let self, let field else { return }
                self.submitOAuthPaste(field.stringValue)
            }
            submit.bezelStyle = .rounded
            submit.setContentHuggingPriority(.required, for: .horizontal)
            pasteRow.addArrangedSubview(submit)
            stack.addArrangedSubview(pasteRow)
            pasteRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        // Inline error while still recoverable (e.g. a bad paste); failures use the status line.
        if flow.phase != .failed, let err = flow.errorMessage, !err.isEmpty {
            let note = noteLabel(text: err, color: .systemRed)
            stack.addArrangedSubview(note)
            note.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        if flow.phase == .failed {
            buttons.addArrangedSubview(primaryButton(title: "重试") { [weak self] in
                self?.startOAuth(flow.provider)
            })
            buttons.addArrangedSubview(linkButton(title: "返回") { [weak self] in
                self?.cancelOAuth()
            })
        } else {
            buttons.addArrangedSubview(linkButton(title: "取消") { [weak self] in
                self?.cancelOAuth()
            })
        }
        stack.addArrangedSubview(buttons)
        return card
    }

    private func oauthProviderBadge(_ provider: OAuthProvider, size: CGFloat = 30) -> NSView {
        let info = ProviderCatalog.info(for: provider.catalogKey)
        let accent = providerAccentColor(info.accentName)
        let badge = RoundedView(fill: accent.withAlphaComponent(0.16), border: .clear, radius: 7)
        badge.translatesAutoresizingMaskIntoConstraints = false
        let config = NSImage.SymbolConfiguration(pointSize: size * 0.45, weight: .semibold)
        let icon = NSImageView(image: NSImage(systemSymbolName: info.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage())
        icon.contentTintColor = accent
        icon.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(icon)
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: size),
            badge.heightAnchor.constraint(equalToConstant: size),
            icon.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: badge.centerYAnchor)
        ])
        return badge
    }

    private func oauthPhaseText(_ flow: OAuthFlow) -> String {
        switch flow.phase {
        case .requesting: return "正在获取授权链接…"
        case .waitingBrowser: return "复制下面的链接到浏览器登录，再把回调链接粘贴回来。"
        case .authorizing: return "复制下面的链接到浏览器完成授权，完成后会自动登录。"
        case .finishing: return "正在验证并保存登录…"
        case .failed: return flow.errorMessage ?? "登录失败，请重试。"
        }
    }

    // MARK: - OAuth flow

    private func startOAuth(_ provider: OAuthProvider) {
        oauthGeneration += 1
        let generation = oauthGeneration
        cleanupOAuthResources()
        state.oauth = OAuthFlow(provider: provider, phase: .requesting)
        state.screen = .addAccount
        render()

        let settings = state.settings
        oauthTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let client = CLIProxyAPIClient(settings: settings)
            do {
                let auth = try await client.requestOAuthURL(for: provider)
                guard self.isCurrentOAuth(generation) else { return }
                self.state.oauth?.authURL = auth.url
                self.state.oauth?.sessionState = auth.state
                // Keep the popover open while the user logs in (in any browser) and returns to paste.
                self.onHoldOpen?(true)
                self.state.oauth?.phase = provider.usesDeviceFlow ? .authorizing : .waitingBrowser
                self.render()
                // Poll for completion: the device flow (Kimi) finishes on its own; redirect flows
                // finish once the user pastes the callback URL (see submitOAuthPaste).
                try await self.pollOAuth(client: client, provider: provider, sessionState: auth.state, generation: generation)
            } catch {
                guard self.isCurrentOAuth(generation), !(error is CancellationError) else { return }
                self.failOAuth(error)
            }
        }
    }

    /// Relays a manually pasted redirect URL to the server. The poll loop started in
    /// `startOAuth` detects completion, so this only needs to submit the callback.
    private func submitOAuthPaste(_ urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let flow = state.oauth, !flow.provider.usesDeviceFlow else { return }
        guard !trimmed.isEmpty else {
            state.oauth?.errorMessage = OAuthError.invalidCallback.errorDescription
            render()
            return
        }
        let generation = oauthGeneration
        let provider = flow.provider
        let sessionState = flow.sessionState ?? ""
        state.oauth?.errorMessage = nil
        state.oauth?.phase = .finishing
        render()

        let settings = state.settings
        Task { @MainActor [weak self] in
            guard let self else { return }
            let client = CLIProxyAPIClient(settings: settings)
            do {
                try await client.submitOAuthCallback(provider: provider.callbackProvider, redirectURL: trimmed, state: sessionState)
                // Completion is detected by the running poll loop; nothing else to do here.
            } catch {
                guard self.isCurrentOAuth(generation), !(error is CancellationError) else { return }
                // Keep the flow alive so the user can correct the link and resubmit.
                self.state.oauth?.phase = .waitingBrowser
                self.state.oauth?.errorMessage = self.friendlyMessage(error)
                self.render()
            }
        }
    }

    private func pollOAuth(client: CLIProxyAPIClient, provider: OAuthProvider, sessionState: String, generation: Int) async throws {
        guard !sessionState.isEmpty else {
            succeedOAuth()
            return
        }
        for _ in 0..<150 { // ~5 minutes at 2s cadence
            try await Task.sleep(nanoseconds: 2_000_000_000)
            guard isCurrentOAuth(generation) else { return }
            let status = try await client.pollOAuthStatus(state: sessionState)
            guard isCurrentOAuth(generation) else { return }
            switch status {
            case .ok:
                succeedOAuth()
                return
            case let .error(message):
                throw OAuthError.providerError(message)
            case .wait:
                continue
            }
        }
        throw OAuthError.timeout
    }

    private func succeedOAuth() {
        let name = state.oauth?.provider.displayName ?? ""
        cleanupOAuthResources()
        state.oauth = nil
        onHoldOpen?(false)
        state.screen = .dashboard
        render()
        NSApp.activate(ignoringOtherApps: true)
        showToast("\(name) 登录成功")
        onRefresh?()
    }

    private func failOAuth(_ error: Error) {
        cleanupOAuthResources()
        onHoldOpen?(false)
        state.oauth?.phase = .failed
        state.oauth?.errorMessage = friendlyMessage(error)
        render()
    }

    private func cancelOAuth() {
        oauthGeneration += 1
        cleanupOAuthResources()
        onHoldOpen?(false)
        state.oauth = nil
        render()
    }

    private func cleanupOAuthResources() {
        oauthTask?.cancel()
        oauthTask = nil
    }

    private func isCurrentOAuth(_ generation: Int) -> Bool {
        generation == oauthGeneration && state.oauth != nil
    }

    private func openURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    private func friendlyMessage(_ error: Error) -> String {
        if let oauthError = error as? OAuthError {
            return oauthError.errorDescription ?? "出错了"
        }
        if let poolError = error as? PoolClientError {
            return poolError.errorDescription ?? "出错了"
        }
        return error.localizedDescription
    }

    // MARK: - API keys

    private func renderAPIKeys(in root: NSStackView) {
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.addArrangedSubview(circularIconButton(symbol: "chevron.left", tooltip: "Back") { [weak self] in
            self?.showDashboard()
        })
        header.addArrangedSubview(label("API 密钥", font: .systemFont(ofSize: 16, weight: .semibold), color: .labelColor))
        header.addArrangedSubview(NSView())
        let refresh = circularIconButton(symbol: "arrow.clockwise", tooltip: "Refresh") { [weak self] in
            self?.loadAPIKeys()
        }
        refresh.isEnabled = !state.apiKeysLoading
        header.addArrangedSubview(refresh)
        addFullWidth(header, to: root)

        addFullWidth(label(
            "管理当前服务的 API 密钥，可复制、新增或删除。",
            font: .systemFont(ofSize: 11),
            color: .secondaryLabelColor
        ), to: root)

        if let error = state.apiKeysError {
            addFullWidth(messageView(text: error), to: root)
        }

        addFullWidth(apiKeyAddRow(), to: root)

        if state.apiKeysLoading && state.apiKeys == nil {
            addFullWidth(placeholderCard(symbol: "key.horizontal", title: "加载中", detail: "正在获取 API 密钥…"), to: root)
        } else if let keys = state.apiKeys {
            if keys.isEmpty {
                addFullWidth(placeholderCard(symbol: "key.horizontal", title: "暂无密钥", detail: "在上方输入并新增第一个 API 密钥。"), to: root)
            } else {
                let scroll = NSScrollView()
                scroll.hasVerticalScroller = true
                scroll.borderType = .noBorder
                scroll.drawsBackground = false
                scroll.scrollerStyle = .overlay
                scroll.automaticallyAdjustsContentInsets = false

                let stack = TopAlignedStackView()
                stack.orientation = .vertical
                stack.alignment = .leading
                stack.spacing = 6
                stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 4, right: 0)
                stack.translatesAutoresizingMaskIntoConstraints = false
                scroll.documentView = stack
                NSLayoutConstraint.activate([
                    stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
                ])

                for key in keys {
                    let row = apiKeyRow(key)
                    stack.addArrangedSubview(row)
                    row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                }
                scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
                addFullWidth(scroll, to: root)
            }
        }

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        root.addArrangedSubview(spacer)
    }

    private func apiKeyAddRow() -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 6
        container.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false

        let field = NSTextField(string: "")
        field.placeholderString = "输入新的 API 密钥"
        field.font = .systemFont(ofSize: 12)
        field.bezelStyle = .roundedBezel
        field.lineBreakMode = .byTruncatingHead
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.heightAnchor.constraint(equalToConstant: 28).isActive = true
        row.addArrangedSubview(field)

        let addButton = CallbackButton(title: state.apiKeyAdding ? "添加中…" : "添加") { [weak self, weak field] in
            guard let self, let field else { return }
            self.submitNewAPIKey(field.stringValue)
        }
        addButton.bezelStyle = .rounded
        addButton.isEnabled = !state.apiKeyAdding
        addButton.setContentHuggingPriority(.required, for: .horizontal)
        row.addArrangedSubview(addButton)
        container.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true

        // One-click: generate a strong random key, save it, and copy it to the clipboard.
        let generate = CallbackButton(title: "🎲 生成随机密钥并复制") { [weak self] in
            self?.generateAndAddAPIKey()
        }
        generate.bezelStyle = .rounded
        generate.isEnabled = !state.apiKeyAdding
        container.addArrangedSubview(generate)

        return container
    }

    private func apiKeyRow(_ key: String) -> NSView {
        let card = cardView()
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8)
        ])

        let keyLabel = label(maskKey(key), font: .monospacedSystemFont(ofSize: 12, weight: .regular), color: .labelColor)
        keyLabel.lineBreakMode = .byTruncatingMiddle
        keyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(keyLabel)
        row.addArrangedSubview(NSView())

        if state.pendingDeleteKey == key {
            row.addArrangedSubview(label("删除？", font: .systemFont(ofSize: 11, weight: .medium), color: .systemRed))
            let confirm = CallbackButton(title: "删除") { [weak self] in
                self?.deleteAPIKeyConfirmed(key)
            }
            confirm.bezelStyle = .rounded
            confirm.contentTintColor = .systemRed
            confirm.font = .systemFont(ofSize: 11, weight: .semibold)
            row.addArrangedSubview(confirm)
            row.addArrangedSubview(linkButton(title: "取消") { [weak self] in
                self?.state.pendingDeleteKey = nil
                self?.render()
            })
        } else {
            row.addArrangedSubview(circularIconButton(symbol: "doc.on.doc", tooltip: "复制密钥") { [weak self] in
                self?.copyToClipboard(key, notice: "已复制密钥")
            })
            let trash = circularIconButton(symbol: "trash", tooltip: "删除密钥") { [weak self] in
                self?.state.pendingDeleteKey = key
                self?.render()
            }
            trash.contentTintColor = .systemRed
            row.addArrangedSubview(trash)
        }
        return card
    }

    private func maskKey(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 4 {
            return trimmed
        }
        if trimmed.count <= 12 {
            return String(trimmed.prefix(2)) + "••••" + String(trimmed.suffix(2))
        }
        return String(trimmed.prefix(6)) + "••••••" + String(trimmed.suffix(4))
    }

    private func loadAPIKeys() {
        guard state.settings.isConfigured else {
            state.apiKeysError = "请先配置服务地址与管理密钥。"
            render()
            return
        }
        state.apiKeysLoading = true
        state.apiKeysError = nil
        render()
        let settings = state.settings
        Task { @MainActor [weak self] in
            guard let self else { return }
            let client = CLIProxyAPIClient(settings: settings)
            do {
                let keys = try await client.fetchAPIKeys()
                guard self.state.screen == .apiKeys else { return }
                self.state.apiKeys = keys
                self.state.apiKeysLoading = false
                self.state.pendingDeleteKey = nil
                self.render()
            } catch {
                guard self.state.screen == .apiKeys else { return }
                self.state.apiKeysError = self.friendlyMessage(error)
                self.state.apiKeysLoading = false
                self.render()
            }
        }
    }

    private func submitNewAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, state.settings.isConfigured, !state.apiKeyAdding else { return }
        state.apiKeyAdding = true
        state.apiKeysError = nil
        render()
        let settings = state.settings
        Task { @MainActor [weak self] in
            guard let self else { return }
            let client = CLIProxyAPIClient(settings: settings)
            do {
                try await client.addAPIKey(trimmed)
                let keys = try await client.fetchAPIKeys()
                guard self.state.screen == .apiKeys else { return }
                self.state.apiKeys = keys
                self.state.apiKeyAdding = false
                self.render()
                self.showToast("已新增密钥")
            } catch {
                guard self.state.screen == .apiKeys else { return }
                self.state.apiKeysError = self.friendlyMessage(error)
                self.state.apiKeyAdding = false
                self.render()
            }
        }
    }

    /// Generates a strong random key, saves it, and copies it to the clipboard in one step.
    private func generateAndAddAPIKey() {
        guard state.settings.isConfigured, !state.apiKeyAdding else { return }
        let key = generateAPIKey()
        state.apiKeyAdding = true
        state.apiKeysError = nil
        render()
        let settings = state.settings
        Task { @MainActor [weak self] in
            guard let self else { return }
            let client = CLIProxyAPIClient(settings: settings)
            do {
                try await client.addAPIKey(key)
                let keys = try await client.fetchAPIKeys()
                guard self.state.screen == .apiKeys else { return }
                self.state.apiKeys = keys
                self.state.apiKeyAdding = false
                self.render()
                self.copyToClipboard(key, notice: "已生成并复制密钥")
            } catch {
                guard self.state.screen == .apiKeys else { return }
                self.state.apiKeysError = self.friendlyMessage(error)
                self.state.apiKeyAdding = false
                self.render()
            }
        }
    }

    private func deleteAPIKeyConfirmed(_ key: String) {
        guard state.settings.isConfigured else { return }
        state.pendingDeleteKey = nil
        state.apiKeysError = nil
        render()
        let settings = state.settings
        Task { @MainActor [weak self] in
            guard let self else { return }
            let client = CLIProxyAPIClient(settings: settings)
            do {
                try await client.deleteAPIKey(key)
                let keys = try await client.fetchAPIKeys()
                guard self.state.screen == .apiKeys else { return }
                self.state.apiKeys = keys
                self.render()
                self.showToast("已删除密钥")
            } catch {
                guard self.state.screen == .apiKeys else { return }
                self.state.apiKeysError = self.friendlyMessage(error)
                self.render()
            }
        }
    }

    // MARK: - Account detail

    private func openDetail(_ account: AccountQuota) {
        state.detailAccount = account
        state.detailModels = []
        state.detailModelsError = nil
        state.detailModelsLoading = false
        state.detailRefreshing = false
        state.screen = .detail
        render()
        loadDetailModels(for: account)
    }

    private func showDashboard() {
        state.screen = .dashboard
        state.detailAccount = nil
        state.detailModels = []
        render()
    }

    private func loadDetailModels(for account: AccountQuota) {
        guard state.settings.isConfigured else { return }
        state.detailModelsLoading = true
        render()
        let settings = state.settings
        let accountID = account.id
        Task { @MainActor [weak self] in
            let client = CLIProxyAPIClient(settings: settings)
            do {
                let models = try await client.fetchModels(for: account.auth)
                guard let self, self.state.screen == .detail, self.state.detailAccount?.id == accountID else { return }
                self.state.detailModels = models
                self.state.detailModelsLoading = false
                self.render()
            } catch {
                guard let self, self.state.screen == .detail, self.state.detailAccount?.id == accountID else { return }
                self.state.detailModelsError = error.localizedDescription
                self.state.detailModelsLoading = false
                self.render()
            }
        }
    }

    private func refreshDetail() {
        guard let account = state.detailAccount, state.settings.isConfigured else { return }
        state.detailRefreshing = true
        state.detailModelsLoading = true
        render()
        let settings = state.settings
        let accountID = account.id
        let existingDetail = account.detail
        Task { @MainActor [weak self] in
            let client = CLIProxyAPIClient(settings: settings)
            let refreshed = await client.refreshUsage(for: account.auth, detail: existingDetail)
            let models = try? await client.fetchModels(for: account.auth)
            guard let self, self.state.screen == .detail, self.state.detailAccount?.id == accountID else { return }
            self.state.detailAccount = refreshed
            if let models {
                self.state.detailModels = models
                self.state.detailModelsError = nil
            }
            self.state.detailRefreshing = false
            self.state.detailModelsLoading = false
            self.render()
        }
    }

    private func renderDetail(in root: NSStackView) {
        guard let account = state.detailAccount else {
            renderDashboard(in: root)
            return
        }
        addFullWidth(detailHeader(account), to: root)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)

        let stack = TopAlignedStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 6, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])

        func addSection(_ view: NSView) {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        addSection(detailHeroCard(account))
        addSection(detailQuotaCard(account))
        addSection(detailRunStatusCard(account))
        if let detail = account.detail {
            if detail.totalRequests > 0 || !detail.recentRequests.isEmpty {
                addSection(detailRecentRequestsCard(detail))
            }
            if !detail.activeModelCooldowns.isEmpty {
                addSection(detailModelCooldownCard(detail))
            }
        }
        addSection(detailModelsCard(account))
        addSection(detailAccountInfoCard(account))

        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        addFullWidth(scroll, to: root)
    }

    private func detailHeader(_ account: AccountQuota) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        let back = circularIconButton(symbol: "chevron.left", tooltip: "Back") { [weak self] in
            self?.showDashboard()
        }
        row.addArrangedSubview(back)

        let title = label(account.auth.displayName, font: .systemFont(ofSize: 16, weight: .semibold), color: .labelColor)
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(title)
        row.addArrangedSubview(NSView())

        let refresh = circularIconButton(symbol: "arrow.clockwise", tooltip: "Refresh") { [weak self] in
            self?.refreshDetail()
        }
        refresh.isEnabled = !state.detailRefreshing
        row.addArrangedSubview(refresh)
        return row
    }

    private func detailHeroCard(_ account: AccountQuota) -> NSView {
        let card = cardView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12)
        ])

        let top = NSStackView()
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 10
        top.addArrangedSubview(providerBadgeView(for: account.auth))

        let titleStack = NSStackView()
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2
        // Click the account name to copy the email (falls back to the account identifier).
        let copyValue = firstNonEmpty(account.auth.email, account.auth.account, account.auth.displayName) ?? account.auth.displayName
        let copiedEmail = firstNonEmpty(account.auth.email) != nil
        let name = copyableLabelRow(
            text: account.auth.displayName,
            font: .systemFont(ofSize: 14, weight: .semibold),
            color: .labelColor,
            copyValue: copyValue,
            notice: copiedEmail ? "已复制邮箱" : "已复制账号"
        )
        titleStack.addArrangedSubview(name)
        let provider = ProviderCatalog.info(for: account.auth.normalizedProvider).displayName
        let subtitle = account.effectivePlanType.map { "\(provider) · \($0.capitalized)" } ?? provider
        titleStack.addArrangedSubview(label(subtitle, font: .systemFont(ofSize: 11, weight: .regular), color: .secondaryLabelColor))
        top.addArrangedSubview(titleStack)
        top.addArrangedSubview(NSView())
        let status = detailStatus(account)
        top.addArrangedSubview(pillLabel(status.0, color: status.1))
        stack.addArrangedSubview(top)
        top.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let counters = NSStackView()
        counters.orientation = .horizontal
        counters.distribution = .fillEqually
        counters.alignment = .centerY
        counters.spacing = 0
        counters.addArrangedSubview(statView(value: "\(account.detail?.success ?? 0)", label: "成功", color: .systemGreen))
        counters.addArrangedSubview(statView(value: "\(account.detail?.failed ?? 0)", label: "失败", color: .systemRed))
        counters.addArrangedSubview(statView(value: displayPercent(account.lowestRemainingPercent), label: "最低剩余", color: summaryColor(account.lowestRemainingPercent)))
        stack.addArrangedSubview(counters)
        counters.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return card
    }

    private func detailQuotaCard(_ account: AccountQuota) -> NSView {
        detailSectionCard(title: "实时剩余额度", symbol: "gauge.with.dots.needle.50percent") { stack in
            if let error = account.errorMessage, !error.isEmpty {
                let note = noteLabel(text: trimError(error), color: .systemRed)
                stack.addArrangedSubview(note)
                note.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            } else if account.usage?.hasQuotaSignal == true {
                for (labelText, window) in quotaRows(for: account.usage) {
                    let row = quotaLine(label: labelText, window: window)
                    stack.addArrangedSubview(row)
                    row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                }
            } else {
                let note = noteLabel(text: account.auth.disabled ? "已暂停" : "该来源仅显示身份状态")
                stack.addArrangedSubview(note)
                note.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            if let date = account.usage?.fetchedAt {
                stack.addArrangedSubview(label("同步于 \(relativeShort(date))", font: .systemFont(ofSize: 10), color: .tertiaryLabelColor))
            }
        }
    }

    private func detailRunStatusCard(_ account: AccountQuota) -> NSView {
        detailSectionCard(title: "运行状态", symbol: "speedometer") { stack in
            let detail = account.detail
            var added = false
            @MainActor func addRow(_ title: String, _ value: String?) {
                guard let value, !value.isEmpty else { return }
                let row = detailRow(title: title, value: value)
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                added = true
            }
            addRow("原因", detail?.quotaReason ?? account.auth.statusMessage)
            if let date = detail?.nextRecoveryDate {
                addRow("预计恢复", absoluteTime(date))
            }
            if let date = detail?.lastRefresh {
                addRow("上次刷新", absoluteTime(date))
            }
            if let date = detail?.nextRefreshAfter {
                addRow("下次刷新", absoluteTime(date))
            }
            if let credits = detail?.credits, credits.known {
                addRow("AI Credits", creditsLine(credits))
            }
            addRow("最近错误", detail?.lastErrorMessage)
            if !added {
                addRow("状态", account.auth.status ?? "未知")
            }
        }
    }

    private func detailRecentRequestsCard(_ detail: AccountDetail) -> NSView {
        detailSectionCard(title: "最近请求", symbol: "chart.bar.xaxis") { stack in
            let summary = label("累计成功 \(detail.success) · 失败 \(detail.failed)", font: .systemFont(ofSize: 11, weight: .medium), color: .secondaryLabelColor)
            stack.addArrangedSubview(summary)
            if !detail.recentRequests.isEmpty {
                let chart = RequestBarsView(buckets: detail.recentRequests)
                chart.heightAnchor.constraint(equalToConstant: 40).isActive = true
                stack.addArrangedSubview(chart)
                chart.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
    }

    private func detailModelCooldownCard(_ detail: AccountDetail) -> NSView {
        detailSectionCard(title: "模型状态", symbol: "hourglass") { stack in
            for item in detail.activeModelCooldowns {
                let block = NSStackView()
                block.orientation = .vertical
                block.alignment = .leading
                block.spacing = 3
                block.addArrangedSubview(label(item.model, font: .systemFont(ofSize: 11, weight: .semibold), color: .labelColor))
                let message = firstNonEmpty(item.state.statusMessage, item.state.lastErrorMessage, item.state.status)
                if let message {
                    block.addArrangedSubview(noteLabel(text: message))
                }
                if let date = item.state.nextRetryAfter, date > Date() {
                    block.addArrangedSubview(label("恢复 \(absoluteTime(date))", font: .systemFont(ofSize: 10), color: .systemOrange))
                }
                stack.addArrangedSubview(block)
                block.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
    }

    private func detailModelsCard(_ account: AccountQuota) -> NSView {
        detailSectionCard(title: "可用模型", symbol: "square.stack.3d.up.fill") { stack in
            if state.detailModelsLoading && state.detailModels.isEmpty {
                stack.addArrangedSubview(label("正在加载模型…", font: .systemFont(ofSize: 11), color: .secondaryLabelColor))
            } else if let error = state.detailModelsError, state.detailModels.isEmpty {
                let note = noteLabel(text: trimError(error), color: .systemRed)
                stack.addArrangedSubview(note)
                note.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            } else if state.detailModels.isEmpty {
                stack.addArrangedSubview(label("暂无模型数据", font: .systemFont(ofSize: 11), color: .secondaryLabelColor))
            } else {
                for model in sortedDetailModels(account) {
                    let row = modelRowView(model, account: account)
                    stack.addArrangedSubview(row)
                    row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                }
            }
        }
    }

    private func detailAccountInfoCard(_ account: AccountQuota) -> NSView {
        detailSectionCard(title: "账号信息", symbol: "info.circle.fill") { stack in
            let auth = account.auth
            let detail = account.detail
            @MainActor func addRow(_ title: String, _ value: String?, copyable: Bool = false) {
                guard let value, !value.isEmpty else { return }
                let row = copyable ? detailRow(title: title, value: value, copyNotice: "已复制\(title)")
                                   : detailRow(title: title, value: value)
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            addRow("Provider", ProviderCatalog.info(for: auth.normalizedProvider).displayName)
            addRow("邮箱", auth.email, copyable: true)
            addRow("项目", auth.projectID)
            addRow("账号类型", detail?.accountType)
            addRow("账号标识", auth.account, copyable: true)
            addRow("ChatGPT Account ID", detail?.chatgptAccountID ?? auth.accountID, copyable: true)
            addRow("Auth Index", auth.authIndex.isEmpty ? nil : auth.authIndex)
            addRow("计划", account.effectivePlanType?.capitalized)
            if let date = detail?.subscriptionActiveStart {
                addRow("订阅开始", absoluteTime(date))
            }
            if let date = detail?.subscriptionActiveUntil {
                addRow("订阅到期", absoluteTime(date))
            }
            if detail?.runtimeOnly == true {
                addRow("来源", "运行时")
            } else {
                addRow("来源", detail?.source)
            }
            if let websockets = detail?.websockets {
                addRow("WebSocket", websockets ? "启用" : "关闭")
            }
            if let priority = detail?.priority {
                addRow("优先级", "\(priority)")
            }
            addRow("备注", detail?.note)
            if let date = detail?.updatedAt {
                addRow("更新时间", absoluteTime(date))
            }
        }
    }

    // MARK: - Detail building blocks

    private func detailSectionCard(title: String, symbol: String, build: @MainActor (NSStackView) -> Void) -> NSView {
        let card = cardView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 11),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -11)
        ])

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        header.addArrangedSubview(icon)
        header.addArrangedSubview(label(title, font: .systemFont(ofSize: 12, weight: .semibold), color: .secondaryLabelColor))
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        build(stack)
        return card
    }

    private func detailRow(title: String, value: String, copyNotice: String? = nil) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2

        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 4
        titleRow.addArrangedSubview(label(title, font: .systemFont(ofSize: 10, weight: .semibold), color: .secondaryLabelColor))
        if copyNotice != nil {
            let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            let copyIcon = NSImageView(image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "复制")?
                .withSymbolConfiguration(config) ?? NSImage())
            copyIcon.contentTintColor = .tertiaryLabelColor
            titleRow.addArrangedSubview(copyIcon)
        }
        stack.addArrangedSubview(titleRow)

        let valueLabel = label(value, font: .systemFont(ofSize: 12, weight: .regular), color: .labelColor)
        valueLabel.lineBreakMode = .byWordWrapping
        valueLabel.maximumNumberOfLines = 3
        // Copyable rows handle clicks themselves; leave non-copyable values text-selectable.
        valueLabel.isSelectable = (copyNotice == nil)
        valueLabel.preferredMaxLayoutWidth = popoverWidth - 92
        stack.addArrangedSubview(valueLabel)

        guard let copyNotice else {
            return stack
        }
        let clickable = ClickableCardView(fill: .clear, border: .clear, radius: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        clickable.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: clickable.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: clickable.trailingAnchor),
            stack.topAnchor.constraint(equalTo: clickable.topAnchor),
            stack.bottomAnchor.constraint(equalTo: clickable.bottomAnchor)
        ])
        clickable.toolTip = "点击复制"
        clickable.onClick = { [weak self] in
            self?.copyToClipboard(value, notice: copyNotice)
        }
        return clickable
    }

    /// A label paired with a copy glyph; clicking anywhere copies `copyValue`.
    private func copyableLabelRow(text: String, font: NSFont, color: NSColor, copyValue: String, notice: String) -> NSView {
        let clickable = ClickableCardView(fill: .clear, border: .clear, radius: 5)
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 5
        row.translatesAutoresizingMaskIntoConstraints = false

        let textLabel = label(text, font: font, color: color)
        textLabel.lineBreakMode = .byTruncatingMiddle
        textLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(textLabel)

        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        let copyIcon = NSImageView(image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "复制")?
            .withSymbolConfiguration(config) ?? NSImage())
        copyIcon.contentTintColor = .tertiaryLabelColor
        copyIcon.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.addArrangedSubview(copyIcon)

        clickable.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: clickable.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: clickable.trailingAnchor),
            row.topAnchor.constraint(equalTo: clickable.topAnchor, constant: 1),
            row.bottomAnchor.constraint(equalTo: clickable.bottomAnchor, constant: -1)
        ])
        clickable.toolTip = "点击复制"
        clickable.onClick = { [weak self] in
            self?.copyToClipboard(copyValue, notice: notice)
        }
        return clickable
    }

    private func detailStatus(_ account: AccountQuota) -> (String, NSColor) {
        if account.errorMessage?.isEmpty == false {
            return ("异常", .systemRed)
        }
        if account.isDisabled {
            return ("已停用", .tertiaryLabelColor)
        }
        if account.detail?.quotaExceeded == true || account.hasUnusableQuotaWindow {
            return ("受限", .systemOrange)
        }
        if account.isUnavailable {
            return ("不可用", .tertiaryLabelColor)
        }
        if let remaining = account.lowestRemainingPercent {
            if remaining <= 15 { return ("紧张", .systemRed) }
            if remaining <= 35 { return ("偏低", .systemOrange) }
        }
        if account.usage?.hasQuotaSignal == true || account.detail != nil {
            return ("可用", .systemGreen)
        }
        return (account.auth.status ?? "未知", .secondaryLabelColor)
    }

    private func creditsLine(_ credits: AccountCredits) -> String {
        let state = credits.available ? "可用" : "不足"
        let amount = displayCredits(credits.creditAmount)
        if let minimum = credits.minCreditAmount {
            return "\(state) · \(amount) / \(displayCredits(minimum))"
        }
        return "\(state) · \(amount)"
    }

    private func sortedDetailModels(_ account: AccountQuota) -> [CPAModelDefinition] {
        state.detailModels.sorted { lhs, rhs in
            let leftRank = modelRuntime(lhs, account: account).rank
            let rightRank = modelRuntime(rhs, account: account).rank
            if leftRank != rightRank {
                return leftRank < rightRank
            }
            let leftName = lhs.displayName ?? lhs.id
            let rightName = rhs.displayName ?? rhs.id
            return leftName.localizedCaseInsensitiveCompare(rightName) == .orderedAscending
        }
    }

    private func modelRowView(_ model: CPAModelDefinition, account: AccountQuota) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        let nameStack = NSStackView()
        nameStack.orientation = .vertical
        nameStack.alignment = .leading
        nameStack.spacing = 1
        let nameLabel = label(model.displayName ?? model.id, font: .systemFont(ofSize: 11, weight: .medium), color: .labelColor)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameStack.addArrangedSubview(nameLabel)
        if model.displayName != nil {
            let idLabel = label(model.id, font: .systemFont(ofSize: 9, weight: .regular), color: .tertiaryLabelColor)
            idLabel.lineBreakMode = .byTruncatingMiddle
            nameStack.addArrangedSubview(idLabel)
        }
        nameStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(nameStack)
        row.addArrangedSubview(NSView())
        let runtime = modelRuntime(model, account: account)
        row.addArrangedSubview(pillLabel(runtime.title, color: runtime.color))
        return row
    }

    private func modelRuntime(_ model: CPAModelDefinition, account: AccountQuota) -> (rank: Int, title: String, color: NSColor) {
        let keys = [model.id.lowercased(), (model.displayName ?? "").lowercased()].filter { !$0.isEmpty }
        let modelState = account.detail?.modelStates.first { keys.contains($0.key.lowercased()) }?.value
        guard let modelState else {
            return (3, "可用", .systemGreen)
        }
        let status = (modelState.status ?? "").lowercased()
        if status.contains("error") || status.contains("fail") || (modelState.lastErrorMessage ?? "").isEmpty == false {
            return (0, "异常", .systemRed)
        }
        if modelState.unavailable || modelState.quotaExceeded ||
            (modelState.nextRetryAfter.map { $0 > Date() } == true) ||
            status.contains("cool") || status.contains("limit") || status.contains("quota") ||
            status.contains("exceeded") || status.contains("unavailable") {
            return (1, "受限", .systemOrange)
        }
        if status.contains("pending") || status.contains("refresh") {
            return (2, "同步中", .systemBlue)
        }
        return (3, "可用", .systemGreen)
    }

    private func providerBadgeView(for auth: AuthFile, size: CGFloat = 30) -> NSView {
        let info = ProviderCatalog.info(for: auth.normalizedProvider)
        let accent = providerAccentColor(info.accentName)
        let badge = RoundedView(fill: accent.withAlphaComponent(0.16), border: .clear, radius: 7)
        badge.translatesAutoresizingMaskIntoConstraints = false
        let config = NSImage.SymbolConfiguration(pointSize: size * 0.45, weight: .semibold)
        let icon = NSImageView(image: NSImage(systemSymbolName: info.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage())
        icon.contentTintColor = accent
        icon.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(icon)
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: size),
            badge.heightAnchor.constraint(equalToConstant: size),
            icon.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: badge.centerYAnchor)
        ])
        return badge
    }

    private func pillLabel(_ text: String, color: NSColor) -> NSView {
        let pill = RoundedView(fill: color.withAlphaComponent(0.16), border: .clear, radius: 5)
        let textLabel = label(text, font: .systemFont(ofSize: 10, weight: .semibold), color: color)
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(textLabel)
        NSLayoutConstraint.activate([
            textLabel.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 7),
            textLabel.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -7),
            textLabel.topAnchor.constraint(equalTo: pill.topAnchor, constant: 2),
            textLabel.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -2)
        ])
        return pill
    }

    private func clickableCardView() -> ClickableCardView {
        ClickableCardView(
            fill: NSColor.controlBackgroundColor.withAlphaComponent(0.55),
            border: NSColor.separatorColor.withAlphaComponent(0.18),
            radius: 12
        )
    }

    private func absoluteTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func relativeShort(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
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
    var onClick: (() -> Void)?

    init(title: String, callback: @escaping () -> Void) {
        self.onClick = callback
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
        onClick?()
    }
}

@MainActor
final class CallbackMenuItem: NSMenuItem {
    private let callback: () -> Void

    init(title: String, callback: @escaping () -> Void) {
        self.callback = callback
        super.init(title: title, action: #selector(runCallback), keyEquivalent: "")
        self.target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func runCallback() {
        callback()
    }
}

final class TopAlignedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

class RoundedView: NSView {
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

final class ClickableCardView: RoundedView {
    var onClick: (() -> Void)?

    override init(fill: NSColor, border: NSColor, radius: CGFloat = 10) {
        super.init(fill: fill, border: border, radius: radius)
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(handleClick)))
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    @objc private func handleClick() {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

final class RequestBarsView: NSView {
    private let buckets: [RecentRequestBucket]

    init(buckets: [RecentRequestBucket]) {
        self.buckets = buckets
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        self.buckets = []
        super.init(coder: coder)
    }

    override func draw(_ dirtyRect: NSRect) {
        let visible = Array(buckets.suffix(16))
        guard !visible.isEmpty else { return }
        let maxValue = max(visible.map { $0.success + $0.failed }.max() ?? 1, 1)
        let gap: CGFloat = 2
        let count = CGFloat(visible.count)
        let barWidth = max(1, (bounds.width - gap * (count - 1)) / count)
        for (index, bucket) in visible.enumerated() {
            let total = bucket.success + bucket.failed
            let height = max(2, bounds.height * CGFloat(total) / CGFloat(maxValue))
            let x = CGFloat(index) * (barWidth + gap)
            let color: NSColor = bucket.failed > 0 ? .systemOrange : .systemTeal
            color.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: x, y: 0, width: barWidth, height: height),
                xRadius: 1.5,
                yRadius: 1.5
            ).fill()
        }
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
