import Foundation

@MainActor
public final class APIKeyManager: ObservableObject {
    @Published public private(set) var providers: [APIKeyProviderConfig] = []
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var refreshingProviderIDs: Set<APIKeyProviderID> = []
    @Published public private(set) var lastError: String?

    public let store: APIKeyConfigStore
    public let secretStore: SecretStore
    public let balanceProvider: APIBalanceProvider
    public var pollInterval: Duration
    public var claudeFetcher: (@Sendable () async throws -> APIBalanceSnapshot)?
    private var pollingTask: Task<Void, Never>?

    public init(
        store: APIKeyConfigStore,
        secretStore: SecretStore,
        balanceProvider: APIBalanceProvider = LLMBalanceProvider(),
        pollInterval: Duration = .seconds(120)
    ) {
        self.store = store
        self.secretStore = secretStore
        self.balanceProvider = balanceProvider
        self.pollInterval = pollInterval
    }

    public func load() {
        do {
            providers = try store.load().providers
            try? store.save(APIKeyConfigFile(providers: providers))
            lastError = nil
        } catch {
            providers = APIKeyProviderConfig.defaults
            lastError = error.localizedDescription
        }
    }

    public func fieldValue(providerID: APIKeyProviderID, key: String) -> String {
        guard let provider = providers.first(where: { $0.id == providerID }),
              let field = provider.fields.first(where: { $0.key == key })
        else {
            return ""
        }

        if field.isSecure {
            return (try? secretStore.get(account: APISecretAccount.field(providerID: providerID, key: key))) ?? ""
        }
        return field.value ?? ""
    }

    public func primaryCopyValue(providerID: APIKeyProviderID) -> String {
        switch providerID {
        case .deepseek, .minimax:
            return fieldValue(providerID: providerID, key: "apiKey")
        case .comfly:
            let provider = providers.first(where: { $0.id == providerID })
            for key in ["token", "apiKey", "apiToken"] {
                let value: String
                if provider?.fields.contains(where: { $0.key == key }) == true {
                    value = fieldValue(providerID: providerID, key: key).trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    value = ((try? secretStore.get(account: APISecretAccount.field(providerID: providerID, key: key))) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if !value.isEmpty { return value }
            }
            return ""
        case .claude:
            return fieldValue(providerID: providerID, key: "sessionKey")
        }
    }

    public func canCopyPrimaryValue(providerID: APIKeyProviderID) -> Bool {
        guard let provider = providers.first(where: { $0.id == providerID }),
              provider.id != .claude,
              provider.hasSecureFields,
              provider.lastSnapshot != nil,
              provider.lastSnapshot?.setupState != .configurationRequired
        else {
            return false
        }
        return true
    }

    public var claudeFiveHourRemaining: Int? {
        guard let snapshot = providers.first(where: { $0.id == .claude })?.lastSnapshot,
              let usedText = snapshot.extras["fiveHourUsed"],
              let used = Int(usedText.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return nil
        }
        return min(100, max(0, 100 - used))
    }

    public var claudeFiveHourResetAt: Date? {
        guard let resetText = providers.first(where: { $0.id == .claude })?.lastSnapshot?.extras["fiveHourResetsAt"] else {
            return nil
        }
        return DateCoding.parseISO8601(resetText)
    }

    public func saveValues(providerID: APIKeyProviderID, values: [String: String]) {
        guard let providerIndex = providers.firstIndex(where: { $0.id == providerID }) else { return }
        for fieldIndex in providers[providerIndex].fields.indices {
            let field = providers[providerIndex].fields[fieldIndex]
            guard let value = values[field.key] else { continue }
            if field.isSecure {
                if value.isEmpty {
                    try? secretStore.delete(account: APISecretAccount.field(providerID: providerID, key: field.key))
                } else {
                    try? secretStore.set(value, account: APISecretAccount.field(providerID: providerID, key: field.key))
                }
                providers[providerIndex].fields[fieldIndex].value = nil
            } else {
                providers[providerIndex].fields[fieldIndex].value = value
            }
        }
        persist()
    }

    public func setProviderEnabled(_ providerID: APIKeyProviderID, isEnabled: Bool) {
        guard let index = providers.firstIndex(where: { $0.id == providerID }) else { return }
        providers[index].isEnabled = isEnabled
        persist()
    }

    public func refreshAll(trigger: APIRefreshTrigger = .manual) async {
        isRefreshing = true
        lastError = nil
        defer { isRefreshing = false }

        for provider in providers where shouldRefresh(provider, trigger: trigger) {
            await refreshProvider(provider.id, trigger: trigger)
        }
        persist()
    }

    public func refreshProvider(_ providerID: APIKeyProviderID, trigger: APIRefreshTrigger = .manual) async {
        guard let index = providers.firstIndex(where: { $0.id == providerID }), providers[index].isEnabled else { return }
        guard shouldRefresh(providers[index], trigger: trigger) else { return }
        refreshingProviderIDs.insert(providerID)
        defer { refreshingProviderIDs.remove(providerID) }

        if providerID == .claude, let claudeFetcher = claudeFetcher {
            do {
                let snapshot = try await claudeFetcher()
                providers[index].lastSnapshot = snapshot.markedReady(actionHint: "已从 Claude Desktop 同步登录态")
            } catch {
                if let claudeError = error as? ClaudeFetchError {
                    providers[index].lastSnapshot = claudeError.snapshot
                } else {
                    providers[index].lastSnapshot = staleSnapshot(
                        from: providers[index].lastSnapshot,
                        error: error,
                        fallbackBalance: providers[index].displayName
                    )
                }
            }
            persist()
            return
        }

        do {
            let credentials = try credentials(
                for: providers[index],
                allowsUserInteraction: shouldAllowSecretInteraction(trigger)
            )
            guard hasRequiredCredentials(providers[index], credentials: credentials) else {
                providers[index].lastSnapshot = missingCredentialSnapshot(for: providers[index], credentials: credentials)
                return
            }
            let snapshot = try await balanceProvider.fetchBalance(for: providers[index], credentials: credentials)
            providers[index].lastSnapshot = snapshot.markedReady()
        } catch KeychainError.userInteractionRequired {
            if providers[index].lastSnapshot == nil {
                providers[index].lastSnapshot = keychainApprovalSnapshot(for: providers[index])
            }
        } catch {
            providers[index].lastSnapshot = staleSnapshot(
                from: providers[index].lastSnapshot,
                error: error,
                fallbackBalance: providers[index].displayName
            )
            lastError = "\(providers[index].displayName): \(error.localizedDescription)"
        }
        persist()
    }

    public func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: self.pollInterval)
                if Task.isCancelled { break }
                await self.refreshAll(trigger: .polling)
            }
        }
    }

    public func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func credentials(for provider: APIKeyProviderConfig, allowsUserInteraction: Bool) throws -> [String: String] {
        try Dictionary(uniqueKeysWithValues: provider.fields.map { field in
            if field.isSecure {
                let value = try secretStore.get(
                    account: APISecretAccount.field(providerID: provider.id, key: field.key),
                    allowsUserInteraction: allowsUserInteraction
                ) ?? ""
                return (field.key, value)
            }
            return (field.key, field.value ?? "")
        })
    }

    private func shouldRefresh(_ provider: APIKeyProviderConfig, trigger: APIRefreshTrigger) -> Bool {
        guard provider.isEnabled else { return false }

        switch trigger {
        case .manual:
            return true
        case .launch:
            if provider.id == .claude {
                return shouldAutoRefreshClaude(provider, trigger: trigger)
            }
            if provider.hasSecureFields {
                return provider.hasReadySnapshot
            }
            return true
        case .polling:
            if provider.id == .claude {
                return shouldAutoRefreshClaude(provider, trigger: trigger)
            }
            if provider.hasSecureFields {
                return provider.hasReadySnapshot
            }
            return true
        }
    }

    private func shouldAllowSecretInteraction(_ trigger: APIRefreshTrigger) -> Bool {
        trigger == .manual
    }

    private func shouldAutoRefreshClaude(_ provider: APIKeyProviderConfig, trigger: APIRefreshTrigger) -> Bool {
        switch trigger {
        case .manual:
            return true
        case .launch, .polling:
            return false
        }
    }

    private func hasRequiredCredentials(_ provider: APIKeyProviderConfig, credentials: [String: String]) -> Bool {
        provider.fields.allSatisfy { field in
            !(credentials[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func staleSnapshot(from existing: APIBalanceSnapshot?, error: Error, fallbackBalance: String) -> APIBalanceSnapshot {
        if var existing {
            existing.status = .error
            existing.note = error.localizedDescription
            existing.extras["setupState"] = ProviderSetupState.fetchFailed.rawValue
            existing.extras["actionHint"] = "检查配置或网络后重试"
            return existing
        }
        return APIBalanceSnapshot.setupPlaceholder(
            balance: fallbackBalance,
            note: error.localizedDescription,
            setupState: .fetchFailed,
            actionHint: "检查配置或网络后重试",
            errorCode: "provider_fetch_failed",
            usedPercent: 100,
            status: .error
        )
    }

    private func persist() {
        try? store.save(APIKeyConfigFile(providers: providers))
    }

    private func missingCredentialSnapshot(for provider: APIKeyProviderConfig, credentials: [String: String]) -> APIBalanceSnapshot {
        let missingFields = provider.fields
            .filter { (credentials[$0.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(\.label)
        let fieldSummary = missingFields.joined(separator: "、")
        return APIBalanceSnapshot.setupPlaceholder(
            balance: provider.displayName,
            note: "请先完成 \(fieldSummary) 配置",
            setupState: .configurationRequired,
            actionHint: "填写必填项并点击“刷新余额”",
            errorCode: "provider_configuration_required"
        )
    }

    private func keychainApprovalSnapshot(for provider: APIKeyProviderConfig) -> APIBalanceSnapshot {
        APIBalanceSnapshot.setupPlaceholder(
            balance: provider.displayName,
            note: "钥匙串需要授权后才能读取密钥",
            setupState: .configurationRequired,
            actionHint: "点击“刷新余额”并允许钥匙串访问",
            errorCode: "provider_keychain_approval_required"
        )
    }
}
