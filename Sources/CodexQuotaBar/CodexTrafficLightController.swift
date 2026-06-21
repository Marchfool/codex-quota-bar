import AppKit
import CoreServices
import Foundation

/// Self-contained Codex "traffic light": watches ~/.codex/sessions/*.jsonl and infers whether
/// the most recent Codex turn is running / completed / errored, shown as a colored dot in its
/// own NSStatusItem. Ported (display path only) from the standalone CodexTaskMonitor — no
/// WebSocket / HTTP server management. Uses FSEvents for near-instant detection plus a periodic
/// poll fallback. File I/O runs on a background queue; UI updates on the main actor.
@MainActor
final class CodexTrafficLightController: ObservableObject {
    enum Mode: Equatable {
        case idle, running, success, failure
        var color: NSColor {
            switch self {
            // App 工作逻辑:工作中=黄,空闲/已完成=绿,报错=红(空闲也用绿,与原项目一致)
            case .idle: return NSColor(calibratedRed: 0.27, green: 0.78, blue: 0.34, alpha: 1) // green
            case .running: return NSColor(calibratedRed: 0.95, green: 0.78, blue: 0.22, alpha: 1) // yellow
            case .success: return NSColor(calibratedRed: 0.27, green: 0.78, blue: 0.34, alpha: 1) // green
            case .failure: return NSColor(calibratedRed: 0.93, green: 0.32, blue: 0.27, alpha: 1) // red
            }
        }
        var label: String {
            switch self {
            case .idle: return "空闲 / 无最近任务"
            case .running: return "执行中"
            case .success: return "已完成"
            case .failure: return "异常 / 报错"
            }
        }
    }

    @Published private(set) var mode: Mode = .idle
    @Published private(set) var detail: String = "无活动任务"

    /// 当 Codex 任务状态(mode)发生变化时回调，供主菜单栏图标重绘其内嵌红绿灯圆点。
    var onModeChange: (@MainActor () -> Void)?

    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var eventStream: FSEventStreamRef?
    private var statusItemVisible = false
    private var panelVisible = false
    /// 主菜单栏图标内嵌了红绿灯时，即使自身独立圆点隐藏，也要持续监听。
    private var embeddedActive = false
    private let scanQueue = DispatchQueue(label: "com.codexquotabar.trafficlight", qos: .utility)
    private var scanScheduled = false
    private var scanInProgress = false
    private var pendingScan = false
    private var lastScanStartedAt = Date.distantPast
    private var renderedMode: Mode = .idle
    private var blinkWorkItems: [DispatchWorkItem] = []
    private let menu = NSMenu()
    private let statusMenuItem = NSMenuItem(title: "Codex: 空闲", action: nil, keyEquivalent: "")
    private let minimumScanInterval: TimeInterval = 1.25
    private let fallbackScanInterval: TimeInterval = 10

    func start() {
        setVisible(true)
    }

    func setVisible(_ visible: Bool) {
        statusItemVisible = visible
        if visible {
            ensureStatusItem()
            statusItem?.isVisible = true
        } else {
            statusItem?.isVisible = false
        }
        updateMonitoringState()
    }

    func setPanelVisible(_ visible: Bool) {
        panelVisible = visible
        updateMonitoringState()
    }

    /// 开启/关闭"主图标内嵌红绿灯"的常驻监听（不显示自身独立圆点）。
    func setEmbeddedActive(_ active: Bool) {
        embeddedActive = active
        updateMonitoringState()
    }

    private func ensureStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: 26)
        statusMenuItem.isEnabled = false
        if menu.items.isEmpty {
            menu.addItem(statusMenuItem)
        }
        item.menu = menu
        statusItem = item
        renderInitialIcon()
    }

    private func updateMonitoringState() {
        if statusItemVisible || panelVisible || embeddedActive {
            startMonitoring()
        } else {
            stopMonitoring()
        }
    }

    private func startMonitoring() {
        startFSEvents()
        if timer == nil {
            let timer = Timer(timeInterval: fallbackScanInterval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scanNow()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        scanNow()
    }

    private func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        stopFSEvents()
        blinkWorkItems.forEach { $0.cancel() }
        blinkWorkItems.removeAll()
    }

    /// Trigger a background scan and apply the result on the main actor.
    func scanNow() {
        scheduleScan()
    }

    private func scheduleScan(after requestedDelay: TimeInterval = 0) {
        if scanInProgress {
            pendingScan = true
            return
        }
        guard !scanScheduled else { return }

        let elapsed = Date().timeIntervalSince(lastScanStartedAt)
        let throttleDelay = max(0, minimumScanInterval - elapsed)
        let delay = max(requestedDelay, throttleDelay)
        scanScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            Task { @MainActor [weak self] in
                self?.performScan()
            }
        }
    }

    private func performScan() {
        guard scanScheduled else { return }
        scanScheduled = false
        scanInProgress = true
        lastScanStartedAt = Date()
        scanQueue.async {
            let result = CodexTrafficLightController.inferCurrentMode()
            Task { @MainActor [weak self] in self?.finishScan(result) }
        }
    }

    private func finishScan(_ result: (mode: Mode, detail: String)?) {
        apply(result)
        scanInProgress = false
        if pendingScan {
            pendingScan = false
            scheduleScan()
        }
    }

    private func apply(_ result: (mode: Mode, detail: String)?) {
        guard let result else { return }
        let modeChanged = mode != result.mode
        detail = result.detail
        statusItem?.button?.toolTip = "Codex: \(result.mode.label)"
        statusMenuItem.title = "Codex: \(result.mode.label) · \(result.detail)"
        setIcon(mode: result.mode, animated: true)
        mode = result.mode
        if modeChanged { onModeChange?() }
    }

    // MARK: - Icon + pulse animation (ported from CodexTaskMonitor)

    private func renderInitialIcon() {
        statusItem?.button?.image = Self.makeCircleImage(color: Mode.idle.color)
        statusItem?.button?.imagePosition = .imageOnly
        renderedMode = .idle
    }

    private func setIcon(mode: Mode, animated: Bool) {
        blinkWorkItems.forEach { $0.cancel() }
        blinkWorkItems.removeAll()

        let changed = renderedMode != mode
        renderedMode = mode
        guard animated, changed, let button = statusItem?.button else {
            statusItem?.button?.image = Self.makeCircleImage(color: mode.color)
            return
        }

        // ~5s breathing pulse on every state change, then settle bright.
        let pulse: [CGFloat] = [0.30, 0.42, 0.58, 0.76, 0.92, 1.00, 0.92, 0.76, 0.58, 0.42]
        let alphas = pulse + pulse + pulse + pulse + pulse
        let images = alphas.map { Self.makeCircleImage(color: mode.color.withAlphaComponent($0)) }
        let bright = Self.makeCircleImage(color: mode.color)
        let frame: TimeInterval = 0.10

        for (i, img) in images.enumerated() {
            let work = DispatchWorkItem { [weak button] in button?.image = img }
            blinkWorkItems.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + frame * Double(i), execute: work)
        }
        let final = DispatchWorkItem { [weak button] in button?.image = bright }
        blinkWorkItems.append(final)
        DispatchQueue.main.asyncAfter(deadline: .now() + frame * Double(images.count), execute: final)
    }

    nonisolated private static func makeCircleImage(color: NSColor) -> NSImage {
        let side: CGFloat = 22
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        let rect = NSRect(x: 2, y: 2, width: side - 4, height: side - 4)
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
        NSColor.controlTextColor.withAlphaComponent(0.25).setStroke()
        let border = NSBezierPath(ovalIn: rect)
        border.lineWidth = 1
        border.stroke()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    // MARK: - FSEvents (near-instant detection)

    private static let eventCallback: FSEventStreamCallback = { _, info, _, _, _, _ in
        guard let info else { return }
        let ctrl = Unmanaged<CodexTrafficLightController>.fromOpaque(info).takeUnretainedValue()
        Task { @MainActor in ctrl.scanNow() }
    }

    private func startFSEvents() {
        guard eventStream == nil else { return }
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".codex/sessions")
        guard FileManager.default.fileExists(atPath: path) else { return }
        var ctx = FSEventStreamContext(version: 0,
                                       info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, Self.eventCallback, &ctx,
            [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, scanQueue)
        FSEventStreamStart(stream)
        eventStream = stream
    }

    private func stopFSEvents() {
        guard let stream = eventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        eventStream = nil
    }

    // MARK: - Inference (nonisolated: runs on the background scan queue)

    private struct Probe { let path: String; let modifiedAt: Date }
    nonisolated private static let candidateWindowSeconds: TimeInterval = 45 * 60
    nonisolated private static let quietTurnGraceSeconds: TimeInterval = 3 * 60
    nonisolated private static let pendingToolGraceSeconds: TimeInterval = 45 * 60
    nonisolated private static let recentProbeLimit = 4
    nonisolated private static let maxTailReadBytes: UInt64 = 512 * 1024

    nonisolated private static func inferCurrentMode() -> (mode: Mode, detail: String)? {
        let probes = recentSessionProbes(limit: recentProbeLimit)
        guard !probes.isEmpty else { return (.idle, "无会话") }

        let now = Date()
        let fresh = probes.filter { now.timeIntervalSince($0.modifiedAt) <= candidateWindowSeconds }
        let candidates = fresh.isEmpty ? Array(probes.prefix(1)) : fresh

        var sawSuccess = false
        for probe in candidates {
            let modifiedAgo = now.timeIntervalSince(probe.modifiedAt)
            guard let mode = inferModeFromJSONL(path: probe.path, modifiedAgo: modifiedAgo) else { continue }
            if mode == .failure { return (.failure, relativeTime(probe.modifiedAt)) }
            if mode == .running { return (.running, relativeTime(probe.modifiedAt)) }
            if mode == .success { sawSuccess = true }
        }
        if sawSuccess { return (.success, relativeTime(candidates.first?.modifiedAt ?? now)) }
        return (.idle, "无活动任务")
    }

    nonisolated private static func recentSessionProbes(limit: Int) -> [Probe] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true).standardized
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var probes: [Probe] = []
        for case let url as URL in en {
            guard url.pathExtension == "jsonl",
                  let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.isRegularFile == true, let m = v.contentModificationDate else { continue }
            probes.append(Probe(path: url.path, modifiedAt: m))
        }
        return Array(probes.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(max(limit, 1)))
    }

    private struct TurnProbeState {
        var hasOpenTurn = false
        var terminalMode: Mode?
        var pendingCallIDs = Set<String>()
        var anonymousPendingCalls = 0

        var hasPendingTool: Bool {
            !pendingCallIDs.isEmpty || anonymousPendingCalls > 0
        }

        mutating func startTurn() {
            hasOpenTurn = true
            terminalMode = nil
            pendingCallIDs.removeAll()
            anonymousPendingCalls = 0
        }

        mutating func finish(_ mode: Mode) {
            hasOpenTurn = false
            terminalMode = mode
            pendingCallIDs.removeAll()
            anonymousPendingCalls = 0
        }

        mutating func startTool(callID: String?) {
            hasOpenTurn = true
            terminalMode = nil
            if let callID, !callID.isEmpty {
                pendingCallIDs.insert(callID)
            } else {
                anonymousPendingCalls += 1
            }
        }

        mutating func finishTool(callID: String?) {
            hasOpenTurn = true
            if let callID, !callID.isEmpty {
                pendingCallIDs.remove(callID)
            } else if anonymousPendingCalls > 0 {
                anonymousPendingCalls -= 1
            }
        }
    }

    nonisolated private static func inferModeFromJSONL(path: String, modifiedAgo: TimeInterval) -> Mode? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        let fileSize = (try? handle.seekToEnd()) ?? 0
        let readSize = min(maxTailReadBytes, fileSize)
        try? handle.seek(toOffset: fileSize - readSize)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }

        var state = TurnProbeState()
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = raw.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let payload = json["payload"] as? [String: Any] else { continue }
            let type = (payload["type"] as? String)?.lowercased() ?? ""
            let phase = (payload["phase"] as? String)?.lowercased() ?? ""
            let callID = (payload["call_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

            if type == "task_started" || type == "user_message" { state.startTurn(); continue }
            if type == "task_complete" || type == "turn_aborted" || phase == "final" || phase == "final_answer" {
                state.finish(.success); continue
            }
            if let failure = failureText(from: payload) {
                let l = failure.lowercased()
                if l.contains("error") || l.contains("failed") || l.contains("exception") || l.contains("crash") {
                    state.finish(.failure); continue
                }
            }
            if isToolCallStart(type) {
                state.startTool(callID: callID); continue
            }
            if isToolCallEnd(type) {
                state.finishTool(callID: callID); continue
            }
            if type == "reasoning" || phase == "commentary" {
                state.hasOpenTurn = true
                if state.terminalMode != nil { state.terminalMode = nil }
            }
        }

        if let terminalMode = state.terminalMode {
            return terminalMode
        }
        if state.hasPendingTool {
            return modifiedAgo <= pendingToolGraceSeconds ? .running : .success
        }
        if state.hasOpenTurn {
            return modifiedAgo <= quietTurnGraceSeconds ? .running : .success
        }
        return nil
    }

    nonisolated private static func isToolCallStart(_ type: String) -> Bool {
        if type == "function_call" || type == "custom_tool_call" { return true }
        if type.hasSuffix("_call"),
           !type.hasSuffix("_tool_call_output"),
           !type.hasSuffix("_output"),
           !type.hasSuffix("_end") {
            return true
        }
        return false
    }

    nonisolated private static func isToolCallEnd(_ type: String) -> Bool {
        if type == "function_call_output" || type == "custom_tool_call_output" { return true }
        return type.hasSuffix("_output") || type.hasSuffix("_end")
    }

    nonisolated private static func failureText(from payload: [String: Any]) -> String? {
        for key in ["error", "errorMessage", "errmsg", "exception", "error_msg"] {
            if let s = payload[key] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return s }
            if let dict = payload[key] as? [String: Any], let msg = dict["message"] as? String { return msg }
        }
        return nil
    }

    nonisolated private static func relativeTime(_ date: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(date)))
        if s < 60 { return "\(s)秒前" }
        if s < 3600 { return "\(s / 60)分前" }
        return "\(s / 3600)小时前"
    }
}
