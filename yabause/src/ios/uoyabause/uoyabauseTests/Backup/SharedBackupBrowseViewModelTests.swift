import XCTest
@testable import YabaSnashiro

@MainActor
final class SharedBackupBrowseViewModelTests: XCTestCase {
    private var database: FakeSharedBackupDatabase!
    private var storage: FakeSharedStorage!
    private var viewModel: SharedBackupBrowseViewModel!

    override func setUp() {
        super.setUp()
        database = FakeSharedBackupDatabase()
        storage = FakeSharedStorage()
        viewModel = SharedBackupBrowseViewModel(
            repository: SharedBackupRepository(database: database,
                                               storage: storage),
            isSignedIn: { true },
            currentUserId: { "uid" })
    }

    private func makeItem(id: String, title: String = "NiGHTS",
                          product: String = "GS-9046",
                          owner: String = "uid") -> SharedBackupItem {
        SharedBackupItem(id: id, data: [
            "ownerId": owner, "ownerName": "Shinya",
            "gameTitle": title, "productNumber": product,
            "filename": "SAVE_\(id)", "comment": "", "description": "",
            "saveDate": "1996/07/05 12:34:56",
            "downloadUrl": "https://example.com/\(id)",
            "downloadCount": 0, "isPublic": true,
            "ratings": ["average": 0.0, "count": 0],
            "dataSize": 2048, "blockSize": 4,
        ])!
    }

    func testSignedOutDoesNotQueryAtAll() async {
        viewModel = SharedBackupBrowseViewModel(
            repository: SharedBackupRepository(database: database,
                                               storage: FakeSharedStorage()),
            isSignedIn: { false })
        await viewModel.loadInitial()
        XCTAssertEqual(viewModel.state, .signInRequired)
        XCTAssertTrue(database.requestedSorts.isEmpty,
                      "a signed-out browse still hit the network")
    }

    func testAnEmptyResultReportsEmptyRatherThanLoaded() async {
        database.pages = [.empty]
        await viewModel.loadInitial()
        XCTAssertEqual(viewModel.state, .empty)
        XCTAssertTrue(viewModel.items.isEmpty)
    }

    func testLoadsTheFirstPage() async {
        database.pages = [SharedBackupPage(items: [makeItem(id: "a"),
                                                   makeItem(id: "b")],
                                           cursor: nil)]
        await viewModel.loadInitial()
        XCTAssertEqual(viewModel.state, .loaded)
        XCTAssertEqual(viewModel.items.map(\.id), ["a", "b"])
    }

    /// Loading again must not refetch; the browse screen's .task runs on every
    /// appearance, as the backup tab's did.
    func testLoadInitialOnlyRunsOnce() async {
        database.pages = [SharedBackupPage(items: [makeItem(id: "a")], cursor: nil)]
        await viewModel.loadInitial()
        await viewModel.loadInitial()
        XCTAssertEqual(database.requestedSorts.count, 1)
    }

    /// The next page appends rather than replacing, or scrolling would reset
    /// the list under the user.
    func testLoadingMoreAppends() async {
        database.pages = [
            SharedBackupPage(items: [makeItem(id: "a")], cursor: "c1"),
            SharedBackupPage(items: [makeItem(id: "b")], cursor: nil),
        ]
        await viewModel.loadInitial()
        await viewModel.loadMore()
        XCTAssertEqual(viewModel.items.map(\.id), ["a", "b"])
        XCTAssertFalse(viewModel.canLoadMore, "the walk should have ended")
    }

    func testLoadingMoreStopsAtTheEnd() async {
        database.pages = [SharedBackupPage(items: [makeItem(id: "a")], cursor: nil)]
        await viewModel.loadInitial()
        await viewModel.loadMore()
        XCTAssertEqual(database.requestedSorts.count, 1,
                       "asked for a page past the end")
    }

    /// Changing the sort restarts the walk: keeping the old rows would show
    /// them in an order the server did not produce.
    func testChangingSortRefetchesFromTheStart() async {
        database.pages = [
            SharedBackupPage(items: [makeItem(id: "a")], cursor: "c1"),
            SharedBackupPage(items: [makeItem(id: "z")], cursor: nil),
        ]
        await viewModel.loadInitial()
        await viewModel.apply(sort: .mostDownloaded)
        XCTAssertEqual(viewModel.items.map(\.id), ["z"])
        XCTAssertEqual(database.requestedSorts.last, .mostDownloaded)
        XCTAssertNil(database.requestedCursors.last ?? nil,
                     "a re-sort must start from the beginning")
    }

    /// Narrowing to one game is a server-side filter, so it also restarts.
    func testFilteringByGameRefetches() async {
        database.pages = [
            SharedBackupPage(items: [makeItem(id: "a")], cursor: nil),
            SharedBackupPage(items: [makeItem(id: "b")], cursor: nil),
        ]
        await viewModel.loadInitial()
        await viewModel.apply(productNumber: "GS-9048")
        XCTAssertEqual(database.requestedProductNumbers.last, "GS-9048")
        XCTAssertEqual(viewModel.items.map(\.id), ["b"])
    }

    /// Text search filters what has been fetched. It cannot be a server query
    /// because Firestore has no substring match, so the UI must not imply it
    /// searched everything -- see displayItems vs items.
    func testSearchFiltersTheLoadedRows() async {
        database.pages = [SharedBackupPage(
            items: [makeItem(id: "a", title: "NiGHTS"),
                    makeItem(id: "b", title: "PANZER DRAGOON")],
            cursor: nil)]
        await viewModel.loadInitial()

        viewModel.searchText = "panzer"
        XCTAssertEqual(viewModel.displayItems.map(\.id), ["b"])

        viewModel.searchText = ""
        XCTAssertEqual(viewModel.displayItems.count, 2)
    }

    func testAFailureIsReportedAndRetryable() async {
        database.pageError = NSError(domain: "test", code: 1)
        await viewModel.loadInitial()
        XCTAssertEqual(viewModel.state, .failed)

        database.pageError = nil
        database.pages = [SharedBackupPage(items: [makeItem(id: "a")], cursor: nil)]
        await viewModel.retry()
        XCTAssertEqual(viewModel.state, .loaded)
    }

    // MARK: - Reporting and blocking

    private func makeBlockList() -> SharedBackupBlockList {
        let defaults = UserDefaults(suiteName: "block-test-\(UUID().uuidString)")!
        return SharedBackupBlockList(defaults: defaults)
    }

    private func makeViewModel(blockList: SharedBackupBlockList,
                               uid: String = "uid") -> SharedBackupBrowseViewModel {
        SharedBackupBrowseViewModel(
            repository: SharedBackupRepository(database: database,
                                               storage: storage),
            isSignedIn: { true },
            currentUserId: { uid },
            blockList: blockList)
    }

    /// Reporting your own save is meaningless; taking it down is the action
    /// that exists for that.
    func testOnlySomeoneElsesSaveCanBeReported() {
        XCTAssertFalse(viewModel.canReport(makeItem(id: "a")))

        let reader = makeViewModel(blockList: makeBlockList(), uid: "other")
        XCTAssertTrue(reader.canReport(makeItem(id: "a")))
    }

    func testReportingRecordsTheSaveItsOwnerAndTheReporter() async {
        let reader = makeViewModel(blockList: makeBlockList(), uid: "other")

        let sent = await reader.report(makeItem(id: "a"), reason: .spam)

        XCTAssertTrue(sent)
        XCTAssertEqual(database.reports.count, 1)
        let report = database.reports[0]
        XCTAssertEqual(report.backupId, "a")
        XCTAssertEqual(report.ownerId, "uid")
        XCTAssertEqual(report.reporterId, "other")
        XCTAssertEqual(report.reason, .spam)
    }

    /// A report is a request to look, not a takedown: the save stays listed
    /// until someone reads the report and decides.
    func testReportingLeavesTheSaveInTheList() async {
        database.pages = [SharedBackupPage(items: [makeItem(id: "a")],
                                           cursor: nil)]
        let reader = makeViewModel(blockList: makeBlockList(), uid: "other")
        await reader.loadInitial()

        _ = await reader.report(makeItem(id: "a"), reason: .spam)

        XCTAssertEqual(reader.displayItems.map(\.id), ["a"])
    }

    func testAFailedReportIsReported() async {
        database.reportFails = true
        let reader = makeViewModel(blockList: makeBlockList(), uid: "other")

        let sent = await reader.report(makeItem(id: "a"), reason: .other)

        XCTAssertFalse(sent)
        XCTAssertNotNil(reader.errorMessage)
    }

    func testBlockingHidesEverythingByThatPoster() async {
        database.pages = [SharedBackupPage(items: [makeItem(id: "a"),
                                                   makeItem(id: "b")],
                                           cursor: nil)]
        let reader = makeViewModel(blockList: makeBlockList(), uid: "other")
        await reader.loadInitial()

        reader.block(makeItem(id: "a"))

        // Both were posted by "uid", so hiding the poster hides both.
        XCTAssertTrue(reader.displayItems.isEmpty)
        XCTAssertEqual(reader.blockedCount, 1)
    }

    /// The unhide row is drawn with the list, and the empty state replaces
    /// the list. Going empty here would leave no way to undo the hiding.
    func testHidingTheLastVisibleRowKeepsTheListShowing() async {
        database.pages = [SharedBackupPage(items: [makeItem(id: "a")],
                                           cursor: nil)]
        let reader = makeViewModel(blockList: makeBlockList(), uid: "other")
        await reader.loadInitial()

        reader.block(makeItem(id: "a"))

        XCTAssertEqual(reader.state, .loaded)
    }

    /// Same reason: an unpublish that empties the list must not hide the row
    /// that would bring the hidden posters back. The hidden poster here has
    /// nothing in this page, which is the ordinary case once a block outlives
    /// the session that made it.
    func testUnpublishingTheLastRowStaysLoadedWhileSomeoneIsHidden() async {
        database.pages = [SharedBackupPage(items: [makeItem(id: "b", owner: "me")],
                                           cursor: nil)]
        let blockList = makeBlockList()
        blockList.block("someone-from-an-earlier-session")
        let owner = makeViewModel(blockList: blockList, uid: "me")
        await owner.loadInitial()

        _ = await owner.unpublish(makeItem(id: "b", owner: "me"))

        XCTAssertTrue(owner.items.isEmpty)
        XCTAssertEqual(owner.state, .loaded)
    }

    /// A search must not be a way back to someone the user hid.
    func testASearchCannotSurfaceABlockedPoster() async {
        database.pages = [SharedBackupPage(items: [makeItem(id: "a")],
                                           cursor: nil)]
        let reader = makeViewModel(blockList: makeBlockList(), uid: "other")
        await reader.loadInitial()
        reader.block(makeItem(id: "a"))

        reader.searchText = "NiGHTS"

        XCTAssertTrue(reader.displayItems.isEmpty)
    }

    func testUnblockingBringsThePostersBack() async {
        database.pages = [SharedBackupPage(items: [makeItem(id: "a")],
                                           cursor: nil)]
        let reader = makeViewModel(blockList: makeBlockList(), uid: "other")
        await reader.loadInitial()
        reader.block(makeItem(id: "a"))

        reader.unblockAll()

        XCTAssertEqual(reader.displayItems.map(\.id), ["a"])
        XCTAssertEqual(reader.state, .loaded)
        XCTAssertEqual(reader.blockedCount, 0)
    }

    // MARK: - Rating

    /// Rating a community save is a Pro feature. These tests are about the
    /// rating itself, so they say who the user is rather than leaving it to
    /// the default entitlement, whose value depends on when the app host's
    /// launch-time StoreKit read lands. The gate is pinned separately below.
    private var unlocked: ProEntitlement {
        ProEntitlement(showsAdvertising: false, legacy: .legacyPaid, purchase: .none)
    }


    func testRatingRecordsTheScoreUnderTheSignedInUser() async {
        let item = makeItem(id: "a")
        let sent = await viewModel.rate(item, stars: 4, entitlement: unlocked)

        XCTAssertTrue(sent)
        XCTAssertEqual(database.ratings["a/uid"], 4)
        XCTAssertNil(viewModel.errorMessage)
    }

    /// The average comes back from the Cloud Function that recomputes it.
    /// Guessing it here would show a figure the server never agreed to.
    func testRatingDoesNotInventANewAverage() async {
        database.pages = [SharedBackupPage(items: [makeItem(id: "a")],
                                           cursor: nil)]
        await viewModel.loadInitial()

        _ = await viewModel.rate(makeItem(id: "a"), stars: 5, entitlement: unlocked)

        XCTAssertEqual(viewModel.items.first?.averageRating, 0)
        XCTAssertEqual(viewModel.items.first?.ratingCount, 0)
    }

    func testTheExistingScoreIsReadBackSoThePickerOpensOnIt() async {
        database.ratings["a/uid"] = 2
        let existing = await viewModel.myRating(of: makeItem(id: "a"))
        XCTAssertEqual(existing, 2)
    }

    func testSignedOutThereIsNowhereToRecordARating() async {
        let signedOut = SharedBackupBrowseViewModel(
            repository: SharedBackupRepository(database: database,
                                               storage: storage),
            isSignedIn: { false },
            currentUserId: { nil })

        XCTAssertFalse(signedOut.canRate)
        let sent = await signedOut.rate(makeItem(id: "a"), stars: 3,
                                        entitlement: unlocked)
        XCTAssertFalse(sent)
        XCTAssertTrue(database.ratingWrites.isEmpty)
    }

    /// Android limits rating to Pro. Without this, nothing would notice if
    /// the gate were dropped from rate().
    func testRatingIsRefusedWithoutAnEntitlement() async {
        let locked = ProEntitlement(showsAdvertising: true, legacy: .notLegacy,
                                    purchase: .none)
        let sent = await viewModel.rate(makeItem(id: "a"), stars: 4,
                                        entitlement: locked)

        XCTAssertFalse(sent)
        XCTAssertTrue(database.ratingWrites.isEmpty, "a locked rating still wrote")
        XCTAssertNotNil(viewModel.gateReason,
                        "the user was refused with no way to fix it")
    }

    func testAFailedRatingIsReported() async {
        database.ratingFails = true
        let sent = await viewModel.rate(makeItem(id: "a"), stars: 3,
                                        entitlement: unlocked)
        XCTAssertFalse(sent)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    // MARK: - Shared links

    /// Fetched by id, not searched for in what has been paged in: a link may
    /// name a save far older than the first page.
    func testFollowingALinkFetchesTheSaveEvenIfItWasNeverListed() async {
        database.pages = [.empty]
        database.stored["z"] = makeItem(id: "z")
        await viewModel.loadInitial()

        await viewModel.openLink(id: "z")

        XCTAssertEqual(viewModel.linkedItem?.id, "z")
    }

    func testALinkToASaveThatIsGoneReportsRatherThanOpeningNothing() async {
        await viewModel.loadInitial()

        await viewModel.openLink(id: "missing")

        XCTAssertNil(viewModel.linkedItem)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    func testFollowingALinkWhileSignedOutAsksForSignIn() async {
        database.stored["z"] = makeItem(id: "z")
        let signedOut = SharedBackupBrowseViewModel(
            repository: SharedBackupRepository(database: database,
                                               storage: storage),
            isSignedIn: { false },
            currentUserId: { nil })

        await signedOut.openLink(id: "z")

        XCTAssertEqual(signedOut.state, .signInRequired)
        XCTAssertNil(signedOut.linkedItem)
    }

    // MARK: - Unpublishing

    func testOnlyTheOwnerMayUnpublish() {
        XCTAssertTrue(viewModel.canUnpublish(makeItem(id: "a")))

        let someoneElse = SharedBackupBrowseViewModel(
            repository: SharedBackupRepository(database: database,
                                               storage: storage),
            isSignedIn: { true },
            currentUserId: { "other" })
        XCTAssertFalse(someoneElse.canUnpublish(makeItem(id: "a")))

        let signedOut = SharedBackupBrowseViewModel(
            repository: SharedBackupRepository(database: database,
                                               storage: storage),
            isSignedIn: { false },
            currentUserId: { nil })
        XCTAssertFalse(signedOut.canUnpublish(makeItem(id: "a")))
    }

    func testUnpublishingDropsTheRowAndBothStoredObjects() async {
        database.pages = [SharedBackupPage(items: [makeItem(id: "a"),
                                                   makeItem(id: "b")],
                                           cursor: nil)]
        await viewModel.loadInitial()

        let removed = await viewModel.unpublish(makeItem(id: "a"))

        XCTAssertTrue(removed)
        XCTAssertEqual(viewModel.items.map(\.id), ["b"])
        XCTAssertEqual(viewModel.displayItems.map(\.id), ["b"])
        XCTAssertEqual(database.deleted, ["a"])
        // The screenshot goes too. Android deletes only the save, leaving an
        // object no document points at and nobody can reach.
        XCTAssertEqual(storage.removed, ["shared_backups/a/SAVE_a",
                                         "shared_backups/a/screenshot.png"])
    }

    /// Removing the only row must not leave the list claiming to be loaded
    /// with nothing in it.
    func testUnpublishingTheLastRowReportsEmpty() async {
        database.pages = [SharedBackupPage(items: [makeItem(id: "a")],
                                           cursor: nil)]
        await viewModel.loadInitial()

        _ = await viewModel.unpublish(makeItem(id: "a"))

        XCTAssertEqual(viewModel.state, .empty)
    }

    func testAFailedUnpublishKeepsTheRowAndReports() async {
        database.pages = [SharedBackupPage(items: [makeItem(id: "a")],
                                           cursor: nil)]
        await viewModel.loadInitial()
        database.deleteFails = true

        let removed = await viewModel.unpublish(makeItem(id: "a"))

        XCTAssertFalse(removed)
        XCTAssertEqual(viewModel.items.map(\.id), ["a"],
                       "the row vanished though the server still has it")
        XCTAssertNotNil(viewModel.errorMessage)
    }

    /// The row is hidden for non-owners, but the check belongs here too: the
    /// rules would refuse anyway, and a local drop would lie about it.
    func testUnpublishingSomeoneElsesSaveDoesNothing() async {
        database.pages = [SharedBackupPage(items: [makeItem(id: "a")],
                                           cursor: nil)]
        let someoneElse = SharedBackupBrowseViewModel(
            repository: SharedBackupRepository(database: database,
                                               storage: storage),
            isSignedIn: { true },
            currentUserId: { "other" })
        await someoneElse.loadInitial()

        let removed = await someoneElse.unpublish(makeItem(id: "a"))

        XCTAssertFalse(removed)
        XCTAssertTrue(database.deleted.isEmpty)
        XCTAssertEqual(someoneElse.items.map(\.id), ["a"])
    }
}
