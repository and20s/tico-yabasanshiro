import XCTest

/// Every real route to `ProGateSheet` needs state a UI test cannot set up:
/// the account tab needs a signed-in Firebase user, and the fourth-game
/// route needs three real disc images already imported. This test does not
/// cover either user route. It launches with a debug-only argument that
/// opens the sheet directly, so it only proves the sheet renders without
/// crashing and carries its accessibility identifier.
final class ProGateTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testTheGateRendersAndCarriesItsIdentifier() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestProGate"]
        app.launch()

        // Not `.otherElements`: the identifier sits on a ScrollView, which
        // XCUITest reports as its own element type, not "Other" -- the same
        // trap ScreenshotTour documents for `gameDetailPlaceholder`.
        let gate = app.descendants(matching: .any).matching(identifier: "proGate").firstMatch
        XCTAssertTrue(gate.waitForExistence(timeout: 10), "the pro gate never opened")
    }
}
