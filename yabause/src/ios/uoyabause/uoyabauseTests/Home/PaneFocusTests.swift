import XCTest
@testable import YabaSnashiro

/// A pane-aware scope that records what the coordinator asked it to do.
@MainActor
private final class PaneScope: ControllerFocusScope {
    let scopeName: String
    let pane: ControllerPane?
    var itemCount: Int
    var focusedIndex: Int?
    var activateCount = 0
    var enteredCount = 0
    var openResult: Bool
    var openCount = 0

    init(name: String, pane: ControllerPane?, itemCount: Int = 3,
         openResult: Bool = false) {
        self.scopeName = name
        self.pane = pane
        self.itemCount = itemCount
        self.openResult = openResult
    }

    func activate() { activateCount += 1 }
    func close() -> Bool { true }

    func openInDetailPane() -> Bool {
        openCount += 1
        return openResult
    }

    func paneDidBecomeActive() {
        enteredCount += 1
        if focusedIndex == nil, itemCount > 0 { focusedIndex = 0 }
    }
}

/// D-pad Left/Right between the sidebar, the list and the detail pane
/// (spec section 4.3).
@MainActor
final class PaneFocusTests: XCTestCase {
    private var coordinator: ControllerFocusCoordinator!
    private var sidebar: PaneScope!
    private var content: PaneScope!

    override func setUp() {
        super.setUp()
        coordinator = ControllerFocusCoordinator()
        sidebar = PaneScope(name: "sidebar", pane: .sidebar, itemCount: 5)
        content = PaneScope(name: "content", pane: .content, itemCount: 4)
    }

    /// The regular-width layout, with a detail already showing.
    private func buildTwoPane(detailItems: Int = 3) -> PaneScope {
        let detail = PaneScope(name: "detail", pane: .detail,
                               itemCount: detailItems)
        coordinator.push(sidebar)
        coordinator.push(content)
        coordinator.push(detail)
        return detail
    }

    // MARK: - Compact width is untouched

    /// No sidebar scope means no second column, which is exactly the compact
    /// layout. Left and Right must do nothing at all there.
    func testLeftAndRightDoNothingWithoutASidebar() {
        coordinator.push(content)
        XCTAssertFalse(coordinator.isTwoPaneLayout)
        XCTAssertFalse(coordinator.handle(.left))
        XCTAssertFalse(coordinator.handle(.right))
        XCTAssertEqual(coordinator.activePane, .content)
        XCTAssertEqual(content.openCount, 0,
                       "a compact list must not be asked to fill a pane")
    }

    /// A sheet over the compact list still gets Up/Down and A as before.
    func testASheetStillTakesTheInputAtCompactWidth() {
        coordinator.push(content)
        let sheet = PaneScope(name: "sheet", pane: nil)
        coordinator.push(sheet)
        coordinator.handle(.down)
        XCTAssertEqual(sheet.focusedIndex, 0)
        XCTAssertNil(content.focusedIndex)
    }

    // MARK: - The transitions of spec section 4.3

    func testRightFromTheListGoesToTheDetailPane() {
        let detail = buildTwoPane()
        XCTAssertTrue(coordinator.handle(.right))
        XCTAssertEqual(coordinator.activePane, .detail)
        XCTAssertTrue(coordinator.top === detail)
        XCTAssertEqual(detail.enteredCount, 1)
    }

    func testLeftFromTheDetailPaneGoesBackToTheList() {
        _ = buildTwoPane()
        coordinator.handle(.right)
        XCTAssertTrue(coordinator.handle(.left))
        XCTAssertEqual(coordinator.activePane, .content)
        XCTAssertTrue(coordinator.top === content)
    }

    func testLeftFromTheListGoesToTheSidebar() {
        _ = buildTwoPane()
        XCTAssertTrue(coordinator.handle(.left))
        XCTAssertEqual(coordinator.activePane, .sidebar)
        XCTAssertTrue(coordinator.top === sidebar)
    }

    func testRightFromTheSidebarGoesToTheList() {
        _ = buildTwoPane()
        coordinator.handle(.left)
        XCTAssertTrue(coordinator.handle(.right))
        XCTAssertEqual(coordinator.activePane, .content)
        XCTAssertTrue(coordinator.top === content)
    }

    /// Both outer edges stop rather than wrapping, the way Up/Down clamps.
    func testTheOuterColumnsAreDeadEnds() {
        _ = buildTwoPane()
        coordinator.handle(.left)
        XCTAssertFalse(coordinator.handle(.left), "nothing is left of the sidebar")
        XCTAssertEqual(coordinator.activePane, .sidebar)

        coordinator.handle(.right)
        coordinator.handle(.right)
        XCTAssertFalse(coordinator.handle(.right), "nothing is right of the detail")
        XCTAssertEqual(coordinator.activePane, .detail)
    }

    /// Between a tab being replaced and the next one appearing there is no
    /// content column. Right out of the sidebar then would aim input at
    /// nothing, so it is refused and the ring stays in the sidebar.
    func testRightOutOfTheSidebarIsRefusedWithNoContentColumn() {
        coordinator.push(sidebar)
        coordinator.push(content)
        coordinator.handle(.left)
        coordinator.pop(content)
        XCTAssertFalse(coordinator.handle(.right))
        XCTAssertEqual(coordinator.activePane, .sidebar)
        XCTAssertTrue(coordinator.top === sidebar)
    }

    // MARK: - Right opens what it moves to

    /// The pane must show the row the user was pointing at, or Right would
    /// carry focus to a detail for some other game.
    func testRightAsksTheListToFillThePaneFirst() {
        content.openResult = true
        coordinator.push(sidebar)
        coordinator.push(content)
        XCTAssertTrue(coordinator.handle(.right))
        XCTAssertEqual(content.openCount, 1)
        XCTAssertEqual(coordinator.activePane, .detail)
    }

    /// With nothing to show - an empty library, or a tab with no detail
    /// column at all - focus stays put rather than moving somewhere with no
    /// ring in it.
    func testRightIsRefusedWhenThereIsNothingToShow() {
        coordinator.push(sidebar)
        coordinator.push(content)
        XCTAssertFalse(coordinator.handle(.right))
        XCTAssertEqual(coordinator.activePane, .content)
        XCTAssertTrue(coordinator.top === content)
    }

    /// The pane is built a runloop after the press that opened it, so the
    /// scope that arrives has to be greeted then.
    func testAPaneArrivingAfterTheMoveIsFocused() {
        content.openResult = true
        coordinator.push(sidebar)
        coordinator.push(content)
        coordinator.handle(.right)

        let detail = PaneScope(name: "detail", pane: .detail)
        coordinator.push(detail)
        XCTAssertEqual(detail.enteredCount, 1)
        XCTAssertEqual(detail.focusedIndex, 0, "a live pane always shows a ring")
        XCTAssertTrue(coordinator.top === detail)
    }

    /// SwiftUI may remove the outgoing pane before or after the incoming one
    /// appears. Right onto a different game must land in the pane either way,
    /// not back in the list.
    func testTheReplacementPaneIsFocusedWhateverTheTeardownOrder() {
        let first = buildTwoPane()
        coordinator.handle(.right)
        content.openResult = true
        coordinator.handle(.right)

        coordinator.pop(first)
        let second = PaneScope(name: "detail2", pane: .detail)
        coordinator.push(second)

        XCTAssertEqual(coordinator.activePane, .detail)
        XCTAssertTrue(coordinator.top === second)
        XCTAssertEqual(second.focusedIndex, 0)
    }

    /// A on a row opens the detail, and focus follows it into the pane - what
    /// A did before there was anywhere else for focus to be.
    func testAOnAListRowCarriesFocusIntoThePaneItOpens() {
        coordinator.push(sidebar)
        coordinator.push(content)
        coordinator.handle(.select)
        let detail = PaneScope(name: "detail", pane: .detail)
        coordinator.push(detail)
        XCTAssertEqual(coordinator.activePane, .detail)
        XCTAssertEqual(detail.focusedIndex, 0)
    }

    /// A pane that appears for any other reason must not take focus, or an
    /// L/R lap around the tabs would drop the user in the detail column of
    /// every tab that kept a selection.
    func testAPaneThatNobodyAskedForDoesNotTakeFocus() {
        coordinator.push(sidebar)
        coordinator.push(content)
        coordinator.handle(.down)
        let restored = PaneScope(name: "detail", pane: .detail)
        coordinator.push(restored)
        XCTAssertEqual(coordinator.activePane, .content)
        XCTAssertTrue(coordinator.top === content)
        XCTAssertNil(restored.focusedIndex)
    }

    /// Before any controller event, nothing is auto-focused: a touch user must
    /// not be shown a selection they never made (spec section 4.1).
    func testAPaneIsNotFocusedBeforeAnyControllerInput() {
        let detail = PaneScope(name: "detail", pane: .detail)
        coordinator.push(detail)
        XCTAssertEqual(detail.enteredCount, 0)
        XCTAssertNil(detail.focusedIndex)
    }

    // MARK: - Nothing strands the user

    /// B in the detail pane closes it. Input has to come back to the list, or
    /// the user is aiming at a column that is no longer there.
    func testLosingTheLivePaneReturnsFocusToTheList() {
        let detail = buildTwoPane()
        coordinator.handle(.right)
        XCTAssertEqual(coordinator.activePane, .detail)
        coordinator.pop(detail)
        XCTAssertEqual(coordinator.activePane, .content)
        XCTAssertTrue(coordinator.top === content)
        XCTAssertEqual(content.focusedIndex, 0, "and it shows a ring again")
    }

    /// Rotating or splitting out of the two-pane layout takes the sidebar
    /// away while focus is in it.
    func testLosingTheSidebarReturnsFocusToTheList() {
        _ = buildTwoPane()
        coordinator.handle(.left)
        coordinator.pop(sidebar)
        XCTAssertEqual(coordinator.activePane, .content)
        XCTAssertFalse(coordinator.isTwoPaneLayout)
        XCTAssertTrue(coordinator.top === content)
    }

    /// A tab change replaces the content scope while focus sits in the
    /// sidebar, which is the normal way to use it.
    func testChangingTabsFromTheSidebarKeepsFocusThere() {
        coordinator.push(sidebar)
        coordinator.push(content)
        coordinator.handle(.left)
        coordinator.pop(content)
        let other = PaneScope(name: "otherTab", pane: .content)
        coordinator.push(other)
        XCTAssertEqual(coordinator.activePane, .sidebar)
        XCTAssertTrue(coordinator.top === sidebar)
    }

    /// A sheet covers whichever column is live, so it takes the input and
    /// Left/Right stop moving until it is gone.
    func testASheetOverAPaneTakesTheInputAndBlocksLateralMoves() {
        let detail = buildTwoPane()
        coordinator.handle(.right)
        let sheet = PaneScope(name: "sheet", pane: nil)
        coordinator.push(sheet)

        coordinator.handle(.down)
        XCTAssertEqual(sheet.focusedIndex, 0)
        XCTAssertEqual(detail.focusedIndex, 0, "the pane behind it must not move")
        XCTAssertFalse(coordinator.handle(.left))
        XCTAssertEqual(coordinator.activePane, .detail)

        coordinator.pop(sheet)
        XCTAssertTrue(coordinator.top === detail)
    }

    // MARK: - Up/Down and A follow the live column

    func testUpAndDownMoveTheLiveColumnOnly() {
        let detail = buildTwoPane()
        coordinator.handle(.down)
        XCTAssertEqual(content.focusedIndex, 0)
        XCTAssertNil(detail.focusedIndex)

        coordinator.handle(.right)
        // Entering the pane already put the ring on its first row, so two
        // presses land on the third.
        coordinator.handle(.down)
        coordinator.handle(.down)
        XCTAssertEqual(content.focusedIndex, 0, "the list must not move from the pane")
        XCTAssertEqual(detail.focusedIndex, 2)
    }

    func testActivateGoesToTheLiveColumn() {
        let detail = buildTwoPane()
        coordinator.handle(.right)
        coordinator.handle(.select)
        XCTAssertEqual(detail.activateCount, 1)
        XCTAssertEqual(content.activateCount, 0)
    }
}
