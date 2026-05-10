import Foundation

public struct AccountSlot: Codable, Equatable, Identifiable, Sendable {
    public var id: String { slotID }
    public var slotID: String
    public var accountKey: String
    public var displayName: String
    public var accountID: String?
    public var isActive: Bool
    public var lastSeenAt: Date?
    public var lastSnapshot: QuotaSnapshot?

    public init(
        slotID: String,
        accountKey: String,
        displayName: String,
        accountID: String? = nil,
        isActive: Bool = true,
        lastSeenAt: Date? = nil,
        lastSnapshot: QuotaSnapshot? = nil
    ) {
        self.slotID = slotID
        self.accountKey = accountKey
        self.displayName = displayName
        self.accountID = accountID
        self.isActive = isActive
        self.lastSeenAt = lastSeenAt
        self.lastSnapshot = lastSnapshot
    }
}

public struct QuotaSnapshot: Codable, Equatable, Sendable {
    public var accountLabel: String
    public var fetchHealth: FetchHealth
    public var limit: Int
    public var note: String
    public var quotaWindows: [QuotaWindow]
    public var remaining: Int
    public var source: String
    public var sourceLabel: String
    public var status: QuotaStatus
    public var unit: String
    public var updatedAt: Date
    public var used: Int
    public var valueFreshness: ValueFreshness
    public var extras: [String: String]
    public var rawMeta: [String: String]

    public init(
        accountLabel: String,
        fetchHealth: FetchHealth,
        limit: Int = 100,
        note: String,
        quotaWindows: [QuotaWindow],
        remaining: Int,
        source: String = "codex-official",
        sourceLabel: String = "API",
        status: QuotaStatus,
        unit: String = "%",
        updatedAt: Date = Date(),
        used: Int,
        valueFreshness: ValueFreshness = .live,
        extras: [String: String] = [:],
        rawMeta: [String: String] = [:]
    ) {
        self.accountLabel = accountLabel
        self.fetchHealth = fetchHealth
        self.limit = limit
        self.note = note
        self.quotaWindows = quotaWindows
        self.remaining = remaining
        self.source = source
        self.sourceLabel = sourceLabel
        self.status = status
        self.unit = unit
        self.updatedAt = updatedAt
        self.used = used
        self.valueFreshness = valueFreshness
        self.extras = extras
        self.rawMeta = rawMeta
    }
}

public struct QuotaWindow: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: QuotaWindowKind
    public var remainingPercent: Int
    public var resetAt: Date?
    public var title: String
    public var usedPercent: Int

    public init(
        id: String,
        kind: QuotaWindowKind,
        remainingPercent: Int,
        resetAt: Date? = nil,
        title: String,
        usedPercent: Int
    ) {
        self.id = id
        self.kind = kind
        self.remainingPercent = remainingPercent
        self.resetAt = resetAt
        self.title = title
        self.usedPercent = usedPercent
    }
}

public enum QuotaWindowKind: String, Codable, Sendable {
    case session
    case weekly
    case credits
    case unknown
}

public enum FetchHealth: String, Codable, Sendable {
    case ok
    case stale
    case error
    case authError
}

public enum QuotaStatus: String, Codable, Sendable {
    case ok
    case warning
    case exhausted
    case error
}

public enum ValueFreshness: String, Codable, Sendable {
    case live
    case stale
}

public struct SlotFile: Codable, Equatable, Sendable {
    public var slots: [AccountSlot]

    public init(slots: [AccountSlot] = []) {
        self.slots = slots
    }
}
