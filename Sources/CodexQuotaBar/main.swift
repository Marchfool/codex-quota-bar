import AppKit
import CodexQuotaCore
import Foundation
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var manager: QuotaManager!
    private var apiKeyManager: APIKeyManager!
    private var secretStore: KeychainSecretStore!
    private var profileStore: FileProfileStore!
    private var accountsWindow: NSWindow?
    private var apiKeysWindow: NSWindow?
    private var desktopWidgetWindow: NSPanel?
    private let popover = NSPopover()
    private let claudeWebFetcher = ClaudeWebFetcher()
    private var didPerformStartupImport = false
    private var startupImportReason = "not_evaluated"
    private var didAccessClaudeSafeStorageDuringLaunch = false
    private var isPerformingInitialLaunchRefresh = false

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
        claudeWebFetcher.onSafeStorageAccessAttempt = { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleClaudeSafeStorageAccessAttempt()
            }
        }
        apiKeyManager.claudeFetcher = { [claudeWebFetcher] in
            try await claudeWebFetcher.fetchOrganizations()
        }
        manager.load()
        apiKeyManager.load()
        migrateStoredProfiles()
        let startupImportDecision = evaluateStartupImport()
        startupImportReason = startupImportDecision.reason
        if startupImportDecision.shouldImport {
            didPerformStartupImport = true
            silentlyImportCurrentCodexAccount()
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

        popover.behavior = .transient
        popover.animates = true
        updatePopoverSize()
        let hostingController = NSHostingController(
            rootView: MonitorPanelView(
                manager: manager,
                apiKeyManager: apiKeyManager,
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

        Task {
            isPerformingInitialLaunchRefresh = true
            try? await Task.sleep(for: StartupRefreshPolicy.initialRefreshDelay)
            await manager.refreshAll(trigger: .launch)
            await apiKeyManager.refreshAll(trigger: .launch)
            isPerformingInitialLaunchRefresh = false
            NSLog(
                "CodexQuotaBar startup refresh completed claudeSafeStorageAccessed=%@",
                String(didAccessClaudeSafeStorageDuringLaunch)
            )
            WidgetCenter.shared.reloadAllTimelines()
            updatePopoverSize()
            configureStatusButton()
        }
        showDesktopWidget()
        manager.startPolling()
        apiKeyManager.startPolling()

        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
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
            updatePopoverSize()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.isOpaque = false
            popover.contentViewController?.view.window?.backgroundColor = .clear
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc private func refreshNow() {
        Task {
            await manager.refreshAll()
            await apiKeyManager.refreshAll()
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

    @objc private func showAPIKeys() {
        popover.performClose(nil)
        if apiKeysWindow == nil {
            let view = APIKeySettingsView(manager: apiKeyManager)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "API Key 与余额"
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
            window.orderOut(nil)
            UserDefaults.standard.set(false, forKey: "desktopWidgetVisible")
            return
        }

        showDesktopWidget()
    }

    private func showDesktopWidget() {
        if desktopWidgetWindow == nil {
            let cornerRadius: CGFloat = 28
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 540),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            panel.isMovableByWindowBackground = true
            let hostingView = NSHostingView(rootView: FloatingDesktopWidgetView(manager: manager, apiKeyManager: apiKeyManager))
            hostingView.wantsLayer = true
            hostingView.layer?.cornerRadius = cornerRadius
            hostingView.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            hostingView.layer?.masksToBounds = true
            hostingView.layer?.backgroundColor = NSColor.clear.cgColor
            panel.contentView = hostingView
            desktopWidgetWindow = panel
        }

        if let screenFrame = NSScreen.main?.visibleFrame {
            desktopWidgetWindow?.setFrameOrigin(NSPoint(x: screenFrame.maxX - 396, y: screenFrame.maxY - 570))
        }
        desktopWidgetWindow?.orderFrontRegardless()
        UserDefaults.standard.set(true, forKey: "desktopWidgetVisible")
    }

    @objc private func openLogs() {
        NSWorkspace.shared.open(FileSlotStore().fileURL.deletingLastPathComponent())
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func silentlyImportCurrentCodexAccount() {
        manager.importCurrentCodexAccount()
        manager.load()
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
    let refresh: () -> Void
    let importAccount: () -> Void
    let showAccounts: () -> Void
    let showAPIKeys: () -> Void
    let refreshAPIKeys: () -> Void
    let toggleDesktopWidget: () -> Void
    let openDataFolder: () -> Void
    let quit: () -> Void

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
                VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
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
                        VStack(spacing: 10) {
                            if let lastError = manager.lastError {
                                MessageStrip(text: lastError, systemImage: "exclamationmark.triangle.fill")
                            }

                            APIBalanceSection(
                                codexManager: manager,
                                manager: apiKeyManager,
                                slots: manager.slots,
                                openSettings: showAPIKeys,
                                refresh: refreshAPIKeys,
                                importAccount: importAccount,
                                showAccounts: showAccounts
                            )
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 10)
                    }
                    .frame(maxHeight: PanelMetrics.scrollHeight(for: panelHeight))

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

    private var actionBar: some View {
        HStack(spacing: 6) {
            IconButton(title: "刷新", systemImage: "arrow.clockwise", action: refresh)
                .disabled(manager.isRefreshing)
            IconButton(title: "导入", systemImage: "person.crop.circle.badge.plus", action: importAccount)
            IconButton(title: "账号", systemImage: "person.2", action: showAccounts)
            IconButton(title: "密钥", systemImage: "key", action: showAPIKeys)
            IconButton(title: "桌面", systemImage: "rectangle.on.rectangle", action: toggleDesktopWidget)
            IconButton(title: "数据", systemImage: "folder", action: openDataFolder)
            Spacer()
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
    static let width: CGFloat = 392
    static let heightScale: CGFloat = 1.0
    static let minHeight: CGFloat = 300
    static let maxHeight: CGFloat = 620
    private static let chromeHeight: CGFloat = 104

    static func rawHeight(codexSlotCount: Int, apiProviderCount: Int, hasError: Bool) -> CGFloat {
        let visibleCardCount = max(1, codexSlotCount) + apiProviderCount
        let cardsHeight = CGFloat(visibleCardCount) * 76
        let cardGaps = CGFloat(max(0, visibleCardCount - 1)) * 6
        let errorHeight: CGFloat = hasError ? 42 : 0
        let contentHeight = cardsHeight + cardGaps + errorHeight + 22
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
                        title: window.kind == .session ? "5小时" : "每周",
                        value: QuotaFormatters.absoluteResetText(window.resetAt),
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
        copiedProviderID = provider.id
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
                APIUsageMeter(label: "5小时", remainingPercent: minimaxIntervalRemaining, color: color)
                APIUsageMeter(label: "每周", remainingPercent: minimaxWeeklyRemaining, color: color.opacity(0.88))
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
        if let balanceYuan = snapshot.extras["balanceYuan"] {
            return "\(snapshot.balance) · \(balanceYuan)"
        }
        if let unit = snapshot.unit {
            return "\(snapshot.balance) \(unit)"
        }
        return snapshot.balance
    }

    private var statusText: String {
        guard provider.lastSnapshot != nil else { return "--" }
        return "\(remainingPercent)%"
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
            let weekly = "\(snapshot.extras["weeklyUsed"] ?? "--")/\(snapshot.extras["weeklyTotal"] ?? "--")"
            let interval = "\(snapshot.extras["intervalUsed"] ?? "--")/\(snapshot.extras["intervalTotal"] ?? "--")"
            return "5小时 \(interval) · 每周 \(weekly)"
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
            return minimaxIntervalRemaining
        case .comfly:
            return max(0, 100 - snapshot.usedPercent)
        case .claude:
            if let val = snapshot.extras["fiveHourUsed"], let used = Int(val) {
                return max(0, 100 - used)
            }
            return max(0, 100 - snapshot.usedPercent)
        }
    }

    private var minimaxIntervalRemaining: Int {
        guard let snapshot = provider.lastSnapshot else { return 0 }
        return Int(snapshot.extras["intervalRemainingPercent"] ?? "") ?? max(0, 100 - snapshot.usedPercent)
    }

    private var minimaxWeeklyRemaining: Int {
        guard let snapshot = provider.lastSnapshot else { return 0 }
        return Int(snapshot.extras["weeklyRemainingPercent"] ?? "") ?? max(0, 100 - snapshot.usedPercent)
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
            if provider.lastSnapshot?.extras["designUsed"] != nil {
                metricLine(
                    title: "Design",
                    value: claudeResetDisplay(provider.lastSnapshot?.extras["designResetsAt"], fallback: provider.lastSnapshot?.extras["designResetLabel"]),
                    meterLabel: claudeRemainingLabel(provider.lastSnapshot?.extras["designResetsAt"], fallback: provider.lastSnapshot?.extras["designResetLabel"]),
                    percent: claudeDesignRemaining
                )
            }
        } else if provider.id == .minimax, provider.lastSnapshot != nil {
            metricLine(title: "5小时", value: minimaxResetDisplay, meterLabel: minimaxRemainingLabel, percent: minimaxIntervalRemaining)
            metricLine(title: "每周", value: "接口未提供", meterLabel: "未提供", percent: minimaxWeeklyRemaining)
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
            APIUsageMeter(label: meterLabel, remainingPercent: percent, color: color)
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
            return snapshot.extras["modelName"] ?? snapshot.unit
        case .comfly:
            return snapshot.extras["balanceYuan"] ?? snapshot.balance
        case .claude:
            return snapshot.extras["billingStatus"] ?? snapshot.extras["billingPeriod"]
        }
    }

    private var primaryMetricLabel: String {
        switch provider.id {
        case .deepseek: return "余额"
        case .minimax: return "模型"
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
            return "5小时 \(snapshot.extras["intervalUsed"] ?? "--")/\(snapshot.extras["intervalTotal"] ?? "--") · 每周 \(snapshot.extras["weeklyUsed"] ?? "--")/\(snapshot.extras["weeklyTotal"] ?? "--")"
        case .comfly:
            return snapshot.extras["displayFullBalance"].map { "满格参考 \($0)" } ?? (snapshot.extras["balanceYuan"].map { "约 \($0)" } ?? "未配置")
        case .claude:
            if let fh = snapshot.extras["fiveHourUsed"], let sd = snapshot.extras["sevenDayUsed"] {
                if let design = snapshot.extras["designUsed"] {
                    return "5h已用 \(fh)% · 每周已用 \(sd)% · Design已用 \(design)%"
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

    private var minimaxResetDisplay: String {
        guard let snapshot = provider.lastSnapshot else { return "重置时间 --" }
        if let iso = snapshot.extras["intervalResetAt"], let date = DateCoding.parseISO8601(iso) {
            return QuotaFormatters.absoluteResetText(date)
        }
        return snapshot.extras["intervalRemainsTime"].map { "\($0)后重置" } ?? "重置时间 --"
    }

    private var minimaxRemainingLabel: String {
        guard let snapshot = provider.lastSnapshot else { return "--" }
        if let iso = snapshot.extras["intervalResetAt"], let date = DateCoding.parseISO8601(iso) {
            return QuotaFormatters.compactRemainingDurationText(date)
        }
        return snapshot.extras["intervalRemainsTime"] ?? "--"
    }
}

private struct APIUsageMeter: View {
    let label: String?
    let remainingPercent: Int
    let color: Color

    private var barColor: Color { quotaColor(remainingPercent) }
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

private struct FloatingDesktopWidgetView: View {
    @ObservedObject var manager: QuotaManager
    @ObservedObject var apiKeyManager: APIKeyManager
    @State private var copiedProviderID: APIKeyProviderID?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            ZStack {
                VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
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
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(manager.slots) { slot in
                                FloatingSlotCard(
                                    slot: slot,
                                    isRefreshing: manager.refreshingSlotIDs.contains(slot.slotID),
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
                                tertiaryLabel: "Design", tertiaryValue: claudeDesignRemaining,
                                tertiaryMeterLabel: floatingRemainingLabel(apiKeyManager.providers.first(where: { $0.id == .claude })?.lastSnapshot?.extras["designResetsAt"], fallback: apiKeyManager.providers.first(where: { $0.id == .claude })?.lastSnapshot?.extras["designResetLabel"]),
                                resetLines: claudeResetLines,
                                updatedText: providerUpdatedText(.claude),
                                isRefreshing: apiKeyManager.refreshingProviderIDs.contains(.claude),
                                refresh: { Task { await apiKeyManager.refreshProvider(.claude) } }
                            )
                            .frame(minHeight: 82)
                            FloatingProviderCard(
                                title: "MiniMax",
                                color: Color(hex: "#7C3AED") ?? .purple,
                                subtitleLabel: "模型",
                                subtitle: minimaxSubtitle,
                                primaryLabel: "5小时", primaryValue: apiRemaining(.minimax),
                                primaryMeterLabel: minimaxFloatingRemainingLabel,
                                secondaryLabel: "每周", secondaryValue: apiWeeklyRemaining(.minimax),
                                secondaryMeterLabel: "未提供",
                                resetLines: minimaxResetLines,
                                updatedText: providerUpdatedText(.minimax),
                                isRefreshing: apiKeyManager.refreshingProviderIDs.contains(.minimax),
                                refresh: { Task { await apiKeyManager.refreshProvider(.minimax) } }
                            )
                            .frame(minHeight: 78)

                            if let provider = apiProvider(.deepseek) {
                                FloatingAPIBalanceCard(
                                    provider: provider,
                                    isRefreshing: apiKeyManager.refreshingProviderIDs.contains(provider.id),
                                    refresh: { Task { await apiKeyManager.refreshProvider(provider.id) } }
                                )
                            }
                            if let provider = apiProvider(.comfly) {
                                FloatingAPIBalanceCard(
                                    provider: provider,
                                    isRefreshing: apiKeyManager.refreshingProviderIDs.contains(provider.id),
                                    refresh: { Task { await apiKeyManager.refreshProvider(provider.id) } }
                                )
                            }
                                }
                        .padding(.bottom, 0)
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
                .padding(.top, 8)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: 380, height: 540)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.10), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.42), radius: 18, y: 10)
        .preferredColorScheme(.dark)
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

    private func metric(_ kind: QuotaWindowKind) -> Int? {
        manager.slots.compactMap(\.lastSnapshot).flatMap(\.quotaWindows).first(where: { $0.kind == kind })?.remainingPercent
    }

    private var updatedText: String {
        guard let updatedAt = manager.slots.compactMap(\.lastSnapshot).first?.updatedAt else {
            return "尚未更新"
        }
        return QuotaFormatters.updatedText(updatedAt)
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

    private func providerUpdatedText(_ providerID: APIKeyProviderID) -> String? {
        guard let updatedAt = apiProvider(providerID)?.lastSnapshot?.updatedAt else { return nil }
        return QuotaFormatters.updatedText(updatedAt)
    }

    private var claudeWeeklyRemaining: Int? {
        guard let provider = apiKeyManager.providers.first(where: { $0.id == .claude }),
              let snapshot = provider.lastSnapshot,
              let val = snapshot.extras["sevenDayUsed"],
              let used = Int(val)
        else { return nil }
        return max(0, 100 - used)
    }

    private var claudeDesignRemaining: Int? {
        guard let provider = apiKeyManager.providers.first(where: { $0.id == .claude }),
              let snapshot = provider.lastSnapshot,
              let val = snapshot.extras["designUsed"],
              let used = Int(val)
        else { return nil }
        return max(0, 100 - used)
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
        if snapshot.extras["designUsed"] != nil {
            lines.append("Design \(floatingAbsoluteReset(snapshot.extras["designResetsAt"], fallback: snapshot.extras["designResetLabel"]))")
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
        if let modelName = snapshot.extras["modelName"] {
            return modelName
        }
        let weekly = "\(snapshot.extras["weeklyUsed"] ?? "--")/\(snapshot.extras["weeklyTotal"] ?? "--")"
        return "每周额度 \(weekly)"
    }

    private var minimaxResetLines: [String] {
        guard let snapshot = apiKeyManager.providers.first(where: { $0.id == .minimax })?.lastSnapshot else { return [] }
        let intervalLine: String
        if let iso = snapshot.extras["intervalResetAt"], let date = DateCoding.parseISO8601(iso) {
            intervalLine = "5小时 \(QuotaFormatters.absoluteResetText(date))"
        } else if let remains = snapshot.extras["intervalRemainsTime"] {
            intervalLine = "5小时 \(remains)后重置"
        } else {
            intervalLine = "5小时 重置时间 --"
        }
        return [intervalLine, "每周 重置时间接口未提供"]
    }

    private var deepseekSubtitle: String? {
        apiKeyManager.providers.first(where: { $0.id == .deepseek })?.lastSnapshot?.balance
    }

    private var comflySubtitle: String? {
        apiKeyManager.providers.first(where: { $0.id == .comfly })?.lastSnapshot?.extras["balanceYuan"]
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

    private var minimaxFloatingRemainingLabel: String {
        guard let snapshot = apiKeyManager.providers.first(where: { $0.id == .minimax })?.lastSnapshot else { return "--" }
        if let iso = snapshot.extras["intervalResetAt"], let date = DateCoding.parseISO8601(iso) {
            return QuotaFormatters.compactRemainingDurationText(date)
        }
        return snapshot.extras["intervalRemainsTime"] ?? "--"
    }

    private func copyKey(_ providerID: APIKeyProviderID) {
        let value = apiKeyManager.primaryCopyValue(providerID: providerID)
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copiedProviderID = providerID
    }
}

private struct FloatingSlotCard: View {
    let slot: AccountSlot
    let isRefreshing: Bool
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
                        title: window.kind == .session ? "5小时" : "每周",
                        value: shortFloatingResetText(for: window),
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
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(accent.opacity(0.24), lineWidth: 0.9))
        .shadow(color: accent.opacity(0.08), radius: 4, y: 2)
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            Circle().fill(accent).frame(width: 6, height: 6)
            Text("Codex")
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
    var resetLines: [String] = []
    var updatedText: String? = nil
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
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.22), lineWidth: 0.9))
        .shadow(color: color.opacity(0.08), radius: 4, y: 2)
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
                .font(.custom("Avenir Next Demi Bold", size: 14))
                .foregroundStyle(.white.opacity(0.94))
                .lineLimit(1)
            Spacer(minLength: 0)
            if let updatedText {
                Text(updatedText)
                    .font(.custom("Avenir Next Medium", size: 8))
                    .foregroundStyle(.white.opacity(0.30))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            FloatingRefreshButton(isRefreshing: isRefreshing, action: refresh)
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
            FloatingCompactBar(label: meterLabel, value: percent)
                .frame(width: FloatingCardGrid.meterColumnWidth)
        }
    }
}

private struct FloatingCompactBar: View {
    let label: String?
    let value: Int
    private var barColor: Color { quotaColor(value) }
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
                Text(updatedText)
                    .font(.custom("Avenir Next Medium", size: 8))
                    .foregroundStyle(.white.opacity(0.30))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                FloatingRefreshButton(isRefreshing: isRefreshing, action: refresh)
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
                FloatingCompactBar(label: nil, value: remainingPercent)
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
        case .minimax: return "模型"
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
            return snapshot.extras["modelName"] ?? snapshot.unit
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
            return snapshot.extras["modelName"] ?? snapshot.balance
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

    private var updatedText: String {
        guard let updatedAt = provider.lastSnapshot?.updatedAt else { return "未更新" }
        return QuotaFormatters.updatedText(updatedAt)
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
    static let valueColumnWidth: CGFloat = 92
    static let meterColumnWidth: CGFloat = 118
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

private struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
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
    @State private var drafts: [String: String] = [:]
    @State private var copiedField: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 12) {
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
        .onAppear(perform: reloadDrafts)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("API Key 与余额")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                Text("所有余额能力都会固定展示。Claude 从 Claude Desktop 自动读取登录态，其余密钥保存到 macOS Keychain。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await manager.refreshAll() }
            } label: {
                Label("刷新余额", systemImage: "arrow.clockwise")
            }
            .disabled(manager.isRefreshing)
        }
        .padding(16)
        .background(.thinMaterial)
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
                Toggle("启用", isOn: Binding(get: { provider.isEnabled }, set: setEnabled))
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
                if provider.id != .claude {
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
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
                stat("周已用", "\(snapshot.extras["weeklyUsed"] ?? "--") / \(snapshot.extras["weeklyTotal"] ?? "--")")
                stat("周剩余", snapshot.extras["weeklyRemains"] ?? snapshot.balance)
                stat("周期已用", "\(snapshot.extras["intervalUsed"] ?? "--") / \(snapshot.extras["intervalTotal"] ?? "--")")
                stat("周期剩余", "\(snapshot.extras["intervalRemains"] ?? "--") · \(snapshot.extras["intervalRemainsTime"] ?? "--")")
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
                    if let design = snapshot.extras["designUsed"] {
                        let remain = max(0, 100 - (Int(design) ?? 0))
                        let resetStr = snapshot.extras["designResetsAt"].flatMap { claudeResetLabel($0) }
                            ?? snapshot.extras["designResetLabel"]
                            ?? ""
                        let suffix = snapshot.extras["designNote"].map { " · \($0)" } ?? ""
                        stat("Design剩余", "\(remain)%\(resetStr.isEmpty ? "" : " · \(resetStr)")\(suffix)")
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

// MARK: - Claude WKWebView Fetcher

@MainActor
private final class ClaudeWebFetcher: NSObject {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<APIBalanceSnapshot, Error>?
    private var timeoutTimer: Timer?
    private let balanceProvider = LLMBalanceProvider()
    private let fileManager = FileManager.default
    private let pythonPath = "/usr/bin/python3"
    private let claudeCookieDBURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/Cookies")
    var onSafeStorageAccessAttempt: (@MainActor () -> Void)?

    func fetchOrganizations() async throws -> APIBalanceSnapshot {
        let sessionKey = try await prepareClaudeSessionKey()

        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont

            let config = WKWebViewConfiguration()
            let ucc = WKUserContentController()
            ucc.add(self, name: "claudeData")
            config.userContentController = ucc

            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                               styleMask: [], backing: .buffered, defer: false)
            win.isReleasedWhenClosed = false
            let wv = WKWebView(frame: win.contentView!.bounds, configuration: config)
            wv.navigationDelegate = self
            win.contentView?.addSubview(wv)
            self.webView = wv

            // Inject the sessionKey cookie before loading
            let props: [HTTPCookiePropertyKey: Any] = [
                .name: "sessionKey",
                .value: sessionKey,
                .domain: ".claude.ai",
                .path: "/",
                .secure: true,
            ]
            if let cookie = HTTPCookie(properties: props) {
                wv.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) {
                    wv.load(URLRequest(url: URL(string: "https://claude.ai/settings/usage")!))
                }
            } else {
                wv.load(URLRequest(url: URL(string: "https://claude.ai/settings/usage")!))
            }

            timeoutTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.finish(.failure(ClaudeFetchError.timedOut))
                }
            }
        }
    }

    private func prepareClaudeSessionKey() async throws -> String {
        try ensureClaudeDesktopInstalled()
        guard fileManager.fileExists(atPath: claudeCookieDBURL.path) else {
            throw ClaudeFetchError.cookieDatabaseMissing
        }
        let password = try await loadClaudeSafeStoragePassword()
        try await ensureCryptographyAvailable()
        return try await decryptClaudeDesktopSessionKey(password: password)
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

    private func loadClaudeSafeStoragePassword() async throws -> String {
        onSafeStorageAccessAttempt?()
        let result = try await runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/security"),
            arguments: ["find-generic-password", "-a", "Claude", "-s", "Claude Safe Storage", "-w"]
        )
        guard result.exitCode == 0 else {
            throw ClaudeFetchError.safeStorageMissing
        }
        let password = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !password.isEmpty else {
            throw ClaudeFetchError.safeStorageMissing
        }
        return password
    }

    private func ensureCryptographyAvailable() async throws {
        let result = try await runProcess(
            executableURL: URL(fileURLWithPath: pythonPath),
            arguments: ["-c", "import cryptography"]
        )
        guard result.exitCode == 0 else {
            if result.stderr.contains("No module named") && result.stderr.contains("cryptography") {
                throw ClaudeFetchError.cryptographyMissing
            }
            throw ClaudeFetchError.pythonUnavailable
        }
    }

    private func decryptClaudeDesktopSessionKey(password: String) async throws -> String {
        let script = """
import hashlib, sqlite3, shutil, os, sys
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.backends import default_backend

pw = sys.argv[1]
src = sys.argv[2]
key = hashlib.pbkdf2_hmac('sha1', pw.encode(), b'saltysalt', 1003, dklen=16)
iv = b' ' * 16

dst = f'/tmp/claude_ck_{os.getpid()}.db'
shutil.copy2(src, dst)
try:
    conn = sqlite3.connect(dst)
    row = conn.execute("SELECT hex(encrypted_value) FROM cookies WHERE name='sessionKey' AND host_key LIKE '%claude.ai%'").fetchone()
    conn.close()
finally:
    os.unlink(dst)

if not row or not row[0]:
    print("__NO_SESSION_KEY__", end='')
    sys.exit(0)

enc_bytes = bytes.fromhex(row[0])[3:]
dec = Cipher(algorithms.AES(key), modes.CBC(iv), backend=default_backend()).decryptor()
raw = dec.update(enc_bytes) + dec.finalize()
pad = raw[-1]
result = raw[:-pad]
print(result[32:].decode('utf-8'), end='')
"""
        let result = try await runProcess(
            executableURL: URL(fileURLWithPath: pythonPath),
            arguments: ["-c", script, password, claudeCookieDBURL.path]
        )
        if result.exitCode != 0 {
            throw ClaudeFetchError.cookieDecryptFailed
        }
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if output == "__NO_SESSION_KEY__" {
            throw ClaudeFetchError.notLoggedIn
        }
        guard !output.isEmpty else {
            throw ClaudeFetchError.unsupportedCookieSchema
        }
        return output
    }

    private func finish(_ result: Result<APIBalanceSnapshot, Error>) {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        continuation?.resume(with: result)
        continuation = nil
    }

    private func runProcess(executableURL: URL, arguments: [String]) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        return try await withCheckedThrowingContinuation { cont in
            do {
                try process.run()
            } catch {
                cont.resume(throwing: ClaudeFetchError.pythonUnavailable)
                return
            }
            process.terminationHandler = { proc in
                let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                cont.resume(returning: (proc.terminationStatus, out, err))
            }
        }
    }
}

extension ClaudeWebFetcher: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("""
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

                let designFromPage = null;
                for (let i = 0; i < 30; i += 1) {
                    designFromPage = parseClaudeDesignFromDocument();
                    if (designFromPage) break;
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
                        pageDebug: {
                            title: document.title || null,
                            url: location.href,
                            hasClaudeDesignText: /Claude Design/i.test(document.body ? document.body.innerText : ''),
                            bodySnippet: (document.body ? document.body.innerText : '').slice(0, 4000)
                        }
                    })
                };
                window.webkit.messageHandlers.claudeData.postMessage(JSON.stringify(result));
            })().catch(e => window.webkit.messageHandlers.claudeData.postMessage('ERROR:' + e.message));
        """) { _, err in
            if let err { _ = err }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(ClaudeFetchError.networkFailure))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(ClaudeFetchError.networkFailure))
    }
}

extension ClaudeWebFetcher: WKScriptMessageHandler {
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let envelope = message.body as? String else {
            finish(.failure(ClaudeFetchError.unsupportedCookieSchema))
            return
        }
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
