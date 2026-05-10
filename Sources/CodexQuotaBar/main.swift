import AppKit
import CodexQuotaCore
import SwiftUI
import WidgetKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var manager: QuotaManager!
    private var apiKeyManager: APIKeyManager!
    private var accountsWindow: NSWindow?
    private var apiKeysWindow: NSWindow?
    private var desktopWidgetWindow: NSPanel?
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let secretStore = KeychainSecretStore()
        manager = QuotaManager(
            store: FileSlotStore(),
            provider: OfficialCodexProvider(secretStore: secretStore),
            importer: CodexAuthImporter(secretStore: secretStore, profileStore: FileProfileStore())
        )
        apiKeyManager = APIKeyManager(store: FileAPIKeyConfigStore(), secretStore: secretStore)
        manager.load()
        apiKeyManager.load()
        silentlyImportCurrentCodexAccount()

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
            await manager.refreshAll()
            await apiKeyManager.refreshAll()
            WidgetCenter.shared.reloadAllTimelines()
            updatePopoverSize()
            configureStatusButton()
        }
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
                hasError: manager.lastError != nil || apiKeyManager.lastError != nil
            )
        )
    }

    private func configureStatusButton() {
        guard let button = statusItem?.button else { return }
        button.image = nil
        button.contentTintColor = nil
        button.attributedTitle = NSAttributedString(
            string: manager.compactStatusBarTitle,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]
        )
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

        if desktopWidgetWindow == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 430, height: 174),
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
            panel.contentView = NSHostingView(rootView: FloatingDesktopWidgetView(manager: manager, apiKeyManager: apiKeyManager))
            desktopWidgetWindow = panel
        }

        if let screenFrame = NSScreen.main?.visibleFrame {
            desktopWidgetWindow?.setFrameOrigin(NSPoint(x: screenFrame.maxX - 450, y: screenFrame.maxY - 204))
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
            hasError: manager.lastError != nil || apiKeyManager.lastError != nil
        )
    }

    var body: some View {
        ZStack {
            VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
            LinearGradient(
                colors: [
                    Color.black.opacity(0.34),
                    Color(red: 0.03, green: 0.05, blue: 0.08).opacity(0.56)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 0) {
                header

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        if manager.slots.isEmpty {
                            EmptyMonitorCard(importAccount: importAccount)
                        } else {
                            ForEach(manager.slots) { slot in
                                SlotDashboardCard(slot: slot)
                            }
                        }

                        if let lastError = manager.lastError {
                            MessageStrip(text: lastError, systemImage: "exclamationmark.triangle.fill")
                        }

                        APIBalanceSection(manager: apiKeyManager, openSettings: showAPIKeys, refresh: refreshAPIKeys)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: PanelMetrics.scrollHeight(for: panelHeight))

                actionBar
            }
        }
        .frame(width: PanelMetrics.width, height: panelHeight)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(LinearGradient(
                        colors: [
                            Color(red: 0.00, green: 0.82, blue: 0.95),
                            Color(red: 0.18, green: 0.36, blue: 1.00)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .shadow(color: .cyan.opacity(0.28), radius: 8, y: 3)
                Image(systemName: "terminal.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text("Codex 额度")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(statusSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.54))
            }

            Spacer()

            Text(manager.statusBarTitle.replacingOccurrences(of: "Codex ", with: ""))
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(manager.hasWarning ? Color.orange : Color.white)
        }
        .padding(.horizontal, 12)
        .padding(.top, 11)
        .padding(.bottom, 8)
    }

    private var statusSubtitle: String {
        if manager.isRefreshing { return "正在刷新..." }
        if manager.slots.isEmpty { return "尚未导入账号" }
        return "5h 与周额度实时监控"
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
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
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.06), in: Circle())
            }
            .buttonStyle(.borderless)
            .help("退出")
        }
        .padding(.horizontal, 10)
        .padding(.top, 7)
        .padding(.bottom, 9)
        .background(.black.opacity(0.16))
    }
}

private enum PanelMetrics {
    static let width: CGFloat = 352
    static let minHeight: CGFloat = 460
    static let maxHeight: CGFloat = 760
    private static let chromeHeight: CGFloat = 126

    static func height(codexSlotCount: Int, apiProviderCount: Int, hasError: Bool) -> CGFloat {
        let codexHeight: CGFloat = codexSlotCount == 0 ? 170 : CGFloat(codexSlotCount) * 215
        let apiHeight: CGFloat = 74 + CGFloat(apiProviderCount) * 86
        let errorHeight: CGFloat = hasError ? 52 : 0
        let contentHeight = codexHeight + apiHeight + errorHeight + 36
        return min(maxHeight, max(minHeight, chromeHeight + contentHeight))
    }

    static func scrollHeight(for panelHeight: CGFloat) -> CGFloat {
        max(280, panelHeight - chromeHeight)
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

            if let snapshot = slot.lastSnapshot, !snapshot.quotaWindows.isEmpty {
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
        .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
    }

    private var metaText: String {
        let plan = slot.lastSnapshot?.extras["planType"].map { "套餐 \($0)" }
        let source = slot.lastSnapshot?.sourceLabel
        return [plan, source].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct APIBalanceSection: View {
    @ObservedObject var manager: APIKeyManager
    let openSettings: () -> Void
    let refresh: () -> Void
    @State private var copiedProviderID: APIKeyProviderID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Label("模型余额", systemImage: "chart.bar.xaxis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                Spacer()
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(manager.isRefreshing ? 0.36 : 0.72))
                        .frame(width: 22, height: 20)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.borderless)
                .disabled(manager.isRefreshing)
                .help("刷新模型余额")
                Button("管理", action: openSettings)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.74))
                    .buttonStyle(.borderless)
            }

            VStack(spacing: 9) {
                ForEach(manager.providers) { provider in
                    APIBalanceRow(
                        provider: provider,
                        isCopied: copiedProviderID == provider.id,
                        isRefreshing: manager.refreshingProviderIDs.contains(provider.id),
                        copy: { copyPrimaryKey(for: provider) },
                        refresh: {
                            Task {
                                await manager.refreshProvider(provider.id)
                            }
                        }
                    )
                }
            }

            if let error = manager.lastError {
                MessageStrip(text: error, systemImage: "exclamationmark.triangle.fill")
            }
        }
        .padding(10)
        .background(
            LinearGradient(
                colors: [Color.white.opacity(0.105), Color.white.opacity(0.045)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 13)
        )
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.white.opacity(0.13), lineWidth: 0.8))
    }

    private func copyPrimaryKey(for provider: APIKeyProviderConfig) {
        let value = manager.primaryCopyValue(providerID: provider.id)
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copiedProviderID = provider.id
    }

}

private struct APIBalanceRow: View {
    let provider: APIKeyProviderConfig
    let isCopied: Bool
    let isRefreshing: Bool
    let copy: () -> Void
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(provider.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.86))
                    .frame(width: 70, alignment: .leading)
                Text(balanceText)
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(provider.lastSnapshot?.status == .error ? .orange : .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Spacer()
                PercentPill(text: statusText, color: color, isError: provider.lastSnapshot?.status == .error)
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(isRefreshing ? 0.36 : 0.62))
                        .frame(width: 22, height: 20)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.borderless)
                .disabled(isRefreshing)
                .help("刷新 \(provider.displayName)")
                Button(action: copy) {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(isCopied ? 0.92 : 0.60))
                        .frame(width: 22, height: 20)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.borderless)
                .help("复制 \(provider.displayName) API Key")
            }

            meterRows

            Text(detailText)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.42))
                .lineLimit(1)

            Text(updatedText)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.34))
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var meterRows: some View {
        if provider.id == .minimax {
            VStack(spacing: 4) {
                APIUsageMeter(label: "5h", remainingPercent: minimaxIntervalRemaining, color: color)
                APIUsageMeter(label: "周", remainingPercent: minimaxWeeklyRemaining, color: color.opacity(0.88))
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
        if snapshot.status == .error {
            return snapshot.note ?? "异常"
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
        guard let snapshot = provider.lastSnapshot else { return "--" }
        return "\(remainingPercent)%"
    }

    private var updatedText: String {
        guard let updatedAt = provider.lastSnapshot?.updatedAt else { return "尚未更新" }
        return QuotaFormatters.updatedText(updatedAt)
    }

    private var detailText: String {
        guard let snapshot = provider.lastSnapshot else { return "保存密钥后刷新余额" }
        switch provider.id {
        case .deepseek:
            let used = snapshot.used ?? "--"
            let total = snapshot.total ?? "--"
            return "已用 \(used) / 总额 \(total)"
        case .minimax:
            let weekly = "\(snapshot.extras["weeklyUsed"] ?? "--")/\(snapshot.extras["weeklyTotal"] ?? "--")"
            let interval = "\(snapshot.extras["intervalUsed"] ?? "--")/\(snapshot.extras["intervalTotal"] ?? "--")"
            return "5h \(interval) · 周 \(weekly)"
        case .comfly:
            if let balanceYuan = snapshot.extras["balanceYuan"] {
                return "约 \(balanceYuan) · 原始 quota \(snapshot.extras["quota"] ?? "--")"
            }
            return "已用 \(snapshot.used ?? "--") / \(snapshot.total ?? "--")"
        }
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

private struct APIUsageMeter: View {
    let label: String?
    let remainingPercent: Int
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            if let label {
                Text(label)
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.46))
                    .frame(width: 16, alignment: .leading)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.105))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(0.86))
                        .frame(width: proxy.size.width * CGFloat(max(0, min(100, remainingPercent))) / 100)
                }
            }
            .frame(height: 5)
            Text("\(remainingPercent)%")
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.44))
                .monospacedDigit()
                .frame(width: 32, alignment: .trailing)
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

    var body: some View {
        ZStack {
            VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
            LinearGradient(
                colors: [
                    Color.black.opacity(0.46),
                    Color(red: 0.03, green: 0.06, blue: 0.10).opacity(0.72)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            HStack(spacing: 22) {
                FloatingGauge(title: "5h", value: metric(.session), systemImage: "terminal.fill", color: .green)
                FloatingGauge(title: "周", value: metric(.weekly), systemImage: "calendar", color: .cyan)
                FloatingGauge(title: "DS", value: apiRemaining(.deepseek), systemImage: "sparkle.magnifyingglass", color: Color(hex: APIKeyProviderID.deepseek.colorHex) ?? .blue)
                FloatingGauge(title: "MM", value: apiRemaining(.minimax), systemImage: "brain.head.profile", color: Color(hex: APIKeyProviderID.minimax.colorHex) ?? .purple)
                FloatingGauge(title: "CF", value: apiRemaining(.comfly), systemImage: "bolt.fill", color: Color(hex: APIKeyProviderID.comfly.colorHex) ?? .orange)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
        }
        .frame(width: 430, height: 174)
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).stroke(.white.opacity(0.24), lineWidth: 1.1))
        .preferredColorScheme(.dark)
    }

    private func metric(_ kind: QuotaWindowKind) -> Int? {
        manager.slots.compactMap(\.lastSnapshot).flatMap(\.quotaWindows).first(where: { $0.kind == kind })?.remainingPercent
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
        }
    }
}

private struct FloatingGauge: View {
    let title: String
    let value: Int?
    let systemImage: String
    let color: Color

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.10), lineWidth: 9)
                Circle()
                    .trim(from: 0, to: CGFloat(clampedValue) / 100)
                    .stroke(
                        color,
                        style: StrokeStyle(lineWidth: 9, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
            }
            .frame(width: 62, height: 62)

            VStack(spacing: 1) {
                Text(value.map { "\($0)%" } ?? "--")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.86))
                Text(title)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.40))
            }
        }
        .frame(width: 62)
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
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.10))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(LinearGradient(colors: [color.opacity(0.85), color], startPoint: .leading, endPoint: .trailing))
                        .frame(width: proxy.size.width * CGFloat(window.remainingPercent) / 100)
                }
            }
            .frame(height: 6)

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
                .foregroundStyle(.white.opacity(0.56))
            Text("还没有 Codex 账号")
                .font(.headline)
                .foregroundStyle(.white)
            Text("导入当前 Codex 登录后即可显示实时额度。")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.56))
            Button("导入当前账号", action: importAccount)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(22)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
    }
}

private struct MessageStrip: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.white.opacity(0.66))
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
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
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.84))
                    .frame(width: 21, height: 15)
                Text(title)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.52))
            }
            .frame(width: 36, height: 30)
            .background(Color.white.opacity(0.060), in: RoundedRectangle(cornerRadius: 10))
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
                Text("默认配置 DeepSeek、MiniMax、Comfly。密钥保存到 macOS Keychain，点击复制可一键放入剪贴板。")
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
                    ForEach(provider.fields) { field in
                        fieldRow(field)
                    }
                }
                .frame(maxWidth: .infinity)

                balanceBox
                    .frame(width: 224)
            }

            HStack {
                Button(action: save) {
                    Label("保存", systemImage: "checkmark.circle")
                }
                Button(action: refresh) {
                    Label("刷新余额", systemImage: "arrow.clockwise")
                }
                Spacer()
                Text("配置文件不会保存安全字段明文")
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
            ProgressView(value: Double(provider.lastSnapshot?.usedPercent ?? 0), total: 100)
                .tint(Color(hex: provider.colorHex) ?? .accentColor)
            if let snapshot = provider.lastSnapshot {
                APIProviderStatsView(providerID: provider.id, snapshot: snapshot)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }

    private var balanceText: String {
        guard let snapshot = provider.lastSnapshot else { return "未配置" }
        if let balanceYuan = snapshot.extras["balanceYuan"] {
            return "\(snapshot.balance) / \(balanceYuan)"
        }
        if let unit = snapshot.unit {
            return "\(snapshot.balance) \(unit)"
        }
        return snapshot.balance
    }

    private var detailText: String {
        guard let snapshot = provider.lastSnapshot else { return "保存后刷新余额" }
        if let note = snapshot.note { return note }
        let total = snapshot.total.map { " / \($0)" } ?? ""
        return "已用 \(snapshot.usedPercent)%\(total)"
    }
}

private struct APIProviderStatsView: View {
    let providerID: APIKeyProviderID
    let snapshot: APIBalanceSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            switch providerID {
            case .deepseek:
                stat("已用", snapshot.used ?? "--")
                stat("总额度", snapshot.total ?? "--")
                stat("赠送", snapshot.extras["grantedBalance"] ?? "--")
                stat("充值", snapshot.extras["toppedUpBalance"] ?? "--")
            case .minimax:
                stat("周已用", "\(snapshot.extras["weeklyUsed"] ?? "--") / \(snapshot.extras["weeklyTotal"] ?? "--")")
                stat("周剩余", snapshot.extras["weeklyRemains"] ?? snapshot.balance)
                stat("周期已用", "\(snapshot.extras["intervalUsed"] ?? "--") / \(snapshot.extras["intervalTotal"] ?? "--")")
                stat("周期剩余", "\(snapshot.extras["intervalRemains"] ?? "--") · \(snapshot.extras["intervalRemainsTime"] ?? "--")")
            case .comfly:
                EmptyView()
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
