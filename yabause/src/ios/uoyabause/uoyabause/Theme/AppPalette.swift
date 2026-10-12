//
//  AppPalette.swift
//  YabaSnashiro
//
//  Copyright © 2026 devMiyax. All rights reserved.
//

import Foundation

/// Material Design 3 dark color tokens, mirroring the Android app so both
/// platforms render the same theme.
///
/// The Android theme is Theme.Material3.Dark.NoActionBar and ships no light
/// variant, so these values are unconditional and the app forces dark mode
/// (see AppDelegate.applyWindowAppearance and UIUserInterfaceStyle in
/// Info.plist). Do not add trait-dependent variants here; a half-light theme
/// would diverge from Android.
///
/// Keep in sync with:
///   yabause/src/android/app/src/main/res/values/colors.xml (md_theme_*)
enum AppPalette {
    // MARK: - Accent roles

    static let primary = 0xBAC7DE
    static let onPrimary = 0x243143
    static let primaryContainer = 0x8491A7
    static let onPrimaryContainer = 0x030F20

    static let secondary = 0xC2C6D1
    static let onSecondary = 0x2C3139
    static let secondaryContainer = 0x454952
    static let onSecondaryContainer = 0xB4B8C2

    static let tertiary = 0xDABED5
    static let onTertiary = 0x3D2A3C
    static let tertiaryContainer = 0xA2899F
    static let onTertiaryContainer = 0x19091A

    // MARK: - Status roles

    static let error = 0xFFB4AB
    static let onError = 0x690005
    static let errorContainer = 0x93000A
    static let onErrorContainer = 0xFFDAD6

    // MARK: - Surfaces

    static let background = 0x131315
    static let onBackground = 0xE4E2E3
    static let surface = 0x131315
    static let onSurface = 0xE4E2E3
    static let surfaceVariant = 0x44474C
    static let onSurfaceVariant = 0xC5C6CD

    /// Elevation ladder. Cards use surfaceContainerHigh, matching the Android
    /// MaterialCardView convention documented in src/android/CLAUDE.md.
    static let surfaceContainerLowest = 0x0E0E0F
    static let surfaceContainerLow = 0x1B1B1D
    static let surfaceContainer = 0x1F1F21
    static let surfaceContainerHigh = 0x2A2A2B
    static let surfaceContainerHighest = 0x343536

    // MARK: - Lines and overlays

    static let outline = 0x8F9197
    static let outlineVariant = 0x44474C
    static let scrim = 0x000000
    static let inverseSurface = 0xE4E2E3
    static let inverseOnSurface = 0x303032

    // MARK: - Fixed accents

    /// Star ratings and other "always warm" affordances. Android uses
    /// colorRating for the same purpose.
    static let rating = 0xFFD700
}
