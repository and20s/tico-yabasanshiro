import XCTest
@testable import YabaSnashiro

final class ProGateSheetTests: XCTestCase {
    /// The storefront's own localized price, never a hardcoded amount: the
    /// price differs per country.
    func testTheAnnualTitleCarriesThePrice() {
        let title = ProGateModel.title(for: .annual, price: "JPY 300")
        XCTAssertTrue(title.contains("JPY 300"))
    }

    func testTheLifetimeTitleCarriesThePrice() {
        let title = ProGateModel.title(for: .lifetime, price: "JPY 700")
        XCTAssertTrue(title.contains("JPY 700"))
    }

    /// The two offers must not read the same, or the user cannot tell which
    /// one renews.
    func testTheTwoOffersAreDistinguishable() {
        XCTAssertNotEqual(ProGateModel.title(for: .annual, price: "X"),
                          ProGateModel.title(for: .lifetime, price: "X"))
    }

    /// No amount may appear in the app's own strings.
    func testNoPriceIsHardcoded() {
        for kind in [ProOffer.Kind.annual, .lifetime] {
            let title = ProGateModel.title(for: kind, price: "PRICE")
            XCTAssertFalse(title.contains("$"))
            XCTAssertFalse(title.contains("1.99"))
            XCTAssertFalse(title.contains("4.99"))
        }
    }

    /// While StoreKit has not answered, the gate must not read as "you are
    /// not a customer". A legacy paid user is `.checking` for the first
    /// seconds after an update, and showing them the offers is how someone
    /// gets walked through buying what they already own.
    @MainActor
    func testAnUndecidedEntitlementIsNotTheSalesLayout() {
        let model = ProGateModel()
        XCTAssertEqual(model.standing, .checking, "the gate must not open on the offers")
        model.apply(ProEntitlement(showsAdvertising: false,
                                   legacy: .unknown, purchase: .unknown))
        XCTAssertEqual(model.standing, .checking)
        XCTAssertFalse(model.isPro)
    }

    /// The answer that arrives while the sheet is open has to be taken.
    @MainActor
    func testALegacyAnswerArrivingLaterEntitles() {
        let model = ProGateModel()
        model.apply(ProEntitlement(showsAdvertising: false,
                                   legacy: .legacyPaid, purchase: .unknown))
        XCTAssertEqual(model.standing, .entitled)
    }

    @MainActor
    func testNoRouteToProIsTheSalesLayout() {
        let model = ProGateModel()
        model.apply(ProEntitlement(showsAdvertising: false,
                                   legacy: .notLegacy, purchase: .none))
        XCTAssertEqual(model.standing, .notEntitled)
    }

    /// The focus list has to name exactly what is drawn, in the same order,
    /// in every state -- including the checking one.
    func testTheFocusListFollowsEveryState() {
        XCTAssertEqual(ProGateModel.rows(standing: .checking,
                                         offerIDs: ["pro.annual"], isLite: false),
                       [.cancel])
        XCTAssertEqual(ProGateModel.rows(standing: .entitled,
                                         offerIDs: ["pro.annual"], isLite: false),
                       [.cancel])
        XCTAssertEqual(ProGateModel.rows(standing: .notEntitled,
                                         offerIDs: ["pro.annual", "pro.lifetime"],
                                         isLite: false),
                       [.offer("pro.annual"), .offer("pro.lifetime"), .restore, .cancel])
        XCTAssertEqual(ProGateModel.rows(standing: .notEntitled,
                                         offerIDs: ["full_function_3mo"], isLite: true),
                       [.offer("full_function_3mo"), .buyFullVersion, .restore, .cancel])
    }

    /// Cancel is the last row wherever the entitlement stands, and it is
    /// always present: no state may leave the sheet with nothing to act on.
    func testCancelIsAlwaysTheLastRow() {
        for standing in [ProGateModel.Standing.checking, .entitled, .notEntitled] {
            let rows = ProGateModel.rows(standing: standing, offerIDs: [], isLite: false)
            XCTAssertEqual(rows.last, .cancel, "\(standing) has no cancel row")
        }
    }

    func testAReasonCarriesItsMessage() {
        XCTAssertEqual(ProGateReason("3 本までです").message, "3 本までです")
        XCTAssertNil(ProGateReason().message)
    }
}
