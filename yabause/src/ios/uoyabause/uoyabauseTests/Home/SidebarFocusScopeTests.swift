import XCTest
@testable import YabaSnashiro

/// The sidebar as a focus scope: the second way to change tabs, for people who
/// would rather not learn the shoulder buttons.
@MainActor
final class SidebarFocusScopeTests: XCTestCase {
    private var coordinator: ControllerFocusCoordinator!
    private var sidebar: SidebarFocusModel!
    private var tab: HomeTab = .games
    private var selected: [HomeTab] = []

    override func setUp() {
        super.setUp()
        coordinator = ControllerFocusCoordinator()
        sidebar = SidebarFocusModel()
        sidebar.entries = [.games, .backup, .add, .settings, .account]
        sidebar.currentTab = tab
        sidebar.onSelect = { [unowned self] in
            self.selected.append($0)
            if $0 != .add {
                self.tab = $0
                self.sidebar.currentTab = $0
            }
        }
    }

    func testItCountsTheEntriesItDraws() {
        XCTAssertEqual(sidebar.itemCount, 5)
        XCTAssertEqual(sidebar.pane, .sidebar)
    }

    /// Entering puts the highlight on the tab that is showing. A highlight
    /// left over from an abandoned walk would claim the user is somewhere
    /// they are not.
    func testEnteringHighlightsTheTabThatIsShowing() {
        sidebar.currentTab = .settings
        sidebar.paneDidBecomeActive()
        XCTAssertEqual(sidebar.focused, 3)

        sidebar.move(by: -1)
        XCTAssertEqual(sidebar.focused, 2)
        sidebar.paneDidBecomeActive()
        XCTAssertEqual(sidebar.focused, 3, "the abandoned walk is forgotten")
    }

    /// Moving the highlight is not choosing. Committing on the way past would
    /// rebuild the detail column once per press and would open the add-game
    /// sheet merely for crossing the Add entry.
    func testMovingDoesNotChangeTheTab() {
        sidebar.paneDidBecomeActive()
        sidebar.move(by: 1)
        sidebar.move(by: 1)
        XCTAssertTrue(selected.isEmpty)
        XCTAssertEqual(tab, .games)
    }

    func testActivateCommitsTheHighlightedTab() {
        sidebar.paneDidBecomeActive()
        sidebar.move(by: 1)
        sidebar.activate()
        XCTAssertEqual(selected, [.backup])
        XCTAssertEqual(tab, .backup)
    }

    /// Add is an action, and the sidebar hands it over unchanged: MainTabView
    /// decides that it opens a sheet instead of selecting a tab.
    func testActivateOnAddIsHandedOverToo() {
        sidebar.paneDidBecomeActive()
        sidebar.move(by: 2)
        sidebar.activate()
        XCTAssertEqual(selected, [.add])
        XCTAssertEqual(tab, .games, "and the tab does not move")
    }

    func testMovementClampsAtBothEnds() {
        coordinator.push(sidebar)
        for _ in 0..<8 { coordinator.handle(.down) }
        XCTAssertEqual(sidebar.focused, 4)
        for _ in 0..<8 { coordinator.handle(.up) }
        XCTAssertEqual(sidebar.focused, 0)
    }

    /// B at the leftmost column has nothing to close, so it is not consumed
    /// and is ignored rather than pretending to have done something.
    func testBackIsNotConsumed() {
        XCTAssertFalse(sidebar.close())
    }
}
