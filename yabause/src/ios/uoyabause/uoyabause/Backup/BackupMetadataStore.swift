import Foundation

/// Remembers which game wrote each save, since the Saturn save itself carries
/// no such field. Written when the emulator reports a backup write.
/// Key shape matches the Android SharedPreferences("backup_game_info") store.
final class BackupMetadataStore {
    struct Info: Equatable {
        let gameTitle: String
        let productNumber: String
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func record(gameTitle: String, productNumber: String,
                fileKey: String, filename: String) {
        defaults.set(gameTitle, forKey: Self.titleKey(fileKey, filename))
        defaults.set(productNumber, forKey: Self.productKey(fileKey, filename))
    }

    func lookup(fileKey: String, filename: String) -> Info? {
        guard let title = defaults.string(forKey: Self.titleKey(fileKey, filename)) else {
            return nil
        }
        let product = defaults.string(forKey: Self.productKey(fileKey, filename)) ?? ""
        return Info(gameTitle: title, productNumber: product)
    }

    /// Carries a save's game over to another backup file, for a copy. The keys
    /// include the file, so the destination would otherwise show no game at
    /// all. A save with no entry copies nothing.
    func copy(fileKey: String, filename: String, toFileKey destination: String) {
        guard let info = lookup(fileKey: fileKey, filename: filename) else { return }
        record(gameTitle: info.gameTitle, productNumber: info.productNumber,
               fileKey: destination, filename: filename)
    }

    private static func titleKey(_ fileKey: String, _ filename: String) -> String {
        "title_\(fileKey)_\(filename)"
    }

    private static func productKey(_ fileKey: String, _ filename: String) -> String {
        "product_\(fileKey)_\(filename)"
    }
}
