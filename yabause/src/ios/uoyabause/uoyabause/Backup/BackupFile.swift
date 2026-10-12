import Foundation

/// A backup RAM file the app can open: the internal memory plus the four
/// cartridge sizes. Mirrors the Android LocalBackupFile enum, but uses the
/// iOS paths (Documents/backup/memory.bin and Documents/cart/backup*.ram).
enum BackupFile: String, CaseIterable, Identifiable {
    case internalMemory
    case cartridge4Mbit
    case cartridge8Mbit
    case cartridge16Mbit
    case cartridge32Mbit

    var id: String { rawValue }

    /// CART_* constant from cs0.h. Internal memory needs no cartridge.
    var cartType: Int32 {
        switch self {
        case .internalMemory:  return 0 // CART_NONE
        case .cartridge4Mbit:  return 2 // CART_BACKUPRAM4MBIT
        case .cartridge8Mbit:  return 3 // CART_BACKUPRAM8MBIT
        case .cartridge16Mbit: return 4 // CART_BACKUPRAM16MBIT
        case .cartridge32Mbit: return 5 // CART_BACKUPRAM32MBIT
        }
    }

    /// Device id used by the core: 0 = internal, 1 = cartridge.
    var deviceId: Int32 {
        self == .internalMemory ? 0 : 1
    }

    /// Exact on-disc size CartInit allocates, used to identify an unnamed file.
    /// The internal memory file is extended on demand, so it has no fixed size.
    var expectedByteSize: Int? {
        switch self {
        case .internalMemory:  return nil
        case .cartridge4Mbit:  return 0x100000
        case .cartridge8Mbit:  return 0x200000
        case .cartridge16Mbit: return 0x400000
        case .cartridge32Mbit: return 0x800000
        }
    }

    /// Name without extension. Used to key screenshots and game metadata.
    var fileKey: String {
        switch self {
        case .internalMemory:  return "memory"
        case .cartridge4Mbit:  return "backup4"
        case .cartridge8Mbit:  return "backup8"
        case .cartridge16Mbit: return "backup16"
        case .cartridge32Mbit: return "backup32"
        }
    }

    private var relativePath: String {
        self == .internalMemory ? "backup/memory.bin" : "cart/\(fileKey).ram"
    }

    var path: String {
        let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent(relativePath).path
    }

    var exists: Bool {
        FileManager.default.fileExists(atPath: path)
    }

    var displayName: String {
        switch self {
        case .internalMemory:
            return String(localized: "Internal Memory", comment: "Backup file name")
        case .cartridge4Mbit:
            return String(localized: "4Mbit Cartridge", comment: "Backup file name")
        case .cartridge8Mbit:
            return String(localized: "8Mbit Cartridge", comment: "Backup file name")
        case .cartridge16Mbit:
            return String(localized: "16Mbit Cartridge", comment: "Backup file name")
        case .cartridge32Mbit:
            return String(localized: "32Mbit Cartridge", comment: "Backup file name")
        }
    }

    /// The cartridge case whose file is exactly this many bytes, if any.
    static func cartridgeCase(forByteSize size: Int) -> BackupFile? {
        allCases.first { $0 != .internalMemory && $0.expectedByteSize == size }
    }
}
