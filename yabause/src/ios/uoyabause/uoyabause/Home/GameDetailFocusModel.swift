import Combine
import Foundation

/// Controller focus scope of the game detail view, in both its sheet and its
/// pane presentation, plus the two dialog flags it drives.
///
/// The rows are a fixed, heterogeneous stack rather than a list, so the order
/// is written out here instead of derived from data. Play is preselected: with
/// the card list focusing index 0 at launch, that makes "launch the third
/// game" Down, Down, A, A.
@MainActor
final class GameDetailFocusModel: ObservableObject, ControllerFocusScope {
    enum Row: Int, CaseIterable {
        case play
        /// The "..." button. Its menu has one entry, File Info, so A on the
        /// button performs it directly: a system menu's highlighted item is
        /// not something the app can move.
        case fileInfo
        case remove
    }

    @Published var focused: Int? = Row.play.rawValue
    @Published var showFileInfo = false
    @Published var showDeleteConfirm = false

    /// A sheet covers the library; a pane sits beside it, so only the sheet
    /// suppresses L/R tab cycling.
    let isModal: Bool

    /// Set by the view. `onPlay` starts the game, `onDismiss` closes the
    /// sheet or clears the pane selection.
    var onPlay: (() -> Void)?
    var onDismiss: (() -> Void)?
    /// Confirms the delete dialog. A dialog draws its own selection, which
    /// the app cannot move, so without this the dialog could be opened with a
    /// controller but never answered.
    var onConfirmDelete: (() -> Void)?

    init(isModal: Bool) {
        self.isModal = isModal
    }

    // MARK: - ControllerFocusScope

    var scopeName: String { isModal ? "gameDetailSheet" : "gameDetailPane" }

    /// A pane is a column beside the list, so D-pad Left/Right moves between
    /// the two. A sheet covers the list instead and keeps the plain
    /// top-of-stack rule, which is why it declares no pane.
    var pane: ControllerPane? { isModal ? nil : .detail }

    var itemCount: Int { Row.allCases.count }

    var focusedIndex: Int? {
        get { focused }
        set { focused = newValue }
    }

    func activate() {
        // A dialog owns the screen: A answers it rather than reaching the row
        // it covers. File Info only has an OK, so A dismisses it.
        if showFileInfo {
            showFileInfo = false
            return
        }
        if showDeleteConfirm {
            showDeleteConfirm = false
            onConfirmDelete?()
            return
        }
        switch Row(rawValue: focused ?? Row.play.rawValue) {
        case .play:
            onPlay?()
        case .fileInfo:
            showFileInfo = true
        case .remove:
            showDeleteConfirm = true
        case nil:
            break
        }
    }

    /// B unwinds one step: an open dialog first, then the detail view itself.
    func close() -> Bool {
        if showFileInfo {
            showFileInfo = false
            return true
        }
        if showDeleteConfirm {
            showDeleteConfirm = false
            return true
        }
        onDismiss?()
        return true
    }
}
