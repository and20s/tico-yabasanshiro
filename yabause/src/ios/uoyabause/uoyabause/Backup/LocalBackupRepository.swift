import Foundation

/// Free/used space of one backup RAM file.
struct BackupStorageStatus: Equatable {
    let totalSize: Int
    let freeSize: Int
    let totalBlock: Int
    let freeBlock: Int

    var usedBlock: Int { totalBlock - freeBlock }
}

enum LocalBackupError: Error {
    case listFailed
    case statusFailed
    case deleteFailed
    case copyFailed
    case destinationFull
    case saveNotFound
    case importFailed
}

/// The local side of an import, behind a protocol so a view model can be
/// tested without touching a real backup file. Both the personal cloud
/// restore and the community import write through it, and
/// `LocalBackupRepository` satisfies it.
protocol BackupImportTarget {
    func saveExists(filename: String, in file: BackupFile) throws -> Bool
    func importRaw(filename: String, comment: String, language: Int,
                   saveDate: Date?, data: Data, into file: BackupFile) throws
}

extension LocalBackupRepository: BackupImportTarget {}

/// Lists and mutates the saves inside the local backup RAM files.
/// Every operation opens a standalone session for the duration of the call.
final class LocalBackupRepository {
    /// Upper bound on how many saves one device can hold; the largest
    /// cartridge has 0x800000 bytes and the smallest save costs one block.
    private static let maxSaveCount = 4096

    private let cartridgeSetting: BackupCartridgeSetting

    init(cartridgeSetting: BackupCartridgeSetting = BackupCartridgeSetting()) {
        self.cartridgeSetting = cartridgeSetting
    }

    /// The internal memory (always, because opening it creates it) plus the
    /// one cartridge the user configured in Settings. Other cartridge sizes
    /// are never offered: opening one would create a .ram file for a
    /// cartridge that is not inserted.
    func availableFiles() -> [BackupFile] {
        var files: [BackupFile] = [.internalMemory]
        if let cartridge = cartridgeSetting.configuredCartridge() {
            files.append(cartridge)
        }
        return files
    }

    func saves(in file: BackupFile) throws -> [BackupSave] {
        try withSession(for: file) {
            try listSaves(in: file)
        }
    }

    func status(of file: BackupFile) throws -> BackupStorageStatus {
        try withSession(for: file) {
            try readStatus(of: file)
        }
    }

    func saveExists(filename: String, in file: BackupFile) throws -> Bool {
        try saves(in: file).contains { $0.filename == filename }
    }

    func delete(filename: String, in file: BackupFile) throws {
        try withSession(for: file) {
            guard try listSaves(in: file).contains(where: { $0.filename == filename })
            else { throw LocalBackupError.saveNotFound }
            let result = filename.withCString {
                YSBupStandaloneDelete(file.deviceId, $0)
            }
            guard result == 0 else { throw LocalBackupError.deleteFailed }
        }
    }

    /// Copies a save between two backup files.
    /// Internal <-> cartridge happens inside one session; cartridge to
    /// cartridge needs two, so it is not supported here (the UI never offers
    /// it because only one cartridge file is open at a time).
    func copy(filename: String, from source: BackupFile, to destination: BackupFile) throws {
        guard source != destination else { throw LocalBackupError.copyFailed }
        guard source == .internalMemory || destination == .internalMemory else {
            throw LocalBackupError.copyFailed
        }
        let cartridge = source == .internalMemory ? destination : source
        try BackupSession.shared.withSession(cartridge: cartridge) {
            let result = filename.withCString {
                YSBupStandaloneCopy(source.deviceId, destination.deviceId, $0)
            }
            if result == -2 { throw LocalBackupError.destinationFull }
            guard result == 0 else { throw LocalBackupError.copyFailed }
        }
    }

    /// The raw save bytes, as the emulator would write them to a cartridge.
    /// This is the payload format the Android app stores in the cloud.
    func exportRaw(filename: String, in file: BackupFile) throws -> Data {
        try withSession(for: file) {
            guard try listSaves(in: file).contains(where: { $0.filename == filename })
            else { throw LocalBackupError.saveNotFound }

            var buffer: UnsafeMutableRawPointer?
            var size: Int32 = 0
            let result = filename.withCString {
                YSBupStandaloneExport(file.deviceId, $0, &buffer, &size)
            }
            guard result == 0, let buffer = buffer, size > 0 else {
                throw LocalBackupError.listFailed
            }
            defer { free(buffer) }
            return Data(bytes: buffer, count: Int(size))
        }
    }

    /// Writes raw save bytes into a backup file, packing the date the way the
    /// core expects. Used when restoring a save from the cloud.
    func importRaw(filename: String, comment: String, language: Int,
                   saveDate: Date?, data: Data, into file: BackupFile) throws {
        let packed = Self.packedDate(from: saveDate)
        try withSession(for: file) {
            let result = filename.withCString { namePtr in
                comment.withCString { commentPtr in
                    data.withUnsafeBytes { bytes in
                        YSBupStandaloneImport(file.deviceId, namePtr, commentPtr,
                                              UInt8(language), packed,
                                              bytes.baseAddress, Int32(data.count))
                    }
                }
            }
            if result == -2 { throw LocalBackupError.destinationFull }
            guard result == 0 else { throw LocalBackupError.importFailed }
        }
    }

    /// Converts a date to the packed form saveinfo_struct.date uses.
    /// Falls back to the current time when the date is missing or out of range.
    private static func packedDate(from date: Date?) -> UInt32 {
        let source = date ?? Date()
        let parts = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: source)
        return YSBupEncodeDate(Int32(parts.year ?? 1998), Int32(parts.month ?? 1),
                               Int32(parts.day ?? 1), Int32(parts.hour ?? 0),
                               Int32(parts.minute ?? 0))
    }

    // MARK: - Session helpers

    /// Opens a session appropriate for the file: internal memory alone needs
    /// no cartridge, a cartridge file is opened alongside it.
    private func withSession<T>(for file: BackupFile, _ body: () throws -> T) throws -> T {
        try BackupSession.shared.withSession(
            cartridge: file == .internalMemory ? nil : file, body)
    }

    private func listSaves(in file: BackupFile) throws -> [BackupSave] {
        var buffer = [YSBupSave](repeating: YSBupSave(), count: Self.maxSaveCount)
        let count = buffer.withUnsafeMutableBufferPointer { pointer in
            YSBupStandaloneList(file.deviceId, pointer.baseAddress,
                                Int32(Self.maxSaveCount))
        }
        guard count >= 0 else { throw LocalBackupError.listFailed }
        return buffer.prefix(Int(count)).map { BackupSave(raw: $0, file: file) }
    }

    private func readStatus(of file: BackupFile) throws -> BackupStorageStatus {
        var totalSize: UInt32 = 0
        var freeSize: UInt32 = 0
        var totalBlock: UInt32 = 0
        var freeBlock: UInt32 = 0
        let result = YSBupStandaloneStatus(file.deviceId, &totalSize, &freeSize,
                                           &totalBlock, &freeBlock)
        guard result == 0 else { throw LocalBackupError.statusFailed }
        return BackupStorageStatus(totalSize: Int(totalSize),
                                   freeSize: Int(freeSize),
                                   totalBlock: Int(totalBlock),
                                   freeBlock: Int(freeBlock))
    }
}

#if DEBUG
extension LocalBackupRepository {
    /// Writes a synthetic save. Test-only: it exists so the unit tests can
    /// build fixtures through the same C path the app uses.
    func debugCreateSave(named name: String, comment: String,
                         in file: BackupFile, byteCount: Int) throws {
        try withSession(for: file) {
            let payload = [UInt8](repeating: 0xA5, count: byteCount)
            let result = name.withCString { namePtr in
                comment.withCString { commentPtr in
                    payload.withUnsafeBufferPointer { bytes in
                        YSBupStandaloneCreateForTest(file.deviceId, namePtr, commentPtr,
                                                     bytes.baseAddress, Int32(byteCount))
                    }
                }
            }
            guard result == 0 else { throw LocalBackupError.copyFailed }
        }
    }
}
#endif
