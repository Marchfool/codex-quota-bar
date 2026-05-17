import Foundation

public protocol CodexQuotaProvider: Sendable {
    func fetchQuota(for slot: AccountSlot) async throws -> QuotaSnapshot
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
    private let secretStore: SecretStore
    private let session: URLSession
    private let endpoint: URL
    private let tokenEndpoint: URL

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
        let token: String
        if let storedToken = try secretStore.get(account: SecretAccount.accessToken(slotID: slot.slotID)) {
            token = storedToken
        } else if let refreshedToken = try await refreshAccessToken(for: slot) {
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
            return try decodeSnapshot(data: data, slot: slot)
        case 401, 403:
            guard let refreshedToken = try await refreshAccessToken(for: slot) else {
                throw ProviderError.unauthorized
            }
            let (retryData, retryResponse) = try await session.data(for: quotaRequest(token: refreshedToken))
            guard let retryHTTP = retryResponse as? HTTPURLResponse else {
                throw ProviderError.unsupportedSchema
            }
            guard retryHTTP.statusCode == 200 else {
                throw retryHTTP.statusCode == 429 ? ProviderError.rateLimited : ProviderError.server(retryHTTP.statusCode)
            }
            return try decodeSnapshot(data: retryData, slot: slot)
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

    private func refreshAccessToken(for slot: AccountSlot) async throws -> String? {
        guard let refreshToken = try secretStore.get(account: SecretAccount.refreshToken(slotID: slot.slotID)),
              let clientID = try secretStore.get(account: SecretAccount.clientID(slotID: slot.slotID))
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

        try secretStore.set(accessToken, account: SecretAccount.accessToken(slotID: slot.slotID))
        if let newRefreshToken = object["refresh_token"] as? String {
            try secretStore.set(newRefreshToken, account: SecretAccount.refreshToken(slotID: slot.slotID))
        }
        if let idToken = object["id_token"] as? String {
            try secretStore.set(idToken, account: SecretAccount.idToken(slotID: slot.slotID))
        }
        return accessToken
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
        let credits = root.string(at: ["creditsBalance"]) ?? root.string(at: ["credits", "balance"])

        if let rateLimit = root["rate_limit"] as? [String: Any] {
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
        let primary = rateLimit["primary_window"] as? [String: Any]
        let secondary = rateLimit["secondary_window"] as? [String: Any]

        var windows: [QuotaWindow] = []
        if let primary, let window = decodeRateWindow(primary, id: "codex-official-session", kind: .session, title: "5h") {
            windows.append(window)
        }
        if let secondary, let window = decodeRateWindow(secondary, id: "codex-official-weekly", kind: .weekly, title: "Weekly") {
            windows.append(window)
        }

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
}

private extension Int {
    var clampedPercent: Int { Swift.min(100, Swift.max(0, self)) }
}
