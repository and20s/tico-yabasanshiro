import XCTest
@testable import YabaSnashiro

final class GameRepositoryTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Builds a minimal Saturn disc header understood by getGameInfoFromBuf.
    private func fixtureHeader(productNumber: String, title: String, releaseDate: String) -> Data {
        var data = Data(repeating: 0x20, count: 0x100) // space-filled
        func put(_ string: String, at offset: Int) {
            let bytes = Array(string.utf8)
            data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        }
        put("SEGA SEGASATURN ", at: 0x00)   // magic containing "SEGA "
        put("SEGA TP T-99", at: 0x10)       // maker id
        put(productNumber, at: 0x20)         // product number (10 bytes)
        put("V1.000", at: 0x2A)             // version
        put(releaseDate, at: 0x30)           // release date (8 bytes)
        put("CD-1/1", at: 0x38)             // device information
        put("JTUE", at: 0x40)               // area
        put("J", at: 0x50)                  // input device
        put(title, at: 0x60)                // game title
        return data
    }

    /// Creates <base>.bin with a Saturn header and <base>.cue referencing it.
    @discardableResult
    private func makeCueGame(base: String, productNumber: String, title: String,
                             releaseDate: String = "19960705", in dir: URL? = nil) throws -> URL {
        let target = dir ?? tempDir!
        let bin = target.appendingPathComponent("\(base).bin")
        try fixtureHeader(productNumber: productNumber, title: title,
                          releaseDate: releaseDate).write(to: bin)
        let cue = target.appendingPathComponent("\(base).cue")
        let cueText = "FILE \"\(base).bin\" BINARY\n  TRACK 01 MODE1/2352\n    INDEX 01 00:00:00\n"
        try Data(cueText.utf8).write(to: cue)
        return cue
    }

    private func makeRepository() -> GameRepository {
        GameRepository(rootDirectory: tempDir, cache: GameListCache(directory: tempDir))
    }

    func testRescanFindsCueGames() throws {
        try makeCueGame(base: "nights", productNumber: "GS-9046", title: "NIGHTS")
        let items = makeRepository().rescan()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].productNumber, "GS-9046")
        XCTAssertEqual(items[0].displayName, "NIGHTS")
        XCTAssertTrue(items[0].filePath.hasSuffix("nights.cue"))
    }

    func testRescanScansSubdirectories() throws {
        let sub = tempDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try makeCueGame(base: "rally", productNumber: "GS-9047", title: "SEGA RALLY", in: sub)
        XCTAssertEqual(makeRepository().rescan().count, 1)
    }

    func testRescanMergesCachedMetadata() throws {
        let cue = try makeCueGame(base: "nights", productNumber: "GS-9046", title: "NIGHTS")
        let repo = makeRepository()
        var items = repo.rescan()
        items[0].rating = 5
        items[0].raTotal = 20
        items[0].raUnlocked = 3
        GameListCache(directory: tempDir).save(items)

        let rescanned = repo.rescan()
        XCTAssertEqual(rescanned.count, 1)
        XCTAssertEqual(rescanned[0].filePath, cue.path)
        XCTAssertEqual(rescanned[0].rating, 5)
        XCTAssertEqual(rescanned[0].raUnlocked, 3)
    }

    func testRescanDropsDeletedGames() throws {
        try makeCueGame(base: "nights", productNumber: "GS-9046", title: "NIGHTS")
        let repo = makeRepository()
        XCTAssertEqual(repo.rescan().count, 1)
        try FileManager.default.removeItem(at: tempDir.appendingPathComponent("nights.cue"))
        try FileManager.default.removeItem(at: tempDir.appendingPathComponent("nights.bin"))
        XCTAssertEqual(repo.rescan().count, 0)
    }

    func testRescanSkipsBrokenCue() throws {
        // cue referencing a missing bin must be skipped without aborting the scan
        let cue = tempDir.appendingPathComponent("broken.cue")
        try Data("FILE \"missing.bin\" BINARY\n".utf8).write(to: cue)
        try makeCueGame(base: "good", productNumber: "GS-9046", title: "GOOD")
        let items = makeRepository().rescan()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].displayName, "GOOD")
    }

    func testImportCopiesFileIntoRoot() throws {
        let srcDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: srcDir) }
        let src = srcDir.appendingPathComponent("import.chd")
        try Data([0x01, 0x02]).write(to: src)

        try makeRepository().importFile(from: src)
        let dst = tempDir.appendingPathComponent("import.chd")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.path))
    }

    func testImportRejectsUnsupportedExtension() throws {
        let src = tempDir.appendingPathComponent("readme.txt")
        try Data("x".utf8).write(to: src)
        XCTAssertThrowsError(try makeRepository().importFile(from: src)) { error in
            guard case GameRepositoryError.unsupportedFileType = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testDeleteRemovesCueAndReferencedFiles() throws {
        try makeCueGame(base: "nights", productNumber: "GS-9046", title: "NIGHTS")
        let repo = makeRepository()
        let items = repo.rescan()
        repo.delete(item: items[0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("nights.cue").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("nights.bin").path))
    }

    // MARK: - Free game limit

    /// The limit is no longer a property of the build. The full app is a free
    /// download now, so what lifts the limit is the purchase, and the test has
    /// to say which user it is asking about: reading the default entitlement
    /// would make the answer depend on when the app host's launch-time
    /// StoreKit read lands.
    func testAProUserIsNeverOverTheFreeLimit() {
        let pro = ProEntitlement(showsAdvertising: false, legacy: .legacyPaid,
                                 purchase: .none)
        XCTAssertFalse(GameRepository.isOverFreeLimit(count: 100, entitlement: pro))
    }

    func testAFreeUserIsOverTheLimitPastTheAllowance() {
        let free = ProEntitlement(showsAdvertising: true, legacy: .notLegacy,
                                  purchase: .none)
        XCTAssertFalse(GameRepository.isOverFreeLimit(count: 2, entitlement: free))
        XCTAssertTrue(GameRepository.isOverFreeLimit(count: 100, entitlement: free))
    }

    // MARK: - Arrival times (free slots)

    /// A file the cache has never seen is new, so it is stamped with the time
    /// of the scan that found it.
    func testANewlyScannedGameIsStampedWithItsArrival() throws {
        try makeCueGame(base: "nights", productNumber: "GS-9046", title: "NIGHTS")
        let before = Date()
        let items = makeRepository().rescan()
        let addedAt = try XCTUnwrap(items[0].addedAt)
        XCTAssertGreaterThanOrEqual(addedAt, before)
        XCTAssertLessThanOrEqual(addedAt, Date())
    }

    func testAnArrivalTimeSurvivesTheNextScan() throws {
        try makeCueGame(base: "nights", productNumber: "GS-9046", title: "NIGHTS")
        let repo = makeRepository()
        let first = try XCTUnwrap(repo.rescan()[0].addedAt)
        try makeCueGame(base: "rally", productNumber: "GS-9089", title: "SEGA RALLY")
        let second = repo.rescan()
        let nights = try XCTUnwrap(second.first { $0.filePath.hasSuffix("nights.cue") })
        // Within a second rather than exactly: the cache is ISO 8601, which
        // carries no fractional seconds. Ordering is unaffected, and the point
        // of the test is that the scan did not stamp a fresh time.
        XCTAssertEqual(try XCTUnwrap(nights.addedAt).timeIntervalSince1970,
                       first.timeIntervalSince1970, accuracy: 1,
                       "a game that keeps its free slot must keep its arrival time")
    }

    /// Cache from before this feature carries no arrival time. Those entries
    /// all migrate to the same one so FreeGameSlots orders them by path, and a
    /// game imported afterwards cannot take a slot from any of them.
    func testCachedGamesWithoutAnArrivalMigrateBehindNewImports() throws {
        try makeCueGame(base: "nights", productNumber: "GS-9046", title: "NIGHTS")
        let cache = GameListCache(directory: tempDir)
        let repo = GameRepository(rootDirectory: tempDir, cache: cache)
        var legacyCache = repo.rescan()
        legacyCache[0].addedAt = nil
        cache.save(legacyCache)

        try makeCueGame(base: "rally", productNumber: "GS-9089", title: "SEGA RALLY")
        let items = repo.rescan()
        let nights = try XCTUnwrap(items.first { $0.filePath.hasSuffix("nights.cue") })
        let rally = try XCTUnwrap(items.first { $0.filePath.hasSuffix("rally.cue") })
        XCTAssertEqual(nights.addedAt, .distantPast)
        XCTAssertGreaterThan(try XCTUnwrap(rally.addedAt), .distantPast)
    }
}
