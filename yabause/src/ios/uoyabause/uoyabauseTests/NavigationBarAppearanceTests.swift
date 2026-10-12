//
//  NavigationBarAppearanceTests.swift
//  YabaSnashiroTests
//
//  Copyright (c) 2026 devMiyax. All rights reserved.
//

import UIKit
import XCTest
@testable import YabaSnashiro

/// Guards the navigation bar appearance proxy configured by AppDelegate.
///
/// An opaque scrollEdgeAppearance installed here stops iOS 26 from drawing the
/// large title whenever scrollable content sits directly under the bar, which
/// left the Games, Settings and Account tabs with a blank navigation bar on an
/// iPhone 16 Pro running iOS 26.1. It cannot be caught by a UI test: the title
/// is still reported by the accessibility tree at its normal frame, it simply
/// is not rendered. So the configuration itself is what we assert.
final class NavigationBarAppearanceTests: XCTestCase {

    func testScrollEdgeAppearanceIsLeftAtTheSystemDefault() {
        XCTAssertNil(UINavigationBar.appearance().scrollEdgeAppearance,
                     "A custom scrollEdgeAppearance suppresses the large title "
                     + "on iOS 26. Style the bar through standardAppearance.")
    }

    /// The rest of the bar styling must survive: this is what paints the
    /// Material 3 surface once the user scrolls away from the top.
    func testStandardAppearanceKeepsTheMaterialSurface() {
        let standard = UINavigationBar.appearance().standardAppearance
        XCTAssertEqual(standard.backgroundColor, UIColor.themeSurface)
        XCTAssertEqual(
            standard.largeTitleTextAttributes[.foregroundColor] as? UIColor,
            UIColor.themeOnSurface)
    }
}
