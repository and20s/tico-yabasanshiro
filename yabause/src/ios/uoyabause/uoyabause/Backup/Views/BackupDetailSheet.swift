import SwiftUI
import FirebaseAuth

/// Detail of one save: screenshot, metadata, copy, cloud upload and delete.
/// The Android sheet also offers sharing; that arrives in SP3c.
struct BackupDetailSheet: View {
    let save: BackupSave
    @ObservedObject var viewModel: BackupListViewModel
    @ObservedObject var cloudViewModel: CloudBackupViewModel
    @Environment(\.dismiss) private var dismiss

    /// Sheet or two-pane detail. Only affects how the view finishes: every
    /// action below used to end in `dismiss()`, which is a no-op when there is
    /// no sheet to dismiss and would leave a deleted save on screen.
    var presentation: DetailPresentation = .sheet
    /// Called instead of `dismiss` in a pane, so the pane can drop its
    /// selection back to the placeholder.
    var onClose: (() -> Void)?
    /// Where this screen declares its focus scope.
    var focus: ControllerFocusCoordinator?

    @State private var showDeleteConfirm = false
    @State private var pendingOverwrite: BackupFile?
    @State private var isUploading = false
    /// Set when the upload row is tapped without an entitlement.
    @State private var gateReason: ProGateReason?
    /// Reads the save's bytes for a publish. Every call goes through
    /// BackupWorkQueue, which serialises backup sessions.
    private let local = LocalBackupRepository()
    /// The community consent, asked once, then the form.
    @State private var showPublishConsent = false
    @State private var showPublishForm = false
    /// The link to hand to the share sheet once a save is published.
    @State private var publishedLink: SharedLink?
    @Environment(\.isControllerConnected) private var isControllerConnected

    /// A sheet covers the list; a pane sits beside it, so only the sheet
    /// suppresses L/R tab cycling.
    @StateObject private var scope =
        ActionListFocusModel(scopeName: "backupDetail")

    /// Copy targets, upload, delete - in the order they are drawn. Read in
    /// one place so the rings and the scope cannot disagree about the index.
    private var destinations: [BackupFile] { viewModel.copyDestinations() }
    /// Always drawn, unlike the other conditional rows. Cloud backup is a
    /// feature a purchase unlocks, and hiding the row hides the way to unlock
    /// it -- so the row stays and only what A does changes (table section 5).
    private var uploadRowIndex: Int { destinations.count }

    /// Publishing needs an account: the record carries an owner, and without
    /// one there would be no way to take it down again. Signed out, the row
    /// is absent rather than present and certain to fail.
    private var canPublish: Bool { Auth.auth().currentUser != nil }

    private var publishRowIndex: Int? {
        guard canPublish else { return nil }
        return destinations.count + 1
    }

    private var deleteRowIndex: Int {
        destinations.count + 1 + (canPublish ? 1 : 0)
    }

    /// Stops showing this save, because it no longer exists. Dismisses the
    /// sheet, or tells the two-pane layout to drop its selection back to the
    /// placeholder - `dismiss()` is a no-op in a pane, which would have left
    /// a deleted save on screen.
    private func close() {
        if let onClose = onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    /// Ends an action that left the save in place (a copy, an upload). A
    /// modal has to get out of the way once it has done its job; a pane is
    /// not in the way of anything, so it keeps showing the save.
    private func finishAction() {
        guard presentation == .sheet else { return }
        dismiss()
    }

    private var formattedDate: String {
        guard let date = save.saveDate else { return "-" }
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
                copySection
                uploadButton
                if canPublish {
                    publishButton
                }
                deleteButton
            }
            .padding(16)
        }
        .followsControllerFocus(scope.focused, in: proxy) { $0 }
        }
        .presentationDragIndicator(.visible)
        .background(Color.themeBackground)
        .controllerFocusScope(scope, in: focus)
        .proGate(item: $gateReason, focus: focus) {
            ProEntitlementStore.shared.refresh()
        }
        .onAppear { configureScope() }
        .onChange(of: destinations.count) { _ in declareRows() }
        .onChange(of: isControllerConnected) {
            scope.applyInitialFocus(controllerConnected: $0)
        }
        .confirmationDialog(
            String(localized: "Make this save public?",
                   comment: "Share consent title"),
            isPresented: $showPublishConsent, titleVisibility: .visible) {
            Button(String(localized: "Continue", comment: "Share consent continue")) {
                SharePublishConsent.grant()
                showPublishForm = true
            }
        } message: {
            Text(String(localized: "Sharing uploads this save so anyone can find and download it from the community list, not only people who have the link.",
                        comment: "Share consent message"))
        }
        .sheet(isPresented: $showPublishForm) {
            SharePublishSheet(save: save,
                              loadPayload: loadPublishPayload,
                              focus: focus,
                              onPublished: { publishedLink = SharedLink(id: $0) })
                .environment(\.isControllerConnected, isControllerConnected)
        }
        .sheet(item: $publishedLink) { link in
            // The system share sheet, so the link can go wherever the user
            // already shares things.
            ShareLinkSheet(url: link.url,
                           title: save.gameTitle ?? save.filename,
                           hashtags: BackupShareLink.hashtags(
                            gameTitle: save.gameTitle ?? ""))
        }
        .confirmationDialog(
            String(localized: "Delete this save?", comment: "Delete confirm title"),
            isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button(String(localized: "Delete", comment: "Delete"), role: .destructive) {
                Task {
                    await viewModel.delete(filename: save.filename)
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
                    Task {
                        await viewModel.copy(filename: save.filename, to: destination)
                        finishAction()
                    }
                }
            }
        }
        // The local sheet covers CloudBackupSection, so the section's own error
        // alert cannot be seen while this sheet is up. Upload failures surface here.
        .alert(String(localized: "Error", comment: "Error alert title"),
               isPresented: Binding(get: { cloudViewModel.errorMessage != nil },
                                    set: { if !$0 { cloudViewModel.clearError() } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(cloudViewModel.errorMessage ?? "")
        }
    }

    // MARK: - Publish

    /// Asks for consent the first time, then opens the form.
    private func startPublish() {
        if SharePublishConsent.isGranted {
            showPublishForm = true
        } else {
            showPublishConsent = true
        }
    }

    /// Reads the bytes and screenshot the publish needs, off the main actor
    /// and through the queue that serialises backup sessions.
    private func loadPublishPayload() async -> (data: Data, screenshot: Data?)? {
        let filename = save.filename
        let file = save.file
        let local = self.local
        let data = try? await BackupWorkQueue.shared.run {
            try local.exportRaw(filename: filename, in: file)
        }
        guard let data else { return nil }
        let screenshot = save.screenshotPath.flatMap {
            FileManager.default.contents(atPath: $0)
        }
        return (data, screenshot)
    }

    /// Identifiable wrapper so the share sheet can be driven by `item:`.
    private struct SharedLink: Identifiable {
        let id: String
        var url: URL { SharedBackupPublisher.shareURL(id: id) }
    }

    // MARK: - Controller focus

    private func configureScope() {
        scope.isModal = presentation == .sheet
        // A pane is a column beside the list, which D-pad Left/Right
        // moves between; a sheet covers the list instead.
        scope.pane = presentation == .pane ? .detail : nil
        // A confirmationDialog and a UIAlertController draw their own
        // selection, which the app cannot move, so A must not act on the row
        // behind them.
        scope.isBlocked = {
            showDeleteConfirm || pendingOverwrite != nil
                || cloudViewModel.errorMessage != nil
        }
        // A answers whichever dialog owns the screen. Without this a
        // controller could open one but never confirm it.
        scope.onConfirm = {
            if showDeleteConfirm {
                showDeleteConfirm = false
                Task {
                    await viewModel.delete(filename: save.filename)
                    close()
                }
                return true
            }
            if let destination = pendingOverwrite {
                pendingOverwrite = nil
                Task {
                    await viewModel.copy(filename: save.filename, to: destination)
                    finishAction()
                }
                return true
            }
            if cloudViewModel.errorMessage != nil {
                cloudViewModel.clearError()
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
            if cloudViewModel.errorMessage != nil {
                cloudViewModel.clearError()
                return true
            }
            close()
            return true
        }
        declareRows()
    }

    /// The actionable rows, in the order they are drawn.
    private func declareRows() {
        var actions: [() -> Void] = destinations.map { destination in
            { startCopy(to: destination) }
        }
        actions.append { startUpload() }
        if canPublish {
            actions.append { startPublish() }
        }
        actions.append { showDeleteConfirm = true }
        scope.setActions(actions)
        scope.applyInitialFocus(controllerConnected: isControllerConnected)
    }

    /// A pane is far wider than a phone sheet, and this screenshot is a
    /// 4:3 Saturn frame: at full pane width it becomes tall enough to push
    /// the copy and delete actions off the first screenful. Cap it to
    /// roughly the width it would have had on a phone.
    private static let paneMaxScreenshotWidth: CGFloat = 320

    private var maxScreenshotWidth: CGFloat {
        presentation == .pane ? Self.paneMaxScreenshotWidth : .infinity
    }

    @ViewBuilder
    private var screenshot: some View {
        if let path = save.screenshotPath,
           let image = UIImage(contentsOfFile: path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: maxScreenshotWidth)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(save.filename).font(.headline)
            if !save.comment.isEmpty {
                Text(save.comment).font(.subheadline).foregroundStyle(.secondary)
            }
            if let title = save.gameTitle, !title.isEmpty {
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            if let product = save.productNumber, !product.isEmpty {
                Text(product).font(.caption).foregroundStyle(.secondary)
            }
            Label(formattedDate, systemImage: "calendar")
                .font(.caption).foregroundStyle(.secondary)
            Text("\(save.displaySize) \u{00B7} \(save.blockSize) "
                 + String(localized: "blocks", comment: "Backup block count unit"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var copySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Copy to", comment: "Copy destination header"))
                .font(.subheadline.weight(.semibold))
            ForEach(Array(destinations.enumerated()),
                    id: \.element.id) { index, destination in
                Button {
                    startCopy(to: destination)
                } label: {
                    HStack {
                        Label(destination.displayName, systemImage: "square.and.arrow.down")
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

    /// Sends this save to the cloud. Hidden unless the user is entitled; the
    /// view model turns an absent sign-in into its own sign-in state.
    /// Publishes this save to the community list.
    private var publishButton: some View {
        Button {
            startPublish()
        } label: {
            Label(String(localized: "Share to Community",
                         comment: "Publish save to the community"),
                  systemImage: "person.2")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .controllerFocusRing(scope.focused == publishRowIndex,
                                     cornerRadius: 10,
                                     base: Color.themeSurfaceContainerHigh)
                .id(publishRowIndex)
        }
        .buttonStyle(.plain)
    }

    private var uploadButton: some View {
        Button {
            startUpload()
        } label: {
            HStack {
                Label(String(localized: "Upload to cloud",
                             comment: "Upload save to cloud"),
                      systemImage: "icloud.and.arrow.up")
                Spacer()
                // Two different waits, one indicator: the upload itself, and
                // StoreKit not having said yet whether this row may upload.
                if isUploading || cloudViewModel.isCheckingEntitlement {
                    ProgressView()
                }
            }
            .padding(12)
            .controllerFocusRing(scope.focused == uploadRowIndex,
                                 cornerRadius: 10,
                                 base: Color.themeSurfaceContainerHigh)
                    .id(uploadRowIndex)
        }
        .buttonStyle(.plain)
        .disabled(isUploading || cloudViewModel.isCheckingEntitlement)
    }

    /// Sends this save to the cloud. Shared by the button and by A on its row.
    private func startUpload() {
        // Still deciding: do nothing rather than sell cloud backup to someone
        // who may already have paid for it. The row shows a spinner meanwhile,
        // so A is not answering with silence (table section 5).
        guard !cloudViewModel.isCheckingEntitlement else { return }
        guard cloudViewModel.isEntitled else {
            gateReason = ProGateReason(
                String(localized: "Cloud backup needs a subscription or the full version.",
                       comment: "Reason the pro gate opened from cloud backup"))
            return
        }
        guard !isUploading else { return }
        isUploading = true
        Task {
            let succeeded = await cloudViewModel.upload(
                save: save, using: LocalBackupRepository())
            isUploading = false
            if succeeded { finishAction() }
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            showDeleteConfirm = true
        } label: {
            Label(String(localized: "Delete", comment: "Delete save"),
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
    /// overwrite check happens in a Task before either confirming or copying.
    private func startCopy(to destination: BackupFile) {
        Task {
            if await viewModel.saveExists(filename: save.filename, in: destination) {
                pendingOverwrite = destination
                return
            }
            await viewModel.copy(filename: save.filename, to: destination)
            finishAction()
        }
    }
}
