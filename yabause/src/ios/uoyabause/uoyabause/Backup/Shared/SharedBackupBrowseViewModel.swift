import Combine
import Foundation
import FirebaseAuth

/// Browsing the community's shared saves.
///
/// Paging is real here, unlike Android, which fetches one page of 20 and
/// filters the text over it -- anything older than the newest 20 is
/// unfindable there. The sort and the game filter are server-side and restart
/// the walk; the text box filters what has been fetched, because Firestore
/// has no substring query, and the UI says so rather than implying otherwise.
@MainActor
final class SharedBackupBrowseViewModel: ObservableObject {
    enum State: Equatable {
        case loading
        case signInRequired
        case empty
        case loaded
        case failed
    }

    @Published private(set) var state: State = .loading
    /// Everything fetched so far, in server order.
    @Published private(set) var items: [SharedBackupItem] = []
    @Published private(set) var isLoadingMore = false
    @Published private(set) var errorMessage: String?

    /// Filters `items`; does not query. See the type comment.
    @Published var searchText: String = "" { didSet { rebuild() } }
    @Published private(set) var sort: SharedBackupSort = .newest
    /// Narrows to one game, server-side. nil browses everything.
    @Published private(set) var productNumber: String?

    /// What the list draws.
    @Published private(set) var displayItems: [SharedBackupItem] = []

    /// A save arrived at by a shared link, for the view to open the detail on.
    @Published private(set) var linkedItem: SharedBackupItem?

    /// Set when a restricted action was refused, carrying what to tell the
    /// user. nil means no gate is open.
    @Published var gateReason: ProGateReason?

    private let repository: SharedBackupRepository
    private let isSignedIn: () -> Bool
    private let currentUserId: () -> String?
    private let blockList: SharedBackupBlockList
    private var cursor: Any?
    private var hasLoadedInitial = false
    /// Bumped whenever the walk restarts, so a page still in flight from the
    /// previous sort or filter can tell that it is no longer wanted.
    private var generation = 0

    /// True while there is another page to ask for.
    var canLoadMore: Bool { cursor != nil }

    /// True when the text box is hiding rows that were fetched. The list uses
    /// it to explain that search only covers what has been loaded.
    /// Counted against what is visible rather than everything fetched, so a
    /// hidden poster does not read as the search having filtered something.
    var isFilteringLocally: Bool {
        !searchText.isEmpty && displayItems.count != visibleItems.count
    }

    private var visibleItems: [SharedBackupItem] {
        blockList.blockedIds.isEmpty
            ? items
            : items.filter { !blockList.isBlocked($0.ownerId) }
    }

    init(repository: SharedBackupRepository = SharedBackupRepository(),
         isSignedIn: @escaping () -> Bool = { Auth.auth().currentUser != nil },
         currentUserId: @escaping () -> String? = { Auth.auth().currentUser?.uid },
         blockList: SharedBackupBlockList = SharedBackupBlockList()) {
        self.repository = repository
        self.isSignedIn = isSignedIn
        self.currentUserId = currentUserId
        self.blockList = blockList
    }

    /// Loads once per screen lifetime; the view's `.task` runs on every
    /// appearance.
    func loadInitial() async {
        guard !hasLoadedInitial else { return }
        hasLoadedInitial = true
        await reload()
    }

    func retry() async {
        await reload()
    }

    func apply(sort: SharedBackupSort) async {
        guard sort != self.sort else { return }
        self.sort = sort
        await reload()
    }

    func apply(productNumber: String?) async {
        guard productNumber != self.productNumber else { return }
        self.productNumber = productNumber
        await reload()
    }

    /// Fetches the next page and appends it.
    func loadMore() async {
        guard let cursor, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        // A new sort or filter starts a different walk. Without this, a page
        // still in flight would append rows from the abandoned query and
        // move the cursor into its ordering, so the list would hold two
        // sorts at once and every later page would follow the wrong one.
        let generation = self.generation
        do {
            let page = try await repository.page(matching: productNumber,
                                                 sort: sort, after: cursor)
            guard generation == self.generation else { return }
            items.append(contentsOf: page.items)
            self.cursor = page.cursor
            rebuild()
        } catch {
            // The rows already on screen stay; only the attempt failed. A
            // page that arrived after the walk restarted is not a failure of
            // the walk the user is now looking at.
            guard generation == self.generation else { return }
            errorMessage = String(localized: "Could not load more shared saves.",
                                  comment: "Shared paging error")
        }
    }

    func clearError() { errorMessage = nil }

    // MARK: - Import

    /// True when the destination already holds a save of this name, so the
    /// caller can confirm before overwriting.
    func wouldOverwrite(item: SharedBackupItem, in file: BackupFile,
                        using local: BackupImportTarget) -> Bool {
        (try? local.saveExists(filename: item.filename, in: file)) ?? false
    }

    /// Downloads a community save and writes it into one of the user's backup
    /// files. The bytes are checked before the write, so a bad download never
    /// reaches local saves.
    @discardableResult
    func `import`(item: SharedBackupItem, into file: BackupFile,
                  using local: BackupImportTarget,
                  screenshots: BackupScreenshotStore = BackupScreenshotStore(),
                  metadata: BackupMetadataStore = BackupMetadataStore(),
                  entitlement: ProEntitlement = ProEntitlement()) async -> Bool {
        guard entitlement.allowsAction else {
            gateReason = ProGateReason(
                String(localized: "Importing a community save needs a subscription or the full version.",
                       comment: "Reason the pro gate opened from a shared backup import"))
            return false
        }
        do {
            let bytes = try await repository.download(item: item)
            guard !bytes.isEmpty else { throw CloudBackupError.corruptPayload }
            // Through the queue: importRaw opens a BackupSession, which must
            // never overlap with a local list reload.
            try await BackupWorkQueue.shared.run {
                // The shared document carries no language, and Android writes
                // 0 here; matching it keeps both apps' imports identical.
                try local.importRaw(filename: item.filename, comment: item.comment,
                                    language: 0, saveDate: item.saveDate,
                                    data: bytes, into: file)
            }
            await carrySideData(of: item, into: file,
                                screenshots: screenshots, metadata: metadata)
            bumpDownloadCount(of: item.id)
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
            print("SharedBackupBrowseViewModel: import failed: \(error)")
        }
        return false
    }

    /// The screenshot and the game are held in local stores keyed by backup
    /// file and save name rather than inside the save, so an import that wrote
    /// only the bytes would land without either. Both are decoration: neither
    /// is allowed to fail the import that just succeeded.
    private func carrySideData(of item: SharedBackupItem, into file: BackupFile,
                               screenshots: BackupScreenshotStore,
                               metadata: BackupMetadataStore) async {
        if let image = await repository.downloadScreenshot(item: item) {
            screenshots.save(pngData: image, fileKey: file.fileKey,
                             filename: item.filename)
        }
        if !item.gameTitle.isEmpty {
            metadata.record(gameTitle: item.gameTitle,
                            productNumber: item.productNumber,
                            fileKey: file.fileKey, filename: item.filename)
        }
    }

    // MARK: - Reporting and blocking

    /// Reporting and hiding only make sense for someone else's save.
    func canReport(_ item: SharedBackupItem) -> Bool {
        guard let uid = currentUserId(), !uid.isEmpty else { return false }
        return uid != item.ownerId
    }

    var blockedCount: Int { blockList.count }

    /// Files a report. The save stays listed: taking it down is a decision
    /// for whoever reads the reports, not for the person who filed one.
    func report(_ item: SharedBackupItem,
                reason: SharedBackupReportReason) async -> Bool {
        guard let uid = currentUserId() else { return false }
        do {
            try await repository.report(item: item, reason: reason,
                                        reporterId: uid)
            return true
        } catch {
            errorMessage = String(localized: "Could not send the report.",
                                  comment: "Report failed")
            return false
        }
    }

    /// Hides everything by one poster, now and in later pages.
    ///
    /// The state deliberately stays `.loaded` even when nothing is left to
    /// show: the empty state replaces the list, and the unhide row lives in
    /// the list. Going empty here would strand the user with no way back.
    func block(_ item: SharedBackupItem) {
        blockList.block(item.ownerId)
        rebuild()
    }

    func unblockAll() {
        blockList.unblockAll()
        rebuild()
        if state == .empty {
            state = displayItems.isEmpty ? .empty : .loaded
        }
    }

    // MARK: - Rating

    /// Whether this user may rate at all. Rating is per account, so signed
    /// out there is nowhere to record it.
    var canRate: Bool { currentUserId() != nil }

    /// This user's existing score for a save, so the picker opens on it
    /// rather than pretending they have not rated.
    func myRating(of item: SharedBackupItem) async -> Int? {
        guard let uid = currentUserId() else { return nil }
        return try? await repository.rating(item: item, userId: uid)
    }

    /// Records a rating and reports whether it went.
    ///
    /// The displayed average is not adjusted here. It is computed by a Cloud
    /// Function from the whole subcollection, and guessing the new figure
    /// locally would show a number the server never agreed to.
    func rate(_ item: SharedBackupItem, stars: Int,
              entitlement: ProEntitlement = ProEntitlement()) async -> Bool {
        guard entitlement.allowsAction else {
            gateReason = ProGateReason(
                String(localized: "Rating a community save needs a subscription or the full version.",
                       comment: "Reason the pro gate opened from a shared backup rating"))
            return false
        }
        guard let uid = currentUserId() else { return false }
        do {
            try await repository.rate(item: item, rating: stars, userId: uid)
            return true
        } catch {
            errorMessage = String(localized: "Could not submit the rating.",
                                  comment: "Rating failed")
            return false
        }
    }

    // MARK: - Shared links

    /// Fetches the save a shared link points at.
    ///
    /// Fetched by id rather than looked for in `items`: the link may name a
    /// save older than anything paged in, and following a link the user
    /// tapped must not depend on how far they had scrolled.
    func openLink(id: String) async {
        guard isSignedIn() else {
            state = .signInRequired
            return
        }
        do {
            guard let item = try await repository.item(id: id) else {
                errorMessage = String(localized: "That shared save is no longer available.",
                                      comment: "Shared link missing")
                return
            }
            linkedItem = item
        } catch {
            errorMessage = String(localized: "Could not open that shared save.",
                                  comment: "Shared link failed")
        }
    }

    /// Called once the detail has been opened, so the same link can be
    /// followed again later.
    func clearLinkedItem() {
        linkedItem = nil
    }

    // MARK: - Unpublishing

    /// Whether this user posted the save, and so may take it down.
    ///
    /// The security rules decide the real answer; this only decides whether
    /// to offer the action, so that no button is shown that cannot work.
    func canUnpublish(_ item: SharedBackupItem) -> Bool {
        guard let uid = currentUserId(), !uid.isEmpty else { return false }
        return uid == item.ownerId
    }

    /// Takes the user's own save off the community list.
    ///
    /// Returns whether it went; the caller closes its sheet on true. The row
    /// is dropped only after the server agrees, since a local drop on a
    /// refused delete would tell the user it is gone when it is not.
    func unpublish(_ item: SharedBackupItem) async -> Bool {
        guard canUnpublish(item) else { return false }
        do {
            try await repository.delete(item: item)
        } catch {
            errorMessage = String(localized: "Could not remove the shared save.",
                                  comment: "Unpublish failed")
            return false
        }
        items.removeAll { $0.id == item.id }
        rebuild()
        // A list that has emptied must say so rather than draw nothing under
        // a loaded state -- unless someone is hidden, because the unhide row
        // is drawn with the list and the empty state would replace it.
        if items.isEmpty, state == .loaded, blockList.blockedIds.isEmpty {
            state = .empty
        }
        return true
    }

    /// Shows the new count immediately. The server was told separately and
    /// may have refused; this is the optimistic local view, as Android's is.
    private func bumpDownloadCount(of id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index] = items[index].bumpingDownloadCount()
        rebuild()
    }

    // MARK: - Private

    /// Starts the walk over: a new sort or filter invalidates every cursor.
    private func reload() async {
        guard isSignedIn() else {
            state = .signInRequired
            items = []
            rebuild()
            return
        }
        state = .loading
        cursor = nil
        generation += 1
        do {
            let page = try await repository.page(matching: productNumber,
                                                 sort: sort, after: nil)
            items = page.items
            cursor = page.cursor
            rebuild()
            state = page.items.isEmpty ? .empty : .loaded
        } catch {
            items = []
            rebuild()
            state = .failed
        }
    }

    private func rebuild() {
        // Hidden posters drop out before the text filter, so a search can
        // never surface someone the user asked not to see.
        let visible = visibleItems
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            displayItems = visible
            return
        }
        displayItems = visible.filter {
            $0.gameTitle.localizedCaseInsensitiveContains(query)
                || $0.filename.localizedCaseInsensitiveContains(query)
                || $0.comment.localizedCaseInsensitiveContains(query)
                || $0.description.localizedCaseInsensitiveContains(query)
                || $0.ownerName.localizedCaseInsensitiveContains(query)
        }
    }
}
