//
//  PurchaseManager.swift
//  YabaSnashiro
//

import Combine
import Foundation
import StoreKit

/// Owns everything the app buys: the annual subscription and the lifetime
/// unlock.
///
/// Not marked @MainActor as a whole. ProEntitlement reads `purchaseStatus`
/// from contexts that are not main-actor isolated, and isolating the class
/// would force every one of those call sites to change.
final class PurchaseManager: ObservableObject {
    static let shared = PurchaseManager()

    /// Starts undecided: reporting .none before StoreKit answers would show a
    /// paying user the upgrade pitch.
    @Published private(set) var purchaseStatus: PurchaseStatus = .unknown
    @Published private(set) var products: [Product] = []

    private var updateListenerTask: Task<Void, Never>?

    private init() {}

    deinit {
        updateListenerTask?.cancel()
    }

    /// Begins listening for purchases made outside this process -- renewals,
    /// refunds, and purchases made on another device. Called once at launch.
    func start() {
        guard updateListenerTask == nil else { return }
        updateListenerTask = Task { [weak self] in
            for await _ in Transaction.updates {
                // Every kind of update -- purchase, renewal, expiry, refund,
                // revocation -- is answered the same way: ask StoreKit what
                // the user is entitled to now.
                await self?.refresh()
            }
        }
        Task {
            await requestProducts()
            await refresh()
        }
    }

    @MainActor
    func requestProducts() async {
        do {
            products = try await Product.products(for: ProProducts.all)
        } catch {
            print("PurchaseManager: product request failed: \(error)")
        }
    }

    /// What StoreKit says this user owns right now.
    ///
    /// Pure: it asks StoreKit and returns the answer without touching any
    /// property, so asking the question is separate from publishing it. That
    /// keeps the rule testable without observing state the update listener is
    /// also writing.
    func currentStatus() async -> PurchaseStatus {
        var found: PurchaseStatus = .none
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.revocationDate == nil else { continue }
            if let lifetime = ProProducts.lifetime,
               transaction.productID == lifetime {
                // Nothing outranks lifetime, so stop looking.
                found = .lifetime
                break
            }
            guard transaction.productID == ProProducts.annual,
                  let expiration = transaction.expirationDate else { continue }
            if case .annual(let existing) = found, existing >= expiration {
                continue
            }
            found = .annual(expiration: expiration)
        }
        return found
    }

    /// Recomputes what the user owns and publishes it.
    ///
    /// Assigns once, at the end. Assigning .unknown at the top would flip a
    /// paying user back to "checking" on every refresh, which the gates and
    /// the ad slot both react to.
    @MainActor
    func refresh() async {
        purchaseStatus = await currentStatus()
    }

    func purchase(_ product: Product) async throws -> Transaction? {
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            guard case .verified(let transaction) = verification else {
                throw StoreError.failedVerification
            }
            await transaction.finish()
            await refresh()
            return transaction
        case .userCancelled, .pending:
            return nil
        @unknown default:
            return nil
        }
    }

    /// Re-evaluates every route to Pro. The legacy entitlement is refreshed
    /// here too, so one control answers all three questions the user is
    /// really asking when they tap Restore.
    @MainActor
    func restorePurchases() async {
        try? await AppStore.sync()
        await refresh()
        await LegacyPurchase.shared.refresh()
    }
}

enum StoreError: Error {
    case failedVerification
}
