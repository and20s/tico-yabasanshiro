//
//  Color+AppTheme.swift
//  YabaSnashiro
//
//  Copyright © 2026 devMiyax. All rights reserved.
//

import SwiftUI

/// Material Design 3 semantic colors for SwiftUI, mirroring the Android theme.
///
/// Pick a token by role, not by appearance:
///   - themeBackground        screen behind everything
///   - themeSurfaceContainer* cards and grouped rows (High is the default card)
///   - themeOnSurface         primary text and icons
///   - themeOnSurfaceVariant  secondary text, captions, disabled glyphs
///   - themePrimary           accent: tints, selected states, prominent buttons
///   - themeError             destructive actions and failure states
extension Color {
    // MARK: - Accent roles

    static let themePrimary = Color(UIColor.themePrimary)
    static let themeOnPrimary = Color(UIColor.themeOnPrimary)
    static let themePrimaryContainer = Color(UIColor.themePrimaryContainer)
    static let themeOnPrimaryContainer = Color(UIColor.themeOnPrimaryContainer)

    static let themeSecondary = Color(UIColor.themeSecondary)
    static let themeSecondaryContainer = Color(UIColor.themeSecondaryContainer)
    static let themeOnSecondaryContainer = Color(UIColor.themeOnSecondaryContainer)

    static let themeTertiary = Color(UIColor.themeTertiary)

    // MARK: - Status roles

    static let themeError = Color(UIColor.themeError)
    static let themeOnError = Color(UIColor.themeOnError)
    static let themeErrorContainer = Color(UIColor.themeErrorContainer)
    static let themeOnErrorContainer = Color(UIColor.themeOnErrorContainer)

    // MARK: - Surfaces

    static let themeBackground = Color(UIColor.themeBackground)
    static let themeSurface = Color(UIColor.themeSurface)
    static let themeOnSurface = Color(UIColor.themeOnSurface)
    static let themeSurfaceVariant = Color(UIColor.themeSurfaceVariant)
    static let themeOnSurfaceVariant = Color(UIColor.themeOnSurfaceVariant)

    static let themeSurfaceContainerLowest = Color(UIColor.themeSurfaceContainerLowest)
    static let themeSurfaceContainerLow = Color(UIColor.themeSurfaceContainerLow)
    static let themeSurfaceContainer = Color(UIColor.themeSurfaceContainer)

    /// The standard card background, matching Android's MaterialCardView.
    static let themeSurfaceContainerHigh = Color(UIColor.themeSurfaceContainerHigh)
    static let themeSurfaceContainerHighest = Color(UIColor.themeSurfaceContainerHighest)

    // MARK: - Lines and overlays

    static let themeOutline = Color(UIColor.themeOutline)
    static let themeOutlineVariant = Color(UIColor.themeOutlineVariant)
    static let themeScrim = Color(UIColor.themeScrim)

    // MARK: - Fixed accents

    static let themeRating = Color(UIColor.themeRating)
}
