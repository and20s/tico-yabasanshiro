import Combine
import Foundation

/// View state of the games tab, plus its controller focus scope.
///
/// This lives outside GamesTabView on purpose. On regular width the sidebar
/// rebuilds `destination(for:)` on every tab change, so an L/R lap used to
/// return a brand new GamesTabView with fresh `@State`: search closed, detail
/// pane cleared, scroll at the top. Holding the state in an object that
/// MainTabView owns makes the rebuild invisible to the user, without the
/// hidden-view keep-alive that duplicated the UIKit navigation bar.
@MainActor
final class GamesTabState: ObservableObject, ControllerFocusScope {
    @Published var isSearching = false
    /// Selection of the regular-width detail pane, as an id rather than a
    /// GameItem so it survives the list being reloaded underneath it.
    @Published var selectedGameID: GameItem.ID?
    /// Item shown as a modal sheet at compact width.
    @Published var detailItem: GameItem?

    /// Mirrored from the environment so `close()` can animate the search
    /// field exactly as the toolbar button does.
    var reduceMotion = false

    /// Position in the navigation bar while focus is up there. Published so
    /// the Search and Sort buttons can draw their ring.
    @Published var toolbarFocused: Int?

    /// Search and Sort, declared by the view because only it knows what they
    /// do. Order matches the order they are drawn in.
    var toolbar: [() -> Void] = []

    private weak var list: GameListViewModel?

    /// Connects the state to the list it navigates. Separate from `init` so
    /// MainTabView can declare both as `@StateObject` defaults.
    func configure(list: GameListViewModel) {
        self.list = list
    }

    /// Focus the first card as soon as a controller is present, so there is a
    /// visible sign that the controller works and the first D-pad press moves
    /// the selection instead of being spent on nil -> 0 (spec section 4.1).
    func applyInitialFocus(controllerConnected: Bool) {
        // Focus sitting in the toolbar is a selection the user made; a library
        // reloading underneath must not add a second ring below it.
        guard toolbarFocused == nil else { return }
        guard controllerConnected, focusedIndex == nil, itemCount > 0 else { return }
        focusedIndex = 0
    }

    // MARK: - ControllerFocusScope

    let scopeName = "games"

    /// The list is the tab's content column; the game detail beside it
    /// declares `.detail`, which is what D-pad Right moves between.
    let pane: ControllerPane? = .content

    var itemCount: Int { list?.displayItems.count ?? 0 }

    var focusedIndex: Int? {
        get { list?.focusedIndex }
        set { list?.focusedIndex = newValue }
    }

    var toolbarActions: [() -> Void] { toolbar }

    var toolbarFocusedIndex: Int? {
        get { toolbarFocused }
        set { toolbarFocused = newValue }
    }

    func activate() {
        guard let list = list,
              let index = focusedIndex,
              index < list.displayItems.count else { return }
        let item = list.displayItems[index]
        // A locked game opens the pro gate instead of its detail. The ring
        // still moves over it (behaviour table section 2): skipping the card
        // would leave a row that looks playable and answers nothing.
        guard list.select(item) else { return }
        list.pendingDetailItem = item
    }

    /// Right shows the focused game in the pane, which is the same thing A
    /// does at this width - the difference is only that the coordinator then
    /// moves focus there. Nothing to show means no move (spec section 4.3).
    func openInDetailPane() -> Bool {
        guard let list = list, let index = focusedIndex,
              index < list.displayItems.count else { return false }
        let item = list.displayItems[index]
        // false keeps focus in the list: the gate is a sheet over this column,
        // and moving to a pane that never changed would strand the ring there.
        guard list.select(item) else { return false }
        list.pendingDetailItem = item
        return true
    }

    /// B closes the search field when it is open. The games list is the root
    /// scope, so with no search open there is nothing left to close.
    func close() -> Bool {
        guard isSearching else { return false }
        list?.searchText = ""
        isSearching = false
        return true
    }
}
