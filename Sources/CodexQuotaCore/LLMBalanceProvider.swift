import Foundation

public protocol APIBalanceProvider: Sendable {
    func fetchBalance(for config: APIKeyProviderConfig, credentials: [String: String]) async throws -> APIBalanceSnapshot
}

public enum APIBalanceError: Error, LocalizedError, Equatable {
    case missingCredential(String)
    case unsupportedSchema
    case provider(String)
    case server(Int)

    public var errorDescription: String? {
        switch self {
        case .missingCredential(let field):
            return "缺少 \(field)"
        case .unsupportedSchema:
            return "余额响应格式不支持"
        case .provider(let message):
            return message
        case .server(let code):
            return "余额接口返回 HTTP \(code)"
        }
    }
}

public final class LLMBalanceProvider: APIBalanceProvider, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchBalance(for config: APIKeyProviderConfig, credentials: [String: String]) async throws -> APIBalanceSnapshot {
        let request = try makeRequest(for: config.id, credentials: credentials)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIBalanceError.unsupportedSchema
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIBalanceError.server(http.statusCode)
        }
        return try decodeBalance(data: data, providerID: config.id, credentials: credentials)
    }

    public func decodeBalance(data: Data, providerID: APIKeyProviderID) throws -> APIBalanceSnapshot {
        try decodeBalance(data: data, providerID: providerID, credentials: [:])
    }

    private func decodeBalance(data: Data, providerID: APIKeyProviderID, credentials: [String: String]) throws -> APIBalanceSnapshot {
        switch providerID {
        case .deepseek:
            return try decodeDeepSeek(data, fullBalance: deepSeekFullBalance(from: credentials))
        case .minimax:
            return try decodeMiniMax(data)
        case .comfly:
            return try decodeComfly(data)
        case .claude:
            return try decodeClaude(data)
        }
    }

    private func makeRequest(for providerID: APIKeyProviderID, credentials: [String: String]) throws -> URLRequest {
        switch providerID {
        case .deepseek:
            let apiKey = try required(credentials["apiKey"], name: "API Key")
            var request = URLRequest(url: URL(string: "https://api.deepseek.com/user/balance")!)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            return request
        case .minimax:
            let apiKey = try required(credentials["apiKey"], name: "API Key")
            var request = URLRequest(url: URL(string: "https://www.minimaxi.com/v1/token_plan/remains")!)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            return request
        case .comfly:
            let userID = try required(credentials["userId"], name: "用户 ID")
            let token = try required(credentials["token"], name: "API Token")
            var request = URLRequest(url: URL(string: "https://ai.comfly.org/api/user/self")!)
            request.setValue(userID, forHTTPHeaderField: "New-API-User")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            return request
        case .claude:
            let sessionKey = try required(credentials["sessionKey"], name: "Session Key")
            var request = URLRequest(url: URL(string: "https://claude.ai/api/organizations")!)
            request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
            return request
        }
    }

    private func required(_ value: String?, name: String) throws -> String {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIBalanceError.missingCredential(name)
        }
        return value
    }

    private func decodeDeepSeek(_ data: Data, fullBalance: Decimal) throws -> APIBalanceSnapshot {
        let response = try JSONDecoder().decode(DeepSeekBalanceResponse.self, from: data)
        guard response.isAvailable else {
            throw APIBalanceError.provider("DeepSeek 账户不可用")
        }
        guard let info = response.balanceInfos.first else {
            throw APIBalanceError.unsupportedSchema
        }

        let balance = Decimal(string: info.totalBalance) ?? 0
        let granted = Decimal(string: info.grantedBalance) ?? 0
        let toppedUp = Decimal(string: info.toppedUpBalance) ?? 0
        let balanceDouble = (balance as NSDecimalNumber).doubleValue
        let fullDouble = max(0.01, (fullBalance as NSDecimalNumber).doubleValue)
        let remainingPercent = min(100, max(0, Int((balanceDouble / fullDouble * 100).rounded())))
        let usedPercent = max(0, 100 - remainingPercent)

        return APIBalanceSnapshot(
            balance: "¥\(formatMoney(balance))",
            total: "¥\(formatMoney(fullBalance))",
            usedPercent: usedPercent,
            currency: info.currency,
            status: balance <= 0 || remainingPercent < 20 ? .warning : .ok,
            extras: [
                "grantedBalance": "¥\(formatMoney(granted))",
                "toppedUpBalance": "¥\(formatMoney(toppedUp))",
                "displayFullBalance": "¥\(formatMoney(fullBalance))",
                "remainingPercent": "\(remainingPercent)"
            ]
        )
    }

    private func deepSeekFullBalance(from credentials: [String: String]) -> Decimal {
        let raw = credentials["progressFullBalance"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, let value = Decimal(string: raw), value > 0 else {
            return 10
        }
        return value
    }

    private func decodeMiniMax(_ data: Data) throws -> APIBalanceSnapshot {
        let response = try JSONDecoder().decode(MiniMaxBalanceResponse.self, from: data)
        guard response.baseResp?.statusCode == 0 else {
            throw APIBalanceError.provider(response.baseResp?.statusMessage ?? "MiniMax 查询失败")
        }
        guard let model = response.modelRemains.first(where: { $0.modelName.hasPrefix("MiniMax-M") }) ?? response.modelRemains.first else {
            throw APIBalanceError.unsupportedSchema
        }

        let weeklyTotal = model.currentWeeklyTotalCount
        let weeklyUsed = model.currentWeeklyUsageCount
        let weeklyRemains = max(0, weeklyTotal - weeklyUsed)
        let weeklyPercent = weeklyTotal > 0 ? min(100, Int((Double(weeklyUsed) / Double(weeklyTotal) * 100).rounded())) : 0
        let intervalTotal = model.currentIntervalTotalCount
        let intervalUsed = model.currentIntervalUsageCount
        let intervalRemains = max(0, intervalTotal - intervalUsed)
        let intervalPercent = intervalTotal > 0 ? min(100, Int((Double(intervalUsed) / Double(intervalTotal) * 100).rounded())) : 0
        let intervalMinutes = model.remainsTime / 60_000
        let intervalTime = "\(intervalMinutes / 60)小时\(intervalMinutes % 60)分"
        let intervalResetAt = Date().addingTimeInterval(TimeInterval(model.remainsTime / 1000))

        return APIBalanceSnapshot(
            balance: "\(weeklyRemains)",
            used: "\(weeklyUsed)",
            total: "\(weeklyTotal)",
            usedPercent: weeklyPercent,
            unit: "次/周",
            currency: "TokenPlan",
            status: weeklyRemains <= 0 ? .warning : .ok,
            extras: [
                "weeklyRemains": "\(weeklyRemains)",
                "weeklyUsed": "\(weeklyUsed)",
                "weeklyTotal": "\(weeklyTotal)",
                "weeklyUsedPercent": "\(weeklyPercent)",
                "weeklyRemainingPercent": "\(max(0, 100 - weeklyPercent))",
                "modelName": model.modelName,
                "intervalRemains": "\(intervalRemains)",
                "intervalUsed": "\(intervalUsed)",
                "intervalTotal": "\(intervalTotal)",
                "intervalUsedPercent": "\(intervalPercent)",
                "intervalRemainingPercent": "\(max(0, 100 - intervalPercent))",
                "intervalRemainsTime": intervalTime,
                "intervalResetAt": DateCoding.formatISO8601(intervalResetAt)
            ]
        )
    }

    private func decodeComfly(_ data: Data) throws -> APIBalanceSnapshot {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw APIBalanceError.provider("Comfly 返回非 JSON 响应，请检查用户 ID、API Token 或接口是否变更")
        }
        guard let object = json as? [String: Any] else {
            throw APIBalanceError.unsupportedSchema
        }
        let success = boolValue(object["success"]) ?? false
        guard success else {
            throw APIBalanceError.provider(stringValue(object["message"]) ?? stringValue(object["error"]) ?? "Comfly 查询失败")
        }
        guard let data = object["data"] as? [String: Any] else {
            throw APIBalanceError.unsupportedSchema
        }

        let quota = intValue(data["quota"]) ?? 0
        let usedQuota = intValue(data["used_quota"]) ?? intValue(data["usedQuota"]) ?? 0
        let totalQuota = quota + usedQuota
        let balanceDisplay = Double(quota) / 500_247
        let balanceYuan = balanceDisplay * 1.2
        let fullBalanceDisplay = Double(totalQuota) / 500_247 * 1.2
        let usedPercent = totalQuota > 0 ? min(100, Int((Double(usedQuota) / Double(totalQuota) * 100).rounded())) : 0

        return APIBalanceSnapshot(
            balance: "¥\(String(format: "%.2f", balanceYuan))",
            used: "\(usedQuota)",
            total: "\(totalQuota)",
            usedPercent: usedPercent,
            currency: "CNY",
            status: quota <= 0 ? .warning : .ok,
            extras: [
                "quota": "\(quota)",
                "usedQuota": "\(usedQuota)",
                "tokenBalance": String(format: "%.2f", balanceDisplay),
                "balanceYuan": "¥\(String(format: "%.2f", balanceYuan))",
                "displayFullBalance": "¥\(String(format: "%.2f", fullBalanceDisplay))"
            ]
        )
    }

    private func decodeClaude(_ data: Data) throws -> APIBalanceSnapshot {
        // Try new envelope format {organizations, usage, limits}
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let orgsArray: [[String: Any]]?
        let usageObj: [String: Any]?
        let limitsObj: [String: Any]?
        let designUsageObj: [String: Any]?

        if let root {
            orgsArray = root["organizations"] as? [[String: Any]]
            usageObj = root["usage"] as? [String: Any]
            limitsObj = root["limits"] as? [String: Any]
            designUsageObj = root["designUsage"] as? [String: Any]
            // Log raw keys for debugging
            NSLog("[Claude] usage keys: %@", (usageObj?.keys.map { $0 } ?? []).joined(separator: ","))
            NSLog("[Claude] limits keys: %@", (limitsObj?.keys.map { $0 } ?? []).joined(separator: ","))
            if let designUsageObj {
                NSLog("[Claude] designUsage keys: %@", designUsageObj.keys.joined(separator: ","))
            } else {
                NSLog("[Claude] designUsage missing from payload")
            }
        } else {
            // Fallback: old format was plain organizations array
            orgsArray = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
            usageObj = nil
            limitsObj = nil
            designUsageObj = nil
        }

        guard let org = orgsArray?.first else {
            throw APIBalanceError.unsupportedSchema
        }

        let tier = org["rate_limit_tier"] as? String ?? ""
        let capabilities = org["capabilities"] as? [String] ?? []
        let isPro = tier.lowercased().contains("pro")
            || tier.lowercased().contains("scale")
            || tier.lowercased().contains("team")
            || capabilities.contains("claude_pro")

        let billing = org["billing"] as? [String: Any]
        let billingStatus = billing?["status"] as? String ?? ""
        let billingPeriod = billing?["period"] as? String ?? "monthly"
        let isActive = billingStatus == "active" || isPro

        let planLabel: String
        if isPro {
            planLabel = "Pro"
        } else {
            switch tier.lowercased() {
            case "pro": planLabel = "Pro"
            case "team": planLabel = "Team"
            case "enterprise": planLabel = "Enterprise"
            case "scale": planLabel = "Scale"
            case _ where tier.lowercased().contains("pro"): planLabel = "Pro"
            case _ where tier.lowercased().contains("claude"): planLabel = "Claude.ai"
            default: planLabel = tier.isEmpty ? "Pro" : tier.capitalized
            }
        }

        let periodLabel = billingPeriod == "monthly" ? "按月续费" : billingPeriod

        // Try to extract usage data
        var extras: [String: String] = [
            "planName": planLabel,
            "billingStatus": isActive ? "订阅中" : (billingStatus.isEmpty ? "未激活" : billingStatus),
            "billingPeriod": periodLabel,
            "isActive": isActive ? "true" : "false",
            "rawTier": tier
        ]

        var usedPercent = isActive ? 0 : 100

        // Parse usage if available
        if let usage = usageObj {
            let fiveHour = usage["five_hour"] as? [String: Any]
            let sevenDay = usage["seven_day"] as? [String: Any]
            let design = (usage["seven_day_omelette"] as? [String: Any])
                ?? (usage["omelette"] as? [String: Any])
                ?? claudeLimitEntry(in: usage, matching: ["design", "omelette"])
                ?? limitsObj.flatMap { claudeLimitEntry(in: $0, matching: ["design"]) }
                ?? designUsageObj

            let fiveHourUtil = intValue(fiveHour?["utilization"]) ?? 0
            let sevenDayUtil = intValue(sevenDay?["utilization"]) ?? 0

            // Use the more constrained window as the headline percent
            usedPercent = max(fiveHourUtil, sevenDayUtil)

            extras["fiveHourUsed"] = "\(fiveHourUtil)"
            extras["sevenDayUsed"] = "\(sevenDayUtil)"

            if let resetsAt = fiveHour?["resets_at"] as? String {
                extras["fiveHourResetsAt"] = resetsAt
            }
            if let resetsAt = sevenDay?["resets_at"] as? String {
                extras["sevenDayResetsAt"] = resetsAt
            }

            if let design {
                let designUtil = intValue(design["utilization"] ?? design["used_percent"] ?? design["used"]) ?? 0
                extras["designUsed"] = "\(designUtil)"
                if let resetsAt = stringValue(design["resets_at"] ?? design["reset_at"] ?? design["resetAt"]) {
                    extras["designResetsAt"] = resetsAt
                }
                if let resetLabel = stringValue(design["reset_label"]) {
                    extras["designResetLabel"] = resetLabel
                }
                if let subtitle = stringValue(design["description"] ?? design["note"]) {
                    extras["designNote"] = subtitle
                }
            }
        }

        if extras["designUsed"] == nil, let design =
            (usageObj?["seven_day_omelette"] as? [String: Any])
            ?? (usageObj?["omelette"] as? [String: Any])
            ?? limitsObj.flatMap({ claudeLimitEntry(in: $0, matching: ["design", "omelette"]) })
            ?? designUsageObj {
            let designUtil = intValue(design["utilization"] ?? design["used_percent"] ?? design["used"]) ?? 0
            extras["designUsed"] = "\(designUtil)"
            if let resetsAt = stringValue(design["resets_at"] ?? design["reset_at"] ?? design["resetAt"]) {
                extras["designResetsAt"] = resetsAt
            }
            if let resetLabel = stringValue(design["reset_label"]) {
                extras["designResetLabel"] = resetLabel
            }
            if let subtitle = stringValue(design["description"] ?? design["note"]) {
                extras["designNote"] = subtitle
            }
        }

        return APIBalanceSnapshot(
            balance: planLabel,
            usedPercent: usedPercent,
            status: isActive ? (usedPercent >= 90 ? .warning : .ok) : .warning,
            extras: extras
        )
    }

    private func formatMoney(_ value: Decimal) -> String {
        let number = value as NSDecimalNumber
        return String(format: "%.2f", number.doubleValue)
    }

    private func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? Int { return value != 0 }
        if let value = value as? Double { return value != 0 }
        if let value = value as? String {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "ok", "success": return true
            case "false", "0", "error", "fail": return false
            default: return nil
            }
        }
        return nil
    }

    private func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value.rounded()) }
        if let value = value as? String {
            return Int(Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
        }
        return nil
    }

    private func stringValue(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value { return "\(value)" }
        return nil
    }

    private func claudeLimitEntry(in object: Any, matching terms: [String]) -> [String: Any]? {
        if let dict = object as? [String: Any] {
            for (key, value) in dict {
                let loweredKey = key.lowercased()
                let matchedKey = terms.contains(where: { loweredKey.contains($0) })
                if matchedKey, let child = value as? [String: Any], looksLikeClaudeLimitEntry(child) {
                    return child
                }
                if matchedKey, looksLikeClaudeLimitEntry(dict) {
                    return dict
                }
                if let nested = claudeLimitEntry(in: value, matching: terms) {
                    return nested
                }
            }
        } else if let array = object as? [Any] {
            for item in array {
                if let dict = item as? [String: Any] {
                    let searchable = [
                        stringValue(dict["name"]),
                        stringValue(dict["title"]),
                        stringValue(dict["label"]),
                        stringValue(dict["type"]),
                        stringValue(dict["kind"])
                    ]
                    .compactMap { $0?.lowercased() }
                    .joined(separator: " ")

                    if terms.contains(where: { searchable.contains($0) }), looksLikeClaudeLimitEntry(dict) {
                        return dict
                    }
                }
                if let nested = claudeLimitEntry(in: item, matching: terms) {
                    return nested
                }
            }
        }
        return nil
    }

    private func looksLikeClaudeLimitEntry(_ dict: [String: Any]) -> Bool {
        dict["utilization"] != nil
            || dict["used_percent"] != nil
            || dict["used"] != nil
            || dict["resets_at"] != nil
            || dict["reset_at"] != nil
            || dict["resetAt"] != nil
    }
}

private struct DeepSeekBalanceResponse: Decodable {
    var isAvailable: Bool
    var balanceInfos: [DeepSeekBalanceInfo]

    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balanceInfos = "balance_infos"
    }
}

private struct DeepSeekBalanceInfo: Decodable {
    var currency: String
    var totalBalance: String
    var grantedBalance: String
    var toppedUpBalance: String

    enum CodingKeys: String, CodingKey {
        case currency
        case totalBalance = "total_balance"
        case grantedBalance = "granted_balance"
        case toppedUpBalance = "topped_up_balance"
    }
}

private struct MiniMaxBalanceResponse: Decodable {
    var baseResp: MiniMaxBaseResponse?
    var modelRemains: [MiniMaxModelRemain]

    enum CodingKeys: String, CodingKey {
        case baseResp = "base_resp"
        case modelRemains = "model_remains"
    }
}

private struct MiniMaxBaseResponse: Decodable {
    var statusCode: Int
    var statusMessage: String?

    enum CodingKeys: String, CodingKey {
        case statusCode = "status_code"
        case statusMessage = "status_msg"
    }
}

private struct MiniMaxModelRemain: Decodable {
    var modelName: String
    var currentWeeklyTotalCount: Int
    var currentWeeklyUsageCount: Int
    var currentIntervalTotalCount: Int
    var currentIntervalUsageCount: Int
    var remainsTime: Int

    enum CodingKeys: String, CodingKey {
        case modelName = "model_name"
        case currentWeeklyTotalCount = "current_weekly_total_count"
        case currentWeeklyUsageCount = "current_weekly_usage_count"
        case currentIntervalTotalCount = "current_interval_total_count"
        case currentIntervalUsageCount = "current_interval_usage_count"
        case remainsTime = "remains_time"
    }
}
