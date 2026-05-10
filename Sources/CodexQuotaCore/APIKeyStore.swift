import Foundation

public protocol APIKeyConfigStore: Sendable {
    func load() throws -> APIKeyConfigFile
    func save(_ file: APIKeyConfigFile) throws
}

public final class FileAPIKeyConfigStore: APIKeyConfigStore, @unchecked Sendable {
    public let fileURL: URL
    private let fileManager: FileManager

    public init(
        fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexQuotaBar/api_keys.json"),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public func load() throws -> APIKeyConfigFile {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return APIKeyConfigFile()
        }
        let data = try Data(contentsOf: fileURL)
        var file = try DateCoding.jsonDecoder.decode(APIKeyConfigFile.self, from: data)
        mergeDefaults(into: &file)
        stripSecureValues(from: &file)
        return file
    }

    public func save(_ file: APIKeyConfigFile) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var sanitized = file
        mergeDefaults(into: &sanitized)
        stripSecureValues(from: &sanitized)
        let data = try DateCoding.jsonEncoder.encode(sanitized)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    private func mergeDefaults(into file: inout APIKeyConfigFile) {
        for defaultProvider in APIKeyProviderConfig.defaults where !file.providers.contains(where: { $0.id == defaultProvider.id }) {
            file.providers.append(defaultProvider)
        }
        file.providers.sort { $0.id.rawValue < $1.id.rawValue }
    }

    private func stripSecureValues(from file: inout APIKeyConfigFile) {
        for providerIndex in file.providers.indices {
            for fieldIndex in file.providers[providerIndex].fields.indices where file.providers[providerIndex].fields[fieldIndex].isSecure {
                file.providers[providerIndex].fields[fieldIndex].value = nil
            }
        }
    }
}

public enum APISecretAccount {
    public static func field(providerID: APIKeyProviderID, key: String) -> String {
        "api.\(providerID.rawValue).\(key)"
    }
}
