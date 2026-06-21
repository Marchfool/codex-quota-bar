import CodexQuotaBarSupport
import CoreGraphics
import Foundation

@main
struct CodexQuotaBarFrameTestRunner {
    static func main() throws {
        clampedFrameRespectsMinimumSizeAndVisibleFrame()
        initialFrameUsesDefaultSizeNearTopRightWhenNothingIsStored()
        initialFrameRestoresSavedFrame()
        claudeCookieDomainFilterOnlyAllowsClaudeHosts()
        compactStatusBarTitleUsesShortProviderLabels()
        compactStatusBarDefaultsHideAuxiliaryIndicatorsAfterMigration()
        statusBarQuotaProviderDefaultsPreserveCurrentMainDisplay()
        statusBarQuotaProviderVisibilitySupportsSingleAndMixedProviders()
        statusBarQuotaProviderVisibilityFallsBackWhenEverythingIsDisabled()
        miniMaxBoostedQuotaDisplayUsesRawRemainingBar()
        try widgetSnapshotLoaderReadsCoreProviderMetrics()
        try widgetSnapshotLoaderHandlesMissingFilesAsStale()
        try widgetSnapshotLoaderMarksOldSnapshotsStale()
        try widgetSharedSnapshotRoundTripsCoreMetricsOnly()
        print("All CodexQuotaBar frame tests passed.")
    }

    private static func clampedFrameRespectsMinimumSizeAndVisibleFrame() {
        let restored = CGRect(x: 900, y: 740, width: 100, height: 100)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)

        let frame = DesktopWidgetFrameStore.clampedFrame(restored, visibleFrame: visibleFrame)

        expect(frame.width == 360, "expected width to clamp to minimum")
        expect(frame.height == 420, "expected height to clamp to minimum")
        expect(frame.maxX == visibleFrame.maxX, "expected frame to fit visible maxX")
        expect(frame.maxY == visibleFrame.maxY, "expected frame to fit visible maxY")
    }

    private static func initialFrameUsesDefaultSizeNearTopRightWhenNothingIsStored() {
        let defaults = isolatedDefaults()
        let visibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)

        let frame = DesktopWidgetFrameStore.initialFrame(visibleFrame: visibleFrame, defaults: defaults)

        expect(frame.width == DesktopWidgetFrameStore.defaultSize.width, "expected default width")
        expect(frame.height == DesktopWidgetFrameStore.defaultSize.height, "expected default height")
        expect(frame.maxX == visibleFrame.maxX - 16, "expected default frame near right edge")
        expect(frame.maxY == visibleFrame.maxY - 30, "expected default frame near top edge")
    }

    private static func initialFrameRestoresSavedFrame() {
        let defaults = isolatedDefaults()
        let visibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let saved = CGRect(x: 120, y: 140, width: 420, height: 520)

        DesktopWidgetFrameStore.save(saved, defaults: defaults)
        let frame = DesktopWidgetFrameStore.initialFrame(visibleFrame: visibleFrame, defaults: defaults)

        expect(frame == saved, "expected saved frame to restore unchanged when visible")
    }

    private static func claudeCookieDomainFilterOnlyAllowsClaudeHosts() {
        expect(ClaudeCookieDomainFilter.isAllowedDomain("claude.ai"), "expected apex Claude domain")
        expect(ClaudeCookieDomainFilter.isAllowedDomain(".claude.ai"), "expected cookie domain form")
        expect(ClaudeCookieDomainFilter.isAllowedDomain("console.claude.ai"), "expected Claude subdomain")
        expect(!ClaudeCookieDomainFilter.isAllowedDomain("evilclaude.ai"), "expected suffix lookalike to be rejected")
        expect(!ClaudeCookieDomainFilter.isAllowedDomain("claude.ai.evil.example"), "expected superdomain lookalike to be rejected")
    }

    private static func compactStatusBarTitleUsesShortProviderLabels() {
        let title = CompactStatusBarDisplay.title(codexRemaining: 98, claudeRemaining: 64)

        expect(title == "CX 98% · CL 64%", "expected compact status bar title")
        expect(!title.contains("Codex"), "compact title should not spend menu bar width on full provider names")
        expect(!title.contains("Claude"), "compact title should not spend menu bar width on full provider names")
    }

    private static func compactStatusBarDefaultsHideAuxiliaryIndicatorsAfterMigration() {
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: CompactStatusBarDefaults.trafficLightKey)
        defaults.set(true, forKey: CompactStatusBarDefaults.memoryIndicatorKey)

        CompactStatusBarDefaults.applyCompactMigration(defaults: defaults)

        expect(!CompactStatusBarDefaults.isTrafficLightVisible(defaults: defaults), "expected traffic light to be hidden after compact migration")
        expect(!CompactStatusBarDefaults.isMemoryIndicatorVisible(defaults: defaults), "expected memory indicator to be hidden after compact migration")
    }

    private static func statusBarQuotaProviderDefaultsPreserveCurrentMainDisplay() {
        let defaults = isolatedDefaults()

        expect(
            CompactStatusBarDefaults.visibleQuotaProviders(defaults: defaults) == [.codex, .claude],
            "expected default status bar provider display to preserve Codex + Claude"
        )
        expect(
            !CompactStatusBarDefaults.isQuotaProviderVisible(.minimax, defaults: defaults),
            "expected MiniMax to remain opt-in for the main status bar"
        )
    }

    private static func statusBarQuotaProviderVisibilitySupportsSingleAndMixedProviders() {
        let defaults = isolatedDefaults()
        defaults.set(false, forKey: CompactStatusBarDefaults.showCodexQuotaKey)
        defaults.set(false, forKey: CompactStatusBarDefaults.showClaudeQuotaKey)
        defaults.set(true, forKey: CompactStatusBarDefaults.showMiniMaxQuotaKey)

        expect(
            CompactStatusBarDefaults.visibleQuotaProviders(defaults: defaults) == [.minimax],
            "expected MiniMax-only status bar display"
        )

        defaults.set(true, forKey: CompactStatusBarDefaults.showCodexQuotaKey)

        expect(
            CompactStatusBarDefaults.visibleQuotaProviders(defaults: defaults) == [.codex, .minimax],
            "expected mixed Codex + MiniMax status bar display"
        )
    }

    private static func statusBarQuotaProviderVisibilityFallsBackWhenEverythingIsDisabled() {
        let defaults = isolatedDefaults()
        defaults.set(false, forKey: CompactStatusBarDefaults.showCodexQuotaKey)
        defaults.set(false, forKey: CompactStatusBarDefaults.showClaudeQuotaKey)
        defaults.set(false, forKey: CompactStatusBarDefaults.showMiniMaxQuotaKey)

        expect(
            CompactStatusBarDefaults.visibleQuotaProviders(defaults: defaults) == [.codex],
            "expected empty provider selection to keep the status item usable"
        )
    }

    private static func miniMaxBoostedQuotaDisplayUsesRawRemainingBar() {
        let display = MiniMaxQuotaDisplay.window(
            extras: [
                "intervalRemainingPercent": "98",
                "intervalQuotaTotalPercent": "200",
                "intervalQuotaUsedPercent": "4",
                "intervalQuotaRemainingPercent": "196"
            ],
            remainingKey: "intervalRemainingPercent",
            totalKey: "intervalQuotaTotalPercent",
            usedKey: "intervalQuotaUsedPercent",
            fallbackUsedPercent: 4
        )

        expect(display.summary == "总额200% · 已用4%", "expected boosted quota summary")
        expect(display.meterLabel == "200%", "expected meter label to show boosted total")
        expect(display.barPercent == 98, "expected bar to use raw remaining percent")
        expect(display.trailingLabel == "98%", "expected trailing label to match the bar")
    }

    private static func widgetSnapshotLoaderReadsCoreProviderMetrics() throws {
        let urls = try temporarySnapshotURLs()
        try """
        {
          "slots": [
            {
              "slotID": "codex-a",
              "accountKey": "tenant:account:abc|principal:subject:user",
              "displayName": "user@example.com",
              "isActive": true,
              "lastSnapshot": {
                "accountLabel": "user@example.com",
                "fetchHealth": "ok",
                "limit": 100,
                "note": "Plan plus | 5h 73% | Weekly 41%",
                "quotaWindows": [
                  {"id": "session", "kind": "session", "remainingPercent": 73, "resetAt": "2026-06-05T18:00:00Z", "title": "5h", "usedPercent": 27},
                  {"id": "weekly", "kind": "weekly", "remainingPercent": 41, "resetAt": "2026-06-08T18:00:00Z", "title": "Weekly", "usedPercent": 59}
                ],
                "remaining": 41,
                "source": "codex-official",
                "sourceLabel": "API",
                "status": "ok",
                "unit": "%",
                "updatedAt": "2026-06-05T12:00:00Z",
                "used": 59,
                "valueFreshness": "live"
              }
            }
          ]
        }
        """.write(to: urls.codexURL, atomically: true, encoding: .utf8)

        try """
        {
          "providers": [
            {
              "id": "claude",
              "displayName": "Claude",
              "colorHex": "#E05A2B",
              "fields": [],
              "isEnabled": true,
              "lastSnapshot": {
                "balance": "Claude",
                "usedPercent": 36,
                "status": "ok",
                "updatedAt": "2026-06-05T12:01:00Z",
                "extras": {
                  "fiveHourUsed": "36",
                  "sevenDayUsed": "12"
                }
              }
            },
            {
              "id": "minimax",
              "displayName": "MiniMax",
              "colorHex": "#7C3AED",
              "fields": [],
              "isEnabled": true,
              "lastSnapshot": {
                "balance": "84",
                "usedPercent": 16,
                "status": "ok",
                "updatedAt": "2026-06-05T12:02:00Z",
                "extras": {
                  "intervalRemainingPercent": "98",
                  "intervalQuotaTotalPercent": "200",
                  "intervalQuotaUsedPercent": "4",
                  "intervalQuotaRemainingPercent": "196",
                  "weeklyRemainingPercent": "84"
                }
              }
            }
          ]
        }
        """.write(to: urls.apiURL, atomically: true, encoding: .utf8)

        let snapshot = WidgetQuotaSnapshotLoader.load(
            codexURL: urls.codexURL,
            apiURL: urls.apiURL,
            now: Date(timeIntervalSince1970: 1_780_661_100)
        )

        expect(snapshot.codex.fiveHourRemaining == 73, "expected Codex 5-hour remaining")
        expect(snapshot.codex.weeklyRemaining == 41, "expected Codex weekly remaining")
        expect(snapshot.claude.fiveHourRemaining == 64, "expected Claude five-hour used percent to invert")
        expect(snapshot.claude.weeklyRemaining == 88, "expected Claude weekly used percent to invert")
        expect(snapshot.minimax.fiveHourRemaining == 98, "expected MiniMax widget to use raw interval remaining")
        expect(snapshot.minimax.weeklyRemaining == 84, "expected MiniMax weekly remaining")
    }

    private static func widgetSnapshotLoaderHandlesMissingFilesAsStale() throws {
        let urls = try temporarySnapshotURLs()

        let snapshot = WidgetQuotaSnapshotLoader.load(
            codexURL: urls.codexURL,
            apiURL: urls.apiURL,
            now: Date(timeIntervalSince1970: 1_780_661_100)
        )

        expect(snapshot.codex.fiveHourRemaining == nil, "expected missing Codex file to have no value")
        expect(snapshot.claude.weeklyRemaining == nil, "expected missing API file to have no value")
        expect(snapshot.minimax.isStale, "expected missing MiniMax data to be stale")
    }

    private static func widgetSnapshotLoaderMarksOldSnapshotsStale() throws {
        let urls = try temporarySnapshotURLs()
        try """
        {
          "slots": [
            {
              "slotID": "codex-a",
              "accountKey": "tenant:account:abc|principal:subject:user",
              "displayName": "user@example.com",
              "isActive": true,
              "lastSnapshot": {
                "accountLabel": "user@example.com",
                "fetchHealth": "ok",
                "limit": 100,
                "note": "old",
                "quotaWindows": [
                  {"id": "session", "kind": "session", "remainingPercent": 55, "title": "5h", "usedPercent": 45}
                ],
                "remaining": 55,
                "source": "codex-official",
                "sourceLabel": "API",
                "status": "ok",
                "unit": "%",
                "updatedAt": "2026-06-05T12:00:00Z",
                "used": 45,
                "valueFreshness": "live"
              }
            }
          ]
        }
        """.write(to: urls.codexURL, atomically: true, encoding: .utf8)

        let snapshot = WidgetQuotaSnapshotLoader.load(
            codexURL: urls.codexURL,
            apiURL: urls.apiURL,
            now: Date(timeIntervalSince1970: 1_780_662_601)
        )

        expect(snapshot.codex.fiveHourRemaining == 55, "expected stale snapshots to keep their last value")
        expect(snapshot.codex.isStale, "expected old Codex snapshot to be marked stale")
    }

    private static func widgetSharedSnapshotRoundTripsCoreMetricsOnly() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexQuotaBarFrameTestRunner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("widget_snapshot.json")
        let updatedAt = Date(timeIntervalSince1970: 1_780_661_200)
        let snapshot = WidgetQuotaSnapshot(
            codex: WidgetQuotaMetric(provider: .codex, fiveHourRemaining: 60, weeklyRemaining: 65, updatedAt: updatedAt, isStale: false),
            claude: WidgetQuotaMetric(provider: .claude, fiveHourRemaining: 0, weeklyRemaining: 59, updatedAt: updatedAt, isStale: false),
            minimax: WidgetQuotaMetric(provider: .minimax, fiveHourRemaining: 99, weeklyRemaining: 94, updatedAt: updatedAt, isStale: false)
        )

        try WidgetQuotaSnapshotLoader.saveSharedSnapshot(snapshot, urls: [url])
        let loaded = WidgetQuotaSnapshotLoader.loadSharedSnapshot(
            url: url,
            now: Date(timeIntervalSince1970: 1_780_661_260)
        )

        expect(loaded == snapshot, "expected shared widget snapshot to round trip")
        let text = try String(contentsOf: url, encoding: .utf8)
        expect(!text.contains("apiKey"), "shared widget snapshot should not contain API key fields")
        expect(!text.contains("accountKey"), "shared widget snapshot should not contain account keys")
        expect(!text.contains("rawMeta"), "shared widget snapshot should not contain raw provider metadata")
    }

    private static func isolatedDefaults() -> UserDefaults {
        let suiteName = "CodexQuotaBarFrameTestRunner.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("expected isolated defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private static func temporarySnapshotURLs() throws -> (codexURL: URL, apiURL: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexQuotaBarFrameTestRunner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (
            directory.appendingPathComponent("codex_slots.json"),
            directory.appendingPathComponent("api_keys.json")
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fatalError(message)
        }
    }
}
