import XCTest
@testable import YabaSnashiro

@MainActor
final class SharedBackupLinkRouterTests: XCTestCase {
    private var router: SharedBackupLinkRouter!

    override func setUp() {
        super.setUp()
        router = SharedBackupLinkRouter()
    }

    func testAcceptsABackupLinkAndHoldsItsId() {
        XCTAssertTrue(router.handle(url: URL(string: "yabasanshiro://backup/abc")!))
        XCTAssertEqual(router.pendingId, "abc")
    }

    /// The custom scheme is shared with the Discord callback, so refusing
    /// what is not ours is what lets AppDelegate fall through to it.
    func testRefusesLinksThatAreNotOurs() {
        XCTAssertFalse(router.handle(url: URL(string: "yabasanshiro://discord/callback")!))
        XCTAssertNil(router.pendingId)

        XCTAssertFalse(router.handle(url: URL(string: "file:///tmp/game.chd")!))
        XCTAssertNil(router.pendingId)
    }

    func testTakesAUniversalLinkFromItsUserActivity() {
        let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        activity.webpageURL = URL(string: "https://www.yabasanshiro.com/backup/abc")

        XCTAssertTrue(router.handle(userActivity: activity))
        XCTAssertEqual(router.pendingId, "abc")
    }

    /// Handoff and Siri activities arrive through the same delegate method.
    func testIgnoresAnActivityThatIsNotAWebLink() {
        let activity = NSUserActivity(activityType: "com.example.other")
        XCTAssertFalse(router.handle(userActivity: activity))
        XCTAssertNil(router.pendingId)
    }

    /// Clearing is what lets the same link be followed twice in one session.
    func testTheSameLinkCanBeFollowedAgainAfterClearing() {
        let url = URL(string: "yabasanshiro://backup/abc")!
        router.handle(url: url)
        router.clearPending()
        XCTAssertNil(router.pendingId)

        router.handle(url: url)
        XCTAssertEqual(router.pendingId, "abc")
    }
}
