import StoreKit
import SwiftUI

/// The account tab. Signed out it offers the two sign-in providers; signed in
/// it shows the profile, the connected accounts, the subscription, the
/// cross-device sync PIN and account deletion -- the same sections as the
/// Android account screen.
struct AccountTabView: View {
    /// Where the signed-in half declares its focus scope. Signed out the tab
    /// is the sign-in providers, which are out-of-process OAuth flows and so
    /// out of scope (spec section 1.2); no scope is pushed there, which
    /// leaves L/R free to move to another tab.
    var focus: ControllerFocusCoordinator?

    /// Owned by MainTabView so the sidebar rebuilding this view does not drop
    /// the auth listener and refetch everything on every tab change.
    @ObservedObject var accountState: AccountState
    @ObservedObject var viewModel: AccountViewModel
    @ObservedObject var pinViewModel: DevicePinViewModel

    var body: some View {
        NavigationStack {
            Group {
                if let profile = accountState.profile {
                    SignedInAccountView(accountState: accountState,
                                        profile: profile,
                                        focus: focus,
                                        viewModel: viewModel,
                                        pinViewModel: pinViewModel)
                } else {
                    SignInView()
                }
            }
            .navigationTitle(String(localized: "Account", comment: "Account tab"))
            .background(Color.themeBackground)
        }
    }
}

/// Everything the tab shows once there is a signed-in user.
struct SignedInAccountView: View {
    @ObservedObject var accountState: AccountState
    let profile: AccountProfile
    var focus: ControllerFocusCoordinator?

    /// Both owned by MainTabView, so a sidebar rebuild does not refetch the
    /// Discord link, the RetroAchievements status and the subscription.
    @ObservedObject var viewModel: AccountViewModel
    @ObservedObject var pinViewModel: DevicePinViewModel
    /// A tab's own column, so D-pad Left reaches the sidebar from here too.
    @StateObject private var scope = ActionListFocusModel(scopeName: "account",
                                                          pane: .content)
    @State private var gateReason: ProGateReason?
    /// Set when Apple's subscription sheet could not be opened.
    @State private var manageError: String?
    @State private var password = ""
    @Environment(\.isControllerConnected) private var isControllerConnected

    /// The PIN card is useless without the gitignored endpoint keys, so a
    /// build that lacks them hides it rather than offering a dead button.
    private let isPinConfigured = DevicePinService().isConfigured

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    profileCard
                    Text(String(localized: "Connected Accounts",
                                comment: "Connected accounts header"))
                        .font(.headline)
                        .padding(.top, 8)
                    discordRow.id(AccountRow.discord)
                    retroAchievementsRow.id(AccountRow.retroAchievements)
                    subscriptionCard.id(AccountRow.subscription)
                    if isPinConfigured {
                        CrossDeviceSyncCard(viewModel: pinViewModel)
                            .controllerFocusRing(isFocused(.pin))
                            .id(AccountRow.pin)
                    }
                    deleteButton.id(AccountRow.delete)
                }
                .padding(16)
            }
            .followsControllerFocus(scope.focused, in: proxy) { index in
                index < visibleRows.count ? visibleRows[index] : nil
            }
        }
        .controllerFocusScope(scope, in: focus)
        .task { await viewModel.refresh() }
        .onAppear { configureScope() }
        .onChange(of: visibleRows) { _ in declareRows() }
        .onChange(of: isControllerConnected) {
            scope.applyInitialFocus(controllerConnected: $0)
        }
        .proGate(item: $gateReason, focus: focus) {
            ProEntitlementStore.shared.refresh()
            Task { await viewModel.refreshSubscription() }
        }
        .overlay {
            if viewModel.deletion == .deleting {
                ProgressView().controlSize(.large)
            }
        }
        .alert(String(localized: "Error", comment: "Error alert title"),
               isPresented: Binding(get: { viewModel.errorMessage != nil },
                                    set: { if !$0 { viewModel.clearError() } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .alert(String(localized: "Error", comment: "Error alert title"),
               isPresented: Binding(get: { manageError != nil },
                                    set: { if !$0 { manageError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(manageError ?? "")
        }
        .alert(String(localized: "Delete Account",
                      comment: "Account deletion confirmation title"),
               isPresented: isPresented(.confirming)) {
            Button(String(localized: "Cancel", comment: "Cancel button"),
                   role: .cancel) { viewModel.cancelDeletion() }
            Button(String(localized: "Delete", comment: "Confirm deletion button"),
                   role: .destructive) {
                Task { await viewModel.confirmDeletion() }
            }
        } message: {
            Text(String(localized: "This deletes your account and all of its data. This cannot be undone.",
                        comment: "Account deletion confirmation message"))
        }
        .alert(String(localized: "Confirm your password",
                      comment: "Reauthentication title"),
               isPresented: isPresented(.passwordRequired)) {
            SecureField(String(localized: "Password", comment: "Password field"),
                        text: $password)
            Button(String(localized: "Cancel", comment: "Cancel button"),
                   role: .cancel) {
                password = ""
                viewModel.cancelDeletion()
            }
            Button(String(localized: "Delete", comment: "Confirm deletion button"),
                   role: .destructive) {
                let entered = password
                password = ""
                Task { await viewModel.deleteAccount(reauthenticatingWith: .password(entered)) }
            }
        }
        .alert(String(localized: "Sign in again",
                      comment: "Reauthentication required title"),
               isPresented: isPresented(.reauthenticationUnsupported)) {
            Button("OK", role: .cancel) { viewModel.cancelDeletion() }
        } message: {
            Text(String(localized: "For your security, sign out and sign in again before deleting your account.",
                        comment: "Reauthentication required message"))
        }
        .alert(String(localized: "Account deleted",
                      comment: "Account deleted title"),
               isPresented: isPresented(.deleted)) {
            Button("OK", role: .cancel) { viewModel.acknowledgeDeletion() }
        } message: {
            Text(String(localized: "Your account and all of its data have been deleted.",
                        comment: "Account deleted message"))
        }
    }

    /// Binding for an alert tied to one deletion step.
    private func isPresented(_ step: AccountViewModel.DeletionStep) -> Binding<Bool> {
        Binding(get: { viewModel.deletion == step }, set: { _ in })
    }

    // MARK: - Controller focus

    /// The actionable rows of this screen. Not an index range: half of them
    /// come and go with the account state, so the order is derived from what
    /// is currently drawn rather than written down once.
    private enum AccountRow: Hashable {
        case signOut, discord, retroAchievements, subscription, pin, delete
    }

    private var visibleRows: [AccountRow] {
        var rows: [AccountRow] = [.signOut]
        // A row still resolving its link state has a spinner where its button
        // will be, so there is nothing to act on yet.
        if viewModel.discord != .checking { rows.append(.discord) }
        if viewModel.retroAchievements != .checking { rows.append(.retroAchievements) }
        if subscriptionAction != nil { rows.append(.subscription) }
        if isPinConfigured, pinAction != nil { rows.append(.pin) }
        rows.append(.delete)
        return rows
    }

    private func isFocused(_ row: AccountRow) -> Bool {
        guard let focused = scope.focused else { return false }
        return visibleRows.firstIndex(of: row) == focused
    }

    /// Nil only while the card is a spinner. Every other state has a button
    /// on it, so A always has something to do here.
    private var subscriptionAction: (() -> Void)? {
        guard !viewModel.isCheckingPro else { return nil }
        // Exactly the condition that draws the Manage button, so the row is
        // focusable whenever the card has a door to open.
        if viewModel.canManageSubscription {
            return { Task { await openSubscriptionManagement() } }
        }
        switch viewModel.pro {
        case .unlocked:
            // A lifetime or legacy unlock with no subscription behind it has
            // nothing to manage, but the card still carries Restore
            // Purchases -- and this row is a controller's only route to it.
            // The pro gate, which also offers Restore, is opened by this very
            // action, and an entitled user never trips a limit that would
            // open it any other way, so a non-focusable row here left a
            // controller-only legacy owner with no route to Restore at all.
            return { Task { await viewModel.restorePurchases() } }
        case .locked, .checking:
            return { gateReason = ProGateReason() }
        }
    }

    @MainActor
    private func openSubscriptionManagement() async {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else {
            manageError = String(localized: "Could not open subscription management.",
                                 comment: "Manage subscription failed")
            return
        }
        do {
            try await AppStore.showManageSubscriptions(in: scene)
            // The sheet is where a cancellation happens, so re-read on the way
            // back rather than waiting for the next launch.
            await viewModel.refreshSubscription()
            ProEntitlementStore.shared.refresh()
        } catch {
            manageError = String(localized: "Could not open subscription management.",
                                 comment: "Manage subscription failed")
            print("AccountTabView: showManageSubscriptions failed: \(error)")
        }
    }

    /// Nil while the PIN card is explaining itself or waiting on the server.
    private var pinAction: (() -> Void)? {
        switch pinViewModel.state {
        case .idle:
            return { Task { await pinViewModel.issue() } }
        case .issued:
            return {
                Task {
                    await pinViewModel.discard()
                    await pinViewModel.issue()
                }
            }
        default:
            return nil
        }
    }

    private func configureScope() {
        // Five alerts and a UIAlertController password prompt draw their own
        // selection, which the app cannot move, so A must not act on the row
        // behind them.
        scope.isBlocked = {
            viewModel.errorMessage != nil || viewModel.deletion != .idle
        }
        // B dismisses an open alert by cancelling the step it belongs to. The
        // account tab is a root, so with nothing open there is nothing left to
        // close.
        scope.onClose = {
            if viewModel.errorMessage != nil {
                viewModel.clearError()
                return true
            }
            switch viewModel.deletion {
            case .confirming, .passwordRequired:
                password = ""
                viewModel.cancelDeletion()
                return true
            case .reauthenticationUnsupported:
                viewModel.cancelDeletion()
                return true
            case .deleted:
                viewModel.acknowledgeDeletion()
                return true
            case .idle, .deleting:
                return false
            }
        }
        declareRows()
    }

    private func declareRows() {
        scope.setActions(visibleRows.map { row in
            { perform(row) }
        })
        scope.applyInitialFocus(controllerConnected: isControllerConnected)
    }

    private func perform(_ row: AccountRow) {
        switch row {
        case .signOut:
            viewModel.signOut()
        case .discord:
            if case .linked = viewModel.discord {
                Task { await viewModel.unlinkDiscord() }
            } else {
                viewModel.linkDiscord()
            }
        case .retroAchievements:
            if case .linked = viewModel.retroAchievements {
                viewModel.disconnectRetroAchievements()
            } else {
                presentRetroAchievementsLogin()
            }
        case .subscription:
            subscriptionAction?()
        case .pin:
            pinAction?()
        case .delete:
            viewModel.askToDeleteAccount()
        }
    }

    // MARK: - Profile

    private var profileCard: some View {
        VStack(spacing: 12) {
            avatar
            if let name = profile.displayName, !name.isEmpty {
                Text(name).font(.title3.bold())
            }
            if let email = profile.email, !email.isEmpty {
                Text(email).font(.subheadline).foregroundStyle(.secondary)
            }
            Button(String(localized: "Sign Out", comment: "Sign out button")) {
                viewModel.signOut()
            }
            .buttonStyle(.bordered)
            .controllerFocusRing(isFocused(.signOut), cornerRadius: 8)
            .id(AccountRow.signOut)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(Color.themeSurfaceContainerHigh)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var avatar: some View {
        let placeholder = Image(systemName: "person.circle.fill")
            .resizable()
            .foregroundStyle(.secondary)
        Group {
            if let url = profile.photoURL {
                AsyncImage(url: url) { image in
                    image.resizable()
                } placeholder: {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .scaledToFill()
        .frame(width: 96, height: 96)
        .clipShape(Circle())
    }

    // MARK: - Connected accounts

    private var discordRow: some View {
        connectionRow(
            isFocused: isFocused(.discord),
            title: String(localized: "Discord", comment: "Discord service name"),
            icon: "bubble.left.and.bubble.right.fill",
            state: viewModel.discord,
            connectTitle: String(localized: "Link", comment: "Link Discord button"),
            disconnectTitle: String(localized: "Unlink", comment: "Unlink Discord button"),
            connect: { viewModel.linkDiscord() },
            disconnect: { Task { await viewModel.unlinkDiscord() } })
    }

    private var retroAchievementsRow: some View {
        connectionRow(
            isFocused: isFocused(.retroAchievements),
            title: String(localized: "RetroAchievements",
                          comment: "RetroAchievements service name"),
            icon: "trophy.fill",
            state: viewModel.retroAchievements,
            connectTitle: String(localized: "Connect", comment: "Connect button"),
            disconnectTitle: String(localized: "Disconnect", comment: "Disconnect button"),
            connect: { presentRetroAchievementsLogin() },
            disconnect: { viewModel.disconnectRetroAchievements() })
    }

    private func connectionRow(isFocused: Bool, title: String, icon: String,
                               state: AccountViewModel.LinkState,
                               connectTitle: String, disconnectTitle: String,
                               connect: @escaping () -> Void,
                               disconnect: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(Color.themePrimary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                Text(statusText(state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            switch state {
            case .checking:
                ProgressView()
            case .linked:
                Button(disconnectTitle, role: .destructive, action: disconnect)
                    .buttonStyle(.bordered)
                    .foregroundStyle(Color.themeError)
            case .notLinked:
                Button(connectTitle, action: connect)
                    .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .controllerFocusRing(isFocused, base: Color.themeSurfaceContainerHigh)
    }

    private func statusText(_ state: AccountViewModel.LinkState) -> String {
        switch state {
        case .checking:
            return String(localized: "Checking...", comment: "Link state unknown")
        case .linked(let name):
            if let name = name, !name.isEmpty {
                return String(localized: "Linked", comment: "Link state linked")
                    + " \u{00B7} " + name
            }
            return String(localized: "Linked", comment: "Link state linked")
        case .notLinked:
            return String(localized: "Not linked", comment: "Link state not linked")
        }
    }

    /// The RetroAchievements login is still a UIKit form sheet.
    private func presentRetroAchievementsLogin() {
        guard let presenter = GameLauncher.topViewController() else { return }
        let controller = RetroAchievementsLoginViewController()
        controller.onLoginSuccess = { _ in
            Task { @MainActor in viewModel.refreshRetroAchievements() }
        }
        controller.modalPresentationStyle = .formSheet
        presenter.present(controller, animated: true)
    }

    // MARK: - Subscription

    private var subscriptionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(String(localized: "Pro", comment: "Pro card title"),
                  systemImage: "star.circle")
                .font(.headline)
            subscriptionContent
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .controllerFocusRing(isFocused(.subscription),
                             base: Color.themeSurfaceContainerHigh)
    }

    @ViewBuilder
    private var subscriptionContent: some View {
        if viewModel.isCheckingPro {
            // Never claim the entitlement is missing while StoreKit is still
            // deciding: a paying user would see a sales pitch.
            HStack(spacing: 8) {
                ProgressView()
                Text(String(localized: "Checking...", comment: "Subscription checking"))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        } else {
            // The headline names the route that granted Pro, so a legacy
            // buyer is thanked and is never told their Pro renews yearly.
            switch viewModel.pro {
            case .unlocked(.legacyPaid):
                Label(String(localized: "Lifetime Pro", comment: "Lifetime pro badge"),
                      systemImage: "checkmark.seal.fill")
                    .font(.subheadline)
                Text(String(localized: "Thank you for purchasing Yaba Sanshiro 2.",
                            comment: "Thanks shown to a legacy paid user"))
                    .font(.footnote).foregroundStyle(.secondary)
            case .unlocked(.lifetime):
                Label(String(localized: "Lifetime Pro", comment: "Lifetime pro badge"),
                      systemImage: "checkmark.seal.fill")
                    .font(.subheadline)
                Text(String(localized: "Pay once. Keep Pro forever.",
                            comment: "Lifetime offer explanation"))
                    .font(.footnote).foregroundStyle(.secondary)
            case .unlocked(.annual):
                Label(String(localized: "Pro Annual", comment: "Annual pro badge"),
                      systemImage: "checkmark.seal.fill")
                    .font(.subheadline)
                renewalNote
                    .font(.footnote).foregroundStyle(.secondary)
            case .locked, .checking:
                Text(String(localized: "Unlock unlimited games, cloud backup and cheats.",
                            comment: "Pro pitch in the account tab"))
                    .font(.subheadline).foregroundStyle(.secondary)
                Button(String(localized: "Upgrade to Pro", comment: "Upgrade button")) {
                    gateReason = ProGateReason()
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(Color.themeOnPrimary)
            }
            // The door is offered whenever a subscription is live, whatever
            // else grants Pro: a legacy user who bought one before their
            // legacy status resolved would otherwise have no way to cancel.
            if viewModel.canManageSubscription {
                manageSubscriptionButton
            }
            // Apple requires a restore control wherever purchases are shown,
            // and it is what recovers a lifetime unlock on a new device.
            Button(String(localized: "Restore Purchases",
                          comment: "Restore purchases button")) {
                Task { await viewModel.restorePurchases() }
            }
            .disabled(viewModel.isBusy)
        }
    }

    /// What happens to the subscription next. A subscriber who cancelled is
    /// still entitled until the period they paid for runs out, and telling
    /// them it renews would be the opposite of the truth. Unknown falls back
    /// to the neutral line: it is the state before StoreKit has answered, and
    /// inventing an expiry date there would be its own lie.
    @ViewBuilder
    private var renewalNote: some View {
        switch viewModel.subscriptionRenewal {
        case .expires(let date):
            // Composed through a placeholder, never concatenated: where the
            // date sits in the sentence differs by language.
            Text(String(format: String(localized: "Expires on %@",
                                       comment: "When a cancelled subscription runs out"),
                        date.formatted(date: .abbreviated, time: .omitted)))
        case .willRenew, .unknown:
            Text(String(localized: "Renews yearly", comment: "Annual renewal note"))
        }
    }

    // Cancelling and reading the renewal date happen on Apple's own screen,
    // and the route to it through Settings moves between iOS releases -- so
    // the app offers the door.
    private var manageSubscriptionButton: some View {
        Button(String(localized: "Manage Subscription",
                      comment: "Opens Apple's subscription management")) {
            Task { await openSubscriptionManagement() }
        }
        .buttonStyle(.borderedProminent)
        .foregroundStyle(Color.themeOnPrimary)
        .disabled(viewModel.isBusy)
    }

    // MARK: - Deletion

    private var deleteButton: some View {
        Button(role: .destructive) {
            viewModel.askToDeleteAccount()
        } label: {
            Text(String(localized: "Delete Account",
                        comment: "Delete account button"))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .foregroundStyle(Color.themeError)
        .controllerFocusRing(isFocused(.delete), cornerRadius: 8)
        .padding(.top, 8)
    }
}
