import Combine
import Foundation

/// Controller focus scope of the regular-width sidebar.
///
/// Declaring the sidebar as a scope is what makes "D-pad Left goes to the
/// sidebar" mean something: once focus is there, Up/Down walks the five
/// entries and A commits one, which gives controller users a way to change
/// tabs that does not depend on the shoulder buttons.
///
/// Up/Down deliberately does *not* change the tab as it passes. Every other
/// scope in the app moves a highlight and acts on A, and committing on the way
/// past would rebuild the detail column once per press - and would open the
/// add-game sheet merely for crossing the Add entry. Moving away without
/// pressing A abandons the highlight, because entering the sidebar resets it
/// to whatever tab is actually showing.
@MainActor
final class SidebarFocusModel: ObservableObject, ControllerFocusScope {
    @Published var focused: Int?

    /// Entries the sidebar draws, in order. Set by the view so the two cannot
    /// disagree about what index 2 is.
    var entries: [HomeTab] = []
    /// The tab currently showing, used to place the highlight on entry.
    /// Pushed in by the view rather than read back out of it: a closure over
    /// the view's `@State` would be reading it from outside the view graph.
    var currentTab: HomeTab = .games
    /// Commits an entry: selects the tab, or opens the add-game sheet.
    var onSelect: ((HomeTab) -> Void)?

    // MARK: - ControllerFocusScope

    let scopeName = "sidebar"

    let pane: ControllerPane? = .sidebar

    var itemCount: Int { entries.count }

    var focusedIndex: Int? {
        get { focused }
        set { focused = newValue }
    }

    /// Entering the sidebar puts the highlight on the tab that is showing,
    /// rather than wherever it was left. A stale highlight would otherwise
    /// claim the user is on a tab they are not.
    func paneDidBecomeActive() {
        focused = entries.firstIndex(of: currentTab) ?? 0
    }

    /// Unlike a list, the sidebar keeps no ring when focus leaves it: the tab
    /// it would return to is already drawn as selected, so a second ring
    /// beside the list's reads as focus never having left.
    func paneDidResignActive() {
        focused = nil
    }

    func activate() {
        guard let index = focused, index < entries.count else { return }
        onSelect?(entries[index])
    }

    /// The sidebar is the leftmost thing there is; B has nothing to close.
    func close() -> Bool { false }
}
