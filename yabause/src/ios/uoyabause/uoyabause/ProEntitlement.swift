import Combine
import Foundation

/// Whether this user may use everything the app can do.
///
/// Three purchases lead here and they are deliberately kept apart: the paid
/// app someone bought years ago, a lifetime unlock, and an annual
/// subscription. Every gate in the app asks this one type, so the restricted
/// features cannot drift apart from each other, and the rule that combines the
/// three lives in exactly one function.
struct ProEntitlement: Equatable {
    /// Where Pro came from. The settings screen names it; nothing gates on it.
    enum Source: Equatable {
        case legacyPaid
        case lifetime
        case annual
    }

    enum State: Equatable {
        case unlocked(Source)
        case locked
        /// StoreKit is still deciding. Not the same as locked.
        case checking
    }

    /// Matches Android's MAX_FREE_GAMES.
    static let freeGameLimit = 3
    /// Matches Android's PRO_MAX_BACKUP_COUNT.
    static let cloudSlotCount = 256

    /// The full app on the App Store, for the second offer in the Lite gate.
    static var fullAppURL: URL? {
        URL(string: "https://apps.apple.com/app/id1549144351")
    }

    /// True in the Lite build, which is the only build that carries ads.
    /// Injectable because the test target compiles as the full app, so a
    /// compile-time check alone would leave the ad behaviour untested.
    static var buildIsLite: Bool {
#if FREE_VERSION
        return true
#else
        return false
#endif
    }

    private let showsAdvertising: Bool
    private let legacy: LegacyStatus
    private let purchase: PurchaseStatus
    private let now: Date

    init(showsAdvertising: Bool = ProEntitlement.buildIsLite,
         legacy: LegacyStatus = LegacyPurchase.shared.status,
         purchase: PurchaseStatus = PurchaseManager.shared.purchaseStatus,
         now: Date = Date()) {
        self.showsAdvertising = showsAdvertising
        self.legacy = legacy
        self.purchase = purchase
        self.now = now
    }

    /// The one place the three routes are combined.
    ///
    /// A known entitlement wins immediately: a legacy user is Pro before
    /// StoreKit has said anything about subscriptions. Only when no route has
    /// granted anything does an outstanding answer matter.
    var state: State {
        if legacy == .legacyPaid { return .unlocked(.legacyPaid) }
        switch purchase {
        case .lifetime:
            return .unlocked(.lifetime)
        case .annual(let expiration) where expiration > now:
            return .unlocked(.annual)
        case .annual, .none, .unknown:
            break
        }
        if legacy == .unknown || purchase == .unknown { return .checking }
        return .locked
    }

    var source: Source? {
        if case .unlocked(let source) = state { return source }
        return nil
    }

    var isUnlocked: Bool { source != nil }

    /// Whether a gate should let the action through. Checking counts as yes:
    /// wrongly blocking a paying user costs more than letting one action
    /// through in the moment before StoreKit answers.
    var allowsAction: Bool { state != .locked }

    /// Whether to draw an ad. Checking counts as yes, the opposite default:
    /// almost every user of an ad-carrying build is a non-payer, so hiding
    /// ads until the answer arrives would lose their impressions.
    var showsAds: Bool { showsAdvertising && !isUnlocked }
}

/// Publishes the entitlement so the views holding it re-render the moment a
/// purchase lands, rather than at the next time they happen to be rebuilt.
@MainActor
final class ProEntitlementStore: ObservableObject {
    static let shared = ProEntitlementStore()

    @Published private(set) var entitlement = ProEntitlement()

    private var cancellables: Set<AnyCancellable> = []
    private var hasStarted = false
    private var isFirstActivation = true

    init() {
        PurchaseManager.shared.$purchaseStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        LegacyPurchase.shared.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    /// Kicks off the StoreKit work: the transaction listener, the first
    /// product request, and the first read of both entitlement sources.
    /// Called once from the app delegate rather than from init, so that
    /// merely mentioning the singleton does not start network traffic.
    func start() {
        hasStarted = true
        PurchaseManager.shared.start()
        Task { await LegacyPurchase.shared.refresh() }
    }

    /// Re-asks both sources, for when the app returns to the foreground.
    ///
    /// Separate from start() so the transaction listener is still installed
    /// exactly once. This is what closes a stuck `.checking`: if the launch
    /// read failed with nothing cached -- offline on a fresh reinstall --
    /// nothing else would ever re-query StoreKit, and every gate would stay
    /// permissive for the rest of the session.
    func recheck() {
        // The first activation follows start() by moments and its reads are
        // already in flight, so asking again there would only duplicate them.
        guard hasStarted, !isFirstActivation else {
            isFirstActivation = false
            return
        }
        Task {
            await PurchaseManager.shared.refresh()
            await LegacyPurchase.shared.refresh()
        }
    }

    /// Re-reads after a purchase or restore driven from outside the listener.
    func refresh() {
        entitlement = ProEntitlement()
    }
}
