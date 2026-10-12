import XCTest
@testable import YabaSnashiro

final class SharedBackupRepositoryTests: XCTestCase {
    private var database: FakeSharedBackupDatabase!
    private var storage: FakeSharedStorage!
    private var repository: SharedBackupRepository!

    override func setUp() {
        super.setUp()
        database = FakeSharedBackupDatabase()
        storage = FakeSharedStorage()
        repository = SharedBackupRepository(database: database, storage: storage)
    }

    private func makeItem(id: String = "abc",
                          filename: String = "NIGHTS_01") -> SharedBackupItem {
        SharedBackupItem(id: id, data: [
            "ownerId": "uid-1", "ownerName": "Shinya",
            "gameTitle": "NiGHTS", "productNumber": "GS-9046",
            "filename": filename, "comment": "", "description": "",
            "saveDate": "1996/07/05 12:34:56",
            "downloadUrl": "https://example.com/save",
            "downloadCount": 0, "isPublic": true,
            "ratings": ["average": 0.0, "count": 0],
            "dataSize": 2048, "blockSize": 4,
        ])!
    }

    // MARK: - Rating

    /// One document per user, keyed by uid, so rating again replaces rather
    /// than stacking. The average is a Cloud Function's job, not ours.
    func testRatingWritesOneDocumentPerUser() async throws {
        try await repository.rate(item: makeItem(), rating: 4, userId: "uid-2")
        try await repository.rate(item: makeItem(), rating: 5, userId: "uid-2")

        XCTAssertEqual(database.ratingWrites.map(\.rating), [4, 5])
        let stored = try await repository.rating(item: makeItem(), userId: "uid-2")
        XCTAssertEqual(stored, 5)
    }

    /// The stars are 1-5. Anything else would land in the aggregate and skew
    /// every reader's average, so it is refused before the write.
    func testAnOutOfRangeRatingIsRefusedBeforeItIsWritten() async {
        for value in [0, 6, -1] {
            do {
                try await repository.rate(item: makeItem(), rating: value,
                                          userId: "uid-2")
                XCTFail("rating \(value) was accepted")
            } catch {
                // expected
            }
        }
        XCTAssertTrue(database.ratingWrites.isEmpty)
    }

    func testAnUnratedSaveReportsNoRating() async throws {
        let stored = try await repository.rating(item: makeItem(), userId: "uid-2")
        XCTAssertNil(stored)
    }

    /// Downloading must count the download, but a save the user asked for has
    /// to arrive even when that bookkeeping write is refused.
    func testDownloadReturnsTheDataAndCountsIt() async throws {
        storage.data = Data([1, 2, 3])
        let data = try await repository.download(item: makeItem())
        XCTAssertEqual(data, Data([1, 2, 3]))
        XCTAssertEqual(database.incremented, ["abc"])
    }

    func testDownloadStillSucceedsWhenTheCountCannotBeWritten() async throws {
        storage.data = Data([9])
        database.incrementFails = true
        let data = try await repository.download(item: makeItem())
        XCTAssertEqual(data, Data([9]))
    }

    /// Android leaves screenshot.png behind on every delete. Both objects go.
    func testDeleteRemovesTheSaveTheScreenshotAndTheDocument() async throws {
        try await repository.delete(item: makeItem())
        XCTAssertEqual(storage.removed, [
            "shared_backups/abc/NIGHTS_01",
            "shared_backups/abc/screenshot.png",
        ])
        XCTAssertEqual(database.deleted, ["abc"])
    }

    /// A missing object must not strand the Firestore document, or the record
    /// stays listed forever with nothing behind it.
    func testDeleteRemovesTheDocumentEvenIfTheObjectIsAlreadyGone() async throws {
        storage.removeFails = true
        try await repository.delete(item: makeItem())
        XCTAssertEqual(database.deleted, ["abc"])
    }

    /// A full page offers a cursor so the caller can ask for more; a short one
    /// ends the walk. Android has no paging at all and can only ever see the
    /// newest 20.
    func testAFullPageOffersACursorAndAShortPageEndsTheWalk() async throws {
        database.pages = [
            SharedBackupPage(items: (0..<20).map { makeItem(id: "id\($0)") },
                             cursor: "cursor-1"),
            SharedBackupPage(items: [makeItem(id: "last")], cursor: nil),
        ]
        let first = try await repository.page()
        XCTAssertEqual(first.items.count, 20)
        XCTAssertNotNil(first.cursor)

        let second = try await repository.page(after: first.cursor)
        XCTAssertEqual(second.items.count, 1)
        XCTAssertNil(second.cursor)
        XCTAssertEqual(database.requestedCursors.last as? String, "cursor-1")
    }

    /// Filtering by game is a server-side narrowing, not a client-side pass
    /// over an arbitrary page.
    func testFilteringPassesTheProductNumberToTheQuery() async throws {
        database.pages = [.empty]
        _ = try await repository.page(matching: "GS-9046")
        XCTAssertEqual(database.requestedProductNumbers, ["GS-9046"])
    }

    func testSortIsPassedThrough() async throws {
        database.pages = [.empty]
        _ = try await repository.page(sort: .mostDownloaded)
        XCTAssertEqual(database.requestedSorts, [.mostDownloaded])
    }
}

// MARK: - Fakes

final class FakeSharedBackupDatabase: SharedBackupDatabase, @unchecked Sendable {
    var pages: [SharedBackupPage] = [.empty]
    var stored: [String: SharedBackupItem] = [:]
    var deleted: [String] = []
    var incremented: [String] = []
    var incrementFails = false

    var requestedProductNumbers: [String?] = []
    var requestedSorts: [SharedBackupSort] = []
    var requestedCursors: [Any?] = []
    /// Set to make the next page call throw.
    var pageError: Error?
    /// Set to make writes throw, for the rollback path.
    var writeFails = false
    /// Set to make deletes throw, for the failed-unpublish path.
    var deleteFails = false

    private var pageIndex = 0

    var reports: [SharedBackupReport] = []
    var reportFails = false

    func addReport(_ report: SharedBackupReport) async throws {
        if reportFails { throw NSError(domain: "test", code: 5) }
        reports.append(report)
    }

    var ratings: [String: Int] = [:]
    var ratingWrites: [(id: String, rating: Int)] = []
    var ratingFails = false

    func rating(id: String, userId: String) async throws -> Int? {
        ratings["\(id)/\(userId)"]
    }

    func setRating(id: String, userId: String, rating: Int) async throws {
        if ratingFails { throw NSError(domain: "test", code: 4) }
        ratings["\(id)/\(userId)"] = rating
        ratingWrites.append((id, rating))
    }

    func page(matching productNumber: String?, sort: SharedBackupSort,
              limit: Int, after cursor: Any?) async throws -> SharedBackupPage {
        if let pageError { throw pageError }
        requestedProductNumbers.append(productNumber)
        requestedSorts.append(sort)
        requestedCursors.append(cursor)
        defer { pageIndex += 1 }
        return pageIndex < pages.count ? pages[pageIndex] : .empty
    }

    func item(id: String) async throws -> SharedBackupItem? { stored[id] }

    func write(_ item: SharedBackupItem) async throws {
        if writeFails { throw NSError(domain: "test", code: 2) }
        stored[item.id] = item
    }

    func delete(id: String) async throws {
        if deleteFails { throw NSError(domain: "test", code: 3) }
        deleted.append(id)
    }

    func incrementDownloadCount(id: String) async {
        guard !incrementFails else { return }
        incremented.append(id)
    }
}

final class FakeSharedStorage: CloudStorage, @unchecked Sendable {
    var data = Data()
    /// Per-URL bodies, for a test that downloads more than one object.
    var dataByURL: [String: Data] = [:]
    var removed: [String] = []
    var removeFails = false
    var uploaded: [(data: Data, path: String)] = []

    func upload(_ data: Data, path: String) async throws -> String {
        uploaded.append((data, path))
        return "https://example.com/\(path)"
    }

    func download(url: String, maxBytes: Int) async throws -> Data {
        if let match = dataByURL[url] { return match }
        return data
    }

    func remove(path: String) async throws {
        if removeFails { throw NSError(domain: "test", code: 1) }
        removed.append(path)
    }
}
