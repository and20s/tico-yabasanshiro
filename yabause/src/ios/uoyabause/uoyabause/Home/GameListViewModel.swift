import Foundation
import Combine

/// View model of the games tab: owns the item list, search filter,
/// sort mode, scan state, and gamepad focus index.
/// Mirrors the Android GameSelectViewModel + GameSortMode.
@MainActor
final class GameListViewModel: ObservableObject {
    enum SortMode: String, CaseIterable {
        case name
        case releaseDate
        case recentlyPlayed
    }

    @Published private(set) var displayItems: [GameItem] = []
    /// Unfiltered library size (for the Lite version game-count limit).
    var totalCount: Int { allItems.count }
    @Published private(set) var isScanning = false
    @Published var searchText: String = "" { didSet { rebuildDisplayItems() } }
    @Published var sortMode: SortMode {
        didSet {
            defaults.set(sortMode.rawValue, forKey: Self.sortModeKey)
            rebuildDisplayItems()
        }
    }
    /// Index into displayItems focused by gamepad navigation (nil = none).
    @Published var focusedIndex: Int?
    /// Set by gamepad selection; GamesTabView observes this to open the sheet.
    @Published var pendingDetailItem: GameItem?
    /// Set when a locked game was chosen, carrying what to tell the user.
    /// nil means no gate is open.
    @Published var gateReason: ProGateReason?
    /// Paths the current user may play, or nil when there is no limit.
    /// Published so the cards redraw the moment a purchase lands.
    @Published private(set) var unlockedPaths: Set<String>?

    private static let sortModeKey = "homeGameSortMode"

    private var allItems: [GameItem] = []
    private var hasLoadedInitial = false
    private var hasRefreshedOnlineMetadata = false
    private let repository: GameRepository
    private let defaults: UserDefaults
    private var entitlement: ProEntitlement

    init(repository: GameRepository = GameRepository(),
         defaults: UserDefaults = .standard,
         entitlement: ProEntitlement = ProEntitlement()) {
        self.repository = repository
        self.defaults = defaults
        self.entitlement = entitlement
        self.sortMode = defaults.string(forKey: Self.sortModeKey)
            .flatMap(SortMode.init(rawValue:)) ?? .name
    }

    // MARK: - Loading

    /// Publish the cached list immediately (stale-while-revalidate step 1).
    func loadCached() {
        allItems = repository.cachedItems()
        rebuildDisplayItems()
    }

    /// Full startup sequence: cached list first, then background rescan.
    ///
    /// Runs once for the lifetime of this view model, which outlives the
    /// games view: on regular width the tab is rebuilt every time the user
    /// comes back to it from the sidebar, and rescanning the library from
    /// disk on each visit would be both slow and pointless. Pull to refresh
    /// still calls `refresh()` directly.
    func loadInitial() async {
        guard !hasLoadedInitial else { return }
        hasLoadedInitial = true
        loadCached()
        await refresh()
    }

    /// Whether the whole-library RetroAchievements fetch has already run, so
    /// it too happens once per launch rather than once per tab visit.
    func claimOnlineMetadataRefresh() -> Bool {
        guard !hasRefreshedOnlineMetadata else { return false }
        hasRefreshedOnlineMetadata = true
        return true
    }

    /// Rescan on a background thread and republish.
    func refresh() async {
        isScanning = true
        let repo = repository
        let items = await Task.detached(priority: .userInitiated) {
            repo.rescan()
        }.value
        allItems = items
        isScanning = false
        rebuildDisplayItems()
    }

    // MARK: - Mutations

    func recordLastPlayed(filePath: String) {
        guard let index = allItems.firstIndex(where: { $0.filePath == filePath }) else { return }
        allItems[index].lastPlayed = Date()
        repository.persist(allItems)
        rebuildDisplayItems()
    }

    /// Replace items whose online metadata was refreshed (rating / RA).
    func applyUpdatedItems(_ updated: [GameItem]) {
        let byPath = Dictionary(updated.map { ($0.filePath, $0) },
                                uniquingKeysWith: { first, _ in first })
        allItems = allItems.map { byPath[$0.filePath] ?? $0 }
        repository.persist(allItems)
        rebuildDisplayItems()
    }

    func delete(item: GameItem) async {
        let repo = repository
        let items = await Task.detached(priority: .userInitiated) { () -> [GameItem] in
            repo.delete(item: item)
            return repo.cachedItems()
        }.value
        allItems = items
        rebuildDisplayItems()
    }

    // MARK: - Free version slots

    /// Re-reads the limit after the entitlement changed (a purchase landed, or
    /// StoreKit finally answered). The view feeds this from the store rather
    /// than the view model observing it, so a test can hand over any user.
    func apply(entitlement: ProEntitlement) {
        guard entitlement != self.entitlement else { return }
        self.entitlement = entitlement
        recomputeUnlockedPaths()
    }

    private func recomputeUnlockedPaths() {
        unlockedPaths = FreeGameSlots.unlockedPaths(items: allItems,
                                                    entitlement: entitlement)
    }

    /// Whether this game is outside the free allowance. Asked per item rather
    /// than per row, so filtering and sorting the list cannot change the
    /// answer for any game.
    func isLocked(_ item: GameItem) -> Bool {
        FreeGameSlots.isLocked(filePath: item.filePath, unlocked: unlockedPaths)
    }

    /// How many games the limit is keeping out of reach.
    var lockedCount: Int {
        guard let unlockedPaths = unlockedPaths else { return 0 }
        return allItems.filter { !unlockedPaths.contains($0.filePath) }.count
    }

    /// The banner offering a subscription shows only once the limit is
    /// actually costing the user something.
    var showsSubscribeOffer: Bool { lockedCount > 0 }

    /// Opens the pro gate, from the banner or from a locked card.
    func presentGate() {
        gateReason = ProGateReason(
            String(localized: "The free version holds three games. A subscription removes the limit.",
                   comment: "Reason the pro gate opened from the game limit"))
    }

    /// Whether choosing this game may open its detail. A locked game opens the
    /// gate instead. Every route into the detail - tap, controller A, and
    /// D-pad Right into the iPad pane - goes through here.
    func select(_ item: GameItem) -> Bool {
        guard isLocked(item) else { return true }
        presentGate()
        return false
    }

    // MARK: - Display list

    private func rebuildDisplayItems() {
        recomputeUnlockedPaths()
        var items = allItems
        if !searchText.isEmpty {
            items = items.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchText)
            }
        }
        switch sortMode {
        case .name:
            items.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .releaseDate:
            items.sort { $0.releaseDate > $1.releaseDate }
        case .recentlyPlayed:
            items.sort {
                let l = $0.lastPlayed ?? .distantPast
                let r = $1.lastPlayed ?? .distantPast
                if l != r { return l > r }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        }
        displayItems = items
        if let focused = focusedIndex, focused >= displayItems.count {
            focusedIndex = displayItems.isEmpty ? nil : displayItems.count - 1
        }
    }
}
