//
//  Colors.swift
//  YabaSnashiro
//
//  Created by Shinya Miyamoto on 2024/08/01.
//  Copyright © 2024 devMiyax. All rights reserved.
//

import UIKit

/// Legacy color aliases, kept only so the remaining UIKit screens (emulator,
/// pad settings, cheats, achievements, menus) keep compiling. Each one now
/// resolves to a Material 3 token from AppPalette, so those screens follow the
/// shared theme without touching their call sites.
///
/// New code must use `Color.theme*` (SwiftUI) or `UIColor.theme*` (UIKit)
/// instead of anything in this file.
///
/// The app is dark only (see AppDelegate.applyWindowAppearance), so these are
/// plain values rather than trait-dependent dynamic colors.
extension UIColor {
    // MARK: - Palette roles

    /// Accent. Was purple 0x8888d5, now the Material 3 primary.
    static var tint: UIColor { .themePrimary }

    static var defaultBackground: UIColor { .themeBackground }

    static var colorPrimary: UIColor { .themeSurface }

    static var colorAccent: UIColor { .themePrimary }

    static var secondary: UIColor { .themeSecondary }

    static var appError: UIColor { .themeError }

    // MARK: - Text roles

    static var adaptiveTextColor: UIColor { .themeOnSurface }

    static var headerTextColor: UIColor { .themePrimary }

    static var appWhite: UIColor { .themeOnSurface }

    static var appBlack: UIColor { .themeSurfaceContainerLowest }

    static var appDisable: UIColor { .themeOnSurfaceVariant }

    static var titleBack: UIColor { .themeOnSurface }

    // MARK: - Surface roles

    static var selectedBackground: UIColor { .themeSecondaryContainer }

    static var cardviewInitialBackground: UIColor { .themeSurfaceContainerHigh }

    static var detailBackground: UIColor { .themeSurfaceContainer }

    static var fastlaneBackground: UIColor { .themeSurfaceContainerLow }

    static var searchOpaque: UIColor { .themeSecondaryContainer }

    // MARK: - Warm accents
    //
    // Stars, warnings and highlights. These stay literal: Material 3 has no
    // matching semantic role and Android uses fixed warm values here too.

    static var appYellow: UIColor { UIColor(hex: 0xEEFF41) }

    static var appOrange: UIColor { UIColor(hex: 0xFADCA7) }

    static var orangeTransparent: UIColor { UIColor(hex: 0xFADCA7, alpha: 0.67) }

    // MARK: - Overlays
    //
    // Scrims and gradients drawn over artwork, not palette roles, so they keep
    // their original alpha behavior.

    static var softOpaque: UIColor { UIColor(hex: 0x000000, alpha: 0.3) }

    static var blackOpaque: UIColor { UIColor(hex: 0x000000, alpha: 0.67) }

    static var halfTransparent: UIColor { UIColor(hex: 0x000000, alpha: 0.8) }

    static var imgSoftOpaque: UIColor { UIColor(hex: 0xFF0000, alpha: 0.3) }

    static var imgFullOpaque: UIColor { UIColor(hex: 0x000000, alpha: 0.0) }

    static var backgroundGradientStart: UIColor { UIColor(hex: 0x000000) }

    static var backgroundGradientEnd: UIColor { UIColor(hex: 0xDDDDDD) }

    // MARK: - Hex Initializer

    convenience init(hex: Int, alpha: CGFloat = 1.0) {
        let red = CGFloat((hex & 0xFF0000) >> 16) / 255.0
        let green = CGFloat((hex & 0x00FF00) >> 8) / 255.0
        let blue = CGFloat(hex & 0x0000FF) / 255.0

        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }
}
