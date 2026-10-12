import XCTest
@testable import YabaSnashiro

/// The two scopes the games tab declares, exercised through the same
/// coordinator the app uses so the routing is covered too.
@MainActor
final class ControllerFocusScopeTests: XCTestCase {
    private var coordinator: ControllerFocusCoordinator!
    private var list: GameListViewModel!
    private var state: GamesTabState!

    override func setUp() {
        super.setUp()
        coordinator = ControllerFocusCoordinator()
        list = GameListViewModel(repository: GameRepository(),
                                 defaults: UserDefaults(suiteName: "focus-scope-tests")!)
        state = GamesTabState()
        state.configure(list: list)
    }

    // MARK: - GamesTabState

    func testUnconfiguredStateReportsNothingFocusable() {
        let orphan = GamesTabState()
        XCTAssertEqual(orphan.itemCount, 0)
        XCTAssertNil(orphan.focusedIndex)
        orphan.move(by: 1)
        XCTAssertNil(orphan.focusedIndex)
    }

    func testFocusIsStoredOnTheListViewModel() {
        state.focusedIndex = 2
        XCTAssertEqual(list.focusedIndex, 2)
        list.focusedIndex = 5
        XCTAssertEqual(state.focusedIndex, 5)
    }

    func testInitialFocusOnlyAppliesWithAControllerAndItems() {
        state.applyInitialFocus(controllerConnected: true)
        XCTAssertNil(state.focusedIndex, "no items yet")

        list.focusedIndex = nil
        state.applyInitialFocus(controllerConnected: false)
        XCTAssertNil(state.focusedIndex, "touch users get no selection")
    }

    func testInitialFocusDoesNotOverrideAnExistingSelection() {
        list.focusedIndex = 3
        state.applyInitialFocus(controllerConnected: true)
        XCTAssertEqual(state.focusedIndex, 3)
    }

    func testBackClosesTheSearchFieldAndThenHasNothingLeft() {
        state.isSearching = true
        list.searchText = "sonic"
        coordinator.push(state)
        XCTAssertTrue(coordinator.handle(.back))
        XCTAssertFalse(state.isSearching)
        XCTAssertEqual(list.searchText, "")
        XCTAssertFalse(coordinator.handle(.back), "the games list is the root scope")
    }

    /// The list is the tab's content column and the detail beside it is the
    /// pane; as a sheet the same detail covers the list, so it is neither.
    func testTheColumnEachScopeDeclares() {
        XCTAssertEqual(state.pane, .content)
        XCTAssertEqual(GameDetailFocusModel(isModal: false).pane, .detail)
        XCTAssertNil(GameDetailFocusModel(isModal: true).pane)
    }

    /// D-pad Right shows the focused card in the pane before focus moves
    /// there, so the pane is the game the user was pointing at.
    func testRightShowsTheFocusedGameInThePane() {
        let items = seedLibrary()
        state.focusedIndex = 1
        XCTAssertTrue(state.openInDetailPane())
        XCTAssertEqual(list.pendingDetailItem?.id, items[1].id)
    }

    func testRightIsRefusedWhenTheLibraryIsEmpty() {
        state.focusedIndex = 0
        XCTAssertFalse(state.openInDetailPane())
        XCTAssertNil(list.pendingDetailItem)
    }

    /// Two games, sorted by name so the order here is the drawn order.
    private func seedLibrary() -> [GameItem] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let repository = GameRepository(rootDirectory: directory,
                                        cache: GameListCache(directory: directory))
        let items = ["Astal", "Burning Rangers"].enumerated().map { index, name -> GameItem in
            var info = GameInfo()
            info.filePath = "/game\(index).chd"
            info.displayName = name
            info.productNumber = "GS-000\(index)"
            return GameItem(gameInfo: info)
        }
        repository.persist(items)
        list = GameListViewModel(
            repository: repository,
            defaults: UserDefaults(suiteName: "focus-scope-tests")!)
        list.loadCached()
        state.configure(list: list)
        XCTAssertEqual(list.displayItems.count, 2)
        return list.displayItems
    }

    func testGamesScopeIsNotModal() {
        coordinator.push(state)
        XCTAssertTrue(coordinator.allowsTabChange)
    }

    // MARK: - GameDetailFocusModel

    func testDetailOpensWithPlayFocused() {
        let rows = GameDetailFocusModel(isModal: true)
        XCTAssertEqual(rows.focusedIndex, GameDetailFocusModel.Row.play.rawValue)
    }

    func testDetailSheetIsModalAndThePaneIsNot() {
        XCTAssertTrue(GameDetailFocusModel(isModal: true).isModal)
        XCTAssertFalse(GameDetailFocusModel(isModal: false).isModal)
    }

    func testAOnPlayStartsTheGame() {
        let rows = GameDetailFocusModel(isModal: true)
        var played = 0
        rows.onPlay = { played += 1 }
        coordinator.push(rows)
        coordinator.handle(.select)
        XCTAssertEqual(played, 1)
    }

    func testRowOrderIsPlayFileInfoRemove() {
        let rows = GameDetailFocusModel(isModal: true)
        coordinator.push(rows)
        coordinator.handle(.down)
        coordinator.handle(.select)
        XCTAssertTrue(rows.showFileInfo)
        rows.showFileInfo = false
        coordinator.handle(.down)
        coordinator.handle(.select)
        XCTAssertTrue(rows.showDeleteConfirm)
    }

    func testAIsIgnoredWhileADialogIsUp() {
        let rows = GameDetailFocusModel(isModal: true)
        var played = 0
        rows.onPlay = { played += 1 }
        rows.showDeleteConfirm = true
        coordinator.push(rows)
        coordinator.handle(.select)
        XCTAssertEqual(played, 0, "the alert draws its own selection")
    }

    func testBUnwindsTheDialogBeforeTheDetailView() {
        let rows = GameDetailFocusModel(isModal: true)
        var dismissed = 0
        rows.onDismiss = { dismissed += 1 }
        rows.showDeleteConfirm = true
        coordinator.push(rows)

        XCTAssertTrue(coordinator.handle(.back))
        XCTAssertFalse(rows.showDeleteConfirm)
        XCTAssertEqual(dismissed, 0)

        XCTAssertTrue(coordinator.handle(.back))
        XCTAssertEqual(dismissed, 1)
    }

    /// B must never be a no-op while a detail view is presented.
    func testBAlwaysClosesAPresentedDetailView() {
        for modal in [true, false] {
            let rows = GameDetailFocusModel(isModal: modal)
            var dismissed = false
            rows.onDismiss = { dismissed = true }
            let local = ControllerFocusCoordinator()
            local.push(rows)
            XCTAssertTrue(local.handle(.back))
            XCTAssertTrue(dismissed)
        }
    }

    // MARK: - The whole games stack

    func testAnOpenSheetTakesEveryEventFromTheList() {
        list.focusedIndex = 1
        coordinator.push(state)
        let rows = GameDetailFocusModel(isModal: true)
        coordinator.push(rows)

        coordinator.handle(.down)
        coordinator.handle(.down)
        coordinator.handle(.select)

        XCTAssertEqual(list.focusedIndex, 1, "the hidden list must not move")
        XCTAssertNil(list.pendingDetailItem,
                     "A must not swap the sheet's content out from under the user")
        XCTAssertFalse(coordinator.allowsTabChange, "L/R must not change tab")
    }
}
