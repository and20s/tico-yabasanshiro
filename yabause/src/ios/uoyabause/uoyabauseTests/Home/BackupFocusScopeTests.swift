import XCTest
@testable import YabaSnashiro

/// The backup tab's scope. One scope covers both halves of the tab; these pin
/// down the part of that decision a future change could silently break.
@MainActor
final class BackupFocusScopeTests: XCTestCase {
    private var coordinator: ControllerFocusCoordinator!
    private var state: BackupTabState!

    override func setUp() {
        super.setUp()
        coordinator = ControllerFocusCoordinator()
        state = BackupTabState()
    }

    /// The source row is always there, even with no lists attached, so a
    /// controller can always change store. Only the saves are missing.
    func testAnUnconfiguredStateOffersOnlyTheSourceRow() {
        XCTAssertEqual(state.itemCount, 1)
        state.focusedIndex = 0
        XCTAssertNil(state.saveIndex(for: 0), "row 0 is the source, not a save")

        // Nothing below it to move to.
        state.move(by: 1)
        XCTAssertEqual(state.focusedIndex, 0)
    }

    /// The defect this conversion fixes: B used to be an `onReceive` on the
    /// raw event stream, so a TabView keeping this tab alive meant B over a
    /// game's detail sheet also cleared this tab's search. Only the top of the
    /// stack is asked now.
    func testBackIsNotDeliveredWhileAnotherScopeIsOnTop() {
        var cleared = false
        state.isSearching = true
        state.onClearSearch = { cleared = true }
        coordinator.push(state)

        let sheet = ActionListFocusModel(scopeName: "someSheet", isModal: true)
        sheet.onClose = { true }
        coordinator.push(sheet)

        XCTAssertTrue(coordinator.handle(.back))
        XCTAssertFalse(cleared, "the sheet closes, not the tab behind it")
        XCTAssertTrue(state.isSearching)
    }

    func testBackClosesTheSearchFieldAndThenHasNothingLeft() {
        var cleared = false
        state.isSearching = true
        state.onClearSearch = { cleared = true }
        coordinator.push(state)

        XCTAssertTrue(coordinator.handle(.back))
        XCTAssertTrue(cleared)
        XCTAssertFalse(state.isSearching)
        XCTAssertFalse(coordinator.handle(.back), "the backup list is a tab root")
    }

    func testTheTabIsNotModalSoLRStillMovesTabs() {
        coordinator.push(state)
        XCTAssertTrue(coordinator.allowsTabChange)
    }

    func testActivateAsksTheViewWhichRowToOpen() {
        var opened: Int?
        state.configure(local: BackupListViewModel(), cloud: CloudBackupViewModel())
        state.onOpen = { opened = $0 }
        state.focusedIndex = 0
        coordinator.push(state)
        coordinator.handle(.select)
        // No saves are loaded in a unit test, so the guard holds and nothing
        // is opened. What matters is that it did not open a row that is not
        // there.
        XCTAssertNil(opened)
    }

    /// The cloud half only has rows once its list has loaded: its sign-in,
    /// upgrade and failure states are a single prompt the controller does not
    /// reach.
    func testTheCloudSectionHasNoRowsUntilItLoads() {
        let cloud = CloudBackupViewModel()
        state.configure(local: BackupListViewModel(), cloud: cloud)
        state.section = .cloud
        // The source row survives, so a signed-out cloud section can still be
        // switched away from rather than trapping the controller.
        XCTAssertEqual(state.itemCount, 1)
        XCTAssertNil(state.saveIndex(for: 0))
    }

    // MARK: - The unified source row

    /// Local memories and the cloud used to be two separate pickers. They are
    /// one list now, local first, so A steps through every store in turn.
    func testCyclingTheSourceVisitsEveryStoreAndWrapsBack() {
        let local = BackupListViewModel()
        state.configure(local: local, cloud: CloudBackupViewModel())

        let all = state.sources
        XCTAssertEqual(all.last, .cloud, "the cloud comes after the local memories")
        XCTAssertTrue(all.dropLast().allSatisfy { $0.isCloud == false })

        let start = state.currentSource
        for _ in all { state.cycleSource() }
        XCTAssertEqual(state.currentSource, start,
                       "a full cycle returns to where it started")
    }

    /// Cycling writes through to the two properties that really hold the
    /// selection, so the rest of the tab needs to know nothing about sources.
    func testSelectingACloudSourceSwitchesTheSection() {
        state.configure(local: BackupListViewModel(), cloud: CloudBackupViewModel())
        state.select(.cloud)
        XCTAssertEqual(state.section, .cloud)

        state.select(.local(.internalMemory))
        XCTAssertEqual(state.section, .local)
    }

    /// A on the source row changes store instead of opening a save, and never
    /// calls the open handler.
    func testActivatingTheSourceRowDoesNotOpenASave() {
        state.configure(local: BackupListViewModel(), cloud: CloudBackupViewModel())
        var opened: [Int] = []
        state.onOpen = { opened.append($0) }

        state.focusedIndex = BackupTabState.sourceRow
        let before = state.currentSource
        state.activate()

        XCTAssertTrue(opened.isEmpty, "the source row must not open a save")
        XCTAssertNotEqual(state.currentSource, before)
    }

    /// Right shows the focused save in the detail pane; the source row has
    /// nothing to show, so it refuses rather than moving to an empty column.
    func testTheSourceRowDoesNotOpenTheDetailPane() {
        state.configure(local: BackupListViewModel(), cloud: CloudBackupViewModel())
        state.focusedIndex = BackupTabState.sourceRow
        XCTAssertFalse(state.openInDetailPane())
    }

    /// The backup tab is a content column with a detail pane beside it, so
    /// D-pad Left/Right applies here exactly as it does in Games.
    func testTheBackupListIsTheContentColumn() {
        XCTAssertEqual(state.pane, .content)
    }

    /// With no rows there is nothing to show in the pane, so Right must be
    /// refused rather than carrying focus to a placeholder with no ring.
    func testRightIsRefusedWithNoRows() {
        state.configure(local: BackupListViewModel(), cloud: CloudBackupViewModel())
        state.focusedIndex = 0
        XCTAssertFalse(state.openInDetailPane())
    }

    func testASectionSwitchDropsTheSelection() {
        state.focusedIndex = 3
        state.resetFocus(controllerConnected: false)
        XCTAssertNil(state.focusedIndex)
    }
}
