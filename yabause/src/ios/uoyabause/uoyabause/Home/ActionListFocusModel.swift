import Combine
import Foundation

/// A focus scope whose items are a plain vertical run of actions.
///
/// GamesTabState and GameDetailFocusModel each write their own scope because
/// each has real state to hold. Most other screens do not: they are a stack of
/// buttons whose order and count follow whatever the view is currently
/// showing. Those declare their rows here instead of repeating the same
/// clamping, blocking and closing logic five times.
///
/// The view owns the declaration and refreshes it whenever its content
/// changes, which is why the actions are set rather than passed to `init`:
/// a card that appears once a subscription is confirmed has to become
/// reachable without the scope being re-pushed.
@MainActor
final class ActionListFocusModel: ObservableObject, ControllerFocusScope {
    @Published var focused: Int?
    /// Published separately from `actions` so the view can size its rings
    /// without holding the closures.
    @Published private(set) var count = 0

    let scopeName: String
    /// Settable, because a view that appears both as a sheet and as an iPad
    /// pane only learns which it is from its own properties, and a
    /// `@StateObject` default cannot read those. The coordinator asks for it
    /// when an event arrives rather than when the scope is pushed, so setting
    /// it from `onAppear` is in time.
    var isModal: Bool
    /// Which column of the regular-width layout this list draws in. Settable
    /// for the same reason `isModal` is: a view only learns whether it is a
    /// sheet or a pane from its own properties.
    var pane: ControllerPane?

    /// True while something the app cannot move draws its own selection - a
    /// UIAlertController, a confirmationDialog, a system document picker. A
    /// must not act on the row behind it.
    var isBlocked: () -> Bool = { false }

    /// B. Returns false when there is nothing here to close, which lets the
    /// press be ignored rather than pretending it worked.
    var onClose: () -> Bool = { false }

    /// A while `isBlocked` is true.
    ///
    /// A confirmationDialog and a UIAlertController draw their own selection,
    /// which the app cannot move -- so blocking A stops it acting on the row
    /// behind them, but it also leaves the dialog with no way to say yes.
    /// A screen that puts one up supplies its confirming action here, giving
    /// the pair the button map already promises: A confirms, B cancels.
    ///
    /// Returns false when there is nothing to confirm, so A is ignored rather
    /// than doing something the user cannot see.
    var onConfirm: () -> Bool = { false }

    /// Position in the navigation bar while focus is up there. Published so
    /// the toolbar buttons can draw their ring.
    @Published var toolbarFocused: Int?

    private var actions: [() -> Void] = []
    private var toolbar: [() -> Void] = []

    /// Left/Right on a row that holds a horizontal value. Given the focused
    /// row and -1 or 1; answers whether it took the press. Unset means no row
    /// here has such a value, which is every screen but the shared detail.
    var onAdjust: ((Int, Int) -> Bool)?

    func adjustFocused(by delta: Int) -> Bool {
        guard let onAdjust, toolbarFocused == nil, let index = focused else {
            return false
        }
        return onAdjust(index, delta)
    }

    init(scopeName: String, isModal: Bool = false, pane: ControllerPane? = nil) {
        self.scopeName = scopeName
        self.isModal = isModal
        self.pane = pane
    }

    /// Declares the rows, in the order they are drawn. Keeps the selection
    /// inside the new range: a row can disappear (an upload button while the
    /// upload runs) while it is the focused one.
    func setActions(_ actions: [() -> Void]) {
        self.actions = actions
        count = actions.count
        guard let index = focused else { return }
        if actions.isEmpty {
            focused = nil
        } else if index >= actions.count {
            focused = actions.count - 1
        }
    }

    /// Declares the navigation bar's buttons, in the order they are drawn.
    /// Keeps the selection inside the new range, as `setActions` does.
    func setToolbarActions(_ actions: [() -> Void]) {
        toolbar = actions
        guard let index = toolbarFocused else { return }
        if actions.isEmpty {
            toolbarFocused = nil
        } else if index >= actions.count {
            toolbarFocused = actions.count - 1
        }
    }

    /// Focus the first row as soon as a controller is present, so there is a
    /// visible sign that the controller works and the first D-pad press moves
    /// the selection instead of being spent on nil -> 0 (spec section 4.1).
    func applyInitialFocus(controllerConnected: Bool) {
        // Focus sitting in the toolbar is a selection the user made; a list
        // that reloads underneath must not add a second ring below it.
        guard toolbarFocused == nil else { return }
        guard controllerConnected, focused == nil, count > 0 else { return }
        focused = 0
    }

    // MARK: - ControllerFocusScope

    var itemCount: Int { count }

    var focusedIndex: Int? {
        get { focused }
        set { focused = newValue }
    }

    var toolbarActions: [() -> Void] { toolbar }

    var toolbarFocusedIndex: Int? {
        get { toolbarFocused }
        set { toolbarFocused = newValue }
    }

    func activate() {
        // A dialog owns the screen: A means "yes" to it, not to the row it
        // is covering.
        if isBlocked() {
            _ = onConfirm()
            return
        }
        guard let index = focused, index < actions.count else { return }
        actions[index]()
    }

    /// Same rule as `activate`: a dialog covering the screen takes A, so a
    /// toolbar button cannot be pressed from behind one.
    func activateFocusedToolbarAction() -> Bool {
        guard let index = toolbarFocused, index < toolbar.count else { return false }
        if isBlocked() {
            _ = onConfirm()
            return true
        }
        toolbar[index]()
        return true
    }

    func close() -> Bool { onClose() }
}

/// A scope with nothing in it, for a presentation the controller cannot drive
/// - a purchase flow, an out-of-process OAuth screen.
///
/// It exists so those are not transparent. Without it the screen underneath
/// stays the top of the stack and keeps answering A, the D-pad and L/R from
/// behind something the user cannot see past. B still closes, because B is
/// never a no-op (spec section 2).
@MainActor
final class ModalBlockerScope: ObservableObject, ControllerFocusScope {
    var scopeName = "modalBlocker"
    let isModal = true
    let itemCount = 0

    var focusedIndex: Int? {
        get { nil }
        set { _ = newValue }
    }

    /// Set by the view: dismisses whatever this scope is standing in for.
    var onClose: (() -> Void)?

    func activate() {}

    func close() -> Bool {
        guard let onClose = onClose else { return false }
        onClose()
        return true
    }
}
