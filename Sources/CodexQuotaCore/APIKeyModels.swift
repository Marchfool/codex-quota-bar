import Foundation

public enum APIKeyProviderID: String, Codable, CaseIterable, Sendable {
    case deepseek
    case minimax
    case comfly

    public var displayName: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .minimax: return "MiniMax"
        case .comfly: return "Comfly"
        }
    }

    public var colorHex: String {
        switch self {
        case .deepseek: return "#2563EB"
        case .minimax: return "#7C3AED"
        case .comfly: return "#F59E0B"
        }
    }
}

public struct APIKeyField: Codable, Equatable, Identifiable, Sendable {
    public var id: String { key }
    public var key: String
    public var label: String
    public var placeholder: String
    public var isSecure: Bool
    public var value: String?

    public init(key: String, label: String, placeholder: String, isSecure: Bool, value: String? = nil) {
        self.key = key
        self.label = label
        self.placeholder = placeholder
        self.isSecure = isSecure
        self.value = value
    }
}

public struct APIKeyProviderConfig: Codable, Equatable, Identifiable, Sendable {
    public var id: APIKeyProviderID
    public var displayName: String
    public var colorHex: String
    public var fields: [APIKeyField]
    public var isEnabled: Bool
    public var lastSnapshot: APIBalanceSnapshot?

    public init(
        id: APIKeyProviderID,
        displayName: String,
        colorHex: String,
        fields: [APIKeyField],
        isEnabled: Bool = true,
        lastSnapshot: APIBalanceSnapshot? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.colorHex = colorHex
        self.fields = fields
        self.isEnabled = isEnabled
        self.lastSnapshot = lastSnapshot
    }

    public static var defaults: [APIKeyProviderConfig] {
        [
            APIKeyProviderConfig(
                id: .deepseek,
                displayName: APIKeyProviderID.deepseek.displayName,
                colorHex: APIKeyProviderID.deepseek.colorHex,
                fields: [
                    APIKeyField(key: "apiKey", label: "API Key", placeholder: "sk-...", isSecure: true),
                    APIKeyField(key: "progressFullBalance", label: "满格余额(元)", placeholder: "10", isSecure: false, value: "10")
                ]
            ),
            APIKeyProviderConfig(
                id: .minimax,
                displayName: APIKeyProviderID.minimax.displayName,
                colorHex: APIKeyProviderID.minimax.colorHex,
                fields: [
                    APIKeyField(key: "apiKey", label: "API Key", placeholder: "eyJhbGci...", isSecure: true)
                ]
            ),
            APIKeyProviderConfig(
                id: .comfly,
                displayName: APIKeyProviderID.comfly.displayName,
                colorHex: APIKeyProviderID.comfly.colorHex,
                fields: [
                    APIKeyField(key: "userId", label: "用户 ID", placeholder: "New-API-User", isSecure: false),
                    APIKeyField(key: "token", label: "API Token", placeholder: "sk-...", isSecure: true)
                ]
            )
        ]
    }
}

public struct APIBalanceSnapshot: Codable, Equatable, Sendable {
    public var balance: String
    public var used: String?
    public var total: String?
    public var usedPercent: Int
    public var unit: String?
    public var currency: String?
    public var status: QuotaStatus
    public var note: String?
    public var updatedAt: Date
    public var extras: [String: String]

    public init(
        balance: String,
        used: String? = nil,
        total: String? = nil,
        usedPercent: Int,
        unit: String? = nil,
        currency: String? = nil,
        status: QuotaStatus = .ok,
        note: String? = nil,
        updatedAt: Date = Date(),
        extras: [String: String] = [:]
    ) {
        self.balance = balance
        self.used = used
        self.total = total
        self.usedPercent = min(100, max(0, usedPercent))
        self.unit = unit
        self.currency = currency
        self.status = status
        self.note = note
        self.updatedAt = updatedAt
        self.extras = extras
    }
}

public struct APIKeyConfigFile: Codable, Equatable, Sendable {
    public var providers: [APIKeyProviderConfig]

    public init(providers: [APIKeyProviderConfig] = APIKeyProviderConfig.defaults) {
        self.providers = providers
    }
}
