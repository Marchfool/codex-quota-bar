import AppKit
import CodexQuotaBarSupport
import CodexQuotaCore
import CommonCrypto
import Foundation
import LocalAuthentication
import Security
import SQLite3
import SwiftUI
import WebKit
import WidgetKit

private enum RuntimeDiagnostics {
    static var buildID: String {
        Bundle.main.object(forInfoDictionaryKey: "CodexQuotaBuildID") as? String ?? "development"
    }

    static var buildTimestamp: String {
        Bundle.main.object(forInfoDictionaryKey: "CodexQuotaBuildTimestamp") as? String ?? "local"
    }

    static var buildLine: String {
        "Build \(buildID) · \(buildTimestamp)"
    }

    static var executablePath: String {
        Bundle.main.executableURL?.path ?? CommandLine.arguments.first ?? "unknown"
    }
}

private enum StartupRefreshPolicy {
    static let initialRefreshDelay: Duration = .seconds(2)
    static let initialRefreshDelaySeconds: TimeInterval = 2
    static let unifiedRefreshIntervalSeconds: TimeInterval = 120
}

@MainActor
private final class RefreshCadence: ObservableObject {
    let intervalSeconds: TimeInterval
    @Published private(set) var nextRefreshAt: Date
    @Published private(set) var isRefreshing = false

    init(intervalSeconds: TimeInterval, initialDelaySeconds: TimeInterval) {
        self.intervalSeconds = intervalSeconds
        self.nextRefreshAt = Date().addingTimeInterval(initialDelaySeconds)
    }

    func markStarted(now: Date = Date()) {
        isRefreshing = true
        nextRefreshAt = now.addingTimeInterval(intervalSeconds)
    }

    func markFinished(now: Date = Date()) {
        isRefreshing = false
        nextRefreshAt = now.addingTimeInterval(intervalSeconds)
    }
}

private struct AppLaunchDiagnostics {
    let bundleIdentifier: String
    let executablePath: String
    let signingIdentity: String
    let isAdHocSigned: Bool

    static func capture() -> AppLaunchDiagnostics {
        let bundlePath = Bundle.main.bundleURL.path
        let signingReport = signingReport(for: bundlePath)
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "unknown"
        let executablePath = RuntimeDiagnostics.executablePath
        let identity = parseSigningIdentity(from: signingReport) ?? "unknown"
        let isAdHoc = signingReport.contains("Signature=adhoc")

        return AppLaunchDiagnostics(
            bundleIdentifier: bundleIdentifier,
            executablePath: executablePath,
            signingIdentity: identity,
            isAdHocSigned: isAdHoc
        )
    }

    private static func signingReport(for path: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dv", "--verbose=4", path]
        let outputPipe = Pipe()
        process.standardError = outputPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "codesign_unavailable:\(error.localizedDescription)"
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func parseSigningIdentity(from report: String) -> String? {
        let lines = report.split(separator: "\n").map(String.init)
        if let authority = lines.first(where: { $0.hasPrefix("Authority=") }) {
            return String(authority.dropFirst("Authority=".count))
        }
        if lines.contains(where: { $0 == "Signature=adhoc" }) {
            return "adhoc"
        }
        return nil
    }
}

private struct StartupImportDecision {
    let shouldImport: Bool
    let reason: String
}

private final class FullBleedHostingView<Content: View>: NSHostingView<Content> {
    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsets()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var manager: QuotaManager!
    private var apiKeyManager: APIKeyManager!
    private var secretStore: KeychainSecretStore!
    private var profileStore: FileProfileStore!
    private var accountsWindow: NSWindow?
    private var apiKeysWindow: NSWindow?
    private var desktopWidgetWindow: NSPanel?
    private let popover = NSPopover()
    private var popoverContentViewController: NSViewController?
    private var claudeWebFetcher: ClaudeWebFetcher?
    private let memoryMonitor = MemoryMonitorController()
    private let trafficLight = CodexTrafficLightController()
    private let claudeActivity = ClaudeActivityController()
    private var didPerformStartupImport = false
    private var startupImportReason = "not_evaluated"
    private var didAccessClaudeSafeStorageDuringLaunch = false
    private var isPerformingInitialLaunchRefresh = false
    private var unifiedPollingTask: Task<Void, Never>?
    private var isRunningUnifiedRefresh = false
    private let keychainSecurityACLVersion = 3
    private let keychainSecurityACLVersionKey = "keychainSecurityACLVersion"
    private let desktopWidgetRestoreOnLaunchKey = "desktopWidgetRestoreOnLaunch"
    private let refreshCadence = RefreshCadence(
        intervalSeconds: StartupRefreshPolicy.unifiedRefreshIntervalSeconds,
        initialDelaySeconds: StartupRefreshPolicy.initialRefreshDelaySeconds
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let launchDiagnostics = AppLaunchDiagnostics.capture()
        NSLog(
            "CodexQuotaBar launching build=%@ bundleID=%@ path=%@ signingIdentity=%@ adhoc=%@",
            RuntimeDiagnostics.buildID,
            launchDiagnostics.bundleIdentifier,
            launchDiagnostics.executablePath,
            launchDiagnostics.signingIdentity,
            String(launchDiagnostics.isAdHocSigned)
        )

        secretStore = KeychainSecretStore()
        profileStore = FileProfileStore()
        manager = QuotaManager(
            store: FileSlotStore(),
            provider: OfficialCodexProvider(secretStore: secretStore),
            importer: CodexAuthImporter(secretStore: secretStore, profileStore: profileStore)
        )
        apiKeyManager = APIKeyManager(store: FileAPIKeyConfigStore(), secretStore: secretStore)
        apiKeyManager.claudeFetcher = { [weak self] allowsUserInteraction in
            guard let self else { throw ClaudeFetchError.webFetchFailed("应用已退出") }
            return try await self.fetchClaudeOrganizations(allowsUserInteraction: allowsUserInteraction)
        }
        manager.load()
        apiKeyManager.load()
        migrateStoredProfiles()
        let startupImportDecision = evaluateStartupImport()
        startupImportReason = startupImportDecision.reason
        if startupImportDecision.shouldImport {
            didPerformStartupImport = true
            if silentlyImportCurrentCodexAccount() {
                UserDefaults.standard.set(keychainSecurityACLVersion, forKey: keychainSecurityACLVersionKey)
            }
        }
        NSLog(
            "CodexQuotaBar startup import performed=%@ reason=%@",
            String(didPerformStartupImport),
            startupImportReason
        )

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.target = self
        statusItem?.button?.action = #selector(togglePopover)
        configureStatusButton()

        // Always start data collection (the dropdown/widget cards need it even when the
        // menu-bar items are hidden); the toggles only control status-item visibility.
        memoryMonitor.start()
        trafficLight.start()
        // Claude has no reliable "generating" signal (Electron + opaque IndexedDB), so its
        // activity watcher is left inert — the Claude card stays static. Only Codex has a work light.
        applyStatusBarVisibility()

        popover.behavior = .transient
        popover.animates = true
        updatePopoverSize()

        Task {
            isPerformingInitialLaunchRefresh = true
            try? await Task.sleep(for: StartupRefreshPolicy.initialRefreshDelay)
            await refreshEverything(quotaTrigger: .launch, apiTrigger: .launch)
            isPerformingInitialLaunchRefresh = false
            NSLog(
                "CodexQuotaBar startup refresh completed claudeSafeStorageAccessed=%@",
                String(didAccessClaudeSafeStorageDuringLaunch)
            )
            WidgetCenter.shared.reloadAllTimelines()
            updatePopoverSize()
            configureStatusButton()
            startUnifiedPolling()
        }
        if UserDefaults.standard.bool(forKey: desktopWidgetRestoreOnLaunchKey) {
            showDesktopWidget()
        }

        // Status-bar text shows reset countdowns in minutes; 15s refresh is plenty and avoids
        // rebuilding the attributed title every few seconds.
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.configureStatusButton()
                self?.updatePopoverSize()
            }
        }
    }

    private func updatePopoverSize() {
        popover.contentSize = NSSize(
            width: PanelMetrics.width,
            height: PanelMetrics.height(
                codexSlotCount: manager.slots.count,
                apiProviderCount: apiKeyManager.providers.count,
                hasError: manager.lastError != nil
            )
        )
    }

    private func configureStatusButton() {
        guard let button = statusItem?.button else { return }
        button.image = nil
        button.contentTintColor = nil
        button.attributedTitle = makeStatusBarTitle()
    }

    private func makeStatusBarTitle() -> NSAttributedString {
        let title = NSMutableAttributedString()
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        let separatorAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let dotAttributes: (NSColor) -> [NSAttributedString.Key: Any] = { color in
            [
                .font: NSFont.systemFont(ofSize: 8.5, weight: .bold),
                .foregroundColor: color,
                .baselineOffset: 0.5
            ]
        }

        title.append(NSAttributedString(
            string: "●",
            attributes: dotAttributes(NSColor(calibratedRed: 0.07, green: 0.66, blue: 0.78, alpha: 1.0))
        ))
        title.append(NSAttributedString(
            string: " \(statusBarPlatformText(name: "Codex", percent: manager.sessionRemaining, resetAt: manager.sessionResetAt))",
            attributes: textAttributes
        ))
        title.append(NSAttributedString(string: " | ", attributes: separatorAttributes))
        title.append(NSAttributedString(
            string: "●",
            attributes: dotAttributes(NSColor(calibratedRed: 0.88, green: 0.35, blue: 0.17, alpha: 1.0))
        ))
        title.append(NSAttributedString(
            string: " \(statusBarPlatformText(name: "Claude", percent: apiKeyManager.claudeFiveHourRemaining, resetAt: apiKeyManager.claudeFiveHourResetAt))",
            attributes: textAttributes
        ))
        return title
    }

    private func statusBarPlatformText(name: String, percent: Int?, resetAt: Date?) -> String {
        "\(name) \(statusBarPercentText(percent)) \(statusBarRemainingText(resetAt))"
    }

    private func statusBarPercentText(_ percent: Int?) -> String {
        guard let percent else { return "--" }
        return "\(min(100, max(0, percent)))%"
    }

    private func statusBarRemainingText(_ date: Date?) -> String {
        guard let date else { return "--" }
        let remaining = max(0, Int(date.timeIntervalSinceNow))
        if remaining < 60 {
            return "\(remaining)s"
        }

        let hours = remaining / 3_600
        let minutes = (remaining % 3_600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h\(minutes)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }

    private func makeStatusIcon(isWarning: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 18, height: 18).fill()

        let symbolName = isWarning ? "exclamationmark.triangle.fill" : "terminal.fill"
        let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Codex 额度")
        symbol?.size = NSSize(width: 15, height: 15)
        NSColor.labelColor.setFill()
        symbol?.draw(in: NSRect(x: 1.5, y: 1.5, width: 15, height: 15), from: .zero, operation: .sourceOver, fraction: 1)
        image.isTemplate = true
        return image
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            installPopoverContentIfNeeded()
            updatePopoverSize()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.isOpaque = false
            popover.contentViewController?.view.window?.backgroundColor = .clear
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func installPopoverContentIfNeeded() {
        guard popover.contentViewController == nil else { return }
        let hostingController = NSHostingController(
            rootView: MonitorPanelView(
                manager: manager,
                apiKeyManager: apiKeyManager,
                refreshCadence: refreshCadence,
                memoryMonitor: memoryMonitor,
                trafficLight: trafficLight,
                claudeActivity: claudeActivity,
                refresh: { [weak self] in self?.refreshNow() },
                importAccount: { [weak self] in self?.importAccount() },
                showAccounts: { [weak self] in self?.showAccounts() },
                showAPIKeys: { [weak self] in self?.showAPIKeys() },
                refreshAPIKeys: { [weak self] in self?.refreshAPIKeys() },
                toggleDesktopWidget: { [weak self] in self?.toggleDesktopWidget() },
                openDataFolder: { [weak self] in self?.openLogs() },
                quit: { [weak self] in self?.quit() }
            )
        )
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        popover.contentViewController = hostingController
        popoverContentViewController = hostingController
    }

    @objc private func refreshNow() {
        Task {
            await refreshEverything(quotaTrigger: .manual, apiTrigger: .manual)
            WidgetCenter.shared.reloadAllTimelines()
            updatePopoverSize()
            configureStatusButton()
        }
    }

    @objc private func refreshAPIKeys() {
        Task {
            await apiKeyManager.refreshAll()
            updatePopoverSize()
            configureStatusButton()
        }
    }

    @objc private func importAccount() {
        silentlyImportCurrentCodexAccount()
        refreshNow()
    }

    @objc private func showAccounts() {
        popover.performClose(nil)
        if accountsWindow == nil {
            let view = AccountsView(manager: manager)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 430),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Codex 账号"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: view)
            window.center()
            accountsWindow = window
        }
        accountsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applyStatusBarVisibility() {
        memoryMonitor.setVisible(UserDefaults.standard.object(forKey: "showMemoryIndicator") as? Bool ?? true)
        trafficLight.setVisible(UserDefaults.standard.object(forKey: "showCodexTrafficLight") as? Bool ?? true)
    }

    @objc private func showAPIKeys() {
        popover.performClose(nil)
        if apiKeysWindow == nil {
            let view = APIKeySettingsView(
                manager: apiKeyManager,
                quotaManager: manager,
                openDataFolder: { [weak self] in self?.openLogs() },
                applyStatusBarVisibility: { [weak self] in self?.applyStatusBarVisibility() }
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "设置"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: view)
            window.center()
            apiKeysWindow = window
        }
        apiKeysWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleDesktopWidget() {
        if let window = desktopWidgetWindow, window.isVisible {
            saveDesktopWidgetFrame(window)
            window.orderOut(nil)
            UserDefaults.standard.set(false, forKey: "desktopWidgetVisible")
            UserDefaults.standard.set(false, forKey: desktopWidgetRestoreOnLaunchKey)
            return
        }

        showDesktopWidget()
    }

    private func applyDesktopWidgetPinLevel() {
        let pinned = UserDefaults.standard.bool(forKey: "desktopWidgetPinned")
        desktopWidgetWindow?.level = pinned ? .floating : .normal
        if pinned {
            desktopWidgetWindow?.orderFrontRegardless()
        }
    }

    private func showDesktopWidget() {
        if desktopWidgetWindow == nil {
            let cornerRadius: CGFloat = 28
            let initialFrame = DesktopWidgetFrameStore.initialFrame(visibleFrame: desktopWidgetVisibleFrame())
            let panel = NSPanel(
                contentRect: initialFrame,
                styleMask: [.titled, .fullSizeContentView, .resizable, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.minSize = DesktopWidgetFrameStore.minimumSize
            panel.delegate = self
            panel.title = ""
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.styleMask.insert(.fullSizeContentView)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = UserDefaults.standard.bool(forKey: "desktopWidgetPinned") ? .floating : .normal
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            panel.isMovableByWindowBackground = true
            let hostingView = FullBleedHostingView(rootView: FloatingDesktopWidgetView(
                manager: manager,
                apiKeyManager: apiKeyManager,
                refreshCadence: refreshCadence,
                memoryMonitor: memoryMonitor,
                trafficLight: trafficLight,
                claudeActivity: claudeActivity,
                onPinChanged: { [weak self] in self?.applyDesktopWidgetPinLevel() }
            ))
            hostingView.wantsLayer = true
            hostingView.layer?.cornerRadius = cornerRadius
            hostingView.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            hostingView.layer?.masksToBounds = true
            hostingView.layer?.backgroundColor = NSColor.clear.cgColor
            panel.contentView = hostingView
            hideDesktopWidgetWindowChrome(panel)
            desktopWidgetWindow = panel
        }

        if let window = desktopWidgetWindow {
            let frame = DesktopWidgetFrameStore.clampedFrame(window.frame, visibleFrame: desktopWidgetVisibleFrame())
            window.setFrame(frame, display: false)
            saveDesktopWidgetFrame(window)
        }
        desktopWidgetWindow?.orderFrontRegardless()
        UserDefaults.standard.set(true, forKey: "desktopWidgetVisible")
        UserDefaults.standard.set(true, forKey: desktopWidgetRestoreOnLaunchKey)
    }

    func windowDidMove(_ notification: Notification) {
        saveDesktopWidgetFrame(from: notification)
    }

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === desktopWidgetWindow else { return }
        guard !window.inLiveResize else { return }

        saveDesktopWidgetFrame(window)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        saveDesktopWidgetFrame(from: notification)
    }

    private func hideDesktopWidgetWindowChrome(_ window: NSWindow) {
        [
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton,
            .toolbarButton,
            .documentIconButton
        ].forEach { buttonType in
            window.standardWindowButton(buttonType)?.isHidden = true
        }

        guard let titlebarView = window.standardWindowButton(.closeButton)?.superview else { return }
        titlebarView.isHidden = true
        if let titlebarContainer = titlebarView.superview,
           String(describing: type(of: titlebarContainer)).localizedCaseInsensitiveContains("titlebar") {
            titlebarContainer.isHidden = true
        }
    }

    private func saveDesktopWidgetFrame(from notification: Notification) {
        guard let window = notification.object as? NSWindow, window === desktopWidgetWindow else { return }
        saveDesktopWidgetFrame(window)
    }

    private func saveDesktopWidgetFrame(_ window: NSWindow) {
        DesktopWidgetFrameStore.save(window.frame)
    }

    private func desktopWidgetVisibleFrame() -> CGRect {
        if let window = desktopWidgetWindow,
           let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(window.frame) }) {
            return screen.visibleFrame
        }

        return NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    @objc private func openLogs() {
        NSWorkspace.shared.open(FileSlotStore().fileURL.deletingLastPathComponent())
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @discardableResult
    private func silentlyImportCurrentCodexAccount() -> Bool {
        manager.importCurrentCodexAccount()
        manager.load()
        return manager.lastError == nil
    }

    private func evaluateStartupImport() -> StartupImportDecision {
        manager.load()
        let activeSlots = manager.slots.filter(\.isActive)
        let activeSlotIDs = Set(activeSlots.map(\.slotID))
        let currentProfiles = ((try? profileStore.load().profiles) ?? [])
            .filter { $0.isCurrentSystemAccount && activeSlotIDs.contains($0.slotID) }

        if activeSlots.isEmpty {
            do {
                return try manager.importer.currentCredentialFingerprint() == nil
                    ? StartupImportDecision(shouldImport: false, reason: "no_active_slots_no_auth_file")
                    : StartupImportDecision(shouldImport: true, reason: "no_active_slots")
            } catch {
                return StartupImportDecision(shouldImport: false, reason: "auth_fingerprint_unavailable")
            }
        }

        do {
            guard let currentFingerprint = try manager.importer.currentCredentialFingerprint() else {
                return currentProfiles.isEmpty
                    ? StartupImportDecision(shouldImport: false, reason: "active_slots_but_no_auth_file")
                    : StartupImportDecision(shouldImport: false, reason: "active_slots_using_cached_profile_metadata")
            }

            if currentProfiles.contains(where: { $0.credentialFingerprint == currentFingerprint }) {
                if UserDefaults.standard.integer(forKey: keychainSecurityACLVersionKey) < keychainSecurityACLVersion {
                    return StartupImportDecision(shouldImport: true, reason: "keychain_security_acl_refresh")
                }
                return StartupImportDecision(shouldImport: false, reason: "profile_fingerprint_matches_auth")
            }

            return StartupImportDecision(
                shouldImport: true,
                reason: currentProfiles.isEmpty ? "missing_profile_metadata" : "auth_fingerprint_changed"
            )
        } catch {
            NSLog("CodexQuotaBar startup import check failed: %@", error.localizedDescription)
            return StartupImportDecision(shouldImport: false, reason: "auth_fingerprint_check_failed")
        }
    }

    private func handleClaudeSafeStorageAccessAttempt() {
        if isPerformingInitialLaunchRefresh {
            didAccessClaudeSafeStorageDuringLaunch = true
        }
        NSLog(
            "CodexQuotaBar Claude Safe Storage access attempted duringLaunch=%@",
            String(isPerformingInitialLaunchRefresh)
        )
    }

    private func fetchClaudeOrganizations(allowsUserInteraction: Bool) async throws -> APIBalanceSnapshot {
        if claudeWebFetcher == nil {
            let fetcher = ClaudeWebFetcher()
            fetcher.onSafeStorageAccessAttempt = { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handleClaudeSafeStorageAccessAttempt()
                }
            }
            claudeWebFetcher = fetcher
        }
        guard let claudeWebFetcher else {
            throw ClaudeFetchError.webFetchFailed("Claude 同步器未初始化")
        }
        return try await claudeWebFetcher.fetchOrganizations(allowsUserInteraction: allowsUserInteraction)
    }

    private func startUnifiedPolling() {
        guard unifiedPollingTask == nil else { return }
        unifiedPollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let secondsUntilRefresh = max(0, self?.refreshCadence.nextRefreshAt.timeIntervalSinceNow ?? 0)
                if secondsUntilRefresh > 0 {
                    let sleepSeconds = min(secondsUntilRefresh, 1)
                    try? await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
                    continue
                }
                if Task.isCancelled { break }
                await self?.refreshEverything(quotaTrigger: .polling, apiTrigger: .polling)
            }
        }
    }

    private func refreshEverything(quotaTrigger: QuotaRefreshTrigger, apiTrigger: APIRefreshTrigger) async {
        guard !isRunningUnifiedRefresh else { return }
        isRunningUnifiedRefresh = true
        refreshCadence.markStarted()
        defer {
            isRunningUnifiedRefresh = false
            refreshCadence.markFinished()
        }
        async let quotaRefresh: Void = manager.refreshAll(trigger: quotaTrigger)
        async let apiRefresh: Void = apiKeyManager.refreshAll(trigger: apiTrigger)
        _ = await (quotaRefresh, apiRefresh)
    }

    private func migrateStoredProfiles() {
        do {
            _ = try profileStore.load()
        } catch {
            NSLog("CodexQuotaBar profile migration failed: \(error.localizedDescription)")
        }
    }
}

private struct MonitorHeaderIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.95))
            Image(systemName: "terminal.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.78))
        }
        .frame(width: 32, height: 32)
    }
}

private struct MonitorPanelView: View {
    @ObservedObject var manager: QuotaManager
    @ObservedObject var apiKeyManager: APIKeyManager
    @ObservedObject var refreshCadence: RefreshCadence
    @ObservedObject var memoryMonitor: MemoryMonitorController
    @ObservedObject var trafficLight: CodexTrafficLightController
    @ObservedObject var claudeActivity: ClaudeActivityController
    let refresh: () -> Void
    let importAccount: () -> Void
    let showAccounts: () -> Void
    let showAPIKeys: () -> Void
    let refreshAPIKeys: () -> Void
    let toggleDesktopWidget: () -> Void
    let openDataFolder: () -> Void
    let quit: () -> Void
    @State private var copiedProviderID: APIKeyProviderID?
    @State private var copyFeedbackToken = 0

    private var panelHeight: CGFloat {
        PanelMetrics.height(
            codexSlotCount: manager.slots.count,
            apiProviderCount: apiKeyManager.providers.count,
            hasError: manager.lastError != nil
        )
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            ZStack {
                Color(red: 0.03, green: 0.03, blue: 0.05)  // opaque base — was a behind-window blur that the ~0.97 gradient covered anyway (live backdrop blur = constant GPU cost)
                ZStack {
                    LinearGradient(
                        colors: [
                            Color(red: 0.05, green: 0.05, blue: 0.08).opacity(0.96),
                            Color(red: 0.02, green: 0.03, blue: 0.05).opacity(0.98)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    RadialGradient(
                        colors: [
                            Color(red: 0.03, green: 0.64, blue: 0.76).opacity(0.20),
                            .clear
                        ],
                        center: .topLeading,
                        startRadius: 24,
                        endRadius: 260
                    )
                    RadialGradient(
                        colors: [
                            Color(red: 0.87, green: 0.34, blue: 0.14).opacity(0.14),
                            .clear
                        ],
                        center: .topTrailing,
                        startRadius: 18,
                        endRadius: 220
                    )
                }

                VStack(spacing: 0) {
                    header

                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 8) {
                            if let lastError = manager.lastError {
                                MessageStrip(text: lastError, systemImage: "exclamationmark.triangle.fill")
                            }

                            SubscriptionCardStack(
                                manager: manager,
                                apiKeyManager: apiKeyManager,
                                refreshCadence: refreshCadence,
                                memoryMonitor: memoryMonitor,
                                trafficLight: trafficLight,
                                claudeActivity: claudeActivity,
                                importAccount: importAccount
                            )
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                    }
                    .frame(maxHeight: PanelMetrics.scrollHeight(for: panelHeight))

                    copyRow
                    actionBar
                }
            }
        }
        .frame(width: PanelMetrics.width, height: panelHeight)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.42), radius: 18, y: 10)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 10) {
            MonitorHeaderIcon()
                .scaleEffect(0.88)

            VStack(alignment: .leading, spacing: 2) {
                Text("订阅余额")
                    .font(.custom("Avenir Next Demi Bold", size: 15))
                    .tracking(0.2)
                    .foregroundStyle(.white)
                Text(statusSubtitle)
                    .font(.custom("Avenir Next Regular", size: 9.5))
                    .foregroundStyle(.white.opacity(0.48))
                BuildIdentityView(compact: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var statusSubtitle: String {
        if manager.isRefreshing || apiKeyManager.isRefreshing { return "正在刷新..." }
        if manager.slots.isEmpty { return "尚未导入账号" }
        return "5小时与周额度实时监控"
    }

    private var copyRow: some View {
        HStack(spacing: 8) {
            ForEach(apiKeyManager.providers) { provider in
                FloatingCopyButton(
                    title: provider.displayName,
                    color: Color(hex: provider.colorHex) ?? .white.opacity(0.6),
                    isCopied: copiedProviderID == provider.id,
                    isEnabled: apiKeyManager.canCopyPrimaryValue(providerID: provider.id),
                    action: { copyKey(provider.id) }
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private func copyKey(_ providerID: APIKeyProviderID) {
        let value = apiKeyManager.primaryCopyValue(providerID: providerID)
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        showCopiedFeedback(for: providerID)
    }

    private func showCopiedFeedback(for providerID: APIKeyProviderID) {
        copyFeedbackToken &+= 1
        let token = copyFeedbackToken
        copiedProviderID = nil
        DispatchQueue.main.async {
            copiedProviderID = providerID
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if copyFeedbackToken == token {
                copiedProviderID = nil
            }
        }
    }

    private var actionBarDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1, height: 22)
            .padding(.horizontal, 3)
    }

    private var actionBar: some View {
        HStack(spacing: 6) {
            IconButton(title: "刷新", systemImage: "arrow.clockwise", action: refresh)
                .disabled(manager.isRefreshing)
            IconButton(title: "桌面", systemImage: "rectangle.on.rectangle", action: toggleDesktopWidget)

            actionBarDivider

            IconButton(title: "设置", systemImage: "gearshape", action: showAPIKeys)

            Spacer(minLength: 0)

            Button(action: quit) {
                Image(systemName: "power")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.06), in: Circle())
            }
            .buttonStyle(.borderless)
            .help("退出")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(
            LinearGradient(
                colors: [Color.white.opacity(0.05), Color.black.opacity(0.16)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

private enum PanelMetrics {
    static let width: CGFloat = 344
    static let heightScale: CGFloat = 1.0
    static let minHeight: CGFloat = 320
    static let maxHeight: CGFloat = 760
    // header + copy row + action bar
    private static let chromeHeight: CGFloat = 140
    // Codex traffic-light strip (~34) + memory card (~120)
    private static let extrasHeight: CGFloat = 158

    static func rawHeight(codexSlotCount: Int, apiProviderCount: Int, hasError: Bool) -> CGFloat {
        let visibleCardCount = max(1, codexSlotCount) + apiProviderCount
        let cardsHeight = CGFloat(visibleCardCount) * 76
        let cardGaps = CGFloat(max(0, visibleCardCount - 1)) * 6
        let errorHeight: CGFloat = hasError ? 42 : 0
        let contentHeight = cardsHeight + cardGaps + errorHeight + extrasHeight + 22
        return chromeHeight + contentHeight
    }

    static func height(codexSlotCount: Int, apiProviderCount: Int, hasError: Bool) -> CGFloat {
        let scaled = rawHeight(
            codexSlotCount: codexSlotCount,
            apiProviderCount: apiProviderCount,
            hasError: hasError
        ) * heightScale
        return min(maxHeight, max(minHeight, scaled))
    }

    static func scrollHeight(for panelHeight: CGFloat) -> CGFloat {
        max(250, panelHeight - chromeHeight)
    }
}

private struct BuildIdentityView: View {
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 1 : 2) {
            Text(RuntimeDiagnostics.buildLine)
                .font(.custom("Avenir Next Medium", size: compact ? 8 : 8.5))
                .foregroundStyle(.white.opacity(0.44))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.top, compact ? 0 : 1)
    }
}

private struct SlotDashboardCard: View {
    let slot: AccountSlot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(slot.displayName)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(metaText)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.52))
                        .lineLimit(1)
                }
                Spacer()
                StatusPill(snapshot: slot.lastSnapshot)
            }

            if let snapshot = slot.lastSnapshot, snapshot.fetchHealth == .authError {
                MessageStrip(text: "Codex 登录已过期，请点“导入”重新读取当前 Codex 登录。", systemImage: "person.crop.circle.badge.exclamationmark")
            } else if let snapshot = slot.lastSnapshot, !snapshot.quotaWindows.isEmpty {
                ForEach(snapshot.quotaWindows) { window in
                    WindowMeter(window: window)
                }
                HStack {
                    if let credits = snapshot.extras["creditsBalance"] {
                        Label("余额 \(credits)", systemImage: "creditcard")
                    }
                    Spacer()
                    Label(QuotaFormatters.updatedText(snapshot.updatedAt).replacingOccurrences(of: "updated ", with: "更新 "), systemImage: "clock")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.52))
            } else {
                MessageStrip(text: "暂未获取到实时额度，请点击刷新或重新导入账号。", systemImage: "wifi.exclamationmark")
            }
        }
        .padding(11)
        .background(
            LinearGradient(
                colors: [Color.white.opacity(0.135), Color.white.opacity(0.055)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 13)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .stroke(Color.white.opacity(0.16), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.22), radius: 12, y: 5)
    }

    private var metaText: String {
        let plan = slot.lastSnapshot?.extras["planType"].map { "套餐 \($0)" }
        let source = slot.lastSnapshot?.sourceLabel
        return [plan, source].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct SlotCard: View {
    let slot: AccountSlot
    let isRefreshing: Bool
    let refresh: () -> Void
    let showAccounts: () -> Void

    private let accentColor = Color(red: 0.00, green: 0.82, blue: 0.95)

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            headerRow
            if let plan = planText {
                rowLine(title: "套餐", value: plan)
            }
            if let credits = slot.lastSnapshot?.extras["creditsBalance"] {
                rowLine(title: "余额", value: credits)
            }
            if let snapshot = slot.lastSnapshot, snapshot.fetchHealth == .authError {
                Text("登录已过期，请重新导入")
                    .font(.custom("Avenir Next Medium", size: 11))
                    .foregroundStyle(.orange.opacity(0.85))
            } else if let snapshot = slot.lastSnapshot, !snapshot.quotaWindows.isEmpty {
                ForEach(snapshot.quotaWindows) { window in
                    metricLine(
                        title: codexWindowMetricTitle(window),
                        value: codexWindowMetricValue(window),
                        meterLabel: QuotaFormatters.compactRemainingDurationText(window.resetAt),
                        percent: window.remainingPercent
                    )
                }
            } else {
                Text("暂无额度数据")
                    .font(.custom("Avenir Next Medium", size: 11))
                    .foregroundStyle(.white.opacity(0.38))
            }

        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.16, blue: 0.18).opacity(0.82),
                    Color(red: 0.02, green: 0.07, blue: 0.08).opacity(0.88)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    LinearGradient(
                        colors: [accentColor.opacity(0.30), .white.opacity(0.045)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: accentColor.opacity(0.08), radius: 4, y: 2)
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            Circle().fill(accentColor).frame(width: 6, height: 6)
            Text("Codex")
                .font(.custom("Avenir Next Demi Bold", size: 14))
                .foregroundStyle(.white.opacity(0.94))
                .lineLimit(1)
            StatusPill(snapshot: slot.lastSnapshot)
            Spacer(minLength: 0)
            Text(updatedText)
                .font(.custom("Avenir Next Medium", size: 8))
                .foregroundStyle(.white.opacity(0.30))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            FloatingRefreshButton(isRefreshing: isRefreshing, action: refresh)
            Button(action: showAccounts) {
                Image(systemName: "person.2")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.62))
                    .frame(width: 18, height: 16)
                    .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.06), lineWidth: 0.7))
            }
            .buttonStyle(.borderless)
            .help("账号")
        }
    }

    @ViewBuilder
    private func cardMetaLine(_ title: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.custom("Avenir Next Demi Bold", size: 9))
                .foregroundStyle(.white.opacity(0.34))
                .frame(width: 42, alignment: .leading)
            Text(value)
                .font(.custom("Avenir Next Medium", size: 9.5))
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(1)
                .minimumScaleFactor(0.76)
        }
    }

    @ViewBuilder
    private func rowLine(title: String, value: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            cardMetaLine(title, value: value)
                .frame(width: MainCardGrid.valueColumnWidth, alignment: .leading)
            Spacer(minLength: 0)
            Color.clear.frame(width: MainCardGrid.meterColumnWidth, height: 12)
        }
    }

    @ViewBuilder
    private func metricLine(title: String, value: String, meterLabel: String, percent: Int) -> some View {
        HStack(alignment: .center, spacing: 8) {
            cardMetaLine(title, value: value)
                .frame(width: MainCardGrid.valueColumnWidth, alignment: .leading)
            Spacer(minLength: 0)
            APIUsageMeter(label: meterLabel, remainingPercent: percent, color: accentColor)
                .frame(width: MainCardGrid.meterColumnWidth)
        }
    }

    private var planText: String? {
        slot.lastSnapshot?.extras["planType"].map(displayPlanName)
    }

    private var updatedText: String {
        guard let updatedAt = slot.lastSnapshot?.updatedAt else { return "未更新" }
        return QuotaFormatters.updatedText(updatedAt)
    }
}

private struct APIBalanceSection: View {
    @ObservedObject var codexManager: QuotaManager
    @ObservedObject var manager: APIKeyManager
    let slots: [AccountSlot]
    let openSettings: () -> Void
    let refresh: () -> Void
    let importAccount: () -> Void
    let showAccounts: () -> Void
    @State private var copiedProviderID: APIKeyProviderID?
    @State private var copyFeedbackToken = 0

    var body: some View {
        let subscriptionIDs: [APIKeyProviderID] = [.claude, .minimax]
        let creditIDs: [APIKeyProviderID] = [.deepseek, .comfly]
        let subscriptionProviders = manager.providers.filter { subscriptionIDs.contains($0.id) }
        let creditProviders = manager.providers.filter { creditIDs.contains($0.id) }
        return VStack(alignment: .leading, spacing: 6) {
            // Subscription group: Codex slots + Claude + MiniMax
            let hasSubscription = !slots.isEmpty || !subscriptionProviders.isEmpty
            if hasSubscription {
                VStack(spacing: 6) {
                    if slots.isEmpty {
                        EmptyMonitorCard(importAccount: importAccount)
                    }
                    ForEach(slots) { slot in
                        SlotCard(
                            slot: slot,
                            isRefreshing: codexManager.refreshingSlotIDs.contains(slot.slotID),
                            refresh: { Task { await codexManager.refreshSlot(slot.slotID) } },
                            showAccounts: showAccounts
                        )
                        .frame(minHeight: 70)
                    }
                    ForEach(subscriptionProviders) { provider in
                        APIBalanceCard(
                            provider: provider,
                            isCopied: copiedProviderID == provider.id,
                            isRefreshing: manager.refreshingProviderIDs.contains(provider.id),
                            canCopy: canCopyPrimaryKey(for: provider),
                            copy: { copyPrimaryKey(for: provider) },
                            refresh: { Task { await manager.refreshProvider(provider.id) } }
                        )
                        .frame(minHeight: provider.id == .claude ? 82 : 78)
                    }
                }
            }

            // Credits group
            if !creditProviders.isEmpty {
                VStack(spacing: 6) {
                    ForEach(creditProviders) { provider in
                        APIBalanceCard(
                            provider: provider,
                            isCopied: copiedProviderID == provider.id,
                            isRefreshing: manager.refreshingProviderIDs.contains(provider.id),
                            canCopy: canCopyPrimaryKey(for: provider),
                            copy: { copyPrimaryKey(for: provider) },
                            refresh: { Task { await manager.refreshProvider(provider.id) } }
                        )
                        .frame(minHeight: 64)
                    }
                }
            }
        }
    }

    private func groupLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.58))
                .frame(width: 20, height: 20)
                .background(
                    LinearGradient(
                        colors: [Color.white.opacity(0.10), Color.white.opacity(0.03)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 7)
                )
            Text(title)
                .font(.custom("Avenir Next Demi Bold", size: 11.5))
                .foregroundStyle(.white.opacity(0.60))
                .tracking(0.4)
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.14), .white.opacity(0.01)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)
        }
    }

    private func copyPrimaryKey(for provider: APIKeyProviderConfig) {
        let value = manager.primaryCopyValue(providerID: provider.id)
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        showCopiedFeedback(for: provider.id)
    }

    private func showCopiedFeedback(for providerID: APIKeyProviderID) {
        copyFeedbackToken &+= 1
        let token = copyFeedbackToken
        copiedProviderID = nil
        DispatchQueue.main.async {
            copiedProviderID = providerID
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if copyFeedbackToken == token {
                copiedProviderID = nil
            }
        }
    }

    private func canCopyPrimaryKey(for provider: APIKeyProviderConfig) -> Bool {
        manager.canCopyPrimaryValue(providerID: provider.id)
    }
}

private struct APIBalanceRow: View {
    let provider: APIKeyProviderConfig
    let isCopied: Bool
    let isRefreshing: Bool
    let copy: () -> Void
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Left accent strip
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 3)
                .padding(.vertical, 2)
                .padding(.trailing, 9)

            VStack(alignment: .leading, spacing: 5) {
                // Header row
                HStack(spacing: 6) {
                    Text(provider.displayName)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.90))
                    Text(balanceText)
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(provider.lastSnapshot?.status == .error ? .orange : .white.opacity(0.58))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Spacer(minLength: 4)
                    Button(action: refresh) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(isRefreshing ? 0.28 : 0.50))
                            .frame(width: 20, height: 18)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.borderless)
                    .disabled(isRefreshing)
                    .help("刷新 \(provider.displayName)")
                    Button(action: copy) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(isCopied ? 0.92 : 0.50))
                            .frame(width: 20, height: 18)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.borderless)
                    .help("复制 \(provider.displayName) API Key")
                }

                meterRows

                // Footer
                HStack {
                    Text(detailText)
                        .foregroundStyle(.white.opacity(0.38))
                    Spacer()
                    Text(updatedText)
                        .foregroundStyle(.white.opacity(0.28))
                }
                .font(.system(size: 9.5, weight: .medium))
                .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var meterRows: some View {
        if provider.id == .minimax {
            VStack(spacing: 4) {
                APIUsageMeter(label: "5小时", remainingPercent: minimaxIntervalUsedPercent, color: color, intent: .usage)
                APIUsageMeter(label: "每周", remainingPercent: minimaxWeeklyUsedPercent, color: color.opacity(0.88), intent: .usage)
            }
        } else if provider.id == .claude, provider.lastSnapshot?.extras["fiveHourUsed"] != nil {
            VStack(spacing: 4) {
                APIUsageMeter(label: "5小时", remainingPercent: claudeFiveHourRemaining, color: color)
                APIUsageMeter(label: "每周", remainingPercent: claudeSevenDayRemaining, color: color.opacity(0.88))
            }
        } else {
            APIUsageMeter(label: nil, remainingPercent: remainingPercent, color: color)
        }
    }

    private var color: Color {
        Color(hex: provider.colorHex) ?? .white.opacity(0.7)
    }

    private var balanceText: String {
        guard let snapshot = provider.lastSnapshot else { return "未配置" }
        if provider.id == .claude {
            if let fh = snapshot.extras["fiveHourUsed"], let sd = snapshot.extras["sevenDayUsed"] {
                let fhRemain = max(0, 100 - (Int(fh) ?? 0))
                let sdRemain = max(0, 100 - (Int(sd) ?? 0))
                return "5小时 \(fhRemain)% · 每周 \(sdRemain)%"
            }
            let status = snapshot.extras["billingStatus"] ?? "订阅中"
            return "\(snapshot.balance) · \(status)"
        }
        if provider.id == .minimax {
            return "Token Plan 共享额度"
        }
        if let balanceYuan = snapshot.extras["balanceYuan"] {
            return "\(snapshot.balance) · \(balanceYuan)"
        }
        if let unit = snapshot.unit {
            return "\(snapshot.balance) \(unit)"
        }
        return snapshot.balance
    }

    private var updatedText: String {
        guard let updatedAt = provider.lastSnapshot?.updatedAt else { return "尚未更新" }
        return QuotaFormatters.updatedText(updatedAt)
    }

    private var detailText: String {
        guard let snapshot = provider.lastSnapshot else { return "保存密钥后刷新余额" }
        if snapshot.status == .error {
            return "刷新失败，已保留上次余额"
        }
        switch provider.id {
        case .deepseek:
            let full = snapshot.extras["displayFullBalance"] ?? snapshot.total ?? "¥10.00"
            return "余额 \(snapshot.balance) / 满格 \(full)"
        case .minimax:
            return minimaxQuotaSummary(snapshot)
        case .comfly:
            if let balanceYuan = snapshot.extras["balanceYuan"] {
                return "约 \(balanceYuan) · 原始 quota \(snapshot.extras["quota"] ?? "--")"
            }
            return "已用 \(snapshot.used ?? "--") / \(snapshot.total ?? "--")"
        case .claude:
            if let fh = snapshot.extras["fiveHourUsed"], let sd = snapshot.extras["sevenDayUsed"] {
                return "5小时已用 \(fh)% · 每周已用 \(sd)%"
            }
            return snapshot.extras["billingPeriod"] ?? "按月续费"
        }
    }

    private var claudeFiveHourRemaining: Int {
        guard let snapshot = provider.lastSnapshot,
              let val = snapshot.extras["fiveHourUsed"],
              let used = Int(val) else { return 100 }
        return max(0, 100 - used)
    }

    private var claudeSevenDayRemaining: Int {
        guard let snapshot = provider.lastSnapshot,
              let val = snapshot.extras["sevenDayUsed"],
              let used = Int(val) else { return 100 }
        return max(0, 100 - used)
    }

    private var remainingPercent: Int {
        guard let snapshot = provider.lastSnapshot else { return 0 }
        switch provider.id {
        case .deepseek:
            return Int(snapshot.extras["remainingPercent"] ?? "") ?? max(0, 100 - snapshot.usedPercent)
        case .minimax:
            return minimaxIntervalUsedPercent
        case .comfly:
            return max(0, 100 - snapshot.usedPercent)
        case .claude:
            if let val = snapshot.extras["fiveHourUsed"], let used = Int(val) {
                return max(0, 100 - used)
            }
            return max(0, 100 - snapshot.usedPercent)
        }
    }

    private var minimaxIntervalUsedPercent: Int {
        guard let snapshot = provider.lastSnapshot else { return 0 }
        return minimaxUsedPercent(snapshot, usedKey: "intervalQuotaUsedPercent")
    }

    private var minimaxWeeklyUsedPercent: Int {
        guard let snapshot = provider.lastSnapshot else { return 0 }
        return minimaxUsedPercent(snapshot, usedKey: "weeklyQuotaUsedPercent")
    }
}

private struct APIBalanceCard: View {
    let provider: APIKeyProviderConfig
    let isCopied: Bool
    let isRefreshing: Bool
    let canCopy: Bool
    let copy: () -> Void
    let refresh: () -> Void

    private var color: Color { Color(hex: provider.colorHex) ?? .white.opacity(0.7) }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            headerRow
            if let package = packageText {
                rowLine(title: "套餐", value: package)
            }
            if let balanceLine = balanceLineText {
                rowLine(title: primaryMetricLabel, value: balanceLine)
            }

            if provider.id == .claude || provider.id == .minimax {
                alignedMetricRows
            } else {
                HStack(alignment: .center, spacing: 8) {
                    Text(detailText)
                        .font(.custom("Avenir Next Medium", size: 9.5))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(2)
                        .minimumScaleFactor(0.76)
                        .frame(width: MainCardGrid.valueColumnWidth, alignment: .leading)
                    Spacer(minLength: 0)
                    APIUsageMeter(label: nil, remainingPercent: remainingPercent, color: color)
                        .frame(width: MainCardGrid.meterColumnWidth)
                }
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: [
                    Color.black.opacity(0.22),
                    color.opacity(0.12),
                    color.opacity(0.05)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    LinearGradient(
                        colors: [color.opacity(0.22), .white.opacity(0.045)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.9
                )
        )
        .shadow(color: color.opacity(0.06), radius: 4, y: 2)
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(provider.displayName)
                .font(.custom("Avenir Next Demi Bold", size: 14))
                .foregroundStyle(.white.opacity(0.94))
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(updatedText)
                .font(.custom("Avenir Next Medium", size: 8))
                .foregroundStyle(.white.opacity(0.30))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            FloatingRefreshButton(isRefreshing: isRefreshing, action: refresh)
            Button(action: copy) {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.white.opacity(isCopied ? 0.92 : (canCopy ? 0.62 : 0.18)))
                    .frame(width: 18, height: 16)
                    .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.06), lineWidth: 0.7))
            }
            .buttonStyle(.borderless)
            .disabled(!canCopy)
            .help("复制 Key")
        }
    }

    @ViewBuilder
    private var alignedMetricRows: some View {
        if provider.id == .claude, provider.lastSnapshot?.setupState == .ready {
            metricLine(title: "5小时", value: claudeResetDisplay(provider.lastSnapshot?.extras["fiveHourResetsAt"]), meterLabel: claudeRemainingLabel(provider.lastSnapshot?.extras["fiveHourResetsAt"]), percent: claudeFiveHourRemaining)
            metricLine(title: "每周", value: claudeResetDisplay(provider.lastSnapshot?.extras["sevenDayResetsAt"]), meterLabel: claudeRemainingLabel(provider.lastSnapshot?.extras["sevenDayResetsAt"]), percent: claudeSevenDayRemaining)
            if let total = provider.lastSnapshot?.extras["routineTotal"], let totalNum = Int(total), totalNum > 0 {
                let used = Int(provider.lastSnapshot?.extras["routineUsed"] ?? "0") ?? 0
                metricLine(
                    title: "Routine",
                    value: "今日 \(used)/\(totalNum) 次",
                    meterLabel: "剩 \(max(0, totalNum - used))",
                    percent: claudeRoutineRemaining
                )
            }
        } else if provider.id == .minimax, provider.lastSnapshot != nil {
            metricLine(title: "5小时", value: minimaxIntervalTotalDisplay, meterLabel: "已用", percent: minimaxIntervalUsedPercent, intent: .usage)
            metricLine(title: "每周", value: minimaxWeeklyTotalDisplay, meterLabel: "已用", percent: minimaxWeeklyUsedPercent, intent: .usage)
        }
    }

    @ViewBuilder
    private func cardMetaLine(_ title: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.custom("Avenir Next Demi Bold", size: 9))
                .foregroundStyle(.white.opacity(0.34))
                .frame(width: 42, alignment: .leading)
            Text(value)
                .font(.custom("Avenir Next Medium", size: 9.5))
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(1)
                .minimumScaleFactor(0.76)
        }
    }

    @ViewBuilder
    private func rowLine(title: String, value: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            cardMetaLine(title, value: value)
                .frame(width: MainCardGrid.valueColumnWidth, alignment: .leading)
            Spacer(minLength: 0)
            Color.clear.frame(width: MainCardGrid.meterColumnWidth, height: 12)
        }
    }

    @ViewBuilder
    private func metricLine(title: String, value: String, meterLabel: String, percent: Int, intent: MeterIntent = .remaining) -> some View {
        HStack(alignment: .center, spacing: 8) {
            cardMetaLine(title, value: value)
                .frame(width: MainCardGrid.valueColumnWidth, alignment: .leading)
            Spacer(minLength: 0)
            APIUsageMeter(label: meterLabel, remainingPercent: percent, color: color, intent: intent)
                .frame(width: MainCardGrid.meterColumnWidth)
        }
    }

    private var packageText: String? {
        guard let snapshot = provider.lastSnapshot else { return nil }
        switch provider.id {
        case .claude:
            return snapshot.extras["planName"].map(displayPlanName)
        case .minimax:
            return snapshot.extras["planName"].map(displayPlanName)
        default:
            return nil
        }
    }

    private var balanceLineText: String? {
        guard let snapshot = provider.lastSnapshot else { return nil }
        if snapshot.setupState != .ready {
            return snapshot.note ?? snapshot.actionHint ?? snapshot.balance
        }
        switch provider.id {
        case .deepseek:
            return snapshot.balance
        case .minimax:
            return "Token Plan 共享额度"
        case .comfly:
            return snapshot.extras["balanceYuan"] ?? snapshot.balance
        case .claude:
            return snapshot.extras["billingStatus"] ?? snapshot.extras["billingPeriod"]
        }
    }

    private var primaryMetricLabel: String {
        switch provider.id {
        case .deepseek: return "余额"
        case .minimax: return "额度"
        case .comfly: return "余额"
        case .claude: return "状态"
        }
    }

    private var balanceText: String {
        guard let snapshot = provider.lastSnapshot else { return provider.id == .claude ? "等待同步" : "等待配置" }
        if snapshot.setupState != .ready {
            return snapshot.balance
        }
        if provider.id == .claude {
            if let fh = snapshot.extras["fiveHourUsed"], let sd = snapshot.extras["sevenDayUsed"] {
                return "5小时 \(max(0, 100-(Int(fh) ?? 0)))% · 每周 \(max(0, 100-(Int(sd) ?? 0)))%"
            }
            return "\(snapshot.balance) · \(snapshot.extras["billingStatus"] ?? "订阅中")"
        }
        if provider.id == .minimax {
            return "Token Plan 共享额度"
        }
        if let balanceYuan = snapshot.extras["balanceYuan"] { return "\(snapshot.balance) · \(balanceYuan)" }
        if let unit = snapshot.unit { return "\(snapshot.balance) \(unit)" }
        return snapshot.balance
    }

    private var detailText: String {
        guard let snapshot = provider.lastSnapshot else {
            return provider.id == .claude ? "从 Claude Desktop 自动读取登录态" : "请填写必填项后刷新余额"
        }
        if let actionHint = snapshot.actionHint, snapshot.setupState != .ready {
            return actionHint
        }
        if snapshot.status == .error, let note = snapshot.note {
            return note
        }
        switch provider.id {
        case .deepseek:
            return snapshot.extras["displayFullBalance"].map { "满格参考 \($0)" } ?? "余额 \(snapshot.balance)"
        case .minimax:
            return minimaxQuotaSummary(snapshot)
        case .comfly:
            return snapshot.extras["displayFullBalance"].map { "满格参考 \($0)" } ?? (snapshot.extras["balanceYuan"].map { "约 \($0)" } ?? "未配置")
        case .claude:
            if let fh = snapshot.extras["fiveHourUsed"], let sd = snapshot.extras["sevenDayUsed"] {
                if let total = snapshot.extras["routineTotal"] {
                    let used = snapshot.extras["routineUsed"] ?? "0"
                    return "5h已用 \(fh)% · 每周已用 \(sd)% · Routine \(used)/\(total)"
                }
                return "5h已用 \(fh)% · 每周已用 \(sd)%"
            }
            return snapshot.extras["billingPeriod"] ?? "按月续费"
        }
    }

    private var updatedText: String {
        guard let updatedAt = provider.lastSnapshot?.updatedAt else { return "未更新" }
        return QuotaFormatters.updatedText(updatedAt)
    }

    private var remainingPercent: Int {
        guard let snapshot = provider.lastSnapshot else { return 0 }
        switch provider.id {
        case .deepseek: return Int(snapshot.extras["remainingPercent"] ?? "") ?? max(0, 100 - snapshot.usedPercent)
        case .minimax: return minimaxIntervalRemaining
        case .comfly: return max(0, 100 - snapshot.usedPercent)
        case .claude:
            if let val = snapshot.extras["fiveHourUsed"], let u = Int(val) { return max(0, 100 - u) }
            return max(0, 100 - snapshot.usedPercent)
        }
    }

    private var claudeFiveHourRemaining: Int {
        guard let snapshot = provider.lastSnapshot, let val = snapshot.extras["fiveHourUsed"], let u = Int(val) else { return 100 }
        return max(0, 100 - u)
    }

    private var claudeSevenDayRemaining: Int {
        guard let snapshot = provider.lastSnapshot, let val = snapshot.extras["sevenDayUsed"], let u = Int(val) else { return 100 }
        return max(0, 100 - u)
    }

    private var claudeDesignRemaining: Int {
        guard let snapshot = provider.lastSnapshot, let val = snapshot.extras["designUsed"], let u = Int(val) else { return 100 }
        return max(0, 100 - u)
    }

    private var claudeRoutineRemaining: Int {
        guard let snapshot = provider.lastSnapshot,
              let total = Int(snapshot.extras["routineTotal"] ?? ""), total > 0 else { return 100 }
        let used = Int(snapshot.extras["routineUsed"] ?? "0") ?? 0
        return max(0, min(100, Int((Double(total - used) / Double(total) * 100).rounded())))
    }

    private func claudeResetDisplay(_ iso: String?, fallback: String? = nil) -> String {
        if let iso, let date = DateCoding.parseISO8601(iso) {
            return QuotaFormatters.absoluteResetText(date)
        }
        return fallback ?? "重置时间 --"
    }

    private func claudeRemainingLabel(_ iso: String?, fallback: String? = nil) -> String {
        if let iso, let date = DateCoding.parseISO8601(iso) {
            return QuotaFormatters.compactRemainingDurationText(date)
        }
        return fallback ?? "--"
    }

    private var minimaxIntervalRemaining: Int {
        guard let snapshot = provider.lastSnapshot else { return 0 }
        return Int(snapshot.extras["intervalRemainingPercent"] ?? "") ?? max(0, 100 - snapshot.usedPercent)
    }

    private var minimaxWeeklyRemaining: Int {
        guard let snapshot = provider.lastSnapshot else { return 0 }
        return Int(snapshot.extras["weeklyRemainingPercent"] ?? "") ?? max(0, 100 - snapshot.usedPercent)
    }

    private var minimaxIntervalTotalDisplay: String {
        guard let snapshot = provider.lastSnapshot else { return "--" }
        return minimaxTotalDisplay(snapshot, totalKey: "intervalQuotaTotalPercent")
    }

    private var minimaxWeeklyTotalDisplay: String {
        guard let snapshot = provider.lastSnapshot else { return "--" }
        return minimaxTotalDisplay(snapshot, totalKey: "weeklyQuotaTotalPercent")
    }

    private var minimaxIntervalUsedPercent: Int {
        guard let snapshot = provider.lastSnapshot else { return 0 }
        return minimaxUsedPercent(snapshot, usedKey: "intervalQuotaUsedPercent")
    }

    private var minimaxWeeklyUsedPercent: Int {
        guard let snapshot = provider.lastSnapshot else { return 0 }
        return minimaxUsedPercent(snapshot, usedKey: "weeklyQuotaUsedPercent")
    }
}

private enum MeterIntent {
    case remaining
    case usage
}

private struct APIUsageMeter: View {
    let label: String?
    let remainingPercent: Int
    let color: Color
    var intent: MeterIntent = .remaining

    private var barColor: Color { meterColor(remainingPercent, intent: intent) }
    private var clamped: CGFloat { CGFloat(max(0, min(100, remainingPercent))) }
    private let labelWidth: CGFloat = MainCardGrid.meterLabelWidth

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if let label {
                    Text(label)
                        .font(.custom("Avenir Next Demi Bold", size: 9.5))
                        .foregroundStyle(.white.opacity(0.54))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .frame(width: labelWidth, alignment: .leading)
                } else {
                    Color.clear
                        .frame(width: labelWidth, height: 1)
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.12), Color.white.opacity(0.04)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.white.opacity(0.05), lineWidth: 0.8)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(LinearGradient(
                            colors: [barColor.opacity(0.72), barColor, barColor.opacity(0.86)],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(width: proxy.size.width * clamped / 100)
                        .animation(.spring(response: 0.5, dampingFraction: 0.75), value: remainingPercent)
                }
            }
            .frame(height: 8)
            Text("\(remainingPercent)%")
                .font(.custom("Avenir Next Demi Bold", size: 9.5))
                .foregroundStyle(barColor)
                .monospacedDigit()
                .frame(width: MainCardGrid.percentColumnWidth, alignment: .trailing)
        }
    }
}

private struct PercentPill: View {
    let text: String
    let color: Color
    let isError: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(isError ? .orange : color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background((isError ? Color.orange : color).opacity(0.16), in: Capsule())
            .overlay(Capsule().stroke((isError ? Color.orange : color).opacity(0.22), lineWidth: 0.7))
    }
}

// Shared card stack used by BOTH the desktop floating widget and the menu-bar popover,
// so the two surfaces render visually identical cards.
// Thin Codex task-status strip (the menu-bar traffic light, surfaced inside the panel/widget).
private struct CodexTrafficLightStrip: View {
    @ObservedObject var trafficLight: CodexTrafficLightController

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color(nsColor: trafficLight.mode.color))
                .frame(width: 8, height: 8)
                .shadow(color: Color(nsColor: trafficLight.mode.color).opacity(0.6), radius: 3)
            Text("Codex 任务")
                .font(.custom("Avenir Next Demi Bold", size: 10.5))
                .foregroundStyle(.white.opacity(0.78))
            Text(trafficLight.mode.label)
                .font(.custom("Avenir Next Medium", size: 10))
                .foregroundStyle(.white.opacity(0.52))
            Spacer(minLength: 0)
            Text(trafficLight.detail)
                .font(.custom("Avenir Next Medium", size: 9))
                .foregroundStyle(.white.opacity(0.36))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.06), lineWidth: 0.8))
    }
}

// Memory card: sparkline of pressure history + used GB + breakdown, matching the dark card style.
private struct MemoryCardView: View {
    @ObservedObject var monitor: MemoryMonitorController

    private var levelColor: Color {
        guard let level = monitor.current?.pressureLevel else { return Color(red: 0.27, green: 0.78, blue: 0.34) }
        if level >= 4 { return Color(red: 0.93, green: 0.32, blue: 0.27) }
        if level >= 2 { return Color(red: 0.95, green: 0.78, blue: 0.22) }
        return Color(red: 0.27, green: 0.78, blue: 0.34)
    }

    var body: some View {
        let s = monitor.current
        let g: (Double) -> String = { String(format: "%.2f GB", $0 / 1_073_741_824) }
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Circle().fill(levelColor).frame(width: 7, height: 7)
                Text("内存")
                    .font(.custom("Avenir Next Demi Bold", size: 14))
                    .foregroundStyle(.white.opacity(0.94))
                Spacer(minLength: 0)
                Text(s.map { String(format: "%.1f / %.0f GB", $0.usedBytes / 1_073_741_824, $0.physicalBytes / 1_073_741_824) } ?? "--")
                    .font(.custom("Avenir Next Demi Bold", size: 13))
                    .foregroundStyle(.white.opacity(0.9))
                    .monospacedDigit()
            }

            MemorySparkline(points: monitor.historySamples)
                .frame(height: 40)

            if let s {
                HStack(alignment: .top, spacing: 14) {
                    memColumn([("已用", g(s.usedBytes)), ("App", g(s.appBytes)), ("联动", g(s.wiredBytes))])
                    memColumn([("已缓存", g(s.cachedBytes)), ("已压缩", g(s.compressedBytes)), ("Swap", g(s.swapUsedBytes))])
                }
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            LinearGradient(colors: [Color(red: 0.05, green: 0.18, blue: 0.20), Color(red: 0.03, green: 0.11, blue: 0.13)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(levelColor.opacity(0.24), lineWidth: 0.9))
    }

    private func memColumn(_ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows, id: \.0) { row in
                HStack(spacing: 6) {
                    Text(row.0)
                        .font(.custom("Avenir Next Medium", size: 9.5))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 38, alignment: .leading)
                    Text(row.1)
                        .font(.custom("Avenir Next Medium", size: 10))
                        .foregroundStyle(.white.opacity(0.82))
                        .monospacedDigit()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MemorySparkline: View {
    let points: [MemoryPoint]

    // No animation timer: the line re-renders only when `points` changes (~every sample),
    // points evenly spaced by index. Cheap; the line just steps forward each update.
    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            let n = points.count
            let maxV = max(points.map(\.ratio).max() ?? 0.05, 0.05)
            let pts = points.enumerated().map { i, point -> CGPoint in
                CGPoint(
                    x: n <= 1 ? 0 : w * CGFloat(i) / CGFloat(n - 1),
                    y: h - h * CGFloat(min(1, point.ratio / maxV)) * 0.9 - 2
                )
            }
            ZStack {
                if pts.count > 1 {
                    // Group consecutive same-level points into runs, each keeping its historical color.
                    ForEach(Array(colorRuns(for: points).enumerated()), id: \.offset) { _, run in
                        let c = Color(nsColor: memoryPressureColor(run.level))
                        if run.end > run.start {
                            Path { p in
                                p.move(to: CGPoint(x: pts[run.start].x, y: h))
                                for i in run.start...run.end { p.addLine(to: pts[i]) }
                                p.addLine(to: CGPoint(x: pts[run.end].x, y: h))
                                p.closeSubpath()
                            }
                            .fill(c.opacity(0.26))
                            Path { p in
                                p.move(to: pts[run.start])
                                for i in (run.start + 1)...run.end { p.addLine(to: pts[i]) }
                            }
                            .stroke(c.opacity(0.9), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
                        }
                    }
                }
            }
        }
    }

    /// Consecutive points sharing a pressure level become one run. Runs overlap by one point
    /// at boundaries so the line stays visually continuous.
    private func colorRuns(for points: [MemoryPoint]) -> [(start: Int, end: Int, level: Int32)] {
        guard points.count > 1 else { return [] }
        var runs: [(start: Int, end: Int, level: Int32)] = []
        var start = 0
        for i in 1..<points.count {
            if points[i].level != points[start].level {
                runs.append((start, i, points[start].level)) // include boundary point i
                start = i
            }
        }
        runs.append((start, points.count - 1, points[start].level))
        return runs
    }
}

private struct SubscriptionCardStack: View {
    @ObservedObject var manager: QuotaManager
    @ObservedObject var apiKeyManager: APIKeyManager
    @ObservedObject var refreshCadence: RefreshCadence
    @ObservedObject var memoryMonitor: MemoryMonitorController
    @ObservedObject var trafficLight: CodexTrafficLightController
    @ObservedObject var claudeActivity: ClaudeActivityController
    /// When provided and there are no Codex slots, shows the import-prompt card (popover only).
    var importAccount: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MemoryCardView(monitor: memoryMonitor)
            if manager.slots.isEmpty, let importAccount {
                EmptyMonitorCard(importAccount: importAccount)
            }
            ForEach(manager.slots) { slot in
                FloatingSlotCard(
                    slot: slot,
                    refreshCadence: refreshCadence,
                    isRefreshing: manager.refreshingSlotIDs.contains(slot.slotID),
                    taskColor: Color(nsColor: trafficLight.mode.color),
                    taskRunning: trafficLight.mode == .running,
                    taskLabel: trafficLight.mode.label,
                    refresh: { Task { await manager.refreshSlot(slot.slotID) } }
                )
                .frame(minHeight: 70)
            }
            FloatingProviderCard(
                title: "Claude",
                color: Color(hex: "#E05A2B") ?? .orange,
                subtitleLabel: "套餐",
                subtitle: claudeSubtitle,
                primaryLabel: "5小时", primaryValue: apiRemaining(.claude),
                primaryMeterLabel: floatingRemainingLabel(apiKeyManager.providers.first(where: { $0.id == .claude })?.lastSnapshot?.extras["fiveHourResetsAt"]),
                secondaryLabel: "每周", secondaryValue: claudeWeeklyRemaining,
                secondaryMeterLabel: floatingRemainingLabel(apiKeyManager.providers.first(where: { $0.id == .claude })?.lastSnapshot?.extras["sevenDayResetsAt"]),
                tertiaryLabel: claudeRoutine != nil ? "Routine" : nil, tertiaryValue: claudeRoutineRemaining,
                tertiaryMeterLabel: claudeRoutine != nil ? claudeRoutineMeterLabel : nil,
                resetLines: claudeResetLines,
                refreshCadence: refreshCadence,
                isRefreshing: apiKeyManager.refreshingProviderIDs.contains(.claude),
                refresh: { Task { await apiKeyManager.refreshProvider(.claude) } }
            )
            .frame(minHeight: 82)
            FloatingProviderCard(
                title: "MiniMax",
                color: Color(hex: "#7C3AED") ?? .purple,
                subtitleLabel: "额度",
                subtitle: minimaxSubtitle,
                primaryLabel: "5小时", primaryValue: minimaxIntervalUsedPercent,
                primaryMeterLabel: "已用",
                secondaryLabel: "每周", secondaryValue: minimaxWeeklyUsedPercent,
                secondaryMeterLabel: "已用",
                meterIntent: .usage,
                resetLines: minimaxResetLines,
                refreshCadence: refreshCadence,
                isRefreshing: apiKeyManager.refreshingProviderIDs.contains(.minimax),
                refresh: { Task { await apiKeyManager.refreshProvider(.minimax) } }
            )
            .frame(minHeight: 78)

            if let provider = apiProvider(.deepseek) {
                FloatingAPIBalanceCard(
                    provider: provider,
                    refreshCadence: refreshCadence,
                    isRefreshing: apiKeyManager.refreshingProviderIDs.contains(provider.id),
                    refresh: { Task { await apiKeyManager.refreshProvider(provider.id) } }
                )
            }
            if let provider = apiProvider(.comfly) {
                FloatingAPIBalanceCard(
                    provider: provider,
                    refreshCadence: refreshCadence,
                    isRefreshing: apiKeyManager.refreshingProviderIDs.contains(provider.id),
                    refresh: { Task { await apiKeyManager.refreshProvider(provider.id) } }
                )
            }
        }
    }

    private func apiRemaining(_ providerID: APIKeyProviderID) -> Int? {
        guard let provider = apiKeyManager.providers.first(where: { $0.id == providerID }),
              let snapshot = provider.lastSnapshot
        else { return nil }
        switch providerID {
        case .deepseek:
            return Int(snapshot.extras["remainingPercent"] ?? "") ?? max(0, 100 - snapshot.usedPercent)
        case .minimax:
            return Int(snapshot.extras["intervalRemainingPercent"] ?? "") ?? max(0, 100 - snapshot.usedPercent)
        case .comfly:
            return max(0, 100 - snapshot.usedPercent)
        case .claude:
            if let val = snapshot.extras["fiveHourUsed"], let used = Int(val) {
                return max(0, 100 - used)
            }
            return max(0, 100 - snapshot.usedPercent)
        }
    }

    private func apiWeeklyRemaining(_ providerID: APIKeyProviderID) -> Int? {
        guard let provider = apiKeyManager.providers.first(where: { $0.id == providerID }),
              let snapshot = provider.lastSnapshot
        else { return nil }
        return Int(snapshot.extras["weeklyRemainingPercent"] ?? "")
    }

    private func apiProvider(_ providerID: APIKeyProviderID) -> APIKeyProviderConfig? {
        apiKeyManager.providers.first(where: { $0.id == providerID })
    }

    private var claudeWeeklyRemaining: Int? {
        guard let snapshot = apiKeyManager.providers.first(where: { $0.id == .claude })?.lastSnapshot,
              let val = snapshot.extras["sevenDayUsed"], let used = Int(val)
        else { return nil }
        return max(0, 100 - used)
    }

    private var claudeRoutine: (used: Int, total: Int)? {
        guard let snapshot = apiKeyManager.providers.first(where: { $0.id == .claude })?.lastSnapshot,
              let total = Int(snapshot.extras["routineTotal"] ?? ""), total > 0
        else { return nil }
        return (Int(snapshot.extras["routineUsed"] ?? "0") ?? 0, total)
    }

    private var claudeRoutineRemaining: Int? {
        guard let r = claudeRoutine else { return nil }
        return max(0, min(100, Int((Double(r.total - r.used) / Double(r.total) * 100).rounded())))
    }

    private var claudeRoutineMeterLabel: String {
        guard let r = claudeRoutine else { return "--" }
        return "今日 \(r.used)/\(r.total) 次"
    }

    private var claudeSubtitle: String? {
        guard let snapshot = apiKeyManager.providers.first(where: { $0.id == .claude })?.lastSnapshot else {
            return "从 Claude Desktop 自动同步"
        }
        return snapshot.extras["planName"].map(displayPlanName) ?? snapshot.extras["billingStatus"]
    }

    private var claudeResetLines: [String] {
        guard let snapshot = apiKeyManager.providers.first(where: { $0.id == .claude })?.lastSnapshot else { return [] }
        var lines: [String] = []
        lines.append("5小时 \(floatingAbsoluteReset(snapshot.extras["fiveHourResetsAt"]))")
        lines.append("每周 \(floatingAbsoluteReset(snapshot.extras["sevenDayResetsAt"]))")
        if let r = claudeRoutine {
            lines.append("Routine 今日 \(r.used)/\(r.total) 次")
        }
        return lines
    }

    private var minimaxSubtitle: String? {
        guard let snapshot = apiKeyManager.providers.first(where: { $0.id == .minimax })?.lastSnapshot else {
            return "等待 MiniMax 数据"
        }
        if let planName = snapshot.extras["planName"]?.trimmingCharacters(in: .whitespacesAndNewlines), !planName.isEmpty {
            return displayPlanName(planName)
        }
        return "Token Plan 共享额度"
    }

    private var minimaxResetLines: [String] {
        guard let snapshot = apiKeyManager.providers.first(where: { $0.id == .minimax })?.lastSnapshot else { return [] }
        let intervalLine = "5小时 \(minimaxTotalDisplay(snapshot, totalKey: "intervalQuotaTotalPercent"))"
        let weeklyLine = "每周 \(minimaxTotalDisplay(snapshot, totalKey: "weeklyQuotaTotalPercent"))"
        return [intervalLine, weeklyLine]
    }

    private func floatingAbsoluteReset(_ iso: String?, fallback: String? = nil) -> String {
        if let iso, let date = DateCoding.parseISO8601(iso) {
            return QuotaFormatters.absoluteResetText(date)
        }
        return fallback ?? "重置时间 --"
    }

    private func floatingRemainingLabel(_ iso: String?, fallback: String? = nil) -> String {
        if let iso, let date = DateCoding.parseISO8601(iso) {
            return QuotaFormatters.compactRemainingDurationText(date)
        }
        return fallback ?? "--"
    }

    private var minimaxIntervalUsedPercent: Int {
        guard let snapshot = apiKeyManager.providers.first(where: { $0.id == .minimax })?.lastSnapshot else { return 0 }
        return minimaxUsedPercent(snapshot, usedKey: "intervalQuotaUsedPercent")
    }

    private var minimaxWeeklyUsedPercent: Int {
        guard let snapshot = apiKeyManager.providers.first(where: { $0.id == .minimax })?.lastSnapshot else { return 0 }
        return minimaxUsedPercent(snapshot, usedKey: "weeklyQuotaUsedPercent")
    }
}

private struct FloatingDesktopWidgetView: View {
    @ObservedObject var manager: QuotaManager
    @ObservedObject var apiKeyManager: APIKeyManager
    @ObservedObject var refreshCadence: RefreshCadence
    @ObservedObject var memoryMonitor: MemoryMonitorController
    @ObservedObject var trafficLight: CodexTrafficLightController
    @ObservedObject var claudeActivity: ClaudeActivityController
    var onPinChanged: () -> Void = {}
    @AppStorage("desktopWidgetPinned") private var isPinned = false
    @State private var copiedProviderID: APIKeyProviderID?
    @State private var copyFeedbackToken = 0

    var body: some View {
        // 10s tick is enough to refresh absolute reset labels; the countdown ring and the
        // memory/traffic-light cards update on their own (own ticker / @Published), so a
        // per-second full redraw of the whole card stack is wasteful.
        TimelineView(.periodic(from: .now, by: 10)) { _ in
            ZStack {
                Color(red: 0.03, green: 0.03, blue: 0.05)  // opaque base — was a behind-window blur that the ~0.97 gradient covered anyway (live backdrop blur = constant GPU cost)
                LinearGradient(
                    colors: [
                        Color(red: 0.05, green: 0.05, blue: 0.08).opacity(0.96),
                        Color(red: 0.02, green: 0.03, blue: 0.05).opacity(0.98)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                RadialGradient(
                    colors: [Color(red: 0.03, green: 0.64, blue: 0.76).opacity(0.20), .clear],
                    center: .topLeading,
                    startRadius: 24,
                    endRadius: 260
                )
                RadialGradient(
                    colors: [Color(red: 0.87, green: 0.34, blue: 0.14).opacity(0.14), .clear],
                    center: .topTrailing,
                    startRadius: 18,
                    endRadius: 220
                )

                VStack(alignment: .leading, spacing: 8) {
                    floatingHeader

                    ScrollView(.vertical, showsIndicators: false) {
                        SubscriptionCardStack(
                            manager: manager,
                            apiKeyManager: apiKeyManager,
                            refreshCadence: refreshCadence,
                            memoryMonitor: memoryMonitor,
                            trafficLight: trafficLight,
                            claudeActivity: claudeActivity
                        )
                    }

                    HStack(spacing: 8) {
                        ForEach(apiKeyManager.providers) { provider in
                            FloatingCopyButton(
                                title: provider.displayName,
                                color: Color(hex: provider.colorHex) ?? .white.opacity(0.6),
                                isCopied: copiedProviderID == provider.id,
                                isEnabled: apiKeyManager.canCopyPrimaryValue(providerID: provider.id),
                                action: { copyKey(provider.id) }
                            )
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: DesktopWidgetFrameStore.minimumSize.width, minHeight: DesktopWidgetFrameStore.minimumSize.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.10), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.42), radius: 18, y: 10)
        .preferredColorScheme(.dark)
    }

    private var floatingHeader: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(red: 0.00, green: 0.82, blue: 0.95))
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 1) {
                Text("订阅余额")
                    .font(.custom("Avenir Next Demi Bold", size: 12))
                    .tracking(0.15)
                    .foregroundStyle(.white.opacity(0.94))
                Text(floatingStatusSubtitle)
                    .font(.custom("Avenir Next Medium", size: 8.5))
                    .foregroundStyle(.white.opacity(0.46))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Text(RuntimeDiagnostics.buildLine)
                .font(.custom("Avenir Next Medium", size: 8))
                .foregroundStyle(.white.opacity(0.34))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 110, alignment: .trailing)

            Button {
                isPinned.toggle()
                onPinChanged()
            } label: {
                Image(systemName: isPinned ? "pin.fill" : "pin.slash")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isPinned ? Color(red: 0.19, green: 0.78, blue: 0.86) : .white.opacity(0.5))
                    .frame(width: 18, height: 16)
                    .background(Color.white.opacity(isPinned ? 0.12 : 0.055), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.06), lineWidth: 0.7))
            }
            .buttonStyle(.borderless)
            .help(isPinned ? "取消置顶" : "置顶")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    private var floatingStatusSubtitle: String {
        if manager.isRefreshing || apiKeyManager.isRefreshing { return "正在刷新..." }
        if manager.slots.isEmpty { return "尚未导入账号" }
        return "5小时与周额度实时监控"
    }

    private func floatingSection<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            content()
        }
        .padding(7)
        .background(
            LinearGradient(
                colors: [.white.opacity(0.045), .white.opacity(0.018)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 15)
        )
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.055), lineWidth: 0.8))
    }

    private func floatingGroupLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.56))
                .frame(width: 18, height: 18)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            Text(title)
                .font(.custom("Avenir Next Demi Bold", size: 11.5))
                .foregroundStyle(.white.opacity(0.56))
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.12), .white.opacity(0.01)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)
        }
    }

    private func copyKey(_ providerID: APIKeyProviderID) {
        let value = apiKeyManager.primaryCopyValue(providerID: providerID)
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        showCopiedFeedback(for: providerID)
    }

    private func showCopiedFeedback(for providerID: APIKeyProviderID) {
        copyFeedbackToken &+= 1
        let token = copyFeedbackToken
        copiedProviderID = nil
        DispatchQueue.main.async {
            copiedProviderID = providerID
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if copyFeedbackToken == token {
                copiedProviderID = nil
            }
        }
    }
}

/// Breathing opacity computed from a low-rate TimelineView (no repeatForever → no 60fps
/// Static status border — running just shows a brighter/thicker solid stroke (no animation,
/// no per-frame redraw). Cheap.
private struct BreathingBorder: View {
    let color: Color
    let running: Bool
    var cornerRadius: CGFloat = 12

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .stroke(color, lineWidth: running ? 1.5 : 1.0)
            .opacity(running ? 0.9 : 0.5)
    }
}

private struct BreathingDot: View {
    let color: Color
    let running: Bool

    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
    }
}

private struct FloatingSlotCard: View {
    let slot: AccountSlot
    @ObservedObject var refreshCadence: RefreshCadence
    let isRefreshing: Bool
    var taskColor: Color = Color(red: 0.00, green: 0.82, blue: 0.95)
    var taskRunning: Bool = false
    var taskLabel: String = ""
    let refresh: () -> Void
    private let accent = Color(red: 0.00, green: 0.82, blue: 0.95)

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            headerRow
            if let plan = planText {
                rowLine(title: "套餐", value: plan)
            }
            if let snap = slot.lastSnapshot, !snap.quotaWindows.isEmpty {
                ForEach(snap.quotaWindows) { window in
                    metricLine(
                        title: codexWindowMetricTitle(window),
                        value: codexWindowMetricValue(window),
                        meterLabel: QuotaFormatters.compactRemainingDurationText(window.resetAt),
                        percent: window.remainingPercent
                    )
                }
            } else {
                Text("暂无数据").font(.system(size: 9)).foregroundStyle(.white.opacity(0.32))
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.18, blue: 0.20),
                    Color(red: 0.03, green: 0.11, blue: 0.13)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(BreathingBorder(color: taskColor, running: taskRunning, cornerRadius: 12))
        .shadow(color: taskColor.opacity(0.14), radius: 4, y: 2)
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            BreathingDot(color: taskColor, running: taskRunning)
            Text("Codex")
                .font(.custom("Avenir Next Demi Bold", size: 14))
                .foregroundStyle(.white.opacity(0.94))
                .lineLimit(1)
            if !taskLabel.isEmpty {
                Text(taskLabel)
                    .font(.custom("Avenir Next Medium", size: 9))
                    .foregroundStyle(taskColor.opacity(0.9))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            FloatingRefreshProgress(cadence: refreshCadence, isRefreshing: isRefreshing, action: refresh)
        }
    }

    private var planText: String? {
        slot.lastSnapshot?.extras["planType"].map(displayPlanName)
    }
    private var updatedText: String {
        guard let d = slot.lastSnapshot?.updatedAt else { return "未更新" }
        return QuotaFormatters.updatedText(d)
    }

    private func floatingResetText(for window: QuotaWindow) -> String {
        let prefix = window.kind == .session ? "5小时" : "每周"
        return "\(prefix) \(QuotaFormatters.absoluteResetText(window.resetAt))"
    }

    private func shortFloatingResetText(for window: QuotaWindow) -> String {
        QuotaFormatters.absoluteResetText(window.resetAt)
    }

    @ViewBuilder
    private func rowLine(title: String, value: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.custom("Avenir Next Demi Bold", size: 9))
                .foregroundStyle(.white.opacity(0.34))
                .lineLimit(1)
                .frame(width: FloatingCardGrid.titleColumnWidth, alignment: .leading)
            Text(value)
                .font(.custom("Avenir Next Medium", size: 9.5))
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(1)
                .minimumScaleFactor(0.76)
                .frame(width: FloatingCardGrid.valueColumnWidth, alignment: .leading)
            Spacer(minLength: 0)
            Color.clear.frame(width: FloatingCardGrid.meterColumnWidth, height: 10)
        }
    }

    @ViewBuilder
    private func metricLine(title: String, value: String, meterLabel: String, percent: Int) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.custom("Avenir Next Demi Bold", size: 9))
                .foregroundStyle(.white.opacity(0.34))
                .lineLimit(1)
                .frame(width: FloatingCardGrid.titleColumnWidth, alignment: .leading)
            Text(value)
                .font(.custom("Avenir Next Medium", size: 9.5))
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(1)
                .minimumScaleFactor(0.76)
                .frame(width: FloatingCardGrid.valueColumnWidth, alignment: .leading)
            Spacer(minLength: 0)
            FloatingCompactBar(label: meterLabel, value: percent)
                .frame(width: FloatingCardGrid.meterColumnWidth)
        }
    }
}

private struct FloatingRefreshButton: View {
    let isRefreshing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(.white.opacity(isRefreshing ? 0.24 : 0.62))
                .frame(width: 18, height: 16)
                .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.06), lineWidth: 0.7))
        }
        .buttonStyle(.borderless)
        .disabled(isRefreshing)
        .help("刷新")
    }
}

private struct FloatingRefreshProgress: View {
    @ObservedObject var cadence: RefreshCadence
    let isRefreshing: Bool
    let action: () -> Void
    private let color = Color(red: 0.19, green: 0.78, blue: 0.86)

    // No per-second ticker: re-renders only when the parent refreshes (~10s) or `cadence`
    // publishes. The countdown text is coarse (≈10s granularity) — fine for a 120s interval —
    // and the ring is drawn statically (no animation).
    var body: some View {
        let state = progressState(now: Date())
        return HStack(spacing: 5) {
            Text(state.label)
                .font(.custom("Avenir Next Demi Bold", size: 7.5))
                .foregroundStyle(.white.opacity(isRefreshing || cadence.isRefreshing ? 0.52 : 0.34))
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: 34, alignment: .trailing)

            Button(action: action) {
                ZStack {
                    Circle().stroke(.white.opacity(0.09), lineWidth: 1.5)
                    Circle()
                        .trim(from: 0, to: state.progress)
                        .stroke(color.opacity(0.92), style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 15, height: 15)
            }
            .buttonStyle(.borderless)
            .disabled(isRefreshing)
            .help("刷新")
        }
        .frame(width: 55, height: 18)
        .help("下次自动刷新")
    }

    private func progressState(now: Date) -> (label: String, progress: CGFloat) {
        if isRefreshing || cadence.isRefreshing {
            return ("刷新中", 1)
        }

        let remaining = max(0, cadence.nextRefreshAt.timeIntervalSince(now))
        let progress = min(1, max(0, (cadence.intervalSeconds - remaining) / cadence.intervalSeconds))
        return (countdownText(remaining), CGFloat(progress))
    }

    private func countdownText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        if total >= 60 {
            return "\(total / 60)m\(String(format: "%02d", total % 60))s"
        }
        return "\(total)s"
    }
}

private struct FloatingProviderCard: View {
    let title: String
    let color: Color
    var subtitleLabel: String? = nil
    var subtitle: String? = nil
    let primaryLabel: String
    let primaryValue: Int?
    var primaryMeterLabel: String? = nil
    var secondaryLabel: String? = nil
    var secondaryValue: Int? = nil
    var secondaryMeterLabel: String? = nil
    var tertiaryLabel: String? = nil
    var tertiaryValue: Int? = nil
    var tertiaryMeterLabel: String? = nil
    var meterIntent: MeterIntent = .remaining
    var resetLines: [String] = []
    var statusColor: Color? = nil      // when set, header dot + border breathe with this color
    var statusRunning: Bool = false
    var statusLabel: String? = nil
    @ObservedObject var refreshCadence: RefreshCadence
    let isRefreshing: Bool
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            headerRow
            if let subtitle, let subtitleLabel {
                rowLine(title: subtitleLabel, value: subtitle)
            }
            metricLine(title: primaryLabel, value: resetValue(at: 0), meterLabel: primaryMeterLabel ?? primaryLabel, percent: primaryValue ?? 0)
            if let secLabel = secondaryLabel {
                metricLine(title: secLabel, value: resetValue(at: 1), meterLabel: secondaryMeterLabel ?? secLabel, percent: secondaryValue ?? 0)
            }
            if let thirdLabel = tertiaryLabel {
                metricLine(title: thirdLabel, value: resetValue(at: 2), meterLabel: tertiaryMeterLabel ?? thirdLabel, percent: tertiaryValue ?? 0)
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.24), color.opacity(0.14), color.opacity(0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(borderOverlay)
        .shadow(color: (statusColor ?? color).opacity(0.1), radius: 4, y: 2)
    }

    @ViewBuilder
    private var borderOverlay: some View {
        if let statusColor {
            BreathingBorder(color: statusColor, running: statusRunning, cornerRadius: 12)
        } else {
            RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.22), lineWidth: 0.9)
        }
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            if let statusColor {
                BreathingDot(color: statusColor, running: statusRunning)
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(title)
                .font(.custom("Avenir Next Demi Bold", size: 14))
                .foregroundStyle(.white.opacity(0.94))
                .lineLimit(1)
            if let statusLabel {
                Text(statusLabel)
                    .font(.custom("Avenir Next Medium", size: 9))
                    .foregroundStyle((statusColor ?? color).opacity(0.9))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            FloatingRefreshProgress(cadence: refreshCadence, isRefreshing: isRefreshing, action: refresh)
        }
    }

    private func resetValue(at index: Int) -> String {
        guard resetLines.indices.contains(index) else { return "--" }
        let line = resetLines[index]
        let prefix: String
        switch index {
        case 0: prefix = primaryLabel
        case 1: prefix = secondaryLabel ?? ""
        default: prefix = tertiaryLabel ?? ""
        }
        if line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return line
    }

    @ViewBuilder
    private func rowLine(title: String, value: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.custom("Avenir Next Demi Bold", size: 9))
                .foregroundStyle(.white.opacity(0.34))
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .frame(width: FloatingCardGrid.titleColumnWidth, alignment: .leading)
            Text(value)
                .font(.custom("Avenir Next Medium", size: 9.5))
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(1)
                .minimumScaleFactor(0.68)
                .frame(width: FloatingCardGrid.valueColumnWidth, alignment: .leading)
            Spacer(minLength: 0)
            Color.clear.frame(width: FloatingCardGrid.meterColumnWidth, height: 10)
        }
    }

    @ViewBuilder
    private func metricLine(title: String, value: String, meterLabel: String, percent: Int) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.custom("Avenir Next Demi Bold", size: 9))
                .foregroundStyle(.white.opacity(0.34))
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .frame(width: FloatingCardGrid.titleColumnWidth, alignment: .leading)
            Text(value)
                .font(.custom("Avenir Next Medium", size: 9.5))
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(1)
                .minimumScaleFactor(0.68)
                .frame(width: FloatingCardGrid.valueColumnWidth, alignment: .leading)
            Spacer(minLength: 0)
            FloatingCompactBar(label: meterLabel, value: percent, intent: meterIntent)
                .frame(width: FloatingCardGrid.meterColumnWidth)
        }
    }
}

private struct FloatingCompactBar: View {
    let label: String?
    let value: Int
    var intent: MeterIntent = .remaining
    private var barColor: Color { meterColor(value, intent: intent) }
    private let labelWidth: CGFloat = FloatingCardGrid.meterLabelWidth

    var body: some View {
        HStack(spacing: 6) {
            if let label {
                Text(label)
                    .font(.custom("Avenir Next Demi Bold", size: 9.5))
                    .foregroundStyle(.white.opacity(0.50))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .frame(width: labelWidth, alignment: .leading)
            } else {
                Color.clear.frame(width: labelWidth, height: 1)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4.5)
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0.11), .white.opacity(0.04)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(colors: [barColor.opacity(0.75), barColor], startPoint: .leading, endPoint: .trailing))
                        .frame(width: proxy.size.width * CGFloat(max(0, min(100, value))) / 100)
                        .animation(.spring(response: 0.5, dampingFraction: 0.75), value: value)
                }
            }
            .frame(height: 8)
            Text("\(value)%")
                .font(.custom("Avenir Next Demi Bold", size: 9.5))
                .foregroundStyle(barColor).monospacedDigit()
                .frame(width: FloatingCardGrid.percentColumnWidth, alignment: .trailing)
        }
    }
}

private struct FloatingAPIBalanceCard: View {
    let provider: APIKeyProviderConfig
    @ObservedObject var refreshCadence: RefreshCadence
    let isRefreshing: Bool
    let refresh: () -> Void

    private var color: Color { Color(hex: provider.colorHex) ?? .white.opacity(0.7) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(provider.displayName)
                    .font(.custom("Avenir Next Demi Bold", size: 14))
                    .foregroundStyle(.white.opacity(0.94))
                    .lineLimit(1)
                Spacer(minLength: 0)
                FloatingRefreshProgress(cadence: refreshCadence, isRefreshing: isRefreshing, action: refresh)
            }

            if let balanceLine = balanceLineText {
                rowLine(title: primaryMetricLabel, value: balanceLine)
            }

            HStack(alignment: .center, spacing: 8) {
                Text(detailText)
                    .font(.custom("Avenir Next Medium", size: 9.5))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .frame(width: FloatingCardGrid.valueColumnWidth, alignment: .leading)
                Spacer(minLength: 0)
                FloatingCompactBar(label: nil, value: meterPercent, intent: meterIntent)
                    .frame(width: FloatingCardGrid.meterColumnWidth)
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: [
                    Color.black.opacity(0.22),
                    color.opacity(0.12),
                    color.opacity(0.05)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.22), lineWidth: 0.9))
        .shadow(color: color.opacity(0.06), radius: 4, y: 2)
    }

    @ViewBuilder
    private func rowLine(title: String, value: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.custom("Avenir Next Demi Bold", size: 9))
                .foregroundStyle(.white.opacity(0.34))
                .frame(width: FloatingCardGrid.titleColumnWidth, alignment: .leading)
            Text(value)
                .font(.custom("Avenir Next Medium", size: 9.5))
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .frame(width: FloatingCardGrid.valueColumnWidth, alignment: .leading)
            Spacer(minLength: 0)
            Color.clear.frame(width: FloatingCardGrid.meterColumnWidth, height: 10)
        }
    }

    private var primaryMetricLabel: String {
        switch provider.id {
        case .deepseek, .comfly: return "余额"
        case .claude: return "状态"
        case .minimax: return "额度"
        }
    }

    private var balanceLineText: String? {
        guard let snapshot = provider.lastSnapshot else { return nil }
        switch provider.id {
        case .deepseek:
            return snapshot.balance
        case .comfly:
            return snapshot.extras["balanceYuan"] ?? snapshot.balance
        case .minimax:
            return "Token Plan 共享额度"
        case .claude:
            return snapshot.extras["billingStatus"] ?? snapshot.extras["billingPeriod"]
        }
    }

    private var detailText: String {
        guard let snapshot = provider.lastSnapshot else { return "等待配置" }
        switch provider.id {
        case .deepseek:
            return snapshot.extras["displayFullBalance"].map { "满格参考 \($0)" } ?? "余额 \(snapshot.balance)"
        case .comfly:
            return snapshot.extras["displayFullBalance"].map { "满格参考 \($0)" } ?? (snapshot.extras["balanceYuan"].map { "约 \($0)" } ?? "未配置")
        case .minimax:
            return minimaxQuotaSummary(snapshot)
        case .claude:
            return snapshot.extras["billingPeriod"] ?? "订阅中"
        }
    }

    private var remainingPercent: Int {
        guard let snapshot = provider.lastSnapshot else { return 0 }
        switch provider.id {
        case .deepseek:
            return Int(snapshot.extras["remainingPercent"] ?? "") ?? max(0, 100 - snapshot.usedPercent)
        case .comfly:
            return max(0, 100 - snapshot.usedPercent)
        case .minimax:
            return Int(snapshot.extras["intervalRemainingPercent"] ?? "") ?? max(0, 100 - snapshot.usedPercent)
        case .claude:
            return max(0, 100 - snapshot.usedPercent)
        }
    }

    private var meterPercent: Int {
        guard let snapshot = provider.lastSnapshot else { return 0 }
        if provider.id == .minimax {
            return minimaxUsedPercent(snapshot, usedKey: "intervalQuotaUsedPercent")
        }
        return remainingPercent
    }

    private var meterIntent: MeterIntent {
        provider.id == .minimax ? .usage : .remaining
    }

}

private enum MainCardGrid {
    static let valueColumnWidth: CGFloat = 116
    static let meterColumnWidth: CGFloat = 136
    static let meterLabelWidth: CGFloat = 28
    static let percentColumnWidth: CGFloat = 34
}

private enum FloatingCardGrid {
    static let titleColumnWidth: CGFloat = 36
    static let valueColumnWidth: CGFloat = 100
    static let meterColumnWidth: CGFloat = 124
    static let meterLabelWidth: CGFloat = 26
    static let percentColumnWidth: CGFloat = 32
}

private struct FloatingCopyButton: View {
    let title: String
    let color: Color
    let isCopied: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: isCopied ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isCopied ? color : color.opacity(isEnabled ? 0.82 : 0.24))
                Text(title)
                    .font(.custom("Avenir Next Demi Bold", size: 9.5))
                    .foregroundStyle(.white.opacity(isCopied ? 0.96 : (isEnabled ? 0.70 : 0.30)))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(
                isCopied ? color.opacity(0.16) : Color.white.opacity(isEnabled ? 0.08 : 0.04),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isCopied ? color.opacity(0.34) : .white.opacity(isEnabled ? 0.10 : 0.05), lineWidth: 0.8)
            )
        }
        .buttonStyle(.borderless)
        .disabled(!isEnabled)
        .help("复制 \(title) Key")
    }
}

private func quotaColor(_ value: Int?) -> Color {
    guard let value else { return .white.opacity(0.46) }
    if value <= 20 { return Color(red: 0.85, green: 0.28, blue: 0.28) }
    if value <= 50 { return Color(red: 0.90, green: 0.65, blue: 0.20) }
    return Color(red: 0.15, green: 0.85, blue: 0.45)
}

private func meterColor(_ value: Int?, intent: MeterIntent) -> Color {
    switch intent {
    case .remaining:
        return quotaColor(value)
    case .usage:
        guard let value else { return .white.opacity(0.46) }
        if value >= 90 { return Color(red: 0.85, green: 0.28, blue: 0.28) }
        if value >= 70 { return Color(red: 0.90, green: 0.65, blue: 0.20) }
        return Color(red: 0.15, green: 0.85, blue: 0.45)
    }
}

private func minimaxQuotaSummary(_ snapshot: APIBalanceSnapshot) -> String {
    if snapshot.extras["intervalQuotaTotalPercent"] != nil || snapshot.extras["weeklyQuotaTotalPercent"] != nil {
        let interval = minimaxUsageDisplay(snapshot, totalKey: "intervalQuotaTotalPercent", usedKey: "intervalQuotaUsedPercent")
        let weekly = minimaxUsageDisplay(snapshot, totalKey: "weeklyQuotaTotalPercent", usedKey: "weeklyQuotaUsedPercent")
        return "5小时 \(interval) · 每周 \(weekly)"
    }
    let intervalTotal = Int(snapshot.extras["intervalTotal"] ?? "") ?? 0
    let weeklyTotal = Int(snapshot.extras["weeklyTotal"] ?? "") ?? 0
    if intervalTotal > 0 || weeklyTotal > 0 {
        let interval = "\(snapshot.extras["intervalUsed"] ?? "--")/\(snapshot.extras["intervalTotal"] ?? "--")"
        let weekly = "\(snapshot.extras["weeklyUsed"] ?? "--")/\(snapshot.extras["weeklyTotal"] ?? "--")"
        return "5小时 \(interval) · 每周 \(weekly)"
    }
    let intervalRemaining = snapshot.extras["intervalRemainingPercent"] ?? "\(max(0, 100 - snapshot.usedPercent))"
    let weeklyRemaining = snapshot.extras["weeklyRemainingPercent"] ?? intervalRemaining
    return "5小时剩余 \(intervalRemaining)% · 每周剩余 \(weeklyRemaining)%"
}

private func minimaxTotalDisplay(_ snapshot: APIBalanceSnapshot, totalKey: String) -> String {
    guard let total = snapshot.extras[totalKey] else {
        return "--"
    }
    return "总额\(total)%"
}

private func minimaxUsedPercent(_ snapshot: APIBalanceSnapshot, usedKey: String) -> Int {
    Int(snapshot.extras[usedKey] ?? "") ?? snapshot.usedPercent
}

private func minimaxUsageDisplay(_ snapshot: APIBalanceSnapshot, totalKey: String, usedKey: String) -> String {
    guard let total = snapshot.extras[totalKey], let used = snapshot.extras[usedKey] else {
        return "--"
    }
    return "总额\(total)% · 已用\(used)%"
}

private func minimaxResetText(_ snapshot: APIBalanceSnapshot, key: String, fallbackKey: String) -> String {
    if let iso = snapshot.extras[key], let date = DateCoding.parseISO8601(iso) {
        return QuotaFormatters.absoluteResetText(date)
    }
    return snapshot.extras[fallbackKey].map { "\($0)后重置" } ?? "重置时间 --"
}

private func minimaxRemainingDurationLabel(_ snapshot: APIBalanceSnapshot, key: String, fallbackKey: String) -> String {
    if let iso = snapshot.extras[key], let date = DateCoding.parseISO8601(iso) {
        return QuotaFormatters.compactRemainingDurationText(date)
    }
    return snapshot.extras[fallbackKey] ?? "--"
}

private func displayPlanName(_ raw: String) -> String {
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "plus": return "Plus"
    case "pro": return "Pro"
    case "prolite": return "Pro Lite"
    case "team": return "Team"
    case "enterprise": return "Enterprise"
    case "scale": return "Scale"
    default:
        let sanitized = raw.replacingOccurrences(of: "_", with: " ")
        return sanitized.isEmpty ? raw : sanitized.capitalized
    }
}

private func codexWindowMetricTitle(_ window: QuotaWindow) -> String {
    if window.title.hasPrefix("Spark") {
        return "Spark"
    }

    switch window.kind {
    case .session: return "5小时"
    case .weekly: return "每周"
    case .credits: return "余额"
    case .unknown: return window.title
    }
}

private func codexWindowMetricValue(_ window: QuotaWindow) -> String {
    let resetText = QuotaFormatters.absoluteResetText(window.resetAt)
    switch window.title {
    case "Spark 5小时":
        return "5小时 \(resetText)"
    case "Spark 每周":
        return "每周 \(resetText)"
    default:
        return resetText
    }
}

private struct FloatingProgressBar: View {
    let value: Int?
    let color: Color
    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(.white.opacity(0.07))
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(LinearGradient(
                        colors: [color.opacity(0.75), color],
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .frame(width: proxy.size.width * CGFloat(clampedValue) / 100)
                    .animation(.spring(response: 0.5, dampingFraction: 0.75), value: clampedValue)
            }
        }
        .frame(height: height)
    }

    private var clampedValue: Int {
        max(0, min(100, value ?? 0))
    }
}

private struct WindowMeter: View {
    let window: QuotaWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(chineseTitle)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.84))
                Spacer()
                Text("\(window.remainingPercent)%")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.white.opacity(0.07))
                    RoundedRectangle(cornerRadius: 5)
                        .fill(LinearGradient(colors: [color.opacity(0.75), color], startPoint: .leading, endPoint: .trailing))
                        .frame(width: proxy.size.width * CGFloat(window.remainingPercent) / 100)
                        .animation(.spring(response: 0.5, dampingFraction: 0.75), value: window.remainingPercent)
                }
            }
            .frame(height: 10)

            HStack {
                Text("已用 \(window.usedPercent)%")
                Spacer()
                Text(QuotaFormatters.resetText(window.resetAt).replacingOccurrences(of: "reset ", with: "重置 "))
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.white.opacity(0.48))
        }
    }

    private var chineseTitle: String {
        switch window.kind {
        case .session: return "5 小时额度"
        case .weekly: return "周额度"
        case .credits: return "余额"
        case .unknown: return window.title
        }
    }

    private var color: Color {
        if window.remainingPercent < 20 { return .orange }
        if window.remainingPercent < 50 { return .yellow }
        return .green
    }
}

private struct StatusPill: View {
    let snapshot: QuotaSnapshot?

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var text: String {
        guard let snapshot else { return "等待中" }
        if snapshot.fetchHealth == .authError { return "需重新登录" }
        if snapshot.valueFreshness == .stale { return "过期" }
        switch snapshot.status {
        case .ok: return "正常"
        case .warning: return "偏低"
        case .exhausted: return "已用尽"
        case .error: return "异常"
        }
    }

    private var color: Color {
        guard let snapshot else { return .secondary }
        if snapshot.fetchHealth == .authError { return .red }
        if snapshot.valueFreshness == .stale { return .orange }
        switch snapshot.status {
        case .ok: return .green
        case .warning: return .orange
        case .exhausted, .error: return .red
        }
    }
}

private struct EmptyMonitorCard: View {
    let importAccount: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 36))
                .foregroundStyle(Color(red: 0.82, green: 0.65, blue: 0.42))
            Text("还没有 Codex 账号")
                .font(.custom("Avenir Next Demi Bold", size: 19))
                .foregroundStyle(.white)
            Text("导入当前 Codex 登录后即可显示实时额度。")
                .font(.custom("Avenir Next Regular", size: 12))
                .foregroundStyle(.white.opacity(0.62))
            Button("导入当前账号", action: importAccount)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(
            LinearGradient(
                colors: [Color(red: 0.16, green: 0.13, blue: 0.10), Color(red: 0.09, green: 0.08, blue: 0.07)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 18)
        )
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}

private struct MessageStrip: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.custom("Avenir Next Medium", size: 12))
            .foregroundStyle(.white.opacity(0.76))
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color(red: 0.36, green: 0.18, blue: 0.10).opacity(0.58), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.orange.opacity(0.28), lineWidth: 0.8))
    }
}

private struct IconButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(width: 18, height: 13)
                Text(title)
                    .font(.custom("Avenir Next Demi Bold", size: 9))
                    .foregroundStyle(.white.opacity(0.58))
            }
            .frame(width: 36, height: 30)
            .background(
                LinearGradient(
                    colors: [Color.white.opacity(0.08), Color.white.opacity(0.03)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.06), lineWidth: 0.8))
        }
        .buttonStyle(.borderless)
        .help(title)
    }
}

private struct APIKeySettingsView: View {
    @ObservedObject var manager: APIKeyManager
    @ObservedObject var quotaManager: QuotaManager
    var openDataFolder: () -> Void = {}
    var applyStatusBarVisibility: () -> Void = {}
    @AppStorage("showCodexTrafficLight") private var showTrafficLight = true
    @AppStorage("showMemoryIndicator") private var showMemory = true
    @State private var drafts: [String: String] = [:]
    @State private var copiedField: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 12) {
                    statusBarCard
                    CodexAccountEditor(manager: quotaManager)
                    ForEach(manager.providers) { provider in
                        APIKeyProviderEditor(
                            provider: provider,
                            values: bindingValues(for: provider),
                            copiedField: copiedField,
                            save: { save(provider) },
                            refresh: { Task { await manager.refreshAll() } },
                            copy: { field in copy(provider: provider, field: field) },
                            setEnabled: { manager.setProviderEnabled(provider.id, isEnabled: $0) }
                        )
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 620, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            reloadDrafts()
            quotaManager.load()
        }
    }

    private var statusBarCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "menubar.rectangle")
                    .foregroundStyle(.secondary)
                Text("状态栏显示")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
            }
            Toggle(isOn: Binding(get: { showTrafficLight }, set: { showTrafficLight = $0; applyStatusBarVisibility() })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex 状态灯").font(.system(size: 13))
                    Text("🟡执行中 · 🟢已完成 · 🔴异常,数据来自 ~/.codex 会话").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            Toggle(isOn: Binding(get: { showMemory }, set: { showMemory = $0; applyStatusBarVisibility() })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("系统内存").font(.system(size: 13))
                    Text("菜单栏显示内存折线胶囊 + 已用 GB").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 0.8))
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("设置")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                Text("Codex 与 Claude 自动读取本机登录态，其余密钥保存到 macOS Keychain。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: openDataFolder) {
                Label("数据文件夹", systemImage: "folder")
            }
            Button {
                Task { await manager.refreshAll(); await quotaManager.refreshAll() }
            } label: {
                Label("刷新余额", systemImage: "arrow.clockwise")
            }
            .disabled(manager.isRefreshing)
        }
        .padding(16)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func bindingValues(for provider: APIKeyProviderConfig) -> Binding<[String: String]> {
        Binding(
            get: {
                Dictionary(uniqueKeysWithValues: provider.fields.map { field in
                    ("\(provider.id.rawValue).\(field.key)", drafts["\(provider.id.rawValue).\(field.key)"] ?? "")
                })
            },
            set: { newValue in
                for (key, value) in newValue {
                    drafts[key] = value
                }
            }
        )
    }

    private func reloadDrafts() {
        drafts = Dictionary(uniqueKeysWithValues: manager.providers.flatMap { provider in
            provider.fields.map { field in
                ("\(provider.id.rawValue).\(field.key)", manager.fieldValue(providerID: provider.id, key: field.key))
            }
        })
    }

    private func save(_ provider: APIKeyProviderConfig) {
        let values = Dictionary(uniqueKeysWithValues: provider.fields.map { field in
            (field.key, drafts["\(provider.id.rawValue).\(field.key)"] ?? "")
        })
        manager.saveValues(providerID: provider.id, values: values)
        Task { await manager.refreshAll() }
    }

    private func copy(provider: APIKeyProviderConfig, field: APIKeyField) {
        let key = "\(provider.id.rawValue).\(field.key)"
        let value = drafts[key] ?? ""
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copiedField = key
    }
}

private struct CodexAccountEditor: View {
    @ObservedObject var manager: QuotaManager

    private let accent = Color(red: 0.00, green: 0.82, blue: 0.95)

    private var slot: AccountSlot? { manager.slots.first(where: { $0.isActive }) ?? manager.slots.first }
    private var snapshot: QuotaSnapshot? { slot?.lastSnapshot }
    private var sessionRemaining: Int {
        snapshot?.quotaWindows.first(where: { $0.kind == .session })?.remainingPercent ?? snapshot?.remaining ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle().fill(accent).frame(width: 10, height: 10)
                Text("Codex")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Spacer()
                if let slot {
                    Toggle("启用", isOn: Binding(
                        get: { slot.isActive },
                        set: { manager.setSlotActive(slot.slotID, isActive: $0) }
                    ))
                    .toggleStyle(.switch)
                    .font(.system(size: 12))
                }
            }

            HStack(alignment: .top, spacing: 14) {
                codexInfoBox
                    .frame(maxWidth: .infinity)
                codexBalanceBox
                    .frame(width: 224)
            }

            HStack {
                Button {
                    manager.importCurrentCodexAccount()
                    Task { await manager.refreshAll() }
                } label: {
                    Label("导入当前登录", systemImage: "person.crop.circle.badge.plus")
                }
                Button {
                    Task { await manager.refreshAll() }
                } label: {
                    Label("刷新余额", systemImage: "arrow.clockwise")
                }
                .disabled(manager.isRefreshing)
                Spacer()
                Text("Codex 令牌同步到钥匙串用于自动续期，不写入本地配置明文")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 0.8))
    }

    private var codexInfoBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("自动登录态来源", systemImage: "desktopcomputer")
                .font(.system(size: 12, weight: .semibold))
            Text("Codex 余额从本机 ~/.codex 登录态自动读取，令牌同步到钥匙串用于自动续期，无需手动填写。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Divider()
            if let slot {
                statusLine("当前账号", slot.displayName)
                statusLine("账号 ID", slot.accountID ?? slot.accountKey)
                if let updatedAt = snapshot?.updatedAt {
                    statusLine("更新时间", QuotaFormatters.updatedText(updatedAt).replacingOccurrences(of: "updated ", with: "更新 "))
                }
            } else {
                statusLine("当前状态", "尚未导入")
                statusLine("操作", "点击下方「导入当前登录」")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }

    private var codexBalanceBox: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("余额")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(snapshot?.extras["planType"].map(displayPlanName) ?? "等待同步")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("会话剩余 \(sessionRemaining)%")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            ProgressView(value: Double(sessionRemaining), total: 100)
                .tint(accent)
            if let snapshot, !snapshot.quotaWindows.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(snapshot.quotaWindows) { window in
                        codexStat(codexWindowLabel(window), "\(window.remainingPercent)%\(codexWindowResetSuffix(window))")
                    }
                    if let credits = snapshot.extras["creditsBalance"] {
                        codexStat("余额", credits)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }

    private func codexWindowLabel(_ window: QuotaWindow) -> String {
        if window.title.hasPrefix("Spark") { return window.title }
        switch window.kind {
        case .session: return "5小时"
        case .weekly: return "每周"
        default: return window.title
        }
    }

    private func codexWindowResetSuffix(_ window: QuotaWindow) -> String {
        guard let resetAt = window.resetAt else { return "" }
        let text = QuotaFormatters.compactRemainingDurationText(resetAt)
        return text.isEmpty ? "" : " · \(text)"
    }

    private func statusLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func codexStat(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }
}

private struct APIKeyProviderEditor: View {
    let provider: APIKeyProviderConfig
    @Binding var values: [String: String]
    let copiedField: String?
    let save: () -> Void
    let refresh: () -> Void
    let copy: (APIKeyField) -> Void
    let setEnabled: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle()
                    .fill(Color(hex: provider.colorHex) ?? .accentColor)
                    .frame(width: 10, height: 10)
                Text(provider.displayName)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Spacer()
                Toggle("启用", isOn: Binding(get: { provider.isEnabled }, set: { value in setEnabled(value) }))
                    .toggleStyle(.switch)
                    .font(.system(size: 12))
            }

            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 10) {
                    if provider.id == .claude {
                        claudeInfoBox
                    } else {
                        ForEach(provider.fields) { field in
                            fieldRow(field)
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                balanceBox
                    .frame(width: 224)
            }

            HStack {
                if provider.id == .claude {
                    Button(action: refresh) {
                        Label("同步登录态", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .help("立即从 Claude Desktop 重新读取登录态")
                } else {
                    Button(action: save) {
                        Label("保存", systemImage: "checkmark.circle")
                    }
                }
                Button(action: refresh) {
                    Label("刷新余额", systemImage: "arrow.clockwise")
                }
                Spacer()
                Text(provider.id == .claude ? "Claude 登录态不会写入本地配置文件" : "配置文件不会保存安全字段明文")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 0.8))
    }

    private func fieldRow(_ field: APIKeyField) -> some View {
        let key = "\(provider.id.rawValue).\(field.key)"
        return HStack(spacing: 8) {
            Text(field.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            if field.isSecure {
                SecureField(field.placeholder, text: Binding(
                    get: { values[key] ?? "" },
                    set: { values[key] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
            } else {
                TextField(field.placeholder, text: Binding(
                    get: { values[key] ?? "" },
                    set: { values[key] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
            }
            Button {
                copy(field)
            } label: {
                Image(systemName: copiedField == key ? "checkmark" : "doc.on.doc")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .help("复制 \(field.label)")
        }
    }

    private var claudeInfoBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("自动登录态来源", systemImage: "desktopcomputer")
                .font(.system(size: 12, weight: .semibold))
            Text("Claude 余额从 Claude Desktop 自动读取本机登录态，无需手动填写 Session Key。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Divider()
            statusLine("当前状态", claudeStatusLabel)
            statusLine("修复步骤", claudeActionHint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }

    private var balanceBox: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("余额")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(balanceText)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detailText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            ProgressView(value: Double(remainingPercent), total: 100)
                .tint(Color(hex: provider.colorHex) ?? .accentColor)
            if let snapshot = provider.lastSnapshot {
                APIProviderStatsView(providerID: provider.id, snapshot: snapshot)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }

    private var balanceText: String {
        guard let snapshot = provider.lastSnapshot else { return provider.id == .claude ? "等待同步" : "未配置" }
        if snapshot.setupState != .ready {
            return snapshot.balance
        }
        if provider.id == .minimax {
            return "Token Plan 共享额度"
        }
        if let balanceYuan = snapshot.extras["balanceYuan"] {
            return "\(snapshot.balance) / \(balanceYuan)"
        }
        if let unit = snapshot.unit {
            return "\(snapshot.balance) \(unit)"
        }
        return snapshot.balance
    }

    private var detailText: String {
        guard let snapshot = provider.lastSnapshot else {
            return provider.id == .claude ? "从 Claude Desktop 自动同步登录态后刷新余额" : "保存后刷新余额"
        }
        if let actionHint = snapshot.actionHint, snapshot.setupState != .ready {
            return actionHint
        }
        if snapshot.status == .error, let note = snapshot.note {
            return note
        }
        if provider.id == .minimax {
            return minimaxQuotaSummary(snapshot)
        }
        if let note = snapshot.note { return note }
        let total = snapshot.total.map { " / \($0)" } ?? ""
        return "已用 \(snapshot.usedPercent)%\(total)"
    }

    private var remainingPercent: Int {
        guard let snapshot = provider.lastSnapshot else { return 0 }
        switch provider.id {
        case .deepseek:
            return Int(snapshot.extras["remainingPercent"] ?? "") ?? max(0, 100 - snapshot.usedPercent)
        case .minimax:
            return Int(snapshot.extras["intervalRemainingPercent"] ?? "") ?? max(0, 100 - snapshot.usedPercent)
        case .comfly:
            return max(0, 100 - snapshot.usedPercent)
        case .claude:
            if let val = snapshot.extras["fiveHourUsed"], let used = Int(val) {
                return max(0, 100 - used)
            }
            return max(0, 100 - snapshot.usedPercent)
        }
    }

    private var claudeStatusLabel: String {
        guard let snapshot = provider.lastSnapshot else { return "等待首次同步" }
        return snapshot.note ?? snapshot.balance
    }

    private var claudeActionHint: String {
        provider.lastSnapshot?.actionHint ?? "安装并登录 Claude Desktop 后点击“刷新余额”"
    }

    private func statusLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct APIProviderStatsView: View {
    let providerID: APIKeyProviderID
    let snapshot: APIBalanceSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            switch providerID {
            case .deepseek:
                stat("满格参考", snapshot.extras["displayFullBalance"] ?? snapshot.total ?? "--")
                stat("赠送", snapshot.extras["grantedBalance"] ?? "--")
                stat("充值", snapshot.extras["toppedUpBalance"] ?? "--")
            case .minimax:
                stat("5小时用量", minimaxUsageDisplay(snapshot, totalKey: "intervalQuotaTotalPercent", usedKey: "intervalQuotaUsedPercent"))
                stat("5小时剩余", "\(snapshot.extras["intervalQuotaRemainingPercent"] ?? snapshot.extras["intervalRemainingPercent"] ?? "--")%")
                stat("5小时重置", minimaxResetText(snapshot, key: "intervalResetAt", fallbackKey: "intervalRemainsTime"))
                stat("每周用量", minimaxUsageDisplay(snapshot, totalKey: "weeklyQuotaTotalPercent", usedKey: "weeklyQuotaUsedPercent"))
                stat("每周剩余", "\(snapshot.extras["weeklyQuotaRemainingPercent"] ?? snapshot.extras["weeklyRemainingPercent"] ?? "--")%")
                stat("每周重置", minimaxResetText(snapshot, key: "weeklyResetAt", fallbackKey: "weeklyRemainsTime"))
            case .comfly:
                EmptyView()
            case .claude:
                if snapshot.setupState != .ready {
                    stat("状态", snapshot.note ?? snapshot.balance)
                    stat("修复", snapshot.actionHint ?? "--")
                } else {
                    stat("套餐", snapshot.extras["planName"] ?? snapshot.balance)
                    stat("状态", snapshot.extras["billingStatus"] ?? "--")
                    if let fh = snapshot.extras["fiveHourUsed"] {
                        let remain = max(0, 100 - (Int(fh) ?? 0))
                        let resetStr = snapshot.extras["fiveHourResetsAt"].flatMap { claudeResetLabel($0) } ?? ""
                        stat("5h剩余", "\(remain)%\(resetStr.isEmpty ? "" : " · \(resetStr)")")
                    }
                    if let sd = snapshot.extras["sevenDayUsed"] {
                        let remain = max(0, 100 - (Int(sd) ?? 0))
                        let resetStr = snapshot.extras["sevenDayResetsAt"].flatMap { claudeResetLabel($0) } ?? ""
                        stat("每周剩余", "\(remain)%\(resetStr.isEmpty ? "" : " · \(resetStr)")")
                    }
                    if let total = snapshot.extras["routineTotal"], let totalNum = Int(total), totalNum > 0 {
                        let used = Int(snapshot.extras["routineUsed"] ?? "0") ?? 0
                        stat("Routine", "今日 \(used)/\(totalNum) 次 · 剩 \(max(0, totalNum - used))")
                    }
                    stat("续费", snapshot.extras["billingPeriod"] ?? "--")
                }
            }
        }
        .padding(.top, 2)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .font(.system(size: 10.5, weight: .medium))
    }

    private func claudeResetLabel(_ iso: String) -> String? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return nil }
        let diff = date.timeIntervalSinceNow
        guard diff > 0 else { return "已重置" }
        let hours = Int(diff / 3600)
        let minutes = Int((diff.truncatingRemainder(dividingBy: 3600)) / 60)
        if hours > 0 {
            return "\(hours)h\(minutes)m后重置"
        }
        return "\(minutes)m后重置"
    }
}

private struct AccountsView: View {
    @ObservedObject var manager: QuotaManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Codex 账号")
                    .font(.title2.bold())
                Spacer()
                Button("导入") {
                    manager.importCurrentCodexAccount()
                    Task { await manager.refreshAll() }
                }
                Button("刷新") {
                    Task { await manager.refreshAll() }
                }
            }

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(manager.slots) { slot in
                        HStack(spacing: 12) {
                            Image(systemName: slot.isActive ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(slot.isActive ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(slot.displayName)
                                    .font(.headline)
                                Text(slot.accountID ?? slot.accountKey)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                if let updatedAt = slot.lastSnapshot?.updatedAt {
                                    Text(QuotaFormatters.updatedText(updatedAt).replacingOccurrences(of: "updated ", with: "更新 "))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(slot.lastSnapshot?.quotaWindows.first(where: { $0.kind == .session }).map { QuotaFormatters.percentText($0.remainingPercent) } ?? slot.lastSnapshot.map { QuotaFormatters.percentText($0.remaining) } ?? "--")
                                .font(.system(.title3, design: .monospaced).bold())
                        }
                        .padding(12)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }

            Text("账号档案保存在 Application Support，令牌也会同步到钥匙串用于刷新。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .onAppear { manager.load() }
    }
}

private extension Color {
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") {
            text.removeFirst()
        }
        guard text.count == 6, let value = Int(text, radix: 16) else {
            return nil
        }
        self.init(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }
}

// MARK: - Claude Usage Fetcher

private struct ClaudeCookieInfo: Sendable {
    var value: String
    var domain: String
    var path: String
    var isSecure: Bool
}

private final class ContinuationGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(throwing: error)
    }
}

private enum ClaudeSafeStorageSecurityError: Error, Sendable {
    case failedToStart
}

private final class ClaudeWebFetcher: NSObject, @unchecked Sendable {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<APIBalanceSnapshot, Error>?
    private var timeoutTimer: Timer?
    private var resultPollTimer: Timer?
    private var didStartDataScript = false
    private let balanceProvider = LLMBalanceProvider()
    private let fileManager = FileManager.default
    private let claudeCookieDBURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/Cookies")
    var onSafeStorageAccessAttempt: (@MainActor () -> Void)?

    func fetchOrganizations(allowsUserInteraction: Bool) async throws -> APIBalanceSnapshot {
        let claudeCookies = try await prepareAllClaudeCookies(allowsUserInteraction: allowsUserInteraction)

        if allowsUserInteraction {
            return try await fetchOrganizationsWithWebView(claudeCookies: claudeCookies)
        }

        do {
            return try await fetchOrganizationsWithHTTP(claudeCookies: claudeCookies)
        } catch {
            throw error
        }
    }

    private func fetchOrganizationsWithHTTP(claudeCookies: [String: ClaudeCookieInfo]) async throws -> APIBalanceSnapshot {
        let httpCookies = Self.httpCookies(from: claudeCookies)
        guard let cookieHeader = HTTPCookie.requestHeaderFields(with: httpCookies)["Cookie"], !cookieHeader.isEmpty else {
            throw ClaudeFetchError.notLoggedIn
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let userAgent = await Self.claudeDesktopUserAgent()
        let orgsJSON = try await fetchClaudeAPIJSON(
            path: "/api/organizations",
            session: session,
            userAgent: userAgent,
            cookieHeader: cookieHeader
        )
        let orgs = (orgsJSON as? [[String: Any]])
            ?? ((orgsJSON as? [String: Any])?["organizations"] as? [[String: Any]])
        guard let orgs else {
            throw ClaudeFetchError.unsupportedCookieSchema
        }

        var envelope: [String: Any] = ["organizations": orgs]
        if let orgID = orgs.first?["uuid"] as? String, !orgID.isEmpty {
            envelope["usage"] = try? await fetchClaudeAPIJSON(
                path: "/api/organizations/\(orgID)/usage",
                session: session,
                userAgent: userAgent,
                cookieHeader: cookieHeader
            )
            envelope["limits"] = try? await fetchClaudeAPIJSON(
                path: "/api/organizations/\(orgID)/rate_limit_status",
                session: session,
                userAgent: userAgent,
                cookieHeader: cookieHeader
            )
        }

        let data = try JSONSerialization.data(withJSONObject: envelope)
        return try balanceProvider.decodeBalance(data: data, providerID: .claude)
    }

    private func fetchClaudeAPIJSON(
        path: String,
        session: URLSession,
        userAgent: String,
        cookieHeader: String
    ) async throws -> Any {
        guard let url = URL(string: "https://claude.ai\(path)") else {
            throw ClaudeFetchError.webFetchFailed("Claude API URL 无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://claude.ai/settings/usage", forHTTPHeaderField: "Referer")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeFetchError.networkFailure
        }
        if httpResponse.statusCode == 401 {
            throw ClaudeFetchError.notLoggedIn
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ClaudeFetchError.webFetchFailed("Claude API 返回 HTTP \(httpResponse.statusCode)")
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func fetchOrganizationsWithWebView(claudeCookies: [String: ClaudeCookieInfo]) async throws -> APIBalanceSnapshot {
        let userAgent = await Self.claudeDesktopUserAgent()
        return try await withCheckedThrowingContinuation { [self] cont in
            DispatchQueue.main.async {
                self.continuation = cont
                self.didStartDataScript = false

                let config = WKWebViewConfiguration()
                config.websiteDataStore = .nonPersistent()

                let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                   styleMask: [], backing: .buffered, defer: false)
                win.isReleasedWhenClosed = false
                let wv = WKWebView(frame: win.contentView!.bounds, configuration: config)
                // Match Claude Desktop's Electron User-Agent so Cloudflare honors its cf_clearance cookie.
                wv.customUserAgent = userAgent
                wv.navigationDelegate = self
                win.contentView?.addSubview(wv)
                self.webView = wv

                // Inject ALL Claude Desktop cookies (incl. cf_clearance + httpOnly sessionKey) into the
                // WKWebView cookie store so both Cloudflare and claude.ai's client-side auth see a valid
                // session. Request-header injection alone fails: the SPA re-checks cookies client-side.
                let store = wv.configuration.websiteDataStore.httpCookieStore
                let httpCookies = Self.httpCookies(from: claudeCookies)

                let usageURL = URL(string: "https://claude.ai/settings/usage")!
                var didLoad = false
                let loadOnce: () -> Void = { [weak wv] in
                    guard !didLoad else { return }
                    didLoad = true
                    wv?.load(URLRequest(url: usageURL))
                }
                let group = DispatchGroup()
                for cookie in httpCookies {
                    group.enter()
                    store.setCookie(cookie) { group.leave() }
                }
                group.notify(queue: .main) { loadOnce() }
                // setCookie completion handlers are unreliable on macOS 26 — load anyway after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { loadOnce() }

                let timer = Timer(timeInterval: 90, repeats: false) { [weak self] _ in
                    DispatchQueue.main.async { self?.finish(.failure(ClaudeFetchError.timedOut)) }
                }
                RunLoop.main.add(timer, forMode: .common)
                self.timeoutTimer = timer
            }
        }
    }

    private static func httpCookies(from claudeCookies: [String: ClaudeCookieInfo]) -> [HTTPCookie] {
        let httpOnlyNames: Set<String> = ["sessionKey", "cf_clearance", "__cf_bm", "routingHint"]
        var httpCookies: [HTTPCookie] = []
        for (name, info) in claudeCookies {
            guard ClaudeCookieDomainFilter.isAllowedDomain(info.domain) else { continue }
            var props: [HTTPCookiePropertyKey: Any] = [
                .name: name, .value: info.value, .domain: info.domain, .path: info.path,
            ]
            if info.isSecure { props[.secure] = true }
            if httpOnlyNames.contains(name) { props[.init(rawValue: "HttpOnly")] = true }
            if let cookie = HTTPCookie(properties: props) { httpCookies.append(cookie) }
        }
        return httpCookies
    }

    private actor UserAgentCache {
        private var cached: String?

        func value(build: @Sendable @escaping () -> String) async -> String {
            if let cached { return cached }
            let userAgent = await Task.detached(priority: .utility) {
                build()
            }.value
            cached = userAgent
            return userAgent
        }
    }

    private static let userAgentCache = UserAgentCache()

    /// Build a User-Agent matching the installed Claude Desktop's Electron runtime. The expensive
    /// binary scan, when needed, runs in a child process and is cached so this menu-bar app never
    /// maps Claude's large Electron framework into its own address space.
    private static func claudeDesktopUserAgent() async -> String {
        await userAgentCache.value {
            buildClaudeDesktopUserAgent()
        }
    }

    private static func buildClaudeDesktopUserAgent() -> String {
        let fallbackChrome = "146.0.7680.216"
        let fallbackElectron = "41.6.1"
        let fm = FileManager.default
        let appPath = ["/Applications/Claude.app",
                       fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Claude.app").path]
            .first(where: { fm.fileExists(atPath: $0) })
        guard let appPath else {
            return formattedClaudeDesktopUserAgent(
                claudeVersion: "",
                chrome: fallbackChrome,
                electron: fallbackElectron
            )
        }

        let claudeVersion = (Bundle(path: appPath)?.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
        let electron = electronFrameworkVersion(appPath: appPath) ?? fallbackElectron
        let chrome = chromeVersionFromElectronBinary(appPath: appPath) ?? fallbackChrome
        return formattedClaudeDesktopUserAgent(
            claudeVersion: claudeVersion,
            chrome: chrome,
            electron: electron
        )
    }

    private static func formattedClaudeDesktopUserAgent(claudeVersion: String, chrome: String, electron: String) -> String {
        let claudePart = claudeVersion.isEmpty ? "" : "Claude/\(claudeVersion) "
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) \(claudePart)Chrome/\(chrome) Electron/\(electron) Safari/537.36"
    }

    private static func electronFrameworkVersion(appPath: String) -> String? {
        let frameworkPath = "\(appPath)/Contents/Frameworks/Electron Framework.framework"
        guard let version = Bundle(path: frameworkPath)?.infoDictionary?["CFBundleVersion"] as? String,
              !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return version.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func chromeVersionFromElectronBinary(appPath: String) -> String? {
        let binaryPath = "\(appPath)/Contents/Frameworks/Electron Framework.framework/Electron Framework"
        guard FileManager.default.fileExists(atPath: binaryPath) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "/usr/bin/strings \(shellQuoted(binaryPath)) | /usr/bin/grep -Eom 1 'Chrome/[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+'"
        ]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let output, output.hasPrefix("Chrome/") else { return nil }
        let version = String(output.dropFirst("Chrome/".count))
        return version.isEmpty ? nil : version
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func prepareAllClaudeCookies(allowsUserInteraction: Bool) async throws -> [String: ClaudeCookieInfo] {
        try ensureClaudeDesktopInstalled()
        guard fileManager.fileExists(atPath: claudeCookieDBURL.path) else {
            throw ClaudeFetchError.cookieDatabaseMissing
        }
        let password = try await loadClaudeSafeStoragePassword(allowsUserInteraction: allowsUserInteraction)
        let cookies = try extractAllClaudeCookiesSwift(password: password)
        return cookies
    }

    private func ensureClaudeDesktopInstalled() throws {
        let candidatePaths = [
            "/Applications/Claude.app",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Claude.app").path
        ]
        if candidatePaths.contains(where: { fileManager.fileExists(atPath: $0) }) || fileManager.fileExists(atPath: claudeCookieDBURL.path) {
            return
        }
        throw ClaudeFetchError.notInstalled
    }

    private func loadClaudeSafeStoragePassword(allowsUserInteraction: Bool) async throws -> String {
        if let cb = onSafeStorageAccessAttempt { await MainActor.run { cb() } }

        // Read the "Claude Safe Storage" password via the /usr/bin/security CLI rather than an
        // in-process SecItemCopyMatching. The keychain ACL is keyed by the *accessing* binary;
        // /usr/bin/security is already trusted for this item, so this returns without popping a
        // per-app authorization dialog and without blocking the app's main run loop.
        do {
            return try await loadClaudeSafeStoragePasswordWithSecurityCLI(timeout: 8)
        } catch ClaudeSafeStorageSecurityError.failedToStart {
            return try await loadClaudeSafeStoragePasswordInProcess(allowsUserInteraction: allowsUserInteraction)
        }
    }

    private func loadClaudeSafeStoragePasswordInProcess(allowsUserInteraction: Bool) async throws -> String {
        try await Task.detached(priority: .utility) {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: "Claude",
                kSecAttrService as String: "Claude Safe Storage",
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            if !allowsUserInteraction {
                let context = LAContext()
                context.interactionNotAllowed = true
                query[kSecUseAuthenticationContext as String] = context
            }

            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound {
                throw ClaudeFetchError.safeStorageMissing
            }
            if !allowsUserInteraction && (status == errSecInteractionNotAllowed || status == errSecAuthFailed) {
                throw KeychainError.userInteractionRequired
            }
            guard status == errSecSuccess, let data = result as? Data,
                  let password = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !password.isEmpty
            else {
                throw ClaudeFetchError.safeStorageMissing
            }
            return password
        }.value
    }

    private func loadClaudeSafeStoragePasswordWithSecurityCLI(timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let gate = ContinuationGate(cont)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = ["find-generic-password", "-a", "Claude", "-s", "Claude Safe Storage", "-w"]
            let outPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = Pipe()
            process.terminationHandler = { proc in
                let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let password = out.trimmingCharacters(in: .whitespacesAndNewlines)
                if proc.terminationStatus == 0, !password.isEmpty {
                    gate.resume(returning: password)
                } else {
                    gate.resume(throwing: ClaudeFetchError.safeStorageMissing)
                }
            }
            do {
                try process.run()
            } catch {
                gate.resume(throwing: ClaudeSafeStorageSecurityError.failedToStart)
                return
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    process.terminate()
                }
                gate.resume(throwing: KeychainError.timedOut)
            }
        }
    }

    // Pure Swift cookie decryption: PBKDF2-SHA1 + AES-CBC via CommonCrypto + SQLite3
    private func extractAllClaudeCookiesSwift(password: String) throws -> [String: ClaudeCookieInfo] {
        // Derive AES-128 key: PBKDF2-SHA1(password, "saltysalt", 1003 iterations)
        guard let pwData = password.data(using: .utf8) else { throw ClaudeFetchError.cookieDecryptFailed }
        let salt = Data("saltysalt".utf8)
        var derivedKey = Data(repeating: 0, count: 16)
        let pbkdfStatus = derivedKey.withUnsafeMutableBytes { keyPtr in
            pwData.withUnsafeBytes { pwPtr in
                salt.withUnsafeBytes { saltPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwPtr.baseAddress, pwData.count,
                        saltPtr.baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        keyPtr.baseAddress, 16
                    )
                }
            }
        }
        guard pbkdfStatus == kCCSuccess else { throw ClaudeFetchError.cookieDecryptFailed }
        let iv = Data(repeating: 0x20, count: 16)  // 16 space chars

        // Copy SQLite DB to temp path to avoid locking
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("claude_ck_\(ProcessInfo.processInfo.processIdentifier).db")
        defer { try? fileManager.removeItem(at: tmpURL) }
        try fileManager.copyItem(at: claudeCookieDBURL, to: tmpURL)

        var db: OpaquePointer?
        guard sqlite3_open_v2(tmpURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else { throw ClaudeFetchError.cookieDecryptFailed }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "SELECT name, encrypted_value, host_key, path, is_secure FROM cookies WHERE host_key LIKE '%claude.ai%'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ClaudeFetchError.cookieDecryptFailed
        }
        defer { sqlite3_finalize(stmt) }

        var cookies: [String: ClaudeCookieInfo] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let nameCStr = sqlite3_column_text(stmt, 0),
                  let hostCStr = sqlite3_column_text(stmt, 2)
            else { continue }
            let name = String(cString: nameCStr)
            let host = String(cString: hostCStr)
            guard ClaudeCookieDomainFilter.isAllowedDomain(host) else { continue }
            let pathStr = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "/"
            let isSecure = sqlite3_column_int(stmt, 4) != 0

            let encLen = Int(sqlite3_column_bytes(stmt, 1))
            guard encLen > 3,
                  let encPtr = sqlite3_column_blob(stmt, 1)
            else { continue }

            let encData = Data(bytes: encPtr, count: encLen)
            // Strip "v10" prefix (3 bytes), then AES-CBC decrypt
            let cipherData = encData.dropFirst(3)
            guard cipherData.count > 0 else { continue }

            var decryptedData = Data(repeating: 0, count: cipherData.count + kCCBlockSizeAES128)
            let decryptedCapacity = decryptedData.count
            var decryptedCount = 0
            let status = decryptedData.withUnsafeMutableBytes { decPtr in
                cipherData.withUnsafeBytes { cipPtr in
                    derivedKey.withUnsafeBytes { keyPtr in
                        iv.withUnsafeBytes { ivPtr in
                            CCCrypt(
                                CCOperation(kCCDecrypt),
                                CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyPtr.baseAddress, 16,
                                ivPtr.baseAddress,
                                cipPtr.baseAddress, cipherData.count,
                                decPtr.baseAddress, decryptedCapacity,
                                &decryptedCount
                            )
                        }
                    }
                }
            }
            guard status == kCCSuccess, decryptedCount > 32 else { continue }

            // Skip 32-byte random prefix, decode UTF-8
            let valueData = decryptedData.prefix(decryptedCount).dropFirst(32)
            guard let value = String(data: valueData, encoding: .utf8), !value.isEmpty else { continue }

            cookies[name] = ClaudeCookieInfo(value: value, domain: host, path: pathStr.isEmpty ? "/" : pathStr, isSecure: isSecure)
        }

        guard cookies["sessionKey"] != nil else {
            throw ClaudeFetchError.notLoggedIn
        }
        return cookies
    }

    @MainActor
    private func finish(_ result: Result<APIBalanceSnapshot, Error>) {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        resultPollTimer?.invalidate()
        resultPollTimer = nil
        didStartDataScript = false
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        continuation?.resume(with: result)
        continuation = nil
    }

}

extension ClaudeWebFetcher: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Guard against multiple didFinish (Cloudflare redirect chains etc.)
        guard !didStartDataScript else { return }
        didStartDataScript = true

        webView.evaluateJavaScript("""
            window.__claudeResult = null;
            (async () => {
                const sleep = (ms) => new Promise(resolve => setTimeout(resolve, ms));

                function parsePercent(text) {
                    const match = text && text.match(/(\\d+)\\s*%\\s*used/i);
                    return match ? parseInt(match[1], 10) : null;
                }

                function parseResetLine(text) {
                    const match = (text || '').match(/Resets[^\\n]*/i);
                    return match ? match[0].trim() : null;
                }

                function extractDesignFromText(text) {
                    if (!text || !/Claude Design/i.test(text)) return null;
                    const percent = parsePercent(text);
                    if (percent == null) return null;
                    const lines = text.split('\\n').map(s => s.trim()).filter(Boolean);
                    const noteLine = lines.find(line =>
                        line &&
                        !/Claude Design/i.test(line) &&
                        !/(\\d+)\\s*%\\s*used/i.test(line) &&
                        !/^Resets/i.test(line) &&
                        !/^Weekly limits/i.test(line) &&
                        !/^All models/i.test(line)
                    );
                    return {
                        utilization: percent,
                        description: noteLine || null,
                        reset_label: parseResetLine(text)
                    };
                }

                function parseClaudeDesignFromDocument() {
                    const candidates = Array.from(document.querySelectorAll('body *'))
                        .filter(el => /Claude Design/i.test(el.textContent || ''))
                        .slice(0, 12);

                    for (const el of candidates) {
                        const blocks = [
                            el.textContent || '',
                            el.parentElement?.textContent || '',
                            el.closest('section,article,div,li')?.textContent || ''
                        ];
                        for (const block of blocks) {
                            const parsed = extractDesignFromText(block);
                            if (parsed) return parsed;
                        }
                    }

                    const raw = document.body ? document.body.innerText : '';
                    if (!raw || !/Claude Design/i.test(raw)) return null;
                    const direct = extractDesignFromText(raw);
                    if (direct) return direct;

                    const blockMatch = raw.match(/Claude Design[\\s\\S]{0,400}?(\\d+)\\s*%\\s*used/i);
                    if (!blockMatch) return null;
                    const blockText = blockMatch[0];
                    return extractDesignFromText(blockText);
                }

                function parseRoutineRunsFromDocument() {
                    const raw = document.body ? document.body.innerText : '';
                    if (!raw) return null;
                    // "Daily included routine runs ... 0 / 5"
                    const m = raw.match(/routine runs[\\s\\S]{0,160}?(\\d+)\\s*\\/\\s*(\\d+)/i);
                    if (!m) return null;
                    return { used: parseInt(m[1], 10), total: parseInt(m[2], 10) };
                }

                let designFromPage = null;
                let routineFromPage = null;
                for (let i = 0; i < 30; i += 1) {
                    if (!designFromPage) designFromPage = parseClaudeDesignFromDocument();
                    if (!routineFromPage) routineFromPage = parseRoutineRunsFromDocument();
                    if (designFromPage || routineFromPage) break;
                    await sleep(500);
                }

                const orgsResp = await fetch('/api/organizations', {credentials: 'include'});
                if (!orgsResp.ok) throw new Error('HTTP ' + orgsResp.status);
                const orgs = await orgsResp.json();
                const orgId = orgs && orgs[0] && orgs[0].uuid;
                const usageUrl = orgId ? '/api/organizations/' + orgId + '/usage' : null;
                const limitsUrl = orgId ? '/api/organizations/' + orgId + '/rate_limit_status' : null;
                const usage = usageUrl ? await fetch(usageUrl, {credentials:'include'}).then(r => r.ok ? r.json() : null).catch(() => null) : null;
                const limits = limitsUrl ? await fetch(limitsUrl, {credentials:'include'}).then(r => r.ok ? r.json() : null).catch(() => null) : null;
                const result = {
                    status: 200,
                    body: JSON.stringify({
                        organizations: orgs,
                        usage: usage,
                        limits: limits,
                        designUsage: designFromPage,
                        routineUsage: routineFromPage,
                        pageDebug: {
                            title: document.title || null,
                            url: location.href,
                            hasClaudeDesignText: /Claude Design/i.test(document.body ? document.body.innerText : ''),
                            bodySnippet: (document.body ? document.body.innerText : '').slice(0, 4000)
                        }
                    })
                };
                window.__claudeResult = JSON.stringify(result);
            })().catch(e => { window.__claudeResult = 'ERROR:' + e.message; });
        """) { _, _ in }

        // Poll window.__claudeResult since message handlers are unreliable on macOS 26
        startResultPolling()
    }

    private func startResultPolling() {
        resultPollTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.webView?.evaluateJavaScript("window.__claudeResult") { value, _ in
                    guard let envelope = value as? String, !envelope.isEmpty else { return }
                    self.handleResultEnvelope(envelope)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        resultPollTimer = timer
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            finish(.failure(ClaudeFetchError.networkFailure))
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            finish(.failure(ClaudeFetchError.networkFailure))
        }
    }
}

extension ClaudeWebFetcher {
    @MainActor
    func handleResultEnvelope(_ envelope: String) {
        // Only act once
        guard continuation != nil else { return }
        persistClaudeDebugEnvelope(envelope)

        if envelope.hasPrefix("ERROR:") {
            if envelope.contains("HTTP 401") || envelope.contains("HTTP 403") {
                finish(.failure(ClaudeFetchError.notLoggedIn))
            } else {
                finish(.failure(ClaudeFetchError.webFetchFailed(String(envelope.dropFirst("ERROR:".count)))))
            }
            return
        }

        do {
            guard let envData = envelope.data(using: .utf8),
                  let envJSON = try? JSONSerialization.jsonObject(with: envData) as? [String: Any],
                  let status = envJSON["status"] as? Int,
                  let body = envJSON["body"] as? String else {
                guard let data = envelope.data(using: .utf8) else { throw ClaudeFetchError.unsupportedCookieSchema }
                let snapshot = try balanceProvider.decodeBalance(data: data, providerID: .claude)
                finish(.success(snapshot))
                return
            }
            guard status == 200 else {
                if status == 401 || status == 403 {
                    finish(.failure(ClaudeFetchError.notLoggedIn))
                } else {
                    finish(.failure(ClaudeFetchError.webFetchFailed("Claude 接口返回 HTTP \(status)")))
                }
                return
            }
            guard let data = body.data(using: .utf8) else { throw ClaudeFetchError.unsupportedCookieSchema }
            let snapshot = try balanceProvider.decodeBalance(data: data, providerID: .claude)
            finish(.success(snapshot))
        } catch {
            finish(.failure(error))
        }
    }

    private func persistClaudeDebugEnvelope(_ envelope: String) {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexQuotaBar", isDirectory: true)
        let fileURL = directory.appendingPathComponent("claude-debug.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try envelope.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            NSLog("[Claude] failed to persist debug envelope: %@", error.localizedDescription)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
