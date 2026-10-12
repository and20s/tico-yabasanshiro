import Foundation
import UIKit

/// Stores one screenshot per save, captured when the emulator writes it.
/// Saves made before this feature existed simply have none.
final class BackupScreenshotStore {
    private let rootDirectory: URL

    init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory ?? FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("backup_screenshots")
    }

    func save(_ image: UIImage, fileKey: String, filename: String) {
        guard let data = image.pngData() else { return }
        save(pngData: data, fileKey: fileKey, filename: filename)
    }

    /// Stores a screenshot that arrives already encoded, as a cloud or a
    /// community download does. The bytes go to disk unchanged; decoding and
    /// re-encoding a PNG only loses time.
    func save(pngData: Data, fileKey: String, filename: String) {
        let url = fileURL(fileKey: fileKey, filename: filename)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? pngData.write(to: url, options: .atomic)
    }

    /// Carries a save's screenshot over to another backup file. The store is
    /// keyed by file, so a save copied between files would otherwise land
    /// without its image. A save that has none copies nothing, which is the
    /// ordinary case for saves written before this feature existed.
    func copy(fileKey: String, filename: String, toFileKey destination: String) {
        guard let source = path(fileKey: fileKey, filename: filename),
              let data = try? Data(contentsOf: URL(fileURLWithPath: source))
        else { return }
        save(pngData: data, fileKey: destination, filename: filename)
    }

    func path(fileKey: String, filename: String) -> String? {
        let url = fileURL(fileKey: fileKey, filename: filename)
        return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }

    func delete(fileKey: String, filename: String) {
        try? FileManager.default.removeItem(at: fileURL(fileKey: fileKey,
                                                        filename: filename))
    }

    private func fileURL(fileKey: String, filename: String) -> URL {
        rootDirectory
            .appendingPathComponent(fileKey)
            .appendingPathComponent("backup_\(filename).png")
    }
}
