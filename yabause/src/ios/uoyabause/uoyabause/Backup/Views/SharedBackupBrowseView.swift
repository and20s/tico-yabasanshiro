import SwiftUI

/// Browsing the community's shared saves.
///
/// Reached from the backup tab's toolbar rather than from the source picker:
/// that picker answers "which of my stores am I looking at", and other
/// people's saves are not one of them.
struct SharedBackupBrowseView: View {
    @ObservedObject var viewModel: SharedBackupBrowseViewModel
    /// The local list an import writes into, and reloads afterwards.
    @ObservedObject var localViewModel: BackupListViewModel
    /// Where this screen declares its focus scope.
    var focus: ControllerFocusCoordinator?
    /// Pops this screen. The navigation stack is the caller's, so B has to be
    /// handed the way back rather than guessing at one.
    var onClose: (() -> Void)?

    @State private var isSearching = false
    @State private var selectedItem: SharedBackupItem?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isControllerConnected) private var isControllerConnected

    @StateObject private var scope =
        ActionListFocusModel(scopeName: "sharedBrowse", pane: .content)

    var body: some View {
        content
            .navigationTitle(String(localized: "Community Saves",
                                    comment: "Shared backup screen title"))
            .navigationBarTitleDisplayMode(.inline)
            .background(Color.themeBackground)
            .safeAreaInset(edge: .top, spacing: 0) {
                if isSearching {
                    SearchField(text: $viewModel.searchText,
                                prompt: String(localized: "Search loaded saves",
                                               comment: "Shared search prompt"),
                                onDismiss: {
                                    withAnimation(SearchField.animation(
                                        reduceMotion: reduceMotion)) {
                                        isSearching = false
                                    }
                                })
                        .background(Color.themeBackground)
                        .transition(SearchField.transition(reduceMotion: reduceMotion))
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SearchToolbarButton(isActive: $isSearching,
                                        onClose: { viewModel.searchText = "" })
                        .padding(4)
                        .controllerFocusRing(scope.toolbarFocused == Toolbar.search,
                                             cornerRadius: 8)
                        .environment(\.isControllerConnected, isControllerConnected)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    sortMenu
                        .padding(4)
                        .controllerFocusRing(scope.toolbarFocused == Toolbar.sort,
                                             cornerRadius: 8)
                        .environment(\.isControllerConnected, isControllerConnected)
                }
            }
            .controllerFocusScope(scope, in: focus)
            .task { await viewModel.loadInitial() }
            .onAppear { configureScope() }
            // Keyed on which saves are showing, not how many. Cycling the
            // sort returns a different page of the same length, and the row
            // actions capture the items themselves, so a count-only check
            // would leave A opening a save that is no longer on screen.
            .onChange(of: rowIdentity) { _ in declareRows() }
            // A shared link names a save directly; opening its detail is the
            // same as having tapped its row.
            .onChange(of: viewModel.linkedItem) { item in
                guard let item else { return }
                selectedItem = item
                viewModel.clearLinkedItem()
            }
            .sheet(item: $selectedItem) { item in
                SharedBackupDetailSheet(item: item, viewModel: viewModel,
                                        localViewModel: localViewModel,
                                        focus: focus)
                    // A sheet can be presented outside this hierarchy, so the
                    // connected flag is handed over rather than inherited.
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

    // MARK: - Controller focus

    private func configureScope() {
        scope.isBlocked = { selectedItem != nil || viewModel.errorMessage != nil }
        scope.onClose = {
            if viewModel.errorMessage != nil {
                viewModel.clearError()
                return true
            }
            if isSearching {
                withAnimation(SearchField.animation(reduceMotion: reduceMotion)) {
                    viewModel.searchText = ""
                    isSearching = false
                }
                return true
            }
            // B is never a no-op (spec section 2). This screen was pushed by
            // the backup tab, so B walks back out of it.
            guard let onClose = onClose else { return false }
            onClose()
            return true
        }
        scope.setToolbarActions([toggleSearch, cycleSort])
        declareRows()
    }

    /// Toolbar positions, in the order the buttons are drawn.
    private enum Toolbar {
        static let search = 0
        static let sort = 1
    }

    /// What the Search button does, reached from the controller instead of a
    /// tap. Same body as SearchToolbarButton, which owns the tap.
    private func toggleSearch() {
        withAnimation(SearchField.animation(reduceMotion: reduceMotion)) {
            if isSearching {
                viewModel.searchText = ""
                isSearching = false
            } else {
                isSearching = true
            }
        }
    }

    /// A on Sort steps to the next order rather than opening the menu: a
    /// system menu draws its own highlight, which the app cannot move.
    private func cycleSort() {
        let all = SharedBackupSort.allCases
        let index = all.firstIndex(of: viewModel.sort) ?? 0
        let next = all[(index + 1) % all.count]
        Task { await viewModel.apply(sort: next) }
    }

    /// What the focus scope's rows are built from: the ids in order, plus
    /// whether the unhide row is present.
    private var rowIdentity: String {
        viewModel.displayItems.map(\.id).joined(separator: ",")
            + "|\(viewModel.blockedCount > 0)"
    }

    /// Where the unhide row sits, after every save. nil when nobody is hidden.
    private var unblockRowIndex: Int? {
        viewModel.blockedCount > 0 ? viewModel.displayItems.count : nil
    }

    private func declareRows() {
        var actions: [() -> Void] = viewModel.displayItems.map { item in
            { selectedItem = item }
        }
        if viewModel.blockedCount > 0 {
            actions.append { viewModel.unblockAll() }
        }
        scope.setActions(actions)
        scope.applyInitialFocus(controllerConnected: isControllerConnected)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .signInRequired:
            message(String(localized: "Sign in to browse community saves.",
                           comment: "Shared sign-in prompt"),
                    systemImage: "person.crop.circle.badge.questionmark")
        case .empty:
            message(String(localized: "No community saves yet.",
                           comment: "Shared empty state"),
                    systemImage: "square.stack.3d.up.slash")
        case .failed:
            VStack(spacing: 12) {
                message(String(localized: "Could not reach the cloud.",
                               comment: "Cloud unreachable"),
                        systemImage: "exclamationmark.triangle")
                Button(String(localized: "Retry", comment: "Retry")) {
                    Task { await viewModel.retry() }
                }
                .buttonStyle(.bordered)
            }
        case .loaded:
            list
        }
    }

    private func message(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(Color.themeOnSurfaceVariant)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Color.themeOnSurfaceVariant)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(Array(viewModel.displayItems.enumerated()),
                        id: \.element.id) { index, item in
                    Button { selectedItem = item } label: { SharedSaveRow(item: item) }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .controllerFocusRing(scope.focused == index)
                        .id(item.id)
                }

                // Search only covers what has been fetched, because Firestore
                // has no substring query. Saying so beats implying the library
                // is exhausted, which is the impression Android's version gives.
                if viewModel.isFilteringLocally {
                    Text(String(localized: "Showing matches among the saves loaded so far.",
                                comment: "Shared local-search note"))
                        .font(.caption)
                        .foregroundStyle(Color.themeOnSurfaceVariant)
                        .listRowBackground(Color.clear)
                }

                if viewModel.canLoadMore && viewModel.searchText.isEmpty {
                    loadMoreRow
                }

                unblockRow
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier(Self.listIdentifier)
            .refreshable { await viewModel.retry() }
            .followsControllerFocus(scope.focused, in: proxy) { index in
                index < viewModel.displayItems.count
                    ? viewModel.displayItems[index].id : nil
            }
        }
    }

    /// The only way back from hiding someone. Without it, a tap made in
    /// annoyance would be permanent, and there is no per-person list to undo
    /// from -- that would mean naming the people the user asked not to see.
    @ViewBuilder
    private var unblockRow: some View {
        if let index = unblockRowIndex {
            Button {
                viewModel.unblockAll()
            } label: {
                HStack {
                    Label(String(format: String(localized: "Hidden users (%d)",
                                                comment: "Blocked users row"),
                                 viewModel.blockedCount),
                          systemImage: "eye.slash")
                    Spacer()
                    Text(String(localized: "Show all", comment: "Unblock all"))
                        .foregroundStyle(Color.themePrimary)
                }
                .font(.caption)
                .foregroundStyle(Color.themeOnSurfaceVariant)
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
            .controllerFocusRing(scope.focused == index)
        }
    }

    private var loadMoreRow: some View {
        HStack {
            Spacer()
            if viewModel.isLoadingMore {
                ProgressView()
            } else {
                Button(String(localized: "Load more", comment: "Shared paging button")) {
                    Task { await viewModel.loadMore() }
                }
                .buttonStyle(.bordered)
            }
            Spacer()
        }
        .listRowBackground(Color.clear)
        .onAppear {
            // Fetches as the row scrolls into view, so the button is a
            // fallback rather than the only way forward.
            Task { await viewModel.loadMore() }
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker(String(localized: "Sort", comment: "Sort menu"),
                   selection: Binding(get: { viewModel.sort },
                                      set: { newValue in
                                          Task { await viewModel.apply(sort: newValue) }
                                      })) {
                Text(String(localized: "Newest first", comment: "Sort by newest"))
                    .tag(SharedBackupSort.newest)
                Text(String(localized: "Oldest first", comment: "Sort by oldest"))
                    .tag(SharedBackupSort.oldest)
                Text(String(localized: "Most downloaded",
                            comment: "Sort by download count"))
                    .tag(SharedBackupSort.mostDownloaded)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel(String(localized: "Sort", comment: "Sort menu"))
    }

    static let listIdentifier = "SharedSaveList"
}
