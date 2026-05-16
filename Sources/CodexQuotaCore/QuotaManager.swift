import Foundation

@MainActor
public final class QuotaManager: ObservableObject {
    @Published public private(set) var slots: [AccountSlot] = []
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var lastError: String?

    public let store: SlotStore
    public let provider: CodexQuotaProvider
    public let importer: CodexAuthImporter
    public var pollInterval: Duration
    private var pollingTask: Task<Void, Never>?

    public init(
        store: SlotStore,
        provider: CodexQuotaProvider,
        importer: CodexAuthImporter,
        pollInterval: Duration = .seconds(120)
    ) {
        self.store = store
        self.provider = provider
        self.importer = importer
        self.pollInterval = pollInterval
    }

    public var lowestRemaining: Int? {
        slots.compactMap { $0.lastSnapshot?.remaining }.min()
    }

    public var primaryRemaining: Int? {
        let sessionValues = slots.compactMap { slot in
            slot.lastSnapshot?.quotaWindows.first(where: { $0.kind == .session })?.remainingPercent
        }
        if let lowestSession = sessionValues.min() {
            return lowestSession
        }

        let validSnapshotValues = slots.compactMap { slot -> Int? in
            guard let snapshot = slot.lastSnapshot, !snapshot.quotaWindows.isEmpty, snapshot.status != .error else {
                return nil
            }
            return snapshot.remaining
        }
        return validSnapshotValues.min()
    }

    public var statusBarTitle: String {
        guard let remaining = primaryRemaining else { return "Codex --" }
        return "Codex \(remaining)%"
    }

    public var compactStatusBarTitle: String {
        let windows = slots.compactMap(\.lastSnapshot).flatMap(\.quotaWindows)
        let session = windows.first(where: { $0.kind == .session })?.remainingPercent
        let weekly = windows.first(where: { $0.kind == .weekly })?.remainingPercent

        switch (session, weekly) {
        case (.some(let session), .some(let weekly)):
            return "5h \(session)%  W \(weekly)%"
        case (.some(let session), .none):
            return "5h \(session)%"
        case (.none, .some(let weekly)):
            return "W \(weekly)%"
        case (.none, .none):
            return "--"
        }
    }

    public var hasWarning: Bool {
        (primaryRemaining ?? 100) < 20 || slots.contains { $0.lastSnapshot?.status == .error }
    }

    public func load() {
        do {
            let localSlots = try store.load().slots
            slots = shouldUseAIPlanMonitorFallback(localSlots) ? loadFreshAIPlanMonitorSlots(defaultingTo: localSlots) : localSlots
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func importCurrentCodexAccount() {
        do {
            let imported = try importer.importCurrentAccount()
            upsert(imported.slot)
            try persist()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func refreshAll() async {
        isRefreshing = true
        defer { isRefreshing = false }

        var updated: [AccountSlot] = []
        var surfacedError: String?
        for var slot in slots where slot.isActive {
            do {
                let snapshot = try await provider.fetchQuota(for: slot)
                slot.lastSnapshot = snapshot
                slot.lastSeenAt = Date()
            } catch {
                let existing = slot.lastSnapshot
                slot.lastSnapshot = staleSnapshot(from: existing, accountLabel: slot.displayName, error: error)
                if shouldSurfaceRefreshError(error, existing: existing) {
                    surfacedError = error.localizedDescription
                }
            }
            updated.append(slot)
        }

        let inactive = slots.filter { !$0.isActive }
        slots = updated + inactive
        lastError = surfacedError
        try? persist()
    }

    public func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshAll()
                try? await Task.sleep(for: self.pollInterval)
            }
        }
    }

    public func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    public func setSlotActive(_ slotID: String, isActive: Bool) {
        guard let index = slots.firstIndex(where: { $0.slotID == slotID }) else { return }
        slots[index].isActive = isActive
        try? persist()
    }

    private func upsert(_ slot: AccountSlot) {
        if let index = slots.firstIndex(where: { $0.slotID == slot.slotID }) {
            var merged = slot
            merged.lastSnapshot = slots[index].lastSnapshot
            slots[index] = merged
        } else {
            slots.append(slot)
        }
    }

    private func persist() throws {
        try store.save(SlotFile(slots: slots))
    }

    private func staleSnapshot(from existing: QuotaSnapshot?, accountLabel: String, error: Error) -> QuotaSnapshot {
        if var existing {
            existing.fetchHealth = error.isAuthError ? .authError : .stale
            if error.isAuthError {
                existing.status = .error
                existing.note = error.localizedDescription
            }
            existing.valueFreshness = .stale
            return existing
        }

        return QuotaSnapshot(
            accountLabel: accountLabel,
            fetchHealth: error.isAuthError ? .authError : .error,
            note: error.localizedDescription,
            quotaWindows: [],
            remaining: 0,
            status: .error,
            updatedAt: Date(),
            used: 0,
            valueFreshness: .stale
        )
    }

    private func shouldSurfaceRefreshError(_ error: Error, existing: QuotaSnapshot?) -> Bool {
        existing == nil || error.isAuthError
    }

    private func shouldUseAIPlanMonitorFallback(_ slots: [AccountSlot]) -> Bool {
        slots.isEmpty || slots.allSatisfy { slot in
            guard let snapshot = slot.lastSnapshot else { return true }
            return snapshot.quotaWindows.isEmpty && snapshot.status == .error
        }
    }

    private func loadFreshAIPlanMonitorSlots(defaultingTo fallback: [AccountSlot]) -> [AccountSlot] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AIPlanMonitor/codex_slots.json")
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let file = try? DateCoding.jsonDecoder.decode(SlotFile.self, from: data),
              !file.slots.isEmpty,
              file.slots.contains(where: { slot in
                  guard let updatedAt = slot.lastSnapshot?.updatedAt else { return false }
                  return Date().timeIntervalSince(updatedAt) < 300
              })
        else {
            return fallback
        }
        return file.slots
    }
}

private extension Error {
    var isAuthError: Bool {
        guard let providerError = self as? ProviderError else { return false }
        return providerError == .unauthorized || providerError == .missingCredential
    }
}
