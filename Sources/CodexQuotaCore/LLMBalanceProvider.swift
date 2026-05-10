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
        return try decodeBalance(data: data, providerID: config.id)
    }

    public func decodeBalance(data: Data, providerID: APIKeyProviderID) throws -> APIBalanceSnapshot {
        switch providerID {
        case .deepseek:
            return try decodeDeepSeek(data)
        case .minimax:
            return try decodeMiniMax(data)
        case .comfly:
            return try decodeComfly(data)
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
            var request = URLRequest(url: URL(string: "https://ai.comfly.chat/api/user/self")!)
            request.setValue(userID, forHTTPHeaderField: "New-API-User")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            return request
        }
    }

    private func required(_ value: String?, name: String) throws -> String {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIBalanceError.missingCredential(name)
        }
        return value
    }

    private func decodeDeepSeek(_ data: Data) throws -> APIBalanceSnapshot {
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
        let total = granted + toppedUp
        let used = max(0, total - balance)
        let totalDouble = (total as NSDecimalNumber).doubleValue
        let usedDouble = (used as NSDecimalNumber).doubleValue
        let usedPercent = totalDouble > 0 ? Int((usedDouble / totalDouble * 100).rounded()) : 0

        return APIBalanceSnapshot(
            balance: "¥\(formatMoney(balance))",
            used: "¥\(formatMoney(used))",
            total: "¥\(formatMoney(total))",
            usedPercent: usedPercent,
            currency: info.currency,
            status: balance <= 0 ? .warning : .ok
        )
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
                "intervalRemains": "\(intervalRemains)",
                "intervalUsed": "\(intervalUsed)",
                "intervalTotal": "\(intervalTotal)",
                "intervalUsedPercent": "\(intervalPercent)",
                "intervalRemainsTime": intervalTime
            ]
        )
    }

    private func decodeComfly(_ data: Data) throws -> APIBalanceSnapshot {
        let response = try JSONDecoder().decode(ComflyBalanceResponse.self, from: data)
        guard response.success else {
            throw APIBalanceError.provider(response.message ?? "Comfly 查询失败")
        }

        let quota = response.data.quota
        let usedQuota = response.data.usedQuota
        let totalQuota = quota + usedQuota
        let balanceDisplay = Double(quota) / 500_247
        let balanceYuan = balanceDisplay * 1.2
        let usedPercent = totalQuota > 0 ? min(100, Int((Double(usedQuota) / Double(totalQuota) * 100).rounded())) : 0

        return APIBalanceSnapshot(
            balance: "B|\(String(format: "%.2f", balanceDisplay))",
            used: "\(usedQuota)",
            total: "\(totalQuota)",
            usedPercent: usedPercent,
            currency: "CNY",
            status: quota <= 0 ? .warning : .ok,
            extras: [
                "quota": "\(quota)",
                "balanceYuan": "¥\(String(format: "%.2f", balanceYuan))"
            ]
        )
    }

    private func formatMoney(_ value: Decimal) -> String {
        let number = value as NSDecimalNumber
        return String(format: "%.2f", number.doubleValue)
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

private struct ComflyBalanceResponse: Decodable {
    var success: Bool
    var message: String?
    var data: ComflyBalanceData
}

private struct ComflyBalanceData: Decodable {
    var quota: Int
    var usedQuota: Int

    enum CodingKeys: String, CodingKey {
        case quota
        case usedQuota = "used_quota"
    }
}
