import XCTest
@testable import YabaSnashiro

final class ProEntitlementTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entitlement(ads: Bool = false,
                             legacy: LegacyStatus = .notLegacy,
                             purchase: PurchaseStatus = .none) -> ProEntitlement {
        ProEntitlement(showsAdvertising: ads, legacy: legacy,
                       purchase: purchase, now: now)
    }

    private var future: PurchaseStatus {
        .annual(expiration: now.addingTimeInterval(86_400))
    }

    private var past: PurchaseStatus {
        .annual(expiration: now.addingTimeInterval(-86_400))
    }

    // MARK: - The three routes to Pro

    /// Case 1 and 2: the user bought the paid app.
    func testALegacyPaidUserIsUnlocked() {
        XCTAssertEqual(entitlement(legacy: .legacyPaid).state, .unlocked(.legacyPaid))
    }

    /// Case 4.
    func testAnActiveAnnualSubscriptionIsUnlocked() {
        XCTAssertEqual(entitlement(purchase: future).state, .unlocked(.annual))
    }

    func testALifetimePurchaseIsUnlocked() {
        XCTAssertEqual(entitlement(purchase: .lifetime).state, .unlocked(.lifetime))
    }

    /// Case 3: downloaded after the app went free, bought nothing.
    func testANewFreeUserIsLocked() {
        XCTAssertEqual(entitlement().state, .locked)
    }

    /// Case 5.
    func testAnExpiredSubscriptionIsLocked() {
        XCTAssertEqual(entitlement(purchase: past).state, .locked)
    }

    /// Case 6: the legacy entitlement outlives a lapsed subscription.
    func testALegacyUserSurvivesAnExpiredSubscription() {
        XCTAssertEqual(entitlement(legacy: .legacyPaid, purchase: past).state,
                       .unlocked(.legacyPaid))
    }

    /// An annual subscription is over the moment it expires, so the boundary
    /// belongs to the locked side: expiring exactly now is not still active.
    func testASubscriptionExpiringExactlyNowIsLocked() {
        XCTAssertEqual(entitlement(purchase: .annual(expiration: now)).state, .locked)
    }

    /// isUnlocked is what most gates read, so it is pinned separately from
    /// state rather than trusted to follow it.
    func testIsUnlockedFollowsTheState() {
        XCTAssertTrue(entitlement(legacy: .legacyPaid).isUnlocked)
        XCTAssertFalse(entitlement().isUnlocked)
        XCTAssertFalse(entitlement(legacy: .unknown).isUnlocked,
                       "checking is not an entitlement, only a permissive gate")
    }

    // MARK: - Precedence

    /// Lifetime is the entitlement that will outlive the other, so it is what
    /// the settings screen should name.
    func testLifetimeOutranksAnActiveSubscription() {
        XCTAssertEqual(entitlement(purchase: .lifetime).source, .lifetime)
    }

    func testLegacyOutranksEverything() {
        XCTAssertEqual(entitlement(legacy: .legacyPaid, purchase: .lifetime).source,
                       .legacyPaid)
    }

    // MARK: - Checking

    func testCheckingWhileEitherSourceHasNotAnswered() {
        XCTAssertEqual(entitlement(legacy: .unknown).state, .checking)
        XCTAssertEqual(entitlement(purchase: .unknown).state, .checking)
        XCTAssertEqual(entitlement(legacy: .unknown, purchase: .unknown).state, .checking)
    }

    /// A known entitlement does not need the other source to answer: a legacy
    /// user is Pro before StoreKit has said anything about subscriptions.
    func testAKnownEntitlementDoesNotWaitForTheOtherSource() {
        XCTAssertEqual(entitlement(legacy: .legacyPaid, purchase: .unknown).state,
                       .unlocked(.legacyPaid))
        XCTAssertEqual(entitlement(legacy: .unknown, purchase: .lifetime).state,
                       .unlocked(.lifetime))
    }

    /// Case 7: blocking a paying user costs more than letting one action
    /// through in the moment before StoreKit answers.
    func testAnActionIsAllowedWhileChecking() {
        XCTAssertTrue(entitlement(legacy: .unknown).allowsAction)
        XCTAssertTrue(entitlement(legacy: .legacyPaid).allowsAction)
        XCTAssertFalse(entitlement().allowsAction)
    }

    // MARK: - Ads

    /// Ads default the other way from actions: almost every free user is a
    /// non-payer, so hiding ads until the answer arrives would lose their
    /// impressions.
    func testAdsShowWhileCheckingWhenTheBuildHasThem() {
        XCTAssertTrue(entitlement(ads: true, legacy: .unknown).showsAds)
        XCTAssertTrue(entitlement(ads: true).showsAds)
        XCTAssertFalse(entitlement(ads: true, legacy: .legacyPaid).showsAds)
        XCTAssertFalse(entitlement(ads: true, purchase: .lifetime).showsAds)
    }

    /// The full app carries no ads at all, whoever the user is. This is the
    /// promise that makes the free download safe for existing customers.
    func testABuildWithoutAdsNeverShowsThem() {
        XCTAssertFalse(entitlement(ads: false).showsAds)
        XCTAssertFalse(entitlement(ads: false, legacy: .unknown).showsAds)
    }

    // MARK: - Constants

    func testLimitsMatchAndroid() {
        XCTAssertEqual(ProEntitlement.freeGameLimit, 3)
        XCTAssertEqual(ProEntitlement.cloudSlotCount, 256)
    }

    func testFullAppURLPointsAtTheRealListing() throws {
        let url = try XCTUnwrap(ProEntitlement.fullAppURL)
        XCTAssertTrue(url.absoluteString.contains("id1549144351"))
    }
}
