import Foundation

public protocol CodexQuotaProvider: Sendable {
    func fetchQuota(for slot: AccountSlot) async throws -> QuotaSnapshot
    func fetchQuota(for slot: AccountSlot, allowsUserInteraction: Bool) async throws -> QuotaSnapshot
}

public extension CodexQuotaProvider {
    func fetchQuota(for slot: AccountSlot, allowsUserInteraction: Bool) async throws -> QuotaSnapshot {
        try await fetchQuota(for: slot)
    }
}

public enum QuotaRefreshTrigger: String, Codable, Sendable {
    case launch
    case polling
    case manual
}

public enum ProviderError: Error, LocalizedError, Equatable {
    case missingCredential
    case unauthorized
    case rateLimited
    case unsupportedSchema
    case server(Int)

    public var errorDescription: String? {
        switch self {
        case .missingCredential:
            return "没有可用的 Codex 登录凭据。"
        case .unauthorized:
            return "Codex 登录已过期或未授权。"
        case .rateLimited:
            return "Codex 额度接口暂时被限流。"
        case .unsupportedSchema:
            return "Codex 额度接口返回格式已变化。"
        case .server(let code):
            return "Codex 额度接口返回 HTTP \(code)。"
        }
    }
}

public final class OfficialCodexProvider: CodexQuotaProvider, @unchecked Sendable {
    private static let supplementalRateLimitsTimeout: TimeInterval = 6
    private static let supplementalRateLimitsFreshCacheAge: TimeInterval = 5 * 60
    private static let supplementalRateLimitsStaleCacheAge: TimeInterval = 60 * 60

    private let secretStore: SecretStore
    private let session: URLSession
    private let endpoint: URL
    private let tokenEndpoint: URL
    private let supplementalRateLimitsCache = SupplementalRateLimitsCache()

    public init(
        secretStore: SecretStore,
        session: URLSession = .shared,
        endpoint: URL = URL(string: ProcessInfo.processInfo.environment["CODEX_QUOTA_ENDPOINT"] ?? "https://chatgpt.com/backend-api/wham/usage")!,
        tokenEndpoint: URL = URL(string: ProcessInfo.processInfo.environment["OPENAI_OAUTH_TOKEN_ENDPOINT"] ?? "https://auth.openai.com/oauth/token")!
    ) {
        self.secretStore = secretStore
        self.session = session
        self.endpoint = endpoint
        self.tokenEndpoint = tokenEndpoint
    }

    public func fetchQuota(for slot: AccountSlot) async throws -> QuotaSnapshot {
        try await fetchQuota(for: slot, allowsUserInteraction: true)
    }

    public func fetchQuota(for slot: AccountSlot, allowsUserInteraction: Bool) async throws -> QuotaSnapshot {
        let token: String
        if let storedToken = try await secret(
            account: SecretAccount.accessToken(slotID: slot.slotID),
            allowsUserInteraction: allowsUserInteraction
        ) {
            token = storedToken
        } else if let refreshedToken = try await refreshAccessToken(
            for: slot,
            allowsUserInteraction: allowsUserInteraction
        ) {
            token = refreshedToken
        } else {
            throw ProviderError.missingCredential
        }

        let (data, response) = try await session.data(for: quotaRequest(token: token))
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.unsupportedSchema
        }

        switch http.statusCode {
        case 200:
            return try await decodeSnapshotWithSupplementalRateLimits(data: data, slot: slot)
        case 401, 403:
            guard let refreshedToken = try await refreshAccessToken(
                for: slot,
                allowsUserInteraction: allowsUserInteraction
            ) else {
                throw ProviderError.unauthorized
            }
            let (retryData, retryResponse) = try await session.data(for: quotaRequest(token: refreshedToken))
            guard let retryHTTP = retryResponse as? HTTPURLResponse else {
                throw ProviderError.unsupportedSchema
            }
            guard retryHTTP.statusCode == 200 else {
                throw retryHTTP.statusCode == 429 ? ProviderError.rateLimited : ProviderError.server(retryHTTP.statusCode)
            }
            return try await decodeSnapshotWithSupplementalRateLimits(data: retryData, slot: slot)
        case 429:
            throw ProviderError.rateLimited
        default:
            throw ProviderError.server(http.statusCode)
        }
    }

    private func quotaRequest(token: String) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")
        request.setValue("CodexQuotaBar/1.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func refreshAccessToken(for slot: AccountSlot, allowsUserInteraction: Bool) async throws -> String? {
        guard let refreshToken = try await secret(
            account: SecretAccount.refreshToken(slotID: slot.slotID),
            allowsUserInteraction: allowsUserInteraction
        ),
              let clientID = try await secret(
                account: SecretAccount.clientID(slotID: slot.slotID),
                allowsUserInteraction: allowsUserInteraction
              )
        else {
            return nil
        }

        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.unsupportedSchema
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 { throw ProviderError.unauthorized }
            if http.statusCode == 429 { throw ProviderError.rateLimited }
            throw ProviderError.server(http.statusCode)
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = object["access_token"] as? String
        else {
            throw ProviderError.unsupportedSchema
        }

        try await setSecret(accessToken, account: SecretAccount.accessToken(slotID: slot.slotID))
        if let newRefreshToken = object["refresh_token"] as? String {
            try await setSecret(newRefreshToken, account: SecretAccount.refreshToken(slotID: slot.slotID))
        }
        if let idToken = object["id_token"] as? String {
            try await setSecret(idToken, account: SecretAccount.idToken(slotID: slot.slotID))
        }
        return accessToken
    }

    private func secret(account: String, allowsUserInteraction: Bool) async throws -> String? {
        let secretStore = secretStore
        return try await Task.detached(priority: .utility) {
            try secretStore.get(account: account, allowsUserInteraction: allowsUserInteraction)
        }.value
    }

    private func setSecret(_ value: String, account: String) async throws {
        let secretStore = secretStore
        try await Task.detached(priority: .utility) {
            try secretStore.set(value, account: account)
        }.value
    }

    private func decodeSnapshotWithSupplementalRateLimits(data: Data, slot: AccountSlot) async throws -> QuotaSnapshot {
        let snapshot = try decodeSnapshot(data: data, slot: slot)
        guard !snapshot.quotaWindows.contains(where: { $0.title.hasPrefix("Spark") }),
              let supplementalData = await fetchSupplementalRateLimitsData(),
              let merged = try? mergeSupplementalRateLimits(data: supplementalData, into: snapshot)
        else {
            return snapshot
        }
        return merged
    }

    public func decodeSnapshot(data: Data, slot: AccountSlot) throws -> QuotaSnapshot {
        if let direct = try? DateCoding.jsonDecoder.decode(QuotaSnapshot.self, from: data) {
            return direct
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.unsupportedSchema
        }

        let root = object["data"] as? [String: Any] ?? object
        let planType = root.string(at: ["planType"]) ?? root.string(at: ["plan", "type"]) ?? root.string(at: ["subscription", "plan_type"])
            ?? root.string(at: ["plan_type"])
        let primaryRateLimit = primaryRateLimit(from: root)
        let credits = root.string(at: ["creditsBalance"])
            ?? root.string(at: ["credits", "balance"])
            ?? primaryRateLimit?.string(at: ["credits", "balance"])

        if let rateLimit = primaryRateLimit {
            return try decodeRateLimitSnapshot(rateLimit: rateLimit, root: root, slot: slot, planType: planType, credits: credits)
        }

        let windowsRaw = root["quotaWindows"] as? [[String: Any]]
            ?? root["quota_windows"] as? [[String: Any]]
            ?? root["limits"] as? [[String: Any]]
            ?? []

        let windows = windowsRaw.compactMap { raw -> QuotaWindow? in
            let kindString = raw.string(at: ["kind"]) ?? raw.string(at: ["type"]) ?? "unknown"
            let kind = QuotaWindowKind(rawValue: kindString) ?? (kindString.contains("week") ? .weekly : kindString.contains("session") || kindString.contains("5h") ? .session : .unknown)
            let title = raw.string(at: ["title"]) ?? (kind == .weekly ? "Weekly" : kind == .session ? "5h" : "Quota")
            let remaining = raw.int(at: ["remainingPercent"])
                ?? raw.int(at: ["remaining_percent"])
                ?? raw.int(at: ["remaining"])
            let used = raw.int(at: ["usedPercent"])
                ?? raw.int(at: ["used_percent"])
                ?? raw.int(at: ["used"])
                ?? remaining.map { max(0, 100 - $0) }
            guard let remaining, let used else { return nil }
            let resetString = raw.string(at: ["resetAt"]) ?? raw.string(at: ["reset_at"])
            let resetAt = resetString.flatMap(DateCoding.parseISO8601)
            return QuotaWindow(
                id: raw.string(at: ["id"]) ?? "codex-official-\(kind.rawValue)",
                kind: kind,
                remainingPercent: remaining.clampedPercent,
                resetAt: resetAt,
                title: title,
                usedPercent: used.clampedPercent
            )
        }

        guard !windows.isEmpty else {
            throw ProviderError.unsupportedSchema
        }

        let remaining = windows.map(\.remainingPercent).min() ?? 0
        let used = windows.map(\.usedPercent).max() ?? 0
        let status: QuotaStatus = remaining <= 0 ? .exhausted : remaining < 20 ? .warning : .ok
        let noteParts = [
            planType.map { "Plan \($0)" },
            windows.map { "\($0.title) \($0.remainingPercent)%" }.joined(separator: " | "),
            credits.map { "Credits \($0)" }
        ].compactMap { $0 }

        return QuotaSnapshot(
            accountLabel: slot.displayName,
            fetchHealth: .ok,
            note: noteParts.joined(separator: " | "),
            quotaWindows: windows,
            remaining: remaining,
            status: status,
            updatedAt: Date(),
            used: used,
            extras: [
                "planType": planType,
                "creditsBalance": credits
            ].compactMapValues { $0 },
            rawMeta: [
                "codex.accountId": slot.accountID,
                "codex.accountKey": slot.accountKey,
                "codex.accountLabel": slot.displayName,
                "codex.slotID": slot.slotID
            ].compactMapValues { $0 }
        )
    }

    private func decodeRateLimitSnapshot(
        rateLimit: [String: Any],
        root: [String: Any],
        slot: AccountSlot,
        planType: String?,
        credits: String?
    ) throws -> QuotaSnapshot {
        let primary = rateLimit.dictionary(at: ["primary_window"]) ?? rateLimit.dictionary(at: ["primary"])
        let secondary = rateLimit.dictionary(at: ["secondary_window"]) ?? rateLimit.dictionary(at: ["secondary"])

        var windows: [QuotaWindow] = []
        if let primary, let window = decodeRateWindow(primary, id: "codex-official-session", kind: .session, title: "5h") {
            windows.append(window)
        }
        if let secondary, let window = decodeRateWindow(secondary, id: "codex-official-weekly", kind: .weekly, title: "Weekly") {
            windows.append(window)
        }
        windows.append(contentsOf: decodeSparkWindows(from: root))

        guard !windows.isEmpty else {
            throw ProviderError.unsupportedSchema
        }

        let sessionRemaining = windows.first(where: { $0.kind == .session })?.remainingPercent
        let remaining = sessionRemaining ?? windows.map(\.remainingPercent).min() ?? 0
        let used = windows.map(\.usedPercent).max() ?? 0
        let allowed = rateLimit["allowed"] as? Bool ?? true
        let limitReached = rateLimit["limit_reached"] as? Bool ?? false
        let status: QuotaStatus = !allowed || limitReached || remaining <= 0 ? .exhausted : remaining < 20 ? .warning : .ok

        let noteParts = [
            planType.map { "Plan \($0)" },
            windows.map { "\($0.title) \($0.remainingPercent)%" }.joined(separator: " | "),
            credits.map { "Credits \($0)" }
        ].compactMap { $0 }

        return QuotaSnapshot(
            accountLabel: root.string(at: ["email"]) ?? slot.displayName,
            fetchHealth: .ok,
            note: noteParts.joined(separator: " | "),
            quotaWindows: windows,
            remaining: remaining,
            status: status,
            updatedAt: Date(),
            used: used,
            extras: [
                "planType": planType,
                "creditsBalance": credits
            ].compactMapValues { $0 },
            rawMeta: [
                "codex.accountId": root.string(at: ["account_id"]) ?? slot.accountID,
                "codex.accountKey": slot.accountKey,
                "codex.accountLabel": root.string(at: ["email"]) ?? slot.displayName,
                "codex.slotID": slot.slotID,
                "codex.userId": root.string(at: ["user_id"])
            ].compactMapValues { $0 }
        )
    }

    public func mergeSupplementalRateLimits(data: Data, into snapshot: QuotaSnapshot) throws -> QuotaSnapshot {
        let sparkWindows = try decodeSupplementalRateLimitWindows(data: data)
        guard !sparkWindows.isEmpty else {
            return snapshot
        }

        var merged = snapshot
        merged.quotaWindows.removeAll { $0.title.hasPrefix("Spark") }
        merged.quotaWindows.append(contentsOf: sparkWindows)
        return merged
    }

    public func decodeSupplementalRateLimitWindows(data: Data) throws -> [QuotaWindow] {
        let payload = Self.accountRateLimitsResponseData(from: data) ?? data
        guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw ProviderError.unsupportedSchema
        }

        let root = object.dictionary(at: ["result"])
            ?? object.dictionary(at: ["data"])
            ?? object
        return decodeSparkWindows(from: root)
    }

    private func primaryRateLimit(from root: [String: Any]) -> [String: Any]? {
        if let rateLimit = root.dictionary(at: ["rate_limit"]) ?? root.dictionary(at: ["rateLimits"]) {
            return rateLimit
        }

        let buckets = rateLimitBuckets(from: root)
        if let codex = buckets["codex"] {
            return codex
        }
        return buckets.first { key, bucket in
            let limitID = bucket.string(at: ["limitId"]) ?? bucket.string(at: ["limit_id"]) ?? key
            return limitID == "codex"
        }?.value
    }

    private func rateLimitBuckets(from root: [String: Any]) -> [String: [String: Any]] {
        let rawBuckets = root.dictionary(at: ["rateLimitsByLimitId"])
            ?? root.dictionary(at: ["rate_limits_by_limit_id"])
            ?? [:]

        var buckets: [String: [String: Any]] = [:]
        for (key, value) in rawBuckets {
            if let bucket = value as? [String: Any] {
                buckets[key] = bucket
            }
        }
        return buckets
    }

    private func decodeSparkWindows(from root: [String: Any]) -> [QuotaWindow] {
        guard let bucket = rateLimitBuckets(from: root).first(where: { key, bucket in
            isSparkRateLimitBucket(key: key, bucket: bucket)
        })?.value else {
            return []
        }

        let limitID = bucket.string(at: ["limitId"]) ?? bucket.string(at: ["limit_id"]) ?? "codex-spark"
        var windows: [QuotaWindow] = []
        if let primary = bucket.dictionary(at: ["primary_window"]) ?? bucket.dictionary(at: ["primary"]),
           let window = decodeRateWindow(primary, id: "\(limitID)-session", kind: .unknown, title: "Spark 5小时") {
            windows.append(window)
        }
        if let secondary = bucket.dictionary(at: ["secondary_window"]) ?? bucket.dictionary(at: ["secondary"]),
           let window = decodeRateWindow(secondary, id: "\(limitID)-weekly", kind: .unknown, title: "Spark 每周") {
            windows.append(window)
        }
        return windows
    }

    private func isSparkRateLimitBucket(key: String, bucket: [String: Any]) -> Bool {
        [
            key,
            bucket.string(at: ["limitId"]),
            bucket.string(at: ["limit_id"]),
            bucket.string(at: ["limitName"]),
            bucket.string(at: ["limit_name"])
        ]
        .compactMap { $0?.lowercased() }
        .contains { value in
            value.contains("spark") || value.contains("bengalfox")
        }
    }

    private func fetchSupplementalRateLimitsData() async -> Data? {
        if let cached = await supplementalRateLimitsCache.data(maxAge: Self.supplementalRateLimitsFreshCacheAge) {
            return cached
        }

        guard let data = await Self.runSupplementalRateLimitsCommand(timeout: Self.supplementalRateLimitsTimeout) else {
            return await supplementalRateLimitsCache.data(maxAge: Self.supplementalRateLimitsStaleCacheAge)
        }
        await supplementalRateLimitsCache.store(data)
        return data
    }

    private static func codexExecutablePath() -> String? {
        let candidates = [
            ProcessInfo.processInfo.environment["CODEX_CLI_PATH"],
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func accountRateLimitsResponseData(from output: Data) -> Data? {
        guard let text = String(data: output, encoding: .utf8) else {
            return nil
        }
        return text.split(separator: "\n")
            .last { line in
                line.contains(#""id":2"#) && line.contains(#""result""#)
            }
            .map { Data($0.utf8) }
    }

    private static func runSupplementalRateLimitsCommand(timeout: TimeInterval) async -> Data? {
        await Task.detached(priority: .utility) {
            runSupplementalRateLimitsCommandSync(timeout: timeout)
        }.value
    }

    private static func runSupplementalRateLimitsCommandSync(timeout: TimeInterval) -> Data? {
        guard let codexPath = codexExecutablePath() else {
            return nil
        }

        let initializeMessage = #"{"method":"initialize","id":1,"params":{"clientInfo":{"name":"codex-quota-bar","version":"0.1.0"},"capabilities":{"experimentalApi":true}}}"#
        let rateLimitMessage = #"{"method":"account/rateLimits/read","id":2}"#

        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = ["app-server", "--listen", "stdio://"]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        let semaphore = DispatchSemaphore(value: 0)
        let output = LockedBox<Data?>(nil)

        process.terminationHandler = { _ in
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            output.set(data)
            semaphore.signal()
        }

        do {
            try process.run()
            let input = "\(initializeMessage)\n\(rateLimitMessage)\n"
            if let inputData = input.data(using: .utf8) {
                inputPipe.fileHandleForWriting.write(inputData)
            }
            try? inputPipe.fileHandleForWriting.close()
        } catch {
            return nil
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning {
                process.terminate()
            }
            return nil
        }

        let completedOutput = output.get()
        guard let completedOutput else {
            return nil
        }
        return accountRateLimitsResponseData(from: completedOutput)
    }

    private func decodeRateWindow(
        _ raw: [String: Any],
        id: String,
        kind: QuotaWindowKind,
        title: String
    ) -> QuotaWindow? {
        guard let used = raw.int(at: ["used_percent"]) ?? raw.int(at: ["usedPercent"]) else {
            return nil
        }
        let resetAt: Date?
        if let epoch = raw.int(at: ["reset_at"]) {
            resetAt = Date(timeIntervalSince1970: TimeInterval(epoch))
        } else if let epoch = raw.int(at: ["resetsAt"]) ?? raw.int(at: ["resetAt"]) {
            resetAt = Date(timeIntervalSince1970: TimeInterval(epoch))
        } else if let seconds = raw.int(at: ["reset_after_seconds"]) {
            resetAt = Date().addingTimeInterval(TimeInterval(seconds))
        } else {
            resetAt = nil
        }
        return QuotaWindow(
            id: id,
            kind: kind,
            remainingPercent: (100 - used).clampedPercent,
            resetAt: resetAt,
            title: title,
            usedPercent: used.clampedPercent
        )
    }
}

private extension Dictionary where Key == String, Value == Any {
    func string(at path: [String]) -> String? {
        value(at: path).flatMap { value in
            if let string = value as? String { return string }
            if let number = value as? NSNumber { return number.stringValue }
            return nil
        }
    }

    func int(at path: [String]) -> Int? {
        value(at: path).flatMap { value in
            if let int = value as? Int { return int }
            if let number = value as? NSNumber { return number.intValue }
            if let string = value as? String { return Int(string) }
            return nil
        }
    }

    func value(at path: [String]) -> Any? {
        var current: Any? = self
        for key in path {
            current = (current as? [String: Any])?[key]
        }
        return current
    }

    func dictionary(at path: [String]) -> [String: Any]? {
        value(at: path) as? [String: Any]
    }
}

private extension Int {
    var clampedPercent: Int { Swift.min(100, Swift.max(0, self)) }
}

private actor SupplementalRateLimitsCache {
    private var cachedData: Data?
    private var cachedAt: Date?

    func data(maxAge: TimeInterval) -> Data? {
        guard let cachedData, let cachedAt, Date().timeIntervalSince(cachedAt) <= maxAge else {
            return nil
        }
        return cachedData
    }

    func store(_ data: Data) {
        cachedData = data
        cachedAt = Date()
    }
}
