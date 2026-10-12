//
//  UIColor+AppTheme.swift
//  YabaSnashiro
//
//  Copyright © 2026 devMiyax. All rights reserved.
//

import UIKit

/// Material Design 3 semantic colors for the UIKit screens (the emulator,
/// pad settings, cheats and achievements). SwiftUI code should use the
/// matching Color.theme* tokens instead.
///
/// Values come from AppPalette, which mirrors the Android theme.
extension UIColor {
    // MARK: - Accent roles

    static var themePrimary: UIColor { UIColor(hex: AppPalette.primary) }
    static var themeOnPrimary: UIColor { UIColor(hex: AppPalette.onPrimary) }
    static var themePrimaryContainer: UIColor { UIColor(hex: AppPalette.primaryContainer) }
    static var themeOnPrimaryContainer: UIColor { UIColor(hex: AppPalette.onPrimaryContainer) }

    static var themeSecondary: UIColor { UIColor(hex: AppPalette.secondary) }
    static var themeSecondaryContainer: UIColor { UIColor(hex: AppPalette.secondaryContainer) }
    static var themeOnSecondaryContainer: UIColor { UIColor(hex: AppPalette.onSecondaryContainer) }

    static var themeTertiary: UIColor { UIColor(hex: AppPalette.tertiary) }

    // MARK: - Status roles

    static var themeError: UIColor { UIColor(hex: AppPalette.error) }
    static var themeOnError: UIColor { UIColor(hex: AppPalette.onError) }
    static var themeErrorContainer: UIColor { UIColor(hex: AppPalette.errorContainer) }
    static var themeOnErrorContainer: UIColor { UIColor(hex: AppPalette.onErrorContainer) }

    // MARK: - Surfaces

    static var themeBackground: UIColor { UIColor(hex: AppPalette.background) }
    static var themeSurface: UIColor { UIColor(hex: AppPalette.surface) }
    static var themeOnSurface: UIColor { UIColor(hex: AppPalette.onSurface) }
    static var themeSurfaceVariant: UIColor { UIColor(hex: AppPalette.surfaceVariant) }
    static var themeOnSurfaceVariant: UIColor { UIColor(hex: AppPalette.onSurfaceVariant) }

    static var themeSurfaceContainerLowest: UIColor { UIColor(hex: AppPalette.surfaceContainerLowest) }
    static var themeSurfaceContainerLow: UIColor { UIColor(hex: AppPalette.surfaceContainerLow) }
    static var themeSurfaceContainer: UIColor { UIColor(hex: AppPalette.surfaceContainer) }

    /// The standard card background, matching Android's MaterialCardView.
    static var themeSurfaceContainerHigh: UIColor { UIColor(hex: AppPalette.surfaceContainerHigh) }
    static var themeSurfaceContainerHighest: UIColor { UIColor(hex: AppPalette.surfaceContainerHighest) }

    // MARK: - Lines and overlays

    static var themeOutline: UIColor { UIColor(hex: AppPalette.outline) }
    static var themeOutlineVariant: UIColor { UIColor(hex: AppPalette.outlineVariant) }
    static var themeScrim: UIColor { UIColor(hex: AppPalette.scrim, alpha: 0.67) }

    // MARK: - Fixed accents

    static var themeRating: UIColor { UIColor(hex: AppPalette.rating) }
}
