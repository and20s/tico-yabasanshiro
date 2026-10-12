import Combine
import SwiftUI

/// The games tab: searchable, sortable card list of the game library.
/// Mirrors the Android fragment_game_select_phone2 behavior, including the
/// toolbar-triggered search bar that hides (and clears) when dismissed.
struct GamesTabView: View {
    @ObservedObject var viewModel: GameListViewModel
    /// Search, pane selection and controller focus. Owned by MainTabView so
    /// none of it is lost when the sidebar rebuilds this view.
    @ObservedObject var state: GamesTabState
    /// Where this screen declares its focus scope. Optional so previews and
    /// tests can build the view without one.
    var focus: ControllerFocusCoordinator?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.isControllerConnected) private var isControllerConnected
    @EnvironmentObject private var entitlementStore: ProEntitlementStore

    /// Two panes wherever there is width for them. Android branches on
    /// orientation instead, which leaves tablet portrait on the phone layout
    /// and misreads split-screen; the size class is the width-aware version of
    /// the same decision, so iPad portrait and Split View get the pane too.
    private var isTwoPane: Bool { horizontalSizeClass == .regular }

    private var selectedGame: GameItem? {
        state.selectedGameID.flatMap { id in
            viewModel.displayItems.first { $0.id == id }
        }
    }

    var body: some View {
        Group {
            if isTwoPane {
                twoPaneLayout
            } else {
                singlePaneLayout
            }
        }
        .controllerFocusScope(state, in: focus)
        .animation(SearchField.animation(reduceMotion: reduceMotion),
                   value: state.isSearching)
        .task {
            await viewModel.loadInitial()
            await refreshOnlineMetadata()
            state.applyInitialFocus(controllerConnected: isControllerConnected)
        }
        .onAppear {
            state.reduceMotion = reduceMotion
            declareToolbarActions()
        }
        .onChange(of: reduceMotion) { state.reduceMotion = $0 }
        .onChange(of: isControllerConnected) {
            state.applyInitialFocus(controllerConnected: $0)
        }
        .onChange(of: viewModel.displayItems.count) { _ in
            state.applyInitialFocus(controllerConnected: isControllerConnected)
        }
        .onChange(of: viewModel.pendingDetailItem) { item in
            if let item = item {
                show(item)
                viewModel.pendingDetailItem = nil
            }
        }
        .proGate(item: $viewModel.gateReason, focus: focus) {
            ProEntitlementStore.shared.refresh()
        }
        // The limit lifts the moment a purchase lands, and the cards have to
        // stop being locked without waiting for the next rescan.
        .onChange(of: entitlementStore.entitlement) { viewModel.apply(entitlement: $0) }
        .onAppear { viewModel.apply(entitlement: entitlementStore.entitlement) }
        // Only ever set in the single-pane layout, so the sheet cannot appear
        // over the two-pane one.
        .sheet(item: $state.detailItem) { item in
            GameDetailSheet(item: item, viewModel: viewModel, focus: focus)
                .presentationDetents([.medium, .large])
                // A sheet is presented outside this view's hierarchy on some
                // iOS versions, so the connected flag is handed over rather
                // than assumed to be inherited.
                .environment(\.isControllerConnected, isControllerConnected)
        }
    }

    /// Compact width (every iPhone orientation): the list fills the tab and
    /// the detail arrives as a modal sheet, exactly as before.
    private var singlePaneLayout: some View {
        NavigationStack {
            chrome(listContent)
        }
    }

    /// Regular width: list and detail side by side, persistently.
    ///
    /// A plain HStack inside one NavigationStack rather than a
    /// NavigationSplitView. The split view was tried first and gives column
    /// resizing for free, but it puts the list in its own narrow navigation
    /// column, and on iPadOS 18 that column's trailing toolbar sits exactly
    /// where the floating top tab bar is drawn: in portrait the Search and
    /// Sort buttons were dropped entirely. One full-width bar over both panes
    /// keeps them, and is also what the Android landscape layout does.
    private var twoPaneLayout: some View {
        NavigationStack {
            chrome(GeometryReader { geometry in
                HStack(spacing: 0) {
                    listContent
                        .frame(width: DetailPane.listWidth(for: geometry.size.width))
                        .controllerPaneIdentity(.content)
                    // Android's 1dp MaterialDivider between the two panes.
                    Divider()
                        .overlay(Color.themeOutlineVariant)
                    detailPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            })
        }
    }

    private var listContent: some View {
        VStack(spacing: 0) {
            if state.isSearching {
                SearchField(text: $viewModel.searchText,
                            prompt: String(localized: "Search",
                                           comment: "Search games"),
                            onDismiss: {
                                withAnimation(SearchField.animation(
                                    reduceMotion: reduceMotion)) {
                                    state.isSearching = false
                                }
                            })
                    .transition(SearchField.transition(reduceMotion: reduceMotion))
            }
            if viewModel.showsSubscribeOffer {
                subscribeBanner
            }
            if viewModel.displayItems.isEmpty && !viewModel.isScanning {
                emptyState
            } else {
                gameList
            }
        }
    }

    /// Title, search and sort. Applied to the list alone when there is one
    /// pane and to the pair when there are two, so the bar always spans the
    /// whole tab exactly as the Android toolbar does.
    private func chrome<V: View>(_ content: V) -> some View {
        content
            .navigationTitle(String(localized: "Games", comment: "Games tab"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SearchToolbarButton(isActive: $state.isSearching,
                                        onClose: { viewModel.searchText = "" })
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
            .background(Color.themeBackground)
    }

    /// Toolbar positions, in the order the buttons are drawn. Named so the
    /// rings and the declared actions cannot disagree about which is which.
    private enum Toolbar {
        static let search = 0
        static let sort = 1
    }

    /// The navigation bar's buttons, for D-pad Up out of the list. The shared
    /// routing does the rest (ControllerFocusScope.toolbarActions).
    private func declareToolbarActions() {
        state.toolbar = [toggleSearch, cycleSort]
    }

    /// What the Search button does, reached from the controller instead of a
    /// tap. Same body as SearchToolbarButton, which owns the tap.
    private func toggleSearch() {
        withAnimation(SearchField.animation(reduceMotion: state.reduceMotion)) {
            if state.isSearching {
                viewModel.searchText = ""
                state.isSearching = false
            } else {
                state.isSearching = true
            }
        }
    }

    /// A on Sort steps to the next mode rather than opening the menu: a
    /// system menu draws its own highlight, which the app cannot move, so
    /// cycling is what the backup tab's source control already does.
    private func cycleSort() {
        let all = GameListViewModel.SortMode.allCases
        let index = all.firstIndex(of: viewModel.sortMode) ?? 0
        viewModel.sortMode = all[(index + 1) % all.count]
    }

    @ViewBuilder
    private var detailPane: some View {
        Group {
            if let item = selectedGame {
                // Same view as the sheet, told which context it is in. Rebuilt
                // per game so its view model picks up the new item.
                GameDetailSheet(item: item,
                                viewModel: viewModel,
                                presentation: .pane,
                                focus: focus,
                                onClose: { state.selectedGameID = nil })
                    .id(item.id)
            } else {
                GameDetailPlaceholderView()
            }
        }
        // Android gives detail_panel colorSurfaceContainerLow so the pane
        // reads as a surface laid over the list background.
        .background(Color.themeSurfaceContainerLow)
        // Rings in here dim while the list is the live column.
        .controllerPaneIdentity(.detail)
    }

    /// Opens a game unless the free version's limit keeps it out of reach, in
    /// which case the pro gate opens instead. Shared by the tap route and the
    /// controller route, which reaches it through GamesTabState.
    private func choose(_ item: GameItem) {
        guard viewModel.select(item) else { return }
        show(item)
    }

    /// Opens a game the way the current layout shows detail.
    private func show(_ item: GameItem) {
        if isTwoPane {
            state.selectedGameID = item.id
        } else {
            state.detailItem = item
        }
    }

    private var gameList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(viewModel.displayItems.enumerated()), id: \.element.id) { index, item in
                        GameCardView(item: item,
                                     isFocused: viewModel.focusedIndex == index,
                                     isLocked: viewModel.isLocked(item))
                            .id(item.id)
                            .onTapGesture { choose(item) }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
#if FREE_VERSION
                // showsAds, not the build flag alone: a subscriber paid to be
                // rid of these. It stays true while StoreKit is undecided, so
                // a non-subscriber's impression is never lost to a slow answer.
                if entitlementStore.entitlement.showsAds {
                    BannerAdView()
                        .frame(height: 60)
                }
#endif
            }
            .refreshable { await viewModel.refresh() }
            // Restores the scroll position after the sidebar rebuilds this
            // view: focusedIndex outlives the rebuild but the scroll offset
            // does not, and onChange only fires on a change.
            .followsControllerFocus(viewModel.focusedIndex, in: proxy) { index in
                index < viewModel.displayItems.count
                    ? viewModel.displayItems[index].id : nil
            }
        }
    }


    /// Offered only once the limit is actually holding games back, so the
    /// three games a free user is entitled to are not sold to on every launch.
    ///
    /// Deliberately not a controller focus target: it would sit at index 0 and
    /// push every card down one, and the gate it opens is already reachable
    /// with A on any locked card (behaviour table section 2).
    private var subscribeBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .foregroundStyle(Color.themePrimary)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "The free version holds three games",
                            comment: "Subscribe banner title"))
                    .font(.subheadline.weight(.semibold))
                Text(String(localized: "\(viewModel.lockedCount) more are locked",
                            comment: "Subscribe banner detail: number of locked games"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(String(localized: "Subscribe to Pro",
                          comment: "Subscribe banner button")) {
                viewModel.presentGate()
            }
            .buttonStyle(.borderedProminent)
            .font(.caption.weight(.semibold))
        }
        .padding(12)
        .background(Color.themeSurfaceContainerHigh,
                    in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .accessibilityIdentifier("subscribeBanner")
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image("missing")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .opacity(0.38)
            Text(String(localized: "No games found",
                        comment: "Empty game list title"))
                .font(.title3.weight(.medium))
            Text(String(localized: "Add games from the Add tab",
                        comment: "Empty game list guidance"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sortMenu: some View {
        Menu {
            Picker(String(localized: "Sort", comment: "Sort menu"),
                   selection: $viewModel.sortMode) {
                Text(String(localized: "Name", comment: "Sort by name"))
                    .tag(GameListViewModel.SortMode.name)
                Text(String(localized: "Release Date", comment: "Sort by release date"))
                    .tag(GameListViewModel.SortMode.releaseDate)
                Text(String(localized: "Recently Played", comment: "Sort by recently played"))
                    .tag(GameListViewModel.SortMode.recentlyPlayed)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel(String(localized: "Sort", comment: "Sort menu"))
    }

    /// Fetch RA progress for the whole library (once per launch) and
    /// republish. Ratings are fetched per game when the detail sheet opens.
    ///
    /// "Once per launch" is enforced by the view model, which outlives this
    /// view: on regular width the sidebar rebuilds the games tab on every
    /// visit, and this would otherwise become one network round trip per
    /// visit. The claim is taken last, so signing in later still gets a fetch.
    private func refreshOnlineMetadata() async {
        guard RetroAchievementsAuthManager.shared.isRetroAchievementsLoggedIn,
              let username = RetroAchievementsAuthManager.shared.currentUsername,
              let token = RAProgressService.currentToken(),
              viewModel.claimOnlineMetadataRefresh() else {
            return
        }
        let service = RAProgressService()
        let updated = await service.updateProgress(items: viewModel.displayItems,
                                                   username: username, token: token)
        viewModel.applyUpdatedItems(updated)
    }
}

#if FREE_VERSION
import GoogleMobileAds

/// Adaptive banner ad shown at the bottom of the games tab (Lite only).
/// Ports the FileSelectController GADBannerView setup.
struct BannerAdView: UIViewRepresentable {
    func makeUIView(context: Context) -> GADBannerView {
        let banner = GADBannerView(
            adSize: GADCurrentOrientationAnchoredAdaptiveBannerAdSizeWithWidth(
                UIScreen.main.bounds.width))
        if let path = Bundle.main.path(forResource: "secrets", ofType: "plist"),
           let dict = NSDictionary(contentsOfFile: path) as? [String: AnyObject],
           let bannerId = dict["bannerId"] as? String {
            banner.adUnitID = bannerId
        } else {
            // Google's test ad unit ID for development
            banner.adUnitID = "ca-app-pub-3940256099942544/2934735716"
        }
        banner.rootViewController = GameLauncher.topViewController()
        banner.load(GADRequest())
        return banner
    }
    func updateUIView(_ view: GADBannerView, context: Context) {}
}
#endif
