import Foundation

public enum WidgetQuotaProvider: String, Codable, Sendable {
    case codex
    case claude
    case minimax
}

public struct WidgetQuotaMetric: Codable, Equatable, Sendable {
    public var provider: WidgetQuotaProvider
    public var fiveHourRemaining: Int?
    public var weeklyRemaining: Int?
    public var updatedAt: Date?
    public var isStale: Bool

    public init(
        provider: WidgetQuotaProvider,
        fiveHourRemaining: Int? = nil,
        weeklyRemaining: Int? = nil,
        updatedAt: Date? = nil,
        isStale: Bool = true
    ) {
        self.provider = provider
        self.fiveHourRemaining = fiveHourRemaining
        self.weeklyRemaining = weeklyRemaining
        self.updatedAt = updatedAt
        self.isStale = isStale
    }
}

public struct WidgetQuotaSnapshot: Codable, Equatable, Sendable {
    public var codex: WidgetQuotaMetric
    public var claude: WidgetQuotaMetric
    public var minimax: WidgetQuotaMetric

    public init(
        codex: WidgetQuotaMetric = WidgetQuotaMetric(provider: .codex),
        claude: WidgetQuotaMetric = WidgetQuotaMetric(provider: .claude),
        minimax: WidgetQuotaMetric = WidgetQuotaMetric(provider: .minimax)
    ) {
        self.codex = codex
        self.claude = claude
        self.minimax = minimax
    }
}

public enum WidgetQuotaSnapshotLoader {
    private static let appSupportDirectoryName = "CodexQuotaBar"
    private static let sharedSnapshotFileName = "widget_snapshot.json"
    private static let appGroupIdentifier = "group.com.codexquotabar.app"
    private static let widgetBundleIdentifier = "com.codexquotabar.app.widget"

    public static var defaultSharedSnapshotURL: URL {
        appGroupSharedSnapshotURL
            ?? applicationSupportDirectory()
            .appendingPathComponent(appSupportDirectoryName, isDirectory: true)
            .appendingPathComponent(sharedSnapshotFileName)
    }

    public static var userHomeSharedSnapshotURL: URL {
        loginHomeDirectory()
            .appendingPathComponent("Library/Application Support/\(appSupportDirectoryName)/\(sharedSnapshotFileName)")
    }

    public static var widgetContainerSharedSnapshotURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(widgetBundleIdentifier)/Data/Library/Application Support/\(appSupportDirectoryName)/\(sharedSnapshotFileName)")
    }

    public static var defaultSharedSnapshotWriteURLs: [URL] {
        uniqueURLs([
            appGroupSharedSnapshotURL,
            applicationSupportDirectory()
                .appendingPathComponent(appSupportDirectoryName, isDirectory: true)
                .appendingPathComponent(sharedSnapshotFileName),
            userHomeSharedSnapshotURL
        ].compactMap { $0 })
    }

    public static var defaultSharedSnapshotReadURLs: [URL] {
        uniqueURLs([
            appGroupSharedSnapshotURL,
            applicationSupportDirectory()
                .appendingPathComponent(appSupportDirectoryName, isDirectory: true)
                .appendingPathComponent(sharedSnapshotFileName),
            userHomeSharedSnapshotURL
        ].compactMap { $0 })
    }

    public static var defaultCodexURL: URL {
        loginHomeDirectory()
            .appendingPathComponent("Library/Application Support/CodexQuotaBar/codex_slots.json")
    }

    public static var defaultAPIURL: URL {
        loginHomeDirectory()
            .appendingPathComponent("Library/Application Support/CodexQuotaBar/api_keys.json")
    }

    public static func load(
        codexURL: URL = defaultCodexURL,
        apiURL: URL = defaultAPIURL,
        now: Date = Date()
    ) -> WidgetQuotaSnapshot {
        if shouldPreferSharedSnapshot(codexURL: codexURL, apiURL: apiURL),
           let snapshot = loadSharedSnapshot(now: now) {
            return snapshot
        }
        return loadFromSourceFiles(codexURL: codexURL, apiURL: apiURL, now: now)
    }

    public static func loadFromSourceFiles(
        codexURL: URL = defaultCodexURL,
        apiURL: URL = defaultAPIURL,
        now: Date = Date()
    ) -> WidgetQuotaSnapshot {
        WidgetQuotaSnapshot(
            codex: loadCodexMetric(from: codexURL, now: now),
            claude: loadAPIMetric(providerID: "claude", from: apiURL, now: now),
            minimax: loadAPIMetric(providerID: "minimax", from: apiURL, now: now)
        )
    }

    public static func loadSharedSnapshot(
        url: URL = defaultSharedSnapshotURL,
        now: Date = Date()
    ) -> WidgetQuotaSnapshot? {
        if equivalent(url, defaultSharedSnapshotURL) {
            for candidate in defaultSharedSnapshotReadURLs {
                if let snapshot = loadSharedSnapshotFile(url: candidate, now: now) {
                    return snapshot
                }
            }
            return nil
        }
        return loadSharedSnapshotFile(url: url, now: now)
    }

    private static func loadSharedSnapshotFile(
        url: URL,
        now: Date
    ) -> WidgetQuotaSnapshot? {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? decoder.decode(WidgetQuotaSnapshot.self, from: data)
        else {
            return nil
        }
        return snapshotWithCurrentStaleFlags(snapshot, now: now)
    }

    public static func saveSharedSnapshot(
        _ snapshot: WidgetQuotaSnapshot,
        urls: [URL] = defaultSharedSnapshotWriteURLs
    ) throws {
        let data = try encoder.encode(snapshot)
        for url in uniqueURLs(urls) {
            try write(data, to: url)
        }
    }

    private static func shouldPreferSharedSnapshot(codexURL: URL, apiURL: URL) -> Bool {
        equivalent(codexURL, defaultCodexURL) && equivalent(apiURL, defaultAPIURL)
    }

    private static func applicationSupportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    private static func loginHomeDirectory() -> URL {
        if let home = NSHomeDirectoryForUser(NSUserName()), !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private static var appGroupSharedSnapshotURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent(appSupportDirectoryName, isDirectory: true)
            .appendingPathComponent(sharedSnapshotFileName)
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { url in
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else { return false }
            seen.insert(path)
            return true
        }
    }

    private static func equivalent(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }

    private static func write(_ data: Data, to url: URL) throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = directory
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
            .appendingPathExtension("tmp")
        do {
            try data.write(to: temporaryURL, options: [.atomic])
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL, backupItemName: nil, options: [.usingNewMetadataOnly])
            } else {
                try fileManager.moveItem(at: temporaryURL, to: url)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private static func snapshotWithCurrentStaleFlags(_ snapshot: WidgetQuotaSnapshot, now: Date) -> WidgetQuotaSnapshot {
        WidgetQuotaSnapshot(
            codex: metricWithCurrentStaleFlag(snapshot.codex, now: now),
            claude: metricWithCurrentStaleFlag(snapshot.claude, now: now),
            minimax: metricWithCurrentStaleFlag(snapshot.minimax, now: now)
        )
    }

    private static func metricWithCurrentStaleFlag(_ metric: WidgetQuotaMetric, now: Date) -> WidgetQuotaMetric {
        WidgetQuotaMetric(
            provider: metric.provider,
            fiveHourRemaining: metric.fiveHourRemaining,
            weeklyRemaining: metric.weeklyRemaining,
            updatedAt: metric.updatedAt,
            isStale: metric.fiveHourRemaining == nil && metric.weeklyRemaining == nil || metric.isStale || isOld(metric.updatedAt, now: now)
        )
    }

    private static func loadCodexMetric(from url: URL, now: Date) -> WidgetQuotaMetric {
        guard let data = try? Data(contentsOf: url),
              let file = try? decoder.decode(CodexSlotFile.self, from: data)
        else {
            return WidgetQuotaMetric(provider: .codex)
        }

        let snapshots = (file.slots ?? [])
            .filter { $0.isActive ?? true }
            .compactMap(\.lastSnapshot)
        let sessionValues = snapshots.compactMap { snapshot in
            snapshot.quotaWindows?.first(where: { $0.kind == "session" })?.remainingPercent
        }
        let weeklyValues = snapshots.compactMap { snapshot in
            snapshot.quotaWindows?.first(where: { $0.kind == "weekly" })?.remainingPercent
        }
        let updatedAt = snapshots.compactMap(\.updatedAt).max()
        let hasValue = !sessionValues.isEmpty || !weeklyValues.isEmpty
        let isExplicitlyStale = snapshots.contains { snapshot in
            snapshot.valueFreshness == "stale" || snapshot.fetchHealth == "stale" || snapshot.fetchHealth == "error" || snapshot.status == "error"
        }

        return WidgetQuotaMetric(
            provider: .codex,
            fiveHourRemaining: sessionValues.min().map(clampPercent),
            weeklyRemaining: weeklyValues.min().map(clampPercent),
            updatedAt: updatedAt,
            isStale: !hasValue || isExplicitlyStale || isOld(updatedAt, now: now)
        )
    }

    private static func loadAPIMetric(providerID: String, from url: URL, now: Date) -> WidgetQuotaMetric {
        let provider = WidgetQuotaProvider(rawValue: providerID) ?? .claude
        guard let data = try? Data(contentsOf: url),
              let file = try? decoder.decode(APIConfigFile.self, from: data),
              let config = (file.providers ?? []).first(where: { $0.id == providerID }),
              config.isEnabled ?? true,
              let snapshot = config.lastSnapshot
        else {
            return WidgetQuotaMetric(provider: provider)
        }

        switch provider {
        case .claude:
            return WidgetQuotaMetric(
                provider: .claude,
                fiveHourRemaining: invertedUsedPercent(snapshot.extras?["fiveHourUsed"]),
                weeklyRemaining: invertedUsedPercent(snapshot.extras?["sevenDayUsed"]),
                updatedAt: snapshot.updatedAt,
                isStale: isAPIStale(snapshot, now: now)
            )
        case .minimax:
            return WidgetQuotaMetric(
                provider: .minimax,
                fiveHourRemaining: intPercent(snapshot.extras?["intervalRemainingPercent"])
                    ?? max(0, 100 - clampPercent(snapshot.usedPercent ?? 100)),
                weeklyRemaining: intPercent(snapshot.extras?["weeklyRemainingPercent"]),
                updatedAt: snapshot.updatedAt,
                isStale: isAPIStale(snapshot, now: now)
            )
        case .codex:
            return WidgetQuotaMetric(provider: .codex)
        }
    }

    private static func isAPIStale(_ snapshot: APISnapshot, now: Date) -> Bool {
        let setupState = snapshot.extras?["setupState"]
        return snapshot.status == "error"
            || setupState == "fetchFailed"
            || isOld(snapshot.updatedAt, now: now)
    }

    private static func isOld(_ updatedAt: Date?, now: Date) -> Bool {
        guard let updatedAt else { return true }
        return now.timeIntervalSince(updatedAt) > 600
    }

    private static func invertedUsedPercent(_ value: String?) -> Int? {
        intPercent(value).map { max(0, 100 - $0) }
    }

    private static func intPercent(_ value: String?) -> Int? {
        guard let value, let intValue = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return clampPercent(intValue)
    }

    private static func clampPercent(_ value: Int) -> Int {
        min(100, max(0, value))
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = parseISO8601(value) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date")
        }
        return decoder
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatISO8601(date))
        }
        return encoder
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let noFraction = ISO8601DateFormatter()
        noFraction.formatOptions = [.withInternetDateTime]
        return withFraction.date(from: value) ?? noFraction.date(from: value)
    }

    private static func formatISO8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private struct CodexSlotFile: Decodable {
    var slots: [CodexAccountSlot]?
}

private struct CodexAccountSlot: Decodable {
    var isActive: Bool?
    var lastSnapshot: CodexSnapshot?
}

private struct CodexSnapshot: Decodable {
    var fetchHealth: String?
    var quotaWindows: [CodexQuotaWindow]?
    var status: String?
    var updatedAt: Date?
    var valueFreshness: String?
}

private struct CodexQuotaWindow: Decodable {
    var kind: String?
    var remainingPercent: Int?
}

private struct APIConfigFile: Decodable {
    var providers: [APIProviderConfig]?
}

private struct APIProviderConfig: Decodable {
    var id: String?
    var isEnabled: Bool?
    var lastSnapshot: APISnapshot?
}

private struct APISnapshot: Decodable {
    var usedPercent: Int?
    var status: String?
    var updatedAt: Date?
    var extras: [String: String]?
}
