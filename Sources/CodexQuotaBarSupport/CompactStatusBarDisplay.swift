import Foundation

public enum StatusBarQuotaProvider: String, CaseIterable, Sendable {
    case codex
    case claude
    case minimax
}

public enum CompactStatusBarDisplay {
    public static func title(codexRemaining: Int?, claudeRemaining: Int?) -> String {
        "CX \(percentText(codexRemaining)) · CL \(percentText(claudeRemaining))"
    }

    public static func percentText(_ percent: Int?) -> String {
        guard let percent else { return "--" }
        return "\(min(100, max(0, percent)))%"
    }
}

public enum CompactStatusBarDefaults {
    public static let trafficLightKey = "showCodexTrafficLight"
    public static let memoryIndicatorKey = "showMemoryIndicator"
    public static let showCodexQuotaKey = "statusBarShowCodex"
    public static let showClaudeQuotaKey = "statusBarShowClaude"
    public static let showMiniMaxQuotaKey = "statusBarShowMiniMax"
    public static let migrationVersionKey = "compactStatusBarMigrationVersion"

    private static let currentMigrationVersion = 1

    public static func applyCompactMigration(defaults: UserDefaults = .standard) {
        guard defaults.integer(forKey: migrationVersionKey) < currentMigrationVersion else { return }

        defaults.set(false, forKey: trafficLightKey)
        defaults.set(false, forKey: memoryIndicatorKey)
        defaults.set(currentMigrationVersion, forKey: migrationVersionKey)
    }

    public static func isTrafficLightVisible(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: trafficLightKey) as? Bool ?? false
    }

    public static func isMemoryIndicatorVisible(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: memoryIndicatorKey) as? Bool ?? false
    }

    public static func isQuotaProviderVisible(
        _ provider: StatusBarQuotaProvider,
        defaults: UserDefaults = .standard
    ) -> Bool {
        switch provider {
        case .codex:
            return defaults.object(forKey: showCodexQuotaKey) as? Bool ?? true
        case .claude:
            return defaults.object(forKey: showClaudeQuotaKey) as? Bool ?? true
        case .minimax:
            return defaults.object(forKey: showMiniMaxQuotaKey) as? Bool ?? false
        }
    }

    public static func visibleQuotaProviders(defaults: UserDefaults = .standard) -> [StatusBarQuotaProvider] {
        let providers = StatusBarQuotaProvider.allCases.filter {
            isQuotaProviderVisible($0, defaults: defaults)
        }
        return providers.isEmpty ? [.codex] : providers
    }
}
