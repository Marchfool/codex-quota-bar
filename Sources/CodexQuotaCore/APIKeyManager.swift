import Foundation

@MainActor
public final class APIKeyManager: ObservableObject {
    @Published public private(set) var providers: [APIKeyProviderConfig] = []
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var lastError: String?

    public let store: APIKeyConfigStore
    public let secretStore: SecretStore
    public let balanceProvider: APIBalanceProvider
    public var pollInterval: Duration
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

    public func refreshAll() async {
        isRefreshing = true
        defer { isRefreshing = false }

        for index in providers.indices where providers[index].isEnabled {
            do {
                let credentials = credentials(for: providers[index])
                guard hasRequiredCredentials(providers[index], credentials: credentials) else {
                    continue
                }
                let snapshot = try await balanceProvider.fetchBalance(for: providers[index], credentials: credentials)
                providers[index].lastSnapshot = snapshot
            } catch {
                providers[index].lastSnapshot = staleSnapshot(from: providers[index].lastSnapshot, error: error)
                lastError = "\(providers[index].displayName): \(error.localizedDescription)"
            }
        }
        persist()
    }

    public func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshAll()
                try? await Task.sleep(for: self.pollInterval)
            }
        }
    }

    public func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func credentials(for provider: APIKeyProviderConfig) -> [String: String] {
        Dictionary(uniqueKeysWithValues: provider.fields.map { field in
            (field.key, field.isSecure ? ((try? secretStore.get(account: APISecretAccount.field(providerID: provider.id, key: field.key))) ?? "") : (field.value ?? ""))
        })
    }

    private func hasRequiredCredentials(_ provider: APIKeyProviderConfig, credentials: [String: String]) -> Bool {
        provider.fields.allSatisfy { field in
            !(credentials[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func staleSnapshot(from existing: APIBalanceSnapshot?, error: Error) -> APIBalanceSnapshot {
        if var existing {
            existing.status = .error
            existing.note = error.localizedDescription
            existing.updatedAt = Date()
            return existing
        }
        return APIBalanceSnapshot(
            balance: "--",
            usedPercent: 0,
            status: .error,
            note: error.localizedDescription
        )
    }

    private func persist() {
        try? store.save(APIKeyConfigFile(providers: providers))
    }
}
