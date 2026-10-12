import Foundation

/// The paid app purchase, derived from AppTransaction.
///
/// Separate from the in-app purchases because it is a different question with
/// a different answer source: not "what did this user buy inside the app" but
/// "which build did this user first download".
enum LegacyStatus: Equatable {
    /// StoreKit has not answered yet. Not the same as notLegacy.
    case unknown
    case legacyPaid
    case notLegacy
}

/// The in-app purchases, derived from Transaction.currentEntitlements.
///
/// Lifetime outranks annual: a user who owns both is shown as lifetime,
/// because that is the entitlement that will outlive the other.
enum PurchaseStatus: Equatable {
    /// StoreKit has not answered yet. Not the same as none.
    case unknown
    case none
    case lifetime
    case annual(expiration: Date)
}

extension PurchaseStatus {
    /// Whether this status entitles the user at `date`.
    ///
    /// The rule lives on the status rather than on PurchaseManager so it can
    /// be applied to an answer that was never published anywhere.
    func entitles(at date: Date = Date()) -> Bool {
        switch self {
        case .lifetime: return true
        case .annual(let expiration): return expiration > date
        case .none, .unknown: return false
        }
    }
}
