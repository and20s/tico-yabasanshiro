import XCTest
@testable import YabaSnashiro

@MainActor
final class GameListViewModelTests: XCTestCase {
    private var tempDir: URL!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "GameListViewModelTests")
        defaults.removePersistentDomain(forName: "GameListViewModelTests")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        defaults.removePersistentDomain(forName: "GameListViewModelTests")
    }

    private func makeItem(path: String, name: String, releaseDate: String,
                          lastPlayed: Date? = nil) -> GameItem {
        var gi = GameInfo()
        gi.filePath = path
        gi.displayName = name
        gi.productNumber = "GS-0001"
        gi.releaseDate = releaseDate
        var item = GameItem(gameInfo: gi)
        item.lastPlayed = lastPlayed
        return item
    }

    private func makeViewModel(items: [GameItem],
                               entitlement: ProEntitlement = ProEntitlement(
                                   showsAdvertising: false, legacy: .legacyPaid,
                                   purchase: .none)) -> GameListViewModel {
        let repo = GameRepository(rootDirectory: tempDir,
                                  cache: GameListCache(directory: tempDir))
        repo.persist(items)
        let vm = GameListViewModel(repository: repo, defaults: defaults,
                                   entitlement: entitlement)
        vm.loadCached()
        return vm
    }

    func testSortByNameIsDefault() {
        let vm = makeViewModel(items: [
            makeItem(path: "/b", name: "Burning Rangers", releaseDate: "19980226"),
            makeItem(path: "/a", name: "Azel", releaseDate: "19980129"),
        ])
        XCTAssertEqual(vm.sortMode, .name)
        XCTAssertEqual(vm.displayItems.map(\.displayName), ["Azel", "Burning Rangers"])
    }

    func testSortByReleaseDateNewestFirst() {
        let vm = makeViewModel(items: [
            makeItem(path: "/a", name: "Azel", releaseDate: "19980129"),
            makeItem(path: "/b", name: "Burning Rangers", releaseDate: "19980226"),
        ])
        vm.sortMode = .releaseDate
        XCTAssertEqual(vm.displayItems.map(\.displayName), ["Burning Rangers", "Azel"])
    }

    func testSortByRecentlyPlayed() {
        let old = Date(timeIntervalSince1970: 1_000)
        let recent = Date(timeIntervalSince1970: 2_000)
        let vm = makeViewModel(items: [
            makeItem(path: "/a", name: "Azel", releaseDate: "19980129", lastPlayed: old),
            makeItem(path: "/n", name: "Never Played", releaseDate: "19960101"),
            makeItem(path: "/b", name: "Burning Rangers", releaseDate: "19980226", lastPlayed: recent),
        ])
        vm.sortMode = .recentlyPlayed
        XCTAssertEqual(vm.displayItems.map(\.displayName),
                       ["Burning Rangers", "Azel", "Never Played"])
    }

    func testSortModePersistsToDefaults() {
        let vm = makeViewModel(items: [])
        vm.sortMode = .recentlyPlayed
        let vm2 = makeViewModel(items: [])
        XCTAssertEqual(vm2.sortMode, .recentlyPlayed)
    }

    func testSearchFiltersCaseInsensitive() {
        let vm = makeViewModel(items: [
            makeItem(path: "/a", name: "Azel", releaseDate: "19980129"),
            makeItem(path: "/b", name: "Burning Rangers", releaseDate: "19980226"),
        ])
        vm.searchText = "burn"
        XCTAssertEqual(vm.displayItems.map(\.displayName), ["Burning Rangers"])
        vm.searchText = ""
        XCTAssertEqual(vm.displayItems.count, 2)
    }

    func testRecordLastPlayedUpdatesItemAndPersists() {
        let vm = makeViewModel(items: [
            makeItem(path: "/a", name: "Azel", releaseDate: "19980129"),
        ])
        vm.recordLastPlayed(filePath: "/a")
        XCTAssertNotNil(vm.displayItems[0].lastPlayed)
        // Persisted through the repository cache
        let repo = GameRepository(rootDirectory: tempDir,
                                  cache: GameListCache(directory: tempDir))
        XCTAssertNotNil(repo.cachedItems()[0].lastPlayed)
    }

    // MARK: - Free version limit

    private var freeUser: ProEntitlement {
        ProEntitlement(showsAdvertising: true, legacy: .notLegacy, purchase: .none)
    }

    /// Five games in arrival order A..E, which is what decides the free three.
    private func library() -> [GameItem] {
        ["A", "B", "C", "D", "E"].enumerated().map { index, name in
            var item = makeItem(path: "/\(name)", name: name, releaseDate: "1996010\(index)")
            item.addedAt = Date(timeIntervalSince1970: TimeInterval(index))
            return item
        }
    }

    func testAFreeUserPlaysTheFirstThreeArrivals() {
        let vm = makeViewModel(items: library(), entitlement: freeUser)
        XCTAssertEqual(vm.displayItems.count, 5, "locked games stay in the list")
        XCTAssertEqual(vm.displayItems.filter { vm.isLocked($0) }.map(\.displayName),
                       ["D", "E"])
        XCTAssertEqual(vm.lockedCount, 2)
        XCTAssertTrue(vm.showsSubscribeOffer)
    }

    func testAProUserHasNothingLockedAndNoOffer() {
        let vm = makeViewModel(items: library())
        XCTAssertTrue(vm.displayItems.allSatisfy { !vm.isLocked($0) })
        XCTAssertEqual(vm.lockedCount, 0)
        XCTAssertFalse(vm.showsSubscribeOffer)
    }

    /// The bug this whole feature exists for: reordering the list must not
    /// hand the free slots to another three games.
    func testSortingDoesNotMoveTheFreeSlots() {
        let vm = makeViewModel(items: library(), entitlement: freeUser)
        for mode in GameListViewModel.SortMode.allCases {
            vm.sortMode = mode
            XCTAssertEqual(Set(vm.displayItems.filter { vm.isLocked($0) }.map(\.displayName)),
                           ["D", "E"], "sorted by \(mode)")
        }
    }

    /// Searching narrows what is shown, not what is owned: typing "D" must
    /// not promote the fourth game into a free slot.
    func testSearchingDoesNotUnlockAGame() {
        let vm = makeViewModel(items: library(), entitlement: freeUser)
        vm.searchText = "D"
        XCTAssertEqual(vm.displayItems.map(\.displayName), ["D"])
        XCTAssertTrue(vm.isLocked(vm.displayItems[0]))
    }

    func testChoosingALockedGameOpensTheGateInsteadOfTheDetail() {
        let vm = makeViewModel(items: library(), entitlement: freeUser)
        let locked = vm.displayItems.first { vm.isLocked($0) }!
        XCTAssertFalse(vm.select(locked))
        XCTAssertNotNil(vm.gateReason?.message)
    }

    func testChoosingAnUnlockedGameOpensTheDetail() {
        let vm = makeViewModel(items: library(), entitlement: freeUser)
        let playable = vm.displayItems.first { !vm.isLocked($0) }!
        XCTAssertTrue(vm.select(playable))
        XCTAssertNil(vm.gateReason)
    }

    /// A purchase has to unlock the library without waiting for a rescan.
    func testAPurchaseUnlocksTheLibraryImmediately() {
        let vm = makeViewModel(items: library(), entitlement: freeUser)
        XCTAssertEqual(vm.lockedCount, 2)
        vm.apply(entitlement: ProEntitlement(showsAdvertising: true,
                                             legacy: .notLegacy,
                                             purchase: .lifetime))
        XCTAssertEqual(vm.lockedCount, 0)
        XCTAssertTrue(vm.displayItems.allSatisfy { !vm.isLocked($0) })
    }

    /// The controller route is the one that used to bypass checks: A on a card
    /// and D-pad Right into the iPad pane both go through the same question.
    func testTheControllerRouteIsGatedToo() {
        let vm = makeViewModel(items: library(), entitlement: freeUser)
        let state = GamesTabState()
        state.configure(list: vm)
        vm.focusedIndex = vm.displayItems.firstIndex { vm.isLocked($0) }

        state.activate()
        XCTAssertNil(vm.pendingDetailItem, "A on a locked card must not open the detail")
        XCTAssertNotNil(vm.gateReason)

        vm.gateReason = nil
        XCTAssertFalse(state.openInDetailPane(),
                       "focus must stay in the list when the pane cannot show the game")
        XCTAssertNil(vm.pendingDetailItem)
        XCTAssertNotNil(vm.gateReason)
    }

    func testTheControllerRouteStillOpensAPlayableGame() {
        let vm = makeViewModel(items: library(), entitlement: freeUser)
        let state = GamesTabState()
        state.configure(list: vm)
        vm.focusedIndex = vm.displayItems.firstIndex { !vm.isLocked($0) }

        state.activate()
        XCTAssertNotNil(vm.pendingDetailItem)
        XCTAssertNil(vm.gateReason)
    }
}
