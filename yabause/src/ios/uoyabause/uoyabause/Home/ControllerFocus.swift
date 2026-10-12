import Combine
import Foundation

/// One column of the regular-width layout.
///
/// The three panes are peers on screen, so a scope declaring one of these is
/// saying "I sit beside the others", not "I cover them". Scopes that leave
/// this nil - a sheet, a pushed sub-screen, a blocker - do cover what is under
/// them and keep the plain top-of-stack rule.
enum ControllerPane: String {
    /// The NavigationSplitView sidebar: the five tab entries.
    case sidebar
    /// The tab's own content, which at compact width is the whole screen.
    case content
    /// The detail column of a two-pane tab (Games, Backup).
    case detail
}

/// A screen's controller-navigable items.
///
/// iOS has no system focus engine for game controllers at any version
/// (`.focusable()` is iOS 17+ and keyboard-driven; `.focusSection()` and
/// `.onMoveCommand` are tvOS only), so the app has to own selection itself.
/// Screens adopt this protocol to *declare* what can be focused. They never
/// install GCController handlers: `HomeGamePadManager` is the only owner of
/// those in the home UI (ios/CLAUDE.md CRITICAL), and
/// `ControllerFocusCoordinator` decides which declared scope an event reaches.
@MainActor
protocol ControllerFocusScope: AnyObject {
    /// Identifies the scope in the coordinator's stack description.
    /// Debug and test only; never shown to the user.
    var scopeName: String { get }
    /// A modal scope hides what is under it, so tab cycling is suppressed
    /// while one is on the stack.
    var isModal: Bool { get }
    /// Number of focusable items. Read live rather than cached, so a list
    /// that reloads underneath the scope reports its new size without the
    /// scope having to be re-pushed.
    var itemCount: Int { get }
    /// Currently focused item, nil when the scope has never been entered.
    var focusedIndex: Int? { get set }
    /// A on the focused item.
    func activate()
    /// B. Returns false when there is nothing here to close, which lets the
    /// press fall through to being ignored rather than pretending it worked.
    func close() -> Bool
    /// D-pad Left/Right on the focused row, for a row whose value is a choice
    /// laid out horizontally (the star rating). Returns false when the row has
    /// no such value, which lets the press mean "change column" as usual.
    func adjustFocused(by delta: Int) -> Bool
    /// Which column of the regular-width layout this scope occupies, nil for
    /// anything that covers a column rather than sitting in one.
    var pane: ControllerPane? { get }
    /// D-pad Right from the content column: show the focused row in the detail
    /// pane. Returns false when there is nothing to show, so focus stays where
    /// it is instead of moving to a pane with no ring in it.
    func openInDetailPane() -> Bool
    /// Called when lateral movement makes this scope's pane the live one.
    func paneDidBecomeActive()
    /// Called when lateral movement makes some other pane the live one.
    ///
    /// A pane normally keeps a dimmed ring so the user can see where Left or
    /// Right would take them back to. The sidebar does not need one -- the
    /// tab it would return to is already marked as selected -- so it clears
    /// its focus here rather than leaving a second ring on screen.
    func paneDidResignActive()
    /// The navigation bar's buttons, in the order they are drawn from leading
    /// to trailing. A screen declares them and gets the whole interaction -
    /// Up enters, Left/Right walks, Down leaves, A runs - without writing any
    /// of it, because the last two controller gaps were each forgotten on five
    /// screens by being wired per screen.
    ///
    /// Empty by default, which is the pre-toolbar behavior exactly: Up at the
    /// first row does nothing.
    var toolbarActions: [() -> Void] { get }
    /// Position in `toolbarActions` while focus sits in the toolbar, nil while
    /// focus is in the list. Kept apart from `focusedIndex` so at most one of
    /// the two ever draws a ring.
    var toolbarFocusedIndex: Int? { get set }
    /// A while focus is in the toolbar. A protocol member rather than a plain
    /// helper because a scope that can be covered by a dialog has to answer A
    /// with the dialog instead, exactly as `activate` does for its rows.
    func activateFocusedToolbarAction() -> Bool
}

extension ControllerFocusScope {
    var isModal: Bool { false }
    var pane: ControllerPane? { nil }

    var toolbarActions: [() -> Void] { [] }

    var toolbarFocusedIndex: Int? {
        get { nil }
        set { _ = newValue }
    }

    func openInDetailPane() -> Bool { false }

    /// Most rows have no horizontal value, so Left/Right keeps meaning the
    /// column change it means everywhere else.
    func adjustFocused(by delta: Int) -> Bool { false }

    /// Most panes keep their ring when focus leaves, dimmed, so the user can
    /// see what Left or Right would bring them back to.
    func paneDidResignActive() {}

    /// Entering a pane must always leave a visible ring, so a pane that has
    /// never been entered lands on its first item.
    func paneDidBecomeActive() {
        // Focus already in this scope's toolbar has a ring of its own; adding
        // a row selection beside it would draw two.
        guard toolbarFocusedIndex == nil else { return }
        guard focusedIndex == nil, itemCount > 0 else { return }
        focusedIndex = 0
    }

    /// Moves the selection by `delta`, clamped at both ends: the list does
    /// not wrap (spec section 2). The first move in a scope that has never
    /// been entered lands on the first item.
    ///
    /// Up at the first row continues into the navigation bar when the scope
    /// declares buttons, and Down brings focus back to the first row. That is
    /// the only way in and out, so a scope with no buttons behaves as it did
    /// before this existed.
    func move(by delta: Int) {
        if toolbarFocusedIndex != nil {
            // Nothing sits above the toolbar, so Up stays. Down returns to the
            // list - unless there is no list, in which case staying keeps a
            // ring on screen instead of losing focus entirely.
            guard delta > 0, itemCount > 0 else { return }
            toolbarFocusedIndex = nil
            focusedIndex = 0
            return
        }
        if delta < 0, !toolbarActions.isEmpty, focusedIndex == 0 || itemCount == 0 {
            toolbarFocusedIndex = 0
            // The row ring is dropped rather than kept, so the user sees one
            // selection at a time.
            focusedIndex = nil
            return
        }
        guard itemCount > 0 else { return }
        guard let current = focusedIndex else {
            focusedIndex = 0
            return
        }
        focusedIndex = min(max(current + delta, 0), itemCount - 1)
    }

    /// D-pad Left/Right while focus is in the toolbar. Returns false when it
    /// is not, which is what lets the same press mean "change column".
    func moveInToolbar(by delta: Int) -> Bool {
        guard let index = toolbarFocusedIndex else { return false }
        let count = toolbarActions.count
        guard count > 0 else { return true }
        // Clamped like the list: the leftmost button is the end of the row,
        // not a wrap round to the rightmost.
        toolbarFocusedIndex = min(max(index + delta, 0), count - 1)
        return true
    }

    /// A while focus is in the toolbar. Returns false when it is not, so the
    /// press goes to the focused row instead.
    func activateFocusedToolbarAction() -> Bool {
        guard let index = toolbarFocusedIndex, index < toolbarActions.count else {
            return false
        }
        toolbarActions[index]()
        return true
    }
}

/// The stack of focus scopes. Only the topmost one receives input.
///
/// This single rule removes three defects at once: the list behind an open
/// sheet can no longer be moved (or have its content swapped) by the D-pad,
/// B always has something to close while a scope is presented, and L/R
/// cannot change tabs from under a modal.
///
/// The regular-width layout adds one qualification, because its three columns
/// are peers rather than a stack: among scopes that declare a column, the live
/// column decides, and D-pad Left/Right changes which column that is. A scope
/// with no column still covers what is under it, so the rule above is
/// unchanged for every sheet and sub-screen, and at compact width - where
/// there are no columns to move between - nothing here applies at all.
@MainActor
final class ControllerFocusCoordinator: ObservableObject {
    /// Scope names, bottom of the stack first. Published so tests and debug
    /// overlays can observe the stack itself; screens observe their own scope.
    @Published private(set) var stackNames: [String] = []

    /// Which column of the regular-width layout is live.
    ///
    /// This lives here rather than in MainTabView because it is the same
    /// question the stack already answers - who receives input - asked along
    /// the other axis. Putting it in the root view would mean the root had to
    /// know each tab's scopes to route Up/Down to the right one, which is the
    /// central registry Phase 1 deliberately avoided. Scopes stay ignorant of
    /// each other: each declares which pane it is in, and this resolves it.
    ///
    /// Compact width has no sidebar scope, so it never leaves `.content`.
    @Published private(set) var activePane: ControllerPane = .content

    private var stack: [ControllerFocusScope] = []
    /// Set by the first event of any kind. Auto-focusing a pane that appears
    /// later is only correct once a controller has actually been used; before
    /// that a touch user would be shown a selection they never made
    /// (spec section 4.1).
    private var hasHandledInput = false
    /// Set by the press that is expected to produce a detail pane - A on a
    /// row, or Right - and consumed by the next scope that is pushed.
    ///
    /// Two things need it. A detail pane is built a runloop after the press,
    /// and SwiftUI may tear the previous one down either side of that, so
    /// without it a Right onto a different game could land back in the list.
    /// And a pane that appears for any other reason - returning to a tab whose
    /// selection was kept - must *not* take focus, or an L/R lap around the
    /// tabs would drop the user in the detail column every time.
    private var expectsDetailPane = false

    /// The scope that receives input.
    ///
    /// A scope with no pane role covers its column, so it wins outright, which
    /// is the whole of the Phase 1 rule. Pane scopes are peers instead, and
    /// the active pane picks between them.
    var top: ControllerFocusScope? {
        guard let last = stack.last else { return nil }
        guard last.pane != nil else { return last }
        return scope(in: activePane)
            ?? scope(in: .content) ?? scope(in: .sidebar) ?? last
    }

    var depth: Int { stack.count }

    /// L/R only moves between tabs when nothing modal is presented.
    var allowsTabChange: Bool { !stack.contains { $0.isModal } }

    /// True while the panes exist to move between. The sidebar scope is
    /// declared by the regular-width layout only, so its presence is the
    /// layout's own answer rather than a second size-class check.
    var isTwoPaneLayout: Bool { scope(in: .sidebar) != nil }

    func push(_ scope: ControllerFocusScope) {
        guard !stack.contains(where: { $0 === scope }) else { return }
        stack.append(scope)
        if expectsDetailPane, scope.pane == .detail {
            // The pane the last press asked for. Whichever way round SwiftUI
            // ordered this against the outgoing pane's removal, focus ends up
            // in it.
            expectsDetailPane = false
            activePane = .detail
            scope.paneDidBecomeActive()
        } else {
            // Anything else settles the question: a pane that arrives later
            // was not asked for.
            expectsDetailPane = false
            if hasHandledInput, let pane = scope.pane, pane == activePane {
                scope.paneDidBecomeActive()
            }
        }
        publish()
    }

    /// Removes one scope from wherever it sits. SwiftUI may run a
    /// replacement view's `onAppear` before the replaced view's
    /// `onDisappear`, so popping must not assume the scope is on top.
    func pop(_ scope: ControllerFocusScope) {
        guard let index = stack.firstIndex(where: { $0 === scope }) else { return }
        stack.remove(at: index)
        // Losing the live pane - B on a detail, a tab change, a rotation out
        // of the two-pane layout - would otherwise leave input aimed at a
        // column that is no longer on screen, with no ring anywhere.
        if let pane = scope.pane, pane == activePane, self.scope(in: pane) == nil {
            activePane = .content
            if hasHandledInput { self.scope(in: .content)?.paneDidBecomeActive() }
        }
        publish()
    }

    private func scope(in pane: ControllerPane) -> ControllerFocusScope? {
        stack.last { $0.pane == pane }
    }

    /// Routes one event to the topmost scope. Returns whether it was
    /// consumed. Tab events are not handled here: they belong to the root
    /// view, which asks `allowsTabChange` first.
    @discardableResult
    func handle(_ event: HomeGamePadManager.Event) -> Bool {
        hasHandledInput = true
        guard let scope = top else { return false }
        switch event {
        case .up:
            scope.move(by: -1)
            return true
        case .down:
            scope.move(by: 1)
            return true
        case .select:
            // A toolbar button is what A means while focus is up there; the
            // row underneath keeps its own meaning for when focus comes back.
            if scope.activateFocusedToolbarAction() { return true }
            // A on a list row opens the detail, and at this width the detail
            // is the pane beside it. Focus follows what it opened, which is
            // what A did before there was anywhere else for focus to be.
            expectsDetailPane = isTwoPaneLayout && scope.pane == .content
            scope.activate()
            return true
        case .back:
            expectsDetailPane = false
            return scope.close()
        case .left:
            // Left/Right normally changes column (spec section 4.3), but a
            // toolbar is a row of buttons and moving along it is the only
            // thing those directions can usefully mean while focus is in it.
            // The toolbar spans the whole tab rather than belonging to one
            // column, so treating this as a column change would carry focus
            // out of a bar that is still drawn above the column it landed in.
            // The way out is Down, which is where the user came in from.
            if scope.moveInToolbar(by: -1) { return true }
            // A row that holds a horizontal value takes the press before the
            // column change does; it is the only thing on screen the user
            // could mean while its ring is showing.
            if scope.adjustFocused(by: -1) { return true }
            return movePane(from: scope, towards: .leading)
        case .right:
            if scope.moveInToolbar(by: 1) { return true }
            if scope.adjustFocused(by: 1) { return true }
            return movePane(from: scope, towards: .trailing)
        case .nextTab, .prevTab:
            return false
        }
    }

    private enum LateralDirection { case leading, trailing }

    /// D-pad Left/Right between the columns (spec section 4.3).
    ///
    /// Sidebar <- content <-> detail, stopping at both outer edges rather than
    /// wrapping, exactly as Up/Down stops at the ends of a list. Nothing here
    /// fires at compact width or under a sheet: neither has panes.
    private func movePane(from scope: ControllerFocusScope,
                          towards direction: LateralDirection) -> Bool {
        guard isTwoPaneLayout, let pane = scope.pane else { return false }
        switch (pane, direction) {
        case (.sidebar, .trailing), (.detail, .leading):
            // Mid tab change the content column can be momentarily absent.
            // Moving to a column with nothing in it would put input somewhere
            // with no ring, so the press is refused instead.
            guard self.scope(in: .content) != nil else { return false }
            return activate(pane: .content)
        case (.content, .leading):
            return activate(pane: .sidebar)
        case (.content, .trailing):
            // Show the focused row before moving, so the pane the user lands
            // in is the one they were pointing at. A screen with no detail
            // column (Settings, Account) answers false and focus stays put.
            let opened = scope.openInDetailPane()
            guard opened || self.scope(in: .detail) != nil else { return false }
            return activate(pane: .detail)
        default:
            // The sidebar is the leftmost column and the detail the rightmost.
            return false
        }
    }

    private func activate(pane: ControllerPane) -> Bool {
        let previous = activePane
        expectsDetailPane = pane == .detail
        activePane = pane
        if previous != pane {
            scope(in: previous)?.paneDidResignActive()
        }
        // Nil when a detail pane is still being built; `push` greets it then.
        scope(in: pane)?.paneDidBecomeActive()
        publish()
        return true
    }

    private func publish() {
        stackNames = stack.map { $0.scopeName }
    }
}
