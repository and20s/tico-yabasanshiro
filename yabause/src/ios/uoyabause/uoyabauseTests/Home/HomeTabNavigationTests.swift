import XCTest
@testable import YabaSnashiro

final class HomeTabNavigationTests: XCTestCase {
    func testForwardCycling() {
        XCTAssertEqual(HomeTabNavigator.next(from: .games, delta: 1), .backup)
        XCTAssertEqual(HomeTabNavigator.next(from: .backup, delta: 1), .settings)
        XCTAssertEqual(HomeTabNavigator.next(from: .settings, delta: 1), .account)
    }

    func testForwardFromLastWrapsToFirst() {
        XCTAssertEqual(HomeTabNavigator.next(from: .account, delta: 1), .games)
    }

    func testBackwardFromFirstWrapsToLast() {
        XCTAssertEqual(HomeTabNavigator.next(from: .games, delta: -1), .account)
    }

    func testBackwardCycling() {
        XCTAssertEqual(HomeTabNavigator.next(from: .account, delta: -1), .settings)
        XCTAssertEqual(HomeTabNavigator.next(from: .settings, delta: -1), .backup)
        XCTAssertEqual(HomeTabNavigator.next(from: .backup, delta: -1), .games)
    }

    func testAddTabIsNeverSelected() {
        XCTAssertFalse(HomeTabNavigator.cycleOrder.contains(.add))
        for tab in HomeTabNavigator.cycleOrder {
            for delta in [-2, -1, 1, 2] {
                XCTAssertNotEqual(HomeTabNavigator.next(from: tab, delta: delta), .add)
            }
        }
    }

    func testUnknownTabIsUnchanged() {
        XCTAssertEqual(HomeTabNavigator.next(from: .add, delta: 1), .add)
    }
}
