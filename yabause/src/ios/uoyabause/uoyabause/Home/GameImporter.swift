import Foundation
import UniformTypeIdentifiers

/// Copies picked disc images into the library.
///
/// Lives outside the view because the Add entry no longer has a screen of its
/// own: it opens the system document browser directly, and the progress and
/// error states this publishes are shown over whichever tab is on screen.
@MainActor
final class GameImporter: ObservableObject {
    /// True while files are being copied in.
    @Published private(set) var isImporting = false
    /// Set when a picked file could not be imported.
    @Published var errorMessage: String?
    /// Set when a restricted feature was reached, carrying what to tell the
    /// user. nil means no gate is open.
    @Published var gateReason: ProGateReason?

    /// The disc image types the picker offers, derived from the same list the
    /// repository accepts so the two cannot drift apart.
    static let contentTypes: [UTType] =
        GameRepository.importableExtensions.compactMap { UTType(filenameExtension: $0) }

    /// Whether the picker may be opened at all. The free version caps how many
    /// files the library may hold.
    func canAdd(currentCount: Int,
                entitlement: ProEntitlement = ProEntitlement()) -> Bool {
        guard GameRepository.isOverFreeLimit(count: currentCount,
                                             entitlement: entitlement) else { return true }
        gateReason = ProGateReason(
            String(localized: "The free version holds three games. A subscription removes the limit.",
                   comment: "Reason the pro gate opened from the game limit"))
        return false
    }

    /// Copies every picked file in, then refreshes the library once.
    ///
    /// The limit is re-checked per file rather than only before the picker
    /// opened: the picker takes several files at once, so a single check made
    /// while the library still had room would let a whole selection through.
    /// Files already copied in this run stay; the rest are dropped and the
    /// gate opens with the same reason the pre-picker check uses.
    func importFiles(_ result: Result<[URL], Error>,
                     into viewModel: GameListViewModel,
                     repository: GameRepository = GameRepository(),
                     entitlement: ProEntitlement = ProEntitlement()) async {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        isImporting = true
        defer { isImporting = false }

        var count = viewModel.totalCount
        for url in urls {
            guard canAdd(currentCount: count, entitlement: entitlement) else { break }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try repository.importFile(from: url)
                }.value
                count += 1
            } catch {
                errorMessage = String(localized: "You can select chd or bin or cue",
                                      comment: "Unsupported file message")
            }
        }
        await viewModel.refresh()
    }
}
