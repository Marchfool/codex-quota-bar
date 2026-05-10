import CryptoKit
import Foundation

public struct CodexProfileFile: Codable, Equatable, Sendable {
    public var profiles: [CodexProfile]

    public init(profiles: [CodexProfile] = []) {
        self.profiles = profiles
    }
}

public struct CodexProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: String { slotID }
    public var accountEmail: String
    public var accountId: String?
    public var accountSubject: String
    public var authJSON: String
    public var credentialFingerprint: String
    public var displayName: String
    public var identityKey: String
    public var isCurrentSystemAccount: Bool
    public var lastImportedAt: Date
    public var slotID: String
    public var tenantKey: String

    public init(
        accountEmail: String,
        accountId: String?,
        accountSubject: String,
        authJSON: String,
        credentialFingerprint: String,
        displayName: String,
        identityKey: String,
        isCurrentSystemAccount: Bool,
        lastImportedAt: Date,
        slotID: String,
        tenantKey: String
    ) {
        self.accountEmail = accountEmail
        self.accountId = accountId
        self.accountSubject = accountSubject
        self.authJSON = authJSON
        self.credentialFingerprint = credentialFingerprint
        self.displayName = displayName
        self.identityKey = identityKey
        self.isCurrentSystemAccount = isCurrentSystemAccount
        self.lastImportedAt = lastImportedAt
        self.slotID = slotID
        self.tenantKey = tenantKey
    }
}

public protocol ProfileStore: Sendable {
    func load() throws -> CodexProfileFile
    func save(_ file: CodexProfileFile) throws
    func upsert(_ profile: CodexProfile) throws
}

public final class FileProfileStore: ProfileStore, @unchecked Sendable {
    public let fileURL: URL
    private let fileManager: FileManager

    public init(
        fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexQuotaBar/codex_profiles.json"),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public func load() throws -> CodexProfileFile {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return CodexProfileFile()
        }
        let data = try Data(contentsOf: fileURL)
        return try DateCoding.jsonDecoder.decode(CodexProfileFile.self, from: data)
    }

    public func save(_ file: CodexProfileFile) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try DateCoding.jsonEncoder.encode(file)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    public func upsert(_ profile: CodexProfile) throws {
        var file = try load()
        if let index = file.profiles.firstIndex(where: { $0.slotID == profile.slotID }) {
            file.profiles[index] = profile
        } else {
            file.profiles.append(profile)
        }
        try save(file)
    }
}

public enum CredentialFingerprint {
    public static func make(for text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
