import Foundation

public struct ImportedCodexCredential: Equatable, Sendable {
    public var slot: AccountSlot
    public var profile: CodexProfile
    public var accessToken: String?
    public var refreshToken: String?
    public var idToken: String?

    public init(slot: AccountSlot, profile: CodexProfile, accessToken: String?, refreshToken: String?, idToken: String?) {
        self.slot = slot
        self.profile = profile
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
    }
}

public enum CodexAuthImportError: Error, LocalizedError {
    case authFileMissing(URL)
    case unsupportedAuthFile

    public var errorDescription: String? {
        switch self {
        case .authFileMissing(let url):
            return "Codex auth file was not found at \(url.path)."
        case .unsupportedAuthFile:
            return "Codex auth file did not contain a ChatGPT token set."
        }
    }
}

public final class CodexAuthImporter: @unchecked Sendable {
    public let authURL: URL
    private let secretStore: SecretStore
    private let profileStore: ProfileStore

    public init(
        authURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json"),
        secretStore: SecretStore,
        profileStore: ProfileStore = FileProfileStore()
    ) {
        self.authURL = authURL
        self.secretStore = secretStore
        self.profileStore = profileStore
    }

    public func currentCredentialFingerprint() throws -> String? {
        guard FileManager.default.fileExists(atPath: authURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: authURL)
        guard let authJSON = String(data: data, encoding: .utf8) else {
            throw CodexAuthImportError.unsupportedAuthFile
        }
        let auth = try JSONDecoder().decode(CodexAuthFile.self, from: data)
        guard auth.authMode == "chatgpt", let tokens = auth.tokens else {
            throw CodexAuthImportError.unsupportedAuthFile
        }
        return Self.credentialFingerprint(for: tokens, authJSON: authJSON)
    }

    public func importCurrentAccount() throws -> ImportedCodexCredential {
        guard FileManager.default.fileExists(atPath: authURL.path) else {
            throw CodexAuthImportError.authFileMissing(authURL)
        }

        let data = try Data(contentsOf: authURL)
        guard let authJSON = String(data: data, encoding: .utf8) else {
            throw CodexAuthImportError.unsupportedAuthFile
        }
        let auth = try JSONDecoder().decode(CodexAuthFile.self, from: data)
        guard auth.authMode == "chatgpt", let tokens = auth.tokens else {
            throw CodexAuthImportError.unsupportedAuthFile
        }

        let claims = JWTClaims.decode(from: tokens.idToken) ?? JWTClaims.decode(from: tokens.accessToken)
        let accountID = tokens.accountID ?? claims?.openAIAuth?["chatgpt_account_id"]?.stringValue
        let email = claims?.email ?? "Codex Account"
        let subject = claims?.subject ?? email
        let slotID = "A"
        let tenantKey = "account:\(accountID ?? "unknown")"
        let accountKey = "tenant:\(tenantKey)|principal:subject:\(subject)"
        let fingerprint = Self.credentialFingerprint(for: tokens, authJSON: authJSON)

        let slot = AccountSlot(
            slotID: slotID,
            accountKey: accountKey,
            displayName: email,
            accountID: accountID,
            isActive: true,
            lastSeenAt: Date()
        )
        let profile = CodexProfile(
            accountEmail: email,
            accountId: accountID,
            accountSubject: subject,
            credentialFingerprint: fingerprint,
            displayName: "Codex \(slotID)",
            identityKey: accountKey,
            isCurrentSystemAccount: true,
            lastImportedAt: Date(),
            slotID: slotID,
            tenantKey: tenantKey
        )

        if let accessToken = tokens.accessToken {
            try secretStore.set(accessToken, account: SecretAccount.accessToken(slotID: slotID))
        }
        if let refreshToken = tokens.refreshToken {
            try secretStore.set(refreshToken, account: SecretAccount.refreshToken(slotID: slotID))
        }
        if let idToken = tokens.idToken {
            try secretStore.set(idToken, account: SecretAccount.idToken(slotID: slotID))
        }
        if let clientID = claims?.clientID {
            try secretStore.set(clientID, account: SecretAccount.clientID(slotID: slotID))
        }
        try profileStore.upsert(profile)

        return ImportedCodexCredential(
            slot: slot,
            profile: profile,
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            idToken: tokens.idToken
        )
    }

    private static func credentialFingerprint(for tokens: CodexTokens, authJSON: String) -> String {
        let claims = JWTClaims.decode(from: tokens.idToken) ?? JWTClaims.decode(from: tokens.accessToken)
        let accountID = tokens.accountID ?? claims?.openAIAuth?["chatgpt_account_id"]?.stringValue
        let identityParts = [
            accountID,
            claims?.subject,
            claims?.email,
            claims?.clientID
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if !identityParts.isEmpty {
            return CredentialFingerprint.make(for: "codex-identity|" + identityParts.joined(separator: "|"))
        }
        return CredentialFingerprint.make(for: authJSON)
    }
}

public enum SecretAccount {
    public static func accessToken(slotID: String) -> String { "codex.\(slotID).access_token" }
    public static func refreshToken(slotID: String) -> String { "codex.\(slotID).refresh_token" }
    public static func idToken(slotID: String) -> String { "codex.\(slotID).id_token" }
    public static func clientID(slotID: String) -> String { "codex.\(slotID).client_id" }
    public static func cookieHeader(slotID: String) -> String { "codex.\(slotID).cookie_header" }
}

private struct CodexAuthFile: Decodable {
    var authMode: String?
    var tokens: CodexTokens?

    enum CodingKeys: String, CodingKey {
        case authMode = "auth_mode"
        case tokens
    }
}

private struct CodexTokens: Decodable {
    var idToken: String?
    var accessToken: String?
    var refreshToken: String?
    var accountID: String?

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case accountID = "account_id"
    }
}

private struct JWTClaims {
    var email: String?
    var subject: String?
    var clientID: String?
    var openAIAuth: [String: JSONValue]?

    static func decode(from jwt: String?) -> JWTClaims? {
        guard let jwt else { return nil }
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        return JWTClaims(
            email: object["email"] as? String,
            subject: object["sub"] as? String,
            clientID: object["client_id"] as? String,
            openAIAuth: (object["https://api.openai.com/auth"] as? [String: Any])?.mapValues(JSONValue.init(any:))
        )
    }
}

public enum JSONValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(any: Any) {
        switch any {
        case let value as String:
            self = .string(value)
        case let value as NSNumber:
            self = CFGetTypeID(value) == CFBooleanGetTypeID() ? .bool(value.boolValue) : .number(value.doubleValue)
        case let value as [String: Any]:
            self = .object(value.mapValues(JSONValue.init(any:)))
        case let value as [Any]:
            self = .array(value.map(JSONValue.init(any:)))
        default:
            self = .null
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}
