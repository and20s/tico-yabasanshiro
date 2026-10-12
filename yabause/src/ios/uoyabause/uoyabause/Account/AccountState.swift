import Foundation
import Combine
import FirebaseAuth

/// The signed-in user, flattened so views and tests never touch Firebase types.
struct AccountProfile: Equatable {
    let userId: String
    let displayName: String?
    let email: String?
    let photoURL: URL?
    /// Firebase provider ids, e.g. "google.com" or "apple.com".
    let providers: [String]
}

/// The authentication seam, so AccountState can be tested without Firebase.
///
/// Main-actor isolated: Firebase delivers auth callbacks on the main thread,
/// and isolating the whole protocol lets the handler assign to AccountState
/// synchronously instead of hopping through a Task.
@MainActor
protocol AccountAuthProviding {
    var currentProfile: AccountProfile? { get }
    func observe(_ handler: @escaping (AccountProfile?) -> Void)
    func stopObserving()
    func signOut() throws
}

/// Publishes the signed-in user. Replaces the manual
/// addStateDidChangeListener plus child-swapping in AccountHostViewController.
@MainActor
final class AccountState: ObservableObject {
    @Published private(set) var profile: AccountProfile?

    private let provider: AccountAuthProviding

    init(provider: AccountAuthProviding = FirebaseAccountAuthProvider()) {
        self.provider = provider
        profile = provider.currentProfile
        provider.observe { [weak self] profile in
            self?.profile = profile
        }
    }

    var isSignedIn: Bool { profile != nil }

    /// The cross-device PIN carries a Google token, so it is only available to
    /// accounts that signed in with Google.
    var isGoogleLinked: Bool {
        profile?.providers.contains("google.com") ?? false
    }

    func signOut() throws {
        try provider.signOut()
    }
}

struct FirebaseAccountAuthProvider: AccountAuthProviding {
    private static var handle: AuthStateDidChangeListenerHandle?

    /// The type holds no instance state, so constructing it needs no actor.
    /// This lets it stay the default argument of AccountState.init, which is
    /// evaluated in a nonisolated context.
    nonisolated init() {}

    var currentProfile: AccountProfile? {
        Self.profile(from: Auth.auth().currentUser)
    }

    func observe(_ handler: @escaping (AccountProfile?) -> Void) {
        Self.handle = Auth.auth().addStateDidChangeListener { _, user in
            // Firebase documents this callback as main-thread, but the
            // compiler cannot see that, so state it explicitly.
            MainActor.assumeIsolated {
                handler(Self.profile(from: user))
            }
        }
    }

    func stopObserving() {
        if let handle = Self.handle {
            Auth.auth().removeStateDidChangeListener(handle)
            Self.handle = nil
        }
    }

    func signOut() throws {
        try Auth.auth().signOut()
    }

    private static func profile(from user: User?) -> AccountProfile? {
        guard let user = user else { return nil }
        return AccountProfile(userId: user.uid,
                              displayName: user.displayName,
                              email: user.email,
                              photoURL: user.photoURL,
                              providers: user.providerData.map(\.providerID))
    }
}
