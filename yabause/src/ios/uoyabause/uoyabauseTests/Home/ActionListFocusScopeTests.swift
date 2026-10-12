import XCTest
@testable import YabaSnashiro

/// The scope shared by the detail sheets, the add-game sheet and the account
/// tab, plus the inert scope that stands in for a presentation the controller
/// cannot drive.
@MainActor
final class ActionListFocusScopeTests: XCTestCase {
    private var coordinator: ControllerFocusCoordinator!

    override func setUp() {
        super.setUp()
        coordinator = ControllerFocusCoordinator()
    }

    private func model(_ count: Int, isModal: Bool = false) -> ActionListFocusModel {
        let model = ActionListFocusModel(scopeName: "test", isModal: isModal)
        model.setActions((0..<count).map { _ in {} })
        return model
    }

    func testMovementIsClampedAtBothEnds() {
        let scope = model(3)
        coordinator.push(scope)
        coordinator.handle(.up)
        XCTAssertEqual(scope.focusedIndex, 0, "the first move enters at the top")
        coordinator.handle(.up)
        XCTAssertEqual(scope.focusedIndex, 0)
        for _ in 0..<5 { coordinator.handle(.down) }
        XCTAssertEqual(scope.focusedIndex, 2, "no wrap at the bottom")
    }

    func testActivateRunsTheFocusedAction() {
        var fired: [Int] = []
        let scope = ActionListFocusModel(scopeName: "test")
        scope.setActions([{ fired.append(0) }, { fired.append(1) }])
        scope.focusedIndex = 1
        coordinator.push(scope)
        coordinator.handle(.select)
        XCTAssertEqual(fired, [1])
    }

    /// A row can disappear while it is the focused one - an upload button
    /// replaced by a spinner, a subscription card that resolves.
    func testShrinkingTheRowsPullsTheSelectionBack() {
        let scope = model(4)
        scope.focusedIndex = 3
        scope.setActions([{}, {}])
        XCTAssertEqual(scope.focusedIndex, 1)
        scope.setActions([])
        XCTAssertNil(scope.focusedIndex)
    }

    /// A UIAlertController or a confirmationDialog draws its own selection,
    /// which the app cannot move, so A must not reach the row behind it.
    func testActivateIsSuppressedWhileADialogIsUp() {
        var fired = false
        let scope = ActionListFocusModel(scopeName: "test")
        scope.setActions([{ fired = true }])
        scope.focusedIndex = 0
        scope.isBlocked = { true }
        coordinator.push(scope)
        coordinator.handle(.select)
        XCTAssertFalse(fired)
    }

    func testInitialFocusOnlyAppliesWithAControllerAndRows() {
        let empty = model(0)
        empty.applyInitialFocus(controllerConnected: true)
        XCTAssertNil(empty.focusedIndex)

        let scope = model(2)
        scope.applyInitialFocus(controllerConnected: false)
        XCTAssertNil(scope.focusedIndex, "touch users get no selection")
        scope.applyInitialFocus(controllerConnected: true)
        XCTAssertEqual(scope.focusedIndex, 0)
    }

    func testAModalScopeSuppressesTabChange() {
        coordinator.push(model(1))
        XCTAssertTrue(coordinator.allowsTabChange)
        coordinator.push(model(1, isModal: true))
        XCTAssertFalse(coordinator.allowsTabChange)
    }

    /// B is never a silent no-op: a scope that has no way to close says so,
    /// rather than reporting success.
    func testCloseReportsFailureWhenNoHandlerIsSet() {
        let scope = model(1)
        coordinator.push(scope)
        XCTAssertFalse(coordinator.handle(.back))
    }

    // MARK: - ModalBlockerScope

    func testTheBlockerSwallowsEverythingButBack() {
        var closed = false
        let blocker = ModalBlockerScope()
        blocker.onClose = { closed = true }
        let underneath = model(3)
        underneath.focusedIndex = 1

        coordinator.push(underneath)
        coordinator.push(blocker)

        coordinator.handle(.down)
        coordinator.handle(.select)
        XCTAssertEqual(underneath.focusedIndex, 1,
                       "the screen underneath must not move behind the sheet")
        XCTAssertFalse(coordinator.allowsTabChange)

        XCTAssertTrue(coordinator.handle(.back))
        XCTAssertTrue(closed)
    }
}
