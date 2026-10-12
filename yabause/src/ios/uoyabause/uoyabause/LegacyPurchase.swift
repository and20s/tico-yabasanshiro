import Combine
import Foundation

/// Whether this user bought the app back when it cost money.
///
/// Apple's own recommendation for a business model change: the app transaction
/// carries the version the user first downloaded, so a build number from
/// before the app went free identifies a paying customer without any server of
/// our own.
///
/// Not marked @MainActor as a whole. ProEntitlement reads `status` from
/// contexts that are not main-actor isolated, and isolating the class would
/// force every one of those call sites to change.
final class LegacyPurchase: ObservableObject {
    static let shared = LegacyPurchase()

    @Published private(set) var status: LegacyStatus

    private let provider: AppTransactionProviding
    private let evidence: LegacyEvidenceStoring

    /// How many times refresh() asks the provider before settling on unknown,
    /// and how long it waits between attempts. Bounded, because a device that
    /// is simply offline must not spin; retried at all, because settling on
    /// unknown after one failed call leaves every gate permissive for the
    /// whole session -- nothing else re-queries StoreKit until the app is
    /// foregrounded again.
    private let retryAttempts: Int
    private let retryDelay: TimeInterval

    /// Reads the cache but never touches StoreKit: a singleton that made a
    /// network call the moment it was first mentioned would be impossible to
    /// reason about. Call refresh() to ask Apple.
    init(provider: AppTransactionProviding = StoreKitAppTransaction(),
         evidence: LegacyEvidenceStoring = KeychainLegacyEvidence(),
         retryAttempts: Int = 3,
         retryDelay: TimeInterval = 0.5) {
        self.provider = provider
        self.evidence = evidence
        self.retryAttempts = max(1, retryAttempts)
        self.retryDelay = retryDelay
        if let cached = evidence.load() {
            self.status = Self.verdict(for: cached)
        } else {
            self.status = .unknown
        }
    }

    /// Asks Apple. Called at launch, again when the app returns to the
    /// foreground, and from Restore Purchases.
    @MainActor
    func refresh() async {
        for attempt in 1...retryAttempts {
            do {
                guard let info = try await provider.appTransaction() else {
                    // Unverified can never grant the entitlement, but it also
                    // must not take it away: fall back to the cache exactly like
                    // a transient failure does. That is safe because the cache
                    // is only ever written from a verified production read, so
                    // resolving from it here still cannot grant anything an
                    // unverified answer alone would not have. With nothing
                    // cached there is nothing to grant, so it resolves to
                    // notLegacy, not unknown -- unknown would leave every gate
                    // permissive.
                    if let cached = evidence.load() {
                        status = Self.verdict(for: cached)
                    } else {
                        status = .notLegacy
                    }
                    return
                }
                guard info.isProduction else {
                    status = Self.nonProductionStatus()
                    return
                }
                // A fresh verified answer always wins, including a negative one:
                // a device that changed Apple ID must stop resolving from the
                // previous owner's evidence.
                evidence.save(info)
                status = Self.verdict(for: info)
                return
            } catch {
                // A temporary StoreKit or network failure must not revoke an
                // entitlement Apple already confirmed. With evidence cached the
                // answer is already known, so there is nothing to retry for.
                if let cached = evidence.load() {
                    status = Self.verdict(for: cached)
                    return
                }
                // Nothing cached, so unknown would be the answer for the rest
                // of the session. Worth a few more asks first.
                if attempt < retryAttempts {
                    try? await Task.sleep(
                        nanoseconds: UInt64(retryDelay * Double(attempt) * 1_000_000_000))
                    continue
                }
                status = .unknown
            }
        }
    }

    private static func verdict(for info: AppTransactionInfo) -> LegacyStatus {
        guard info.isProduction else { return nonProductionStatus() }
        guard let isBefore = BuildNumber
            .isBeforeFreeBusinessModel(info.originalAppVersion) else {
            // Unreadable. Never guess in the user's favour here: the guess
            // would be permanent.
            return .notLegacy
        }
        return isBefore ? .legacyPaid : .notLegacy
    }

    private static func nonProductionStatus() -> LegacyStatus {
#if DEBUG
        // Debug builds only, so both paths can be walked in the simulator
        // where StoreKit always reports 1.0. This is never compiled into a
        // release build: no shipped build can grant itself the entitlement.
        return ProcessInfo.processInfo.arguments.contains("-simulateLegacyPaidUser")
            ? .legacyPaid : .notLegacy
#else
        // TestFlight runs against the sandbox, where originalAppVersion is
        // always 1.0. Believing it would make every tester a Pro user and
        // leave the free path untested.
        return .notLegacy
#endif
    }
}
