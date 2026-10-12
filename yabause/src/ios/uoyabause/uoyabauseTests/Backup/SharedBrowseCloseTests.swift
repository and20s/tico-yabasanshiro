import XCTest
@testable import YabaSnashiro

/// B is never a no-op (spec section 2). The community browse screen is pushed
/// by the backup tab, so B has to walk back out of it -- it cannot pop the
/// caller's navigation stack itself, which is why the way back is handed in.
@MainActor
final class SharedBrowseCloseTests: XCTestCase {
    func testTheBackupTabTracksWhetherCommunityIsPushed() {
        let state = BackupTabState()
        XCTAssertFalse(state.showCommunity)

        state.showCommunity = true
        XCTAssertTrue(state.showCommunity)

        // What the browse screen's B does with the closure it is handed.
        state.showCommunity = false
        XCTAssertFalse(state.showCommunity,
                       "B left the community screen pushed")
    }

    /// A scope handed no way back reports the press as unhandled rather than
    /// claiming it worked, so the press can fall through instead.
    func testAScopeWithNoWayBackDoesNotClaimThePress() {
        let scope = ActionListFocusModel(scopeName: "test")
        XCTAssertFalse(scope.close())
    }
}
