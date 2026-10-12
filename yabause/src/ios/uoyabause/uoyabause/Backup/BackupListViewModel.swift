import Foundation
import Combine

/// Drives the backup tab: which file is selected, its saves, the search
/// filter, the sort order and the storage bar.
@MainActor
final class BackupListViewModel: ObservableObject {
    /// Same four orders as the Android backup_sort_menu.
    enum SortMode: String, CaseIterable {
        case nameAscending
        case nameDescending
        case dateDescending
        case dateAscending
    }

    @Published private(set) var displaySaves: [BackupSave] = []
    @Published private(set) var availableFiles: [BackupFile] = []
    @Published private(set) var status: BackupStorageStatus?
    @Published private(set) var isLoading = false
    /// Transient message shown as an alert (delete/copy failures).
    @Published private(set) var errorMessage: String?
    /// The list itself could not be read, so the view shows a retry state.
    @Published private(set) var loadFailed = false
    @Published var selectedFile: BackupFile = .internalMemory {
        didSet {
            guard oldValue != selectedFile else { return }
            Task { await load() }
        }
    }
    @Published var searchText: String = "" { didSet { rebuild() } }
    @Published var sortMode: SortMode = .dateDescending { didSet { rebuild() } }

    private var allSaves: [BackupSave] = []
    /// Bumped by every load; a finished load only publishes when it is still
    /// the newest one, so a slow load for a file the user already left cannot
    /// overwrite the newer result.
    private var loadGeneration = 0

    /// Counts how many loads have been started, so a test can tell a second
    /// `loadInitial()` did nothing.
    var loadGenerationForTesting: Int { loadGeneration }
    private let repository: LocalBackupRepository
    private let metadata: BackupMetadataStore
    private let screenshots: BackupScreenshotStore

    init(repository: LocalBackupRepository = LocalBackupRepository(),
         metadata: BackupMetadataStore = BackupMetadataStore(),
         screenshots: BackupScreenshotStore = BackupScreenshotStore()) {
        self.repository = repository
        self.metadata = metadata
        self.screenshots = screenshots
    }

    /// Loads once per launch. The view's `.task` runs again every time the
    /// tab is shown, and at regular width that is every sidebar switch, so
    /// re-reading the backup memory each time would be pure waste. Pull to
    /// refresh and a file change still go through `load()` directly.
    func loadInitial() async {
        guard !hasLoadedInitial else { return }
        hasLoadedInitial = true
        await load()
    }

    private var hasLoadedInitial = false

    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        let file = selectedFile
        let repository = self.repository
        let metadata = self.metadata
        let screenshots = self.screenshots

        let result = await BackupWorkQueue.shared.run {
            () -> Result<([BackupFile], [BackupSave], BackupStorageStatus), Error> in
            do {
                let files = repository.availableFiles()
                var saves = try repository.saves(in: file)
                for index in saves.indices {
                    let info = metadata.lookup(fileKey: file.fileKey,
                                               filename: saves[index].filename)
                    saves[index].gameTitle = info?.gameTitle
                    saves[index].productNumber = info?.productNumber
                    saves[index].screenshotPath = screenshots.path(
                        fileKey: file.fileKey, filename: saves[index].filename)
                }
                let status = try repository.status(of: file)
                return .success((files, saves, status))
            } catch {
                return .failure(error)
            }
        }

        // A newer load started while this one was running: let it publish.
        guard generation == loadGeneration else { return }
        isLoading = false
        switch result {
        case .success(let (files, saves, status)):
            loadFailed = false
            availableFiles = files
            allSaves = saves
            self.status = status
            rebuild()
        case .failure(let error):
            loadFailed = true
            allSaves = []
            self.status = nil
            displaySaves = []
            print("BackupListViewModel: load failed: \(error)")
        }
    }

    func delete(filename: String) async {
        let file = selectedFile
        let repository = self.repository
        let screenshots = self.screenshots
        do {
            try await BackupWorkQueue.shared.run {
                try repository.delete(filename: filename, in: file)
                screenshots.delete(fileKey: file.fileKey, filename: filename)
            }
        } catch {
            errorMessage = String(localized: "Could not delete the save.",
                                  comment: "Backup delete error")
            print("BackupListViewModel: delete failed: \(error)")
        }
        await load()
    }

    /// Copy targets: between the internal memory and the configured
    /// cartridge only. Cartridge to cartridge is impossible anyway, since
    /// the Saturn has a single slot.
    func copyDestinations() -> [BackupFile] {
        availableFiles.filter { $0 != selectedFile }
    }

    /// Async because it opens a session of its own; it has to take its turn
    /// in the queue like every other repository call.
    func saveExists(filename: String, in destination: BackupFile) async -> Bool {
        let repository = self.repository
        return await BackupWorkQueue.shared.run {
            (try? repository.saveExists(filename: filename, in: destination)) ?? false
        }
    }

    func copy(filename: String, to destination: BackupFile) async {
        let source = selectedFile
        let repository = self.repository
        let screenshots = self.screenshots
        let metadata = self.metadata
        do {
            try await BackupWorkQueue.shared.run {
                try repository.copy(filename: filename, from: source, to: destination)
                // Both side stores are keyed by backup file, so the copy would
                // show up on the destination with no image and no game unless
                // their entries are carried over with it.
                screenshots.copy(fileKey: source.fileKey, filename: filename,
                                 toFileKey: destination.fileKey)
                metadata.copy(fileKey: source.fileKey, filename: filename,
                              toFileKey: destination.fileKey)
            }
        } catch LocalBackupError.destinationFull {
            errorMessage = String(localized: "Not enough space on the destination.",
                                  comment: "Backup copy full error")
        } catch {
            errorMessage = String(localized: "Could not copy the save.",
                                  comment: "Backup copy error")
            print("BackupListViewModel: copy failed: \(error)")
        }
        await load()
    }

    func clearError() {
        errorMessage = nil
    }

    private func rebuild() {
        var saves = allSaves
        if !searchText.isEmpty {
            saves = saves.filter {
                $0.filename.localizedCaseInsensitiveContains(searchText)
                    || $0.comment.localizedCaseInsensitiveContains(searchText)
                    || ($0.gameTitle ?? "").localizedCaseInsensitiveContains(searchText)
            }
        }
        switch sortMode {
        case .nameAscending:
            saves.sort { $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedAscending }
        case .nameDescending:
            saves.sort { $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedDescending }
        case .dateDescending:
            saves.sort { ($0.saveDate ?? .distantPast) > ($1.saveDate ?? .distantPast) }
        case .dateAscending:
            saves.sort { ($0.saveDate ?? .distantFuture) < ($1.saveDate ?? .distantFuture) }
        }
        displaySaves = saves
    }
}
