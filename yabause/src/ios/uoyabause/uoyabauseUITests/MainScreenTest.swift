//
//  MainScreenTest.swift
//  YabaSnashiroUITests
//
//  Created by devMiyax on 2024/08/04.
//  Copyright © 2024 devMiyax. All rights reserved.
//

import Foundation
import XCTest

/// Fastlane screenshot driver.
///
/// The screenshot names ("01MainScreen" / "02NextScreen") are kept from the
/// legacy MainScreenController based test so the existing fastlane
/// deliver / screenshots_all configuration keeps working. Only the elements
/// being driven changed: the home screen is now the SwiftUI MainTabView.
final class uoyabauseUITests: XCTestCase {

    var app: XCUIApplication?

    @MainActor override func setUp() {
        super.setUp()
        continueAfterFailure = false
        self.app = XCUIApplication()
        setupSnapshot(self.app!)

        // Permission alerts would otherwise sit on top of the screenshots.
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

        self.app!.launch()
        dismissSystemAlertIfPresent()
    }

    /// Taps away a system permission alert if one is on screen.
    private func dismissSystemAlertIfPresent(timeout: TimeInterval = 5) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let systemAlert = springboard.alerts.firstMatch
        if systemAlert.waitForExistence(timeout: timeout), tapDismissButton(in: systemAlert) {
            return
        }
        let inAppAlert = app!.alerts.firstMatch
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
    func testScreenShot1() {
        let app = self.app!

        // The app does Firebase / RetroAchievements startup work before the
        // home screen renders, so allow a generous timeout.
        XCTAssertTrue(app.waitForHomeUI(), "The home screen never appeared")

        // Give the asynchronous game scan a moment so the library is populated
        // in the screenshot instead of showing the empty state.
        _ = app.scrollViews.firstMatch.waitForExistence(timeout: 10)

        // 01: the home screen (games library).
        snapshot("01MainScreen")

        // 02: the settings tab. Screenshot runs use other languages, so fall
        // back to index based lookup when the localized label differs.
        var settingsTab = app.tabButton("Settings")
        if !settingsTab.waitForExistence(timeout: 10) {
            settingsTab = app.tabBars.buttons.element(boundBy: 3)
        }
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 10), "Settings tab did not appear")
        settingsTab.tap()
        dismissSystemAlertIfPresent(timeout: 1)

        // Wait for the settings content to render before capturing.
        _ = app.tables.firstMatch.waitForExistence(timeout: 15)

        snapshot("02NextScreen")
    }
}
