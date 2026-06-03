import CodexQuotaCore
import Foundation

@main
struct TestRunner {
    static func main() async throws {
        try decodesExistingQuotaWindowShape()
        try providerDecodesFlexibleSchema()
        try providerDecodesWhamUsageSchema()
        try providerDecodesSparkRateLimitBucket()
        try providerMergesSupplementalSparkRateLimitResponse()
        try llmBalanceProviderDecodesSamples()
        formattersClampPercent()
        formattersUseReadableChineseUpdatedText()
        await lowestRemainingUsesTightestAccount()
        await statusBarPrefersSessionWindow()
        authErrorDoesNotDriveStatusBar()
        claudeStatusBarValueUsesFiveHourWindow()
        await refreshFailureKeepsStaleSnapshot()
        try persistedSnapshotDoesNotContainSecrets()
        try profileStoreDoesNotPersistAuthJSON()
        try codexCredentialFingerprintIgnoresTokenRotation()
        try codexImportStoresClientIDFromAccessTokenWhenIDTokenOmitsIt()
        try apiKeyStoreDoesNotPersistSecureValues()
        try minimaxPrefersResponseRemainingPercentWhenCountsAreZero()
        try minimaxDecodesResponseResetTimes()
        await launchRefreshSkipsSecureProviderReadsButUpdatesClaude()
        await launchRefreshUsesNonInteractiveSecretReads()
        copyAvailabilityUsesSnapshotsOnly()
        await claudeAutoRefreshUsesNonInteractivePath()
        await claudeAutoRefreshPreservesDOMOnlyRoutineMetrics()
        await claudeRefreshFailureKeepsLastUsageSnapshot()
        claudeErrorSnapshotsAreActionable()
        markedReadyPreservesExistingMetrics()
        print("All CodexQuotaCore tests passed.")
    }

    static func decodesExistingQuotaWindowShape() throws {
        let json = """
        {
          "slots": [
            {
              "accountKey": "tenant:account:abc|principal:subject:user",
              "displayName": "user@example.com",
              "isActive": true,
              "lastSeenAt": "2026-05-10T03:40:50Z",
              "lastSnapshot": {
                "accountLabel": "user@example.com",
                "extras": {"creditsBalance": "0.00", "planType": "plus"},
                "fetchHealth": "ok",
                "limit": 100,
                "note": "Plan plus | 5h 99% | Weekly 0%",
                "quotaWindows": [
                  {"id": "codex-official-session", "kind": "session", "remainingPercent": 99, "resetAt": "2026-05-10T08:40:50Z", "title": "5h", "usedPercent": 1},
                  {"id": "codex-official-weekly", "kind": "weekly", "remainingPercent": 0, "resetAt": "2026-05-12T13:11:51Z", "title": "Weekly", "usedPercent": 100}
                ],
                "rawMeta": {"codex.slotID": "A"},
                "remaining": 0,
                "source": "codex-official",
                "sourceLabel": "API",
                "status": "warning",
                "unit": "%",
                "updatedAt": "2026-05-10T03:40:50Z",
                "used": 1,
                "valueFreshness": "live"
              },
              "slotID": "A"
            }
          ]
        }
        """

        let file = try DateCoding.jsonDecoder.decode(SlotFile.self, from: Data(json.utf8))
        expect(file.slots.count == 1, "expected one slot")
        expect(file.slots[0].lastSnapshot?.quotaWindows.count == 2, "expected two quota windows")
        expect(file.slots[0].lastSnapshot?.quotaWindows[1].kind == .weekly, "expected weekly window")
        expect(file.slots[0].lastSnapshot?.remaining == 0, "expected exhausted weekly quota")
    }

    static func providerDecodesFlexibleSchema() throws {
        let provider = OfficialCodexProvider(secretStore: MemorySecretStore())
        let slot = AccountSlot(slotID: "A", accountKey: "key", displayName: "user@example.com", accountID: "acct")
        let json = """
        {
          "data": {
            "planType": "plus",
            "creditsBalance": "0.00",
            "quotaWindows": [
              {"kind": "session", "title": "5h", "remainingPercent": 70, "usedPercent": 30, "resetAt": "2026-05-10T08:40:50Z"},
              {"kind": "weekly", "title": "Weekly", "remainingPercent": 12, "usedPercent": 88, "resetAt": "2026-05-12T13:11:51Z"}
            ]
          }
        }
        """

        let snapshot = try provider.decodeSnapshot(data: Data(json.utf8), slot: slot)
        expect(snapshot.remaining == 12, "expected tightest remaining quota")
        expect(snapshot.used == 88, "expected highest used quota")
        expect(snapshot.status == .warning, "expected warning under 20%")
        expect(snapshot.extras["planType"] == "plus", "expected plan type")
    }

    static func providerDecodesWhamUsageSchema() throws {
        let provider = OfficialCodexProvider(secretStore: MemorySecretStore())
        let slot = AccountSlot(slotID: "A", accountKey: "key", displayName: "user@example.com", accountID: "acct")
        let json = """
        {
          "user_id": "user-123",
          "account_id": "acct-123",
          "email": "user@example.com",
          "plan_type": "prolite",
          "rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": {
              "used_percent": 13,
              "limit_window_seconds": 18000,
              "reset_after_seconds": 11644,
              "reset_at": 1778406572
            },
            "secondary_window": {
              "used_percent": 2,
              "limit_window_seconds": 604800,
              "reset_after_seconds": 598444,
              "reset_at": 1778993372
            }
          }
        }
        """

        let snapshot = try provider.decodeSnapshot(data: Data(json.utf8), slot: slot)
        expect(snapshot.remaining == 87, "expected primary 5h remaining to be 100 - used")
        expect(snapshot.quotaWindows[0].kind == .session, "expected primary window to map to session")
        expect(snapshot.quotaWindows[1].remainingPercent == 98, "expected secondary weekly remaining")
        expect(snapshot.extras["planType"] == "prolite", "expected snake_case plan type")
    }

    static func providerDecodesSparkRateLimitBucket() throws {
        let provider = OfficialCodexProvider(secretStore: MemorySecretStore())
        let slot = AccountSlot(slotID: "A", accountKey: "key", displayName: "user@example.com", accountID: "acct")
        let json = """
        {
          "email": "user@example.com",
          "planType": "prolite",
          "rateLimits": {
            "limitId": "codex",
            "primary": {"usedPercent": 23, "windowDurationMins": 300, "resetsAt": 1780214850},
            "secondary": {"usedPercent": 4, "windowDurationMins": 10080, "resetsAt": 1780797498}
          },
          "rateLimitsByLimitId": {
            "codex_bengalfox": {
              "limitId": "codex_bengalfox",
              "limitName": "GPT-5.3-Codex-Spark",
              "primary": {"usedPercent": 0, "windowDurationMins": 300, "resetsAt": 1780226011},
              "secondary": {"usedPercent": 0, "windowDurationMins": 10080, "resetsAt": 1780812811}
            },
            "codex": {
              "limitId": "codex",
              "primary": {"usedPercent": 23, "windowDurationMins": 300, "resetsAt": 1780214850},
              "secondary": {"usedPercent": 4, "windowDurationMins": 10080, "resetsAt": 1780797498}
            }
          }
        }
        """

        let snapshot = try provider.decodeSnapshot(data: Data(json.utf8), slot: slot)
        let sparkWindows = snapshot.quotaWindows.filter { $0.title.hasPrefix("Spark") }

        expect(snapshot.remaining == 77, "main Codex remaining should stay tied to the standard 5-hour bucket")
        expect(sparkWindows.count == 2, "expected Spark 5-hour and weekly windows")
        expect(sparkWindows.map(\.remainingPercent) == [100, 100], "expected unused Spark windows to render as full")
        expect(sparkWindows.map(\.title) == ["Spark 5小时", "Spark 每周"], "expected Chinese Spark labels for the card")
    }

    static func providerMergesSupplementalSparkRateLimitResponse() throws {
        let provider = OfficialCodexProvider(secretStore: MemorySecretStore())
        let slot = AccountSlot(slotID: "A", accountKey: "key", displayName: "user@example.com", accountID: "acct")
        let whamJSON = """
        {
          "email": "user@example.com",
          "plan_type": "prolite",
          "rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": {"used_percent": 23, "reset_at": 1780214850},
            "secondary_window": {"used_percent": 4, "reset_at": 1780797498}
          }
        }
        """
        let appServerJSON = """
        {
          "id": 2,
          "result": {
            "rateLimitsByLimitId": {
              "codex_bengalfox": {
                "limitId": "codex_bengalfox",
                "limitName": "GPT-5.3-Codex-Spark",
                "primary": {"usedPercent": 0, "resetsAt": 1780226011},
                "secondary": {"usedPercent": 0, "resetsAt": 1780812811}
              }
            }
          }
        }
        """

        let snapshot = try provider.decodeSnapshot(data: Data(whamJSON.utf8), slot: slot)
        let merged = try provider.mergeSupplementalRateLimits(data: Data(appServerJSON.utf8), into: snapshot)

        expect(snapshot.quotaWindows.filter { $0.title.hasPrefix("Spark") }.isEmpty, "legacy wham usage should not contain Spark")
        expect(merged.remaining == 77, "supplemental Spark should not change standard Codex remaining")
        expect(merged.quotaWindows.map(\.title) == ["5h", "Weekly", "Spark 5小时", "Spark 每周"], "expected supplemental Spark windows appended to card data")
    }

    static func formattersClampPercent() {
        expect(QuotaFormatters.percentText(-10) == "0%", "negative percentages should clamp")
        expect(QuotaFormatters.percentText(110) == "100%", "over-limit percentages should clamp")
        expect(QuotaFormatters.percentText(42) == "42%", "normal percentages should pass through")
    }

    static func formattersUseReadableChineseUpdatedText() {
        let now = Date(timeIntervalSince1970: 1_000)
        expect(QuotaFormatters.updatedText(now, now: now) == "刚刚更新", "fresh updates should read naturally")
        expect(
            QuotaFormatters.updatedText(Date(timeIntervalSince1970: 940), now: now) == "更新于 1 分钟前",
            "minute-old updates should use Chinese before phrasing"
        )
    }

    static func llmBalanceProviderDecodesSamples() throws {
        let provider = LLMBalanceProvider()
        let deepseek = try provider.decodeBalance(data: Data("""
        {
          "is_available": true,
          "balance_infos": [
            {"currency": "CNY", "total_balance": "12.50", "granted_balance": "10.00", "topped_up_balance": "5.00"}
          ]
        }
        """.utf8), providerID: .deepseek)
        expect(deepseek.balance == "¥12.50", "expected DeepSeek balance")
        expect(deepseek.usedPercent == 0, "expected DeepSeek to clamp balance over the default full reference")
        expect(deepseek.extras["remainingPercent"] == "100", "expected DeepSeek remaining percent")
        expect(deepseek.extras["grantedBalance"] == "¥10.00", "expected DeepSeek granted balance")
        expect(deepseek.extras["toppedUpBalance"] == "¥5.00", "expected DeepSeek topped up balance")

        let minimax = try provider.decodeBalance(data: Data("""
        {
          "base_resp": {"status_code": 0, "status_msg": ""},
          "model_remains": [
            {
              "model_name": "MiniMax-M1",
              "current_weekly_total_count": 100,
              "current_weekly_usage_count": 25,
              "current_interval_total_count": 20,
              "current_interval_usage_count": 5,
              "remains_time": 5400000
            }
          ]
        }
        """.utf8), providerID: .minimax)
        expect(minimax.balance == "75", "expected MiniMax weekly remains")
        expect(minimax.extras["intervalRemainsTime"] == "1小时30分", "expected MiniMax interval reset text")
        expect(minimax.extras["weeklyUsedPercent"] == "25", "expected MiniMax weekly used percent")
        expect(minimax.extras["intervalRemainingPercent"] == "75", "expected MiniMax interval remaining percent")

        let comfly = try provider.decodeBalance(data: Data("""
        {"success": true, "data": {"quota": 500247, "used_quota": 500247}}
        """.utf8), providerID: .comfly)
        expect(comfly.balance == "¥1.20", "expected Comfly balance")
        expect(comfly.extras["balanceYuan"] == "¥1.20", "expected Comfly balance display")
        expect(comfly.extras["displayFullBalance"] == "¥2.40", "expected Comfly full balance reference")
        expect(comfly.extras["tokenBalance"] == "1.00", "expected Comfly token balance")

        let comflyStringQuota = try provider.decodeBalance(data: Data("""
        {"success": true, "data": {"quota": "500247", "used_quota": "500247.0"}}
        """.utf8), providerID: .comfly)
        expect(comflyStringQuota.balance == "¥1.20", "expected Comfly string quota to decode")

        let claude = try provider.decodeBalance(data: Data("""
        {
          "organizations": [
            {
              "rate_limit_tier": "pro",
              "billing": {"status": "active", "period": "monthly"}
            }
          ],
          "usage": {
            "five_hour": {"utilization": 83, "resets_at": "2026-05-21T02:18:00Z"},
            "seven_day": {"utilization": 19, "resets_at": "2026-05-21T22:00:00Z"},
            "seven_day_omelette": {"utilization": 8, "resets_at": "2026-05-21T22:00:00Z"}
          },
          "limits": {
            "weekly_limits": [
              {"name": "All models", "utilization": 19, "reset_at": "2026-05-21T22:00:00Z"},
              {"name": "Claude Design", "utilization": 0, "reset_at": "2026-05-21T22:00:00Z", "description": "You haven’t used Claude Design yet"}
            ]
          }
        }
        """.utf8), providerID: .claude)
        expect(claude.extras["designUsed"] == "8", "expected Claude Design usage to prefer structured usage")
        expect(claude.extras["designResetsAt"] == "2026-05-21T22:00:00Z", "expected Claude Design reset time")
        expect(
            claude.extras["designNote"] == nil || claude.extras["designNote"] == "You haven’t used Claude Design yet",
            "expected Claude Design note compatibility"
        )

        do {
            _ = try provider.decodeBalance(data: Data("""
            {"success": false, "message": "token invalid"}
            """.utf8), providerID: .comfly)
            expect(false, "expected Comfly provider error")
        } catch APIBalanceError.provider(let message) {
            expect(message == "token invalid", "expected Comfly provider message")
        }
    }

    static func minimaxPrefersResponseRemainingPercentWhenCountsAreZero() throws {
        let provider = LLMBalanceProvider()
        let snapshot = try provider.decodeBalance(data: Data("""
        {
          "base_resp": {"status_code": 0, "status_msg": "success"},
          "model_remains": [
            {
              "model_name": "general",
              "current_weekly_total_count": 0,
              "current_weekly_usage_count": 0,
              "current_interval_total_count": 0,
              "current_interval_usage_count": 0,
              "current_interval_remaining_percent": 99,
              "current_weekly_remaining_percent": 98,
              "remains_time": 17944325
            }
          ]
        }
        """.utf8), providerID: .minimax)

        expect(snapshot.usedPercent == 2, "MiniMax headline usage should prefer response weekly remaining percent")
        expect(snapshot.extras["intervalRemainingPercent"] == "99", "MiniMax interval remaining percent should come from response")
        expect(snapshot.extras["weeklyRemainingPercent"] == "98", "MiniMax weekly remaining percent should come from response")
        expect(snapshot.extras["intervalUsedPercent"] == "1", "MiniMax interval used percent should invert response remaining percent")
        expect(snapshot.extras["weeklyUsedPercent"] == "2", "MiniMax weekly used percent should invert response remaining percent")
        expect(snapshot.status == .ok, "MiniMax percent quota should not warn just because count totals are zero")
        expect(snapshot.note == nil, "MiniMax percent quota should not show an unavailable quota note")
    }

    static func minimaxDecodesResponseResetTimes() throws {
        let provider = LLMBalanceProvider()
        let snapshot = try provider.decodeBalance(data: Data("""
        {
          "base_resp": {"status_code": 0, "status_msg": "success"},
          "model_remains": [
            {
              "model_name": "general",
              "current_weekly_total_count": 0,
              "current_weekly_usage_count": 0,
              "current_interval_total_count": 0,
              "current_interval_usage_count": 0,
              "current_interval_remaining_percent": 98,
              "current_weekly_remaining_percent": 98,
              "remains_time": 16886990,
              "weekly_remains_time": 394886990,
              "end_time": 1780470000000,
              "weekly_end_time": 1780848000000
            }
          ]
        }
        """.utf8), providerID: .minimax)

        expect(
            snapshot.extras["intervalResetAt"].flatMap(DateCoding.parseISO8601) == Date(timeIntervalSince1970: 1_780_470_000),
            "MiniMax interval reset should prefer response end_time"
        )
        expect(
            snapshot.extras["weeklyResetAt"].flatMap(DateCoding.parseISO8601) == Date(timeIntervalSince1970: 1_780_848_000),
            "MiniMax weekly reset should come from response weekly_end_time"
        )
        expect(snapshot.extras["weeklyRemainsTime"] == "109小时41分", "MiniMax weekly remaining time should be readable")
    }

    static func claudeErrorSnapshotsAreActionable() {
        let notInstalled = ClaudeFetchError.notInstalled.snapshot
        expect(notInstalled.setupState == .notInstalled, "expected Claude install error classification")
        expect(notInstalled.errorCode == "claude_not_installed", "expected Claude install error code")
        expect(notInstalled.actionHint == "安装 Claude Desktop 并完成登录后刷新", "expected Claude install hint")

        let missingDependency = ClaudeFetchError.cryptographyMissing.snapshot
        expect(missingDependency.setupState == .missingDependency, "expected dependency classification")
        expect(missingDependency.errorCode == "python_cryptography_missing", "expected dependency error code")

        let notLoggedIn = ClaudeFetchError.notLoggedIn.snapshot
        expect(notLoggedIn.setupState == .notLoggedIn, "expected login classification")
        expect(notLoggedIn.actionHint == "打开 Claude Desktop 并确认已登录 claude.ai", "expected Claude login hint")
    }

    static func markedReadyPreservesExistingMetrics() {
        let snapshot = APIBalanceSnapshot(
            balance: "Pro",
            usedPercent: 42,
            status: .warning,
            extras: ["fiveHourUsed": "42"]
        ).markedReady(actionHint: "已同步")

        expect(snapshot.setupState == .ready, "expected ready state")
        expect(snapshot.actionHint == "已同步", "expected ready hint")
        expect(snapshot.extras["fiveHourUsed"] == "42", "expected existing metrics to survive")
    }

    @MainActor
    static func lowestRemainingUsesTightestAccount() async {
        let store = MemorySlotStore(file: SlotFile(slots: [
            slot("A", remaining: 80),
            slot("B", remaining: 0)
        ]))
        let manager = QuotaManager(
            store: store,
            provider: StaticProvider(snapshot: snapshot(remaining: 50)),
            importer: CodexAuthImporter(secretStore: MemorySecretStore())
        )

        manager.load()
        expect(manager.statusBarTitle == "Codex 0%", "status bar should show tightest quota")
        expect(manager.hasWarning, "exhausted quota should warn")
    }

    @MainActor
    static func statusBarPrefersSessionWindow() async {
        let sessionResetAt = DateCoding.parseISO8601("2026-05-10T08:40:50Z")
        let snapshot = QuotaSnapshot(
            accountLabel: "user@example.com",
            fetchHealth: .ok,
            note: "Plan plus | 5h 99% | Weekly 0%",
            quotaWindows: [
                QuotaWindow(id: "session", kind: .session, remainingPercent: 99, resetAt: sessionResetAt, title: "5h", usedPercent: 1),
                QuotaWindow(id: "weekly", kind: .weekly, remainingPercent: 0, title: "Weekly", usedPercent: 100)
            ],
            remaining: 0,
            status: .warning,
            used: 1
        )
        let store = MemorySlotStore(file: SlotFile(slots: [
            AccountSlot(slotID: "A", accountKey: "key", displayName: "user@example.com", lastSnapshot: snapshot)
        ]))
        let manager = QuotaManager(
            store: store,
            provider: StaticProvider(snapshot: snapshot),
            importer: CodexAuthImporter(secretStore: MemorySecretStore())
        )

        manager.load()
        expect(manager.sessionRemaining == 99, "session remaining should prefer 5h/session window")
        expect(manager.sessionResetAt == sessionResetAt, "session reset should come from 5h/session window")
        expect(manager.statusBarTitle == "Codex 99%", "status bar should prefer 5h/session window over weekly minimum")
    }

    @MainActor
    static func refreshFailureKeepsStaleSnapshot() async {
        let store = MemorySlotStore(file: SlotFile(slots: [slot("A", remaining: 42)]))
        let manager = QuotaManager(
            store: store,
            provider: FailingProvider(),
            importer: CodexAuthImporter(secretStore: MemorySecretStore())
        )

        manager.load()
        await manager.refreshAll()

        expect(manager.slots[0].lastSnapshot?.remaining == 42, "stale refresh should keep previous quota")
        expect(manager.slots[0].lastSnapshot?.valueFreshness == .stale, "failed refresh should mark snapshot stale")
        expect(manager.lastError == nil, "transient refresh failures with existing data should not surface global errors")
    }

    @MainActor
    static func authErrorDoesNotDriveStatusBar() {
        let authSnapshot = QuotaSnapshot(
            accountLabel: "user@example.com",
            fetchHealth: .authError,
            note: "Codex 登录已过期或未授权。",
            quotaWindows: [
                QuotaWindow(id: "session", kind: .session, remainingPercent: 100, title: "5h", usedPercent: 0),
                QuotaWindow(id: "weekly", kind: .weekly, remainingPercent: 100, title: "Weekly", usedPercent: 0)
            ],
            remaining: 100,
            status: .error,
            used: 0,
            valueFreshness: .stale
        )
        let manager = QuotaManager(
            store: MemorySlotStore(file: SlotFile(slots: [
                AccountSlot(slotID: "A", accountKey: "key", displayName: "user@example.com", lastSnapshot: authSnapshot)
            ])),
            provider: StaticProvider(snapshot: snapshot(remaining: 50)),
            importer: CodexAuthImporter(secretStore: MemorySecretStore())
        )

        manager.load()
        expect(manager.statusBarTitle == "Codex --", "auth errors should not pretend quota is 100%")
        expect(manager.compactStatusBarTitle == "--", "compact title should hide auth-error percentages")
        expect(manager.sessionRemaining == nil, "session title should hide auth-error percentages")
        expect(manager.hasWarning, "auth errors should still surface as warning state")
    }

    @MainActor
    static func claudeStatusBarValueUsesFiveHourWindow() {
        var providers = APIKeyProviderConfig.defaults
        for index in providers.indices {
            providers[index].isEnabled = providers[index].id == .claude
            if providers[index].id == .claude {
                providers[index].lastSnapshot = APIBalanceSnapshot(
                    balance: "Claude Pro",
                    usedPercent: 92,
                    extras: [
                        "fiveHourUsed": "25",
                        "fiveHourResetsAt": "2026-05-21T02:18:00Z",
                        "sevenDayUsed": "92"
                    ]
                ).markedReady()
            }
        }

        let manager = APIKeyManager(
            store: MemoryAPIKeyConfigStore(file: APIKeyConfigFile(providers: providers)),
            secretStore: MemorySecretStore(),
            balanceProvider: CountingBalanceProvider()
        )

        manager.load()
        expect(manager.claudeFiveHourRemaining == 75, "Claude menu bar value should use fiveHourUsed, not weekly or headline usage")
        expect(manager.claudeFiveHourResetAt == DateCoding.parseISO8601("2026-05-21T02:18:00Z"), "Claude menu bar reset should use fiveHourResetsAt")
    }

    static func persistedSnapshotDoesNotContainSecrets() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("codex_slots.json")
        let store = FileSlotStore(fileURL: url)
        try store.save(SlotFile(slots: [slot("A", remaining: 10)]))

        let text = try String(contentsOf: url)
        expect(!text.contains("access_token"), "snapshot should not contain access token")
        expect(!text.contains("refresh_token"), "snapshot should not contain refresh token")
        expect(!text.contains("id_token"), "snapshot should not contain id token")
        expect(!text.contains("secret"), "snapshot should not contain generic secret fields")
    }

    static func profileStoreDoesNotPersistAuthJSON() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("codex_profiles.json")
        let store = FileProfileStore(fileURL: url)
        let profile = CodexProfile(
            accountEmail: "user@example.com",
            accountId: "acct-123",
            accountSubject: "sub-123",
            credentialFingerprint: "abcd1234",
            displayName: "Codex A",
            identityKey: "tenant:account:acct-123|principal:subject:sub-123",
            isCurrentSystemAccount: true,
            lastImportedAt: Date(timeIntervalSince1970: 1_000),
            slotID: "A",
            tenantKey: "account:acct-123"
        )
        try store.save(CodexProfileFile(profiles: [profile]))

        let text = try String(contentsOf: url)
        expect(!text.contains("authJSON"), "profile should not persist raw auth JSON")
        expect(!text.contains("access_token"), "profile should not contain access token")
        expect(!text.contains("refresh_token"), "profile should not contain refresh token")
        expect(!text.contains("id_token"), "profile should not contain id token")
    }

    static func codexCredentialFingerprintIgnoresTokenRotation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let idToken = try makeJWT(
            email: "user@example.com",
            subject: "subject-123",
            clientID: "client-123",
            accountID: "acct-123"
        )
        let importer = CodexAuthImporter(authURL: url, secretStore: MemorySecretStore())

        try makeCodexAuthJSON(accessToken: "access-one", refreshToken: "refresh-one", idToken: idToken, accountID: "acct-123")
            .write(to: url, atomically: true, encoding: .utf8)
        let first = try importer.currentCredentialFingerprint()

        try makeCodexAuthJSON(accessToken: "access-two", refreshToken: "refresh-two", idToken: idToken, accountID: "acct-123")
            .write(to: url, atomically: true, encoding: .utf8)
        let second = try importer.currentCredentialFingerprint()

        expect(first == second, "token rotation should not force a startup keychain re-import")
    }

    static func codexImportStoresClientIDFromAccessTokenWhenIDTokenOmitsIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let authURL = directory.appendingPathComponent("auth.json")
        let profilesURL = directory.appendingPathComponent("profiles.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let idToken = try makeJWT(
            email: "user@example.com",
            subject: "subject-123",
            clientID: nil,
            accountID: "acct-123"
        )
        let accessToken = try makeJWT(
            email: nil,
            subject: "subject-123",
            clientID: "client-from-access-token",
            accountID: "acct-123"
        )
        try makeCodexAuthJSON(accessToken: accessToken, refreshToken: "refresh-token", idToken: idToken, accountID: "acct-123")
            .write(to: authURL, atomically: true, encoding: .utf8)

        let secretStore = MemorySecretStore()
        let importer = CodexAuthImporter(
            authURL: authURL,
            secretStore: secretStore,
            profileStore: FileProfileStore(fileURL: profilesURL)
        )

        _ = try importer.importCurrentAccount()

        let storedClientID = try secretStore.get(account: SecretAccount.clientID(slotID: "A"))
        expect(storedClientID == "client-from-access-token", "import should store client_id from access token when id token omits it")
    }

    static func apiKeyStoreDoesNotPersistSecureValues() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("api_keys.json")
        let store = FileAPIKeyConfigStore(fileURL: url)
        var file = APIKeyConfigFile()
        file.providers[0].fields[0].value = "sk-secret-value"
        try store.save(file)

        let text = try String(contentsOf: url)
        expect(!text.contains("sk-secret-value"), "API key config should not persist secure values")
        expect(text.contains("deepseek"), "API key config should include default providers")
    }

    @MainActor
    static func launchRefreshSkipsSecureProviderReadsButUpdatesClaude() async {
        var providers = APIKeyProviderConfig.defaults
        for index in providers.indices {
            providers[index].isEnabled = true
            providers[index].lastSnapshot = nil
        }

        let balanceProvider = CountingBalanceProvider()
        let manager = APIKeyManager(
            store: MemoryAPIKeyConfigStore(file: APIKeyConfigFile(providers: providers)),
            secretStore: MemorySecretStore(),
            balanceProvider: balanceProvider
        )
        let claudeFetchCounter = Counter()
        manager.claudeFetcher = { allowsUserInteraction in
            await claudeFetchCounter.increment()
            expect(!allowsUserInteraction, "launch refresh should read Claude login state without keychain UI")
            return APIBalanceSnapshot(balance: "Claude", usedPercent: 0)
        }

        manager.load()
        await manager.refreshAll(trigger: .launch)

        let requestedProviders = await balanceProvider.requestedProviderIDs()
        let claudeFetchCount = await claudeFetchCounter.value()
        expect(requestedProviders.isEmpty, "launch refresh should skip secure providers without a ready snapshot")
        expect(claudeFetchCount == 1, "launch refresh should update Claude through the lightweight non-interactive path")
        expect(manager.providers.first(where: { $0.id == .claude })?.lastSnapshot?.setupState == .ready, "Claude should refresh during the shared cadence")
    }

    @MainActor
    static func launchRefreshUsesNonInteractiveSecretReads() async {
        var providers = APIKeyProviderConfig.defaults
        for index in providers.indices {
            providers[index].isEnabled = providers[index].id == .deepseek
            if providers[index].id == .deepseek {
                providers[index].lastSnapshot = APIBalanceSnapshot(balance: "DeepSeek", usedPercent: 10).markedReady()
            }
        }

        let secretStore = RecordingSecretStore(values: [
            APISecretAccount.field(providerID: .deepseek, key: "apiKey"): "sk-test"
        ])
        let balanceProvider = CountingBalanceProvider()
        let manager = APIKeyManager(
            store: MemoryAPIKeyConfigStore(file: APIKeyConfigFile(providers: providers)),
            secretStore: secretStore,
            balanceProvider: balanceProvider
        )

        manager.load()
        await manager.refreshAll(trigger: .launch)

        let reads = secretStore.recordedReads()
        expect(reads.count == 1, "launch refresh should read one secure field")
        expect(reads.first?.0 == APISecretAccount.field(providerID: .deepseek, key: "apiKey"), "launch refresh should read the DeepSeek key")
        expect(reads.first?.1 == false, "launch refresh should not allow keychain UI")
        let requestedProviders = await balanceProvider.requestedProviderIDs()
        expect(requestedProviders == [.deepseek], "ready secure providers should still refresh when non-interactive access succeeds")
    }

    @MainActor
    static func copyAvailabilityUsesSnapshotsOnly() {
        var providers = APIKeyProviderConfig.defaults
        for index in providers.indices {
            providers[index].isEnabled = providers[index].id == .deepseek
            if providers[index].id == .deepseek {
                providers[index].lastSnapshot = APIBalanceSnapshot(balance: "DeepSeek", usedPercent: 10).markedReady()
            }
        }

        let secretStore = RecordingSecretStore()
        let manager = APIKeyManager(
            store: MemoryAPIKeyConfigStore(file: APIKeyConfigFile(providers: providers)),
            secretStore: secretStore,
            balanceProvider: CountingBalanceProvider()
        )

        manager.load()
        expect(manager.canCopyPrimaryValue(providerID: .deepseek), "copy affordance should use cached setup state")
        expect(secretStore.recordedReads().isEmpty, "copy affordance should not read keychain secrets")
    }

    @MainActor
    static func claudeAutoRefreshUsesNonInteractivePath() async {
        var providers = APIKeyProviderConfig.defaults
        for index in providers.indices {
            providers[index].isEnabled = providers[index].id == .claude
            if providers[index].id == .claude {
                providers[index].lastSnapshot = APIBalanceSnapshot(
                    balance: "Claude Pro",
                    usedPercent: 12
                ).markedReady(actionHint: "已同步")
            }
        }

        let manager = APIKeyManager(
            store: MemoryAPIKeyConfigStore(file: APIKeyConfigFile(providers: providers)),
            secretStore: MemorySecretStore(),
            balanceProvider: CountingBalanceProvider()
        )
        let claudeFetchRecorder = ClaudeFetchRecorder()
        manager.claudeFetcher = { allowsUserInteraction in
            await claudeFetchRecorder.record(allowsUserInteraction)
            return APIBalanceSnapshot(balance: "Claude Pro", usedPercent: 10)
        }

        manager.load()
        await manager.refreshAll(trigger: .launch)

        await manager.refreshAll(trigger: .polling)

        await manager.refreshProvider(.claude, trigger: .manual)

        let reads = await claudeFetchRecorder.reads()
        expect(reads == [false, false, true], "Claude launch and polling should use the lightweight non-interactive path; manual refresh may use WebKit fallback")
    }

    @MainActor
    static func claudeAutoRefreshPreservesDOMOnlyRoutineMetrics() async {
        var providers = APIKeyProviderConfig.defaults
        for index in providers.indices {
            providers[index].isEnabled = providers[index].id == .claude
            if providers[index].id == .claude {
                providers[index].lastSnapshot = APIBalanceSnapshot(
                    balance: "Claude Pro",
                    usedPercent: 12,
                    extras: [
                        "fiveHourUsed": "12",
                        "sevenDayUsed": "2",
                        "routineUsed": "1",
                        "routineTotal": "5"
                    ]
                ).markedReady(actionHint: "已同步")
            }
        }

        let manager = APIKeyManager(
            store: MemoryAPIKeyConfigStore(file: APIKeyConfigFile(providers: providers)),
            secretStore: MemorySecretStore(),
            balanceProvider: CountingBalanceProvider()
        )
        manager.claudeFetcher = { _ in
            APIBalanceSnapshot(
                balance: "Claude Pro",
                usedPercent: 8,
                extras: [
                    "fiveHourUsed": "8",
                    "sevenDayUsed": "1"
                ]
            )
        }

        manager.load()
        await manager.refreshProvider(.claude, trigger: .polling)

        let snapshot = manager.providers.first(where: { $0.id == .claude })?.lastSnapshot
        expect(snapshot?.extras["fiveHourUsed"] == "8", "Claude API metrics should update during lightweight polling")
        expect(snapshot?.extras["routineUsed"] == "1", "DOM-only routine used count should survive lightweight polling")
        expect(snapshot?.extras["routineTotal"] == "5", "DOM-only routine total should survive lightweight polling")
    }

    @MainActor
    static func claudeRefreshFailureKeepsLastUsageSnapshot() async {
        var providers = APIKeyProviderConfig.defaults
        for index in providers.indices {
            providers[index].isEnabled = providers[index].id == .claude
            if providers[index].id == .claude {
                providers[index].lastSnapshot = APIBalanceSnapshot(
                    balance: "Pro",
                    usedPercent: 7,
                    extras: [
                        "fiveHourUsed": "7",
                        "sevenDayUsed": "1",
                        "designUsed": "12",
                        "fiveHourResetsAt": "2026-05-20T20:00:00Z",
                        "sevenDayResetsAt": "2026-05-27T14:00:00Z",
                        "designResetsAt": "2026-05-27T14:00:00Z"
                    ]
                ).markedReady(actionHint: "已同步")
            }
        }

        let manager = APIKeyManager(
            store: MemoryAPIKeyConfigStore(file: APIKeyConfigFile(providers: providers)),
            secretStore: MemorySecretStore(),
            balanceProvider: CountingBalanceProvider()
        )
        manager.claudeFetcher = { _ in
            throw ClaudeFetchError.timedOut
        }

        manager.load()
        await manager.refreshProvider(.claude, trigger: .manual)

        let snapshot = manager.providers.first(where: { $0.id == .claude })?.lastSnapshot
        expect(snapshot?.extras["fiveHourUsed"] == "7", "Claude refresh failures should keep the last 5-hour usage")
        expect(snapshot?.extras["sevenDayUsed"] == "1", "Claude refresh failures should keep the last weekly usage")
        expect(snapshot?.extras["designUsed"] == "12", "Claude refresh failures should keep the last design usage")
        expect(snapshot?.setupState == .ready, "stale Claude metrics should remain renderable instead of becoming an empty setup placeholder")
        expect(snapshot?.status == .error, "stale Claude metrics should still mark the failed refresh")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fatalError("Test failed: \(message)")
        }
    }
}

private func slot(_ id: String, remaining: Int) -> AccountSlot {
    AccountSlot(
        slotID: id,
        accountKey: "key-\(id)",
        displayName: "user-\(id)@example.com",
        lastSnapshot: snapshot(remaining: remaining)
    )
}

private func snapshot(remaining: Int) -> QuotaSnapshot {
    QuotaSnapshot(
        accountLabel: "user@example.com",
        fetchHealth: .ok,
        note: "Weekly \(remaining)%",
        quotaWindows: [
            QuotaWindow(id: "weekly", kind: .weekly, remainingPercent: remaining, title: "Weekly", usedPercent: 100 - remaining)
        ],
        remaining: remaining,
        status: remaining < 20 ? .warning : .ok,
        used: 100 - remaining
    )
}

private func makeCodexAuthJSON(accessToken: String, refreshToken: String, idToken: String, accountID: String) throws -> String {
    let object: [String: Any] = [
        "auth_mode": "chatgpt",
        "tokens": [
            "access_token": accessToken,
            "refresh_token": refreshToken,
            "id_token": idToken,
            "account_id": accountID
        ]
    ]
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(data: data, encoding: .utf8) ?? "{}"
}

private func makeJWT(email: String?, subject: String, clientID: String?, accountID: String) throws -> String {
    let headerData = try JSONSerialization.data(withJSONObject: ["alg": "none"], options: [.sortedKeys])
    var payload: [String: Any] = [
        "sub": subject,
        "https://api.openai.com/auth": [
            "chatgpt_account_id": accountID
        ]
    ]
    if let email {
        payload["email"] = email
    }
    if let clientID {
        payload["client_id"] = clientID
    }
    let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    return "\(base64URL(headerData)).\(base64URL(payloadData)).signature"
}

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private final class MemorySlotStore: SlotStore, @unchecked Sendable {
    var file: SlotFile

    init(file: SlotFile) {
        self.file = file
    }

    func load() throws -> SlotFile {
        file
    }

    func save(_ file: SlotFile) throws {
        self.file = file
    }
}

private final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private var values: [String: String] = [:]

    func set(_ value: String, account: String) throws {
        values[account] = value
    }

    func get(account: String) throws -> String? {
        values[account]
    }

    func delete(account: String) throws {
        values.removeValue(forKey: account)
    }
}

private final class RecordingSecretStore: SecretStore, @unchecked Sendable {
    private var values: [String: String]
    private var reads: [(String, Bool)] = []

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func set(_ value: String, account: String) throws {
        values[account] = value
    }

    func get(account: String) throws -> String? {
        try get(account: account, allowsUserInteraction: true)
    }

    func get(account: String, allowsUserInteraction: Bool) throws -> String? {
        reads.append((account, allowsUserInteraction))
        return values[account]
    }

    func delete(account: String) throws {
        values.removeValue(forKey: account)
    }

    func recordedReads() -> [(String, Bool)] {
        reads
    }
}

private final class MemoryAPIKeyConfigStore: APIKeyConfigStore, @unchecked Sendable {
    var file: APIKeyConfigFile

    init(file: APIKeyConfigFile) {
        self.file = file
    }

    func load() throws -> APIKeyConfigFile {
        file
    }

    func save(_ file: APIKeyConfigFile) throws {
        self.file = file
    }
}

private struct StaticProvider: CodexQuotaProvider {
    var snapshot: QuotaSnapshot

    func fetchQuota(for slot: AccountSlot) async throws -> QuotaSnapshot {
        snapshot
    }
}

private struct FailingProvider: CodexQuotaProvider {
    func fetchQuota(for slot: AccountSlot) async throws -> QuotaSnapshot {
        throw ProviderError.rateLimited
    }
}

private actor CountingBalanceProvider: APIBalanceProvider {
    private var providerIDs: [APIKeyProviderID] = []

    func fetchBalance(for config: APIKeyProviderConfig, credentials: [String : String]) async throws -> APIBalanceSnapshot {
        providerIDs.append(config.id)
        return APIBalanceSnapshot(balance: config.displayName, usedPercent: 0)
    }

    func requestedProviderIDs() -> [APIKeyProviderID] {
        providerIDs
    }
}

private actor Counter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private actor ClaudeFetchRecorder {
    private var values: [Bool] = []

    func record(_ allowsUserInteraction: Bool) {
        values.append(allowsUserInteraction)
    }

    func reads() -> [Bool] {
        values
    }
}
