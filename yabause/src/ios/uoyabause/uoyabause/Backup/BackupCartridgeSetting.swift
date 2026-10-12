import Foundation

/// Reads which cartridge the user selected in Settings.
///
/// The Saturn has one cartridge slot, so the backup tab must only offer that
/// cartridge: opening a session for any other size would create a .ram file
/// that should not exist (CartInit formats a missing file).
struct BackupCartridgeSetting {
    private let settingsPath: String

    init(settingsPath: String? = nil) {
        self.settingsPath = settingsPath ?? Self.defaultSettingsPath()
    }

    /// The configured backup RAM cartridge, or nil when none is selected or
    /// the configured cartridge is a DRAM type (which holds no saves).
    func configuredCartridge() -> BackupFile? {
        guard let dictionary = NSDictionary(contentsOfFile: settingsPath),
              let value = dictionary["cartridge"] as? Int else {
            return nil
        }
        return BackupFile.allCases.first {
            $0 != .internalMemory && $0.cartType == Int32(value)
        }
    }

    private static func defaultSettingsPath() -> String {
        let library = NSSearchPathForDirectoriesInDomains(
            .libraryDirectory, .userDomainMask, true)[0]
        return (library as NSString).appendingPathComponent("settings.plist")
    }
}
