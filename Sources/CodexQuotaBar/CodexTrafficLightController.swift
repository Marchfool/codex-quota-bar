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

    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var eventStream: FSEventStreamRef?
    private let scanQueue = DispatchQueue(label: "com.codexquotabar.trafficlight", qos: .utility)
    private var renderedMode: Mode = .idle
    private var blinkWorkItems: [DispatchWorkItem] = []
    private let menu = NSMenu()
    private let statusMenuItem = NSMenuItem(title: "Codex: 空闲", action: nil, keyEquivalent: "")

    func start() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: 26)
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        item.menu = menu
        statusItem = item
        renderInitialIcon()

        startFSEvents()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scanNow()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        scanNow()
    }

    func setVisible(_ visible: Bool) {
        if visible {
            if statusItem == nil { start() }
            statusItem?.isVisible = true
        } else {
            statusItem?.isVisible = false
        }
    }

    /// Trigger a background scan and apply the result on the main actor.
    func scanNow() {
        scanQueue.async {
            let result = CodexTrafficLightController.inferCurrentMode()
            Task { @MainActor [weak self] in self?.apply(result) }
        }
    }

    private func apply(_ result: (mode: Mode, detail: String)?) {
        guard let result else { return }
        detail = result.detail
        statusItem?.button?.toolTip = "Codex: \(result.mode.label)"
        statusMenuItem.title = "Codex: \(result.mode.label) · \(result.detail)"
        setIcon(mode: result.mode, animated: true)
        mode = result.mode
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
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".codex/sessions")
        guard FileManager.default.fileExists(atPath: path) else { return }
        var ctx = FSEventStreamContext(version: 0,
                                       info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, Self.eventCallback, &ctx,
            [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, scanQueue)
        FSEventStreamStart(stream)
        eventStream = stream
    }

    // MARK: - Inference (nonisolated: runs on the background scan queue)

    private struct Probe { let path: String; let modifiedAt: Date }

    nonisolated private static func inferCurrentMode() -> (mode: Mode, detail: String)? {
        let probes = recentSessionProbes(limit: 12)
        guard !probes.isEmpty else { return (.idle, "无会话") }

        let now = Date()
        let fresh = probes.filter { now.timeIntervalSince($0.modifiedAt) <= 10 * 60 }
        let candidates = fresh.isEmpty ? Array(probes.prefix(1)) : fresh

        var sawSuccess = false
        for probe in candidates {
            guard let mode = inferModeFromJSONL(path: probe.path) else { continue }
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

    nonisolated private static func inferModeFromJSONL(path: String) -> Mode? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        let fileSize = (try? handle.seekToEnd()) ?? 0
        let readSize = min(UInt64(2 * 1024 * 1024), fileSize)
        try? handle.seek(toOffset: fileSize - readSize)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }

        var seenCurrentTurn = false
        var latest: Mode?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = raw.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let payload = json["payload"] as? [String: Any] else { continue }
            let type = (payload["type"] as? String)?.lowercased() ?? ""
            let phase = (payload["phase"] as? String)?.lowercased() ?? ""

            if type == "user_message" { seenCurrentTurn = true; latest = .running; continue }
            if type == "task_complete" || type == "turn_aborted" || phase == "final" || phase == "final_answer" {
                latest = .success; continue
            }
            guard seenCurrentTurn else {
                if type == "function_call" || type == "function_call_output" || type == "reasoning" { latest = .running }
                continue
            }
            if let failure = failureText(from: payload) {
                let l = failure.lowercased()
                if l.contains("error") || l.contains("failed") || l.contains("exception") || l.contains("crash") {
                    latest = .failure; continue
                }
            }
            if type == "function_call" || type == "function_call_output" || type == "reasoning" { latest = .running }
        }
        return latest
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
