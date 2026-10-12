//
//  ScreenshotTour.swift
//  YabaSnashiroUITests
//
//  Copyright (c) 2026 devMiyax. All rights reserved.
//

import XCTest

/// Walks the app's main screens and captures one screenshot of each, for the
/// App Store listing.
///
/// Every step is best effort. A screenshot run covers six languages and four
/// devices, so an element that is missing on one of them -- an empty library,
/// a signed-out account, an iPad laying the same screen out as two panes --
/// must skip that shot rather than fail or, worse, block. The previous
/// screenshot test asserted its way through the tabs and a run once sat for an
/// hour on a screen that never arrived.
///
/// Names are numbered because App Store Connect orders screenshots by
/// filename, not by capture order.
final class ScreenshotTour: XCTestCase {

    private var app: XCUIApplication!

    /// Long enough for a cold launch with Firebase and the library scan, short
    /// enough that a screen which never appears costs seconds, not the run.
    private let screenTimeout: TimeInterval = 20
    private let elementTimeout: TimeInterval = 5

    @MainActor override func setUp() {
        super.setUp()
        // A failed step must not abandon the remaining screens: each one is
        // guarded, and the run is worth more than any single shot.
        continueAfterFailure = true

        app = XCUIApplication()
        setupSnapshot(app)

        addUIInterruptionMonitor(withDescription: "System permission alert") { alert in
            Self.dismissButton(in: alert)?.tap() != nil
        }

        app.launch()
        dismissSystemAlert()
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    // MARK: - The tour

    @MainActor
    func testScreenshotTour() {
        guard app.waitForHomeUI(timeout: screenTimeout) else {
            XCTFail("The home screen never appeared; nothing to capture")
            return
        }
        // The library scan runs after launch, so the grid fills in a moment
        // later. Waiting on the scroll view rather than sleeping keeps a
        // populated library from being photographed half-drawn.
        _ = app.scrollViews.firstMatch.waitForExistence(timeout: elementTimeout)

        // On iPad the detail is a pane beside the list, so leaving nothing
        // selected photographs half an empty screen. Landscape plus a
        // selected game uses the whole width. On iPhone the same tap opens a
        // sheet over the library, which is the wrong picture for "01Games",
        // so both are skipped there.
        if isRegularWidth {
            // Landscape for the whole iPad tour: the store shows one
            // orientation per set, and a sidebar plus a detail pane is what
            // the wide layout exists for. The rotation is animated and the
            // split view re-lays out after it, so the next step waits for
            // the new geometry rather than tapping where a row used to be.
            XCUIDevice.shared.orientation = .landscapeLeft
            _ = app.scrollViews.firstMatch.waitForExistence(timeout: elementTimeout)
            selectFirstGame()
        }
        capture("01Games")
        captureTab("Backup", named: "03Backup")
        captureCommunity()
        captureTab("Settings", named: "05Settings")
        captureTab("Account", named: "06Account")
        // Last on purpose. The game detail is a bottom sheet with no close
        // button, and a swipe does not reliably get rid of it, so anything
        // captured after it risks being taken through the sheet. Capture
        // order does not matter to the store, which sorts by filename.
        captureGameDetail()
    }

    // MARK: - Screens

    /// The detail sheet of the first game, which is the screen that shows the
    /// box art, the play button and the per-game options.
    ///
    /// Skipped when the library is empty, which is what a freshly created
    /// simulator has until games are put in it.
    /// Whether the detail is a pane beside the list rather than a sheet over
    /// it. The sidebar only exists at regular width, so its presence is the
    /// same question asked of the running app rather than of a device list.
    /// The first game in the library, or nil when there is none to tap.
    ///
    /// A game row publishes no Button and no Cell -- only the StaticTexts of
    /// its title and product number -- so the text is what there is to tap.
    /// The other queries are kept for the layouts that do publish rows.
    @MainActor
    private func firstGameRow() -> XCUIElement? {
        // Not scrollViews.firstMatch: on iPad the sidebar is a scroll view
        // too and comes first, so that took the "Games" sidebar row and the
        // detail pane stayed empty. The library is the wider of the two.
        let library = widestScrollView ?? app.scrollViews.firstMatch
        guard library.waitForExistence(timeout: elementTimeout) else { return nil }

        let candidates: [XCUIElement] = [
            library.buttons.firstMatch,
            library.cells.firstMatch,
            library.staticTexts.firstMatch,
        ]
        return candidates.first {
            $0.waitForExistence(timeout: elementTimeout) && $0.isHittable
        }
    }

    /// Whether a game's detail is on screen.
    ///
    /// The play control publishes as an Image rather than a Button, and the
    /// placeholder disappears once something is selected, so both are worth
    /// asking about -- an identifier alone said "Button" and waited forever.
    @MainActor
    private func detailIsShowing(timeout: TimeInterval) -> Bool {
        let play = app.descendants(matching: .any).matching(identifier: "play.fill")
        if play.firstMatch.waitForExistence(timeout: timeout) { return true }
        return app.descendants(matching: .any)
            .matching(identifier: "gameDetailPlaceholder").count == 0
    }

    /// The scroll view holding the library, told apart from the sidebar by
    /// width: the sidebar is a fixed narrow column, the library takes the
    /// rest. On iPhone there is only one, so this returns that.
    @MainActor
    private var widestScrollView: XCUIElement? {
        let all = app.scrollViews.allElementsBoundByIndex
        guard !all.isEmpty else { return nil }
        return all.max { $0.frame.width < $1.frame.width }
    }

    @MainActor
    private var isRegularWidth: Bool {
        // The placeholder is drawn only by the two-pane layout, and only
        // while nothing is selected -- which is exactly when this is asked.
        // Matching on the sidebar instead would mean guessing its element
        // type, and the tab identifier there sits on an "Other", not a
        // Button or a Cell.
        app.descendants(matching: .any)
            .matching(identifier: "gameDetailPlaceholder").count > 0
    }

    /// Selects the first game without capturing anything, so the iPad's
    /// detail pane has something in it.
    @MainActor
    private func selectFirstGame() {
        guard let row = firstGameRow() else {
            print("SCREENSHOT-TOUR: no row to select")
            return
        }
        // Tapping the element itself can miss: the text is narrower than the
        // row and SwiftUI puts the gesture on the card. A tap at the row's
        // own coordinate hits the card wherever the label sits inside it.
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        // The play button is the one thing every detail layout has, so it is
        // the signal that the pane has drawn rather than a guessed identifier.
        if !detailIsShowing(timeout: elementTimeout) {
            print("SCREENSHOT-TOUR: detail pane did not open. Hierarchy:")
            print(app.debugDescription)
        }
    }

    @MainActor
    private func captureGameDetail() {
        // Captured last, so the tour is on whichever tab it ended on: go back
        // to the library before looking for a game in it.
        guard tap(tab: "Games") else { return }
        _ = app.scrollViews.firstMatch.waitForExistence(timeout: elementTimeout)

        // The library is a grid of cards at some sizes and a list of rows at
        // others, and neither carries an identifier, so this takes whatever
        // tappable thing the library area holds first.
        guard let target = firstGameRow() else {
            print("SCREENSHOT-TOUR: no game to open. Hierarchy follows:")
            print(app.debugDescription)
            return
        }
        target.tap()
        // The detail is a sheet at compact width and a pane at regular width;
        // either way something new has to draw before it is worth capturing.
        _ = detailIsShowing(timeout: elementTimeout)
        capture("02GameDetail")
        dismissSheet()
    }

    /// The community list, one tab deeper than Backup.
    ///
    /// Signed out this shows the sign-in prompt rather than saves. That is
    /// still a truthful screenshot of the feature, so it is captured either
    /// way and the caller decides whether to ship it.
    @MainActor
    private func captureCommunity() {
        guard tap(tab: "Backup") else { return }
        let community = app.buttons.matching(identifier: "person.2").firstMatch
        guard community.waitForExistence(timeout: elementTimeout), community.isHittable else {
            return
        }
        community.tap()
        _ = app.navigationBars.firstMatch.waitForExistence(timeout: elementTimeout)
        capture("04Community")
        // Leave the screen as it was found, so the next tab starts from the
        // same place on every device.
        if let back = app.navigationBars.buttons.firstMatch as XCUIElement?, back.exists {
            back.tap()
        }
    }

    @MainActor
    private func captureTab(_ tab: String, named name: String) {
        guard tap(tab: tab) else { return }
        // Any of the three is "the tab drew something"; which one depends on
        // whether the screen is a List, a Form or a scroll view.
        _ = app.tables.firstMatch.waitForExistence(timeout: elementTimeout)
            || app.collectionViews.firstMatch.waitForExistence(timeout: 1)
            || app.scrollViews.firstMatch.waitForExistence(timeout: 1)
        capture(name)
    }

    // MARK: - Helpers

    @MainActor
    private func tap(tab: String) -> Bool {
        let button = app.tabButton(tab)
        guard button.waitForExistence(timeout: elementTimeout), button.isHittable else {
            // Printed rather than swallowed: a skipped screen is invisible in
            // a passing run, and the hierarchy is the only way to see which
            // query missed.
            // Kept rather than removed: a skipped screen is invisible in a
            // passing run, and printing the hierarchy is what turned three
            // wrong guesses about this into one correct fix.
            print("SCREENSHOT-TOUR: no tab '\(tab)'. Hierarchy follows:")
            print(app.debugDescription)
            return false
        }
        button.tap()
        dismissSystemAlert(timeout: 1)
        return true
    }

    @MainActor
    private func capture(_ name: String) {
        snapshot(name)
    }

    /// Closes whatever is covering the tabs.
    ///
    /// The game detail is a bottom sheet with no close button, so the only
    /// way out is a downward swipe. Button labels are not used at all here:
    /// they are translated, and reaching for "the first navigation bar
    /// button" instead tapped Search on the screen behind the sheet.
    ///
    /// Success is defined as the tab bar being tappable again, which is the
    /// thing the next step actually needs.
    @MainActor
    private func dismissSheet() {
        for _ in 0..<3 {
            if app.tabButton("Games").isHittable { return }
            app.swipeDown()
        }
    }

    @MainActor
    private func dismissSystemAlert(timeout: TimeInterval = 3) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        if alert.waitForExistence(timeout: timeout) {
            Self.dismissButton(in: alert)?.tap()
            return
        }
        let inApp = app.alerts.firstMatch
        if inApp.exists {
            Self.dismissButton(in: inApp)?.tap()
        }
    }

    /// The button that makes an alert go away, whichever of the usual labels
    /// it happens to carry. Permission alerts are answered "don't allow" so
    /// the screenshots show the app rather than a system prompt.
    private static func dismissButton(in alert: XCUIElement) -> XCUIElement? {
        for label in ["Don't Allow", "Dont Allow", "Allow", "OK", "Cancel"] {
            let button = alert.buttons[label]
            if button.exists { return button }
        }
        return nil
    }
}
