import XCTest
@testable import YabaSnashiro

/// A scope that records what the coordinator asked it to do.
@MainActor
private final class SpyScope: ControllerFocusScope {
    let scopeName: String
    let isModal: Bool
    var itemCount: Int
    var focusedIndex: Int?
    var activateCount = 0
    var closeResult: Bool
    var closeCount = 0

    init(name: String, itemCount: Int = 3, isModal: Bool = false,
         closeResult: Bool = true) {
        self.scopeName = name
        self.itemCount = itemCount
        self.isModal = isModal
        self.closeResult = closeResult
    }

    func activate() { activateCount += 1 }

    func close() -> Bool {
        closeCount += 1
        return closeResult
    }
}

/// A scope that also declares navigation bar buttons, plus a pane so the
/// column movement it has to override can be exercised.
@MainActor
private final class ToolbarSpyScope: ControllerFocusScope {
    let scopeName: String
    var itemCount: Int
    var focusedIndex: Int?
    var toolbarFocusedIndex: Int?
    var pane: ControllerPane?
    /// Which toolbar button was run, in order.
    var pressed: [Int] = []
    var activateCount = 0

    init(name: String, buttons: Int = 2, itemCount: Int = 3,
         pane: ControllerPane? = nil) {
        self.scopeName = name
        self.itemCount = itemCount
        self.pane = pane
        buttonCount = buttons
    }

    private let buttonCount: Int

    var toolbarActions: [() -> Void] {
        (0..<buttonCount).map { index in { [weak self] in self?.pressed.append(index) } }
    }

    func activate() { activateCount += 1 }

    func close() -> Bool { false }
}

@MainActor
final class ControllerToolbarFocusTests: XCTestCase {
    private var coordinator: ControllerFocusCoordinator!
    private var scope: ToolbarSpyScope!

    override func setUp() {
        super.setUp()
        coordinator = ControllerFocusCoordinator()
        scope = ToolbarSpyScope(name: "list")
        coordinator.push(scope)
        scope.focusedIndex = 0
    }

    func testUpAtTheFirstRowEntersTheToolbarAndStaysThere() {
        coordinator.handle(.up)
        XCTAssertEqual(scope.toolbarFocusedIndex, 0)
        XCTAssertNil(scope.focusedIndex, "only one ring is drawn at a time")

        coordinator.handle(.up)
        XCTAssertEqual(scope.toolbarFocusedIndex, 0, "nothing sits above the toolbar")
    }

    func testUpFromALowerRowJustMovesUpTheList() {
        scope.focusedIndex = 2
        coordinator.handle(.up)
        XCTAssertEqual(scope.focusedIndex, 1)
        XCTAssertNil(scope.toolbarFocusedIndex)
    }

    func testLeftAndRightWalkTheToolbarAndClamp() {
        coordinator.handle(.up)
        XCTAssertTrue(coordinator.handle(.right))
        XCTAssertEqual(scope.toolbarFocusedIndex, 1)
        coordinator.handle(.right)
        XCTAssertEqual(scope.toolbarFocusedIndex, 1, "must not wrap past the last button")
        coordinator.handle(.left)
        XCTAssertEqual(scope.toolbarFocusedIndex, 0)
        coordinator.handle(.left)
        XCTAssertEqual(scope.toolbarFocusedIndex, 0, "must not wrap past the first button")
    }

    func testDownLeavesTheToolbarForTheFirstRow() {
        coordinator.handle(.up)
        coordinator.handle(.down)
        XCTAssertNil(scope.toolbarFocusedIndex)
        XCTAssertEqual(scope.focusedIndex, 0)
    }

    func testAcceptRunsTheFocusedToolbarButtonNotTheRow() {
        coordinator.handle(.up)
        coordinator.handle(.right)
        coordinator.handle(.select)
        XCTAssertEqual(scope.pressed, [1])
        XCTAssertEqual(scope.activateCount, 0, "A must not reach the list behind it")
    }

    func testAcceptGoesBackToTheRowOnceTheToolbarIsLeft() {
        coordinator.handle(.up)
        coordinator.handle(.down)
        coordinator.handle(.select)
        XCTAssertEqual(scope.pressed, [])
        XCTAssertEqual(scope.activateCount, 1)
    }

    /// The deliberate override: the toolbar spans the whole tab, so while
    /// focus is in it Left/Right walks the buttons instead of changing column.
    func testLeftAndRightInTheToolbarDoNotChangeColumnAtRegularWidth() {
        let coordinator = ControllerFocusCoordinator()
        let sidebar = ToolbarSpyScope(name: "sidebar", buttons: 0, pane: .sidebar)
        let content = ToolbarSpyScope(name: "content", pane: .content)
        coordinator.push(sidebar)
        coordinator.push(content)
        XCTAssertTrue(coordinator.isTwoPaneLayout)
        content.focusedIndex = 0

        coordinator.handle(.up)
        coordinator.handle(.left)
        XCTAssertEqual(coordinator.activePane, .content, "the column must not change")
        XCTAssertEqual(content.toolbarFocusedIndex, 0)

        coordinator.handle(.right)
        XCTAssertEqual(coordinator.activePane, .content)
        XCTAssertEqual(content.toolbarFocusedIndex, 1)

        // Down is the way out, and the column moves again from there.
        coordinator.handle(.down)
        XCTAssertTrue(coordinator.handle(.left))
        XCTAssertEqual(coordinator.activePane, .sidebar)
    }

    func testAnEmptyListStillReachesAndKeepsTheToolbar() {
        let scope = ToolbarSpyScope(name: "empty", itemCount: 0)
        let coordinator = ControllerFocusCoordinator()
        coordinator.push(scope)
        coordinator.handle(.up)
        XCTAssertEqual(scope.toolbarFocusedIndex, 0)
        coordinator.handle(.down)
        XCTAssertEqual(scope.toolbarFocusedIndex, 0,
                       "leaving would put focus where no ring can be drawn")
    }

    /// A scope that declares no buttons is exactly as it was before the
    /// toolbar existed.
    func testAScopeWithNoToolbarIsUnaffected() {
        let scope = SpyScope(name: "plain", itemCount: 3)
        let coordinator = ControllerFocusCoordinator()
        coordinator.push(scope)
        scope.focusedIndex = 0
        coordinator.handle(.up)
        XCTAssertEqual(scope.focusedIndex, 0)
        XCTAssertNil(scope.toolbarFocusedIndex)
        coordinator.handle(.select)
        XCTAssertEqual(scope.activateCount, 1)
    }

    /// Entering a pane while focus is in its toolbar must not add a second
    /// ring in the list below.
    func testPaneActivationLeavesToolbarFocusAlone() {
        coordinator.handle(.up)
        scope.paneDidBecomeActive()
        XCTAssertNil(scope.focusedIndex)
        XCTAssertEqual(scope.toolbarFocusedIndex, 0)
    }
}

@MainActor
final class ControllerFocusCoordinatorTests: XCTestCase {
    private var coordinator: ControllerFocusCoordinator!

    override func setUp() {
        super.setUp()
        coordinator = ControllerFocusCoordinator()
    }

    // MARK: - Stack mechanics

    func testEmptyStackConsumesNothing() {
        XCTAssertNil(coordinator.top)
        XCTAssertFalse(coordinator.handle(.down))
        XCTAssertFalse(coordinator.handle(.select))
        XCTAssertFalse(coordinator.handle(.back))
    }

    func testPushAndPop() {
        let list = SpyScope(name: "list")
        let sheet = SpyScope(name: "sheet")
        coordinator.push(list)
        coordinator.push(sheet)
        XCTAssertEqual(coordinator.stackNames, ["list", "sheet"])
        XCTAssertTrue(coordinator.top === sheet)
        coordinator.pop(sheet)
        XCTAssertEqual(coordinator.stackNames, ["list"])
        XCTAssertTrue(coordinator.top === list)
    }

    func testPushingTheSameScopeTwiceIsIdempotent() {
        let list = SpyScope(name: "list")
        coordinator.push(list)
        coordinator.push(list)
        XCTAssertEqual(coordinator.depth, 1)
    }

    /// SwiftUI can run a replacement view's onAppear before the replaced
    /// view's onDisappear, so a pop must remove that instance wherever it is.
    func testPopRemovesTheNamedScopeNotTheTop() {
        let list = SpyScope(name: "list")
        let oldPane = SpyScope(name: "pane1")
        let newPane = SpyScope(name: "pane2")
        coordinator.push(list)
        coordinator.push(oldPane)
        coordinator.push(newPane)
        coordinator.pop(oldPane)
        XCTAssertEqual(coordinator.stackNames, ["list", "pane2"])
        XCTAssertTrue(coordinator.top === newPane)
    }

    func testPoppingAScopeThatIsNotOnTheStackDoesNothing() {
        let list = SpyScope(name: "list")
        coordinator.push(list)
        coordinator.pop(SpyScope(name: "stranger"))
        XCTAssertEqual(coordinator.stackNames, ["list"])
    }

    // MARK: - Only the top scope receives input

    func testOnlyTheTopScopeIsMoved() {
        let list = SpyScope(name: "list", itemCount: 10)
        let sheet = SpyScope(name: "sheet", itemCount: 3)
        list.focusedIndex = 4
        coordinator.push(list)
        coordinator.push(sheet)

        coordinator.handle(.down)
        coordinator.handle(.down)
        XCTAssertEqual(list.focusedIndex, 4, "the list behind a sheet must not move")
        XCTAssertEqual(sheet.focusedIndex, 1)
    }

    func testOnlyTheTopScopeIsActivated() {
        let list = SpyScope(name: "list")
        let sheet = SpyScope(name: "sheet")
        coordinator.push(list)
        coordinator.push(sheet)
        coordinator.handle(.select)
        XCTAssertEqual(list.activateCount, 0,
                       "A must not swap the sheet's content from underneath it")
        XCTAssertEqual(sheet.activateCount, 1)
    }

    func testBackClosesTheTopScopeOnly() {
        let list = SpyScope(name: "list")
        let sheet = SpyScope(name: "sheet")
        coordinator.push(list)
        coordinator.push(sheet)
        XCTAssertTrue(coordinator.handle(.back))
        XCTAssertEqual(sheet.closeCount, 1)
        XCTAssertEqual(list.closeCount, 0)
    }

    func testBackIsUnconsumedWhenTheRootHasNothingToClose() {
        let list = SpyScope(name: "list", closeResult: false)
        coordinator.push(list)
        XCTAssertFalse(coordinator.handle(.back))
        XCTAssertEqual(list.closeCount, 1, "B is still offered to the scope")
    }

    // MARK: - Tab gating

    func testTabChangeIsAllowedWithNoModal() {
        coordinator.push(SpyScope(name: "list"))
        coordinator.push(SpyScope(name: "pane", isModal: false))
        XCTAssertTrue(coordinator.allowsTabChange)
    }

    func testTabChangeIsBlockedBehindAModal() {
        coordinator.push(SpyScope(name: "list"))
        let sheet = SpyScope(name: "sheet", isModal: true)
        coordinator.push(sheet)
        XCTAssertFalse(coordinator.allowsTabChange)
        coordinator.pop(sheet)
        XCTAssertTrue(coordinator.allowsTabChange)
    }

    func testTabEventsAreNeverConsumedByAScope() {
        coordinator.push(SpyScope(name: "list"))
        XCTAssertFalse(coordinator.handle(.nextTab))
        XCTAssertFalse(coordinator.handle(.prevTab))
    }

    // MARK: - Movement

    func testFirstMoveEntersAtTheFirstItem() {
        let list = SpyScope(name: "list", itemCount: 5)
        coordinator.push(list)
        coordinator.handle(.down)
        XCTAssertEqual(list.focusedIndex, 0)
    }

    func testMovementClampsAtBothEnds() {
        let list = SpyScope(name: "list", itemCount: 3)
        coordinator.push(list)
        for _ in 0..<6 { coordinator.handle(.down) }
        XCTAssertEqual(list.focusedIndex, 2, "must not wrap past the end")
        for _ in 0..<6 { coordinator.handle(.up) }
        XCTAssertEqual(list.focusedIndex, 0, "must not wrap past the start")
    }

    func testMovementOnAnEmptyScopeDoesNothing() {
        let list = SpyScope(name: "list", itemCount: 0)
        coordinator.push(list)
        coordinator.handle(.down)
        XCTAssertNil(list.focusedIndex)
    }
}
