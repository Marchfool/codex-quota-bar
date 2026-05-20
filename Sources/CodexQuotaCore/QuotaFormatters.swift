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

    public static func absoluteResetText(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "重置时间 --" }
        let calendar = Calendar.current
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "zh_CN")
        timeFormatter.dateFormat = "HH:mm"

        if calendar.isDateInToday(date) {
            return "今天 \(timeFormatter.string(from: date)) 重置"
        }
        if calendar.isDateInTomorrow(date) {
            return "明天 \(timeFormatter.string(from: date)) 重置"
        }

        let weekdayFormatter = DateFormatter()
        weekdayFormatter.locale = Locale(identifier: "zh_CN")
        weekdayFormatter.dateFormat = "E HH:mm"
        return "\(weekdayFormatter.string(from: date)) 重置"
    }

    public static func remainingDurationText(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "剩余时间 --" }
        let remaining = max(0, Int(date.timeIntervalSince(now)))
        if remaining < 60 {
            return "\(remaining)秒"
        }

        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3_600
        let minutes = (remaining % 3_600) / 60

        if days > 0 {
            if hours > 0 {
                return "\(days)天\(hours)小时"
            }
            return "\(days)天"
        }

        if hours > 0 {
            if minutes > 0 {
                return "\(hours)小时\(minutes)分"
            }
            return "\(hours)小时"
        }

        return "\(minutes)分"
    }

    public static func compactRemainingDurationText(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "--" }
        let remaining = max(0, Int(date.timeIntervalSince(now)))
        if remaining < 60 {
            return "\(remaining)秒"
        }

        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3_600
        let minutes = (remaining % 3_600) / 60

        if days > 0 {
            return "\(days)天"
        }
        if hours > 0 {
            return "\(hours)小时"
        }
        return "\(minutes)分"
    }
}
