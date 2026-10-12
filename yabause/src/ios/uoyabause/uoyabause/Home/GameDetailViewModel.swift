import Foundation
import UIKit

/// Loads on-demand detail data (fresh rating) when the detail sheet opens.
/// Mirrors the Android GameDetailBottomSheet loading.
@MainActor
final class GameDetailViewModel: ObservableObject {
    @Published var item: GameItem
    @Published private(set) var isLoadingRating = false

    private let ratingService: GameRatingService
    private let listViewModel: GameListViewModel

    init(item: GameItem, listViewModel: GameListViewModel,
         ratingService: GameRatingService = GameRatingService()) {
        self.item = item
        self.listViewModel = listViewModel
        self.ratingService = ratingService
    }

    /// Refresh the community rating from Firestore and persist it.
    func refreshRating() async {
        isLoadingRating = true
        defer { isLoadingRating = false }
        guard let rating = await ratingService.fetchRating(
            productNumber: item.productNumber) else { return }
        item.rating = rating
        listViewModel.applyUpdatedItems([item])
    }

    func play(from presenter: UIViewController?) {
        guard let presenter = presenter else { return }
        // A locked game cannot be reached from the list any more, but a pane
        // holds its selection across a rescan and a purchase can lapse while
        // the detail is open. Asking again here opens the gate instead of the
        // emulator, and it is the same question the list asked.
        guard listViewModel.select(item) else { return }
        listViewModel.recordLastPlayed(filePath: item.filePath)
        GameLauncher.launch(filePath: item.filePath,
                            productNumber: item.productNumber,
                            from: presenter)
    }

    func delete() async {
        await listViewModel.delete(item: item)
    }
}
