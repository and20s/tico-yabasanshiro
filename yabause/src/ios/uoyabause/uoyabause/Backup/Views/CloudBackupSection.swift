import SwiftUI
import FirebaseAuth

/// The cloud half of the backup tab: the list plus its sign-in, upgrade,
/// empty and failure states.
struct CloudBackupSection: View {
    @ObservedObject var viewModel: CloudBackupViewModel
    @ObservedObject var localViewModel: BackupListViewModel
    /// The backup tab's shared state. This section's detail selection lives
    /// there rather than here so the whole tab has one focus scope, which is
    /// what lets B reach the search field the two sections share.
    @ObservedObject var state: BackupTabState
    var focus: ControllerFocusCoordinator?
    @State private var showSignIn = false
    @State private var gateReason: ProGateReason?
    /// Observed so the load can be re-driven the moment StoreKit decides.
    /// The first load bails to `.checkingEntitlement` when the answer has not
    /// arrived, and nothing else on this screen would ever ask again: the
    /// `.task` runs once per appearance and pull to refresh only exists on
    /// the loaded list.
    @ObservedObject private var entitlementStore = ProEntitlementStore.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.isControllerConnected) private var isControllerConnected

    /// Two panes wherever there is width for them, the same width-based rule
    /// the games and local backup lists use, and only once there is a list to
    /// put beside the detail: a sign-in or upgrade prompt fills the section.
    private var isTwoPane: Bool {
        horizontalSizeClass == .regular && viewModel.state == .loaded
    }

    private var selectedItem: CloudBackupItem? {
        state.cloudSelectedItemID.flatMap { id in
            viewModel.displayItems.first { $0.id == id }
        }
    }

    var body: some View {
        Group {
            if isTwoPane {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        listColumn
                            .frame(width: DetailPane.listWidth(for: geometry.size.width))
                            .controllerPaneIdentity(.content)
                        // Android's 1dp MaterialDivider between the two panes.
                        Divider()
                            .overlay(Color.themeOutlineVariant)
                        detailPane
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else {
                listColumn
            }
        }
        .task { await viewModel.loadInitial() }
        .onChange(of: entitlementStore.entitlement) { _ in
            // loadInitial(), not load(): a section that already loaded stays
            // put, and one still waiting on the entitlement finally runs.
            Task { await viewModel.loadInitial() }
        }
        .sheet(item: $state.cloudDetailItem) { item in
            CloudBackupDetailSheet(item: item, cloudViewModel: viewModel,
                                   localViewModel: localViewModel,
                                   focus: focus)
                .presentationDetents([.medium, .large])
                .environment(\.isControllerConnected, isControllerConnected)
        }
        .sheet(isPresented: $showSignIn, onDismiss: {
            Task { await viewModel.load() }
        }) {
            SignInSheet(focus: focus)
                .environment(\.isControllerConnected, isControllerConnected)
        }
        .alert(String(localized: "Error", comment: "Error alert title"),
               isPresented: Binding(get: { viewModel.errorMessage != nil },
                                    set: { if !$0 { viewModel.clearError() } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .proGate(item: $gateReason, focus: focus) {
            ProEntitlementStore.shared.refresh()
            Task { await viewModel.load() }
        }
    }

    /// Slot bar plus the list or whichever state stands in for it: everything
    /// the compact layout shows, which becomes the left column when split.
    private var listColumn: some View {
        VStack(spacing: 0) {
            if let usage = viewModel.slotUsage,
               viewModel.state == .loaded || viewModel.state == .empty {
                slotBar(usage)
            }
            content
        }
    }

    private var detailPane: some View {
        Group {
            if let item = selectedItem {
                // Same view as the sheet, told which context it is in.
                CloudBackupDetailSheet(item: item,
                                       cloudViewModel: viewModel,
                                       localViewModel: localViewModel,
                                       presentation: .pane,
                                       onClose: { state.cloudSelectedItemID = nil },
                                       focus: focus)
                    .id(item.id)
            } else {
                DetailPanePlaceholderView(
                    systemImage: "icloud",
                    text: String(localized: "Select a save",
                                 comment: "Backup detail pane placeholder"))
            }
        }
        .background(Color.themeSurfaceContainerLow)
        // Rings in here dim while the list is the live column.
        .controllerPaneIdentity(.detail)
    }

    /// Opens a backup the way the current layout shows detail.
    private func show(_ item: CloudBackupItem) {
        if isTwoPane {
            state.cloudSelectedItemID = item.id
        } else {
            state.cloudDetailItem = item
        }
    }

    /// Slots, not bytes: the old build rendered "3 Byte used / 256 Byte total".
    private func slotBar(_ usage: CloudSlotUsage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: usage.total > 0
                         ? Double(usage.used) / Double(usage.total) : 0)
                .tint(Color.themePrimary)
            Text("\(usage.used)/\(usage.total) "
                 + String(localized: "slots used", comment: "Cloud slot usage"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading, .checkingEntitlement:
            // Neutral while StoreKit decides: a subscriber must not be shown
            // the upgrade prompt just because the answer has not arrived.
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .signInRequired:
            message(icon: "person.crop.circle.badge.questionmark",
                    text: String(localized: "Sign in to use cloud backup.",
                                 comment: "Cloud sign in prompt"),
                    button: String(localized: "Sign In", comment: "Sign in button")) {
                showSignIn = true
            }
        case .upgradeRequired:
            message(icon: "lock",
                    text: String(localized: "Cloud backup is available in the full version.",
                                 comment: "Cloud upgrade prompt"),
                    button: String(localized: "Get the full version",
                                   comment: "Upgrade button")) {
                gateReason = ProGateReason(
                    String(localized: "Cloud backup needs a subscription or the full version.",
                           comment: "Reason the pro gate opened from cloud backup"))
            }
        case .failed:
            message(icon: "exclamationmark.triangle",
                    text: String(localized: "Could not reach the cloud.",
                                 comment: "Cloud load error"),
                    button: String(localized: "Retry", comment: "Retry loading")) {
                Task { await viewModel.load() }
            }
        case .empty:
            message(icon: "icloud",
                    text: String(localized: "No cloud backups yet.",
                                 comment: "Empty cloud list"),
                    button: nil, action: nil)
        case .loaded:
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(viewModel.displayItems.enumerated()),
                            id: \.element.id) { index, item in
                        Button { show(item) } label: { CloudSaveRow(item: item) }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                            .controllerFocusRing(
                                state.saveIndex(for: state.focused ?? -1) == index)
                            .id(item.id)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .refreshable { await viewModel.load() }
                // See BackupTabView.listIdentifier: names the list so a row
                // query cannot pick up the sidebar's rows instead.
                .accessibilityIdentifier(Self.listIdentifier)
                .followsControllerFocus(state.focused, in: proxy) { focusIndex -> String? in
                    guard let index = state.saveIndex(for: focusIndex),
                          index < viewModel.displayItems.count else { return nil }
                    return viewModel.displayItems[index].id
                }
            }
        }
    }

    /// Accessibility identifier of the cloud save list.
    static let listIdentifier = "CloudSaveList"

    @ViewBuilder
    private func message(icon: String, text: String, button: String?,
                         action: (() -> Void)?) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if let button = button, let action = action {
                Button(button, action: action)
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(Color.themeOnPrimary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The sign-in screen as a sheet. Dismisses itself once Firebase reports a
/// signed-in user, and the cloud list reloads from its own auth listener.
struct SignInSheet: View {
    var focus: ControllerFocusCoordinator?

    @Environment(\.dismiss) private var dismiss
    @StateObject private var watcher = SignInSheetAuthWatcher()

    var body: some View {
        NavigationStack {
            SignInView()
                .navigationTitle(String(localized: "Sign In",
                                        comment: "Sign in heading"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Close",
                                      comment: "Close Dialoig")) { dismiss() }
                    }
                }
        }
        // The providers are out-of-process OAuth flows, which spec section 1.2
        // puts out of scope. B still closes the sheet, and the backup list
        // underneath stops answering while it is up.
        .modalControllerBlocker(named: "signInSheet", in: focus) { dismiss() }
        .onChange(of: watcher.isSignedIn) { signedIn in
            if signedIn { dismiss() }
        }
    }
}

/// Watches Firebase auth for as long as the sheet is on screen, so the sheet
/// can close itself the moment sign-in succeeds. It owns its listener and
/// removes it on deinit, unlike the shared one in AccountState.
@MainActor
final class SignInSheetAuthWatcher: ObservableObject {
    @Published private(set) var isSignedIn: Bool

    private var handle: AuthStateDidChangeListenerHandle?

    init() {
        isSignedIn = Auth.auth().currentUser != nil
        handle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            MainActor.assumeIsolated {
                self?.isSignedIn = user != nil
            }
        }
    }

    deinit {
        if let handle = handle {
            Auth.auth().removeStateDidChangeListener(handle)
        }
    }
}
