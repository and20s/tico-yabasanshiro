import SwiftUI
import Kingfisher

/// Game detail bottom sheet. Element parity with the Android
/// bottom_sheet_game_detail (shortcut creation intentionally excluded).
struct GameDetailSheet: View {
    @StateObject private var detail: GameDetailViewModel
    /// Row focus plus the two dialog flags. Also this view's focus scope, so
    /// A and B reach Play / File Info / Remove instead of the list behind it.
    @StateObject private var rows: GameDetailFocusModel
    @Environment(\.dismiss) private var dismiss

    private let presentation: DetailPresentation
    /// Where this view declares its focus scope. Optional so previews and
    /// tests can build it without one.
    private let focus: ControllerFocusCoordinator?
    /// Called instead of `dismiss` when there is no sheet to dismiss, so the
    /// pane can drop its selection back to the placeholder.
    private let onClose: (() -> Void)?

    init(item: GameItem,
         viewModel: GameListViewModel,
         presentation: DetailPresentation = .sheet,
         focus: ControllerFocusCoordinator? = nil,
         onClose: (() -> Void)? = nil) {
        _detail = StateObject(wrappedValue:
            GameDetailViewModel(item: item, listViewModel: viewModel))
        _rows = StateObject(wrappedValue:
            GameDetailFocusModel(isModal: presentation == .sheet))
        self.presentation = presentation
        self.focus = focus
        self.onClose = onClose
    }

    private var item: GameItem { detail.item }

    /// Height taken by everything between the box art and the bottom of the
    /// Play row: title, product number, divider, meta row, spacing, padding
    /// and the buttons themselves. The art gets whatever is left, so Play
    /// stays visible without scrolling however tall the jacket scan is.
    private static let headerChromeHeight: CGFloat = 215

    /// Chrome below the art in a pane. Unlike the sheet, which only has to
    /// keep Play reachable, a pane is expected to show every control without
    /// scrolling, so this covers the title, product number, divider, meta row,
    /// the Play row AND the Remove row, plus spacing and padding.
    private static let paneChromeHeight: CGFloat = 265

    /// The RetroAchievements card, added only when the game has achievements.
    private static let paneRetroAchievementsHeight: CGFloat = 134

    /// Height available to the art. Driving the art from height rather than
    /// width matters for non-Japanese releases, whose jackets are portrait: at
    /// a pane's width those would tower over the controls.
    private func maxArtHeight(in available: CGFloat) -> CGFloat {
        switch presentation {
        case .sheet:
            return max(120, available - Self.headerChromeHeight)
        case .pane:
            let chrome = Self.paneChromeHeight
                + (item.raTotal > 0 ? Self.paneRetroAchievementsHeight : 0)
            return max(120, available - chrome)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(maxArtHeight: maxArtHeight(in: geometry.size.height))
                    actionButtons
                    if item.raTotal > 0 { raSection }
                    deleteSection
                }
                .padding(16)
            }
        }
        .controllerFocusScope(rows, in: focus)
        .onAppear {
            rows.onPlay = { startGame() }
            rows.onDismiss = { close() }
            rows.onConfirmDelete = {
                Task {
                    await detail.delete()
                    close()
                }
            }
        }
        .presentationDragIndicator(.visible)
        // A pane sits on the slightly raised surface Android gives
        // detail_panel; a sheet keeps the plain background it always had.
        .background(presentation == .pane
                    ? Color.themeSurfaceContainerLow
                    : Color.themeBackground)
        .task { await detail.refreshRating() }
        .confirmationDialog(
            String(localized: "Delete this game?", comment: "Delete confirm title"),
            isPresented: $rows.showDeleteConfirm, titleVisibility: .visible) {
            Button(String(localized: "Delete", comment: "Delete"), role: .destructive) {
                Task {
                    await detail.delete()
                    close()
                }
            }
        }
        .alert(String(localized: "File Info", comment: "File info title"),
               isPresented: $rows.showFileInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("\(item.filePath)\n\(item.productNumber)\n\(item.deviceInformation)")
        }
    }

    /// Vertical stack mirroring bottom_sheet_game_detail: hero box art,
    /// title, product number, divider, then the meta row.
    private func header(maxArtHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            boxArt(maxHeight: maxArtHeight)
            Text(item.displayName)
                .font(.title2)
                .foregroundStyle(Color.themeOnSurface)
                .padding(.top, 12)
            Text(item.productNumber)
                .font(.subheadline)
                .foregroundStyle(Color.themeOnSurfaceVariant)
                .padding(.top, 4)
            Divider()
                .overlay(Color.themeOutlineVariant)
                .padding(.vertical, 12)
            metaRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Full width minus the Android 32dp side margin, height driven by the
    /// image aspect ratio (adjustViewBounds + fitCenter on Android) but capped
    /// so a portrait jacket cannot push the Play button off the sheet. The cap
    /// grows with the sheet, so dragging up to the large detent shows the art
    /// at its full hero size.
    private func boxArt(maxHeight: CGFloat) -> some View {
        KFImage(item.imageUrl.flatMap(URL.init(string:)))
            .placeholder { Image("missing").resizable().scaledToFit() }
            .resizable()
            .scaledToFit()
            // Height is the governing constraint. A width cap would size a
            // portrait jacket by its narrow edge and let it run tall, which is
            // exactly what pushes the controls off a pane.
            .frame(maxHeight: maxHeight)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, presentation == .pane ? 0 : 32)
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityLabel(String(localized: "Box art",
                                       comment: "Box art image description"))
    }

    private var metaRow: some View {
        HStack(spacing: 12) {
            Label(item.formattedReleaseDate, systemImage: "calendar")
                .font(.footnote)
                .foregroundStyle(Color.themeOnSurfaceVariant)
            if item.rating > 0 {
                HStack(spacing: 1) {
                    ForEach(0..<5, id: \.self) { index in
                        Image(systemName: index < item.rating ? "star.fill" : "star")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.themeRating)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button {
                startGame()
            } label: {
                Label(String(localized: "Play", comment: "Play button"),
                      systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(Color.themeOnPrimary)
            .controlSize(.large)
            .controllerFocusRing(rows.focused == GameDetailFocusModel.Row.play.rawValue)

            Menu {
                Button {
                    rows.showFileInfo = true
                } label: {
                    Label(String(localized: "File Info", comment: "File info menu"),
                          systemImage: "doc.text.magnifyingglass")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 44)
                    .background(Color.themeSurfaceContainerHigh)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .accessibilityLabel(String(localized: "More", comment: "More actions menu"))
            .controllerFocusRing(
                rows.focused == GameDetailFocusModel.Row.fileInfo.rawValue)
        }
    }

    /// Closes this detail view: dismisses the sheet, or tells the two-pane
    /// layout to clear its selection when there is no sheet to dismiss.
    private func close() {
        if let onClose = onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    /// Presents the emulator.
    ///
    /// As a sheet this has to dismiss first and launch from the controller
    /// that presented the sheet, because presenting from a controller that is
    /// being dismissed fails; the launch therefore waits for the dismissal
    /// completion rather than using the SwiftUI dismiss action. As a pane
    /// nothing is presented over the library, so the top controller is the
    /// right presenter and dismissing it would tear down the whole tab.
    private func startGame() {
        guard let top = GameLauncher.topViewController() else { return }
        guard presentation == .sheet else {
            detail.play(from: top)
            return
        }
        guard let presenter = top.presentingViewController else {
            dismiss()
            return
        }
        presenter.dismiss(animated: true) {
            detail.play(from: presenter)
        }
    }

    private var raSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("RetroAchievements", systemImage: "trophy")
                .font(.subheadline.weight(.semibold))
            ProgressView(value: Double(item.raUnlocked), total: Double(item.raTotal))
                .tint(Color.themeRating)
            Text("\(item.raUnlocked)/\(item.raTotal)")
                .font(.caption).foregroundStyle(.secondary)
            ProgressView(value: Double(item.raUnlockedHardcore), total: Double(item.raTotal))
                .tint(Color.themeError)
            Text(String(localized: "Hardcore", comment: "Hardcore progress label")
                 + ": \(item.raUnlockedHardcore)/\(item.raTotal)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.themeSurfaceContainerHigh)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var deleteSection: some View {
        Button(role: .destructive) {
            rows.showDeleteConfirm = true
        } label: {
            Label(String(localized: "Remove from list", comment: "Delete game"),
                  systemImage: "trash")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.themeSurfaceContainerHigh)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        // Material 3 error role, not the iOS system red.
        .foregroundStyle(Color.themeError)
        .controllerFocusRing(rows.focused == GameDetailFocusModel.Row.remove.rawValue)
    }
}
