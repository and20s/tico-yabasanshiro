//
//  DetailPane.swift
//  YabaSnashiro
//
//  Copyright (c) 2026 devMiyax. All rights reserved.
//

import SwiftUI

/// Where a detail view is being shown. The same body serves both, the way
/// Android's landscape detail panel `<include>`s the bottom sheet layout
/// rather than forking it, but the two contexts differ in how they close.
enum DetailPresentation {
    /// Modal sheet over a compact-width list.
    case sheet
    /// Persistent right-hand pane of the regular-width two-pane layout.
    case pane
}

/// Shared geometry for the regular-width list + detail layouts.
enum DetailPane {
    /// Android splits its panes 1:1, which is its number for a phone in
    /// landscape. These list rows are short, so half of an iPad is far more
    /// width than the list can use and it is width the detail wants; a third,
    /// clamped to a comfortable reading column, leaves the detail the larger
    /// share in both orientations.
    static func listWidth(for totalWidth: CGFloat) -> CGFloat {
        min(400, max(300, totalWidth / 3))
    }
}

/// Fills a detail pane while nothing is selected. Mirrors the centred
/// placeholder Android shows in its landscape detail_panel, so the pane never
/// reads as a blank void.
struct DetailPanePlaceholderView: View {
    let systemImage: String
    let text: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(Color.themeOnSurfaceVariant)
                .opacity(0.5)
            Text(text)
                .font(.title3)
                .foregroundStyle(Color.themeOnSurfaceVariant)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
