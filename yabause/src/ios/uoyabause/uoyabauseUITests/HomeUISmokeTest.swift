//
//  HomeUISmokeTest.swift
//  YabaSnashiroUITests
//
//  End-to-end smoke test for the SwiftUI home UI (MainTabView).
//  Copyright (c) 2026 devMiyax. All rights reserved.
//

import XCTest

/// Verifies the user-visible behavior of the new five-tab home screen.
/// This is the regression net for the follow-up tasks that remove the
/// legacy MainScreenController / FileSelectController screens.
final class HomeUISmokeTest: XCTestCase {

    private var app: XCUIApplication!

    /// The springboard hosts system permission alerts (notifications).
    private var springboard: XCUIApplication {
        XCUIApplication(bundleIdentifier: "com.apple.springboard")
    }

    // MARK: - Setup

    @MainActor override func setUp() {
        super.setUp()
        continueAfterFailure = false

        app = XCUIApplication()
        // Force English so the localized assertions below are stable
        // regardless of the simulator language.
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]

        // System alerts block taps; handle them both reactively (monitor)
        // and proactively (explicit dismissal after launch).
        addUIInterruptionMonitor(withDescription: "System permission alert") { alert in
            for label in ["Don't Allow", "Dont Allow", "Allow", "OK", "Cancel"] {
                let button = alert.buttons[label]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            return false
        }

        app.launch()
        dismissSystemAlertIfPresent()

        // The app does Firebase / RetroAchievements startup work, so give
        // the first render a generous timeout. See TabQueries: this must not
        // assert on a tab bar, which iPad does not have.
        XCTAssertTrue(app.waitForHomeUI(),
                      "The home screen never appeared")
    }

    /// Scrolls the scroll view down until `element` exists and is hittable.
    /// Needed for anything in a lazily rendered Form or List that starts below
    /// the fold: waitForExistence alone never succeeds, because the row is not
    /// built until it is scrolled into range.
    private func scrollUntilVisible(_ element: XCUIElement,
                                    maxSwipes: Int = 8) -> Bool {
        if element.exists && element.isHittable { return true }
        let container = app.scrollViews.firstMatch.exists
            ? app.scrollViews.firstMatch
            : app.otherElements.firstMatch
        for _ in 0..<maxSwipes {
            container.swipeUp()
            if element.exists && element.isHittable { return true }
        }
        return element.exists && element.isHittable
    }

    /// Taps away a system permission alert if one is on screen.
    /// Safe to call when no alert is present: it simply does nothing.
    private func dismissSystemAlertIfPresent(timeout: TimeInterval = 5) {
        let systemAlert = springboard.alerts.firstMatch
        if systemAlert.waitForExistence(timeout: timeout), tapDismissButton(in: systemAlert) {
            return
        }
        let inAppAlert = app.alerts.firstMatch
        if inAppAlert.exists {
            _ = tapDismissButton(in: inAppAlert)
        }
    }

    private func tapDismissButton(in alert: XCUIElement) -> Bool {
        for label in ["Don't Allow", "Dont Allow", "Allow", "OK", "Cancel"] {
            let button = alert.buttons[label]
            if button.exists {
                button.tap()
                return true
            }
        }
        return false
    }

    /// Selects a tab and waits until it reports itself selected.
    @discardableResult
    private func selectTab(_ name: String,
                           file: StaticString = #filePath,
                           line: UInt = #line) -> XCUIElement {
        let tab = app.tabButton(name)
        XCTAssertTrue(tab.waitForExistence(timeout: 10),
                      "Tab \"\(name)\" does not exist", file: file, line: line)
        tab.tap()
        dismissSystemAlertIfPresent(timeout: 1)
        return tab
    }

    // MARK: - Tests

    /// All five tabs from the Android bottom navigation exist.
    @MainActor
    func testFiveTabsExist() {
        for name in ["Games", "Backup", "Add", "Settings", "Account"] {
            XCTAssertTrue(app.tabButton(name).waitForExistence(timeout: 10),
                          "Tab \"\(name)\" is missing")
        }
    }

    /// The games tab shows either the library or the empty state.
    /// Both branches are real assertions: an empty library must explain
    /// itself, a populated one must render cards whose detail sheet opens.
    @MainActor
    func testGamesTabShowsLibraryOrEmptyState() throws {
        selectTab("Games")

        XCTAssertTrue(app.navigationBars["Games"].waitForExistence(timeout: 15),
                      "The games tab navigation title did not appear")

        let emptyTitle = app.staticTexts["No games found"]
        // A card's subtitle is "<product number> / YYYY-MM-DD".
        let cardSubtitle = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES %@", ".+ / [0-9]{4}-[0-9]{2}-[0-9]{2}")
        ).firstMatch

        // The scan is asynchronous, so wait for whichever state settles.
        // The timeout is generous because a cold launch also does Firebase
        // startup and box art loading; running this suite alongside the unit
        // tests in one xcodebuild invocation makes that noticeably slower.
        let settled = expectation(for: NSPredicate(format: "exists == true"),
                                  evaluatedWith: emptyTitle)
        let listed = expectation(for: NSPredicate(format: "exists == true"),
                                 evaluatedWith: cardSubtitle)
        _ = XCTWaiter().wait(for: [settled, listed], timeout: 60)

        if emptyTitle.exists {
            XCTAssertTrue(app.staticTexts["Add games from the Add tab"].exists,
                          "The empty state is missing its guidance text")
            throw XCTSkip("Library is empty: the game card / detail sheet path was not exercised")
        }

        XCTAssertTrue(cardSubtitle.exists,
                      "Neither the empty state nor any game card appeared on the games tab")

        // Tapping a card opens the detail sheet, which offers Play.
        cardSubtitle.tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 10),
                      "The game detail sheet did not show the Play button")
    }

    /// Search is hidden behind a toolbar button, as on Android: no field on
    /// arrival, the button reveals it, Cancel puts it away again.
    @MainActor
    func testSearchFieldIsHiddenUntilTheToolbarButtonIsTapped() {
        for (tab, title) in [("Games", "Games"), ("Backup", "Backup")] {
            selectTab(tab)
            let navBar = app.navigationBars[title]
            XCTAssertTrue(navBar.waitForExistence(timeout: 15),
                          "The \(tab) tab did not show its navigation title")

            XCTAssertFalse(app.textFields["Search"].exists,
                           "The \(tab) tab showed a search field before it was asked for")

            let button = navBar.buttons["Search"]
            XCTAssertTrue(button.waitForExistence(timeout: 5),
                          "The \(tab) tab is missing its search toolbar button")
            button.tap()

            let field = app.textFields["Search"]
            XCTAssertTrue(field.waitForExistence(timeout: 5),
                          "Tapping search did not reveal the field on \(tab)")

            app.buttons["Cancel"].tap()
            XCTAssertTrue(waitForDisappearance(of: field),
                          "Cancel did not hide the search field on \(tab)")
        }
    }

    /// Waits until `element` is gone, mirroring waitForExistence.
    private func waitForDisappearance(of element: XCUIElement,
                                      timeout: TimeInterval = 10) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"),
                               evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    /// The backup tab hosts the backup manager (see BackupUISmokeTest for
    /// its contents); here we only check the tab opens.
    @MainActor
    func testBackupTabOpens() {
        selectTab("Backup")
        XCTAssertTrue(app.navigationBars["Backup"].waitForExistence(timeout: 15),
                      "The backup tab did not show its navigation title")
    }

    /// The Add tab is an action button: it opens the document browser
    /// directly and leaves the previously selected tab in place.
    @MainActor
    func testAddTabOpensTheFileBrowserAndKeepsPreviousTab() {
        // Start from Backup so "kept the previous tab" is distinguishable
        // from the default Games selection.
        selectTab("Backup")
        XCTAssertTrue(app.navigationBars["Backup"].waitForExistence(timeout: 15),
                      "The backup tab did not load before opening the browser")

        selectTab("Add")

        // The picker belongs to the document management extension, so assert
        // on its Cancel button rather than on any of our own chrome.
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 20),
                      "Tapping Add did not open the document browser")
        cancel.tap()

        XCTAssertTrue(app.navigationBars["Backup"].waitForExistence(timeout: 15),
                      "Closing the browser did not return to the previous (Backup) tab")
        // The navigation bar above already proves which tab is showing. Where
        // the tab presentation also exposes a selected button, check that it
        // agrees; iPadOS does not report selection, hence the optional.
        if let isSelected = app.tabSelectionState("Backup") {
            XCTAssertTrue(isSelected,
                          "The Add tab stole the selection from the Backup tab")
        }
    }

    /// The settings tab shows the sections the emulator settings live in.
    @MainActor
    func testSettingsTabShowsItsSections() {
        selectTab("Settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15),
                      "The settings tab did not show its navigation title")
        XCTAssertTrue(app.switches["Show FPS"].waitForExistence(timeout: 10),
                      "The settings tab is missing the Show FPS toggle")
        for section in ["General", "Display", "Sound", "Input", "Notifications"] {
            XCTAssertTrue(app.staticTexts[section].waitForExistence(timeout: 5),
                          "The \(section) section is missing")
        }
    }

    /// The Notification Settings row stopped being a NavigationLink when the
    /// controller work landed - a link cannot be followed programmatically on
    /// iOS 16, so it became a Button plus navigationDestination. Touch has to
    /// reach the same screen, and back out of it again.
    @MainActor
    func testNotificationSettingsRowStillNavigates() {
        selectTab("Settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15),
                      "The settings tab did not show its navigation title")

        // Notifications is the last section, so on a phone the row starts
        // below the fold. A Form renders lazily, which means the element does
        // not merely sit off screen -- it does not exist until scrolled to.
        let row = app.buttons["Notification Settings"]
        XCTAssertTrue(scrollUntilVisible(row),
                      "The Notification Settings row is missing")
        row.tap()

        XCTAssertTrue(
            app.navigationBars["Notification Settings"].waitForExistence(timeout: 10),
            "Tapping the row did not push the notification settings screen")

        app.navigationBars["Notification Settings"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10),
                      "Could not get back to the settings list")
    }

    /// The account tab settles into either the signed-in cards or the
    /// sign-in prompt, never a blank screen. Returning to Games afterwards
    /// must still work: the account screen used to leave gamepad handlers
    /// behind and strand the user there.
    @MainActor
    func testAccountTabShowsSignInOrProfile() {
        selectTab("Account")
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 15),
                      "The account tab did not show its navigation title")

        let candidates = [
            app.buttons["Sign in with Google"],
            app.staticTexts["Sign In"],
            app.buttons["Sign Out"],
            app.staticTexts["Connected Accounts"],
        ]
        let expectations = candidates.map {
            expectation(for: NSPredicate(format: "exists == true"), evaluatedWith: $0)
        }
        _ = XCTWaiter().wait(for: expectations, timeout: 30)
        XCTAssertTrue(candidates.contains { $0.exists },
                      "The account tab showed no recognizable state")

        selectTab("Games")
        XCTAssertTrue(app.navigationBars["Games"].waitForExistence(timeout: 15),
                      "Could not return to the games tab")
        XCTAssertTrue(app.state == .runningForeground,
                      "The app is no longer running in the foreground")
    }
}
