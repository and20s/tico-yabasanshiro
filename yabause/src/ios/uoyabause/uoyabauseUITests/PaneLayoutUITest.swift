//
//  PaneLayoutUITest.swift
//  YabaSnashiroUITests
//
//  The regular-width three-column layout the controller navigates.
//  Copyright (c) 2026 devMiyax. All rights reserved.
//

import XCTest

/// D-pad Left/Right moves between the sidebar, the list and the detail pane,
/// which only means anything if all three are on screen at once. A controller
/// press cannot be synthesized by XCUITest, so what is checked here is the
/// layout that movement assumes - in both orientations, because the sidebar
/// is meant to stay visible in portrait too - and the screenshots are the
/// record of it.
final class PaneLayoutUITest: XCTestCase {

    private var app: XCUIApplication!

    @MainActor override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        addUIInterruptionMonitor(withDescription: "System permission alert") { alert in
            for label in ["Don't Allow", "Dont Allow", "Allow", "OK", "Cancel"] {
                if alert.buttons[label].exists {
                    alert.buttons[label].tap()
                    return true
                }
            }
            return false
        }
        app.launch()
    }

    @MainActor override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        app.terminate()
        super.tearDown()
    }

    /// A card's subtitle is "<product number> / YYYY-MM-DD", which is the only
    /// text a card is guaranteed to have whatever the library holds.
    private var cardSubtitle: XCUIElement {
        app.staticTexts.matching(
            NSPredicate(format: "label MATCHES %@",
                        ".+ / [0-9]{4}-[0-9]{2}-[0-9]{2}")).firstMatch
    }

    @MainActor
    func testBothOrientationsShowSidebarListAndDetail() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("One pane at compact width: nothing to move between")
        }
        for (name, orientation) in [("landscape", UIDeviceOrientation.landscapeLeft),
                                    ("portrait", UIDeviceOrientation.portrait)] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(app.waitForHomeUI(),
                          "the home UI did not appear in \(name)")

            // The sidebar column, which D-pad Left reaches.
            XCTAssertTrue(app.tabButton("Games").waitForExistence(timeout: 10),
                          "the sidebar has no Games entry in \(name)")

            guard cardSubtitle.waitForExistence(timeout: 60) else {
                attach(named: "games-empty-\(name)")
                throw XCTSkip("Library is empty: the detail pane was not filled")
            }
            // Filling the pane by touch is what D-pad Right does for the
            // focused card, so this is the same state that press lands in.
            cardSubtitle.tap()
            XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 15),
                          "the detail pane did not appear in \(name)")
            // Both columns at once: a sheet would have covered the list.
            XCTAssertTrue(cardSubtitle.exists,
                          "the list was replaced rather than kept beside the pane in \(name)")
            attach(named: "games-two-pane-\(name)")
        }
    }

    @MainActor
    private func attach(named name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
