import XCTest
@testable import YabaSnashiro

final class GameItemTests: XCTestCase {
    private func makeGameInfo() -> GameInfo {
        var gi = GameInfo()
        gi.filePath = "/docs/nights.cue"
        gi.displayName = "NiGHTS into Dreams"
        gi.gameTitle = "NIGHTS"
        gi.productNumber = "GS-9046"
        gi.releaseDate = "19960705"
        gi.deviceInformation = "CD-1/1"
        gi.imageUrl = "https://example.com/GS-9046.PNG"
        return gi
    }

    func testInitFromGameInfo() {
        let item = GameItem(gameInfo: makeGameInfo())
        XCTAssertEqual(item.filePath, "/docs/nights.cue")
        XCTAssertEqual(item.displayName, "NiGHTS into Dreams")
        XCTAssertEqual(item.productNumber, "GS-9046")
        XCTAssertEqual(item.releaseDate, "19960705")
        XCTAssertEqual(item.rating, 0)
        XCTAssertEqual(item.raTotal, 0)
        XCTAssertNil(item.lastPlayed)
        XCTAssertEqual(item.id, "/docs/nights.cue")
    }

    func testMergingCarriesCachedMetadata() {
        var cached = GameItem(gameInfo: makeGameInfo())
        cached.rating = 4
        cached.raHash = "0123456789abcdef0123456789abcdef"
        cached.raGameId = 24213
        cached.raTotal = 20
        cached.raUnlocked = 12
        cached.raUnlockedHardcore = 7
        cached.raNotSupported = false
        cached.lastPlayed = Date(timeIntervalSince1970: 1_700_000_000)

        let fresh = GameItem(gameInfo: makeGameInfo()).merging(cached: cached)
        XCTAssertEqual(fresh.rating, 4)
        XCTAssertEqual(fresh.raGameId, 24213)
        XCTAssertEqual(fresh.raUnlocked, 12)
        XCTAssertEqual(fresh.lastPlayed, cached.lastPlayed)
    }

    func testMergingWithNilReturnsSelf() {
        let item = GameItem(gameInfo: makeGameInfo())
        XCTAssertEqual(item.merging(cached: nil), item)
    }

    // MARK: - Release date formatting

    func testFormattedReleaseDateSplitsTheSaturnHeaderFormat() {
        var item = GameItem(gameInfo: makeGameInfo())
        item.releaseDate = "19941109"
        XCTAssertEqual(item.formattedReleaseDate, "1994-11-09")
    }

    /// Discs with a short or malformed date field are shown as-is rather
    /// than sliced into nonsense.
    func testFormattedReleaseDateLeavesUnexpectedLengthsAlone() {
        var item = GameItem(gameInfo: makeGameInfo())
        item.releaseDate = "1994"
        XCTAssertEqual(item.formattedReleaseDate, "1994")

        item.releaseDate = ""
        XCTAssertEqual(item.formattedReleaseDate, "")

        item.releaseDate = "199411091"
        XCTAssertEqual(item.formattedReleaseDate, "199411091")
    }
}
