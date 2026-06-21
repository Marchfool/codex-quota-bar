import Foundation

public struct MiniMaxQuotaWindowDisplay: Equatable, Sendable {
    public var summary: String
    public var meterLabel: String
    public var barPercent: Int
    public var trailingLabel: String

    public init(summary: String, meterLabel: String, barPercent: Int, trailingLabel: String) {
        self.summary = summary
        self.meterLabel = meterLabel
        self.barPercent = barPercent
        self.trailingLabel = trailingLabel
    }
}

public enum MiniMaxQuotaDisplay {
    public static func window(
        extras: [String: String],
        remainingKey: String,
        totalKey: String,
        usedKey: String,
        fallbackUsedPercent: Int
    ) -> MiniMaxQuotaWindowDisplay {
        let remaining = intValue(extras[remainingKey]) ?? max(0, 100 - fallbackUsedPercent)
        let total = intValue(extras[totalKey]) ?? 100
        let used = intValue(extras[usedKey]) ?? max(0, total - remaining)

        return MiniMaxQuotaWindowDisplay(
            summary: "总额\(total)% · 已用\(used)%",
            meterLabel: "\(total)%",
            barPercent: clampPercent(remaining),
            trailingLabel: "\(clampPercent(remaining))%"
        )
    }

    private static func intValue(_ value: String?) -> Int? {
        guard let value else { return nil }
        return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func clampPercent(_ value: Int) -> Int {
        min(100, max(0, value))
    }
}
