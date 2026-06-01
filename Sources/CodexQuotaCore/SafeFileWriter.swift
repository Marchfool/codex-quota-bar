import Foundation

enum SafeFileWriter {
    static func write(_ data: Data, to fileURL: URL, fileManager: FileManager) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let tempURL = directory
            .appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString)")
            .appendingPathExtension("tmp")

        do {
            try data.write(to: tempURL, options: [.atomic])
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(
                    fileURL,
                    withItemAt: tempURL,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try fileManager.moveItem(at: tempURL, to: fileURL)
            }
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw error
        }
    }
}
