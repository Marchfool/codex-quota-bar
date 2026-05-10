import Foundation

public protocol SlotStore: Sendable {
    func load() throws -> SlotFile
    func save(_ file: SlotFile) throws
}

public final class FileSlotStore: SlotStore, @unchecked Sendable {
    public let fileURL: URL
    private let fileManager: FileManager

    public init(
        fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexQuotaBar/codex_slots.json"),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public func load() throws -> SlotFile {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return SlotFile()
        }
        let data = try Data(contentsOf: fileURL)
        return try DateCoding.jsonDecoder.decode(SlotFile.self, from: data)
    }

    public func save(_ file: SlotFile) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try DateCoding.jsonEncoder.encode(file)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}
