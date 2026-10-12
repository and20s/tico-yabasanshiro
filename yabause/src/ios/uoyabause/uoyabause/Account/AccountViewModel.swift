import Foundation
import Combine
import FirebaseAuth
import FirebaseCore
import FirebaseDatabase
import FirebaseFirestore
import FirebaseStorage
import GoogleSignIn

/// Firestore lookup for the Discord link, behind a seam so the view model
/// can be tested without a network.
@MainActor
protocol DiscordLinkStoring {
    func isLinked(userId: String) async throws -> Bool
    func unlink(userId: String) async throws
}

/// The link lives in discord_links/{uid}, field discord_id -- the same
/// document the legacy profile screen read and deleted.
struct FirestoreDiscordLinkStore: DiscordLinkStoring {
    nonisolated init() {}

    func isLinked(userId: String) async throws -> Bool {
        let document = try await Firestore.firestore()
            .collection("discord_links").document(userId).getDocument()
        guard document.exists,
              let discordId = document.data()?["discord_id"] as? String else {
            return false
        }
        return !discordId.isEmpty
    }

    func unlink(userId: String) async throws {
        try await Firestore.firestore()
            .collection("discord_links").document(userId).delete()
    }
}

/// RetroAchievements sign-in state, behind a seam for tests.
@MainActor
protocol RetroAchievementsStatusProviding {
    var isLoggedIn: Bool { get }
    var username: String? { get }
    func signOut()
}

struct LiveRetroAchievementsStatus: RetroAchievementsStatusProviding {
    nonisolated init() {}

    var isLoggedIn: Bool {
        RetroAchievementsManager.initialize()
        return RetroAchievementsAuthManager.shared.isRetroAchievementsLoggedIn
    }

    var username: String? {
        RetroAchievementsAuthManager.shared.currentUsername
    }

    func signOut() {
        RetroAchievementsAuthManager.shared.logoutRetroAchievements()
    }
}

/// What Apple says will happen to a live annual subscription next.
///
/// Cancelled is not the same as gone: the subscription stays valid to the end
/// of the period that was paid for, and until then the card must say when it
/// runs out rather than that it renews.
enum SubscriptionRenewal: Equatable {
    /// No subscription, or nothing known about one yet. The card says
    /// nothing about a date; it must never guess one.
    case unknown
    case willRenew
    /// Cancelled, still valid until this date.
    case expires(Date)
}

/// The Pro entitlement, behind a seam for tests.
@MainActor
protocol ProStatusProviding {
    /// Re-reads StoreKit. Returns .checking only while it cannot decide.
    func currentState() async -> ProEntitlement.State

    /// Whether an annual subscription is live right now, whichever route
    /// happens to grant Pro. A legacy user who bought a subscription by
    /// mistake still holds one, and it is only cancellable if we say so.
    /// Read after currentState(), which is what refreshes it.
    var hasActiveSubscription: Bool { get }

    /// Whether that subscription is still set to renew, and when it turns
    /// over if it is not. Asked separately from `currentState()` because it
    /// is a second round trip to StoreKit, and only the annual line uses it.
    func currentRenewal() async -> SubscriptionRenewal

    func restore() async
}

struct StoreKitProStatus: ProStatusProviding {
    nonisolated init() {}

    func currentState() async -> ProEntitlement.State {
        // Force a fresh read: both sources start out undecided.
        await PurchaseManager.shared.refresh()
        await LegacyPurchase.shared.refresh()
        return ProEntitlement().state
    }

    var hasActiveSubscription: Bool {
        guard case .annual(let expiration) = PurchaseManager.shared.purchaseStatus
        else { return false }
        return expiration > Date()
    }

    /// Reads Product.SubscriptionInfo.Status, which is the only place that
    /// says whether a live subscription has been cancelled: a cancelled one
    /// is still in `currentEntitlements` until it lapses, so the transaction
    /// alone cannot tell the two apart.
    func currentRenewal() async -> SubscriptionRenewal {
        guard case .annual(let expiration) = PurchaseManager.shared.purchaseStatus,
              expiration > Date() else { return .unknown }
        if PurchaseManager.shared.products.isEmpty {
            await PurchaseManager.shared.requestProducts()
        }
        guard let subscription = PurchaseManager.shared.products
            .first(where: { $0.id == ProProducts.annual })?.subscription,
              let statuses = try? await subscription.status else { return .unknown }
        for status in statuses {
            // A lapsed or revoked row says nothing about the subscription
            // this user is holding right now.
            guard status.state != .expired, status.state != .revoked,
                  case .verified(let renewal) = status.renewalInfo else { continue }
            return renewal.willAutoRenew ? .willRenew : .expires(expiration)
        }
        return .unknown
    }

    func restore() async {
        await PurchaseManager.shared.restorePurchases()
    }
}

/// How the user proves who they are before the account is deleted.
/// Firebase refuses a delete on a stale session.
enum AccountReauthentication: Equatable {
    case google
    case password(String)
}

enum AccountDeletionError: Error {
    case notSignedIn
    case missingCredential
}

/// Deletes the account and everything attached to it, behind a seam so the
/// view model can be tested without Firebase.
@MainActor
protocol AccountDeleting {
    func deleteAccount(reauthenticatingWith method: AccountReauthentication) async throws
}

/// Same order as the legacy profile screen: Realtime Database, the two
/// Firestore documents, Storage, then the Firebase user itself.
struct FirebaseAccountDeleter: AccountDeleting {
    nonisolated init() {}

    func deleteAccount(reauthenticatingWith method: AccountReauthentication) async throws {
        guard let user = Auth.auth().currentUser else {
            throw AccountDeletionError.notSignedIn
        }
        let credential = try await credential(for: method, user: user)
        _ = try await user.reauthenticate(with: credential)

        let userId = user.uid
        try await removeUserPosts(userId: userId)
        let firestore = Firestore.firestore()
        try await firestore.collection("users").document(userId).delete()
        try await firestore.collection("discord_links").document(userId).delete()
        // Storage cleanup is best effort, as it was in the legacy screen:
        // a leftover file must not block deleting the account itself.
        await deleteStorageTree(Storage.storage().reference().child(userId))
        try await user.delete()
    }

    private func credential(for method: AccountReauthentication,
                            user: User) async throws -> AuthCredential {
        switch method {
        case .password(let password):
            guard let email = user.email else {
                throw AccountDeletionError.missingCredential
            }
            return EmailAuthProvider.credential(withEmail: email, password: password)
        case .google:
            guard let clientID = FirebaseApp.app()?.options.clientID,
                  let presenter = GameLauncher.topViewController() else {
                throw AccountDeletionError.missingCredential
            }
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
            let result: GIDSignInResult = try await withCheckedThrowingContinuation { continuation in
                GIDSignIn.sharedInstance.signIn(withPresenting: presenter) { result, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else if let result = result {
                        continuation.resume(returning: result)
                    } else {
                        continuation.resume(throwing: AccountDeletionError.missingCredential)
                    }
                }
            }
            guard let idToken = result.user.idToken?.tokenString else {
                throw AccountDeletionError.missingCredential
            }
            return GoogleAuthProvider.credential(
                withIDToken: idToken,
                accessToken: result.user.accessToken.tokenString)
        }
    }

    private func removeUserPosts(userId: String) async throws {
        let reference = Database.database().reference(withPath: "/user-posts/\(userId)")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            reference.removeValue { error, _ in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Deletes every file under the reference, recursing into subfolders.
    private func deleteStorageTree(_ reference: StorageReference) async {
        guard let result = try? await reference.listAll() else { return }
        for item in result.items {
            try? await item.delete()
        }
        for prefix in result.prefixes {
            await deleteStorageTree(prefix)
        }
    }
}

/// Drives the connected-accounts and subscription parts of the account tab.
/// The signed-in user itself comes from AccountState.
@MainActor
final class AccountViewModel: ObservableObject {
    enum LinkState: Equatable {
        /// Still asking the backing store.
        case checking
        /// Linked, with the account name when the provider exposes one.
        case linked(String?)
        case notLinked
    }

    /// Where the account-deletion flow currently stands.
    enum DeletionStep: Equatable {
        case idle
        /// Waiting for the user to confirm they mean it.
        case confirming
        /// The account signs in with a provider we cannot silently refresh.
        case reauthenticationUnsupported
        /// Waiting for the password of an email/password account.
        case passwordRequired
        case deleting
        case deleted
    }

    /// Discord notification names posted by DiscordOAuthRedirectHandler.
    static let discordLinkSuccess = Notification.Name("discordLinkSuccess")
    static let discordLinkFailure = Notification.Name("discordLinkFailure")

    @Published private(set) var discord: LinkState = .checking
    @Published private(set) var retroAchievements: LinkState = .checking
    /// Which purchase granted Pro, or that none has. The account tab names it.
    @Published private(set) var pro: ProEntitlement.State = .checking

    /// Whether Apple's subscription management screen has anything to show.
    /// Tracked apart from `pro` because the two can disagree: a legacy paid
    /// user is .unlocked(.legacyPaid) and may still hold a subscription.
    @Published private(set) var hasActiveSubscription = false

    /// What happens to that subscription next. Unknown until StoreKit says,
    /// and the card falls back to the neutral line rather than claiming a
    /// renewal that may have been cancelled.
    @Published private(set) var subscriptionRenewal: SubscriptionRenewal = .unknown
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var deletion: DeletionStep = .idle

    private let accountState: AccountState
    private let discordStore: DiscordLinkStoring
    private let retroStatus: RetroAchievementsStatusProviding
    private let proStatus: ProStatusProviding
    private let deleter: AccountDeleting
    private var observers: [NSObjectProtocol] = []

    init(accountState: AccountState,
         discordStore: DiscordLinkStoring = FirestoreDiscordLinkStore(),
         retroStatus: RetroAchievementsStatusProviding = LiveRetroAchievementsStatus(),
         proStatus: ProStatusProviding = StoreKitProStatus(),
         deleter: AccountDeleting = FirebaseAccountDeleter()) {
        self.accountState = accountState
        self.discordStore = discordStore
        self.retroStatus = retroStatus
        self.proStatus = proStatus
        self.deleter = deleter
        observeDiscordNotifications()
    }

    deinit {
        let center = NotificationCenter.default
        for observer in observers {
            center.removeObserver(observer)
        }
    }

    var isPro: Bool {
        if case .unlocked = pro { return true }
        return false
    }

    /// True while StoreKit has not answered. Callers must not claim the
    /// entitlement is missing while this holds.
    var isCheckingPro: Bool { pro == .checking }

    /// Whether to offer the door to Apple's subscription management. Never
    /// gated on the source: someone who bought a subscription they did not
    /// need must still be able to cancel it.
    var canManageSubscription: Bool {
        if case .unlocked(.annual) = pro { return true }
        return hasActiveSubscription
    }

    // MARK: - Refresh

    func refresh() async {
        refreshRetroAchievements()
        await refreshDiscord()
        await refreshSubscription()
    }

    func refreshDiscord() async {
        guard let userId = accountState.profile?.userId else {
            discord = .notLinked
            return
        }
        do {
            discord = try await discordStore.isLinked(userId: userId)
                ? .linked(nil) : .notLinked
        } catch {
            discord = .notLinked
            print("AccountViewModel: discord lookup failed: \(error)")
        }
    }

    func refreshRetroAchievements() {
        retroAchievements = retroStatus.isLoggedIn
            ? .linked(retroStatus.username) : .notLinked
    }

    func refreshSubscription() async {
        pro = await proStatus.currentState()
        hasActiveSubscription = proStatus.hasActiveSubscription
        subscriptionRenewal = await proStatus.currentRenewal()
    }

    // MARK: - Actions

    /// Opens the Discord OAuth flow in Safari. The result comes back through
    /// the discordLinkSuccess / discordLinkFailure notifications.
    func linkDiscord() {
        DiscordAuthManager().startDiscordLogin()
    }

    func unlinkDiscord() async {
        guard let userId = accountState.profile?.userId else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await discordStore.unlink(userId: userId)
            discord = .notLinked
        } catch {
            errorMessage = String(localized: "Could not unlink Discord.",
                                  comment: "Discord unlink error")
            print("AccountViewModel: discord unlink failed: \(error)")
        }
    }

    func disconnectRetroAchievements() {
        retroStatus.signOut()
        refreshRetroAchievements()
    }

    func restorePurchases() async {
        isBusy = true
        await proStatus.restore()
        await refreshSubscription()
        isBusy = false
    }

    func signOut() {
        do {
            try accountState.signOut()
            discord = .notLinked
        } catch {
            errorMessage = String(localized: "Could not sign out.",
                                  comment: "Sign out error")
            print("AccountViewModel: sign out failed: \(error)")
        }
    }

    func clearError() {
        errorMessage = nil
    }

    // MARK: - Account deletion

    func askToDeleteAccount() {
        deletion = .confirming
    }

    func cancelDeletion() {
        deletion = .idle
    }

    /// The user confirmed. Pick the reauthentication the provider supports.
    func confirmDeletion() async {
        let providers = accountState.profile?.providers ?? []
        if providers.contains("google.com") {
            await deleteAccount(reauthenticatingWith: .google)
        } else if providers.contains("password") {
            deletion = .passwordRequired
        } else {
            // Apple-only accounts: the legacy screen told the user to sign
            // out and back in, and so do we.
            deletion = .reauthenticationUnsupported
        }
    }

    func deleteAccount(reauthenticatingWith method: AccountReauthentication) async {
        deletion = .deleting
        do {
            try await deleter.deleteAccount(reauthenticatingWith: method)
            deletion = .deleted
        } catch {
            deletion = .idle
            errorMessage = String(localized: "Could not delete the account.",
                                  comment: "Account deletion error")
            print("AccountViewModel: account deletion failed: \(error)")
        }
    }

    func acknowledgeDeletion() {
        deletion = .idle
    }

    // MARK: - Notifications

    private func observeDiscordNotifications() {
        let center = NotificationCenter.default
        let refreshOnPost: (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in await self?.refreshDiscord() }
        }
        observers.append(center.addObserver(forName: Self.discordLinkSuccess,
                                           object: nil, queue: .main,
                                           using: refreshOnPost))
        observers.append(center.addObserver(forName: Self.discordLinkFailure,
                                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.errorMessage = String(localized: "Could not link Discord.",
                                            comment: "Discord link error")
                await self?.refreshDiscord()
            }
        })
    }
}
