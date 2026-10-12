import XCTest
@testable import YabaSnashiro

final class CloudBackupEntitlementTests: XCTestCase {
    private func lite(_ purchase: PurchaseStatus) -> CloudBackupEntitlement {
        CloudBackupEntitlement(entitlement: ProEntitlement(showsAdvertising: true,
                                                           legacy: .notLegacy,
                                                           purchase: purchase))
    }

    private var paid: CloudBackupEntitlement {
        CloudBackupEntitlement(entitlement: ProEntitlement(showsAdvertising: false,
                                                           legacy: .legacyPaid,
                                                           purchase: .none))
    }

    func testALegacyPaidUserNeverNeedsASubscription() {
        XCTAssertTrue(paid.isEnabled)
        XCTAssertFalse(paid.isCheckingEntitlement)
        XCTAssertEqual(paid.slotCount, 256)
    }

    func testAProPurchaseEnablesCloudBackup() {
        XCTAssertTrue(lite(.lifetime).isEnabled)
        XCTAssertEqual(lite(.lifetime).slotCount, 256)
    }

    func testWithoutAnyPurchaseCloudBackupIsNotEnabled() {
        XCTAssertFalse(lite(.none).isEnabled)
        XCTAssertEqual(lite(.none).slotCount, 0)
    }

    /// While the store is still checking, never tell a subscriber they cannot
    /// use what they paid for.
    func testAnUnansweredPurchaseStatusIsChecking() {
        XCTAssertTrue(lite(.unknown).isCheckingEntitlement)
        XCTAssertFalse(lite(.unknown).isEnabled)
    }

    /// The slot count is the number Android writes; letting the two drift
    /// would show a different capacity on each platform for one account.
    func testSlotCountMatchesAndroid() {
        XCTAssertEqual(CloudBackupEntitlement.entitledSlotCount,
                       ProEntitlement.cloudSlotCount)
    }
}
