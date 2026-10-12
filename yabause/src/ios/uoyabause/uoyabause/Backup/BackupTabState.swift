import Combine
import Foundation

/// View state of the backup tab, plus its controller focus scope.
///
/// One scope for both halves of the tab rather than one each. The Local and
/// Cloud lists never coexist, and the search field they share belongs to the
/// tab: giving the cloud section its own scope would have put it on top of
/// this one, where B would have had to reach past it to close that shared
/// field. Whichever list is showing is the one this scope counts.
@MainActor
final class BackupTabState: ObservableObject, ControllerFocusScope {
    @Published var section: BackupTabView.Section = .local
    @Published var isSearching = false
    /// True while the community browse screen is pushed.
    @Published var showCommunity = false
    /// Local save shown as a modal sheet at compact width.
    @Published var detailSave: BackupSave?
    /// Selection of the regular-width local detail pane, as an id rather than
    /// a BackupSave so it survives the list being reloaded underneath it.
    @Published var selectedSaveID: BackupSave.ID?
    /// The same pair for the cloud half, held here so the tab has one scope.
    @Published var cloudDetailItem: CloudBackupItem?
    @Published var cloudSelectedItemID: CloudBackupItem.ID?

    @Published var focused: Int?
    /// Position in the navigation bar while focus is up there. Published so
    /// the Community, Search and Sort buttons can draw their ring.
    @Published var toolbarFocused: Int?

    /// Community, Search and Sort, declared by the view because only it knows
    /// what they do. Order matches the order they are drawn in.
    var toolbar: [() -> Void] = []

    /// Mirrored from the environment so `close()` can animate the search
    /// field exactly as the toolbar button does.
    var reduceMotion = false

    /// Set by the view, which is the only thing that knows whether this width
    /// opens a save as a sheet or selects it in a pane.
    var onOpen: ((Int) -> Void)?
    /// Set by the view: clears both sections' filters.
    var onClearSearch: (() -> Void)?
    /// Set by the view: true while an error alert is up. A UIAlertController
    /// draws its own selection, which the app cannot move, so A must not open
    /// a save behind it and B must dismiss the alert first.
    var isBlocked: () -> Bool = { false }
    /// Set by the view: dismisses that alert.
    var onDismissAlert: (() -> Void)?

    private weak var local: BackupListViewModel?
    private weak var cloud: CloudBackupViewModel?

    /// Connects the state to the lists it navigates. Separate from `init` so
    /// the view can declare all three as `@StateObject` defaults.
    func configure(local: BackupListViewModel, cloud: CloudBackupViewModel) {
        self.local = local
        self.cloud = cloud
    }

    // MARK: - Backup source

    /// Every store the user can switch to, local memories first. Built from
    /// the files that actually exist, so a device with no cartridge shows
    /// just the internal memory and the cloud.
    ///
    /// availableFiles is empty until the list has loaded, and an empty local
    /// half would drop the internal memory out of the list while it is still
    /// the selected source -- so it falls back to it rather than to nothing.
    var sources: [BackupSource] {
        let files = local?.availableFiles ?? []
        let locals = files.isEmpty ? [BackupFile.internalMemory] : files
        return locals.map(BackupSource.local) + [.cloud]
    }

    var currentSource: BackupSource {
        section == .cloud ? .cloud : .local(local?.selectedFile ?? .internalMemory)
    }

    /// Writes a source back to the two properties that really hold it.
    func select(_ source: BackupSource) {
        switch source {
        case .local(let file):
            local?.selectedFile = file
            if section != .local { section = .local }
        case .cloud:
            if section != .cloud { section = .cloud }
        }
    }

    /// A on the source row steps to the next store. Cycling rather than
    /// opening a menu keeps D-pad Left/Right meaning "change column"
    /// everywhere, instead of meaning something else on this one screen.
    func cycleSource() {
        let all = sources
        guard !all.isEmpty else { return }
        let index = all.firstIndex(of: currentSource) ?? 0
        select(all[(index + 1) % all.count])
    }

    // MARK: - Row indices

    /// The source row sits above the saves, so it is row 0 and the list is
    /// offset by one. Kept in one place so the scope and the view cannot
    /// disagree about what a focus index means.
    static let sourceRow = 0

    /// The save at a focus index, or nil when the index is the source row.
    func saveIndex(for focusIndex: Int) -> Int? {
        focusIndex == Self.sourceRow ? nil : focusIndex - 1
    }

    /// Focus the first row as soon as a controller is present (spec 4.1).
    func applyInitialFocus(controllerConnected: Bool) {
        // Focus sitting in the toolbar is a selection the user made; a list
        // reloading underneath must not add a second ring below it.
        guard toolbarFocused == nil else { return }
        guard controllerConnected, focused == nil, itemCount > 0 else { return }
        focused = 0
    }

    /// A section switch shows a different list of a different length, so the
    /// selection cannot carry over.
    func resetFocus(controllerConnected: Bool) {
        focused = nil
        applyInitialFocus(controllerConnected: controllerConnected)
    }

    // MARK: - ControllerFocusScope

    let scopeName = "backup"

    /// The tab's content column. Both halves put their detail in the same
    /// pane beside it, so D-pad Right works in Local and in Cloud alike.
    let pane: ControllerPane? = .content

    /// Only a loaded cloud list has rows; its sign-in, upgrade and failure
    /// states are a single prompt that the controller does not reach.
    private var saveCount: Int {
        switch section {
        case .local:
            return local?.displaySaves.count ?? 0
        case .cloud:
            guard cloud?.state == .loaded else { return 0 }
            return cloud?.displayItems.count ?? 0
        }
    }

    /// The source row plus the saves. The source row is always present, so a
    /// section with nothing in it can still be switched away from -- an empty
    /// cloud list used to be a dead end for a controller.
    var itemCount: Int { 1 + saveCount }

    var focusedIndex: Int? {
        get { focused }
        set { focused = newValue }
    }

    var toolbarActions: [() -> Void] { toolbar }

    var toolbarFocusedIndex: Int? {
        get { toolbarFocused }
        set { toolbarFocused = newValue }
    }

    /// Same rule as `activate`: an error alert draws its own selection, so a
    /// toolbar button must not be pressed from behind it.
    func activateFocusedToolbarAction() -> Bool {
        guard let index = toolbarFocused, index < toolbar.count else { return false }
        guard !isBlocked() else { return true }
        toolbar[index]()
        return true
    }

    func activate() {
        guard !isBlocked(), let index = focused, index < itemCount else { return }
        guard let save = saveIndex(for: index) else {
            cycleSource()
            return
        }
        onOpen?(save)
    }

    /// Right shows the focused save in the pane. Same call as A, which at
    /// this width selects rather than presents; the coordinator then moves
    /// focus across. An empty list, or a cloud section showing a sign-in
    /// prompt instead of rows, has nothing to show and answers false.
    func openInDetailPane() -> Bool {
        guard !isBlocked(), let index = focused, index < itemCount else { return false }
        // The source row has nothing to show in the pane, so Right stays put
        // rather than moving focus to an empty column.
        guard let save = saveIndex(for: index) else { return false }
        onOpen?(save)
        return true
    }

    /// B closes the search field when it is open. The backup list is a tab
    /// root, so with no search open there is nothing left to close.
    ///
    /// This used to be an `onReceive` on the raw event stream, which is why B
    /// while a game's detail sheet was open also cleared this tab's search:
    /// a TabView keeps every visited tab alive, so the subscription kept
    /// firing from behind whatever was on screen. Declaring a scope is the fix
    /// as well as the tidy-up - only the top of the stack is asked.
    func close() -> Bool {
        if isBlocked() {
            onDismissAlert?()
            return true
        }
        guard isSearching else { return false }
        onClearSearch?()
        isSearching = false
        return true
    }
}
