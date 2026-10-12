import Foundation
import Combine
import GoogleSignIn

/// Drives the cross-device sync card: issue a PIN, show it with a countdown,
/// and revoke it when the user leaves.
@MainActor
final class DevicePinViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case signInRequired
        case googleRequired
        case issuing
        case issued(String)
    }

    /// How long we tell the user the PIN is good for. The server enforces its
    /// own TTL, which we cannot read, so this is a display value only.
    static let displayValidity: TimeInterval = 5 * 60

    @Published private(set) var state: State = .idle
    @Published private(set) var expiresAt: Date?
    @Published private(set) var errorMessage: String?

    private let accountState: AccountState
    private let googleTokenProvider: () -> String?
    private let issuePinAction: (String) async throws -> String
    private let revokePinAction: (String) async -> Void

    init(accountState: AccountState,
         googleTokenProvider: @escaping () -> String? = {
             GIDSignIn.sharedInstance.currentUser?.idToken?.tokenString
         },
         issuePin: ((String) async throws -> String)? = nil,
         revokePin: ((String) async -> Void)? = nil) {
        self.accountState = accountState
        self.googleTokenProvider = googleTokenProvider
        let service = DevicePinService()
        self.issuePinAction = issuePin ?? { try await service.issuePin(googleIDToken: $0) }
        self.revokePinAction = revokePin ?? { await service.revokePinIgnoringErrors($0) }
        state = Self.initialState(for: accountState)
    }

    private static func initialState(for accountState: AccountState) -> State {
        if !accountState.isSignedIn { return .signInRequired }
        if !accountState.isGoogleLinked { return .googleRequired }
        return .idle
    }

    func issue() async {
        guard accountState.isSignedIn else {
            state = .signInRequired
            return
        }
        guard accountState.isGoogleLinked else {
            state = .googleRequired
            return
        }
        guard let token = googleTokenProvider() else {
            // The Google session can lapse even when Firebase still has a user.
            errorMessage = String(localized: "Sign in with Google again to create a PIN.",
                                  comment: "PIN needs a fresh Google session")
            return
        }

        state = .issuing
        do {
            let pin = try await issuePinAction(token)
            expiresAt = Date().addingTimeInterval(Self.displayValidity)
            state = .issued(pin)
        } catch {
            state = .idle
            errorMessage = String(localized: "Could not create a PIN.",
                                  comment: "PIN issue error")
            print("DevicePinViewModel: issue failed: \(error)")
        }
    }

    /// Revokes the PIN so it cannot be redeemed after the user leaves.
    /// The Android card skips this, leaving PINs alive until the server TTL.
    func discard() async {
        if case .issued(let pin) = state {
            await revokePinAction(pin)
        }
        expiresAt = nil
        state = Self.initialState(for: accountState)
    }

    func remainingSeconds(at now: Date) -> Int {
        guard let expiresAt = expiresAt else { return 0 }
        return max(0, Int(expiresAt.timeIntervalSince(now)))
    }

    func clearError() {
        errorMessage = nil
    }
}
