import Combine
import SwiftUI

/// Tab identifiers matching the Android bottom navigation
/// (nav_games / nav_backup / nav_add / nav_settings / nav_account).
enum HomeTab: Hashable, CaseIterable, Identifiable {
    case games, backup, add, settings, account

    var id: Self { self }

    var title: String {
        switch self {
        case .games: return String(localized: "Games", comment: "Games tab")
        case .backup: return String(localized: "Backup", comment: "Backup tab")
        case .add: return String(localized: "Add", comment: "Add game tab")
        case .settings: return String(localized: "Settings", comment: "Settings tab")
        case .account: return String(localized: "Account", comment: "Account tab")
        }
    }

    /// Also the accessibility identifier of the tab's button, which is how the
    /// UI tests find a tab on a device running in another language.
    var systemImage: String {
        switch self {
        case .games: return "gamecontroller"
        case .backup: return "externaldrive.badge.icloud"
        case .add: return "plus.circle"
        case .settings: return "gearshape"
        case .account: return "person.circle"
        }
    }
}

/// Root of the new home UI: five destinations mirroring the Android structure.
/// The Add destination acts as an action button opening the add-game sheet.
///
/// Compact width keeps the bottom tab bar. Regular width moves the same five
/// entries into a sidebar, which is what Android does with its
/// NavigationRailView in landscape - except that this branches on width
/// rather than orientation, so iPad portrait and Split View are handled too.
/// `.tabViewStyle(.sidebarAdaptable)` would do this in one line but needs
/// iOS 18; the deployment target here is iOS 16.
struct MainTabView: View {
    @StateObject private var gameList = GameListViewModel()
    /// Held here rather than inside GamesTabView so that rebuilding the
    /// sidebar's detail column does not throw away the search field, the pane
    /// selection or the focused card.
    @StateObject private var gamesTab = GamesTabState()
    @State private var selectedTab: HomeTab = .games
    /// The other tabs' state, held here for the same reason gamesTab is: at
    /// regular width the sidebar rebuilds the detail column on every tab
    /// change, and anything a tab owned itself would be destroyed with it.
    @StateObject private var backupList = BackupListViewModel()
    @StateObject private var cloudBackup = CloudBackupViewModel()
    @StateObject private var backupTab = BackupTabState()
    @StateObject private var settingsTab = SettingsTabModel()
    /// Community browsing keeps its fetched pages across a sidebar switch for
    /// the same reason the other lists do -- and here a refetch costs network.
    @StateObject private var sharedBrowse = SharedBackupBrowseViewModel()
    /// Shared by AppDelegate, which is where a tapped link is first seen.
    @ObservedObject private var linkRouter = SharedBackupLinkRouter.shared

    /// The account tab's three objects, built together because the two view
    /// models read the same AccountState. Holding them here also keeps the
    /// Firebase auth listener alive for the whole session rather than only
    /// while the tab is on screen.
    @StateObject private var accountState: AccountState
    @StateObject private var accountViewModel: AccountViewModel
    @StateObject private var pinViewModel: DevicePinViewModel

    init() {
        let state = AccountState()
        _accountState = StateObject(wrappedValue: state)
        _accountViewModel = StateObject(
            wrappedValue: AccountViewModel(accountState: state))
        _pinViewModel = StateObject(
            wrappedValue: DevicePinViewModel(accountState: state))
    }

    /// The document browser the Add entry opens straight into.
    @State private var showFilePicker = false
    @StateObject private var importer = GameImporter()
    @StateObject private var gamePad = HomeGamePadManager()
    /// The single owner of "who receives controller input".
    @StateObject private var focus = ControllerFocusCoordinator()
    /// The sidebar's focus, declared only while the sidebar exists. Its
    /// presence on the stack is also how the coordinator knows this is the
    /// two-pane layout, so D-pad Left/Right is dead at compact width without
    /// a second size-class test.
    @StateObject private var sidebarFocus = SidebarFocusModel()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    private var isSidebar: Bool { horizontalSizeClass == .regular }

    /// Everything the sidebar and the tab bar list, in order.
    private static let entries: [HomeTab] = [.games, .backup, .add, .settings, .account]

    /// Add is an action, not a destination: selecting it opens the document
    /// browser and leaves the current selection alone. Shared by the tab bar
    /// and the sidebar so the two cannot drift apart.
    ///
    /// It opens the browser directly rather than a sheet offering to open it.
    /// The sheet's only other content was a list of supported extensions,
    /// which the picker already enforces.
    private func select(_ tab: HomeTab) {
        if tab == .add {
            if importer.canAdd(currentCount: gameList.totalCount) {
                showFilePicker = true
            }
        } else {
            selectedTab = tab
        }
    }

    /// Walks the UI to the save a shared link names: the backup tab, then the
    /// community screen, then that save's detail.
    ///
    /// The id is cleared straight away rather than after the fetch, so a link
    /// that fails to resolve does not fire again on the next redraw.
    private func openSharedLink(id: String) {
        linkRouter.clearPending()
        selectedTab = .backup
        backupTab.showCommunity = true
        Task { await sharedBrowse.openLink(id: id) }
    }

    private var tabSelection: Binding<HomeTab> {
        Binding(get: { selectedTab }, set: { select($0) })
    }

    /// A sidebar List reports no selection when it has none, so this unwraps
    /// before applying the same rule. Reading `selectedTab` back means a tap
    /// on Add leaves the highlight where it was instead of sticking on Add.
    private var sidebarSelection: Binding<HomeTab?> {
        Binding(get: { selectedTab },
                set: { newValue in
                    guard let newValue = newValue else { return }
                    select(newValue)
                })
    }

    var body: some View {
        Group {
            if isSidebar {
                sidebarLayout
            } else {
                tabLayout
            }
        }
        .tint(Color.themePrimary)
        .environment(\.isControllerConnected, gamePad.isControllerConnected)
        .environmentObject(ProEntitlementStore.shared)
        // Compact width has one pane, so it publishes no active pane at all
        // and every ring there keeps drawing exactly as it did.
        .environment(\.activeControllerPane, isSidebar ? focus.activePane : nil)
        .fileImporter(isPresented: $showFilePicker,
                      allowedContentTypes: GameImporter.contentTypes,
                      allowsMultipleSelection: true) { result in
            Task { await importer.importFiles(result, into: gameList) }
        }
        // The document browser is another process's view controller: the
        // D-pad would otherwise keep moving the list behind it, and B cannot
        // dismiss it from here. A blocker scope parks input until it closes.
        .modalControllerBlocker(named: "filePicker", in: focus,
                                onClose: {},
                                isPresented: showFilePicker)
        .overlay {
            if importer.isImporting {
                ProgressView(String(localized: "Importing...",
                                    comment: "Import progress"))
                    .padding(24)
                    .background(Color.themeSurfaceContainerHigh,
                                in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .proGate(item: $importer.gateReason, focus: focus) {
            ProEntitlementStore.shared.refresh()
        }
        .alert(String(localized: "Fail to open", comment: "Import error title"),
               isPresented: Binding(get: { importer.errorMessage != nil },
                                    set: { if !$0 { importer.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importer.errorMessage ?? "")
        }
        .onReceive(gamePad.events) { event in
            handleGamePad(event)
        }
        .onAppear {
            gamesTab.configure(list: gameList)
            sidebarFocus.entries = Self.entries
            sidebarFocus.currentTab = selectedTab
            sidebarFocus.onSelect = { select($0) }
            gamePad.activate()
            #if DEBUG
            // Every real route to the gate needs either a signed-in Firebase
            // user or seeded library content, neither of which a UI test can
            // set up. This flag opens the same sheet through the same
            // binding so a test can still prove the sheet renders and
            // carries its identifier. Debug-only: the Lite scheme's Test
            // action builds Debug and Archive builds Release, so this
            // argument has no effect in a shipped build.
            if ProcessInfo.processInfo.arguments.contains("-uiTestProGate") {
                importer.gateReason = ProGateReason()
            }
            #endif
        }
        // A tapped share link lands in the router; bring the screen to it.
        .onReceive(linkRouter.$pendingId.compactMap { $0 }) { id in
            openSharedLink(id: id)
        }
        .onChange(of: selectedTab) { tab in
            // Entering the sidebar highlights the tab that is showing.
            sidebarFocus.currentTab = tab
            // Every tab is SwiftUI now, so none of them installs its own
            // GCController handlers: ours stays active everywhere. Leaving it
            // off on a tab would trap a controller user on that tab, since the
            // shoulder buttons are the only way back (ios/CLAUDE.md CRITICAL).
            gamePad.activate()
        }
    }

    /// Compact width: the same five `.tabItem`s as before the iPad work,
    /// written out rather than looped so the TabView keeps building each tab
    /// exactly as it did.
    private var tabLayout: some View {
        TabView(selection: tabSelection) {
            tab(.games)
            tab(.backup)
            tab(.add)
            tab(.settings)
            tab(.account)
        }
    }

    private func tab(_ tab: HomeTab) -> some View {
        destination(for: tab)
            .tabItem { Label(tab.title, systemImage: tab.systemImage) }
            // The label is translated, so the symbol name is what a test can
            // rely on to find this tab in any of the languages the app ships.
            // The sidebar rows carry the same identifier.
            .accessibilityIdentifier(tab.systemImage)
            .tag(tab)
    }

    /// Regular width: the same entries as a sidebar, with the selected one
    /// filling the rest of the window.
    private var sidebarLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: sidebarSelection) {
                ForEach(Array(Self.entries.enumerated()), id: \.element) { index, tab in
                    Label(tab.title, systemImage: tab.systemImage)
                        .accessibilityIdentifier(tab.systemImage)
                        // The system's selection highlight says which tab is
                        // showing; this says where the controller is, which
                        // during a D-pad walk are two different entries.
                        .controllerFocusRing(sidebarFocus.focused == index,
                                             cornerRadius: 8)
                        .tag(tab)
                }
            }
            .controllerPaneIdentity(.sidebar)
            .controllerFocusScope(sidebarFocus, in: focus)
            .navigationTitle("YabaSanshiro")
            .navigationBarTitleDisplayMode(.inline)
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            detailColumn
        }
        // Not .prominentDetail: in portrait that hides the sidebar behind a
        // button, and the whole point here is that the rail stays visible in
        // both orientations the way the Android rail does.
        .navigationSplitViewStyle(.balanced)
    }

    /// Only the selected destination exists.
    ///
    /// A TabView instead keeps every visited tab alive, and stacking all of
    /// them here with the unselected ones hidden was tried so that behaviour
    /// would carry over. It does not work: a destination's navigation bar is
    /// UIKit chrome that neither `opacity` nor `accessibilityHidden` reaches,
    /// so the hidden tabs kept drawing their titles and toolbar buttons over
    /// the visible one - the Backup pane appeared under the title "Games"
    /// with two search and two sort buttons. Rebuilding the column is the
    /// only presentation that stays correct; the loads that used to happen
    /// once per launch are held to that by the view model instead, and the
    /// games tab's own view state lives in `gamesTab` so the rebuild no longer
    /// costs the user their search, selection or scroll position.
    @ViewBuilder
    private var detailColumn: some View {
        destination(for: selectedTab)
            // Everything the sidebar shows is the content column by default.
            // A tab that splits again (Games, Backup) marks its own detail
            // pane, and the nested value wins there.
            .controllerPaneIdentity(.content)
    }

    @ViewBuilder
    private func destination(for tab: HomeTab) -> some View {
        switch tab {
        case .games:
            GamesTabView(viewModel: gameList, state: gamesTab, focus: focus)
        case .backup:
            BackupTabView(focus: focus,
                          viewModel: backupList,
                          cloudViewModel: cloudBackup,
                          state: backupTab,
                          sharedViewModel: sharedBrowse)
        case .add:
            // Never shown: selecting Add opens the sheet instead. The tab bar
            // still needs something to put behind the item.
            Color.clear
        case .settings:
            SettingsTabView(focus: focus, model: settingsTab)
        case .account:
            AccountTabView(focus: focus,
                           accountState: accountState,
                           viewModel: accountViewModel,
                           pinViewModel: pinViewModel)
        }
    }

    /// Tab movement is the only thing handled here. Everything else belongs to
    /// whichever scope is on top of the stack, which is what stops a sheet
    /// from letting input through to the list behind it.
    private func handleGamePad(_ event: HomeGamePadManager.Event) {
        switch event {
        case .nextTab, .prevTab:
            // A modal covers the tabs, so L/R must not move them from under it.
            guard focus.allowsTabChange else { return }
            selectedTab = HomeTabNavigator.next(
                from: selectedTab, delta: event == .nextTab ? 1 : -1)
        default:
            focus.handle(event)
        }
    }
}
