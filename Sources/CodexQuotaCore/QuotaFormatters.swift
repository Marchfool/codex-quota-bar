import Foundation

public enum QuotaFormatters {
    public static func resetText(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "reset --" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "reset \(formatter.localizedString(for: date, relativeTo: now))"
    }

    public static func updatedText(_ date: Date, now: Date = Date()) -> String {
        chineseUpdatedText(date, now: now)
    }

    public static func chineseUpdatedText(_ date: Date, now: Date = Date()) -> String {
        let elapsed = now.timeIntervalSince(date)
        if abs(elapsed) < 10 {
            return "刚刚更新"
        }

        if elapsed >= 0 {
            if elapsed < 60 {
                return "更新于 \(Int(elapsed)) 秒前"
            }
            if elapsed < 3_600 {
                return "更新于 \(Int(elapsed / 60)) 分钟前"
            }
            if elapsed < 86_400 {
                return "更新于 \(Int(elapsed / 3_600)) 小时前"
            }
            return "更新于 \(Int(elapsed / 86_400)) 天前"
        }

        let remaining = abs(elapsed)
        if remaining < 60 {
            return "\(Int(remaining)) 秒后更新"
        }
        if remaining < 3_600 {
            return "\(Int(remaining / 60)) 分钟后更新"
        }
        return "\(Int(remaining / 3_600)) 小时后更新"
    }

    public static func percentText(_ value: Int) -> String {
        "\(min(100, max(0, value)))%"
    }
}
