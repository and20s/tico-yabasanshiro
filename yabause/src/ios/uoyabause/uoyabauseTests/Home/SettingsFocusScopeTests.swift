import XCTest
@testable import YabaSnashiro

/// The settings and notification scopes, driven through the same coordinator
/// the app uses so the routing is covered as well as the arithmetic.
///
/// Structural rather than behavioural, for the reason
/// GamePadHandlerOwnershipTests states: HomeTabNavigator had six green tests
/// while the feature was broken. What these pin down is the row order (the
/// five-input target depends on Show FPS being the third row), that A does
/// something on every row kind, and that B is never a no-op where a scope
/// claims it.
@MainActor
final class SettingsFocusScopeTests: XCTestCase {
    private var coordinator: ControllerFocusCoordinator!
    private var model: SettingsTabModel!

    override func setUp() {
        super.setUp()
        coordinator = ControllerFocusCoordinator()
        model = SettingsTabModel(
            store: EmulatorSettingsStore(
                defaults: UserDefaults(suiteName: "settings-focus-tests")!))
    }

    // MARK: - Row order

    /// The step-count target in the spec is five inputs from the games tab:
    /// R, R to reach Settings, then Down, Down, A. That only holds while Show
    /// FPS is the third row and the first row is focused on arrival.
    func testShowFPSIsTheThirdRow() {
        XCTAssertEqual(SettingsTabModel.Row.showFPS.rawValue, 2)
    }

    /// The pad-layout editor is out of scope for controller navigation (spec
    /// section 1.2) and has no B to leave it with, so entering it with A would
    /// strand a controller user. It stays a touch-only row.
    func testPadSettingsIsNotAFocusableRow() {
        let names = SettingsTabModel.Row.allCases.map { String(describing: $0) }
        XCTAssertFalse(names.contains("padSettings"))
        XCTAssertEqual(SettingsTabModel.Row.allCases.count, 10)
    }

    func testTwoDownsFromTheInitialFocusReachShowFPS() {
        model.applyInitialFocus(controllerConnected: true)
        coordinator.push(model)
        coordinator.handle(.down)
        coordinator.handle(.down)
        XCTAssertEqual(model.focusedIndex, SettingsTabModel.Row.showFPS.rawValue)
    }

    func testAOnShowFPSTogglesIt() {
        let before = model.showFPS
        model.focusedIndex = SettingsTabModel.Row.showFPS.rawValue
        coordinator.push(model)
        coordinator.handle(.select)
        XCTAssertEqual(model.showFPS, !before)
    }

    // MARK: - Initial focus

    func testInitialFocusOnlyAppliesWithAController() {
        model.applyInitialFocus(controllerConnected: false)
        XCTAssertNil(model.focusedIndex, "touch users get no selection")
        model.applyInitialFocus(controllerConnected: true)
        XCTAssertEqual(model.focusedIndex, 0)
    }

    func testInitialFocusDoesNotOverrideAnExistingSelection() {
        model.focusedIndex = 4
        model.applyInitialFocus(controllerConnected: true)
        XCTAssertEqual(model.focusedIndex, 4)
    }

    // MARK: - Row kinds

    /// A picker's system menu draws a highlight the app cannot move, so A
    /// advances the value instead of opening it. Every option has to stay
    /// reachable, which means it wraps.
    func testAOnAPickerAdvancesThroughEveryOptionAndWraps() {
        model.focusedIndex = SettingsTabModel.Row.soundEngine.rawValue
        coordinator.push(model)
        let first = model.soundEngine
        var seen: [Int] = [first]
        for _ in 0..<SettingsTabModel.soundOptions.count {
            coordinator.handle(.select)
            seen.append(model.soundEngine)
        }
        XCTAssertEqual(Set(seen).count, SettingsTabModel.soundOptions.count)
        XCTAssertEqual(model.soundEngine, first, "the last step wraps back")
    }

    func testAnUnknownStoredValueStillAdvances() {
        model.cartridge = 999
        model.focusedIndex = SettingsTabModel.Row.cartridge.rawValue
        coordinator.push(model)
        coordinator.handle(.select)
        XCTAssertEqual(model.cartridge, SettingsTabModel.cartridgeOptions[0].value)
    }

    func testAOnTheNotificationRowPushesTheNotificationScreen() {
        model.focusedIndex = SettingsTabModel.Row.notificationSettings.rawValue
        coordinator.push(model)
        coordinator.handle(.select)
        XCTAssertTrue(model.showNotificationSettings)
    }

    // MARK: - Modality and closing

    func testTheSettingsTabIsARootScope() {
        coordinator.push(model)
        XCTAssertFalse(model.isModal)
        XCTAssertTrue(coordinator.allowsTabChange)
        XCTAssertFalse(coordinator.handle(.back), "nothing to close on a tab root")
    }

    // MARK: - Notification settings

    func testTheNotificationScreenIsModalAndBClosesIt() {
        let notifications = NotificationSettingsModel(
            store: NotificationSettingsStore(
                defaults: UserDefaults(suiteName: "settings-focus-tests")!))
        var closed = false
        notifications.onClose = { closed = true }

        coordinator.push(model)
        coordinator.push(notifications)
        XCTAssertFalse(coordinator.allowsTabChange,
                       "a pushed screen must not let L/R move the tab under it")
        XCTAssertTrue(coordinator.handle(.back))
        XCTAssertTrue(closed)
    }

    /// Without an onClose the scope would swallow B and do nothing, which the
    /// spec forbids: B is never a silent no-op.
    func testTheNotificationScreenReportsItCannotCloseWithoutAWayBack() {
        let notifications = NotificationSettingsModel(
            store: NotificationSettingsStore(
                defaults: UserDefaults(suiteName: "settings-focus-tests")!))
        coordinator.push(notifications)
        XCTAssertFalse(coordinator.handle(.back))
    }

    func testTheNotificationRowCountFollowsThePermissionRow() {
        let notifications = NotificationSettingsModel(
            store: NotificationSettingsStore(
                defaults: UserDefaults(suiteName: "settings-focus-tests")!))
        let categories = NotificationSettingsStore.Category.allCases.count
        // notDetermined shows the Open Settings row.
        XCTAssertEqual(notifications.itemCount, categories + 1)
        XCTAssertEqual(notifications.categoryRow(0), 1)
    }

    func testClampingKeepsTheSelectionInsideTheRows() {
        let notifications = NotificationSettingsModel(
            store: NotificationSettingsStore(
                defaults: UserDefaults(suiteName: "settings-focus-tests")!))
        notifications.focusedIndex = 99
        notifications.clampFocus()
        XCTAssertEqual(notifications.focusedIndex, notifications.itemCount - 1)
    }
}
