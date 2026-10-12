import Foundation
import StoreKit

/// What the app needs out of an AppTransaction.
struct AppTransactionInfo: Equatable {
    /// On iOS this is the CFBundleVersion -- the build number -- the user
    /// first downloaded, not the marketing version.
    let originalAppVersion: String
    /// False in the sandbox, in TestFlight and under an Xcode StoreKit
    /// configuration, where originalAppVersion is always 1.0 and therefore
    /// says nothing about what the user bought.
    let isProduction: Bool
}

/// Reads the app transaction, behind a seam.
///
/// The seam exists because the sandbox always reports 1.0: without it, the
/// legacy path and the new-user path could not both be tested.
protocol AppTransactionProviding {
    /// The verified app transaction, or nil when it could not be verified.
    ///
    /// A transient failure -- no network, StoreKit unavailable -- is a thrown
    /// error, never nil. The caller treats the two very differently: an
    /// unverified transaction grants nothing, while a thrown error leaves an
    /// already-granted entitlement in place.
    func appTransaction() async throws -> AppTransactionInfo?
}

struct StoreKitAppTransaction: AppTransactionProviding {
    func appTransaction() async throws -> AppTransactionInfo? {
        let result = try await AppTransaction.shared
        switch result {
        case .unverified:
            return nil
        case .verified(let transaction):
            return AppTransactionInfo(
                originalAppVersion: transaction.originalAppVersion,
                isProduction: transaction.environment == .production)
        }
    }
}

/// Remembers what Apple last said, so a temporary StoreKit failure does not
/// revoke an entitlement Apple already confirmed.
///
/// Stores the evidence -- the version Apple reported -- rather than the
/// verdict. A stored verdict would go stale the day the boundary moves.
protocol LegacyEvidenceStoring {
    func load() -> AppTransactionInfo?
    func save(_ info: AppTransactionInfo)
}

struct KeychainLegacyEvidence: LegacyEvidenceStoring {
    /// Shares KeychainHelper's service name with the RetroAchievements
    /// credentials; the account name keeps the two apart.
    private static let key = "legacy_app_transaction"

    func load() -> AppTransactionInfo? {
        guard let raw = KeychainHelper.load(key: Self.key) else { return nil }
        let parts = raw.split(separator: "|", maxSplits: 1,
                              omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return nil }
        return AppTransactionInfo(originalAppVersion: String(parts[0]),
                                  isProduction: parts[1] == "1")
    }

    func save(_ info: AppTransactionInfo) {
        let raw = "\(info.originalAppVersion)|\(info.isProduction ? "1" : "0")"
        _ = KeychainHelper.save(key: Self.key, value: raw)
    }
}
