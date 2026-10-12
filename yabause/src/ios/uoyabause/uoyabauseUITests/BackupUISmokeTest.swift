//
//  BackupUISmokeTest.swift
//  YabaSnashiroUITests
//
//  End-to-end smoke test for the backup tab (BackupTabView).
//  Copyright (c) 2026 devMiyax. All rights reserved.
//

import XCTest

/// Smoke test for the backup tab. Asserts the tab opens and settles into
/// either a list of saves or the empty state.
final class BackupUISmokeTest: XCTestCase {
    private var app: XCUIApplication!

    /// The springboard hosts system permission alerts (notifications).
    private var springboard: XCUIApplication {
        XCUIApplication(bundleIdentifier: "com.apple.springboard")
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Force English so the localized assertions below are stable
        // regardless of the simulator language.
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]

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

    @MainActor
    func testBackupTabShowsListOrEmptyState() throws {
        XCTAssertTrue(app.waitForHomeUI(),
                      "The home screen did not appear")
        app.tabButton("Backup").tap()
        dismissSystemAlertIfPresent(timeout: 1)

        XCTAssertTrue(app.navigationBars["Backup"].waitForExistence(timeout: 15),
                      "The backup tab navigation title did not appear")

        let emptyTitle = app.staticTexts["No saves found"]
        let anyRow = app.rows(ofList: "BackupSaveList").firstMatch

        let empty = expectation(for: NSPredicate(format: "exists == true"),
                                evaluatedWith: emptyTitle)
        let listed = expectation(for: NSPredicate(format: "exists == true"),
                                 evaluatedWith: anyRow)
        _ = XCTWaiter().wait(for: [empty, listed], timeout: 60)

        XCTAssertTrue(emptyTitle.exists || anyRow.exists,
                      "The backup tab showed neither saves nor the empty state")
    }

    /// Switching to the cloud section settles into one of its states rather
    /// than hanging or showing a blank screen.
    @MainActor
    func testCloudSectionShowsOneOfItsStates() throws {
        XCTAssertTrue(app.waitForHomeUI(),
                      "The home screen did not appear")
        app.tabButton("Backup").tap()
        dismissSystemAlertIfPresent(timeout: 1)

        XCTAssertTrue(app.navigationBars["Backup"].waitForExistence(timeout: 15),
                      "The backup tab navigation title did not appear")

        // Local memories and the cloud share one source control now, so
        // reaching the cloud means opening it and picking the entry rather
        // than tapping a Local/Cloud segment.
        let sourcePicker = app.buttons["BackupSourcePicker"]
        XCTAssertTrue(sourcePicker.waitForExistence(timeout: 10),
                      "The backup source picker is missing")
        sourcePicker.tap()

        let cloudEntry = app.buttons["Cloud"]
        XCTAssertTrue(cloudEntry.waitForExistence(timeout: 10),
                      "The source menu has no Cloud entry")
        cloudEntry.tap()

        // Any of these is a valid settled state; a blank screen is not.
        let candidates = [
            app.staticTexts["Sign in to use cloud backup."],
            app.staticTexts["Cloud backup is available in the full version."],
            app.staticTexts["No cloud backups yet."],
            app.staticTexts["Could not reach the cloud."],
            app.rows(ofList: "CloudSaveList").firstMatch,
        ]
        let expectations = candidates.map {
            expectation(for: NSPredicate(format: "exists == true"), evaluatedWith: $0)
        }
        _ = XCTWaiter().wait(for: expectations, timeout: 60)

        XCTAssertTrue(candidates.contains { $0.exists },
                      "The cloud section showed no recognizable state")
    }
}
