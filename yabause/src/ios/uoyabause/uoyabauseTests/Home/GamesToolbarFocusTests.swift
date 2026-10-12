import XCTest
@testable import YabaSnashiro

/// The toolbar routing is shared, but each scope supplies its own
/// `focusedIndex` storage. GamesTabState forwards that to the list view model,
/// so it is worth pinning that Up out of the list still reaches the toolbar.
@MainActor
final class GamesToolbarFocusTests: XCTestCase {
    func testUpFromTheFirstCardEntersTheToolbar() {
        let list = GameListViewModel()
        let state = GamesTabState()
        state.configure(list: list)
        state.toolbar = [{}, {}]

        state.focusedIndex = 0
        state.move(by: -1)

        XCTAssertEqual(state.toolbarFocusedIndex, 0,
                       "Up at the first card did not reach the toolbar")
        XCTAssertNil(state.focusedIndex, "two rings would be drawn at once")
    }

    func testUpWithNoToolbarDeclaredDoesNothing() {
        let list = GameListViewModel()
        let state = GamesTabState()
        state.configure(list: list)

        state.focusedIndex = 0
        state.move(by: -1)

        XCTAssertNil(state.toolbarFocusedIndex)
        XCTAssertEqual(state.focusedIndex, 0)
    }

    /// Down only leaves when there is a list to land in: with none, staying
    /// keeps a ring on screen rather than losing focus entirely.
    func testDownStaysInTheToolbarWhenTheLibraryIsEmpty() {
        let list = GameListViewModel()
        let state = GamesTabState()
        state.configure(list: list)
        state.toolbar = [{}, {}]
        state.toolbarFocusedIndex = 0

        state.move(by: 1)

        XCTAssertEqual(state.toolbarFocusedIndex, 0)
    }
}

/// Leaving a pane should not leave a second ring behind in it.
@MainActor
final class SidebarFocusReleaseTests: XCTestCase {
    func testTheSidebarDropsItsRingWhenFocusMovesToTheList() {
        let sidebar = SidebarFocusModel()
        sidebar.entries = HomeTab.allCases
        sidebar.currentTab = .games

        sidebar.paneDidBecomeActive()
        XCTAssertNotNil(sidebar.focusedIndex, "entering the sidebar drew no ring")

        sidebar.paneDidResignActive()
        XCTAssertNil(sidebar.focusedIndex,
                     "the sidebar kept a ring after focus moved to the list")
    }

    /// Re-entering puts the ring back on the tab that is showing, so nothing
    /// is lost by clearing it.
    func testReenteringTheSidebarLandsOnTheCurrentTab() {
        let sidebar = SidebarFocusModel()
        sidebar.entries = HomeTab.allCases
        sidebar.currentTab = .settings

        sidebar.paneDidResignActive()
        sidebar.paneDidBecomeActive()

        XCTAssertEqual(sidebar.focusedIndex,
                       HomeTab.allCases.firstIndex(of: .settings))
    }

    /// A list pane keeps its dimmed ring, which is how the user sees what
    /// Left would bring them back to.
    func testAListPaneKeepsItsRing() {
        let scope = ActionListFocusModel(scopeName: "test", pane: .content)
        scope.setActions([{}, {}])
        scope.focusedIndex = 1

        scope.paneDidResignActive()

        XCTAssertEqual(scope.focusedIndex, 1)
    }
}
