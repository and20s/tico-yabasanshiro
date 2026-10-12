import StoreKit
import StoreKitTest
import XCTest
@testable import YabaSnashiro

/// Drives the real StoreKit APIs against the bundled configuration file, so
/// the purchase, expiry and refund paths are exercised rather than mocked.
///
/// Every assertion reads PurchaseManager.currentStatus(), which computes the
/// answer and returns it. Nothing here reads the published purchaseStatus: the
/// test host is the app, so AppDelegate has installed a process-lifetime
/// Transaction.updates listener that refreshes that property on its own
/// schedule, and a test that asserted on it would be racing that listener.
final class PurchaseManagerTests: XCTestCase {
    private var session: SKTestSession!

    /// Named once so the skip and the compiler guards cannot drift apart.
    private static let needsIOS17 =
        "SKTestSession.buyProduct(identifier:) requires iOS 17; this simulator is older, "
        + "so the purchase, expiry and refund gates were not exercised."

    override func setUp() async throws {
        try await super.setUp()
        // A runtime skip rather than @available on the class: an availability
        // attribute would hide these tests from an older simulator and let the
        // run report success over nothing.
        guard #available(iOS 17.0, *) else { throw XCTSkip(Self.needsIOS17) }
        session = try SKTestSession(configurationFileNamed: "YabaSanshiro")
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
    }

    override func tearDown() async throws {
        session?.clearTransactions()
        session = nil
        // The store is empty again, so leave the singleton saying so too.
        // The update listener converges on the same answer; this only makes
        // the moment it happens deterministic for whatever runs next.
        await PurchaseManager.shared.refresh()
        try await super.tearDown()
    }

    /// The ids in the configuration file have to be the ids the app asks for,
    /// or the gate has nothing to show.
    func testTheStoreReturnsBothProducts() async throws {
        let products = try await Product.products(for: ProProducts.all)
        XCTAssertEqual(Set(products.map(\.id)), Set(ProProducts.all))
    }

    /// Proves the local configuration file answered, not the sandbox: these
    /// names and prices exist only in YabaSanshiro.storekit.
    func testTheProductsComeFromTheLocalConfigurationFile() async throws {
        let products = try await Product.products(for: ProProducts.all)
        let byID = Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0) })
        let annual = try XCTUnwrap(byID[ProProducts.annual])
        XCTAssertEqual(annual.displayName, "Pro Annual")
        XCTAssertEqual(annual.price, Decimal(string: "1.99"))
        let lifetimeID = try XCTUnwrap(ProProducts.lifetime)
        let lifetime = try XCTUnwrap(byID[lifetimeID])
        XCTAssertEqual(lifetime.displayName, "Lifetime Pro")
        XCTAssertEqual(lifetime.price, Decimal(string: "4.99"))
    }

    func testNothingBoughtMeansNoEntitlement() async {
        let status = await PurchaseManager.shared.currentStatus()
        XCTAssertEqual(status, .none)
        XCTAssertFalse(status.entitles())
    }

    /// Case 4.
    func testBuyingTheAnnualSubscriptionEntitles() async throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip(Self.needsIOS17) }
        try await session.buyProduct(identifier: ProProducts.annual)
        let status = await PurchaseManager.shared.currentStatus()
        guard case .annual(let expiration) = status else {
            return XCTFail("expected an annual entitlement, got \(status)")
        }
        XCTAssertGreaterThan(expiration, Date())
        XCTAssertTrue(status.entitles())
    }

    /// Case 5.
    func testAnExpiredSubscriptionNoLongerEntitles() async throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip(Self.needsIOS17) }
        try await session.buyProduct(identifier: ProProducts.annual)
        try session.expireSubscription(productIdentifier: ProProducts.annual)
        let status = await PurchaseManager.shared.currentStatus()
        XCTAssertEqual(status, .none)
        XCTAssertFalse(status.entitles())
    }

    func testBuyingLifetimeEntitles() async throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip(Self.needsIOS17) }
        let lifetime = try XCTUnwrap(ProProducts.lifetime)
        try await session.buyProduct(identifier: lifetime)
        let status = await PurchaseManager.shared.currentStatus()
        XCTAssertEqual(status, .lifetime)
        XCTAssertTrue(status.entitles())
    }

    /// Lifetime is what the settings screen names when a user holds both.
    func testLifetimeOutranksTheSubscription() async throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip(Self.needsIOS17) }
        let lifetime = try XCTUnwrap(ProProducts.lifetime)
        try await session.buyProduct(identifier: ProProducts.annual)
        try await session.buyProduct(identifier: lifetime)
        let status = await PurchaseManager.shared.currentStatus()
        XCTAssertEqual(status, .lifetime)
    }

    /// A refunded lifetime purchase must stop entitling.
    func testARefundedLifetimePurchaseStopsEntitling() async throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip(Self.needsIOS17) }
        let lifetime = try XCTUnwrap(ProProducts.lifetime)
        try await session.buyProduct(identifier: lifetime)
        let transaction = try XCTUnwrap(session.allTransactions()
            .first { $0.productIdentifier == lifetime })
        try session.refundTransaction(identifier: transaction.identifier)
        let status = await PurchaseManager.shared.currentStatus()
        XCTAssertEqual(status, .none)
        XCTAssertFalse(status.entitles())
    }
}
