import SwiftUI

/// Detail of one community save, and the place it is imported from.
///
/// Rating, reporting and owner-delete arrive in the following SP3c phases.
struct SharedBackupDetailSheet: View {
    let item: SharedBackupItem
    @ObservedObject var viewModel: SharedBackupBrowseViewModel
    @ObservedObject var localViewModel: BackupListViewModel
    var focus: ControllerFocusCoordinator?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.isControllerConnected) private var isControllerConnected

    @State private var isWorking = false
    @State private var pendingOverwrite: BackupFile?
    @State private var isConfirmingUnpublish = false
    /// The star the picker is sitting on. Starts in the middle when the user
    /// has not rated: an end would read as if it only moved one way.
    @State private var stars = 3
    @State private var hasRated = false
    @State private var isChoosingReportReason = false
    @State private var isConfirmingBlock = false
    @State private var hasReported = false
    @StateObject private var scope =
        ActionListFocusModel(scopeName: "sharedDetail", isModal: true)

    /// Created once per sheet; every call goes through BackupWorkQueue inside
    /// the view model.
    private let local = LocalBackupRepository()

    /// Where an import may go: the same backup files the local list offers.
    private var destinations: [BackupFile] { localViewModel.availableFiles }

    /// Only the poster may take a save down, so for anyone else the row is
    /// absent rather than present and certain to be refused.
    private var canUnpublish: Bool { viewModel.canUnpublish(item) }

    /// Rating is recorded per account, so signed out the row is absent.
    private var canRate: Bool { viewModel.canRate }

    private var ratingRowIndex: Int? {
        canRate ? destinations.count : nil
    }

    /// Reporting and hiding are for other people's saves; the poster's own
    /// save offers the takedown in the same position instead.
    private var canReport: Bool { viewModel.canReport(item) }

    private var reportRowIndex: Int? {
        guard canReport else { return nil }
        return destinations.count + (canRate ? 1 : 0)
    }

    private var blockRowIndex: Int? {
        guard canReport else { return nil }
        return destinations.count + (canRate ? 1 : 0) + 1
    }

    /// Last in the list, after the destinations, rating and moderation rows.
    private var unpublishRowIndex: Int? {
        guard canUnpublish else { return nil }
        return destinations.count + (canRate ? 1 : 0)
    }

    private var formattedDate: String {
        guard let date = item.saveDate else { return "-" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    var body: some View {
        NavigationStack {
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
                        importSection
                        ratingSection
                        moderationSection
                        unpublishSection
                    }
                }
                .padding(16)
            }
            .followsControllerFocus(scope.focused, in: proxy) { $0 }
            }
            .background(Color.themeBackground)
            .navigationTitle(item.gameTitle.isEmpty
                             ? item.filename : item.gameTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "Close", comment: "Close")) { dismiss() }
                }
            }
        }
        .controllerFocusScope(scope, in: focus)
        .onAppear { configureScope() }
        .task { await loadMyRating() }
        .onChange(of: destinations.count) { _ in declareRows() }
        .onChange(of: isWorking) { _ in declareRows() }
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
                    Task { await runImport(into: destination) }
                }
            }
        }
        .confirmationDialog(
            String(localized: "Remove this save from the community list?",
                   comment: "Unpublish confirm"),
            isPresented: $isConfirmingUnpublish,
            titleVisibility: .visible) {
            Button(String(localized: "Remove", comment: "Unpublish action"),
                   role: .destructive) {
                Task { await runUnpublish() }
            }
        } message: {
            Text(String(localized: "Anyone who already downloaded it keeps their copy.",
                        comment: "Unpublish explanation"))
        }
        // The list has an alert on the same message, but this sheet covers
        // it, and every failure here deliberately keeps the sheet open.
        // Without one here the spinner just stops and nothing says why.
        .alert(String(localized: "Error", comment: "Error alert title"),
               isPresented: Binding(get: { viewModel.errorMessage != nil },
                                    set: { if !$0 { viewModel.clearError() } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .confirmationDialog(
            String(localized: "Why are you reporting this save?",
                   comment: "Report reason prompt"),
            isPresented: $isChoosingReportReason,
            titleVisibility: .visible) {
            ForEach(SharedBackupReportReason.allCases) { reason in
                Button(reason.title) { Task { await runReport(reason) } }
            }
        }
        .confirmationDialog(
            String(localized: "Hide every save from this user?",
                   comment: "Block confirm"),
            isPresented: $isConfirmingBlock,
            titleVisibility: .visible) {
            Button(String(localized: "Hide", comment: "Block action"),
                   role: .destructive) {
                viewModel.block(item)
                dismiss()
            }
        } message: {
            Text(String(localized: "This only changes what you see, and you can undo it from the community list.",
                        comment: "Block explanation"))
        }
        .proGate(item: $viewModel.gateReason, focus: focus) {
            ProEntitlementStore.shared.refresh()
        }
    }

    // MARK: - Controller focus

    private func configureScope() {
        scope.isBlocked = {
            pendingOverwrite != nil || isConfirmingUnpublish
                || isConfirmingBlock || isChoosingReportReason || isWorking
                || viewModel.errorMessage != nil
        }
        // A on either dialog answers it. Without this a dialog could be
        // opened with a controller but never answered.
        scope.onConfirm = {
            // The error alert is the topmost thing on screen when it is up,
            // so A dismisses it rather than reaching a row behind it.
            if viewModel.errorMessage != nil {
                viewModel.clearError()
                return true
            }
            if let destination = pendingOverwrite {
                pendingOverwrite = nil
                Task { await runImport(into: destination) }
                return true
            }
            if isConfirmingUnpublish {
                isConfirmingUnpublish = false
                Task { await runUnpublish() }
                return true
            }
            if isConfirmingBlock {
                isConfirmingBlock = false
                viewModel.block(item)
                dismiss()
                return true
            }
            // The reason list is a choice, not a yes/no, and the controller
            // cannot walk it. A answers it as "report, reason unstated",
            // which is still actionable and beats a dialog with no way out
            // but B.
            if isChoosingReportReason {
                isChoosingReportReason = false
                Task { await runReport(.other) }
                return true
            }
            return false
        }
        // Left/Right picks the star while the rating row has the ring. Every
        // other row answers false, so those directions keep changing column.
        scope.onAdjust = { index, delta in
            guard index == ratingRowIndex else { return false }
            stars = min(5, max(1, stars + delta))
            return true
        }
        scope.onClose = {
            if viewModel.errorMessage != nil {
                viewModel.clearError()
                return true
            }
            if pendingOverwrite != nil {
                pendingOverwrite = nil
                return true
            }
            if isConfirmingUnpublish {
                isConfirmingUnpublish = false
                return true
            }
            if isConfirmingBlock {
                isConfirmingBlock = false
                return true
            }
            if isChoosingReportReason {
                isChoosingReportReason = false
                return true
            }
            dismiss()
            return true
        }
        declareRows()
    }

    private func declareRows() {
        guard !isWorking else {
            scope.setActions([])
            return
        }
        var actions: [() -> Void] = destinations.map { destination in
            { startImport(into: destination) }
        }
        if canRate {
            actions.append { Task { await submitRating() } }
        }
        if canReport {
            actions.append { isChoosingReportReason = true }
            actions.append { isConfirmingBlock = true }
        }
        if canUnpublish {
            actions.append { isConfirmingUnpublish = true }
        }
        scope.setActions(actions)
        scope.applyInitialFocus(controllerConnected: isControllerConnected)
    }

    // MARK: - Import

    /// Asks before replacing a save of the same name, then imports.
    private func startImport(into destination: BackupFile) {
        if viewModel.wouldOverwrite(item: item, in: destination, using: local) {
            pendingOverwrite = destination
        } else {
            Task { await runImport(into: destination) }
        }
    }

    // MARK: - Rating

    /// Opens the picker on what this user already gave, so rating again is
    /// an adjustment rather than a fresh guess.
    private func loadMyRating() async {
        guard let existing = await viewModel.myRating(of: item) else { return }
        stars = existing
        hasRated = true
    }

    private func submitRating() async {
        isWorking = true
        let sent = await viewModel.rate(item, stars: stars,
                                        entitlement: ProEntitlementStore.shared.entitlement)
        isWorking = false
        if sent { hasRated = true }
    }

    // MARK: - Reporting

    private func runReport(_ reason: SharedBackupReportReason) async {
        isWorking = true
        let sent = await viewModel.report(item, reason: reason)
        isWorking = false
        // The sheet stays open: the save is still there, and the user may
        // well want to hide the poster next.
        if sent { hasReported = true }
    }

    // MARK: - Unpublish

    private func runUnpublish() async {
        isWorking = true
        let removed = await viewModel.unpublish(item)
        isWorking = false
        // On failure the view model has set the message the list shows, and
        // the sheet stays open so the user can try again.
        if removed { dismiss() }
    }

    private func runImport(into destination: BackupFile) async {
        isWorking = true
        let succeeded = await viewModel.import(item: item, into: destination,
                                               using: local,
                                               entitlement: ProEntitlementStore.shared.entitlement)
        // The local list is what the user will look at next, so it has to see
        // the new save.
        await localViewModel.load()
        isWorking = false
        if succeeded { dismiss() }
    }

    // MARK: - Content

    @ViewBuilder
    private var screenshot: some View {
        if let text = item.screenshotURL, let url = URL(string: text) {
            AsyncImage(url: url) { image in
                image
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .frame(maxWidth: .infinity, alignment: .center)
            } placeholder: {
                EmptyView()
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.filename).font(.headline)
            if !item.description.isEmpty {
                Text(item.description)
                    .font(.subheadline)
                    .foregroundStyle(Color.themeOnSurfaceVariant)
            }
            if !item.comment.isEmpty {
                Text(item.comment)
                    .font(.caption)
                    .foregroundStyle(Color.themeOnSurfaceVariant)
            }
            Label(item.ownerName, systemImage: "person.circle")
                .font(.caption)
                .foregroundStyle(Color.themeOnSurfaceVariant)
            Label(formattedDate, systemImage: "calendar")
                .font(.caption)
                .foregroundStyle(Color.themeOnSurfaceVariant)
            if item.ratingCount > 0 {
                // Only shown once someone has rated: "0.0 (0)" reads as a bad
                // score rather than as an absence of scores.
                Label(String(format: "%.1f (%d)",
                             item.averageRating, item.ratingCount),
                      systemImage: "star.fill")
                    .font(.caption)
                    .foregroundStyle(Color.themeOnSurfaceVariant)
            }
            Text("\(item.blockSize) "
                 + String(localized: "blocks", comment: "Backup block count unit")
                 + " \u{00B7} \(item.downloadCount) "
                 + String(localized: "downloads", comment: "Download count unit"))
                .font(.caption)
                .foregroundStyle(Color.themeOnSurfaceVariant)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var importSection: some View {
        if destinations.isEmpty {
            Text(String(localized: "No local backup memory to import into.",
                        comment: "Shared import has no destination"))
                .font(.caption)
                .foregroundStyle(Color.themeOnSurfaceVariant)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "Copy to", comment: "Copy destination header"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.themeOnSurface)
                ForEach(Array(destinations.enumerated()), id: \.element) { index, destination in
                    Button {
                        startImport(into: destination)
                    } label: {
                        HStack {
                            Label(destination.displayName,
                                  systemImage: "square.and.arrow.down")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(Color.themeOnSurfaceVariant)
                                // Decorative: keep it out of the label.
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
    }

    @ViewBuilder
    private var moderationSection: some View {
        if let reportIndex = reportRowIndex, let blockIndex = blockRowIndex {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    isChoosingReportReason = true
                } label: {
                    HStack {
                        Label(hasReported
                              ? String(localized: "Reported",
                                       comment: "Report row, already reported")
                              : String(localized: "Report this save",
                                       comment: "Report row"),
                              systemImage: "flag")
                        Spacer()
                    }
                    .padding(12)
                    .controllerFocusRing(scope.focused == reportIndex,
                                         cornerRadius: 10,
                                         base: Color.themeSurfaceContainerHigh)
                    .id(reportIndex)
                }
                .buttonStyle(.plain)
                .disabled(hasReported)

                Button {
                    isConfirmingBlock = true
                } label: {
                    HStack {
                        Label(String(localized: "Hide saves from this user",
                                     comment: "Block row"),
                              systemImage: "eye.slash")
                        Spacer()
                    }
                    .padding(12)
                    .controllerFocusRing(scope.focused == blockIndex,
                                         cornerRadius: 10,
                                         base: Color.themeSurfaceContainerHigh)
                    .id(blockIndex)
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(Color.themeOnSurfaceVariant)
        }
    }

    @ViewBuilder
    private var ratingSection: some View {
        if let index = ratingRowIndex {
            VStack(alignment: .leading, spacing: 8) {
                Text(hasRated
                     ? String(localized: "Your rating", comment: "Rating header, rated")
                     : String(localized: "Rate this save", comment: "Rating header"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.themeOnSurface)
                HStack(spacing: 4) {
                    ForEach(1...5, id: \.self) { star in
                        Button {
                            stars = star
                            Task { await submitRating() }
                        } label: {
                            Image(systemName: star <= stars ? "star.fill" : "star")
                                .font(.title3)
                                .foregroundStyle(Color.themePrimary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(
                            format: String(localized: "%d stars",
                                           comment: "Rating accessibility"), star))
                    }
                    Spacer()
                }
                .padding(12)
                .controllerFocusRing(scope.focused == index,
                                     cornerRadius: 10,
                                     base: Color.themeSurfaceContainerHigh)
                .id(index)
            }
        }
    }

    @ViewBuilder
    private var unpublishSection: some View {
        if let index = unpublishRowIndex {
            Button(role: .destructive) {
                isConfirmingUnpublish = true
            } label: {
                HStack {
                    Label(String(localized: "Remove from Community",
                                 comment: "Unpublish row"),
                          systemImage: "trash")
                    Spacer()
                }
                .padding(12)
                .controllerFocusRing(scope.focused == index,
                                     cornerRadius: 10,
                                     base: Color.themeSurfaceContainerHigh)
                .id(index)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.themeError)
        }
    }
}
