import SwiftUI

/// Detail of one cloud save: screenshot, metadata, download into a local
/// backup file and delete from the cloud. Mirrors BackupDetailSheet.
struct CloudBackupDetailSheet: View {
    let item: CloudBackupItem
    @ObservedObject var cloudViewModel: CloudBackupViewModel
    @ObservedObject var localViewModel: BackupListViewModel
    @Environment(\.dismiss) private var dismiss

    /// Sheet or two-pane detail. Only affects how the view finishes: every
    /// action below used to end in `dismiss()`, which is a no-op when there is
    /// no sheet to dismiss and would leave a deleted backup on screen.
    var presentation: DetailPresentation = .sheet
    /// Called instead of `dismiss` in a pane, so the pane can drop its
    /// selection back to the placeholder.
    var onClose: (() -> Void)?
    /// Where this screen declares its focus scope.
    var focus: ControllerFocusCoordinator?

    @State private var showDeleteConfirm = false
    @State private var pendingOverwrite: BackupFile?
    /// A download is running: the buttons give way to a spinner so the user
    /// cannot start a second repository call on top of the first.
    @State private var isWorking = false
    @Environment(\.isControllerConnected) private var isControllerConnected

    @StateObject private var scope =
        ActionListFocusModel(scopeName: "cloudBackupDetail")

    /// Download targets then delete, in the order they are drawn. Read in one
    /// place so the rings and the scope cannot disagree about the index.
    private var destinations: [BackupFile] { localViewModel.availableFiles }
    private var deleteRowIndex: Int { destinations.count }

    /// The repository is created once per sheet; every call it makes goes
    /// through BackupWorkQueue inside the view model.
    private let local = LocalBackupRepository()

    private var formattedDate: String {
        guard let date = item.saveDate else { return "-" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                screenshot
                details
                if isWorking {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                } else {
                    downloadSection
                    deleteButton
                }
            }
            .padding(16)
        }
        .followsControllerFocus(scope.focused, in: proxy) { $0 }
        }
        .presentationDragIndicator(.visible)
        .background(Color.themeBackground)
        .controllerFocusScope(scope, in: focus)
        .onAppear { configureScope() }
        .onChange(of: destinations.count) { _ in declareRows() }
        .onChange(of: isWorking) { _ in declareRows() }
        .onChange(of: isControllerConnected) {
            scope.applyInitialFocus(controllerConnected: $0)
        }
        .confirmationDialog(
            String(localized: "Delete this cloud backup?",
                   comment: "Cloud delete confirm title"),
            isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button(String(localized: "Delete", comment: "Delete"), role: .destructive) {
                Task {
                    await cloudViewModel.delete(key: item.key)
                    close()
                }
            }
        }
        .confirmationDialog(
            String(localized: "A save with this name already exists. Overwrite it?",
                   comment: "Copy overwrite confirm"),
            isPresented: Binding(get: { pendingOverwrite != nil },
                                 set: { if !$0 { pendingOverwrite = nil } }),
            titleVisibility: .visible) {
            Button(String(localized: "Overwrite", comment: "Overwrite"),
                   role: .destructive) {
                if let destination = pendingOverwrite {
                    pendingOverwrite = nil
                    Task { await restore(into: destination) }
                }
            }
        }
    }

    // MARK: - Controller focus

    private func configureScope() {
        scope.isModal = presentation == .sheet
        // A pane is a column beside the list, which D-pad Left/Right
        // moves between; a sheet covers the list instead.
        scope.pane = presentation == .pane ? .detail : nil
        // A confirmationDialog draws its own selection, which the app cannot
        // move, so A must not act on the row behind it.
        scope.isBlocked = { showDeleteConfirm || pendingOverwrite != nil }
        // A answers whichever dialog owns the screen. Without this a
        // controller could open one but never confirm it.
        scope.onConfirm = {
            if showDeleteConfirm {
                showDeleteConfirm = false
                Task {
                    await cloudViewModel.delete(key: item.key)
                    close()
                }
                return true
            }
            if let destination = pendingOverwrite {
                pendingOverwrite = nil
                Task { await restore(into: destination) }
                return true
            }
            return false
        }
        // B unwinds one step: an open dialog first, then the detail itself.
        scope.onClose = {
            if showDeleteConfirm {
                showDeleteConfirm = false
                return true
            }
            if pendingOverwrite != nil {
                pendingOverwrite = nil
                return true
            }
            close()
            return true
        }
        declareRows()
    }

    /// The actionable rows, in the order they are drawn. A download replaces
    /// them all with a spinner, so during one there is nothing to focus.
    private func declareRows() {
        guard !isWorking else {
            scope.setActions([])
            return
        }
        var actions: [() -> Void] = destinations.map { destination in
            { startRestore(to: destination) }
        }
        actions.append { showDeleteConfirm = true }
        scope.setActions(actions)
        scope.applyInitialFocus(controllerConnected: isControllerConnected)
    }

    /// A pane is far wider than a phone sheet, and this screenshot is a
    /// 4:3 Saturn frame: at full pane width it becomes tall enough to push
    /// the download and delete actions off the first screenful. Cap it to
    /// roughly the width it would have had on a phone.
    private static let paneMaxScreenshotWidth: CGFloat = 320

    private var maxScreenshotWidth: CGFloat {
        presentation == .pane ? Self.paneMaxScreenshotWidth : .infinity
    }

    @ViewBuilder
    private var screenshot: some View {
        if let text = item.screenshotURL, let url = URL(string: text) {
            AsyncImage(url: url) { image in
                image
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: maxScreenshotWidth)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } placeholder: {
                EmptyView()
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.filename).font(.headline)
            if !item.comment.isEmpty {
                Text(item.comment).font(.subheadline).foregroundStyle(.secondary)
            }
            if let title = item.gameTitle, !title.isEmpty {
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            if let product = item.productNumber, !product.isEmpty {
                Text(product).font(.caption).foregroundStyle(.secondary)
            }
            Label(formattedDate, systemImage: "calendar")
                .font(.caption).foregroundStyle(.secondary)
            Text("\(item.displaySize) \u{00B7} \(item.blockSize) "
                 + String(localized: "blocks", comment: "Backup block count unit"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var downloadSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Download to",
                        comment: "Cloud download destination header"))
                .font(.subheadline.weight(.semibold))
            ForEach(Array(destinations.enumerated()),
                    id: \.element.id) { index, destination in
                Button {
                    startRestore(to: destination)
                } label: {
                    HStack {
                        Label(destination.displayName, systemImage: "icloud.and.arrow.down")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                            // Decorative: keep it out of the button's label.
                            .accessibilityHidden(true)
                    }
                    .padding(12)
                    .controllerFocusRing(scope.focused == index,
                                         cornerRadius: 10,
                                         base: Color.themeSurfaceContainerHigh)
                    .id(index)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            showDeleteConfirm = true
        } label: {
            Label(String(localized: "Delete from cloud",
                         comment: "Delete cloud backup"),
                  systemImage: "trash")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .controllerFocusRing(scope.focused == deleteRowIndex,
                                     cornerRadius: 10,
                                     base: Color.themeSurfaceContainerHigh)
                    .id(deleteRowIndex)
        }
    }

    /// saveExists is async (it serializes against the backup session), so the
    /// overwrite check happens in a Task before either confirming or writing.
    private func startRestore(to destination: BackupFile) {
        Task {
            if await localViewModel.saveExists(filename: item.filename,
                                               in: destination) {
                pendingOverwrite = destination
                return
            }
            await restore(into: destination)
        }
    }

    private func restore(into destination: BackupFile) async {
        isWorking = true
        let succeeded = await cloudViewModel.restore(item: item, into: destination,
                                                     using: local)
        await localViewModel.load()
        isWorking = false
        // The backup itself is still in the cloud after a download, so only a
        // sheet needs to get out of the way; a pane keeps showing it.
        if succeeded, presentation == .sheet { dismiss() }
    }

    /// Stops showing this backup, because it no longer exists. Dismisses the
    /// sheet, or tells the two-pane layout to drop its selection back to the
    /// placeholder - `dismiss()` is a no-op in a pane, which would have left
    /// a deleted backup on screen.
    private func close() {
        if let onClose = onClose {
            onClose()
        } else {
            dismiss()
        }
    }
}
