import Combine
import SwiftUI

/// The backup tab. SP3a covers local backup RAM, SP3b adds the cloud section;
/// the shared section arrives in SP3c.
struct BackupTabView: View {
    /// Which half of the backup tab is showing. SP3c adds a shared section.
    enum Section: String, CaseIterable, Identifiable {
        case local
        case cloud
        var id: String { rawValue }
        var title: String {
            switch self {
            case .local: return String(localized: "Local", comment: "Backup section")
            case .cloud: return String(localized: "Cloud", comment: "Backup section")
            }
        }
    }

    /// Where this screen declares its focus scope. Optional so previews and
    /// tests can build the view without one.
    var focus: ControllerFocusCoordinator?

    /// Owned by MainTabView, not by this view.
    ///
    /// At regular width the sidebar rebuilds the detail column on every tab
    /// change, so anything this view held itself would be thrown away and
    /// rebuilt each time -- the list would re-read the backup memory, and the
    /// section, search text and selection would reset. Holding it a level up
    /// is what Games already does.
    @ObservedObject var viewModel: BackupListViewModel
    @ObservedObject var cloudViewModel: CloudBackupViewModel
    /// Section, search, both halves' detail selection and the controller
    /// focus, in one object so the tab has exactly one scope.
    @ObservedObject var state: BackupTabState
    @ObservedObject var sharedViewModel: SharedBackupBrowseViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.isControllerConnected) private var isControllerConnected

    private var section: Section { state.section }
    private var isSearching: Bool { state.isSearching }

    /// Two panes wherever there is width for them. Android branches on
    /// orientation instead, which leaves tablet portrait on the phone layout
    /// and misreads split-screen; the size class is the width-aware version of
    /// the same decision, so iPad portrait and Split View get the pane too.
    private var isTwoPane: Bool { horizontalSizeClass == .regular }

    private var selectedSave: BackupSave? {
        state.selectedSaveID.flatMap { id in
            viewModel.displaySaves.first { $0.id == id }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                sectionPicker
                if isSearching {
                    SearchField(text: searchBinding,
                                prompt: String(localized: "Search",
                                               comment: "Search saves"),
                                onDismiss: {
                                    withAnimation(SearchField.animation(
                                        reduceMotion: reduceMotion)) {
                                        state.isSearching = false
                                    }
                                })
                        .transition(SearchField.transition(reduceMotion: reduceMotion))
                }
                switch section {
                case .local:
                    localSection
                case .cloud:
                    // Reads the size class itself and splits its own list the
                    // same way; Android likewise puts a detail_container in
                    // each list fragment rather than in the host.
                    CloudBackupSection(viewModel: cloudViewModel,
                                       localViewModel: viewModel,
                                       state: state,
                                       focus: focus)
                }
            }
            .navigationTitle(String(localized: "Backup", comment: "Backup tab"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    communityButton
                        .padding(4)
                        .controllerFocusRing(state.toolbarFocused == Toolbar.community,
                                             cornerRadius: 8)
                        .environment(\.isControllerConnected, isControllerConnected)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SearchToolbarButton(isActive: $state.isSearching,
                                        onClose: clearSearch)
                        .padding(4)
                        .controllerFocusRing(state.toolbarFocused == Toolbar.search,
                                             cornerRadius: 8)
                        .environment(\.isControllerConnected, isControllerConnected)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    sortMenu
                        .padding(4)
                        .controllerFocusRing(state.toolbarFocused == Toolbar.sort,
                                             cornerRadius: 8)
                        .environment(\.isControllerConnected, isControllerConnected)
                }
            }
            .navigationDestination(isPresented: $state.showCommunity) {
                SharedBackupBrowseView(viewModel: sharedViewModel,
                                       localViewModel: viewModel,
                                       focus: focus,
                                       onClose: { state.showCommunity = false })
            }
            .background(Color.themeBackground)
        }
        .controllerFocusScope(state, in: focus)
        .onAppear {
            state.configure(local: viewModel, cloud: cloudViewModel)
            state.reduceMotion = reduceMotion
            state.onClearSearch = clearSearch
            state.onOpen = openFocusedRow
            state.isBlocked = { viewModel.errorMessage != nil }
            state.onDismissAlert = { viewModel.clearError() }
            declareToolbarActions()
        }
        .onChange(of: reduceMotion) { state.reduceMotion = $0 }
        .onChange(of: isControllerConnected) {
            state.applyInitialFocus(controllerConnected: $0)
        }
        .onChange(of: viewModel.displaySaves.count) { _ in
            state.applyInitialFocus(controllerConnected: isControllerConnected)
        }
        .onChange(of: cloudViewModel.displayItems.count) { _ in
            state.applyInitialFocus(controllerConnected: isControllerConnected)
        }
        .onChange(of: section) { _ in
            state.resetFocus(controllerConnected: isControllerConnected)
            // The pane belongs to the list it was opened from. Keeping a
            // local save selected while Cloud is showing would bring back a
            // detail for a save that may have been deleted in between, so a
            // section switch resets it for the same reason it resets the
            // search. The cloud section's own selection needs no handling:
            // the section view itself is torn down by this switch.
            state.selectedSaveID = nil
            // Android's hide semantics: leaving the bar open across a
            // section switch would apply one section's query to the other
            // list, so switching closes it and resets both filters.
            guard isSearching else { return }
            withAnimation(SearchField.animation(reduceMotion: reduceMotion)) {
                clearSearch()
                state.isSearching = false
            }
        }
        .task { await viewModel.loadInitial() }
        .sheet(item: $state.detailSave) { save in
            BackupDetailSheet(save: save, viewModel: viewModel,
                              cloudViewModel: cloudViewModel,
                              focus: focus)
                .presentationDetents([.medium, .large])
                // A sheet is presented outside this view's hierarchy on some
                // iOS versions, so the connected flag is handed over rather
                // than assumed to be inherited.
                .environment(\.isControllerConnected, isControllerConnected)
        }
        .alert(String(localized: "Error", comment: "Error alert title"),
               isPresented: Binding(get: { viewModel.errorMessage != nil },
                                    set: { if !$0 { viewModel.clearError() } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    /// One control for "which store am I looking at": the local memories and
    /// the cloud, which used to be a segmented picker plus a separate file
    /// menu. Grouped so the two kinds stay distinguishable inside the menu.
    private var sectionPicker: some View {
        Menu {
            Picker(String(localized: "Backup Memory", comment: "Backup source picker"),
                   selection: sourceBinding) {
                ForEach(state.sources) { source in
                    Text(source.displayName).tag(source)
                }
            }
        } label: {
            HStack {
                Label(state.currentSource.displayName,
                      systemImage: state.currentSource.isCloud
                          ? "icloud" : "internaldrive")
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.footnote)
                    .foregroundStyle(Color.themeOnSurfaceVariant)
                    // Decorative: keep it out of the control's label.
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(Color.themeOnSurface)
        // Named so a test can open it without knowing which store is showing.
        .accessibilityIdentifier(Self.sourcePickerIdentifier)
        .padding(12)
        .controllerFocusRing(state.focused == BackupTabState.sourceRow,
                             cornerRadius: 10,
                             base: Color.themeSurfaceContainerHigh)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var sourceBinding: Binding<BackupSource> {
        Binding(get: { state.currentSource },
                set: { state.select($0) })
    }

    /// The local backup RAM half. Compact width shows the list alone and
    /// opens a save as a modal sheet; regular width puts the detail in a
    /// persistent pane beside it, the way Android's landscape
    /// fragment_backup_list adds a detail_container next to its list column.
    @ViewBuilder
    private var localSection: some View {
        if isTwoPane {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    localListColumn
                        .frame(width: DetailPane.listWidth(for: geometry.size.width))
                        .controllerPaneIdentity(.content)
                    // Android's 1dp MaterialDivider between the two panes.
                    Divider()
                        .overlay(Color.themeOutlineVariant)
                    localDetailPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            localListColumn
        }
    }

    /// Storage bar and the save list: everything the compact layout shows,
    /// which in the two-pane layout becomes the left column. Choosing the
    /// memory moved into the source control above, next to the cloud.
    private var localListColumn: some View {
        VStack(spacing: 0) {
            if let status = viewModel.status {
                BackupStorageBar(status: status)
            }
            content
        }
    }

    private var localDetailPane: some View {
        Group {
            if let save = selectedSave {
                // Same view as the sheet, told which context it is in. Rebuilt
                // per save so its in-progress state does not carry over.
                BackupDetailSheet(save: save,
                                  viewModel: viewModel,
                                  cloudViewModel: cloudViewModel,
                                  presentation: .pane,
                                  onClose: { state.selectedSaveID = nil },
                                  focus: focus)
                    .id(save.id)
            } else {
                DetailPanePlaceholderView(
                    systemImage: "externaldrive",
                    text: String(localized: "Select a save",
                                 comment: "Backup detail pane placeholder"))
            }
        }
        // Android gives detail_container colorSurfaceContainerLow so the pane
        // reads as a surface laid over the list background.
        .background(Color.themeSurfaceContainerLow)
        // Rings in here dim while the list is the live column.
        .controllerPaneIdentity(.detail)
    }

    /// Opens a save the way the current layout shows detail.
    private func show(_ save: BackupSave) {
        if isTwoPane {
            state.selectedSaveID = save.id
        } else {
            state.detailSave = save
        }
    }

    /// A on the focused row. The scope knows which list is showing but not how
    /// this width presents a detail, so it asks the view.
    private func openFocusedRow(_ index: Int) {
        switch section {
        case .local:
            guard index < viewModel.displaySaves.count else { return }
            show(viewModel.displaySaves[index])
        case .cloud:
            guard index < cloudViewModel.displayItems.count else { return }
            let item = cloudViewModel.displayItems[index]
            // CloudBackupSection decides its own presentation the same way,
            // and both flags live on the shared state.
            if horizontalSizeClass == .regular && cloudViewModel.state == .loaded {
                state.cloudSelectedItemID = item.id
            } else {
                state.cloudDetailItem = item
            }
        }
    }

    /// Search and sort act on whichever section is visible.
    private var searchBinding: Binding<String> {
        section == .local ? $viewModel.searchText : $cloudViewModel.searchText
    }

    /// Resets both sections' filters, so no hidden query survives.
    private func clearSearch() {
        viewModel.searchText = ""
        cloudViewModel.searchText = ""
    }

    private var sortBinding: Binding<BackupListViewModel.SortMode> {
        section == .local ? $viewModel.sortMode : $cloudViewModel.sortMode
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.displaySaves.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.loadFailed {
            errorState
        } else if viewModel.displaySaves.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(viewModel.displaySaves.enumerated()),
                            id: \.element.id) { index, save in
                        Button {
                            show(save)
                        } label: {
                            BackupSaveRow(save: save)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .controllerFocusRing(
                            state.saveIndex(for: state.focused ?? -1) == index)
                        .id(save.id)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .refreshable { await viewModel.load() }
                // Names the list itself, so a test asking "is there a save
                // row?" can say which list it means: on regular width the
                // sidebar is a collection of rows too, and an unscoped row
                // query matches it.
                .accessibilityIdentifier(Self.listIdentifier)
                .followsControllerFocus(state.focused, in: proxy) { focusIndex -> String? in
                    guard let index = state.saveIndex(for: focusIndex),
                          index < viewModel.displaySaves.count else { return nil }
                    return viewModel.displaySaves[index].id
                }
            }
        }
    }

    /// Accessibility identifier of the local save list.
    static let listIdentifier = "BackupSaveList"
    /// The one control that chooses the store, local memories and cloud alike.
    static let sourcePickerIdentifier = "BackupSourcePicker"

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(String(localized: "No saves found", comment: "Empty backup list"))
                .font(.title3.weight(.medium))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Shown when the backup memory could not be read at all.
    private var errorState: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(String(localized: "Could not read the backup memory.",
                        comment: "Backup load error"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button(String(localized: "Retry", comment: "Retry loading backups")) {
                Task { await viewModel.load() }
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(Color.themeOnPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar

    /// Toolbar positions, in the order the buttons are drawn. Named so the
    /// rings and the declared actions cannot disagree about which is which.
    private enum Toolbar {
        static let community = 0
        static let search = 1
        static let sort = 2
    }

    /// The navigation bar's buttons, for D-pad Up out of the list. The shared
    /// routing does the rest (ControllerFocusScope.toolbarActions).
    private func declareToolbarActions() {
        state.toolbar = [
            { state.showCommunity = true },
            toggleSearch,
            cycleSort
        ]
    }

    /// What the Search button does, reached from the controller instead of a
    /// tap. Same body as SearchToolbarButton, which owns the tap.
    private func toggleSearch() {
        withAnimation(SearchField.animation(reduceMotion: state.reduceMotion)) {
            if state.isSearching {
                clearSearch()
                state.isSearching = false
            } else {
                state.isSearching = true
            }
        }
    }

    /// A on Sort steps to the next mode of whichever section is showing,
    /// rather than opening the menu: a system menu draws its own highlight,
    /// which the app cannot move, so this cycles as the source control does.
    private func cycleSort() {
        let all = BackupListViewModel.SortMode.allCases
        let binding = sortBinding
        let index = all.firstIndex(of: binding.wrappedValue) ?? 0
        binding.wrappedValue = all[(index + 1) % all.count]
    }

    /// Community saves are a separate place, not a fourth entry in the source
    /// picker: that picker chooses among the user's own stores, and other
    /// people's saves are not one of those.
    private var communityButton: some View {
        Button {
            state.showCommunity = true
        } label: {
            Image(systemName: "person.2")
        }
        .accessibilityLabel(String(localized: "Community Saves",
                                   comment: "Shared backup screen title"))
        // The label above is translated; this is what a screenshot run in any
        // language can find the button by.
        .accessibilityIdentifier("person.2")
    }

    private var sortMenu: some View {
        Menu {
            Picker(String(localized: "Sort", comment: "Sort menu"),
                   selection: sortBinding) {
                Text(String(localized: "Name (A-Z)", comment: "Sort saves"))
                    .tag(BackupListViewModel.SortMode.nameAscending)
                Text(String(localized: "Name (Z-A)", comment: "Sort saves"))
                    .tag(BackupListViewModel.SortMode.nameDescending)
                Text(String(localized: "Newest first", comment: "Sort saves"))
                    .tag(BackupListViewModel.SortMode.dateDescending)
                Text(String(localized: "Oldest first", comment: "Sort saves"))
                    .tag(BackupListViewModel.SortMode.dateAscending)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel(String(localized: "Sort", comment: "Sort menu"))
    }
}
