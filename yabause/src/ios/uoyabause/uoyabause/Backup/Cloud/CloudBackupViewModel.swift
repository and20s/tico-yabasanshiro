import Foundation
import Combine
import FirebaseAuth

/// The signed-in user id, behind a seam so the view model can be tested.
protocol CloudAuth {
    var userId: String? { get }
}

struct FirebaseCloudAuth: CloudAuth {
    var userId: String? { Auth.auth().currentUser?.uid }
}

/// Drives the cloud section of the backup tab.
@MainActor
final class CloudBackupViewModel: ObservableObject {
    enum State: Equatable {
        case loading
        /// StoreKit has not said whether the subscription is active.
        case checkingEntitlement
        case signInRequired
        case upgradeRequired
        case empty
        case loaded
        case failed
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var displayItems: [CloudBackupItem] = []
    @Published private(set) var slotUsage: CloudSlotUsage?
    @Published private(set) var errorMessage: String?
    @Published var searchText: String = "" { didSet { rebuild() } }
    @Published var sortMode: BackupListViewModel.SortMode = .dateDescending {
        didSet { rebuild() }
    }

    /// Exposed so the local detail sheet can hide its upload button.
    ///
    /// Computed, never stored: this object is built at app-root before
    /// StoreKit answers, and the local detail sheet reads this without the
    /// cloud section -- and therefore without any load() -- ever having been
    /// on screen. A stored snapshot would deny a paying subscriber the
    /// upload button for the whole session.
    var isEntitled: Bool { entitlementProvider().isEnabled }

    /// True while the entitlement is still unknown. Showing the upgrade
    /// prompt here would sell cloud backup to someone who already pays.
    var isCheckingEntitlement: Bool { entitlementProvider().isCheckingEntitlement }

    private var allItems: [CloudBackupItem] = []
    private let repository: CloudBackupRepository
    private let auth: CloudAuth
    /// Read again on every access. The entitlement changes mid-session, the
    /// moment a purchase or a restore lands.
    private let entitlementProvider: () -> CloudBackupEntitlement
    /// The two computed properties above cannot be @Published, so the change
    /// they answer differently after has to be announced by hand. Views
    /// reading them re-render when a purchase lands rather than at whatever
    /// later moment some other published property happens to fire.
    private var entitlementCancellable: AnyCancellable?

    init(repository: CloudBackupRepository = CloudBackupRepository(),
         auth: CloudAuth = FirebaseCloudAuth(),
         entitlement: @escaping () -> CloudBackupEntitlement = { CloudBackupEntitlement() }) {
        self.repository = repository
        self.auth = auth
        self.entitlementProvider = entitlement
        entitlementCancellable = ProEntitlementStore.shared.$entitlement
            .dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// Pins the entitlement for tests that need one state to stay put.
    convenience init(repository: CloudBackupRepository,
                     auth: CloudAuth,
                     isEntitled: Bool,
                     isCheckingEntitlement: Bool,
                     entitledSlotCount: Int) {
        self.init(repository: repository, auth: auth,
                  entitlement: {
                      CloudBackupEntitlement(isEnabled: isEntitled,
                                             isCheckingEntitlement: isCheckingEntitlement,
                                             slotCount: entitledSlotCount)
                  })
    }

    /// Loads once per launch. The section's `.task` runs again on every
    /// appearance, and at regular width that is every sidebar switch, so
    /// without this each tab change would hit the network again. Pull to
    /// refresh, retry and sign-in changes still call `load()` directly.
    /// Latched only once the load reached a real answer. A load that bailed
    /// because StoreKit had not decided yet has loaded nothing, and latching
    /// there would leave a legacy paid customer -- who opens this tab in the
    /// seconds before AppTransaction answers -- on a spinner with no retry
    /// until they relaunch the app.
    func loadInitial() async {
        guard !hasLoadedInitial else { return }
        await load()
        hasLoadedInitial = state != .checkingEntitlement
    }

    private var hasLoadedInitial = false

    func load() async {
        // One snapshot for the whole load, so the three questions below
        // cannot be answered from three different moments in time.
        let entitlement = entitlementProvider()
        guard !entitlement.isCheckingEntitlement else {
            state = .checkingEntitlement
            return
        }
        guard entitlement.isEnabled else {
            state = .upgradeRequired
            return
        }
        guard let userId = auth.userId else {
            state = .signInRequired
            return
        }

        state = .loading
        do {
            // The old iOS build never wrote this node, so uploads aborted for
            // anyone who had not also used the Android app.
            try await repository.ensureSlotCount(entitlement.slotCount, userId: userId)

            allItems = try await repository.items(userId: userId)
            slotUsage = try await repository.slotUsage(userId: userId)
            rebuild()
            state = allItems.isEmpty ? .empty : .loaded
        } catch {
            allItems = []
            displayItems = []
            slotUsage = nil
            state = .failed
            print("CloudBackupViewModel: load failed: \(error)")
        }
    }

    /// Uploads a local save to the cloud, refusing when the slots are full.
    func upload(save: BackupSave, using local: LocalBackupRepository,
                screenshots: BackupScreenshotStore = BackupScreenshotStore()) async -> Bool {
        guard isEntitled else { return false }
        guard let userId = auth.userId else {
            state = .signInRequired
            return false
        }

        do {
            let usage = try await repository.slotUsage(userId: userId)
            guard !usage.isFull else {
                errorMessage = String(localized: "All cloud slots are in use. Delete a cloud backup first.",
                                      comment: "Cloud slots full")
                return false
            }

            // Through the queue: exportRaw opens a BackupSession, which must
            // never overlap with a local list reload.
            let bytes = try await BackupWorkQueue.shared.run {
                try local.exportRaw(filename: save.filename, in: save.file)
            }
            var screenshot: Data?
            if let path = screenshots.path(fileKey: save.file.fileKey,
                                           filename: save.filename) {
                screenshot = try? Data(contentsOf: URL(fileURLWithPath: path))
            }

            try await repository.upload(save: save, data: bytes,
                                        screenshot: screenshot, userId: userId)
            await load()
            return true
        } catch {
            errorMessage = String(localized: "Could not upload the backup.",
                                  comment: "Upload error")
            print("CloudBackupViewModel: upload failed: \(error)")
            return false
        }
    }

    /// Downloads a cloud save and writes it into a local backup file.
    /// The bytes are validated before the write, so a corrupt download never
    /// touches the user's local saves.
    func restore(item: CloudBackupItem, into file: BackupFile,
                 using local: BackupImportTarget,
                 screenshots: BackupScreenshotStore = BackupScreenshotStore(),
                 metadata: BackupMetadataStore = BackupMetadataStore()) async -> Bool {
        do {
            let bytes = try await repository.download(item: item)
            guard !bytes.isEmpty else { throw CloudBackupError.corruptPayload }
            // Through the queue: importRaw opens a BackupSession, which must
            // never overlap with a local list reload.
            try await BackupWorkQueue.shared.run {
                try local.importRaw(filename: item.filename, comment: item.comment,
                                    language: item.language, saveDate: item.saveDate,
                                    data: bytes, into: file)
            }
            await carrySideData(of: item, into: file,
                                screenshots: screenshots, metadata: metadata)
            return true
        } catch LocalBackupError.destinationFull {
            errorMessage = String(localized: "Not enough space on the destination.",
                                  comment: "Restore full error")
        } catch CloudBackupError.tooLarge {
            errorMessage = String(localized: "This backup is too large to download.",
                                  comment: "Restore too large error")
        } catch CloudBackupError.corruptPayload {
            errorMessage = String(localized: "The downloaded backup is damaged.",
                                  comment: "Restore corrupt error")
        } catch {
            errorMessage = String(localized: "Could not download the backup.",
                                  comment: "Restore error")
            print("CloudBackupViewModel: restore failed: \(error)")
        }
        return false
    }

    /// The screenshot and the game are held in local stores keyed by backup
    /// file and save name rather than inside the save, so a restore that
    /// wrote only the bytes would land without either. Both are decoration:
    /// neither is allowed to fail the restore that just succeeded.
    private func carrySideData(of item: CloudBackupItem, into file: BackupFile,
                               screenshots: BackupScreenshotStore,
                               metadata: BackupMetadataStore) async {
        if let image = await repository.downloadScreenshot(item: item) {
            screenshots.save(pngData: image, fileKey: file.fileKey,
                             filename: item.filename)
        }
        if let title = item.gameTitle, !title.isEmpty {
            metadata.record(gameTitle: title,
                            productNumber: item.productNumber ?? "",
                            fileKey: file.fileKey, filename: item.filename)
        }
    }

    func delete(key: String) async {
        guard let userId = auth.userId else { return }
        do {
            try await repository.delete(key: key, userId: userId)
        } catch {
            errorMessage = String(localized: "Could not delete the cloud backup.",
                                  comment: "Cloud delete error")
            print("CloudBackupViewModel: delete failed: \(error)")
        }
        await load()
    }

    func clearError() {
        errorMessage = nil
    }

    private func rebuild() {
        var items = allItems
        if !searchText.isEmpty {
            items = items.filter {
                $0.filename.localizedCaseInsensitiveContains(searchText)
                    || $0.comment.localizedCaseInsensitiveContains(searchText)
                    || ($0.gameTitle ?? "").localizedCaseInsensitiveContains(searchText)
            }
        }
        switch sortMode {
        case .nameAscending:
            items.sort { $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedAscending }
        case .nameDescending:
            items.sort { $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedDescending }
        case .dateDescending:
            items.sort { ($0.saveDate ?? .distantPast) > ($1.saveDate ?? .distantPast) }
        case .dateAscending:
            items.sort { ($0.saveDate ?? .distantFuture) < ($1.saveDate ?? .distantFuture) }
        }
        displayItems = items
    }
}
