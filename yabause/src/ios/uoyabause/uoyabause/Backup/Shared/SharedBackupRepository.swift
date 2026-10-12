import Foundation
import FirebaseFirestore
import FirebaseStorage

/// How the shared list is ordered. Android offers the same three.
enum SharedBackupSort: String, CaseIterable, Identifiable {
    case newest
    case oldest
    case mostDownloaded

    var id: String { rawValue }
}

/// One page of results plus the cursor needed to ask for the next.
struct SharedBackupPage {
    let items: [SharedBackupItem]
    /// Opaque cursor for the next call; nil when the end has been reached.
    let cursor: Any?

    static let empty = SharedBackupPage(items: [], cursor: nil)
}

/// The Firestore side of shared backups, behind a protocol so the view model
/// can be tested without a network.
protocol SharedBackupDatabase {
    func page(matching productNumber: String?,
              sort: SharedBackupSort,
              limit: Int,
              after cursor: Any?) async throws -> SharedBackupPage
    func item(id: String) async throws -> SharedBackupItem?
    func write(_ item: SharedBackupItem) async throws
    func delete(id: String) async throws
    func incrementDownloadCount(id: String) async
    func rating(id: String, userId: String) async throws -> Int?
    func setRating(id: String, userId: String, rating: Int) async throws
    func addReport(_ report: SharedBackupReport) async throws
}

enum SharedBackupRatingError: Error {
    case outOfRange
}

/// Browsing, publishing and importing community saves.
///
/// Deliberately different from Android in one respect: Android fetches a fixed
/// 20 documents and filters the text client-side, so anything older than the
/// newest 20 cannot be found and there is no paging at all. This pages
/// properly and filters what it has fetched, so the list can be walked.
final class SharedBackupRepository {
    private let database: SharedBackupDatabase
    private let storage: CloudStorage

    /// Matches the page size Android's single fetch uses, so the first screen
    /// costs the same.
    static let pageSize = 20

    init(database: SharedBackupDatabase = FirestoreSharedBackupDatabase(),
         storage: CloudStorage = FirebaseCloudStorage()) {
        self.database = database
        self.storage = storage
    }

    func page(matching productNumber: String? = nil,
              sort: SharedBackupSort = .newest,
              after cursor: Any? = nil) async throws -> SharedBackupPage {
        try await database.page(matching: productNumber, sort: sort,
                                limit: Self.pageSize, after: cursor)
    }

    func item(id: String) async throws -> SharedBackupItem? {
        try await database.item(id: id)
    }

    /// Writes the document for a newly published save.
    func write(_ item: SharedBackupItem) async throws {
        try await database.write(item)
    }

    /// Uploads one object for a publish. Routed through here rather than the
    /// caller holding its own CloudStorage: two references could disagree,
    /// and a test that replaced only one would silently hit the network.
    func upload(_ data: Data, path: String) async throws -> String {
        try await storage.upload(data, path: path)
    }

    /// Removes one object, for rolling a failed publish back.
    func remove(path: String) async throws {
        try await storage.remove(path: path)
    }

    /// Downloads the shared save's bytes and counts the download.
    ///
    /// The count is a courtesy: a failure there must not stop the user
    /// getting the save they asked for.
    func download(item: SharedBackupItem) async throws -> Data {
        // Same ceiling as the personal cloud path: a shared save is the same
        // kind of object and there is no reason for two limits.
        let data = try await storage.download(
            url: item.downloadURL,
            maxBytes: CloudBackupRepository.maxDownloadBytes)
        await database.incrementDownloadCount(id: item.id)
        return data
    }

    /// Fetches a shared save's screenshot, or nil when it has none or cannot
    /// be reached. Never throws, for the same reason as the personal cloud
    /// path: the image is decoration, the save is not.
    func downloadScreenshot(item: SharedBackupItem) async -> Data? {
        guard let url = item.screenshotURL, !url.isEmpty else { return nil }
        let data = try? await storage.download(
            url: url, maxBytes: CloudBackupRepository.maxDownloadBytes)
        return (data?.isEmpty ?? true) ? nil : data
    }

    /// The rating this user gave, or nil if they have not rated it.
    func rating(item: SharedBackupItem, userId: String) async throws -> Int? {
        try await database.rating(id: item.id, userId: userId)
    }

    /// Records one user's rating.
    ///
    /// The document is keyed by uid, so rating again replaces the old score.
    /// The `ratings` aggregate on the parent is written by a Cloud Function
    /// (`calculateSharedBackupRatings`), not from here: a client that could
    /// write the average could also forge it.
    func rate(item: SharedBackupItem, rating: Int, userId: String) async throws {
        guard (1...5).contains(rating) else {
            throw SharedBackupRatingError.outOfRange
        }
        try await database.setRating(id: item.id, userId: userId, rating: rating)
    }

    /// Files a report against one save.
    func report(item: SharedBackupItem, reason: SharedBackupReportReason,
                reporterId: String) async throws {
        try await database.addReport(SharedBackupReport(
            backupId: item.id, ownerId: item.ownerId,
            reporterId: reporterId, reason: reason))
    }

    func delete(item: SharedBackupItem) async throws {
        // Storage first: a failed document delete leaves an unreachable
        // record, but a failed object delete after the document is gone
        // leaves an orphan nobody can find. Android leaks the screenshot
        // here; this removes both.
        try? await storage.remove(path: SharedBackupItem.storagePath(
            id: item.id, filename: item.filename))
        try? await storage.remove(path: SharedBackupItem.screenshotStoragePath(
            id: item.id))
        try await database.delete(id: item.id)
    }
}

/// Live Firestore implementation.
struct FirestoreSharedBackupDatabase: SharedBackupDatabase {
    private static let collection = "shared_backups"

    private var backups: CollectionReference {
        Firestore.firestore().collection(Self.collection)
    }

    func page(matching productNumber: String?,
              sort: SharedBackupSort,
              limit: Int,
              after cursor: Any?) async throws -> SharedBackupPage {
        var query: Query = backups.whereField("isPublic", isEqualTo: true)

        // Narrowing by game is a server-side equality so the page is full of
        // usable rows, rather than 20 arbitrary rows that mostly get filtered
        // away on the client.
        if let productNumber, !productNumber.isEmpty {
            query = query.whereField("productNumber", isEqualTo: productNumber)
        }

        switch sort {
        case .newest:
            query = query.order(by: "sharedAt", descending: true)
        case .oldest:
            query = query.order(by: "sharedAt", descending: false)
        case .mostDownloaded:
            query = query.order(by: "downloadCount", descending: true)
        }

        if let cursor = cursor as? DocumentSnapshot {
            query = query.start(afterDocument: cursor)
        }

        let snapshot = try await query.limit(to: limit).getDocuments()
        let items = snapshot.documents.compactMap {
            SharedBackupItem(id: $0.documentID, data: $0.data())
        }
        // A short page means the end; a full one may or may not, so the
        // cursor is offered and the next call decides.
        let cursor = snapshot.documents.count < limit ? nil : snapshot.documents.last
        return SharedBackupPage(items: items, cursor: cursor)
    }

    func item(id: String) async throws -> SharedBackupItem? {
        let document = try await backups.document(id).getDocument()
        guard let data = document.data() else { return nil }
        return SharedBackupItem(id: document.documentID, data: data)
    }

    func write(_ item: SharedBackupItem) async throws {
        try await backups.document(item.id).setData(item.documentData())
    }

    func delete(id: String) async throws {
        try await backups.document(id).delete()
    }

    func incrementDownloadCount(id: String) async {
        // Best effort, and an atomic increment so two readers at once do not
        // lose a count. Whether a non-owner may write this depends on the
        // deployed rules; a refusal must not surface as a download failure.
        try? await backups.document(id).updateData([
            "downloadCount": FieldValue.increment(Int64(1)),
        ])
    }

    /// `shared_backups/{id}/ratings/{uid}`. Note the subcollection shares its
    /// name with the aggregate map field on the parent; they are different
    /// namespaces and reading the wrong one silently loses the score.
    private func ratings(of id: String) -> CollectionReference {
        backups.document(id).collection("ratings")
    }

    func rating(id: String, userId: String) async throws -> Int? {
        let document = try await ratings(of: id).document(userId).getDocument()
        guard let value = document.data()?["rating"] as? NSNumber else {
            return nil
        }
        return value.intValue
    }

    /// Write-only from the client: a reporter must not be able to read, edit
    /// or withdraw anyone's reports, including their own.
    func addReport(_ report: SharedBackupReport) async throws {
        try await Firestore.firestore()
            .collection("shared_backup_reports")
            .addDocument(data: report.documentData(createdAt: Date()))
    }

    func setRating(id: String, userId: String, rating: Int) async throws {
        // Android's BackupRating.toMap shape, so a score written by either app
        // reads back in the other and the Cloud Function counts both.
        try await ratings(of: id).document(userId).setData([
            "rating": rating,
            "createdAt": Timestamp(date: Date()),
        ])
    }
}
