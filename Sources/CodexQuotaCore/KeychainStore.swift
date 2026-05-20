import Foundation
import LocalAuthentication
import Security

public protocol SecretStore: Sendable {
    func set(_ value: String, account: String) throws
    func get(account: String) throws -> String?
    func get(account: String, allowsUserInteraction: Bool) throws -> String?
    func delete(account: String) throws
}

public enum KeychainError: Error, LocalizedError {
    case unexpectedStatus(OSStatus)
    case userInteractionRequired

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "Keychain returned status \(status)."
        case .userInteractionRequired:
            return "Keychain requires user approval."
        }
    }
}

public extension SecretStore {
    func get(account: String, allowsUserInteraction: Bool) throws -> String? {
        try get(account: account)
    }
}

public final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    private let service: String

    public init(service: String = "com.codexquotabar.secrets") {
        self.service = service
    }

    public func set(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
            return
        }
        throw KeychainError.unexpectedStatus(status)
    }

    public func get(account: String) throws -> String? {
        try get(account: account, allowsUserInteraction: true)
    }

    public func get(account: String, allowsUserInteraction: Bool) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowsUserInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        if !allowsUserInteraction && (status == errSecInteractionNotAllowed || status == errSecAuthFailed) {
            throw KeychainError.userInteractionRequired
        }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
