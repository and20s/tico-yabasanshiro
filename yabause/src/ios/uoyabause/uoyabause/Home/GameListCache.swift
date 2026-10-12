import Foundation

/// Stale-while-revalidate cache for the scanned game list.
/// The last scan result is persisted as JSON so the next launch can show
/// the list immediately while a rescan runs in the background.
/// Mirrors the Android GameListCacheManager behavior.
final class GameListCache {
    private let fileURL: URL

    init(directory: URL? = nil) {
        let base = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("game_list_cache.json")
    }

    func load() -> [GameItem] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([GameItem].self, from: data)) ?? []
    }

    func save(_ items: [GameItem]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
