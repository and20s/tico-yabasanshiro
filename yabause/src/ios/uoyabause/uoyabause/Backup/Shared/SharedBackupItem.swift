import Foundation

/// One publicly shared save, stored as a Firestore document under
/// `shared_backups/{uuid}`.
///
/// Both apps read and write these documents, so the field names below are
/// Android's exactly (`SharedBackupItem.toMap` / `fromDocument`). Getting one
/// wrong does not crash: the record simply stops appearing, or its rating
/// resets, which is how the personal-cloud interop bugs presented.
///
/// Note this is a different record in a different database from
/// `CloudBackupItem`, which is the *personal* backup in the Realtime Database.
/// They share no shape.
struct SharedBackupItem: Identifiable, Equatable {
    let id: String
    let ownerId: String
    let ownerName: String
    let ownerPhotoURL: String?
    let gameTitle: String
    let productNumber: String
    let filename: String
    let comment: String
    let description: String
    let saveDate: Date?
    /// Kept verbatim so a value this app cannot parse is still written back
    /// unchanged rather than blanked.
    let saveDateText: String
    let downloadURL: String
    let sharedAt: Date?
    /// The one field ever changed locally (the optimistic bump on import),
    /// so the one that is not a `let`.
    private(set) var downloadCount: Int
    let isPublic: Bool
    let averageRating: Double
    let ratingCount: Int
    let dataSize: Int
    let blockSize: Int
    let screenshotURL: String?

    // MARK: - Storage layout

    private static let storageRoot = "shared_backups"

    /// `shared_backups/{id}/{filename}` -- the Saturn name goes in verbatim,
    /// as Android writes it, so both apps address the same object.
    static func storagePath(id: String, filename: String) -> String {
        "\(storageRoot)/\(id)/\(filename)"
    }

    static func screenshotStoragePath(id: String) -> String {
        "\(storageRoot)/\(id)/screenshot.png"
    }

    // MARK: - Reading

    /// Builds an item from a Firestore document.
    ///
    /// Tolerant like Android's reader: every field falls back to a default so
    /// a partially written document still lists. The one exception is the
    /// filename, without which the save cannot be restored and the Storage
    /// path cannot be built.
    init?(id: String, data: [String: Any]) {
        guard let filename = Self.string(data["filename"]), !filename.isEmpty
        else { return nil }

        self.id = id
        self.filename = filename
        ownerId = Self.string(data["ownerId"]) ?? ""
        ownerName = Self.string(data["ownerName"]) ?? "Unknown"
        ownerPhotoURL = Self.nonEmpty(data["ownerPhotoUrl"])
        gameTitle = Self.string(data["gameTitle"]) ?? ""
        productNumber = Self.string(data["productNumber"]) ?? ""
        comment = Self.string(data["comment"]) ?? ""
        description = Self.string(data["description"]) ?? ""

        let dateText = Self.string(data["saveDate"]) ?? ""
        saveDateText = dateText
        saveDate = BackupSaveDateFormat.date(from: dateText)

        downloadURL = Self.string(data["downloadUrl"]) ?? ""
        sharedAt = Self.timestamp(data["sharedAt"])
        downloadCount = Self.int(data["downloadCount"]) ?? 0
        isPublic = data["isPublic"] as? Bool ?? true

        // The aggregate is a map *field* named `ratings`, which shares its
        // name with the per-user subcollection. Different namespaces; reading
        // the wrong one silently loses the score.
        let ratings = data["ratings"] as? [String: Any]
        averageRating = Self.double(ratings?["average"]) ?? 0
        ratingCount = Self.int(ratings?["count"]) ?? 0

        dataSize = Self.int(data["dataSize"]) ?? 0
        blockSize = Self.int(data["blockSize"]) ?? 0
        screenshotURL = Self.nonEmpty(data["screenshotUrl"])
    }

    // MARK: - Writing

    /// The document to write on publish, in Android's shape.
    ///
    /// Absent optionals are written as explicit nulls rather than omitted,
    /// which is what Android does and what the security rules may expect.
    func documentData() -> [String: Any] {
        [
            "ownerId": ownerId,
            "ownerName": ownerName,
            "ownerPhotoUrl": ownerPhotoURL as Any? ?? NSNull(),
            "gameTitle": gameTitle,
            "productNumber": productNumber,
            "filename": filename,
            "comment": comment,
            "description": description,
            "saveDate": saveDateText,
            "downloadUrl": downloadURL,
            "sharedAt": sharedAt ?? Date(),
            "downloadCount": downloadCount,
            "isPublic": isPublic,
            "ratings": ["average": averageRating, "count": ratingCount],
            "dataSize": dataSize,
            "blockSize": blockSize,
            "screenshotUrl": screenshotURL as Any? ?? NSNull(),
        ]
    }

    /// A copy with one more download, for showing the new figure without
    /// waiting on a refetch that may never come.
    func bumpingDownloadCount() -> SharedBackupItem {
        // Copied rather than round-tripped through documentData(): that
        // substitutes `sharedAt ?? Date()`, so an item whose date failed to
        // parse would quietly acquire today's as soon as it was imported.
        var copy = self
        copy.downloadCount += 1
        return copy
    }

    // MARK: - Value helpers

    private static func string(_ value: Any?) -> String? {
        value as? String
    }

    /// An empty or null value counts as absent.
    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    /// Firebase hands numbers back as NSNumber, so a plain Int cast fails.
    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    /// `sharedAt` arrives as a Firestore Timestamp, which the SDK bridges to
    /// Date; a plain Date appears in tests and in locally built items.
    private static func timestamp(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        if let converting = value as? NSObject,
           converting.responds(to: Selector(("dateValue"))) {
            return converting.value(forKey: "dateValue") as? Date
        }
        return nil
    }
}
