import Combine
import XCTest
@testable import YabaSnashiro

/// Holding Up or Down walks the list. The repeat itself needs a controller to
/// exercise, so these pin the parts that can be reasoned about without one.
@MainActor
final class GamePadRepeatTests: XCTestCase {
    /// A press has to register before the delay elapses, or a single tap
    /// would feel laggy.
    func testTheFirstStepIsNotDelayed() {
        let manager = HomeGamePadManager()
        var received: [HomeGamePadManager.Event] = []
        let subscription = manager.events.sink { received.append($0) }
        defer { subscription.cancel() }

        // What the press handler does before starting the repeat.
        manager.sendForTesting(.down)
        XCTAssertEqual(received, [.down])
    }

    /// Long enough that a deliberate single press is one step, short enough
    /// that holding does not feel stuck.
    func testTheRepeatDelayLeavesRoomForASinglePress() {
        XCTAssertGreaterThanOrEqual(HomeGamePadManager.repeatDelay,
                                    .milliseconds(300))
        XCTAssertLessThanOrEqual(HomeGamePadManager.repeatDelay,
                                 .milliseconds(600))
    }

    /// Fast enough to walk a long list, slow enough to read.
    func testTheRepeatIntervalIsInAUsableRange() {
        XCTAssertGreaterThanOrEqual(HomeGamePadManager.repeatInterval,
                                    .milliseconds(80))
        XCTAssertLessThanOrEqual(HomeGamePadManager.repeatInterval,
                                 .milliseconds(250))
        XCTAssertLessThan(HomeGamePadManager.repeatInterval,
                          HomeGamePadManager.repeatDelay,
                          "repeats must come faster than the delay before them")
    }

    /// The list clamps, so a held direction stops at the end rather than
    /// running off it.
    func testAHeldDirectionStopsAtTheEndOfTheList() {
        let scope = ActionListFocusModel(scopeName: "test")
        scope.setActions([{}, {}, {}])
        scope.focusedIndex = 0

        for _ in 0..<10 { scope.move(by: 1) }
        XCTAssertEqual(scope.focusedIndex, 2)

        for _ in 0..<10 { scope.move(by: -1) }
        XCTAssertEqual(scope.focusedIndex, 0)
    }
}
