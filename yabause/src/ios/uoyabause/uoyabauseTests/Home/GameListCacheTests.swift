import XCTest
@testable import YabaSnashiro

final class GameListCacheTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeItem(path: String) -> GameItem {
        var gi = GameInfo()
        gi.filePath = path
        gi.displayName = "Game"
        gi.productNumber = "GS-0001"
        return GameItem(gameInfo: gi)
    }

    func testSaveAndLoadRoundTrip() {
        let cache = GameListCache(directory: tempDir)
        var item = makeItem(path: "/docs/a.cue")
        item.rating = 4
        item.raTotal = 20
        item.raUnlocked = 12
        // Whole-second date so the ISO8601 round trip is lossless
        item.lastPlayed = Date(timeIntervalSince1970: 1_700_000_000)
        cache.save([item])
        XCTAssertEqual(cache.load(), [item])
    }

    func testLoadReturnsEmptyWhenNoCache() {
        XCTAssertEqual(GameListCache(directory: tempDir).load(), [])
    }

    func testLoadReturnsEmptyOnCorruptFile() throws {
        let cache = GameListCache(directory: tempDir)
        try Data("not json".utf8).write(to: tempDir.appendingPathComponent("game_list_cache.json"))
        XCTAssertEqual(cache.load(), [])
    }
}
