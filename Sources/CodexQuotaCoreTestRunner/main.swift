import CodexQuotaCore
import Foundation

@main
struct TestRunner {
    static func main() async throws {
        try decodesExistingQuotaWindowShape()
        try providerDecodesFlexibleSchema()
        try providerDecodesWhamUsageSchema()
        try llmBalanceProviderDecodesSamples()
        formattersClampPercent()
        formattersUseReadableChineseUpdatedText()
        await lowestRemainingUsesTightestAccount()
        await statusBarPrefersSessionWindow()
        await refreshFailureKeepsStaleSnapshot()
        try persistedSnapshotDoesNotContainSecrets()
        try profileStoreDoesNotPersistAuthJSON()
        try apiKeyStoreDoesNotPersistSecureValues()
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
        expect(deepseek.usedPercent == 17, "expected DeepSeek used percent")
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
        expect(comfly.balance == "B|1.00", "expected Comfly balance")
        expect(comfly.extras["balanceYuan"] == "¥1.20", "expected Comfly CNY estimate")
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
        let snapshot = QuotaSnapshot(
            accountLabel: "user@example.com",
            fetchHealth: .ok,
            note: "Plan plus | 5h 99% | Weekly 0%",
            quotaWindows: [
                QuotaWindow(id: "session", kind: .session, remainingPercent: 99, title: "5h", usedPercent: 1),
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
