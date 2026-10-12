import XCTest
@testable import YabaSnashiro

/// A confirmation dialog draws its own selection, which the app cannot move.
/// Blocking A while one is up keeps it off the row behind -- but it also left
/// the dialog with no way to say yes, so every destructive confirmation was
/// unreachable by controller.
@MainActor
final class ConfirmationFocusTests: XCTestCase {
    private func makeScope() -> ActionListFocusModel {
        let scope = ActionListFocusModel(scopeName: "test")
        scope.setActions([{}])
        scope.focusedIndex = 0
        return scope
    }

    func testAConfirmsTheDialogRatherThanTheRowBehindIt() {
        var rowRan = false
        var confirmed = false
        let scope = ActionListFocusModel(scopeName: "test")
        scope.setActions([{ rowRan = true }])
        scope.focusedIndex = 0
        scope.isBlocked = { true }
        scope.onConfirm = { confirmed = true; return true }

        scope.activate()

        XCTAssertTrue(confirmed, "A did not confirm the dialog")
        XCTAssertFalse(rowRan, "A reached the row behind the dialog")
    }

    func testAStillRunsTheRowWhenNoDialogIsUp() {
        var rowRan = false
        var confirmed = false
        let scope = ActionListFocusModel(scopeName: "test")
        scope.setActions([{ rowRan = true }])
        scope.focusedIndex = 0
        scope.onConfirm = { confirmed = true; return true }

        scope.activate()

        XCTAssertTrue(rowRan)
        XCTAssertFalse(confirmed, "A confirmed a dialog that was not showing")
    }

    /// A screen that blocks without supplying a confirming action -- a system
    /// document picker, say -- must swallow A rather than do something the
    /// user cannot see.
    func testABlockedScopeWithNothingToConfirmIgnoresA() {
        var rowRan = false
        let scope = ActionListFocusModel(scopeName: "test")
        scope.setActions([{ rowRan = true }])
        scope.focusedIndex = 0
        scope.isBlocked = { true }

        scope.activate()
        XCTAssertFalse(rowRan)
    }

    /// The same rule one row up: a dialog covering the screen takes A, so a
    /// toolbar button cannot be pressed from behind one.
    func testABehindADialogDoesNotPressAToolbarButton() {
        var buttonRan = false
        var confirmed = false
        let scope = makeScope()
        scope.setToolbarActions([{ buttonRan = true }])
        scope.toolbarFocused = 0
        scope.isBlocked = { true }
        scope.onConfirm = { confirmed = true; return true }

        let coordinator = ControllerFocusCoordinator()
        coordinator.push(scope)
        coordinator.handle(.select)

        XCTAssertFalse(buttonRan, "A reached the toolbar from behind the dialog")
        XCTAssertTrue(confirmed)
    }

    /// A declared toolbar is reachable through the coordinator, which is the
    /// only wiring a screen adopting this scope has to do.
    func testAPressesTheFocusedToolbarButton() {
        var pressed: [Int] = []
        let scope = makeScope()
        scope.setToolbarActions([{ pressed.append(0) }, { pressed.append(1) }])

        let coordinator = ControllerFocusCoordinator()
        coordinator.push(scope)
        coordinator.handle(.up)
        coordinator.handle(.right)
        coordinator.handle(.select)

        XCTAssertEqual(pressed, [1])
    }

    /// A button that disappears must not leave focus pointing past the end.
    func testToolbarFocusIsClampedWhenTheButtonsShrink() {
        let scope = makeScope()
        scope.setToolbarActions([{}, {}])
        scope.toolbarFocused = 1
        scope.setToolbarActions([{}])
        XCTAssertEqual(scope.toolbarFocused, 0)
        scope.setToolbarActions([])
        XCTAssertNil(scope.toolbarFocused)
    }

    /// B keeps cancelling, so the pair reads as the button map promises.
    func testBStillCancels() {
        let scope = makeScope()
        var cancelled = false
        scope.isBlocked = { true }
        scope.onClose = { cancelled = true; return true }

        XCTAssertTrue(scope.close())
        XCTAssertTrue(cancelled)
    }
}
