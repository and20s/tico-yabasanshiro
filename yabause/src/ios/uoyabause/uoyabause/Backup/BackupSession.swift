import Foundation

enum BackupSessionError: Error {
    case alreadyOpen
    case openFailed
}

/// Owns the standalone backup RAM session. The underlying C API uses process
/// globals shared with the emulator, so only one session may exist at a time
/// and it must be closed before a game launches.
final class BackupSession {
    static let shared = BackupSession()

    private let lock = NSLock()
    private var open = false

    private init() {}

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return open
    }

    /// Runs body with the internal memory and (optionally) one cartridge file
    /// open, closing the session afterwards even if body throws.
    func withSession<T>(cartridge: BackupFile?, _ body: () throws -> T) throws -> T {
        try openSession(cartridge: cartridge)
        defer { closeIfOpen() }
        return try body()
    }

    /// Closes an open session. Safe to call when nothing is open.
    /// Called before launching a game so the emulator gets the globals back.
    func closeIfOpen() {
        lock.lock()
        defer { lock.unlock() }
        guard open else { return }
        YSBupStandaloneClose()
        open = false
    }

    private func openSession(cartridge: BackupFile?) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !open else { throw BackupSessionError.alreadyOpen }

        createDirectories(for: cartridge)

        let result = BackupFile.internalMemory.path.withCString { bupPath -> Int32 in
            guard let cartridge = cartridge else {
                return YSBupStandaloneOpen(bupPath, "", BackupFile.internalMemory.cartType)
            }
            return cartridge.path.withCString { cartPath in
                YSBupStandaloneOpen(bupPath, cartPath, cartridge.cartType)
            }
        }
        guard result == 0 else { throw BackupSessionError.openFailed }
        open = true
    }

    /// The core opens the files with fopen, which does not create directories.
    private func createDirectories(for cartridge: BackupFile?) {
        let manager = FileManager.default
        var directories = [
            URL(fileURLWithPath: BackupFile.internalMemory.path)
                .deletingLastPathComponent()
        ]
        if let cartridge = cartridge {
            directories.append(
                URL(fileURLWithPath: cartridge.path).deletingLastPathComponent())
        }
        for directory in directories {
            try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}
