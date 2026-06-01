import AppKit
import Darwin

/// One history point: memory-pressure ratio + the kernel pressure level at that moment,
/// so the sparkline can keep each past segment's color (like Activity Monitor).
struct MemoryPoint: Equatable {
    let ratio: Double
    let level: Int32
    let capturedAt: Date
}

/// Maps kernel memory-pressure level to the Activity-Monitor-style color.
@MainActor
func memoryPressureColor(_ level: Int32) -> NSColor {
    if level >= 4 { return NSColor(calibratedRed: 0.93, green: 0.32, blue: 0.27, alpha: 1) } // red
    if level >= 2 { return NSColor(calibratedRed: 0.95, green: 0.78, blue: 0.22, alpha: 1) } // yellow
    return NSColor(calibratedRed: 0.27, green: 0.78, blue: 0.34, alpha: 1)                   // green
}

/// Self-contained menu-bar memory indicator: reads VM stats via native Mach/sysctl APIs
/// (no subprocess), draws a sparkline pill with the used-GB number, tinted by kernel
/// memory-pressure level. Lives in its own NSStatusItem, independent of the quota UI.
@MainActor
final class MemoryMonitorController: ObservableObject {
    struct Sample {
        var usedBytes: Double
        var appBytes: Double
        var wiredBytes: Double
        var compressedBytes: Double
        var cachedBytes: Double
        var swapUsedBytes: Double
        var physicalBytes: Double
        var pressureLevel: Int32   // 1 normal, 2 warn, >=4 critical
        var pressureRatio: Double  // (wired + compressed) / physical
    }

    @Published private(set) var current: Sample?
    @Published private(set) var historySamples: [MemoryPoint] = []

    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var history: [MemoryPoint] = []
    private let sampleInterval: TimeInterval = 1
    private let historyWindow: TimeInterval = 60
    private let menu = NSMenu()
    private var breakdownItems: [String: NSMenuItem] = [:]
    private var historyCapacity: Int { Int(historyWindow / sampleInterval) + 2 }

    private static let breakdownRows: [(label: String, key: String)] = [
        ("已用", "used"), ("App", "app"), ("联动", "wired"),
        ("已压缩", "compressed"), ("已缓存", "cached"), ("Swap", "swap")
    ]

    func start() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: 66)
        item.button?.imagePosition = .imageOnly
        buildMenu()
        item.menu = menu
        statusItem = item

        if let first = try? readSample() {
            let now = Date()
            history = (0..<historyCapacity).map { index in
                let secondsAgo = Double(historyCapacity - index - 1) * sampleInterval
                return MemoryPoint(
                    ratio: first.pressureRatio,
                    level: first.pressureLevel,
                    capturedAt: now.addingTimeInterval(-secondsAgo)
                )
            }
        }
        tick()

        let timer = Timer(timeInterval: sampleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func setVisible(_ visible: Bool) {
        if visible {
            if statusItem == nil { start() }
            statusItem?.isVisible = true
        } else {
            statusItem?.isVisible = false
        }
    }

    private func buildMenu() {
        for row in Self.breakdownRows {
            let mi = NSMenuItem(title: "\(row.label)\t--", action: nil, keyEquivalent: "")
            mi.isEnabled = false
            breakdownItems[row.key] = mi
            menu.addItem(mi)
        }
    }

    private func tick() {
        guard let sample = try? readSample() else {
            statusItem?.button?.title = "MEM ?"
            return
        }
        let now = Date()
        history.append(MemoryPoint(ratio: sample.pressureRatio, level: sample.pressureLevel, capturedAt: now))
        let cutoff = now.addingTimeInterval(-historyWindow - sampleInterval)
        history.removeAll { $0.capturedAt < cutoff }
        if history.count > historyCapacity {
            history.removeFirst(history.count - historyCapacity)
        }
        current = sample
        historySamples = history

        let usedGB = sample.usedBytes / 1_073_741_824
        statusItem?.button?.image = makePillImage(usedGB: usedGB)
        statusItem?.button?.toolTip = String(format: "内存已用 %.1f GB / %.0f GB", usedGB, sample.physicalBytes / 1_073_741_824)

        let gb: (Double) -> String = { String(format: "%.2f GB", $0 / 1_073_741_824) }
        breakdownItems["used"]?.title = "已用\t\(gb(sample.usedBytes))"
        breakdownItems["app"]?.title = "App\t\(gb(sample.appBytes))"
        breakdownItems["wired"]?.title = "联动\t\(gb(sample.wiredBytes))"
        breakdownItems["compressed"]?.title = "已压缩\t\(gb(sample.compressedBytes))"
        breakdownItems["cached"]?.title = "已缓存\t\(gb(sample.cachedBytes))"
        breakdownItems["swap"]?.title = "Swap\t\(gb(sample.swapUsedBytes))"
    }

    // MARK: - Data (native Mach + sysctl, no subprocess)

    private func readSample() throws -> Sample {
        let page = Double(getpagesize())

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { throw NSError(domain: "mem", code: Int(kr)) }

        let free = Double(stats.free_count) * page
        let purgeable = Double(stats.purgeable_count) * page
        let app = Double(stats.internal_page_count) * page - purgeable
        let wired = Double(stats.wire_count) * page
        let compressed = Double(stats.compressor_page_count) * page
        let cached = (Double(stats.external_page_count) + Double(stats.speculative_count)) * page + purgeable

        let physical = Double(sysctlUInt64("hw.memsize"))
        let used = max(0, physical - free - cached)

        var xsw = xsw_usage()
        var xswLen = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &xsw, &xswLen, nil, 0)
        let swapUsed = Double(xsw.xsu_used)

        var level: Int32 = 1
        var levelLen = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelLen, nil, 0)

        let pressure = physical > 0 ? (wired + compressed) / physical : 0

        return Sample(
            usedBytes: used, appBytes: app, wiredBytes: wired, compressedBytes: compressed,
            cachedBytes: cached, swapUsedBytes: swapUsed, physicalBytes: physical,
            pressureLevel: level, pressureRatio: pressure
        )
    }

    private func sysctlUInt64(_ name: String) -> UInt64 {
        var value: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        sysctlbyname(name, &value, &len, nil, 0)
        return value
    }

    // MARK: - Drawing (per-segment colored sparkline, like Activity Monitor)

    private func makePillImage(usedGB: Double) -> NSImage {
        let width: CGFloat = 60
        let height = NSStatusBar.system.thickness
        let curColor = memoryPressureColor(current?.pressureLevel ?? 1)
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        defer { image.unlockFocus() }

        let inset: CGFloat = 1.5
        let pill = NSRect(x: inset, y: inset + 1, width: width - inset * 2, height: height - inset * 2 - 2)
        let radius = pill.height / 2

        NSColor(calibratedWhite: 0.10, alpha: 0.95).setFill()
        NSBezierPath(roundedRect: pill, xRadius: radius, yRadius: radius).fill()

        if history.count > 1 {
            NSBezierPath(roundedRect: pill, xRadius: radius, yRadius: radius).setClip()
            let maxV = max(history.map(\.ratio).max() ?? 0.05, 0.05)
            let n = history.count
            let now = Date()
            let windowStart = now.addingTimeInterval(-historyWindow)
            func point(_ i: Int) -> NSPoint {
                let progress = min(1, max(0, history[i].capturedAt.timeIntervalSince(windowStart) / historyWindow))
                let x = pill.minX + pill.width * CGFloat(progress)
                let y = pill.minY + 2 + (pill.height - 4) * CGFloat(min(1, history[i].ratio / maxV))
                return NSPoint(x: x, y: y)
            }
            // color each segment by the level at its right endpoint
            for i in 1..<n {
                let seg = NSBezierPath()
                seg.move(to: point(i - 1))
                seg.line(to: point(i))
                seg.lineWidth = 1.2
                memoryPressureColor(history[i].level).withAlphaComponent(0.6).setStroke()
                seg.stroke()
            }
        }

        let text = String(format: "%.1fG", usedGB)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.85)
        shadow.shadowBlurRadius = 1.5
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .bold),
            .foregroundColor: curColor.blended(withFraction: 0.35, of: .white) ?? curColor,
            .shadow: shadow
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let textRect = NSRect(x: pill.midX - size.width / 2, y: pill.midY - size.height / 2, width: size.width, height: size.height)
        (text as NSString).draw(in: textRect, withAttributes: attrs)

        image.isTemplate = false
        return image
    }
}
