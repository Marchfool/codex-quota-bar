import Foundation

public enum QuotaFormatters {
    public static func resetText(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "reset --" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "reset \(formatter.localizedString(for: date, relativeTo: now))"
    }

    public static func updatedText(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "updated \(formatter.localizedString(for: date, relativeTo: now))"
    }

    public static func percentText(_ value: Int) -> String {
        "\(min(100, max(0, value)))%"
    }
}
