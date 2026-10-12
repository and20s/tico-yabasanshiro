import Foundation
import FirebaseDatabase
import FirebaseStorage

enum CloudBackupError: Error {
    case notSignedIn
    case network
    case tooLarge
    case slotsFull
    case corruptPayload
}

struct CloudSlotUsage: Equatable {
    let used: Int
    let total: Int
    var isFull: Bool { used >= total }
}

/// The Realtime Database operations the cloud backup needs.
/// Split out so the repository can be tested without Firebase.
protocol CloudDatabase {
    func loadRecords(userId: String) async throws -> [String: [String: Any]]
    func loadMaxBackupCount(userId: String) async throws -> Int?
    func writeMaxBackupCount(_ count: Int, userId: String) async throws
    func updateRecord(_ values: [String: Any], key: String, userId: String) async throws
    func removeRecord(key: String, userId: String) async throws
}

/// The Cloud Storage operations the cloud backup needs.
protocol CloudStorage {
    func upload(_ data: Data, path: String) async throws -> String
    func download(url: String, maxBytes: Int) async throws -> Data
    func remove(path: String) async throws
}

/// Lists, uploads, downloads and deletes cloud saves.
/// Layout matches Android: Realtime Database user-posts/{uid}/backup/{key},
/// Cloud Storage {uid}/backups/{key} plus {key}_screenshot.png.
final class CloudBackupRepository {
    /// Same cap Android uses. The old iOS code capped at 1 MB, which silently
    /// broke larger saves.
    static let maxDownloadBytes = 10 * 1024 * 1024

    private let database: CloudDatabase
    private let storage: CloudStorage

    init(database: CloudDatabase = FirebaseCloudDatabase(),
         storage: CloudStorage = FirebaseCloudStorage()) {
        self.database = database
        self.storage = storage
    }

    func items(userId: String) async throws -> [CloudBackupItem] {
        let records = try await database.loadRecords(userId: userId)
        return records.compactMap { CloudBackupItem(key: $0.key, dictionary: $0.value) }
    }

    /// Counts only records that parse into an item, so the number matches both
    /// the list on screen and what Android reports. Counting raw children would
    /// include records neither platform can display.
    func slotUsage(userId: String) async throws -> CloudSlotUsage {
        let records = try await database.loadRecords(userId: userId)
        let maximum = try await database.loadMaxBackupCount(userId: userId)
        let usable = records.compactMap { CloudBackupItem(key: $0.key, dictionary: $0.value) }
        return CloudSlotUsage(used: usable.count, total: maximum ?? 0)
    }

    /// Writes the slot allowance. The old iOS build never did this, so an
    /// iOS-only user had no max_backup_count node and every upload aborted.
    func ensureSlotCount(_ count: Int, userId: String) async throws {
        try await database.writeMaxBackupCount(count, userId: userId)
    }

    /// Uploads a local save. The bytes go up raw, at the Android path, so the
    /// Android app can restore them.
    /// Returns the key of the new record.
    @discardableResult
    func upload(save: BackupSave, data: Data, screenshot: Data?,
                userId: String) async throws -> String {
        let key = UUID().uuidString

        let downloadURL = try await storage.upload(
            data, path: Self.storagePath(userId: userId, key: key))

        var screenshotURL: String?
        if let screenshot = screenshot {
            screenshotURL = try? await storage.upload(
                screenshot, path: Self.screenshotPath(userId: userId, key: key))
        }

        let item = CloudBackupItem(key: key, filename: save.filename,
                                   comment: save.comment, language: save.language,
                                   saveDate: save.saveDate, dataSize: save.dataSize,
                                   blockSize: save.blockSize, downloadURL: downloadURL,
                                   screenshotURL: screenshotURL,
                                   gameTitle: save.gameTitle,
                                   productNumber: save.productNumber)

        try await database.updateRecord(item.dictionaryForUpload(),
                                        key: key, userId: userId)
        return key
    }

    /// Fetches a save's bytes, unwrapping the legacy iOS envelope when needed.
    func download(item: CloudBackupItem) async throws -> Data {
        guard !item.downloadURL.isEmpty else { throw CloudBackupError.network }
        let raw = try await storage.download(url: item.downloadURL,
                                             maxBytes: Self.maxDownloadBytes)
        do {
            return try CloudBackupPayload.saveBytes(from: raw)
        } catch {
            throw CloudBackupError.corruptPayload
        }
    }

    /// Fetches a save's screenshot, or nil when it has none or cannot be
    /// reached. Unlike `download` this never throws: the image is decoration,
    /// and losing it must not cost the user the restore it came with.
    func downloadScreenshot(item: CloudBackupItem) async -> Data? {
        guard let url = item.screenshotURL, !url.isEmpty else { return nil }
        let data = try? await storage.download(url: url, maxBytes: Self.maxDownloadBytes)
        return (data?.isEmpty ?? true) ? nil : data
    }

    /// Removes the record and both storage objects.
    /// The old iOS build removed only the record, leaking a blob every time.
    func delete(key: String, userId: String) async throws {
        try await database.removeRecord(key: key, userId: userId)
        try? await storage.remove(path: Self.storagePath(userId: userId, key: key))
        try? await storage.remove(path: Self.screenshotPath(userId: userId, key: key))
    }

    static func storagePath(userId: String, key: String) -> String {
        "\(userId)/backups/\(key)"
    }

    static func screenshotPath(userId: String, key: String) -> String {
        "\(userId)/backups/\(key)_screenshot.png"
    }
}

// MARK: - Firebase implementations

/// Realtime Database backing store. The database URL comes from
/// GoogleService-Info.plist, so it is never hardcoded here.
struct FirebaseCloudDatabase: CloudDatabase {
    private func userRoot(_ userId: String) -> DatabaseReference {
        Database.database().reference().child("user-posts").child(userId)
    }

    func loadRecords(userId: String) async throws -> [String: [String: Any]] {
        let value = try await value(at: userRoot(userId).child("backup"))
        guard let raw = value as? [String: Any] else { return [:] }
        return raw.compactMapValues { $0 as? [String: Any] }
    }

    func loadMaxBackupCount(userId: String) async throws -> Int? {
        let value = try await value(at: userRoot(userId).child("max_backup_count"))
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    func writeMaxBackupCount(_ count: Int, userId: String) async throws {
        try await write(count, to: userRoot(userId).child("max_backup_count"))
    }

    /// Uses updateChildValues so fields written by the Android app
    /// (gameTitle, screenshotUrl and friends) survive an iOS write.
    /// setValue would wipe them.
    func updateRecord(_ values: [String: Any], key: String, userId: String) async throws {
        let reference = userRoot(userId).child("backup").child(key)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            reference.updateChildValues(values) { error, _ in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func removeRecord(key: String, userId: String) async throws {
        let reference = userRoot(userId).child("backup").child(key)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            reference.removeValue { error, _ in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Callback bridges

    private func value(at reference: DatabaseReference) async throws -> Any? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            reference.getData { error, snapshot in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let snapshot = snapshot, snapshot.exists() else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: snapshot.value)
            }
        }
    }

    private func write(_ value: Any, to reference: DatabaseReference) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            reference.setValue(value) { error, _ in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

/// Cloud Storage backing store.
struct FirebaseCloudStorage: CloudStorage {
    /// No content type is set, matching what the Android app uploads.
    func upload(_ data: Data, path: String) async throws -> String {
        let reference = Storage.storage().reference(withPath: path)
        _ = try await reference.putDataAsync(data)
        let url = try await reference.downloadURL()
        return url.absoluteString
    }

    func download(url: String, maxBytes: Int) async throws -> Data {
        let reference = Storage.storage().reference(forURL: url)
        return try await reference.data(maxSize: Int64(maxBytes))
    }

    func remove(path: String) async throws {
        try await Storage.storage().reference(withPath: path).delete()
    }
}
