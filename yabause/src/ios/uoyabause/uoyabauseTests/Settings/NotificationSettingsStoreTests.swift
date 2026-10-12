import XCTest
@testable import YabaSnashiro

final class NotificationSettingsStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: NotificationSettingsStore!

    override func setUpWithError() throws {
        defaults = UserDefaults(suiteName: "NotificationSettingsStoreTests")
        defaults.removePersistentDomain(forName: "NotificationSettingsStoreTests")
        store = NotificationSettingsStore(defaults: defaults)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: "NotificationSettingsStoreTests")
    }

    func testDefaultsMatchTheLegacyScreen() {
        XCTAssertTrue(store.isEnabled(.gameUpdates))
        XCTAssertTrue(store.isEnabled(.systemNotifications))
        XCTAssertFalse(store.isEnabled(.achievements))
        XCTAssertFalse(store.isEnabled(.leaderboards))
        XCTAssertFalse(store.isEnabled(.promotions))
    }

    func testSetThenRead() {
        store.setEnabled(true, for: .achievements)
        XCTAssertTrue(store.isEnabled(.achievements))
        store.setEnabled(false, for: .achievements)
        XCTAssertFalse(store.isEnabled(.achievements))
    }

    /// The keys must stay compatible with what MessagingManager already wrote,
    /// or a user's existing choices are lost on upgrade.
    func testUserDefaultsKeyShape() {
        store.setEnabled(true, for: .leaderboards)
        XCTAssertEqual(defaults.bool(forKey: "notification_leaderboards_enabled"), true)
    }

    func testTopicShape() {
        XCTAssertEqual(NotificationSettingsStore.Category.achievements.topic,
                       "yabasanshiro_achievements")
    }

    func testEveryCategoryHasADistinctTitle() {
        let titles = NotificationSettingsStore.Category.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count)
        XCTAssertFalse(titles.contains(where: \.isEmpty))
    }
}
