import Foundation
import SwiftUI
import WidgetKit

struct QuotaEntry: TimelineEntry {
    let date: Date
    let session: Int?
    let weekly: Int?
    let account: String
    let updatedAt: Date?
    let isStale: Bool
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> QuotaEntry {
        QuotaEntry(date: Date(), session: 84, weekly: 98, account: "Codex", updatedAt: Date(), isStale: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (QuotaEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuotaEntry>) -> Void) {
        let entry = loadEntry()
        let next = Calendar.current.date(byAdding: .minute, value: 5, to: Date()) ?? Date().addingTimeInterval(300)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func loadEntry() -> QuotaEntry {
        let snapshotURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexQuotaBar/codex_slots.json")

        guard let data = try? Data(contentsOf: snapshotURL),
              let file = try? JSONDecoder.codexQuota.decode(SlotFile.self, from: data),
              let slot = file.slots.first,
              let snapshot = slot.lastSnapshot
        else {
            return QuotaEntry(date: Date(), session: nil, weekly: nil, account: "Codex", updatedAt: nil, isStale: true)
        }

        let session = snapshot.quotaWindows.first(where: { $0.kind == "session" })?.remainingPercent
        let weekly = snapshot.quotaWindows.first(where: { $0.kind == "weekly" })?.remainingPercent
        let isStale = snapshot.valueFreshness == "stale" || Date().timeIntervalSince(snapshot.updatedAt) > 600

        return QuotaEntry(
            date: Date(),
            session: session,
            weekly: weekly,
            account: slot.displayName,
            updatedAt: snapshot.updatedAt,
            isStale: isStale
        )
    }
}

struct CodexQuotaWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuotaEntry

    var body: some View {
        switch family {
        case .systemMedium:
            mediumView
        default:
            smallView
        }
    }

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Spacer(minLength: 2)
            RingMetric(title: "5h", value: entry.session, color: .green)
            RingMetric(title: "W", value: entry.weekly, color: .cyan)
        }
        .padding(14)
        .containerBackground(backgroundGradient, for: .widget)
    }

    private var mediumView: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(spacing: 12) {
                QuotaBlock(title: "5 小时", subtitle: "短期额度", value: entry.session, color: .green)
                QuotaBlock(title: "周额度", subtitle: "Weekly", value: entry.weekly, color: .cyan)
            }
            Spacer(minLength: 0)
            Text(footerText)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.54))
        }
        .padding(16)
        .containerBackground(backgroundGradient, for: .widget)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(
                    LinearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 7)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text("Codex 额度")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(entry.isStale ? "等待刷新" : "实时快照")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.54))
            }
            Spacer(minLength: 0)
        }
    }

    private var footerText: String {
        guard let updatedAt = entry.updatedAt else { return "尚无快照" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "更新 \(formatter.localizedString(for: updatedAt, relativeTo: Date()))"
    }

    private var backgroundGradient: some ShapeStyle {
        LinearGradient(
            colors: [
                Color(red: 0.04, green: 0.06, blue: 0.10),
                Color(red: 0.08, green: 0.12, blue: 0.18),
                Color(red: 0.02, green: 0.03, blue: 0.06)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct QuotaBlock: View {
    let title: String
    let subtitle: String
    let value: Int?
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.48))
                }
                Spacer()
                Text(valueText)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
            }
            ProgressView(value: Double(value ?? 0), total: 100)
                .tint(color)
        }
        .padding(11)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.13), lineWidth: 0.8))
    }

    private var valueText: String {
        value.map { "\($0)%" } ?? "--"
    }
}

struct RingMetric: View {
    let title: String
    let value: Int?
    let color: Color

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.70))
            Spacer()
            Text(value.map { "\($0)%" } ?? "--")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }
}

@main
struct CodexQuotaWidgetBundle: WidgetBundle {
    var body: some Widget {
        CodexQuotaWidget()
    }
}

struct CodexQuotaWidget: Widget {
    let kind = "CodexQuotaWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            CodexQuotaWidgetView(entry: entry)
        }
        .configurationDisplayName("Codex 额度")
        .description("在桌面上查看 Codex 5 小时额度和周额度。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct SlotFile: Decodable {
    var slots: [AccountSlot]
}

private struct AccountSlot: Decodable {
    var displayName: String
    var lastSnapshot: QuotaSnapshot?
}

private struct QuotaSnapshot: Decodable {
    var quotaWindows: [QuotaWindow]
    var updatedAt: Date
    var valueFreshness: String
}

private struct QuotaWindow: Decodable {
    var kind: String
    var remainingPercent: Int
}

private extension JSONDecoder {
    static var codexQuota: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let noFraction = ISO8601DateFormatter()
            noFraction.formatOptions = [.withInternetDateTime]
            if let date = withFraction.date(from: value) ?? noFraction.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date")
        }
        return decoder
    }
}
