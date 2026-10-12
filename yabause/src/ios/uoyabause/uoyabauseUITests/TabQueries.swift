//
//  TabQueries.swift
//  YabaSnashiroUITests
//
//  Tab lookups that do not assume how SwiftUI rendered the TabView.
//  Copyright (c) 2026 devMiyax. All rights reserved.
//

import XCTest

/// The home destinations are drawn three different ways. Compact width gets
/// the classic bottom UITabBar. Regular width gets the sidebar MainTabView
/// builds on NavigationSplitView, whose entries are List rows, not buttons.
/// (Before the sidebar, iPadOS 18+ drew the same `TabView` as a floating top
/// bar; that path is kept below because a top bar is still what a plain
/// TabView produces on iPad.) Only the first of the three is exposed to
/// XCUITest as an element of type `.tabBar`, so `app.tabBars` is empty on
/// iPad and any assertion built on it fails before the test body runs. Every
/// helper here therefore falls back to buttons and then to cells, and the
/// "the app is up" signal is the Games tab's navigation title rather than the
/// existence of a bar.
extension XCUIApplication {

    /// Waits until the home UI has finished launching. Games is the tab
    /// selected on launch, so its navigation title appears whichever way the
    /// tabs themselves are drawn.
    @discardableResult
    func waitForHomeUI(timeout: TimeInterval = 30) -> Bool {
        // Not the navigation title: screenshot runs launch the app in six
        // languages and the title is translated in every one of them. The
        // Games tab's SF Symbol is the accessibility identifier and is not
        // translated, so it is the same signal everywhere. A navigation bar
        // of any name is accepted as a fallback, since the home screen always
        // has one and no earlier launch screen does.
        let gamesTab = buttons.matching(identifier: "gamecontroller").firstMatch
        if gamesTab.waitForExistence(timeout: timeout) { return true }
        return navigationBars.firstMatch.waitForExistence(timeout: 5)
    }

    /// The button that selects the named tab, wherever it lives.
    /// Call after `waitForHomeUI()` so the bar, if there is one, exists.
    ///
    /// `firstMatch` is not decoration: iPadOS publishes each button of its top
    /// tab bar twice, as two elements with the same label, identifier and
    /// frame, so an unqualified query resolves to "multiple matching elements"
    /// and the tap fails. Either duplicate works; take the first.
    func tabButton(_ name: String) -> XCUIElement {
        if tabBars.firstMatch.exists {
            // A UITabBar button carries only its translated label. The symbol
            // name lives on the button's child Image, and it is the *filled*
            // variant UIKit uses for a tab item, not the one MainTabView
            // names -- "externaldrive.fill.badge.icloud", not
            // "externaldrive.badge.icloud".
            if let filled = Self.tabFilledSymbols[name] {
                let byImage = tabBars.buttons.containing(.image, identifier: filled)
                if byImage.count > 0 { return byImage.firstMatch }
            }
            // Position is the last resort, and a reliable one: the five tabs
            // are written out in a fixed order and no language reorders them.
            if let index = Self.tabOrder.firstIndex(of: name),
               tabBars.buttons.count > index {
                return tabBars.buttons.element(boundBy: index)
            }
            return tabBars.buttons[name].firstMatch
        }
        // The label is localized, so on a device running in another language
        // it will not be the English name the tests use. Every entry carries
        // its SF Symbol name as the accessibility identifier, which is not
        // localized, so that is tried too.
        //
        // A sidebar row is neither a tab-bar button nor a plain button: the
        // row is an unlabelled Cell whose tappable, row-sized child is a
        // StaticText. Matching that by identifier rather than by label also
        // keeps it apart from the detail column's navigation title, which
        // carries the same text but no identifier.
        let symbol = Self.tabSymbols[name] ?? name
        let candidates: [XCUIElementQuery] = [
            buttons.matching(NSPredicate(format: "label == %@", name)),
            buttons.matching(identifier: symbol),
            staticTexts.matching(identifier: symbol),
            cells.matching(identifier: symbol),
        ]
        for candidate in candidates where candidate.count > 0 {
            return candidate.firstMatch
        }
        return buttons[symbol].firstMatch
    }

    /// Tab name to the SF Symbol MainTabView gives that entry, which surfaces
    /// as its accessibility identifier.
    /// The order MainTabView writes the tabs in, which is also the order the
    /// tab bar draws them.
    private static let tabOrder = ["Games", "Backup", "Add", "Settings", "Account"]

    /// What UIKit puts on a selected tab item's image.
    private static let tabFilledSymbols = [
        "Games": "gamecontroller.fill",
        "Backup": "externaldrive.fill.badge.icloud",
        "Add": "plus.circle.fill",
        "Settings": "gearshape.fill",
        "Account": "person.circle.fill",
    ]

    private static let tabSymbols = [
        "Games": "gamecontroller",
        "Backup": "externaldrive.badge.icloud",
        "Add": "plus.circle",
        "Settings": "gearshape",
        "Account": "person.circle",
    ]

    /// The rows of one named list.
    ///
    /// Not `app.cells`: on regular width the sidebar is itself a collection
    /// of cells, so an unscoped row query matches its five entries and any
    /// "did the list show anything?" assertion passes on an empty list.
    /// The lists that tests look at carry an accessibility identifier.
    func rows(ofList identifier: String) -> XCUIElementQuery {
        collectionViews[identifier].cells
    }

    /// Whether the named tab is the selected one, or `nil` when this platform
    /// does not report tab selection at all.
    ///
    /// A real UITabBar marks its selected button `isSelected`. Neither the
    /// iPadOS top tab bar nor the sidebar reports selection that way, so
    /// there is nothing to assert on there; callers must read `nil` as
    /// "cannot tell" and lean on the visible content instead.
    func tabSelectionState(_ name: String) -> Bool? {
        guard tabBars.firstMatch.exists else { return nil }
        return tabBars.buttons[name].isSelected
    }
}
