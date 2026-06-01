import AppKit
import CoreServices
import Foundation

/// Heuristic Claude "working" detector. Claude Desktop is an Electron app with no task-event
/// log like Codex, so we watch its chat IndexedDB (leveldb) for writes: while Claude streams a
/// reply it persists to IndexedDB, so frequent writes ⇒ "working". This is best-effort only.
@MainActor
final class ClaudeActivityController: ObservableObject {
    /// True when Claude's chat store was written within the recent activity window.
    @Published private(set) var active = false

    private var eventStream: FSEventStreamRef?
    private var timer: Timer?
    private var lastWriteAt = Date.distantPast
    private let activityWindow: TimeInterval = 4   // seconds of quiet before flipping back to idle
    private let scanQueue = DispatchQueue(label: "com.codexquotabar.claudeactivity", qos: .utility)

    private var watchPaths: [String] {
        let base = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Claude/IndexedDB")
        return [base]
    }

    func start() {
        startFSEvents()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let stillActive = Date().timeIntervalSince(self.lastWriteAt) < self.activityWindow
                if self.active != stillActive { self.active = stillActive }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func noteActivity() {
        lastWriteAt = Date()
        if !active { active = true }
    }

    private static let eventCallback: FSEventStreamCallback = { _, info, _, _, _, _ in
        guard let info else { return }
        let ctrl = Unmanaged<ClaudeActivityController>.fromOpaque(info).takeUnretainedValue()
        Task { @MainActor in ctrl.noteActivity() }
    }

    private func startFSEvents() {
        let paths = watchPaths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !paths.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0,
                                       info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, Self.eventCallback, &ctx,
            paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, scanQueue)
        FSEventStreamStart(stream)
        eventStream = stream
    }
}
