//
//  GameDetailPlaceholderView.swift
//  YabaSnashiro
//
//  Copyright (c) 2026 devMiyax. All rights reserved.
//

import SwiftUI

/// Fills the detail pane of the regular-width games layout while nothing is
/// selected. Mirrors the centred "Select a game" placeholder Android shows in
/// its landscape detail_panel.
struct GameDetailPlaceholderView: View {
    var body: some View {
        DetailPanePlaceholderView(
            systemImage: "gamecontroller",
            text: String(localized: "Select a game",
                         comment: "Games detail pane placeholder"))
            // Only the two-pane layout draws this, so its presence is how a
            // test tells the layouts apart without naming device models. The
            // text above is translated; this is not.
            .accessibilityIdentifier("gameDetailPlaceholder")
    }
}
