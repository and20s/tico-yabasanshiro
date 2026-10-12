import Foundation

/// One entry of the home game library.
/// Wraps on-disc header data (GameInfo) plus cached online metadata
/// (rating, RetroAchievements progress) and local play history.
/// Mirrors the Android Room entity `GameInfo` fields used by the new UI.
struct GameItem: Codable, Identifiable, Equatable {
    var filePath: String
    var displayName: String
    var productNumber: String
    var releaseDate: String
    var deviceInformation: String
    var imageUrl: String?

    // Online metadata (cached across rescans)
    var rating: Int
    // RetroAchievements progress (cached across rescans)
    var raHash: String?
    var raGameId: Int
    var raTotal: Int
    var raUnlocked: Int
    var raUnlockedHardcore: Int
    var raNotSupported: Bool
    // Local play history (drives the recently-played sort)
    var lastPlayed: Date?
    /// When this game entered the library. Decides the free version's three
    /// playable slots (FreeGameSlots), which is why it is kept rather than
    /// derived from the presentation order. Optional because cache written
    /// before it existed carries none; those entries are ordered by path.
    var addedAt: Date?

    var id: String { filePath }

    /// The disc header stores the release date as YYYYMMDD. Split it for
    /// display; anything that is not 8 digits is passed through untouched
    /// rather than sliced into nonsense.
    var formattedReleaseDate: String {
        guard releaseDate.count == 8 else { return releaseDate }
        let year = releaseDate.prefix(4)
        let month = releaseDate.dropFirst(4).prefix(2)
        let day = releaseDate.suffix(2)
        return "\(year)-\(month)-\(day)"
    }

    init(gameInfo: GameInfo) {
        filePath = gameInfo.filePath ?? ""
        displayName = gameInfo.displayName ?? gameInfo.gameTitle ?? ""
        productNumber = gameInfo.productNumber ?? ""
        releaseDate = gameInfo.releaseDate ?? ""
        deviceInformation = gameInfo.deviceInformation ?? ""
        imageUrl = gameInfo.imageUrl
        rating = 0
        raHash = nil
        raGameId = 0
        raTotal = 0
        raUnlocked = 0
        raUnlockedHardcore = 0
        raNotSupported = false
        lastPlayed = nil
        addedAt = nil
    }

    /// Carry over cached online metadata from a previously cached item so
    /// rating / RA progress / play history survive a rescan.
    func merging(cached: GameItem?) -> GameItem {
        guard let cached = cached else { return self }
        var item = self
        item.rating = cached.rating
        item.raHash = cached.raHash
        item.raGameId = cached.raGameId
        item.raTotal = cached.raTotal
        item.raUnlocked = cached.raUnlocked
        item.raUnlockedHardcore = cached.raUnlockedHardcore
        item.raNotSupported = cached.raNotSupported
        item.lastPlayed = cached.lastPlayed
        item.addedAt = cached.addedAt
        return item
    }
}
