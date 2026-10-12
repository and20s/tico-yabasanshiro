import Foundation

/// Moves the legacy cart/invalid.ram to its correctly named file.
///
/// GetCartridgePath used to fall through every switch case, so every
/// cartridge size was stored as cart/invalid.ram. The size on disc identifies
/// which cartridge it really is. When it does not, or when the destination
/// already exists, the file is left untouched: losing a save is worse than
/// leaving one behind.
struct CartridgeFileMigration {
    enum Outcome: Equatable {
        case nothingToDo
        case alreadyRun
        case migrated(to: BackupFile)
        case skippedUnknownSize
        case skippedDestinationExists
        case failed
    }

    private static let defaultsKey = "cartridgeInvalidRamMigrated"

    private let cartDirectory: URL
    private let defaults: UserDefaults

    init(cartDirectory: URL? = nil, defaults: UserDefaults = .standard) {
        self.cartDirectory = cartDirectory ?? URL(
            fileURLWithPath: BackupFile.cartridge4Mbit.path).deletingLastPathComponent()
        self.defaults = defaults
    }

    @discardableResult
    func run() -> Outcome {
        if defaults.bool(forKey: Self.defaultsKey) {
            return .alreadyRun
        }

        let manager = FileManager.default
        let source = cartDirectory.appendingPathComponent("invalid.ram")
        guard manager.fileExists(atPath: source.path) else {
            defaults.set(true, forKey: Self.defaultsKey)
            return .nothingToDo
        }

        guard let size = try? manager.attributesOfItem(
            atPath: source.path)[.size] as? Int,
              let target = BackupFile.cartridgeCase(forByteSize: size) else {
            print("CartridgeFileMigration: unknown size, leaving invalid.ram in place")
            defaults.set(true, forKey: Self.defaultsKey)
            return .skippedUnknownSize
        }

        let destination = cartDirectory.appendingPathComponent("\(target.fileKey).ram")
        guard !manager.fileExists(atPath: destination.path) else {
            print("CartridgeFileMigration: \(destination.lastPathComponent) exists, leaving invalid.ram in place")
            defaults.set(true, forKey: Self.defaultsKey)
            return .skippedDestinationExists
        }

        do {
            try manager.moveItem(at: source, to: destination)
        } catch {
            print("CartridgeFileMigration: move failed: \(error)")
            return .failed
        }

        defaults.set(true, forKey: Self.defaultsKey)
        return .migrated(to: target)
    }
}
