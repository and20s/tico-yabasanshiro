import XCTest
@testable import YabaSnashiro

/// The account tab's rows are plain properties in a VStack, so a row that
/// stops being referenced simply vanishes -- no compiler error, no failing
/// test. That is exactly how Discord and RetroAchievements disappeared from
/// Connected Accounts once.
///
/// These read the source, because the alternative is a UI test that has to be
/// signed in to see any of it.
final class AccountTabRowsTests: XCTestCase {
    private func source() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Account
            .deletingLastPathComponent()   // uoyabauseTests
            .deletingLastPathComponent()   // project dir
            .appendingPathComponent("uoyabause/Account/Views/AccountTabView.swift")
        return try String(contentsOf: root, encoding: .utf8)
    }

    /// Every row the scope can focus must also be drawn.
    func testEveryFocusableRowIsRendered() throws {
        let text = try source()
        // The body's VStack, from profileCard to the closing padding.
        guard let start = text.range(of: "profileCard"),
              let end = text.range(of: ".padding(16)") else {
            return XCTFail("could not find the account tab's body")
        }
        let body = String(text[start.lowerBound..<end.lowerBound])

        for row in ["profileCard", "discordRow", "retroAchievementsRow",
                    "subscriptionCard", "CrossDeviceSyncCard", "deleteButton"] {
            XCTAssertTrue(body.contains(row),
                          "\(row) is no longer drawn in the account tab")
        }
    }

    /// A controller-only legacy or lifetime owner reaches Restore Purchases
    /// through this row and nowhere else: the pro gate is opened by this very
    /// action, and an entitled user never trips a limit that opens it any
    /// other way. Making the row non-focusable left them no route at all.
    func testAnEntitledUserKeepsAControllerRouteToRestore() throws {
        let text = try source()
        guard let start = text.range(of: "private var subscriptionAction"),
              let end = text.range(of: "private func openSubscriptionManagement") else {
            return XCTFail("could not find the subscription row's action")
        }
        let action = String(text[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(action.contains("viewModel.restorePurchases()"),
                      "the entitled states no longer bind A to Restore Purchases")
    }

    /// The annual line has to follow the renewal state. Drawn unconditionally
    /// it told a subscriber who had cancelled that their subscription renews,
    /// which is the opposite of the truth.
    func testTheAnnualLineFollowsTheRenewalState() throws {
        let text = try source()
        XCTAssertTrue(text.contains("viewModel.subscriptionRenewal"),
                      "the account card no longer reads the renewal state")
        XCTAssertTrue(text.contains("Expires on %@"),
                      "a cancelled subscriber is no longer told when Pro runs out")
    }

    /// Scrolling to a focused row needs an anchor on it, or the D-pad walks
    /// the ring off screen.
    func testEveryScrollAnchorIsPresent() throws {
        let text = try source()
        for anchor in ["AccountRow.signOut", "AccountRow.discord",
                       "AccountRow.retroAchievements", "AccountRow.subscription",
                       "AccountRow.pin", "AccountRow.delete"] {
            XCTAssertTrue(text.contains(".id(\(anchor))"),
                          "\(anchor) has no scroll anchor")
        }
    }
}
