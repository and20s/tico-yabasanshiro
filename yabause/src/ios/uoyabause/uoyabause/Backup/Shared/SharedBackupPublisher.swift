import Foundation
import FirebaseAuth

/// What the publisher types about the save they are sharing.
struct SharedBackupDetails: Equatable {
    /// Required: the community list is browsed by game, so an untitled record
    /// is one nobody finds.
    var gameTitle: String
    var productNumber: String
    var description: String

    init(gameTitle: String = "", productNumber: String = "",
         description: String = "") {
        self.gameTitle = gameTitle
        self.productNumber = productNumber
        self.description = description
    }

    var isValid: Bool {
        !gameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum SharedBackupPublishError: Error {
    case signInRequired
    case titleRequired
    /// The Saturn name is the only field a shared record cannot do without:
    /// it is both the Storage path and the name the save is restored under.
    case unnamedSave
}

/// Publishes one of the user's saves to the community list.
///
/// Uploads the bytes, then writes the Firestore document Android reads. One
/// deliberate difference: when the document write fails, the uploaded objects
/// are removed. Android leaves them, so every failed share there bills for a
/// blob nobody can reach.
@MainActor
final class SharedBackupPublisher {
    struct Publisher {
        let userId: String
        let name: String
        let photoURL: String?
    }

    private let repository: SharedBackupRepository
    private let identity: () -> Publisher?

    /// Storage comes through the repository, which already owns one. Holding
    /// a second reference here let the two disagree -- and a test that
    /// replaced only the repository's uploaded to the real bucket.
    init(repository: SharedBackupRepository = SharedBackupRepository(),
         identity: @escaping () -> Publisher? = { SharedBackupPublisher.currentUser() }) {
        self.repository = repository
        self.identity = identity
    }

    /// The link both apps build for a shared save.
    ///
    /// Kept as a forwarder so publishing has one obvious entry point, but the
    /// format lives in BackupShareLink, which also has to parse it back.
    nonisolated static func shareURL(id: String) -> URL {
        BackupShareLink.buildURL(id: id)
    }

    /// Uploads and publishes. Returns the new document's id.
    @discardableResult
    func publish(save: BackupSave, data: Data, screenshot: Data?,
                 details: SharedBackupDetails) async throws -> String {
        guard details.isValid else { throw SharedBackupPublishError.titleRequired }
        // Checked before anything is uploaded: a nameless save cannot be
        // turned into a record, and finding that out afterwards would leave
        // objects in Storage that no document points at.
        guard !save.filename.isEmpty else {
            throw SharedBackupPublishError.unnamedSave
        }
        guard let publisher = identity() else {
            throw SharedBackupPublishError.signInRequired
        }

        let id = UUID().uuidString.lowercased()
        let savePath = SharedBackupItem.storagePath(id: id, filename: save.filename)
        let screenshotPath = SharedBackupItem.screenshotStoragePath(id: id)

        let downloadURL = try await repository.upload(data, path: savePath)
        var screenshotURL: String?
        if let screenshot {
            // A missing screenshot must not stop the share: it is decoration.
            screenshotURL = try? await repository.upload(screenshot, path: screenshotPath)
        }

        let item = SharedBackupItem(id: id, data: [
            "ownerId": publisher.userId,
            "ownerName": publisher.name,
            "ownerPhotoUrl": publisher.photoURL as Any? ?? NSNull(),
            "gameTitle": details.gameTitle
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "productNumber": details.productNumber,
            "filename": save.filename,
            "comment": save.comment,
            "description": details.description,
            "saveDate": save.saveDate.map(BackupSaveDateFormat.string(from:)) ?? "",
            "downloadUrl": downloadURL,
            "sharedAt": Date(),
            "downloadCount": 0,
            "isPublic": true,
            // Written as zeroes, as Android does; a Cloud Function aggregates
            // the per-user ratings into this map.
            "ratings": ["average": 0.0, "count": 0],
            "dataSize": save.dataSize,
            "blockSize": save.blockSize,
            "screenshotUrl": screenshotURL as Any? ?? NSNull(),
        ])

        // Roll the uploads back rather than leaving objects nobody can reach:
        // without the document there is no id to find them by.
        func rollBack() async {
            try? await repository.remove(path: savePath)
            if screenshotURL != nil {
                try? await repository.remove(path: screenshotPath)
            }
        }

        // Defensive: the filename check above is what makes this unreachable.
        guard let item else {
            await rollBack()
            throw SharedBackupPublishError.unnamedSave
        }

        do {
            try await repository.write(item)
        } catch {
            await rollBack()
            throw error
        }
        return id
    }

    /// Nonisolated because Swift evaluates a default argument outside the
    /// actor. Reading the current user is a plain property access.
    private nonisolated static func currentUser() -> Publisher? {
        guard let user = Auth.auth().currentUser else { return nil }
        return Publisher(userId: user.uid,
                         name: user.displayName ?? "Unknown",
                         photoURL: user.photoURL?.absoluteString)
    }
}
