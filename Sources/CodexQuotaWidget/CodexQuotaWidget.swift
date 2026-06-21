import Foundation
import AppKit
import SwiftUI
import WidgetKit

struct QuotaEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetQuotaSnapshot
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> QuotaEntry {
        QuotaEntry(
            date: Date(),
            snapshot: WidgetQuotaSnapshot(
                codex: WidgetQuotaMetric(provider: .codex, fiveHourRemaining: 84, weeklyRemaining: 98, updatedAt: Date(), isStale: false),
                claude: WidgetQuotaMetric(provider: .claude, fiveHourRemaining: 64, weeklyRemaining: 88, updatedAt: Date(), isStale: false),
                minimax: WidgetQuotaMetric(provider: .minimax, fiveHourRemaining: 98, weeklyRemaining: 84, updatedAt: Date(), isStale: false)
            )
        )
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
        QuotaEntry(date: Date(), snapshot: WidgetQuotaSnapshotLoader.load())
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
        VStack(alignment: .leading, spacing: 8) {
            header
            Spacer(minLength: 2)
            CompactProviderRow(title: "Codex", metric: entry.snapshot.codex, color: .cyan)
            CompactProviderRow(title: "Claude", metric: entry.snapshot.claude, color: .orange)
        }
        .padding(13)
        .containerBackground(backgroundGradient, for: .widget)
    }

    private var mediumView: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            VStack(spacing: 5) {
                MediumProviderQuotaRow(title: "Codex", metric: entry.snapshot.codex, color: .cyan)
                MediumProviderQuotaRow(title: "Claude", metric: entry.snapshot.claude, color: .orange)
                MediumProviderQuotaRow(title: "MiniMax", metric: entry.snapshot.minimax, color: .purple)
            }
            Text(footerText)
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(.white.opacity(0.54))
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 10, trailing: 14))
        .containerBackground(backgroundGradient, for: .widget)
    }

    private var header: some View {
        HStack(spacing: 8) {
            codexIcon
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Codex 额度")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(isAnyStale ? "等待刷新" : "核心额度快照")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.54))
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var codexIcon: some View {
        CodexAppIconView()
    }

    private var footerText: String {
        guard let updatedAt = latestUpdatedAt else { return "等待快照" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: updatedAt)
        return isSnapshotOld ? "数据较旧 · \(time)" : "快照 \(time)"
    }

    private var latestUpdatedAt: Date? {
        [
            entry.snapshot.codex.updatedAt,
            entry.snapshot.claude.updatedAt,
            entry.snapshot.minimax.updatedAt
        ].compactMap { $0 }.max()
    }

    private var isAnyStale: Bool {
        entry.snapshot.codex.isStale || entry.snapshot.claude.isStale || entry.snapshot.minimax.isStale
    }

    private var isSnapshotOld: Bool {
        guard let updatedAt = latestUpdatedAt else { return true }
        return Date().timeIntervalSince(updatedAt) > 600 || isAnyStale
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

private struct CodexAppIconView: View {
    @Environment(\.widgetRenderingMode) private var widgetRenderingMode

    var body: some View {
        Group {
            if let image = CodexAppIconAsset.image {
                if widgetRenderingMode == WidgetRenderingMode.fullColor {
                    fullColorAppIcon(image)
                } else {
                    desaturatedAppIcon(image)
                }
            } else {
                fallbackIcon(isFullColor: widgetRenderingMode == WidgetRenderingMode.fullColor)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func fullColorAppIcon(_ image: NSImage) -> some View {
        if #available(macOS 15.0, *) {
            Image(nsImage: image)
                .renderingMode(.original)
                .resizable()
                .interpolation(.high)
                .widgetAccentedRenderingMode(WidgetAccentedRenderingMode.fullColor)
                .aspectRatio(contentMode: ContentMode.fit)
        } else {
            Image(nsImage: image)
                .renderingMode(.original)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: ContentMode.fit)
        }
    }

    @ViewBuilder
    private func desaturatedAppIcon(_ image: NSImage) -> some View {
        if #available(macOS 15.0, *) {
            Image(nsImage: image)
                .renderingMode(.original)
                .resizable()
                .interpolation(.high)
                .widgetAccentedRenderingMode(WidgetAccentedRenderingMode.desaturated)
                .saturation(0)
                .contrast(1.16)
                .brightness(0.04)
                .aspectRatio(contentMode: ContentMode.fit)
        } else {
            Image(nsImage: image)
                .renderingMode(.original)
                .resizable()
                .interpolation(.high)
                .saturation(0)
                .contrast(1.16)
                .brightness(0.04)
                .aspectRatio(contentMode: ContentMode.fit)
        }
    }

    private func fallbackIcon(isFullColor: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(isFullColor ? Color.white.opacity(0.96) : Color(red: 0.78, green: 0.86, blue: 0.91).opacity(0.95))
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    LinearGradient(
                        colors: isFullColor ? [
                            Color(red: 0.50, green: 0.44, blue: 1.0),
                            Color(red: 0.18, green: 0.42, blue: 1.0)
                        ] : [
                            Color(red: 0.43, green: 0.58, blue: 0.66),
                            Color(red: 0.26, green: 0.40, blue: 0.49)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 21, height: 17)
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(isFullColor ? .white : Color(red: 0.86, green: 0.93, blue: 0.96))
                .offset(x: -4)
            Rectangle()
                .fill(isFullColor ? .white : Color(red: 0.86, green: 0.93, blue: 0.96))
                .frame(width: 7, height: 1.6)
                .offset(x: 4, y: 4)
        }
        .widgetAccentable(false)
    }
}

private enum CodexAppIconAsset {
    static var image: NSImage? {
        let candidates = [
            Bundle.main.url(forResource: "CodexAppIcon", withExtension: "png"),
            Bundle.main.resourceURL?.appendingPathComponent("CodexAppIcon.png"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/CodexAppIcon.png")
        ].compactMap { $0 }

        for url in candidates {
            if let image = NSImage(contentsOf: url) {
                image.isTemplate = false
                return image
            }
        }
        if let image = NSImage(named: "CodexAppIcon") {
            image.isTemplate = false
            return image
        }
        return nil
    }
}

struct MediumProviderQuotaRow: View {
    let title: String
    let metric: WidgetQuotaMetric
    let color: Color

    var body: some View {
        HStack(spacing: 7) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color.opacity(metric.isStale ? 0.42 : 0.95))
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.86)
                    .foregroundStyle(.white.opacity(0.86))
            }
            .frame(width: 66, alignment: .leading)

            WidgetMetricPill(label: "5h", value: metric.fiveHourRemaining, color: color)
            WidgetMetricPill(label: "W", value: metric.weeklyRemaining, color: color)
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.12), lineWidth: 0.7))
    }
}

struct WidgetMetricPill: View {
    @Environment(\.widgetRenderingMode) private var widgetRenderingMode
    let label: String
    let value: Int?
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.white.opacity(0.50))
                .frame(width: 16, alignment: .leading)
            QuotaBar(value: value, color: color, showsTrack: widgetRenderingMode == WidgetRenderingMode.fullColor)
                .frame(maxWidth: .infinity)
            Text(valueText(value))
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(value == nil ? .white.opacity(0.38) : valueColor)
                .frame(width: 34, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
    }

    private var valueColor: Color {
        widgetRenderingMode == WidgetRenderingMode.fullColor ? color : .white.opacity(0.86)
    }

    private func valueText(_ value: Int?) -> String {
        value.map { "\($0)%" } ?? "--"
    }
}

struct QuotaBar: View {
    let value: Int?
    let color: Color
    let showsTrack: Bool

    private var percent: CGFloat {
        CGFloat(min(100, max(0, value ?? 0))) / 100
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                if showsTrack {
                    Capsule()
                        .fill(.white.opacity(0.36))
                        .frame(width: proxy.size.width, height: 4)
                }
                if value != nil {
                    Capsule()
                        .fill(fillColor)
                        .frame(width: max(3, proxy.size.width * percent), height: 4)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
        .frame(height: 6)
    }

    private var fillColor: Color {
        showsTrack ? color : .white.opacity(0.82)
    }
}

struct ProviderQuotaBlock: View {
    @Environment(\.widgetRenderingMode) private var widgetRenderingMode
    let title: String
    let metric: WidgetQuotaMetric
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Circle()
                    .fill(color.opacity(metric.isStale ? 0.42 : 0.95))
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
            }
            metricLine(label: "5h", value: metric.fiveHourRemaining)
            metricLine(label: "W", value: metric.weeklyRemaining)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.13), lineWidth: 0.8))
    }

    private func metricLine(label: String, value: Int?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.48))
                Spacer()
                Text(valueText(value))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(value == nil ? .white.opacity(0.38) : color)
            }
            QuotaBar(value: value, color: color, showsTrack: widgetRenderingMode == WidgetRenderingMode.fullColor)
        }
    }

    private func valueText(_ value: Int?) -> String {
        value.map { "\($0)%" } ?? "--"
    }
}

struct CompactProviderRow: View {
    let title: String
    let metric: WidgetQuotaMetric
    let color: Color

    var body: some View {
        HStack {
            Circle()
                .fill(color.opacity(metric.isStale ? 0.42 : 0.95))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
                Text("5h \(valueText(metric.fiveHourRemaining))  W \(valueText(metric.weeklyRemaining))")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.52))
            }
            Spacer()
            Text(valueText(metric.fiveHourRemaining))
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(metric.fiveHourRemaining == nil ? .white.opacity(0.38) : color)
        }
    }

    private func valueText(_ value: Int?) -> String {
        value.map { "\($0)%" } ?? "--"
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
        .description("在桌面上查看 Codex、Claude 与 MiniMax 核心额度。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
